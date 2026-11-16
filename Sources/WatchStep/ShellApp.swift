import SwiftUI

@main
struct WatchStepShell: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("催步")
                    .font(.title2.bold())
                Text("全部逻辑在手表上跑。\n打开手表上的「催步」开始使用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
