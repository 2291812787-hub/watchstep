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

        // 下次再问的时机：跟着 App 的 tick 节奏走。App 每轮 tick 都会主动
        // reloadTimelines，这一条只是兜底 —— 万一 App 没在跑，也别让表盘
        // 一直挂着老数据。15 分钟足够，且远在系统预算之内。
        func finish(_ steps: Int?) {
            // 除了「现在」这一条，还要在**到期那一刻**放一条。
            //
            // 为什么必须这样：倒计时用的是 Text(_, style: .timer)，那是系统
            // 从某个时刻开始的计时器，过了零点会继续往上加。整条时间线只有
            // 「现在」一条的话，跨过零点没有新条目来顶替它，用户就会看到
            // 「一轮都结束了，它还在往上增加」。
            //
            // 放一条 date == deadline 的 entry，系统到点自动切过去，
            // 那条的子行是「该动了」，不依赖 App 是否还活着。
            var entries = [Entry(date: now, snapshot: snap, roundSteps: steps)]
            if let d = deadlineOf(snap), d > now {
                entries.append(Entry(date: d, snapshot: snap, roundSteps: steps))
                entries.append(Entry(date: d.addingTimeInterval(1), snapshot: snap, roundSteps: steps))
            }
            // 5 分钟兜底：扩展崩溃/被系统压制时，至少这个间隔后还会再被问一次。
            // 15 分钟太长了 —— 用户拉手腕看到的步数会明显落后。
            // 90 秒：App 后台 tick 是 60 秒一轮，表盘兜底比它稍长一点，
            // 这样每轮 tick 漏掉的刷新，最多 90 秒后系统重算一次补上。
            // 原来 5 分钟太长 —— 走满归零之后用户要盯着一格错数字等五分钟。
            completion(Timeline(entries: entries,
                                policy: .after(now.addingTimeInterval(90))))
        }

        // CMPedometer 的回调不一定按时来（权限被拒、系统忙都可能）。
        // 不设看门狗的话 completion 永远不调用 = 这一格永远没有新数据，
        // 系统会一直显示上一次的旧画面。所以到点必给一个结果。
        // 主 App 每轮 tick 都会把真实的 roundSteps 写进共享快照，它一定
        // 有 Motion 权限（App 本体声明过）。表盘自己调 CMPedometer 只是
        // 「让数字更新鲜一点」的加分项 —— 扩展里这次查询可能直接失败，
        // 一辈子不回调。所以先用快照里的值当底，查询成功了再往上顶。
        let baseSteps = snap?.roundSteps

        var answered = false
        func finishOnce(_ steps: Int?) {
            guard !answered else { return }
            answered = true
            // 两个来源取大的那个：快照是主 App 算的，pedometer 是刚查的，
            // 正常情况下后者 ≥ 前者；万一 pedometer 给出更小值（权限/口径
            // 问题），用快照的，别让进度往回退。
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
        guard CMPedometer.isStepCountingAvailable() else {
            finishOnce(nil)
            return
        }
        // 必须持住这个对象。写成 `CMPedometer().queryPedometerData(...)` 的话，
        // 它是临时实例，方法一返回就被释放，回调永远不会来 ——
        // 表盘会一直停在「还差 — 步」。用完再放掉。
        let pedometer = CMPedometer()
        Self.pedometer = pedometer
        pedometer.queryPedometerData(from: anchor, to: now) { data, _ in
            Self.pedometer = nil
            finishOnce(data.map { Int(truncating: $0.numberOfSteps) })
        }
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
            } else if deadline != nil {
                // 逾期不显示具体分钟：那个数字会随 entry 老化变错，
                // 而 "该动了" 永远是对的。
                Text("该动了")
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
