import SwiftUI
import WatchKit

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

/// 后台唤醒都从这里进 —— 这是"app 被系统叫醒"的唯一统一入口。
final class AppDelegate: NSObject, WKApplicationDelegate {

    func applicationDidFinishLaunching() {
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

/// 后台刷新排期。
struct WatchBackgroundScheduler {
    static let shared = WatchBackgroundScheduler()

    func reschedule(interval: TimeInterval = 15 * 60) {
        // 系统只把时间当"偏好"，受复杂功能预算限制（约 4 次/小时）。
        // 所以这里只是额外的一双眼睛，主引擎是前台 tick，兜底是预排通知。
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(interval),
            userInfo: nil
        ) { _ in }
    }
}
