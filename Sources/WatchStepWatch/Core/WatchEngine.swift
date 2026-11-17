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
    /// 这一轮查询是什么时候发起的。用来解除卡死，见 tick()。
    private var busySince: Date?
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
        // 进前台就把通知中心里已经弹过的清掉：该响的时候都响过了、也震过了，
        // 堆着只会变成「一打开一堆消息」。（待发的整条链绝不动 —— 那是后台继续催的命根。）
        NotificationPlanner.shared.clearDeliveredNotificationCenter()
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

    /// 现在是不是在后台。仅用于留痕，不参与任何判定 —— 判定答错一次就会
    /// 静默一整天，所以宁可判定只看时间，视角只用来记账。
    private func isBackgroundNow() -> Bool {
        return WKExtension.shared().applicationState != .active
    }

    // MARK: - 主循环

    func tick(force: Bool) {
        if busy {
            // 卡死保护：CMPedometer 的回调有可能永远不来 —— 在「App 正要被系统
            // 冻结」的那一瞬间发起查询就是这样：进程冻住，回调排不上，解冻后
            // 也可能已经丢了。不解除的话 busy 永真，之后每一次 tick 都被这里
            // 直接丢弃：界面不动、通知也不再重排，用户「点开才发现弹窗根本没弹」。
            if let since = busySince, Date().timeIntervalSince(since) > 10 {
                busy = false
                busySince = nil
                pendingForce = false
            } else {
                // 已经在查了。force 的那次不能悄悄丢掉 —— 用户点进来这一刻的答案必须
                // 是准的，所以记一笔，等这一轮回来再补跑一次（串行，不并发）。
                // 以前 force 会直接并行进来，两次查询的回调互相覆盖 stepsInWindow，
                // 于是同一秒里先得 195 再得 200 —— 这也是"两条通知先后到"的帮凶。
                if force { pendingForce = true }
                return
            }
        }
        busy = true
        busySince = Date()
        reloadConfig()

        let now = Date()
        // 留痕：后台到底有没有在跑。这是唯一能证伪"死在后台"的依据，
        // 自检页会把这两个数摆出来。
        AnchorStore.shared.lastTickAt = now
        AnchorStore.shared.tickCount += 1
        if isBackgroundNow() {
            AnchorStore.shared.lastBgTickAt = now
            AnchorStore.shared.bgTickCount += 1
        }
        let cfg = config
        let anchor = saneAnchor(now: now, cfg: cfg)

        // force 的语义就是「现在到底怎样」：用户点进来、回到前台、后台任务醒来、
        // 常驻会话启动。这种时刻绝不能拿缓存回答 —— 刚走够 200 步点进来却读到
        // 走够前的旧账，就会先发一条"起来走动"、再发一条"已满 200 步"。
        if force { StepReader.shared.invalidateCache() }

        // 只看最近一个窗口，不是"从上次归零到现在的累计"。
        //
        // 累计口径是这一整轮的病根：锚点只在走够时推进，所以只要你一直没在
        // 30 分钟内走够 200，这个区间就无限拉长，上午走的两千步全算进来 →
        // 每次一算就是"早就超了" → 归零 → 界面永远是 30:00 重新开始。
        // 你从来不是在 30 分钟内走够的，只是累计越了线。
        let windowStart = RuleEngine.stepQueryStart(anchor: anchor, now: now, config: cfg)
        StepReader.shared.steps(from: windowStart, to: now) { [weak self] steps in
            guard let self = self else { return }
            self.apply(steps: steps, anchor: anchor, now: now, cfg: cfg)
            // 走满时 apply() 会把锚点重置成「现在」——新一轮从零开始计时。
            // 但传进 reconcile 的 steps 还是刚才那个 ≥200 的旧值、anchor 还是旧值，
            // 于是 reconcile 命中「已走够 → 一条都不留」，把新一轮的通知全撤了。
            // 之后要等下一次 tick 才补排；而用户不点进来，下一次 tick 永远不来 ——
            // 这就是「5 分钟走满后，不点进去就不再提醒，卡在那里」的全部原因。
            //
            // 所以这里必须用**重置后**的锚点和归零的步数去重排：走满的同一瞬间
            // 就把下一轮该催的那条排进系统，App 之后死不死都挡不住它响。
            let liveAnchor = AnchorStore.shared.anchor
            let liveSteps = liveAnchor > anchor ? 0 : steps
            self.reconcileNotifications(steps: liveSteps, anchor: liveAnchor, now: Date(), cfg: cfg)
            self.busy = false
            self.busySince = nil
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

        // ---- 先认账：挂起期间链上过点的槽位可能已经真弹过了 ----
        //
        // 必须在步数 guard **之前**。以前认账放在 .nudge / .satisfied 两个分支里，
        // 于是"CMPedometer 这轮没返回"就走不到认账，而 reconcile 照样跑：
        // 它按旧状态重排链，那批"其实已经响过"的时刻又被排了一遍 → 几秒后连响。
        // 读不到步数时唯一必须做的事，就是别把已经响过的再排一遍。
        let preDelivered = NotificationPlanner.shared.consumeDelivered(now: now)
        if let d = preDelivered,
           AnchorStore.shared.lastNudgeAt == nil || d > AnchorStore.shared.lastNudgeAt! {
            AnchorStore.shared.lastNudgeAt = d
            AnchorStore.shared.nudgesToday += 1
            nudgesToday = AnchorStore.shared.nudgesToday
        }

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
            let delivered = preDelivered
            // 不在这里 cancelAll：撤光和重排之间若被系统冻结，系统里一条通知都不剩，
            // 而 App 已死、没人能补。replaceChain 会自己撤掉多余槽位。

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
                // 后台不许撤链：充电状态在挂起边缘可能读到旧值，
                // 一撤空就再没人排回来（和 clearChain 同一个理由）。
                if isBackgroundNow() {
                    AnchorStore.shared.noteChain("≈ 后台想撤(安静:\(q))，拒绝")
                } else {
                    NotificationPlanner.shared.cancelAll()
                }
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

            // 挂起期间预排的那条可能已经自己弹出来了 —— 那一条就是这次催命。
            // 认账在上面统一做过了；这里只要"刚刚已经响过"就别再补一条。
            // 用 dedupeGap 而不是 tick：tick 是"该催的间隔"，dedupeGap 是
            // "两条真提醒之间最少隔多久"，后者才是防重复的那道线。
            let recent = AnchorStore.shared.lastNudgeAt.map {
                now.timeIntervalSince($0) < Self.dedupeGap(cfg)
            } ?? false
            if recent {
                // 这一轮就是那条已经响过的，什么都不做。
            } else if canNudge {
                // 只有真发出去才记一笔。以前被去重闸门拦掉也照样记 lastNudgeAt
                // 和次数，于是计数虚高、触感序列错乱，还会把下一次机会推后。
                if fireNudge(steps: steps, anchor: anchor, now: now, cfg: cfg) {
                    AnchorStore.shared.lastNudgeAt = now
                    AnchorStore.shared.nudgesToday += 1
                }
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
    @discardableResult
    private func fireNudge(steps: Int, anchor: Date, now: Date, cfg: Config) -> Bool {
        // 去重闸门放在震动之前：被抑制时连震都不震，
        // 否则"不弹通知但一直震"同样烦人。
        let gap = Self.dedupeGap(cfg)
        if let last = AnchorStore.shared.lastNudgeAt,
           now.timeIntervalSince(last) < gap {
            AnchorStore.shared.noteChain(
                "≈ 抑制重复催命 \(Int(now.timeIntervalSince(last)))s<" + "\(Int(gap))s")
            return false
        }

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
        return true
    }

    /// 两条真实提醒之间至少隔多久。
    /// 取间隔的一半（1 分钟 → 30 秒，5 分钟 → 60 秒），下限 20 秒。
    /// 上限压到 60 秒：5 分钟间隔时如果闸门放到 2.5 分钟，
    /// App 活着时的实时催命会被压成一条，反而变少。
    static func dedupeGap(_ cfg: Config) -> TimeInterval {
        return max(20, min(cfg.tick / 2, 60))
    }

    // MARK: - 通知对账（关键）

    /// 任何时刻：系统里最多一条待发通知，且它的时刻必须由当前锚点现算得出。
    /// 撤链的唯一出口，带一条审计。
    ///
    /// **后台不撤**：后台判定依赖 CMPedometer 和电量/充电读取，这两个在挂起边缘
    /// 都可能拿到失败或旧值。一旦在这里把链撤空，而 App 随即被系统挂起，
    /// 就再没有任何东西能把它排回来 —— 用户看到的正是「响过一两声就彻底安静」。
    /// 宁可多响，不可哑掉。
    private func clearChain(_ why: String, now: Date) {
        if isBackgroundNow() {
            AnchorStore.shared.noteChain("≈ 后台想撤(\(why))，拒绝，链保持")
            return
        }
        AnchorStore.shared.noteChain("✗ 撤链(\(why))")
        NotificationPlanner.shared.replaceChain([], now: now) { _ in "" }
        pendingNotifications = 0
    }

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
            clearChain("安静:\(q)", now: now)
            return
        }

        guard cfg.isActive(at: now) else {
            clearChain("非活动时段", now: now)
            return
        }

        // 已走够 → 一条都不该留
        if let s = steps, s >= cfg.targetSteps {
            clearChain("已走够\(s)步", now: now)
            return
        }

        let deadline = RuleEngine.deadline(anchor: anchor, config: cfg)

        // ---- 时刻表 = 固定网格，绝不跟着 now 漂移 ----
        //
        // 以前是 `first = max(lastNudge + tick, now + 5)`。只要 lastNudgeAt 是 nil
        // （充过电、刚启动、正好赶上"安静"分支清过它），first 就每次重建都变成
        // 「现在 + 5 秒」—— 每 tick 一次就往后挪 5 秒，于是链的起点永远对不上，
        // 每次都判定"不一样"、整链重建，而每重建一次 slot0 就是个新的 5 秒后
        // → 十几秒后又弹一条。这是"一分钟里隔几秒连发好几条"的全部机制：
        // **漂移 → 重建 → 新排期 → 又漂移**，自己喂自己。
        //
        // 现在改成挂在锚点上的固定网格：deadline + k × tick。网格点不随 now 变，
        // 于是同一个 tick 反复跑，算出来的 want 完全一样，replaceChain 直接跳过。
        // 只有当某个网格点真的过去（跨过一条提醒）时，链才降一位、重排一次 ——
        // 即每分钟最多一次，而不是每十几秒一次。
        let step = max(cfg.tick, 5)
        let gap = Swift.max(10, Swift.min(step / 2, 60))
        let lastNudge = AnchorStore.shared.lastNudgeAt

        var fires: [Date] = []
        var t = deadline
        // 只由 maxSlots 决定链有多长，不再另设"从现在起 24 分钟内"的截断。
        // 那个截断和旧的 maxSlots = 24 配套，改大之后忘了同步，于是设 30 分钟窗口时
        // first（30 分钟后）已经落在截断之外 → fires 为空 → 兜底成「只排 1 条」，
        // 响完系统里就空了，App 不醒就再也不响。用户看到的「只响一两条就没了」就是它。
        while fires.count < NotificationPlanner.maxSlots {
            if !cfg.isActive(at: t) { break }
            // 宽容 1 秒：tick 比 deadline 晚几百毫秒才跑，紧贴 deadline 的那个点
            // 会被判成"已过去"而丢掉 —— 设 5 分钟就变成 6 分钟才响（老毛病）。
            // 留着它、交给下面的 max(1, …) 变成"1 秒后响"才是对的。
            if t.timeIntervalSince(now) >= -2 {
                // 刚催过就别再排紧挨着的那个点，否则等于同一分钟里两条。
                if lastNudge == nil || Swift.abs(t.timeIntervalSince(lastNudge!)) >= gap {
                    fires.append(t)
                }
            }
            t = t.addingTimeInterval(step)
        }
        if fires.isEmpty {
            // 窗口到期那一刻本身就在生效时段之外（比如 23:59 到期、次日 8:00 才开门）。
            // 这种情况一条都不该排，也别去动现有的链 —— 等进了时段自然会重排。
            if !cfg.isActive(at: deadline) {
                AnchorStore.shared.noteChain("窗口落在时段外，链不动")
                return
            }
            fires = [Swift.max(deadline, now.addingTimeInterval(5))]
        }

        // 坐着的分钟数按通知**真正弹出的时刻**现算，不按现在算 ——
        // 排程可能提前好几分钟，用 now 算会少报。
        let changed = NotificationPlanner.shared.replaceChain(fires, now: now) { fire in
            NudgeText.reminder(
                targetSteps: cfg.targetSteps,
                steps: steps,
                sittingMinutes: Int(fire.timeIntervalSince(anchor) / 60),
                tickMinutes: cfg.tickMinutes,
                approximate: true          // 步数是排程时的快照，弹出时可能又走了几步
            )
        }

        pendingNotifications = NotificationPlanner.shared.chainCount
        // 只在链真的变了才写审计。以前每 30 秒 tick 都写一行，日志里全是
        // "排60条"，把"链什么时候变空"这种真信息淹掉了。
        if changed {
            AnchorStore.shared.noteChain(
                "排\(fires.count)条 \(fmt(fires[0]))→\(fmt(fires[fires.count - 1]))")
        }
    }

    private func fmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
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
        let old = config
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

        // 窗口/间隔改过 = 重新定义「一轮」。
        //
        // 不重置锚点的话：把 30 分钟改成 2 分钟那一刻，判定看到的是「已坐 33 分钟」，
        // 立刻进入催命态 —— 用户想要的是「从两分钟开始重新计时」，不是立刻挨骂。
        // 不撤旧排期的话：系统里那条按旧参数排的通知还占着 id，会按上一轮的节奏
        // 一直响到它自己弹完为止。两处一起改，配置才会当场生效。
        let rhythmChanged = c.windowMinutes != old.windowMinutes
            || c.tickMinutes != old.tickMinutes
        if rhythmChanged && c.enabled {
            NotificationPlanner.shared.cancelAll()
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
    /// 自检页那个「测试通知」按钮：15 秒后该响一条，用来验投递通路。
    /// 响不出来 → 是权限/投递问题；响得出来但晚了 → 是排程时刻问题。
    func testNotificationNow() {
        selfCheckLog.insert("· 按了测试通知按钮", at: 0)
        NotificationPlanner.shared.scheduleTest(after: 15) { [weak self] msg in
            guard let self = self else { return }
            self.selfCheckLog.insert(msg, at: 0)
        }
    }

    func runSelfCheck() {
        var log: [String] = []
        let now = Date()
        let anchor = AnchorStore.shared.anchor
        let idle = now.timeIntervalSince(anchor)

        // 0. 构建标识放在最前面：装上之后第一眼就能确认跑的是哪个包。
        //    以前三个包的 CFBundleVersion 全是 1.0(1)，装了旧包也看不出来。
        log.append("构建 \(BuildInfo.stamp)")

        // 0.5 运行痕迹：这是判断"到底死了没有"的唯一硬证据。
        //     bg = 后台检查次数。它一直是 0 就说明进程在后台根本没醒过。
        let store = AnchorStore.shared
        let bgAgo = store.lastBgTickAt.map { Int(now.timeIntervalSince($0) / 60) }
        let bgTxt = bgAgo.map { "\($0) 分钟前" } ?? "从未"
        log.append("· 检查 \(store.tickCount) 次，其中后台 \(store.bgTickCount) 次（最近 \(bgTxt)）")

        // 1. 锚点合理性：不该在未来，也不该比"窗口 + 1 小时"还久（除非整天没开）
        if anchor > now.addingTimeInterval(60) {
            log.append("✗ 锚点在未来（时钟跳变？）")
        } else if idle > config.window + 3600 {
            log.append("⚠ 锚点已 \(Int(idle / 60)) 分钟未更新（长时间没走够？）")
        } else {
            log.append("✓ 锚点正常，已静坐 \(Int(idle / 60)) 分钟")
        }

        // 2. 待发通知：现在是一整条链（后台死了也能按点响），上限 maxSlots
        NotificationPlanner.shared.pendingCount { [weak self] n in
            guard let self = self else { return }
            var lines = log
            if n <= NotificationPlanner.maxSlots {
                lines.append("✓ 待发通知 \(n) 条")
            } else {
                lines.append("✗ 待发通知 \(n) 条（超过上限，对账失效）")
            }
            for row in AnchorStore.shared.chainLog.split(separator: "\n").suffix(4) {
                lines.append("· \(row)")
            }

            // 3. 通知授权
            NotificationPlanner.shared.authorizationStatus { s in
                lines.append(s == "已允许" ? "✓ 通知权限已允许" : "✗ 通知权限：\(s)（会没声音）")
                let style = NotificationPlanner.shared.lastStyleReport
                if style.isEmpty {
                    lines.append("· 样式读取中，再点一次「重新自检」")
                } else {
                    lines.append(style)
                }

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
                    if d >= 0 {
                        lines.append("· 待发 \(n) 条，最近 " + String(d) + " 秒后")
                    } else {
                        lines.append("· 最近一条已过期 " + String(-d) + " 秒")
                    }
                } else {
                    lines.append("· 无待发通知")
                }

                // 7. 系统里那几条到底排在几点 —— 直接看，不靠推算。
                // 「设 5 分钟却 6 分钟才响」就是靠这一行确认的。
                let fm = DateFormatter()
                fm.dateFormat = "HH:mm:ss"
                let planned = NotificationPlanner.shared.plannedFires.prefix(4)
                if planned.isEmpty {
                    lines.append("· 链内容为空（系统里没排）")
                } else {
                    let shown = planned.map { fm.string(from: $0) }.joined(separator: " ")
                    lines.append("· 排定：" + shown)
                }

                self.selfCheckLog = lines
            }
        }
    }

}
