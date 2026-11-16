import Foundation
import WatchKit
import Combine

/// 引擎：把「状态 → 判定 → 动作 → 通知对账」串成一条链。
/// 所有入口（前台 tick、后台刷新、开机、用户点按钮）都调同一个 `tick`，
/// 不存在第二套逻辑。
final class WatchEngine: ObservableObject {
    static let shared = WatchEngine()

    // MARK: - 对外状态

    @Published private(set) var config: Config
    @Published private(set) var stepsInWindow: Int = 0
    @Published private(set) var lastDecision: Decision = .unknown
    @Published private(set) var lastCheckAt: Date?
    @Published private(set) var nudgesToday: Int = 0
    @Published private(set) var longestIdle: TimeInterval = 0
    @Published private(set) var pendingNotifications: Int = 0
    @Published private(set) var notificationAuth: String = "未询问"
    @Published private(set) var stepCountingAvailable: Bool = StepReader.shared.isAvailable
    @Published private(set) var lastError: String = ""

    /// 自检结果（验收用）
    @Published private(set) var selfCheckLog: [String] = []

    private var timer: Timer?
    private var busy = false
    private var booted = false

    private init() {
        config = Config.load()
        nudgesToday = AnchorStore.shared.nudgesToday
        longestIdle = AnchorStore.shared.longestIdle
    }

    // MARK: - 生命周期

    func boot() {
        guard !booted else {
            tick(force: true)
            return
        }
        booted = true
        NotificationPlanner.shared.requestAuthorization()
        NotificationPlanner.shared.authorizationStatus { [weak self] s in
            self?.notificationAuth = s
        }
        startTicker()
        WatchBackgroundScheduler.shared.reschedule()
        tick(force: true)
    }

    /// 前台定时器：每 30 秒看一眼。真正的步数查询有缓存，不会打爆数据库。
    private func startTicker() {
        timer?.invalidate()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.tick(force: false)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - 主循环

    func tick(force: Bool) {
        if busy && !force { return }
        busy = true
        reloadConfig()

        let now = Date()
        let anchor = AnchorStore.shared.anchor
        let cfg = config

        StepReader.shared.steps(from: anchor, to: now) { [weak self] steps in
            guard let self = self else { return }
            self.apply(steps: steps, anchor: anchor, now: now, cfg: cfg)
            self.reconcileNotifications(steps: steps, anchor: anchor, now: Date(), cfg: cfg)
            self.busy = false
        }
    }

    // MARK: - 应用判定

    private func apply(steps: Int?, anchor: Date, now: Date, cfg: Config) {
        lastCheckAt = now
        lastError = ""

        guard let steps = steps else {
            lastDecision = stepCountingAvailable ? .unknown : .unknown
            lastError = stepCountingAvailable ? "读不到步数（运动权限？）" : "这台设备不支持计步"
            // 读不到时也要把通知排上，否则会完全静默失效
            return
        }

        stepsInWindow = steps
        let decision = RuleEngine.decide(anchor: anchor, steps: steps, now: now, config: cfg)
        lastDecision = decision

        switch decision {
        case .satisfied:
            let wasNudging = AnchorStore.shared.isNudging
            AnchorStore.shared.reset(to: now)
            StepReader.shared.invalidateCache()
            if wasNudging || cfg.confirmHapticOnReset {
                WKInterfaceDevice.current().play(.success)
            }
            nudgesToday = AnchorStore.shared.nudgesToday

        case .nudge:
            if AnchorStore.shared.nudgingSince == nil {
                AnchorStore.shared.nudgingSince = now
            }
            // 震动频率独立控制：不能每次 tick 都震，否则会变成每分钟震
            let last = AnchorStore.shared.lastNudgeAt
            let canNudge = last == nil || now.timeIntervalSince(last!) >= cfg.tick
            if canNudge {
                fireNudgeHaptic()
                AnchorStore.shared.lastNudgeAt = now
                AnchorStore.shared.nudgesToday += 1
            }
            AnchorStore.shared.noteIdle(now.timeIntervalSince(anchor))
            nudgesToday = AnchorStore.shared.nudgesToday
            longestIdle = AnchorStore.shared.longestIdle

        case .waiting, .inactive, .unknown:
            break
        }
    }

    /// 催命震动。第 1 次提醒，之后升级力度。
    private func fireNudgeHaptic() {
        let count = AnchorStore.shared.nudgesToday
        let device = WKInterfaceDevice.current()
        if count == 0 {
            device.play(.notification)
        } else if count < 3 {
            device.play(.retry)
        } else {
            device.play(.failure)
            device.play(.notification)
        }
    }

    // MARK: - 通知对账（关键）

    /// 任何时刻：系统里最多一条待发通知，且它的时刻必须由当前锚点现算得出。
    private func reconcileNotifications(steps: Int?, anchor: Date, now: Date, cfg: Config) {
        guard cfg.isActive(at: now) else {
            NotificationPlanner.shared.replace(fireAt: nil, now: now, body: "")
            pendingNotifications = 0
            return
        }

        // 已走够 → 一条都不该留
        if let s = steps, s >= cfg.targetSteps {
            NotificationPlanner.shared.replace(fireAt: nil, now: now, body: "")
            pendingNotifications = 0
            return
        }

        let deadline = RuleEngine.deadline(anchor: anchor, config: cfg)
        let nextCheck = now.addingTimeInterval(cfg.tick)

        let fire: Date
        if now >= deadline {
            // 已在催命期：下一次检查点就要有动静
            fire = nextCheck
        } else {
            // 窗口未满：排在窗口到期那一刻
            fire = deadline
        }

        NotificationPlanner.shared.replace(
            fireAt: fire,
            now: now,
            body: bodyText(for: now, deadline: deadline, cfg: cfg)
        )

        NotificationPlanner.shared.pendingCount { [weak self] n in
            self?.pendingNotifications = n
        }

        // 会话开关：只在生效时段内占电，时段外一律释放。
        ExtendedSessionManager.shared.setDesired(cfg.enabled && cfg.isActive(at: now))
    }

    /// 通知正文。刻意不写死分钟数 —— 预排的通知撤不回来，
    /// 写死"已静坐 35 分钟"就会出现走了很多步还在被告知静坐的尴尬。
    private func bodyText(for now: Date, deadline: Date, cfg: Config) -> String {
        if now >= deadline {
            return "还没到 \(cfg.targetSteps) 步。起身走一走，\(cfg.tickMinutes) 分钟后再提醒你一次。"
        }
        return "\(cfg.windowMinutes) 分钟了，起来走到 \(cfg.targetSteps) 步就归零。"
    }

    // MARK: - 对外操作

    func reloadConfig() {
        let latest = Config.load()
        if latest != config {
            config = latest
            StepReader.shared.invalidateCache()
        }
    }

    func update(_ mutate: (inout Config) -> Void) {
        var c = config
        mutate(&c)
        c.save()
        config = c
        StepReader.shared.invalidateCache()
        tick(force: true)
    }

    /// 按 keyPath 改一个 Int 字段（设置页用，避免闭包里嵌套闭包写错）
    func set(_ keyPath: WritableKeyPath<Config, Int>, _ value: Int) {
        update { c in c[keyPath: keyPath] = value }
    }

    func setBool(_ keyPath: WritableKeyPath<Config, Bool>, _ value: Bool) {
        update { c in c[keyPath: keyPath] = value }
    }

    /// 手动归零（比如"我刚走了但没带表"）
    func resetNow() {
        AnchorStore.shared.reset(to: Date())
        StepReader.shared.invalidateCache()
        tick(force: true)
    }

    // MARK: - 派生值（UI 用）

    var anchorDate: Date { AnchorStore.shared.anchor }

    var deadlineDate: Date { RuleEngine.deadline(anchor: anchorDate, config: config) }

    var isNudging: Bool { AnchorStore.shared.isNudging }

    func secondsRemaining(at date: Date) -> TimeInterval {
        RuleEngine.secondsUntilDeadline(anchor: anchorDate, now: date, config: config)
    }

    /// 三档状态：正常 / 快到了 / 该动了。故意不给"活秒数"，
    /// 避免表盘上出现一个越走越离谱的数字。
    enum Level { case ok, soon, overdue, off }

    func level(at date: Date) -> Level {
        guard config.isActive(at: date) else { return .off }
        let remain = secondsRemaining(at: date)
        if remain <= 0 { return .overdue }
        if remain <= 5 * 60 { return .soon }
        return .ok
    }

    func levelText(at date: Date) -> String {
        switch level(at: date) {
        case .ok: return "正常"
        case .soon: return "快到了"
        case .overdue: return "该动了"
        case .off: return "已关闭"
        }
    }

    // MARK: - 自检（验收标准第 4、5 条就靠它）

    /// 逐条核对不变量，把结论打在界面上。装上去第一件事就是跑它。
    func runSelfCheck() {
        var log: [String] = []
        let now = Date()
        let anchor = AnchorStore.shared.anchor
        let idle = now.timeIntervalSince(anchor)

        // 1. 锚点合理性：不该在未来，也不该比"窗口 + 1 小时"还久（除非整天没开）
        if anchor > now.addingTimeInterval(60) {
            log.append("✗ 锚点在未来（时钟跳变？）")
        } else if idle > config.window + 3600 {
            log.append("⚠ 锚点已 \(Int(idle / 60)) 分钟未更新（长时间没走够？）")
        } else {
            log.append("✓ 锚点正常，已静坐 \(Int(idle / 60)) 分钟")
        }

        // 2. 待发通知只能是 0 或 1 条
        NotificationPlanner.shared.pendingCount { [weak self] n in
            guard let self = self else { return }
            var lines = log
            if n <= 1 {
                lines.append("✓ 待发通知 \(n) 条")
            } else {
                lines.append("✗ 待发通知 \(n) 条（应 ≤ 1，对账失效）")
            }

            // 3. 通知授权
            NotificationPlanner.shared.authorizationStatus { s in
                lines.append(s == "已允许" ? "✓ 通知权限已允许" : "✗ 通知权限：\(s)（会没声音）")

                // 4. 计步
                lines.append(self.stepCountingAvailable ? "✓ 计步可用" : "✗ 设备不支持计步")

                // 5. 当前判定
                lines.append("· 当前判定：\(self.describe(self.lastDecision))，窗口内 \(self.stepsInWindow) 步")
                lines.append("· 生效时段：\(self.config.startHour):00–\(self.config.endHour):00")

                self.selfCheckLog = lines
            }
        }
    }

    private func describe(_ d: Decision) -> String {
        switch d {
        case .inactive: return "不在时段"
        case .satisfied: return "已走够"
        case .waiting: return "计时中"
        case .nudge: return "该催"
        case .unknown: return "读不到步数"
        }
    }
}
