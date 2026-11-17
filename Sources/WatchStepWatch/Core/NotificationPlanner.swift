import Foundation
import UserNotifications

/// 通知（也是唯一一条）。
///
/// 核心约束：**全文只有一个通知 id**。预排的兜底通知，和 app 活着时
/// 立刻弹的那条，用的是同一个 identifier —— 于是系统里永远最多存在一条，
/// 物理上不可能出现「起来走走」和「还差 137 步」几乎同时冒出来两条。
///
/// 定位：app 挂起时，这是唯一能把手机在手腕上震响的东西。
/// 用的是本地通知，不需要 Push Notifications 能力，免费签名账号也能用。
final class NotificationPlanner {
    static let shared = NotificationPlanner()

    /// 唯一 id。所有通知共用，新的一律顶掉旧的。
    static let identifier = "ws.nudge"
    /// 统一标题。只有「走够了」那条会临时换成别的。
    static let title = "起来走走"

    private let center = UNUserNotificationCenter.current()

    /// 当前排进系统的那条兜底通知的触发时刻（本地记账）。
    /// 教训：tick 每 30 秒一次，如果每次都 remove + add(now + 60s)，
    /// 那条通知就被无限推后、永远送不出去 —— 表现就是"催了五六次才冒出来一次"。
    private var pendingFireAt: Date?

    /// 最近一次真正送出去的时刻（兜底那条，或 app 活着时立刻弹的那条）。
    private(set) var lastDeliveredAt: Date?

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // 结果不用管：被拒绝时 app 内仍有震动 + 界面提示
        }
    }

    /// 兜底通知有没有已经送出去。系统不会回调我们，只能靠触发时刻反推。
    ///
    /// 返回非 nil 说明那一条**已经震过手腕了** —— 调用方必须把它记成一次催命，
    /// 否则随后醒来的 tick 会因为"还没催过"再补一条，用户就同时收到两条。
    @discardableResult
    func consumeDelivered(now: Date = Date()) -> Date? {
        guard let p = pendingFireAt, p <= now else { return nil }
        pendingFireAt = nil
        lastDeliveredAt = p
        return p
    }

    /// 用一条新的兜底通知替换掉旧的。`fireAt == nil` 表示现在不该有任何待发通知。
    ///
    /// 关键：**触发时刻没变就什么都不做**。否则 tick 每次重排都会把
    /// 同一条通知往后推一分钟，系统里永远躺着一个"还有一分钟"的通知。
    ///
    /// 这里只碰"待发"的那条，不清投递箱 —— 刚弹出来的那条不该被抹掉。
    func replace(fireAt: Date?, now: Date = Date(), body: String) {
        consumeDelivered(now: now)

        if let fire = fireAt, let prev = pendingFireAt,
           abs(prev.timeIntervalSince(fire)) <= 2 {
            return                      // 还是那个时刻，别动它
        }
        if fireAt == nil && pendingFireAt == nil {
            return                      // 本来就没有，别白清一次
        }

        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        pendingFireAt = nil

        guard let fire = fireAt else { return }
        let delay = fire.timeIntervalSince(now)
        guard delay > 1 else { return }

        let content = UNMutableNotificationContent()
        content.title = Self.title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger)
        center.add(request, withCompletionHandler: nil)
        pendingFireAt = fire
    }

    /// 立刻弹一条。只在 app 活着、且这一刻的数字是真的的时候用 ——
    /// 所以正文可以写准确步数。
    ///
    /// 会先撤掉还没发出去的兜底通知：同 id，绝不会和它并存。
    func fireNow(body: String, title: String = "起来走走", now: Date = Date()) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        pendingFireAt = nil
        lastDeliveredAt = now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    /// 自检用：现在有没有一条在等
    var nextFireAt: Date? { pendingFireAt }

    func cancelAll() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        pendingFireAt = nil
    }

    /// 自检用：系统里现在到底排了几条
    func pendingCount(_ completion: @escaping (Int) -> Void) {
        center.getPendingNotificationRequests { requests in
            let n = requests.filter { $0.identifier == Self.identifier }.count
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
