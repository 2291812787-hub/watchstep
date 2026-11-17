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
    /// 后台计时器（GCD）。见 `startTicker`：不能靠前台 Timer。
    private var backgroundTicker: DispatchSourceTimer?
    private var busy = false
    /// `busy` 是哪一刻置上的。用于卡死保护，见 `tick`。
    private var busySince: Date?

    /// 界面是否正亮着、正被看着。由 AppDelegate 的生命周期回调维护。
    ///
    /// 不直接问 `WKApplication.applicationState`：带着常驻运行时会话时，
    /// 熄屏后那个值仍可能是 `.active`（会话本来就允许后台跑），拿它判断
    /// "要不要多排几条"会永远排 1 条，等于把后台那条链彻底关掉。
    /// 显式标志没有歧义：离开前台就是离开前台。
    var isForeground: Bool = true
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

    /// 后台计时器：每 20 秒看一眼。
    ///
    /// **不能用 `Timer` + `RunLoop.main`。** 那是前台定时器：屏幕一黑、App 退到
    /// 后台，系统就把进程挂起，RunLoop 不再转，Timer 一声不响地停掉 ——
    /// 后台不查步数、不震、也不对账，用户抬腕看表盘更是完全碰不到它。
    /// 等点开 App 时 `applicationDidBecomeActive` 才发现早就该催，于是把欠的
    /// 提醒一次性补发出来。用户看到的"死后台 + 点进去一堆"就是这么来的。
    ///
    /// GCD 的 `DispatchSourceTimer` 挂在独立队列上，不依赖 RunLoop 的事件源。
    /// 只要进程还活着（self-care 会话保的正是这个），它就照常滴答。
    private func startTicker() {
        timer?.invalidate()
        backgroundTicker?.cancel()

        let q = DispatchQueue(label: "watchstep.ticker", qos: .utility)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(3))
        t.setEventHandler { [weak self] in
            self?.tick(force: false)
        }
        t.resume()
        backgroundTicker = t

        // 前台时再快一点，让界面数字跟得上；后台仍然靠上面那个 GCD 计时器。
        let ui = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshUIOnly()
        }
        RunLoop.main.add(ui, forMode: .common)
        timer = ui
    }

    /// 只让界面重算显示，不查步数 —— 挪动数字的活儿交给后台计时器。
    private func refreshUIOnly() {
        guard isForeground else { return }
        objectWillChange.send()
    }

    // MARK: - 主循环

    func tick(force: Bool) {
        // 卡死保护：正常查询 1 秒内就回来。超过 10 秒一定是回调丢了 ——
        // 在挂起边缘发起查询、process 被冻住，completion 就永远不会来。
        // 不解除的话 `busy` 永远为真，下面那句会让**之后每一次 tick 都被丢弃**，
        // App 表现成"只有点进来才动一下"，然后一路静默到天荒地老。
        if busy, let since = busySince, Date().timeIntervalSince(since) > 10 {
            busy = false
            busySince = nil
        }
        if busy {
            // 已经在查了。force 的那次不能悄悄丢掉 —— 用户点进来这一刻的答案必须
            // 是准的，所以记一笔，等这一轮回来再补跑一次（串行，不并发）。
            // 以前 force 会直接并行进来，两次查询的回调互相覆盖 stepsInWindow，
            // 于是同一秒里先得 195 再得 200 —— 这也是"两条通知先后到"的帮凶。
            if force { pendingForce = true }
            return
        }
        busy = true
        busySince = Date()
        reloadConfig()

        let now = Date()
        let cfg = config
        let anchor = saneAnchor(now: now, cfg: cfg)

        // force 的语义就是「现在到底怎样」：用户点进来、回到前台、后台任务醒来、
        // 常驻会话启动。这种时刻绝不能拿缓存回答 —— 刚走够 200 步点进来却读到
        // 走够前的旧账，就会先发一条"起来走动"、再发一条"已满 200 步"。
        if force { StepReader.shared.invalidateCache() }

        // 查哪一段？**只查最近一个窗口，不能从锚点一路累加。**
        //
        // 以前查的是 [anchor, now]。锚点在下一次走够之前不会动，所以只要用户
        // 一直没在 30 分钟内走够 200 步，这个区间就会无限变长：坐一下午累计
        // 三五百步是常事，于是**打开的一瞬间必然 ≥ 200 → 判「走够」→ 归零**，
        // 用户看到的就是"一打开刚好 30 分钟满格"。而那些步数是几小时里零散
        // 走出来的，根本不是"30 分钟内走了 200 步"。
        //
        // 起点取 max(锚点, now - 窗口)，见 RuleEngine.stepQueryStart。
        let windowStart = RuleEngine.stepQueryStart(anchor: anchor, now: now, config: cfg)
        StepReader.shared.steps(from: windowStart, to: now) { [weak self] steps in
            guard let self = self else { return }
            // 判定、震动、排通知都搬到主线程执行：tick 现在由后台队列的 GCD
            // 计时器发起，而 `apply` 要更新 @Published（SwiftUI 只在主线程安全）。
            // 注意这和 Timer 不是一回事：main queue 的块由 libdispatch 直接唤醒
            // 主线程，后台照样会执行；停掉的只是 RunLoop 上的 Timer 事件源。
            let run = {
                self.apply(steps: steps, anchor: anchor, now: now, cfg: cfg)
                self.reconcileNotifications(steps: steps, anchor: anchor, now: Date(), cfg: cfg)
                self.busy = false
                self.busySince = nil
                if self.pendingForce {
                    self.pendingForce = false
                    self.tick(force: true)
                }
            }
            if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
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

        // 触觉一旦成立就不用管前台后台：会话活着时进程没被挂起，
        // `play()` 在后台同样震得动。真正让"熄屏就死"的不是 play 失效，
        // 而是外面那个前台 Timer 停摆 —— 已换成后台队列的 GCD 计时器。
        for (i, h) in seq.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 * Double(i)) {
                WKInterfaceDevice.current().play(h)
            }
        }

        // 通知只发一条，id 与兜底那条一致，内容由 NudgeText 统一生成。
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

    /// 任何时刻，系统里的待发通知都必须由当前锚点现算得出。
    ///
    /// 条数分两档，这是「后台静默」的正解：
    ///   · 人在前台（常驻会话跑着、每 30 秒一次 tick）→ 只排 1 条，
    ///     因为走够的那一刻我们会自己撤、自己震，排多了是噪音。
    ///   · 其余所有情况（熄屏、挂起、会话死了）→ 一次排 6 条，
    ///     覆盖 30 分钟。挂起期间没有任何代码在跑，这是唯一能按时震响的手段。
    ///
    /// 会话若还活着，它 tick 到走够会 `fireNow()` 并撤掉这条预排，
    /// 所以兜底通知不会和实时震动叠加。
    private func reconcileNotifications(steps: Int?, anchor: Date, now: Date, cfg: Config) {
        // 会话开关必须先算：下面每一条都是 early return，
        // 放在函数末尾就会被跳过 —— 一插上充电器那次 tick 正好命中第一个 guard，
        // 会话没释放，人却在充电，白耗电。
        ExtendedSessionManager.shared.setDesired(
            cfg.enabled && cfg.isActive(at: now) && quiet == nil
        )

        // 该彻底安静了：暂停（充电/摘下）、时段外、已走够。
        //
        // 但「电量低」绝不能撤。低电量是「该省电」的理由，不是「别提醒我」的理由；
        // 阈值 20% 是一天里很容易碰到的普通状态，一撤就等于整条提醒链静默，
        // 用户只会得到「它没响」——然后以为 App 坏了。这正是「通知被压」的元凶之一。
        // 所以低电量只停常驻会话（省电的地方），预排通知留着。
        let q = RuleEngine.quietReason(now: now, config: cfg, surroundings: surroundings)
        if let q = q, q != .lowBattery {
            clearScheduled(now: now)
            return
        }
        guard cfg.isActive(at: now) else {
            clearScheduled(now: now)
            return
        }
        if let s = steps, s >= cfg.targetSteps {
            clearScheduled(now: now)
            return
        }

        let deadline = RuleEngine.deadline(anchor: anchor, config: cfg)
        let interval = TimeInterval(max(1, cfg.tickMinutes)) * 60

        // 第一条排在哪儿？
        //  · 窗口还没满 → 排在窗口到期那一刻（正文承诺的那个点）；
        //  · 已在催命期 → 排在"上次催命 + 一个间隔"，也就是上一句说的是什么时候。
        //    已经有更早的待发通知就沿用它，别每 30 秒往后推。
        let first: Date
        if now >= deadline {
            if let p = NotificationPlanner.shared.nextFireAt, p > now {
                first = p
            } else {
                let base = AnchorStore.shared.lastNudgeAt ?? now
                // 已经错过了就 5 秒后补一条（比如刚从挂起/重启里醒来）
                first = max(base.addingTimeInterval(interval), now.addingTimeInterval(5))
            }
        } else {
            first = deadline
        }

        // **只排 1 条，绝不排一串。**
        //
        // 排 12 条试过，结果更糟：watchOS 把同一 threadIdentifier 的通知归成
        // 一组压着不发，等抬腕/打开 App 时一次性全放出来 —— 正是最让人恼火的
        // "点进去一堆通知"。密集提醒不能靠预排，只能靠 App 活着自己震。
        //
        // 所以分工是死的：
        //   · 准点震手腕 = 常驻会话活着时每 20 秒 tick（后台队列），
        //     到点走会话的 notifyUser（后台也震得动）
        //   · 这一条预排 = 会话万一死了的兜底，且只兜下一次，不兜一整天
        let slots = 1

        // 坐着的分钟数按通知**真正弹出的时刻**现算，不按现在算 ——
        // 排程可能提前好几分钟，用 now 算会少报。
        NotificationPlanner.shared.replace(
            firstFire: first,
            interval: interval,
            slots: slots,
            now: now,
            body: NudgeText.reminder(
                targetSteps: cfg.targetSteps,
                steps: steps,
                sittingMinutes: Int(first.timeIntervalSince(anchor) / 60),
                tickMinutes: cfg.tickMinutes,
                approximate: true          // 步数是排程时的快照，弹出时可能又走了几步
            )
        )

        NotificationPlanner.shared.pendingCount { [weak self] n in
            self?.pendingNotifications = n
        }
    }

    /// 撤掉所有待发通知，并把界面上的条数清零。
    private func clearScheduled(now: Date) {
        NotificationPlanner.shared.replace(
            firstFire: nil, interval: 0, slots: 1, now: now, body: ""
        )
        pendingNotifications = 0
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

        // 0. 构建标识放在最前面：装上之后第一眼就能确认跑的是哪个包。
        //    以前三个包的 CFBundleVersion 全是 1.0(1)，装了旧包也看不出来。
        log.append("构建 \(BuildInfo.stamp)")

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
            if n == 0 {
                lines.append("✓ 无待发通知")
            } else if n == 1 {
                lines.append("✓ 待发通知 1 条")
            } else {
                lines.append("✓ 已排 \(n) 条预排（挂起时的催命链，正常）")
            }

            // 3. 通知授权
            NotificationPlanner.shared.authorizationStatus { s in
                lines.append(s == "已允许" ? "✓ 通知权限已允许" : "✗ 通知权限：\(s)（会没声音）")

                // 4. 计步 + 最近一个窗口的步数
                lines.append(self.stepCountingAvailable ? "✓ 计步可用" : "✗ 设备不支持计步")
                lines.append("· 最近 \(self.config.windowMinutes) 分钟 \(self.stepsInWindow) 步"
                             + "（目标 \(self.config.targetSteps)）")

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
                    if d >= 0 {
                        lines.append("· 待发通知 " + String(d) + " 秒后")
                    } else {
                        lines.append("· 待发通知已过期 " + String(-d) + " 秒")
                    }
                } else {
                    lines.append("· 无待发通知")
                }

                self.selfCheckLog = lines
            }
        }
    }

}
