import SwiftUI
import WatchKit
import UserNotifications

@main
struct WatchStepApp: App {
    @WKApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var engine = WatchEngine.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .onAppear { engine.boot() }
        }
    }
}

/// App 在前台（用户正抬腕看着界面）时，系统默认不显示横幅。
/// 这样"只有一下震动、抬腕什么都没有"就发生了 —— 所以必须接管一次。
final class NudgePresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NudgePresenter()

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.alert, .sound])
    }
}

/// 后台唤醒都从这里进 —— 这是"app 被系统叫醒"的唯一统一入口。
final class AppDelegate: NSObject, WKApplicationDelegate {

    func applicationDidFinishLaunching() {
        NudgePresenter.shared.install()
        WatchEngine.shared.boot()
    }

    func applicationDidBecomeActive() {
        // 回到前台：先记下来，再无条件对账 —— 从挂起回来时，内存和现实可能已经不一致
        WatchEngine.shared.isForeground = true
        WatchEngine.shared.tick(force: true)
    }

    func applicationWillResignActive() {
        // 离开前把通知排好，这是挂起期间唯一能震手腕的东西。
        // 必须先把标志置成 false：对账要靠它决定"排 1 条还是排满一条链"，
        // 顺序反了就会只排 1 条，然后熄屏后彻底静默。
        WatchEngine.shared.isForeground = false
        WatchEngine.shared.tick(force: true)
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            WatchEngine.shared.tick(force: true)
            WatchBackgroundScheduler.shared.reschedule()
            switch task {
            case let t as WKApplicationRefreshBackgroundTask:
                t.setTaskCompletedWithSnapshot(false)
            case let t as WKSnapshotRefreshBackgroundTask:
                t.setTaskCompleted(restoredDefaultState: false, estimatedSnapshotExpiration: .distantFuture, userInfo: nil)
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

