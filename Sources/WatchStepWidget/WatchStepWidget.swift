import WidgetKit
import SwiftUI
import CoreMotion

// MARK: - 设计原则（别随手改回去）
//
// 1. **只给一条 entry**，不预生成逐分钟的时间线。
//    以前试过一次给 60~95 条、每分钟一条，靠系统到点换条来让倒计时走字。
//    代价是每一格都要重新渲染一次，白耗电；而且条目一多，系统更容易把
//    这格复杂功能放进低优先级队列，反而更不准。
//
// 2. **倒计时用 Text(_, style: .timer)，交给系统渲染。**
//    秒是系统自己画的，不走 App、不占快照、不产生额外唤醒，只在这一格
//    可见且系统刷新表盘时跟着变一下 —— 实测代价可以忽略。
//    所以这里保留「本轮 12:40」这种带秒的读法，不用自己做逐分钟时间线。
//    表盘自己不跑定时器、不自己轮询步数 —— 那才是真费电。

// MARK: - 数据

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: SharedSnapshot?
    /// 本轮已走步数。nil = 读不到（没锚点 / 计步器不可用 / 拿不到共享数据）。
    let roundSteps: Int?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snapshot: nil, roundSteps: 133)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: SharedSnapshot.load(), roundSteps: nil))
    }

    /// 本轮到期时刻 = 锚点 + 窗口长度。和视图里的算法保持一致。
    private func deadlineOf(_ snap: SharedSnapshot?) -> Date? {
        guard let snap, let anchor = snap.anchor else { return nil }
        return anchor.addingTimeInterval(TimeInterval(snap.windowMinutes * 60))
    }

    /// 表盘自己用 CMPedometer 从锚点算到现在。
    ///
    /// 这样**不依赖主 App 是否还活着** —— App 被杀掉，步数照样是新算的，
    /// 不用等它醒来。但「走够 200 步要不要归零」这件判断仍然只有主 App 能做，
    /// 因为它要靠通知链和锚点，那是 App 自己的事。
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date()
        let snap = SharedSnapshot.load()

        // completion 只能调用一次。查询链可能比看门狗慢（二分要好几轮），
        // 没有这道闸的话超时先交了一份、查询回来又交一份 ——
        // WidgetKit 会当成两次时间线请求，白烧预算。
        var answered = false

        // 下次再问的时机：App 醒着时由它主动 reload，这一条只是兜底。
        func finish(_ steps: Int?, anchorOverride: Date? = nil) {
            guard !answered else { return }
            answered = true
            // anchorOverride：表盘自己推算出来的新一轮起点。
            // 走满归零时 App 可能在睡觉，等它醒就晚了 15 分钟 ——
            // 这时用表盘算出来的时刻顶替，倒计时和进度立刻就是对的。
            var used = snap
            if let a = anchorOverride { used?.anchor = a }
            // 除了「现在」这一条，还要在**到期那一刻**放一条。
            //
            // 为什么必须这样：倒计时用的是 Text(_, style: .timer)，那是系统
            // 从某个时刻开始的计时器，过了零点会继续往上加。整条时间线只有
            // 「现在」一条的话，跨过零点没有新条目来顶替它，用户就会看到
            // 「一轮都结束了，它还在往上增加」。
            //
            // 放一条 date == deadline 的 entry，系统到点自动切过去，
            // 那条的子行是「该动了」，不依赖 App 是否还活着。
            var entries = [Entry(date: now, snapshot: used, roundSteps: steps)]
            if let d = deadlineOf(used), d > now {
                entries.append(Entry(date: d, snapshot: used, roundSteps: steps))
                entries.append(Entry(date: d.addingTimeInterval(1), snapshot: used, roundSteps: steps))
            }
            // 兜底节奏：这是「系统下次来问扩展」的时间，属于**要花预算**的动作，
            // 和 App 侧的 reloadTimelines 抢同一份配额。
            //
            // watchOS 给一块表盘复杂功能的额度大约是**按天**几十次，不是按小时。
            // 我们踩过的坑：4.8 把 App 侧节流收到 60 秒（每小时 60 次）、
            // 4.9 又把这里收到 90 秒，一两个小时就把一整天的额度烧光。
            // 烧完之后系统退化成固定间隔 —— 实测就是**15 分钟**才更新一次，
            // 而且不管 App 怎么喊都不再理。
            //
            // 现在放到 15 分钟，对齐系统自己的退化频率：既然它反正按这个节奏
            // 来问，我们就不必再额外消耗额度去求它。真正要紧的那一次
            // （走满归零）由 App 的 reload 负责，而且表盘自己也会算（见下）。
            completion(Timeline(entries: entries,
                                policy: .after(now.addingTimeInterval(900))))
        }

        // CMPedometer 的回调不一定按时来（权限被拒、系统忙都可能）。
        // 不设看门狗的话 completion 永远不调用 = 这一格永远没有新数据，
        // 系统会一直显示上一次的旧画面。所以到点必给一个结果。
        // 主 App 每轮 tick 都会把真实的 roundSteps 写进共享快照，它一定
        // 有 Motion 权限（App 本体声明过）。表盘自己调 CMPedometer 只是
        // 「让数字更新鲜一点」的加分项 —— 扩展里这次查询可能直接失败，
        // 一辈子不回调。所以先用快照里的值当底，查询成功了再往上顶。
        let baseSteps = snap?.roundSteps

        func finishOnce(_ steps: Int?) {
            // 两个来源取大的那个：快照是主 App 算的，pedometer 是刚查的，
            // 正常情况下后者 ≥ 前者；万一 pedometer 给出更小值（权限/口径
            // 问题），用快照的，别让进度往回退。
            // 去重交给 finish 里的 answered 闸门。
            if let a = steps, let b = baseSteps { finish(max(a, b)); return }
            finish(steps ?? baseSteps)
        }
        // 兜底提前到 2 秒：用户抬手腕就等这一下，3 秒已经能感觉到空白。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            finishOnce(nil)
        }

        guard let snap, snap.enabled, let anchor = snap.anchor, anchor < now else {
            finishOnce(nil)
            return
        }
        // 暂停期间不推算归零：暂停就是「别催我」，算出个新一轮反而更吵。
        if let until = snap.pausedUntil, until > now {
            finishOnce(nil)
            return
        }
        guard CMPedometer.isStepCountingAvailable() else {
            finishOnce(nil)
            return
        }

        // ★ 走满归零：表盘自己算，不等 App 醒。
        //
        // watchOS 不给 App 真常驻 —— 主 App 被挂起后，「走够 200 步该归零」
        // 这个决定就没人做了，表盘只能卡在「还差 0 步」等系统下次唤醒 App。
        // 实测那个等待是 15 分钟，用户看到的就是「第二轮都在催了，
        // 表盘还停在上一条」。
        //
        // 表盘扩展自己有 CMPedometer 权限（NSMotionUsageDescription 已声明），
        // 被系统问到的那一刻，可以用二分把「什么时候达到 target 步」算出来。
        // 那一刻就是新一轮的起点 —— 和主 App 的归零逻辑一致（走满即重置）。
        //
        // 成本：只在「确实已走满」时才做，最多 7 次本地查询（亚秒级），
        // 而且发生在系统本来就要问我们的那一次，不额外消耗刷新预算。
        let target = max(1, snap.targetSteps)
        query(from: anchor, to: now) { total in
            guard let total, total >= target else {
                finishOnce(total)
                return
            }
            roll(anchor: anchor, now: now, target: target, depth: 0) { rolledAt, rest in
                finish(rest, anchorOverride: rolledAt)
            }
        }
    }

    /// 查 a→b 的步数。
    ///
    /// 必须持住 CMPedometer 实例：写成 `CMPedometer().queryPedometerData(...)`
    /// 的话它是临时实例，方法一返回就被释放，回调永远不会来 ——
    /// 表盘会一直停在「还差 — 步」。用完再放掉。
    private func query(from a: Date, to b: Date, done: @escaping (Int?) -> Void) {
        let p = CMPedometer()
        Self.pedometer = p
        p.queryPedometerData(from: a, to: b) { data, _ in
            Self.pedometer = nil
            done(data.map { Int(truncating: $0.numberOfSteps) })
        }
    }

    /// 找出本轮达到 target 步的时刻（二分），把它当作新一轮的起点。
    ///
    /// 精度 60 秒就够 —— 用户看的是「本轮剩 12 分钟」和「还差 30 步」，
    /// 起点差几十秒看不出来。再往下二分也没意义：CMPedometer 本身按分钟聚合。
    ///
    /// depth 用来兜住「App 睡了很久、期间走满好几轮」的情况。
    /// 不循环的话，推算出来的新一轮可能起点也已经满了，视图会卡在「已满」。
    private func roll(anchor: Date, now: Date, target: Int, depth: Int,
                      done: @escaping (Date, Int) -> Void) {
        var lo = anchor
        var hi = now
        var iter = 0

        func go() {
            // 7 次二分把区间收到 ~60 秒（30 分钟窗口的 1/32）。
            if iter >= 7 || hi.timeIntervalSince(lo) <= 60 {
                // hi 附近就是走满的时刻。这一轮之后还剩多少步，交给下一段算。
                query(from: hi, to: now) { rest in
                    let r = rest ?? 0
                    if r >= target && depth < 3 {
                        roll(anchor: hi, now: now, target: target, depth: depth + 1, done: done)
                    } else {
                        done(hi, r)
                    }
                }
                return
            }
            iter += 1
            let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
            query(from: anchor, to: mid) { s in
                if let v = s, v >= target { hi = mid } else { lo = mid }
                go()
            }
        }
        go()
    }

    /// 查询期间保活用。同一时刻只有一个查询，够用。
    private static var pedometer: CMPedometer?
}

// MARK: - 视图

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    private var target: Int { max(1, entry.snapshot?.targetSteps ?? 200) }
    private var steps: Int? { entry.roundSteps }

    private var paused: Bool {
        guard let until = entry.snapshot?.pausedUntil else { return false }
        return until > entry.date
    }

    private var disabled: Bool { entry.snapshot.map { !$0.enabled } ?? false }

    private var remaining: Int? {
        guard let steps else { return nil }
        return max(0, target - steps)
    }

    private var progress: Double {
        guard let steps else { return 0 }
        return min(1, Double(steps) / Double(target))
    }

    /// 本轮该提醒的时刻 = 锚点 + 窗口长度。
    /// 显示绝对值而不是倒计时，一次渲染管一整轮，不用分分钟刷新。
    private var deadline: Date? {
        guard let snap = entry.snapshot, let anchor = snap.anchor else { return nil }
        return anchor.addingTimeInterval(TimeInterval(snap.windowMinutes * 60))
    }

    private var reached: Bool { (steps ?? 0) >= target }

    private var overdue: Bool {
        guard let deadline, !reached, !paused else { return false }
        return entry.date > deadline
    }

    /// 走满 = 绿；超时没走够 = 红；其余 = 蓝。
    /// 必须是明确的 Color：以前返回 .accentColor，表盘上会被解析成
    /// 白/灰（看着就是"没有颜色"），只有 .blue/.green 这种明确的色值
    /// 才画得出来 —— 用户看到的"走满时是绿的"就是这个原因。
    private var tint: Color {
        if reached { return .green }
        if overdue { return .red }
        return .blue
    }

    /// 第一行大字。
    private var headline: String {
        if disabled { return "已关闭" }
        if paused { return "已暂停" }
        if reached { return "已满 \(target) 步" }
        guard let remaining else { return "还差 — 步" }
        return "还差 \(remaining) 步"
    }

    /// 第二行小字：倒计时，带秒。
    /// 用 Text(_, style: .timer) 交给系统自己渲染 —— 这个字是系统画的，
    /// 不用 App 算、不唤醒 App、也不预生成一堆 entry，
    /// 表盘本来就在走秒，这一格只是跟着变，额外耗电可忽略。
    /// 所以按用户要求保留秒：12:40 → 12:39 → 12:38，到点归零。
    @ViewBuilder
    private var subline: some View {
        Group {
            if disabled {
                Text("催步已关")
            } else if paused {
                Text("催步暂停")
            } else if reached {
                Text("本轮完成")
            } else if let deadline, deadline > entry.date {
                HStack(spacing: 0) {
                    Text("剩 ")
                    Text(deadline, style: .timer)
                }
            } else if let deadline {
                // 逾期之后计时继续往上数。
                //
                // 原来这里只有 "该动了" 三个字，理由是「具体分钟会随 entry
                // 老化变错」。那个理由不成立：Text(_, style: .timer) 是系统
                // 画的秒表，entry 再老它也按真实时间走，那个数永远不会错。
                //
                // 而且它比三个字有用得多：看到 "该动了 4:12" 就知道已经逾期
                // 4 分钟，再按系统约 15 分钟问一次表盘的节奏，能自己估出
                // 还有多久会跳成正确数字。这正好把「刷新滞后」这件看不见的
                // 事变成了看得见的数 —— 表盘还在走秒，也说明它还活着。
                HStack(spacing: 3) {
                    Text("该动了")
                    Text(deadline, style: .timer)
                        .foregroundStyle(.red)
                }
            } else {
                Text("催步")
            }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    var body: some View {
        content
            // accessory 系列要用 AccessoryWidgetBackground()，不能塞 Color.clear。
            // 透明背景在表盘上会被当成「没有背景材质」，跟着一起被去色处理。
            .containerBackground(for: .widget) { AccessoryWidgetBackground() }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryInline:
            // inline 只接受纯文本，套容器会渲染成空白。
            Text(inline)
        default:
            rectangular
        }
    }

    private var inline: String {
        if disabled { return "催步已关" }
        if paused { return "催步暂停" }
        if reached { return "已走满 \(target)" }
        return "走 \(steps ?? 0)/\(target)"
    }

    // MARK: 大格（模块化大表盘）

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 标题就用白色。不要 widgetAccentable —— 进强调组会跟着
            // 表盘主题色跑，反而不是我们想要的白。
            Text(headline)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            // 进度条自己画，不用 ProgressView：
            // 系统在表盘上下文会把 ProgressView 强制画成单色，
            // 只有自己用 Shape + 明确的 Color 填充才拿得到真颜色。
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.28))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, geo.size.width * progress))
                }
            }
            .frame(height: 5)

            subline
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 小圆圈（只当入口用）

    private var circular: some View {
        Gauge(value: progress) {
            Image(systemName: "figure.walk")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(tint)
    }
}

// MARK: - 入口

struct WatchStepComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchStepComplication", provider: Provider()) { entry in
            ComplicationView(entry: entry)
        }
        .configurationDisplayName("步数进度")
        .description("本轮还差多少步，以及几点提醒。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

@main
struct WatchStepWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchStepComplication()
    }
}
