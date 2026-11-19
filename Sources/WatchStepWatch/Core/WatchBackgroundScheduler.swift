import WatchKit
import Foundation

/// 后台刷新排期。
///
/// 注意：watchOS 的后台刷新预算很粗 —— 官方文档 *"the system performs approximately
/// four tasks per hour for each app with a complication on the active watch face"*，
/// 也就是 15 分钟左右一次，**比我们需要的 5 分钟粒度粗**。
///
/// 所以后台刷新只是「补充唤醒」，不是主力：
///   · 主力是 ExtendedSessionManager（真活着，能精确震、能撤销）
///   · 兜底是 NotificationPlanner（预排通知，系统闹钟，不受预算限制）
///   · 这里排队列只是「多给几次机会去对账」，有更好，没有也不影响正确性
///
/// 这也解释了为什么不能靠"每 5 分钟唤醒一次"来做判断 —— 但判断本身根本不需要唤醒，
/// 计步是系统级记账，事后 queryPedometerData(from:to:) 能全额查回来。
final class WatchBackgroundScheduler {
    static let shared = WatchBackgroundScheduler()

    private let taskIdentifier = "com.watchstep.refresh"
    private var scheduleRequested = false

    private init() {}

    /// 排一次后台刷新。重复调用无副作用。
    func reschedule(after interval: TimeInterval = 5 * 60) {
        // WKApplication.scheduleBackgroundRefresh 对同一时间点的重复排队是幂等的，
        // 但频繁重新排会消耗配额，所以这里做一层「本轮已排过就不再排」。
        let now = Date()
        if scheduleRequested,
           let last = UserDefaults.standard.object(forKey: "bg.lastScheduledAt") as? Date,
           now.timeIntervalSince(last) < 60 {
            return
        }

        UserDefaults.standard.set(now, forKey: "bg.lastScheduledAt")
        scheduleRequested = true

        // 时段外（含手动暂停）一律不排后台唤醒。
        // 排了也只是把 App 从深睡里拽起来一次，然后 tick 立刻早退 —— 纯耗电。
        // 不排的代价只是「明早第一次唤醒晚一点」，打开 App 会重新排上。
        guard WatchEngine.shared.config.isActive(at: now) else { return }

        let fireAt = now.addingTimeInterval(max(60, interval))
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: fireAt,
            userInfo: nil
        ) { error in
            if let error = error {
                // 配额耗尽或系统拒绝：不影响正确性，兜底通知仍然在。
                NSLog("[WatchStep] 后台刷新排期失败：\(error.localizedDescription)")
                UserDefaults.standard.set(
                    error.localizedDescription,
                    forKey: "bg.lastError"
                )
            }
        }
    }

    /// 后台任务被系统唤起时调用（在 WatchStepApp 的 handle() 里）。
    /// 只做一件事：把控制权交回引擎，引擎自己会重新对账并重排通知。
    func handle(task: WKApplicationRefreshBackgroundTask) {
        // 不传 force：时段外或暂停中，tick 会自己早退，一次查询都不做。
        WatchEngine.shared.tick(force: false)
        // 顺手排下一次
        reschedule(after: 5 * 60)
        task.setTaskCompletedWithSnapshot(false)
    }
}
