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
            let retry = now.addingTimeInterval(15 * 60)
            completion(Timeline(entries: [Entry(date: now, snapshot: snap, roundSteps: steps)],
                                policy: .after(retry)))
        }

        guard let snap, snap.enabled, let anchor = snap.anchor, anchor < now else {
            finish(nil)
            return
        }
        guard CMPedometer.isStepCountingAvailable() else {
            finish(snap.roundSteps)
            return
        }
        // 必须持住这个对象。写成 `CMPedometer().queryPedometerData(...)` 的话，
        // 它是临时实例，方法一返回就被释放，回调永远不会来 ——
        // 表盘会一直停在「还差 — 步」。用完再放掉。
        let pedometer = CMPedometer()
        Self.pedometer = pedometer
        pedometer.queryPedometerData(from: anchor, to: now) { data, _ in
            Self.pedometer = nil
            finish(data.map { Int(truncating: $0.numberOfSteps) })
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

    /// 走满 = 绿；超时没走够 = 红；其余跟随表盘主题色。
    /// 注意：这一格在表盘上最终还是由系统按「强调色」渲染，
    /// 这里的 tint 只在支持全色的场合生效，别指望它一定变成绿色。
    private var tint: Color {
        if reached { return .green }
        if overdue { return .red }
        return .accentColor
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
            Text(headline)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                // 进强调色组：进组后这一行会跟表盘主题色走，
                // 而不是被当成「不参与着色」的纯白文字。
                .widgetAccentable()

            ProgressView(value: progress)
                .tint(tint)
                .widgetAccentable()

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
        // 表盘上小圆圈槽位默认单色。进强调组后它会用表盘主题色，
        // 和系统的活动圆环一样有颜色，而不是一格白图标。
        .widgetAccentable()
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
