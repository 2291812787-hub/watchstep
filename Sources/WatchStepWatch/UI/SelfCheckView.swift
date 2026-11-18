import SwiftUI

/// 验收工具。装上去第一件事就是跑它，把七条验收里的关键不变量摊在屏幕上。
struct SelfCheckView: View {
    @EnvironmentObject var engine: WatchEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("自检")
                    .font(.system(size: 14, weight: .bold))

                ForEach(engine.selfCheckLog, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(line.hasPrefix("✗") ? .red : (line.hasPrefix("⚠") ? .yellow : .primary))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if engine.selfCheckLog.isEmpty {
                    Text("点下面按钮跑一次").font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Button("重新自检") { engine.runSelfCheck() }
                    .font(.system(size: 11))

                Button("测试上传通道") {
                    StepsUploader.shared.probe { _ in engine.runSelfCheck() }
                }
                .font(.system(size: 11))
                .foregroundStyle(.green)

                Button("测试通知 15 秒后") { engine.testNotificationNow() }
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)

                Button("关闭") { dismiss() }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
    }
}
