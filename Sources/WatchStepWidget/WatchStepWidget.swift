import WidgetKit
import SwiftUI
import CoreMotion

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

        func finish(_ steps: Int?) {
            let entry = Entry(date: now, snapshot: snap, roundSteps: steps)
            // 5 分钟后再请系统刷一次。实际给不给刷由系统预算决定，
            // 但下面的倒计时用的是 system 动态文本，中间不会停在旧时间上。
            let next = now.addingTimeInterval(5 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
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

    /// 本轮该提醒的时刻 = 锚点 + 窗口长度。交给系统按相对时间自己走字，
    /// 不占我的刷新预算，抬腕看到的永远是准的。
    private var deadline: Date? {
        guard let snap = entry.snapshot, let anchor = snap.anchor else { return nil }
        return anchor.addingTimeInterval(TimeInterval(snap.windowMinutes * 60))
    }

    private var reached: Bool { (steps ?? 0) >= target }

    private var overdue: Bool {
        guard let deadline, !reached, !paused else { return false }
        return entry.date > deadline
    }

    private var tint: Color {
        if disabled || paused { return .secondary }
        if reached { return .green }
        if overdue { return .red }
        return .primary
    }

    private var headline: String {
        if disabled { return "提醒已关" }
        if paused { return "已暂停" }
        if let remaining {
            return reached ? "已满 \(target) 步" : "还差 \(remaining) 步"
        }
        return "还差 — 步"
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
        default:
            rectangular
        }
    }

    /// 大表盘（模块化那一格）：两行字 + 一条细进度。
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(headline)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                // 关键：加进「强调色组」。
                //
                // watchOS 表盘的复杂功能是 accented 渲染：系统把视图分成两组，
                // 强调组用表盘主题色，默认组用白色。而且**忽略视图自己的颜色，
                // 只按 alpha 通道上色**（Apple 文档原文）。
                //
                // 所以 foregroundStyle(tint) 在表盘上根本不生效，不标记的话
                // 这一格就是纯白 —— 也正是整块表盘跟着被压成单色的原因。
                // 标记之后它会跟系统日历、天气一样用表盘的主题色。
                .widgetAccentable()

            HStack(spacing: 4) {
                if disabled || paused {
                    Text(disabled ? "在 App 里打开" : "在 App 里恢复")
                        .font(.system(size: 11))
                } else if let deadline {
                    // 用 .relative 不用 .timer：.timer 对**未来**的时刻会显示成
                    // "-12:30" 这种负数倒计时，很怪。.relative 是系统动态文本，
                    // 会自己走字（"12分钟后" / 过期后"3分钟前"），不消耗刷新预算。
                    Text("本轮").font(.system(size: 11))
                    Text(deadline, style: .relative)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(deadline > entry.date ? Color.secondary : Color.red)
                } else {
                    Text("打开 App 开始").font(.system(size: 11))
                }
            }
            .lineLimit(1)

            ProgressView(value: progress)
                .tint(tint)
                // 进度条也进强调组，跟着表盘主题色走；不标记的话表盘上是一条白杠。
                .widgetAccentable()
        }
    }

    /// 小表盘：只放一个走人图标当前入口，外圈那道弧是进度，不显示数字
    /// —— 步数用户另外有软件看。
    private var circular: some View {
        Gauge(value: progress) {
            Image(systemName: "figure.walk")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(tint)
        // 表盘上小圆圈槽位默认是单色的。进强调组后它会用表盘主题色，
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
        .description("还差多少步、本轮还剩多久")
        // 只出这两款。accessoryInline 只能返回一个纯 Text，
        // 套 containerBackground 容易渲成空白，而且那一格本来就是「一句话」的位置，
        // 用户要的是图标入口 + 模块化那一格，不要它。
        .supportedFamilies([.accessoryRectangular, .accessoryCircular])
    }
}

@main
struct WatchStepWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchStepComplication()
    }
}
