import SwiftUI

/// 验收工具。装上去第一件事就是跑它，把七条验收里的关键不变量摊在屏幕上。
/// 外加一块「网络诊断」：权限开关没有 API 可读，只能靠实测反推，所以把测出来的
/// 路径 / 三个目标的连通性 / 底层 errno 全摆出来，让人一眼能看出卡在哪一层。
struct SelfCheckView: View {
    @EnvironmentObject var engine: WatchEngine
    @Environment(\.dismiss) private var dismiss

    /// 版本行：营销版本 + 构建号 + CI 构建标识。
    /// 直接从 Bundle 读，不依赖 CI 生成的 BuildInfo 字段。
    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short)(\(build)) · \(BuildInfo.stamp)"
    }

    @State private var netLines: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("自检")
                    .font(.system(size: 14, weight: .bold))

                // 常驻显示版本号，不依赖"重新自检"按钮。
                // 之前只把构建号塞在 selfCheckLog 里，而那个日志要点按钮才有内容，
                // 结果界面上永远看不到自己装的是哪个版本 —— 装错包也没法第一时间发现。
                // 版本号直接从 Bundle 读：BuildInfo.swift 每次编译都会被 CI 覆写
                // （只留 stamp 和 sha），往里加字段等于白加。
                Text(versionLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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

                Divider().padding(.vertical, 3)

                Text("网络诊断")
                    .font(.system(size: 13, weight: .bold))

                if netLines.isEmpty {
                    Text("点「测网络」").font(.system(size: 10)).foregroundStyle(.secondary)
                }

                ForEach(netLines.indices, id: \.self) { i in
                    Text(netLines[i])
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(bad(netLines[i]) ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("测网络") {
                    netLines = ["测…（第一轮真发，失败会自动重连再打一轮）"]
                    NetDiag.run { lines in netLines = lines }
                }
                .font(.system(size: 11))
                .foregroundStyle(.green)

                // 主动重连：不等系统放行，自己扔掉旧 session 要一次。
                Button("强制重连并上传") {
                    netLines = ["重连中…"]
                    StepsUploader.shared.forceReconnect()
                    NetDiag.run { lines in netLines = lines }
                }
                .font(.system(size: 11))
                .foregroundStyle(.orange)

                // 路径 unsatisfied + 立刻 -1004，是「这个 App 被禁止使用
                // 无线数据」的典型表现，不是设备没网。两者必须分清，
                // 否则会一直让人去查路由器/重连 Wi-Fi（走过这条路）。
                Text(NetGateway.shared.lastPath.contains("unsat")
                     ? "路径被系统判为无通道 → 本 App 可能未获准使用无线数据"
                     : "网关 重连\(NetGateway.shared.rebuildCount())次 · 路径\(NetGateway.shared.lastPath) · 错码\(NetGateway.shared.lastCode)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NetGateway.shared.lastCode == 0 ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)

                Button("测试上传通道") {
                    StepsUploader.shared.probe { _ in engine.runSelfCheck() }
                }
                .font(.system(size: 11))
                .foregroundStyle(.green)

                Text("通知")
                    .font(.system(size: 13, weight: .bold))

                Text("授权：\(engine.notificationAuth)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(engine.notificationAuth == "已允许" ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)

                Text("待发：\(StepsUploader.shared.pendingCount()) 条（存本地，有通道自动补）")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(StepsUploader.shared.pendingCount() == 0 ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)

                Text("预排：\(engine.pendingNotifications) 条" +
                     (NotificationPlanner.shared.lastFireError.map { "\n最近一次没排进去：\($0)" } ?? ""))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(engine.pendingNotifications > 0 ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)

                Button("重新请求通知授权") { engine.requestNotificationAuth() }
                    .font(.system(size: 11))
                    .foregroundStyle(.yellow)

                Button("测试通知 15 秒后") { engine.testNotificationNow() }
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)

                Button("关闭") { dismiss() }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .onAppear {
            if netLines.isEmpty {
                netLines = ["测…"]
                NetDiag.run { lines in netLines = lines }
            }
        }
    }

    /// 失败和断网标红，一行一个字都别糊在一起。
    private func bad(_ line: String) -> Bool {
        line.contains("✗") || line.contains("断") || line.contains("未知")
    }
}
