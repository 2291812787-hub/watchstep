import UIKit

/// iOS 壳。手表 app 需要它作为容器才能被安装/签名（免费签名路线尤其如此）。
/// 它不做任何事：不参与判断、不推送、不需要 HealthKit。
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }
}
