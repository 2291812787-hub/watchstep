import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: WatchEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("启用", isOn: Binding(
                    get: { engine.config.enabled },
                    set: { v in engine.update { $0.enabled = v } }
                ))

                numberRow("目标步数", value: engine.config.targetSteps, unit: "步",
                          range: 50...2000, step: 50) { engine.set(\.targetSteps, $0) }

                numberRow("窗口", value: engine.config.windowMinutes, unit: "分",
                          range: 10...120, step: 5) { engine.set(\.windowMinutes, $0) }

                numberRow("催命间隔", value: engine.config.tickMinutes, unit: "分",
                          range: 1...30, step: 1) { engine.set(\.tickMinutes, $0) }

                numberRow("开始时段", value: engine.config.startHour, unit: "点",
                          range: 0...23, step: 1) { engine.set(\.startHour, $0) }

                numberRow("结束时段", value: engine.config.endHour, unit: "点",
                          range: 0...23, step: 1) { engine.set(\.endHour, $0) }

                Toggle("走够时确认一下", isOn: Binding(
                    get: { engine.config.confirmHapticOnReset },
                    set: { v in engine.update { $0.confirmHapticOnReset = v } }
                ))

                Button("本轮立即归零") { engine.resetNow() }
                    .foregroundStyle(.orange)

                Button("关闭") { dismiss() }
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private func numberRow(_ title: String, value: Int, unit: String,
                           range: ClosedRange<Int>, step: Int,
                           apply: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(value) \(unit)")
                .font(.system(size: 12))
            HStack(spacing: 6) {
                Button {
                    apply(max(range.lowerBound, value - step))
                } label: { Image(systemName: "minus") }
                    .buttonStyle(.bordered)

                Button {
                    apply(min(range.upperBound, value + step))
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.bordered)
            }
        }
    }
}
