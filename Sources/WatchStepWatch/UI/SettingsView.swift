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
                          range: 1...120, step: 1) { engine.set(\.windowMinutes, $0) }

                numberRow("催命间隔", value: engine.config.tickMinutes, unit: "分",
                          range: 1...30, step: 1) { engine.set(\.tickMinutes, $0) }

                // 时段按「一天中的第几分钟」存，步长 30 分钟。
                // 以前只有整点可选，可是「22:30 之后别吵我」才是真实作息。
                timeRow("开始时段", minute: engine.config.startMinute, step: 30) {
                    engine.set(\.startMinute, $0)
                }

                timeRow("结束时段", minute: engine.config.endMinute, step: 30) {
                    engine.set(\.endMinute, $0)
                }

                Text(engine.config.activeSpanText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Toggle("走够时确认一下", isOn: Binding(
                    get: { engine.config.confirmHapticOnReset },
                    set: { v in engine.update { $0.confirmHapticOnReset = v } }
                ))

                Divider().padding(.vertical, 2)
                Text("别打扰我")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Toggle("充电中不催", isOn: Binding(
                    get: { engine.config.pauseWhileCharging },
                    set: { v in engine.update { $0.pauseWhileCharging = v } }
                ))

                Toggle("电量低不催", isOn: Binding(
                    get: { engine.config.pauseOnLowBattery },
                    set: { v in engine.update { $0.pauseOnLowBattery = v } }
                ))

                if engine.config.pauseOnLowBattery {
                    numberRow("低电阈值", value: engine.config.lowBatteryPercent, unit: "%",
                              range: 5...50, step: 5) { engine.set(\.lowBatteryPercent, $0) }
                }

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

    /// 时段行：显示成 08:00 这种，而不是「480 分钟」。
    /// 步长 30 分钟 = 整点和半点，正好覆盖「22:30 之后别吵我」这类作息。
    @ViewBuilder
    private func timeRow(_ title: String, minute: Int, step: Int,
                         apply: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(Config.clockString(minute))")
                .font(.system(size: 12))
            HStack(spacing: 6) {
                Button {
                    // 1440 分钟一圈，越过 00:00 要回绕，不能变成负数。
                    apply(((minute - step) % 1440 + 1440) % 1440)
                } label: { Image(systemName: "minus") }
                    .buttonStyle(.bordered)

                Button {
                    apply((minute + step) % 1440)
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.bordered)
            }
        }
    }
}
