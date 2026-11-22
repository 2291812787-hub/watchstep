import Foundation
import UserNotifications

/// 通知排期 —— **一整条链，不是一条**。
///
/// 为什么要一条链：
/// watchOS 没有任何办法让第三方 App 一直在后台活着（self-care 会话上限 1 小时、
/// 实际常半小时就断；后台刷新由系统随便决定）。所以「到点震动」这件事必须脱离
/// 进程：把未来若干次提醒**提前排进系统**，App 冻死、被杀、手表重启都照样响。
///
/// 之前只有一条槽，于是死掉之后最多响一声，下一条要等 App 醒来才排 ——
/// 用户看到的就是「第一个窗口结束响了一次，第二个 5 分钟就没了」。
///
/// 代价与对策（必须说清楚）：
/// 预排的正文在排进去那一刻就冻住了，步数是快照。所以文案只说上界
/// 「最多还差 N 步」+ 精确的「已坐 N 分钟」。App 每次醒来整链重排，立刻回到精确值。
///
/// 时间轴永远是「窗口到期 + k × 间隔」，锚定在锚点上，不随 tick 漂移 ——
/// 于是每 30 秒一次的 tick 重排出来的结果完全一样，`replaceChain` 直接跳过，
/// 不会有「越推越远，永远差一分钟」的老毛病。
final class NotificationPlanner {
    static let shared = NotificationPlanner()

    /// 立刻弹的那条用这个 id（重复投递会互相顶掉，通知中心不会堆一串）。
    static let baseID = "ws.nudge"
    /// 链上第 i 条。必须各用各的 id，否则系统里只能存在一条。
    static func chainID(_ i: Int) -> String { "\(baseID).c\(i)" }
    /// 测试通知独立 id，不参与链对账，也不被 cancelAll 撤掉。
    static let testID = "ws.test"
    /// 「接力」——一条 repeats 通知，**只占 1 个槽位，却无限期按间隔响**。
    ///
    /// 为什么需要它：预排上限是 64 条，我们排 60 条。间隔 1 分钟时这 60 条
    /// 正好等于 60 分钟 —— 一小时后系统里就空了。而 watchOS 的后台刷新
    /// 官方上限约 4 次/小时且不保证执行，所以「一小时后要手动点开才恢复」
    /// 不是 App 被杀，是链用完了。
    ///
    /// repeats 的 trigger 只吃「每隔多久」，不吃「第一次在几点」，所以它
    /// **不可能和精确链无缝拼接**：只能在进入催命期之后挂上，从那一刻起
    /// 每间隔响一次。代价是正文冻结（不带分钟数），换来的是永不耗尽。
    static let relayID = "ws.nudge.relay"
    private static let relayKey = "ws.relayArmed"

    /// 统一标题。只有「走够了」那条会临时换成别的。
    static let title = "起来走走"
    /// 一次最多排几条。系统上限是 64，留 2 个给接力（repeats）和测试通知。
    static let maxSlots = 62

    private let center = UNUserNotificationCenter.current()

    /// 当前排进系统的那条链，按触发时刻升序。
    private(set) var chain: [(id: String, fireAt: Date)] = []

    /// 每条链通知**排进去那一刻的正文**。
    ///
    /// 为什么必须记：通知一旦 add 进系统，正文就冻结了，只有用同一个 id 再 add
    /// 才能换掉。以前 replaceChain 只比触发时刻 —— 时刻不变就直接 return，于是
    /// 第一次排进去写的是「最多还差 200 步」，之后你走了 60 步、120 步，这句
    /// 一个字节都不会变。用户看到的就是**永远差 200**。这里把正文一起比。
    private var chainBodies: [String] = []

    /// 上一次因为正文变化而重排的时刻。走路时步数每轮都在涨，若不加这道闸门，
    /// 每 30 秒就要重排 62 条通知，费电也容易撞系统限流。
    private var lastBodyRefreshAt: Date = .distantPast

    /// 接力是否挂在系统里。存 UserDefaults —— App 被杀重启后照样知道，
    /// 否则会重复挂一条、或者在走够时忘了撤，一直响到晚上。
    var relayArmed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.relayKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.relayKey) }
    }

    /// 最近一次真正送出去的时刻（链上某条，或 app 活着时立刻弹的那条）。
    private(set) var lastDeliveredAt: Date?

    /// 最近一次 `add` 失败的原因。自检页直接显示这一行 ——
    /// 「有震动没弹窗」是不是因为 add 被系统拒了（超出限流、通知权限被收、
    /// 内容非法），看这里一眼就知道，不用再猜。
    var lastFireError: String?

    var nextFireAt: Date? { chain.first?.fireAt }
    var chainCount: Int { chain.count }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // 结果不用管：被拒绝时 app 内仍有震动 + 界面提示
        }
    }

    /// 自检页手动触发：再问一次系统要授权，然后把最新状态读回来。
    /// 用 ASK 是故意的——被拒之后重复请求不会再弹框，但能确认状态。
    func requestAgain() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 链上最早那条有没有已经送出去。系统不会回调我们，只能靠触发时刻反推。
    ///
    /// 返回非 nil 说明那一条**已经震过手腕了** —— 调用方必须把它记成一次催命，
    /// 否则随后醒来的 tick 会因为"还没催过"再补一条，用户就同时收到两条。
    @discardableResult
    func consumeDelivered(now: Date = Date()) -> Date? {
        // 一次吃完**全部**已经过点的槽位，取最晚的那一个。
        //
        // 以前只 removeFirst 一条。App 睡过好几个间隔再醒来时，链上已经有 3、4 条
        // 都过了点（真响过、也真震过），却只认账 1 条 —— 剩下的在内存里还算"待发"，
        // 下一轮 reconcile 又按它们重排一遍，于是十几秒内连补好几条。
        // 用户看到的就是「一分钟里隔几秒来一条」。
        var latest: Date?
        while let first = chain.first, first.fireAt <= now {
            latest = first.fireAt
            chain.removeFirst()
        }
        if let l = latest { lastDeliveredAt = l }
        return latest
    }

    /// 距上一次真正送出去还不到 minGap 就不许再发。
    /// 这是物理层的兜底：上面的判定逻辑将来再改错，也不会连发。
    func canDeliver(now: Date = Date(), minGap: TimeInterval) -> Bool {
        guard let last = lastDeliveredAt else { return true }
        return now.timeIntervalSince(last) >= minGap
    }

    /// 让系统里排着的那条链，正好等于 `fires`（未来时刻，升序）。
    ///
    /// 时刻一致就什么都不做 —— 否则每 30 秒的 tick 都会把整条链删掉重建，
    /// 白耗电，也给了系统限流的机会。
    ///
    /// `body` 按每一条自己的触发时刻生成：坐着的分钟数必须按它真正弹出的那一刻算，
    /// 用现在的时刻算会少报好几分钟。
    @discardableResult
    func replaceChain(_ fires: [Date], now: Date = Date(), body: (Date) -> String) -> Bool {
        // 只要还在未来就得排。以前这里是 `> 1`，把「刚过去半秒」的 deadline
        // 一起丢掉 —— 那正是 5 分钟那条从没排进去的原因。
        //
        // 现在放宽到「过去 2.5 秒内还算数」：迟到的那个网格点必须补一条"马上就响"，
        // 否则设 5 分钟会变成 6 分钟才响。重复的风险由调用方兜着 ——
        // 引擎每轮先用 consumeDelivered 认账，再用 dedupeGap 把这些点剔掉。
        // 只保留「还没过去」的点，外加半秒的抖动容忍。
        //
        // 以前这里放到 -2.5 秒，理由是「迟到的网格点也要补一条，否则设 5 分钟
        // 会变成 6 分钟才响」。但补的代价是**重复**：那条刚过去 2 秒的通知
        // 其实已经投递过了（consumeDelivered 认得账，可 App 被冻结时认不到），
        // 再补一条就是用户说的「步数一变，马上又发一条」。
        //
        // 真正的迟到补救交回给引擎：它每轮先 consumeDelivered 认账，
        // 认到就在 lastNudgeAt 上挡住；认不到才 fireNow 补。补一条准确的
        // 比补一条快照好 —— 快照里的步数早就过时了。
        let want = fires.filter { $0.timeIntervalSince(now) > -0.5 }.sorted()
        let wantBodies = want.map(body)

        if want.count == chain.count {
            var sameTimes = true
            for (i, w) in want.enumerated() {
                if abs(w.timeIntervalSince(chain[i].fireAt)) > 2 { sameTimes = false; break }
            }
            if sameTimes {
                // 时刻没变，但正文里带着步数和坐着的分钟数 —— 那才是用户看的东西。
                // 正文一致就真没事可做，一致不了就得换。
                //
                // **但 58 秒这道闸门只该管远处的槽位，不该管马上要弹的那条。**
                // 现在是 62 条正文一起重写（远处那些重写毫无意义，它们变成链首时
                // 自然会被重写），所以必须节流省电；结果连链首都被压了 58 秒。
                // 叠上后台 tick 的 60 秒下限，用户看到的那条最坏旧 118 秒 ——
                // 走路 1.5–2 步/秒，就是 150–200 步的误差，而目标才 200 步。
                // 用户说的「三分钟一次，隔两轮才准」，量出来的就是这个数。
                //
                // 只刷链首两条，成本与刷 62 条相比可以忽略，所以链首变了立刻换。
                if wantBodies == chainBodies { return false }
                if now.timeIntervalSince(lastBodyRefreshAt) < 58 {
                    let head = Swift.min(2, wantBodies.count)
                    let headChanged = head > 0
                        && zip(wantBodies.prefix(head), chainBodies.prefix(head))
                            .contains { $0.0 != $0.1 }
                    if !headChanged { return false }
                }
            }
        }

        // **先加后删**。同 id 的 add 是原子替换，所以任何一刻系统里都有通知排着。
        // 以前的顺序是先 removePending 再 add —— App 若正好在这两步之间被系统冻结
        // （挂起时机由系统决定，App 管不了），系统里就一条都不剩，而 App 已经死了、
        // 没人能补回来。这正是「活着好好的，过一阵就哑了」的机制。
        var fresh: [(id: String, fireAt: Date)] = []

        for (i, fire) in want.enumerated() {
            let id = Self.chainID(i)
            let content = UNMutableNotificationContent()
            content.title = Self.title
            content.body = body(fire)
            content.sound = .default
            // 这里曾经设过 .timeSensitive（时效性通知）。那是错的：
            // 它需要 com.apple.developer.usernotifications.time-sensitive 权限，
            // 免费签名的个人开发者账户拿不到。缺权限时 add() 不报错、待发条数
            // 照样算得进去，但到点系统不投递 —— 正是「排了 12 条，一条都不响」。
            // 默认 .active 就能弹横幅 + 响铃 + 震动，不需要任何额外权限。

            let delay = max(1, fire.timeIntervalSince(now))
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            center.add(request, withCompletionHandler: nil)
            fresh.append((id, fire))
        }

        // 新链比旧链短时，把多出来的槽位撤掉。id 是 0..maxSlots-1 连续编号，
        // 所以直接按范围撤，不依赖内存里的 chain（App 重启后它是空的）。
        let stale = (want.count..<Self.maxSlots).map { Self.chainID($0) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        chain = fresh
        chainBodies = wantBodies
        lastBodyRefreshAt = now
        return true
    }

    /// 立刻弹一条。只在 app 活着、且这一刻的数字是真的的时候用 ——
    /// 所以正文可以写准确步数。
    ///
    /// **不再撤掉整条链**。以前它会把唯一那条兜底排期一起撤掉，于是每次实时
    /// 催命都会把后续提醒清空，App 一睡就再也不响 —— 这正是"点开才发现弹窗没弹"。
    /// 现在只弹自己这一条（同 id 互相顶掉），链原样留着。
    @discardableResult
    func fireNow(body: String, title: String = "起来走走", now: Date = Date(),
                 minGap: TimeInterval = 0) -> Bool {
        // minGap 是最后一道物理闸门。以前没有任何闸门：判定逻辑一抖，
        // 这里就再弹一条，用户手腕上几十秒内收到好几条一样的。
        if minGap > 0, !canDeliver(now: now, minGap: minGap) {
            return false
        }
        lastDeliveredAt = now

        // **先加，后撤。** 顺序反了就是「有震动、没弹窗」。
        //
        // 原来是先 removeDeliveredNotifications 撤掉全部我方 id、再 add。
        // 于是走成这样：链上那条「还差 N 步」刚被系统投递（震动已经发生了）
        // → App 醒 → 判定走够 → 先撤一遍（clearDeliveredNotificationCenter 一次、
        // 这里再一次）→ **横幅被收走** → 而 add(trigger: nil) 是即时投递，
        // 要求进程还活着，赶上正要挂起就不生效 → 手腕上只剩一下震，屏幕空的。
        // 等下次 App 醒才补上一条「已满」—— 用户说的「隔一会儿通知才发过来」。
        //
        // 这条规矩项目自己在 replaceChain 里立过：先加后删，任何一刻系统里都
        // 有通知排着。fireNow 一直没遵守。
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: Self.baseID, content: content, trigger: nil)
        center.add(request) { error in
            if let error = error {
                DispatchQueue.main.async {
                    self.lastFireError = error.localizedDescription
                }
                // 加失败了就**不要撤**：旧的那条还留在屏幕上，比空无一物强。
                return
            }
            // 撤的是 delivered（已经响过的），pending 那条链不动。
            // baseID 必须排除 —— trigger: nil 是立即投递，撤自己等于刚弹就收走。
            var stale = [Self.relayID]
            for i in 0..<Self.maxSlots { stale.append(Self.chainID(i)) }
            DispatchQueue.main.async {
                self.lastFireError = nil
                self.center.removeDeliveredNotifications(withIdentifiers: stale)
            }
        }
        return true
    }

    /// 挂上接力：从现在起每 `interval` 秒响一次，无限期。
    ///
    /// 只在**进入催命期之后**调用。窗口还没到期就挂，会在窗口内提前响。
    func armRelay(interval: TimeInterval, title: String, body: String,
                  completion: @escaping (Bool) -> Void) {
        // repeats 的 trigger 有硬下限 60 秒，低于它会崩。配置下限本来就是 1 分钟，
        // 这里再夹一次，防止将来有人把间隔改小。
        let secs = max(60, interval)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: true)
        let request = UNNotificationRequest(identifier: Self.relayID, content: content, trigger: trigger)
        center.add(request) { error in
            let ok = (error == nil)
            DispatchQueue.main.async {
                if ok { self.relayArmed = true }
                completion(ok)
            }
        }
    }

    /// 撤掉接力。走够、充电、出了时段、关开关，都要撤 ——
    /// 它不像精确链那样会自己耗尽，不撤就会一直响下去。
    func disarmRelay() {
        guard relayArmed else {
            // 没挂也清一次，防止 UserDefaults 和系统状态不一致时残留
            center.removePendingNotificationRequests(withIdentifiers: [Self.relayID])
            return
        }
        relayArmed = false
        center.removePendingNotificationRequests(withIdentifiers: [Self.relayID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.relayID])
    }

    /// 撤掉待发的整条链（走够了、充电、摘下、关掉开关时用）。
    /// 不动 `watchstep.renew` 那条会话续期提醒 —— 它归 ExtendedSessionManager 管。
    func cancelAll() {
        var ids = chain.map { $0.id }
        ids.append(Self.baseID)
        ids.append(Self.relayID)
        relayArmed = false
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        chain = []
        chainBodies = []
    }

    /// 清空通知中心里已经弹过的那些，不动待发的。
    ///
    /// App 一进前台就调一次：后台该响的时候都响过、也震过了，堆在中心里只是碍眼，
    /// 用户点进来会看到「一堆消息」。以前靠"只排一条"避免这个，代价是一死就哑；
    /// 现在排整条链保证后台不断，代价用这一行清掉。
    func clearDeliveredNotificationCenter() {
        var ids = [Self.baseID, Self.relayID]
        for i in 0..<Self.maxSlots { ids.append(Self.chainID(i)) }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// 排一条 N 秒后必定该响的测试通知。
    ///
    /// 存在的理由：前面几轮全是「改一版 → 等 5 分钟 → 你说没响 → 再猜」，
    /// 每轮要好几分钟，而且分不清是「没排进去」「排进去没弹」「弹了没震动」。
    /// 有了这个，按一下 15 秒就有答案：标题写排定时刻，正文写排定的钟点，
    /// 弹出时和真实钟点一比就知道延迟多少。
    func scheduleTest(after seconds: TimeInterval = 15, completion: @escaping (String) -> Void) {
        let now = Date()
        let fire = now.addingTimeInterval(seconds)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"

        let content = UNMutableNotificationContent()
        content.title = "测试 " + f.string(from: fire)
        content.body = "排定 \(f.string(from: fire)) 响，现在 \(f.string(from: now))"
        content.sound = .default

        center.removePendingNotificationRequests(withIdentifiers: [Self.testID])
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let request = UNNotificationRequest(identifier: Self.testID, content: content, trigger: trigger)
        center.add(request) { error in
            DispatchQueue.main.async {
                if let e = error {
                    completion("✗ 测试通知排不进去：" + e.localizedDescription)
                } else {
                    completion("· 测试已排 " + f.string(from: fire) + " 响（现在 " + f.string(from: now) + "）")
                }
            }
        }
    }

    /// 最近一次读到的提醒样式明细，自检页直接显示这一行。
    var lastStyleReport: String = ""
    var plannedFires: [Date] { chain.map { $0.fireAt } }

    func pendingCount(_ completion: @escaping (Int) -> Void) {
        center.getPendingNotificationRequests { requests in
            let ours = requests.filter { $0.identifier.hasPrefix(Self.baseID) }.count
            DispatchQueue.main.async { completion(ours) }
        }
    }

    /// 不只看「授权了没有」，还要看**提醒样式**是不是被设成了静默投递。
    /// 权限「已允许」但 alertSetting/soundSetting 是 disabled 时，系统照样收下通知、
    /// 照样算进待发条数，只是不响不震、悄悄塞进通知中心 —— 看起来就像「后台死了」。
    func authorizationStatus(_ completion: @escaping (String) -> Void) {
        center.getNotificationSettings { settings in
            let s: String
            switch settings.authorizationStatus {
            case .authorized: s = "已允许"
            case .denied: s = "已拒绝"
            case .notDetermined: s = "未询问"
            case .provisional: s = "临时允许"
            case .ephemeral: s = "临时"
            @unknown default: s = "未知"
            }
            func flag(_ v: UNNotificationSetting) -> String {
                switch v {
                case .enabled: return "开"
                case .disabled: return "**关**"
                case .notSupported: return "不支持"
                @unknown default: return "?"
                }
            }
            // watchOS 没有 alertStyle（那是 iOS 的）。能拿到的是下面三项开关。
            let detail = "· 声音 \(flag(settings.soundSetting)) 横幅 \(flag(settings.alertSetting)) 通知中心 \(flag(settings.notificationCenterSetting))"
            DispatchQueue.main.async {
                completion(s)
                self.lastStyleReport = detail
            }
        }
    }
}
