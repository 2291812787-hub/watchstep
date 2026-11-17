import Foundation
import UserNotifications

/// 通知排期。
///
/// 两个层次，缺一不可：
///
/// 1. **app 活着时（常驻会话在跑）**：走够立刻震、立刻撤掉还没弹的提醒。
/// 2. **app 被挂起时**：没有任何代码在跑，唯一能把手机在手腕上震响的东西
///    就是系统里已经排好的本地通知（不需要 Push 能力，免费签名也能用）。
///
/// 第 2 条以前只排了**一条**。于是每一次「离开前台」只换来一次提醒 ——
/// 那条弹完，人还没动，后面就彻底静默了，直到用户点开 App 才「补算」。
/// 用户看到的正是「平时不吭声，一打开全来」。
///
/// 现在离开前台那一刻一次排满一条链（默认覆盖 2 小时，每 tickMinutes 一条）。
/// 走够、充电、摘表、时段外，都由 `cancelAll()` 一次全撤 —— 不留残弹。
final class NotificationPlanner {
    static let shared = NotificationPlanner()

    /// 链上第 i 条的 id。共用前缀，撤销时不必先查系统。
    private static let idPrefix = "ws.nudge."
    private static func id(_ i: Int) -> String { "\(idPrefix)\(i)" }

    /// 链最长排多少条。iOS/watchOS 对单个 app 的待发本地通知上限是 64 条，
    /// 24 条（≈2 小时）留足余量，也远大于用户实际会忍的时长。
    static let maxSlots = 24

    /// 统一标题。
    static let title = "起来走走"

    private let center = UNUserNotificationCenter.current()

    /// 已经排进系统的那条链的触发时刻（本地记账，用于幂等与"是否已弹过"推断）。
    private var chain: [Date] = []
    /// 排这条链时的间隔，用于判断是否需要重排。
    private var chainInterval: TimeInterval = 0

    /// 最近一次真正送出去的时刻。
    private(set) var lastDeliveredAt: Date?

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // 被拒绝时 app 内仍有震动 + 界面提示
        }
    }

    /// 链上有没有哪一条其实已经弹出来了。系统不会回调我们，只能靠触发时刻反推。
    ///
    /// 返回非 nil 说明**至少震过一次手腕** —— 调用方必须记成一次催命，
    /// 否则随后醒来的 tick 会因为"还没催过"再补一条，用户就同时收到两条。
    @discardableResult
    func consumeDelivered(now: Date = Date()) -> Date? {
        let fired = chain.filter { $0 <= now }
        guard let last = fired.max() else { return nil }
        chain.removeAll { $0 <= now }
        lastDeliveredAt = last
        // 已经弹过的那几条，系统那边也一并清掉投递箱记录里的待发（本来就不在了）
        return last
    }

    /// 排一条链：第一条在 `firstFire`，之后每隔 `interval` 一条，共 `slots` 条。
    ///
    /// - `firstFire == nil` 表示现在不该有任何待发通知。
    /// - `slots == 1` 就是老行为（app 活着时够用）。
    ///
    /// 关键：**触发时刻没变就什么都不做**。否则 tick 每次重排都会把整条链
    /// 往后推，系统里永远躺着一堆"还有五分钟"的通知，一条都弹不出来。
    func replace(firstFire: Date?,
                 interval: TimeInterval,
                 slots: Int,
                 now: Date = Date(),
                 body: String) {
        consumeDelivered(now: now)

        let slotCount = max(1, min(slots, Self.maxSlots))

        guard let first = firstFire else {
            if chain.isEmpty { return }          // 本来就没有，别白清一次
            cancelPending()
            return
        }
        guard first.timeIntervalSince(now) > 1 else { return }

        // 幂等：链头没挪、条数没变，就别动
        if let head = chain.first,
           abs(head.timeIntervalSince(first)) <= 2,
           chain.count >= slotCount - 1,
           abs(chainInterval - interval) <= 1 {
            return
        }

        cancelPending()

        // 先把内容准备好，再多条一起交出去 —— 少几十次跨进程调用。
        var requests: [UNNotificationRequest] = []
        var times: [Date] = []
        for i in 0 ..< slotCount {
            let fire = first.addingTimeInterval(interval * Double(i))
            let delay = fire.timeIntervalSince(now)
            guard delay > 1 else { continue }

            let content = UNMutableNotificationContent()
            content.title = Self.title
            content.body = body
            content.sound = .default
            // 同一组，便于系统合并展示；也方便将来整体清掉
            content.threadIdentifier = "watchstep.nudge"

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            requests.append(UNNotificationRequest(identifier: Self.id(i),
                                                  content: content,
                                                  trigger: trigger))
            times.append(fire)
        }

        for r in requests { center.add(r, withCompletionHandler: nil) }
        chain = times
        chainInterval = interval
    }

    /// 立刻弹一条。只在 app 活着、且这一刻的数字是真的的时候用 ——
    /// 所以正文可以写准确步数。
    ///
    /// 会先撤掉整条链：绝不让预排的那几条随后再补刀。
    func fireNow(body: String, title: String = "起来走走", now: Date = Date()) {
        cancelPending()
        lastDeliveredAt = now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "watchstep.nudge"

        let request = UNNotificationRequest(identifier: Self.id(0), content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    /// 自检用：链上还有几条没弹
    var pendingCountLocal: Int { chain.count }

    /// 下一条要弹的时刻
    var nextFireAt: Date? { chain.first }

    /// 整个链的时刻表（自检用）
    var scheduledTimes: [Date] { chain }

    private func cancelPending() {
        let ids = (0 ..< Self.maxSlots).map { Self.id($0) } + [Self.idPrefix]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        chain = []
        chainInterval = 0
    }

    func cancelAll() {
        cancelPending()
        center.removeDeliveredNotifications(withIdentifiers: (0 ..< Self.maxSlots).map { Self.id($0) })
        center.removeAllDeliveredNotifications()
    }

    /// 自检用：系统里现在到底排了几条
    func pendingCount(_ completion: @escaping (Int) -> Void) {
        center.getPendingNotificationRequests { requests in
            let n = requests.filter { $0.identifier.hasPrefix(Self.idPrefix) }.count
            DispatchQueue.main.async { completion(n) }
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
