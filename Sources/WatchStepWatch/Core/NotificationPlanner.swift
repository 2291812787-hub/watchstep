import Foundation
import UserNotifications

/// 兜底通知。
///
/// 定位：app 挂起时唯一能把手机在手腕上震响的东西。
/// 规则：**系统里永远最多一条待发通知，id 固定**。每次 app 醒来（任何原因）
/// 都先清空再按当前锚点重排 —— 所以它不可能和真实状态长期脱节。
///
/// 注意：本条路径用的是本地通知，不需要 Push Notifications 能力，
/// 免费签名账号也能用（本地通知不是 entitlement）。
final class NotificationPlanner {
    static let shared = NotificationPlanner()

    static let identifier = "ws.nudge"

    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // 结果不用管：被拒绝时 app 内仍有震动 + 界面提示
        }
    }

    /// 用一条新通知替换掉旧的。`fireAt == nil` 表示现在不该有任何待发通知。
    func replace(fireAt: Date?, now: Date = Date(), body: String) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])

        guard let fire = fireAt else { return }
        let delay = fire.timeIntervalSince(now)
        guard delay > 1 else { return }

        let content = UNMutableNotificationContent()
        content.title = "该走走了"
        // 正文刻意不写"已静坐 35 分钟"这类可被证伪的数字：
        // 通知一旦排进系统就撤不回来，写死数字就会出现"走了 1000 步还在说你静坐"的尴尬。
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger)
        center.add(request, withCompletionHandler: nil)
    }

    func cancelAll() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
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
