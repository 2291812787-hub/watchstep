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
        // 前台呈现的通知**不会进通知中心**（系统既定行为），因此
        // getDeliveredNotifications 永远看不到它 —— 引擎的"认账"必然落空，
        // 它以为这一轮没催过，几十秒后又补一条，用户就看到两条数字不一样的提醒。
        // 在呈现的当下补记一笔，把这条漏洞从根上堵掉。
        WatchEngine.shared.notePresented(notification.request.identifier)
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
        // 无条件对账：从挂起回来时，内存和现实可能已经不一致
        WatchEngine.shared.tick(force: true)
    }

    func applicationWillResignActive() {
        // 离开前把通知排好，这是挂起期间唯一能震手腕的东西
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

