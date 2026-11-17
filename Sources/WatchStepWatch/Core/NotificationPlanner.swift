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

    /// 统一标题。只有「走够了」那条会临时换成别的。
    static let title = "起来走走"
    /// 一次最多排几条。系统上限是 64，留足余量。
    static let maxSlots = 24

    private let center = UNUserNotificationCenter.current()

    /// 当前排进系统的那条链，按触发时刻升序。
    private(set) var chain: [(id: String, fireAt: Date)] = []

    /// 最近一次真正送出去的时刻（链上某条，或 app 活着时立刻弹的那条）。
    private(set) var lastDeliveredAt: Date?

    var nextFireAt: Date? { chain.first?.fireAt }
    var chainCount: Int { chain.count }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // 结果不用管：被拒绝时 app 内仍有震动 + 界面提示
        }
    }

    /// 链上最早那条有没有已经送出去。系统不会回调我们，只能靠触发时刻反推。
    ///
    /// 返回非 nil 说明那一条**已经震过手腕了** —— 调用方必须把它记成一次催命，
    /// 否则随后醒来的 tick 会因为"还没催过"再补一条，用户就同时收到两条。
    @discardableResult
    func consumeDelivered(now: Date = Date()) -> Date? {
        guard let first = chain.first, first.fireAt <= now else { return nil }
        chain.removeFirst()
        lastDeliveredAt = first.fireAt
        return first.fireAt
    }

    /// 让系统里排着的那条链，正好等于 `fires`（未来时刻，升序）。
    ///
    /// 时刻一致就什么都不做 —— 否则每 30 秒的 tick 都会把整条链删掉重建，
    /// 白耗电，也给了系统限流的机会。
    ///
    /// `body` 按每一条自己的触发时刻生成：坐着的分钟数必须按它真正弹出的那一刻算，
    /// 用现在的时刻算会少报好几分钟。
    func replaceChain(_ fires: [Date], now: Date = Date(), body: (Date) -> String) {
        // 只要还在未来就得排。以前这里是 `> 1`，把「刚过去半秒」的 deadline
        // 一起丢掉 —— 那正是 5 分钟那条从没排进去的原因。
        let want = fires.filter { $0.timeIntervalSince(now) > 0.5 }.sorted()

        if want.count == chain.count {
            var same = true
            for (i, w) in want.enumerated() {
                if abs(w.timeIntervalSince(chain[i].fireAt)) > 2 { same = false; break }
            }
            if same { return }
        }

        let olds = chain.map { $0.id }
        if !olds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: olds)
        }
        chain = []

        for (i, fire) in want.enumerated() {
            let id = Self.chainID(i)
            let content = UNMutableNotificationContent()
            content.title = Self.title
            content.body = body(fire)
            content.sound = .default
            if #available(watchOS 8.0, *) {
                // 熄屏、专注模式下也别被压掉 —— 提醒晚了就等于没提醒。
                content.interruptionLevel = .timeSensitive
            }

            let delay = max(1, fire.timeIntervalSince(now))
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            center.add(request, withCompletionHandler: nil)
            chain.append((id, fire))
        }
    }

    /// 立刻弹一条。只在 app 活着、且这一刻的数字是真的的时候用 ——
    /// 所以正文可以写准确步数。
    ///
    /// **不再撤掉整条链**。以前它会把唯一那条兜底排期一起撤掉，于是每次实时
    /// 催命都会把后续提醒清空，App 一睡就再也不响 —— 这正是"点开才发现弹窗没弹"。
    /// 现在只弹自己这一条（同 id 互相顶掉），链原样留着。
    func fireNow(body: String, title: String = "起来走走", now: Date = Date()) {
        lastDeliveredAt = now
        center.removeDeliveredNotifications(withIdentifiers: [Self.baseID])

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if #available(watchOS 8.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        let request = UNNotificationRequest(identifier: Self.baseID, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    /// 撤掉待发的整条链（走够了、充电、摘下、关掉开关时用）。
    /// 不动 `watchstep.renew` 那条会话续期提醒 —— 它归 ExtendedSessionManager 管。
    func cancelAll() {
        var ids = chain.map { $0.id }
        ids.append(Self.baseID)
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        chain = []
    }

    /// 清空通知中心里已经弹过的那些，不动待发的。
    ///
    /// App 一进前台就调一次：后台该响的时候都响过、也震过了，堆在中心里只是碍眼，
    /// 用户点进来会看到「一堆消息」。以前靠"只排一条"避免这个，代价是一死就哑；
    /// 现在排整条链保证后台不断，代价用这一行清掉。
    func clearDeliveredNotificationCenter() {
        var ids = [Self.baseID]
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

    /// 链里各条的触发时刻，给自检页直接看「系统里到底排着几点」。
    var plannedFires: [Date] { chain.map { $0.fireAt } }

    func pendingCount(_ completion: @escaping (Int) -> Void) {
        center.getPendingNotificationRequests { requests in
            let ours = requests.filter { $0.identifier.hasPrefix(Self.baseID) }.count
            DispatchQueue.main.async { completion(ours) }
        }
    }

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
            DispatchQueue.main.async { completion(s) }
        }
    }
}
