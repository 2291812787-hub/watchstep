import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: WatchEngine
    @State private var showSettings = false
    @State private var showSelfCheck = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            main(context.date)
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(engine) }
        .sheet(isPresented: $showSelfCheck) { SelfCheckView().environmentObject(engine) }
    }

    @ViewBuilder
    private func main(_ date: Date) -> some View {
        VStack(spacing: 5) {
            statusBadge(date)
            bigNumber(date)
            stepRow()
            Text(detail(date))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Button {
                    engine.tick(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)

                Button {
                    showSelfCheck = true
                    engine.runSelfCheck()
                } label: {
                    Image(systemName: "checklist")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 三档状态（验收第 10 条：不许出现会走错的数字）

    @ViewBuilder
    private func statusBadge(_ date: Date) -> some View {
        if let q = engine.quiet {
            // 暂停原因比"正常"重要：充电时显示"正常"等于骗人
            badge(q.label, q == .outsideWindow ? .gray : .orange)
        } else if !engine.config.enabled {
            badge("已关闭", .gray)
        } else {
            switch engine.level(at: date) {
            case .ok:      badge("正常", .green)
            case .soon:    badge("快到了", .yellow)
            case .overdue: badge("该动了", .red)
            case .off:     badge("已关闭", .gray)
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
    }

    // MARK: - 主数字（倒计时）

    /// 只在"该动了"之后才显示活秒数 —— 此时压迫感才是重点。
    /// 平时显示"距该提醒还有 X 分钟"，由锚点现算，不会跑偏。
    private func bigNumber(_ date: Date) -> some View {
        let remaining = engine.secondsRemaining(at: date)
        if remaining <= 0 {
            let over = Int(-remaining)
            return Text(timerText(over))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.red)
        } else {
            let mins = Int(ceil(remaining / 60))
            return Text("\(mins)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(engine.level(at: date) == .soon ? .yellow : .white)
        }
    }

    private func timerText(_ secondsOver: Int) -> String {
        let m = secondsOver / 60
        let s = secondsOver % 60
        return String(format: "+%d:%02d", m, s)
    }

    // MARK: - 本轮步数（一直显示，不让主界面只剩一个孤零零的数字）

    @ViewBuilder
    private func stepRow() -> some View {
        let target = max(1, engine.config.targetSteps)
        let cur = engine.stepsInWindow
        let reached = cur >= target
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 11))
                    .foregroundStyle(reached ? .green : .secondary)
                Text("\(cur) / \(target) 步")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(reached ? .green : .primary)
            }
            ProgressView(value: Double(min(cur, target)), total: Double(target))
                .progressViewStyle(.linear)
                .tint(reached ? .green : .blue)
        }
    }

    private func detail(_ date: Date) -> String {
        if case .unknown = engine.lastDecision {
            return engine.lastError.isEmpty ? "读不到步数" : engine.lastError
        }
        if !engine.config.enabled { return "已在设置里关闭" }
        if !engine.config.isActive(at: date) {
            return "生效时段 \(engine.config.startHour):00–\(engine.config.endHour):00"
        }
        if engine.level(at: date) == .overdue {
            return "每 \(engine.config.tickMinutes) 分钟催一次"
        }
        return "\(engine.config.windowMinutes) 分钟一轮，走够就归零"
    }
}
