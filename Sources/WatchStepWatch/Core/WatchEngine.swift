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

    /// 此刻为什么没在催（充电/摘下/低电/时段外）。nil = 一切正常。
    @Published private(set) var quiet: QuietReason?
    /// 最近一次读到的环境，界面直接显示。
    @Published private(set) var surroundings: Surroundings = .unknown

    /// 自检结果（验收用）
    @Published private(set) var selfCheckLog: [String] = []

    private var timer: Timer?
    private var busy = false
    private var pendingForce = false
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
        if busy {
            // 已经在查了。force 的那次不能悄悄丢掉 —— 用户点进来这一刻的答案必须
            // 是准的，所以记一笔，等这一轮回来再补跑一次（串行，不并发）。
            // 以前 force 会直接并行进来，两次查询的回调互相覆盖 stepsInWindow，
            // 于是同一秒里先得 195 再得 200 —— 这也是"两条通知先后到"的帮凶。
            if force { pendingForce = true }
            return
        }
        busy = true
        reloadConfig()

        let now = Date()
        let cfg = config
        let anchor = saneAnchor(now: now, cfg: cfg)

        // force 的语义就是「现在到底怎样」：用户点进来、回到前台、后台任务醒来、
        // 常驻会话启动。这种时刻绝不能拿缓存回答 —— 刚走够 200 步点进来却读到
        // 走够前的旧账，就会先发一条"起来走动"、再发一条"已满 200 步"。
        if force { StepReader.shared.invalidateCache() }

        StepReader.shared.steps(from: anchor, to: now) { [weak self] steps in
            guard let self = self else { return }
            self.apply(steps: steps, anchor: anchor, now: now, cfg: cfg)
            self.reconcileNotifications(steps: steps, anchor: anchor, now: Date(), cfg: cfg)
            self.busy = false
            if self.pendingForce {
                self.pendingForce = false
                self.tick(force: true)
            }
        }
    }

    // MARK: - 应用判定

    /// 锚点校准。锚点是「上次走够 200 步的时刻」，但它会被三件事搞坏，
    /// 不修就会变成「一戴上手表就立刻挨骂」。
    private func saneAnchor(now: Date, cfg: Config) -> Date {
        let stored = AnchorStore.shared.anchor

        // 1) 锚点落在将来：调过系统时间或换了时区。照用的话永远不催。
        if stored > now {
            AnchorStore.shared.reset(to: now)
            return now
        }

        // 2) 断了六个小时以上：只可能是关机或彻底没电。
        //    注意不能用「一小时没被唤醒」当依据 —— CMPedometer 是系统级记账，
        //    App 睡着的时候步数照样在记，那时候重置反而把真实进度抹掉。
        if let last = AnchorStore.shared.lastTickAt,
           now.timeIntervalSince(last) > 6 * 3600 {
            AnchorStore.shared.reset(to: now)
            return now
        }

        // 3) 刚跨进生效时段：昨天夜里攒的空档不该在早上 8:00 立刻兑现。
        //    把锚点抬到时段起点，于是 8:00 一开门就有完整的一个窗口。
        if let start = RuleEngine.windowStart(now: now, config: cfg), stored < start {
            AnchorStore.shared.anchor = start
            return start
        }

        return stored
    }

    private func apply(steps: Int?, anchor: Date, now: Date, cfg: Config) {
        lastCheckAt = now
        lastError = ""

        // 每轮都读一次真实环境：电量、是否插电、是否已摘下。
        // 这些是「此刻该不该吵」的唯一依据，界面也拿它显示。
        let env = SurroundingsReader.read()
        surroundings = env
        AnchorStore.shared.lastTickAt = now

        // 一次算清「此刻该不该吵」，后面所有分支共用，界面也读它。
        // 必须放在步数 guard **之前**：读不到步数时界面照样要显示
        // 「充电中，暂停」，留一个上一轮的旧值会显示成「正常」——那是骗人。
        quiet = RuleEngine.quietReason(now: now, config: cfg, surroundings: env)

        guard let steps = steps else {
            lastDecision = .unknown
            lastError = stepCountingAvailable ? "读不到步数（运动权限？）" : "这台设备不支持计步"
            // 读不到也要继续走通知对账（外面会调），否则会完全静默失效
            return
        }

        stepsInWindow = steps
        let decision = RuleEngine.decide(anchor: anchor, steps: steps, now: now, config: cfg)
        lastDecision = decision

        switch decision {
        case .satisfied:
            let wasNudging = AnchorStore.shared.isNudging

            // 挂起期间那条预排的"起来走动"可能已经被系统弹出来了（它的步数是
            // 排程时的快照，现在可能是错的）。先认账、再从通知中心撤掉，
            // 然后只发一条正确的 —— 用户不会看到"先催命、后说走够"这种自打嘴巴。
            let delivered = NotificationPlanner.shared.consumeDelivered(now: now)
            if let d = delivered {
                AnchorStore.shared.lastNudgeAt = d
                AnchorStore.shared.nudgesToday += 1
            }
            NotificationPlanner.shared.cancelAll()

            AnchorStore.shared.reset(to: now)
            StepReader.shared.invalidateCache()
            if wasNudging || delivered != nil || cfg.confirmHapticOnReset {
                WKInterfaceDevice.current().play(.success)
            }
            // 「达成」也要有可见的反馈。否则用户只感到一震、屏幕上什么都没有，
            // 分不清是走够了还是又催一次。
            // 条件不能只看 wasNudging：App 挂起时是那条预排通知替我们催的，
            // 此时 nudgingSince 仍是 nil，但用户确实已经被催过了 —— 漏掉他更困惑。
            if wasNudging || delivered != nil {
                NotificationPlanner.shared.fireNow(
                    body: "已满 \(cfg.targetSteps) 步，重新开始计时",
                    title: "走够了",
                    now: now
                )
            }
            nudgesToday = AnchorStore.shared.nudgesToday

        case .nudge:
            // 环境不对就别吵：充电、摘下。暂停不能让锚点永远停在很久以前 ——
            // 一充满电、一戴回手腕就立刻催，那才是最烦的。所以暂停期间锚点跟着走，
            // 恢复后重新给一个完整窗口。
            //
            // 低电量不在此列：它只让常驻会话别起（省电），提醒本身照旧。
            // 电量 20% 就静默，等于一天里有一大段时间 App 假装自己不存在。
            if let q = quiet, q != .lowBattery {
                AnchorStore.shared.nudgingSince = nil
                AnchorStore.shared.lastNudgeAt = nil
                NotificationPlanner.shared.cancelAll()
                if now.timeIntervalSince(anchor) >= cfg.window {
                    AnchorStore.shared.anchor = now
                }
                nudgesToday = AnchorStore.shared.nudgesToday
                break
            }

            if AnchorStore.shared.nudgingSince == nil {
                AnchorStore.shared.nudgingSince = now
            }
            // 震动频率独立控制：不能每次 tick 都震，否则会变成每分钟震
            let last = AnchorStore.shared.lastNudgeAt
            let canNudge = last == nil || now.timeIntervalSince(last!) >= cfg.tick

            // 挂起期间那条预排的兜底通知可能已经自己弹出来了 —— 那一条就是这次催命。
            // 不认账的话，现在醒来就会再补一条，用户手腕上就是两条几乎一样的通知。
            let delivered = NotificationPlanner.shared.consumeDelivered(now: now)
            if let d = delivered, last == nil || d > last! {
                AnchorStore.shared.lastNudgeAt = d
                AnchorStore.shared.nudgesToday += 1
            } else if canNudge {
                fireNudge(steps: steps, anchor: anchor, now: now, cfg: cfg)
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

    /// 催命：震动 + 一条立即投递的通知。
    /// 只有震动的话，抬腕什么也看不到，用户根本不知道刚才震的是谁。
    private func fireNudge(steps: Int, anchor: Date, now: Date, cfg: Config) {
        let count = AnchorStore.shared.nudgesToday
        // 每次给一串触感，间隔 0.7 秒。连着调用会被系统合并成一下，
        // 必须错开时间，才不会被误认为错觉或系统提示。
        let seq: [WKHapticType] = count < 3
            ? [.notification, .retry]
            : [.failure, .retry, .notification]
        for (i, h) in seq.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 * Double(i)) {
                WKInterfaceDevice.current().play(h)
            }
        }

        // 只发一条：id 与兜底通知相同，正文由 NudgeText 统一生成。
        // 以前这里另用"ws.now.<时间戳>"的 id，于是"该走了"和预排的"该走走了"
        // 会几乎同时冒出来两条，还各说一半 —— 现在物理上不可能了。
        NotificationPlanner.shared.fireNow(
            body: NudgeText.reminder(
                targetSteps: cfg.targetSteps,
                steps: steps,
                sittingMinutes: Int(now.timeIntervalSince(anchor) / 60),
                tickMinutes: cfg.tickMinutes
            ),
            now: now
        )
    }

    // MARK: - 通知对账（关键）

    /// 任何时刻：系统里最多一条待发通知，且它的时刻必须由当前锚点现算得出。
    private func reconcileNotifications(steps: Int?, anchor: Date, now: Date, cfg: Config) {
        // 会话开关必须先算：下面每一条都是 early return，
        // 放在函数末尾就会被跳过 —— 一插上充电器那次 tick 正好命中第一个 guard，
        // 会话没释放，人却在充电，白耗电。
        ExtendedSessionManager.shared.setDesired(
            cfg.enabled && cfg.isActive(at: now) && quiet == nil
        )

        // 充电 / 摘下时预排通知必须撤掉 —— 人不在状态上，弹了就是骚扰。
        //
        // 但「电量低」绝不能撤。低电量是「该省电」的理由，不是「别提醒我」的理由；
        // 阈值 20% 是一天里很容易碰到的普通状态，一撤就等于整条提醒链静默，
        // 用户只会得到「它没响」——然后以为 App 坏了。这正是「通知被压」的元凶之一。
        // 所以低电量只停常驻会话（省电的地方），兜底的那条通知留着。
        let q = RuleEngine.quietReason(now: now, config: cfg, surroundings: surroundings)
        if let q = q, q != .lowBattery {
            NotificationPlanner.shared.replace(fireAt: nil, now: now, body: "")
            pendingNotifications = 0
            return
        }

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

        // 已在催命期：排在"上次催命 + 一个间隔"—— 也就是正文里承诺的那一刻。
        // 以前排的是 2 个间隔，比嘴上说的晚一倍，用户会觉得"说好一分钟，结果没来"。
        // 已经有更早的待发通知就沿用，避免每 30 秒的 tick 把它往后推。
        let fire: Date
        if now >= deadline {
            if let p = NotificationPlanner.shared.nextFireAt, p > now {
                fire = p
            } else {
                let base = AnchorStore.shared.lastNudgeAt ?? now
                let due = base.addingTimeInterval(cfg.tick)
                // 已经错过了就 5 秒后补一条（比如刚从挂起/重启里醒来）
                fire = max(due, now.addingTimeInterval(5))
            }
        } else {
            // 窗口未满：排在窗口到期那一刻
            fire = deadline
        }

        // 坐着的分钟数按通知**真正弹出的时刻**（fire）现算，不按现在算 ——
        // 排程可能提前好几分钟，用 now 算会少报。
        NotificationPlanner.shared.replace(
            fireAt: fire,
            now: now,
            body: NudgeText.reminder(
                targetSteps: cfg.targetSteps,
                steps: steps,
                sittingMinutes: Int(fire.timeIntervalSince(anchor) / 60),
                tickMinutes: cfg.tickMinutes,
                approximate: true          // 步数是排程时的快照，弹出时可能又走了几步
            )
        )

        NotificationPlanner.shared.pendingCount { [weak self] n in
            self?.pendingNotifications = n
        }
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
        let wasEnabled = config.enabled
        var c = config
        mutate(&c)
        c.save()
        config = c

        // 关掉时把系统里已经排好的那条一并撤掉，否则关完还会弹一次。
        if wasEnabled && !c.enabled {
            NotificationPlanner.shared.cancelAll()
        }
        // 重新打开不该当场就震：锚点可能停在几小时前，一开就是「已经坐了 4 小时」。
        // 给一个完整的新窗口。
        if !wasEnabled && c.enabled {
            AnchorStore.shared.reset(to: Date())
        }

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
        // 暂停中（充电/摘下）不要显示成「该动了」—— 那时我们本来就不催。
        // 但低电量不算暂停：它只是不开常驻会话省电，通知照弹，
        // 界面要是也写成「暂停」，用户看到的就是一个自相矛盾的 App。
        if let q = quiet, q != .outsideWindow, q != .lowBattery { return .ok }
        let remain = secondsRemaining(at: date)
        if remain <= 0 { return .overdue }
        if remain <= 5 * 60 { return .soon }
        return .ok
    }

    func levelText(at date: Date) -> String {
        if let q = quiet, q != .lowBattery {
            switch q {
            case .disabled:      return "已关闭"
            case .outsideWindow: return "不在时段"
            default:             return q.label
            }
        }
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

                // 5. 环境（电量/充电/摘下）与暂停原因
                let env = self.surroundings
                let b = env.batteryPercent >= 0 ? "\(env.batteryPercent)%" : "读不到"
                var flags: [String] = []
                if env.charging { flags.append("充电中") }
                if env.offWrist { flags.append("已摘下") }
                if env.lowPowerMode { flags.append("低电量模式") }
                let fs = flags.isEmpty ? "" : "（\(flags.joined(separator: "、"))）"
                lines.append("· 电量 \(b)\(fs)")
                if let q = self.quiet {
                    lines.append("· 判定：暂停（\(q.label)），不会震动")
                } else {
                    lines.append("· 判定：会按点催")
                }
                lines.append("· 生效时段：\(self.config.startHour):00–\(self.config.endHour):00")

                // 6. 后台能不能真的跑起来 —— 这决定「走够就立刻确认」成不成立。
                // 挂起时手表不给步数变化的回调，只能靠常驻会话自己醒着去查；
                // 会话一断，就只能等用户点进来才知道已经走够。
                let ext = ExtendedSessionManager.shared
                if ext.isRunning {
                    lines.append("✓ 常驻会话在跑（第 \(ext.segmentsStarted) 段）")
                } else {
                    let why = ext.lastEndReason.isEmpty ? "没启动" : ext.lastEndReason
                    lines.append("✗ 常驻会话没在跑：\(why)")
                }
                if let last = self.lastCheckAt {
                    let age = Int(now.timeIntervalSince(last))
                    lines.append(age < 120 ? "· 上次检查 \(age) 秒前"
                                           : "⚠ 上次检查 \(age / 60) 分钟前（后台被挂起了）")
                }
                if let p = NotificationPlanner.shared.nextFireAt {
                    let d = Int(p.timeIntervalSince(now))
                    lines.append(d >= 0 ? "· 待发通知 \(d) 秒后" : "· 待发通知已过期 \((-d) 秒)")
                } else {
                    lines.append("· 无待发通知")
                }

                self.selfCheckLog = lines
            }
        }
    }

}
