import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: WatchEngine
    @State private var showSettings = false
    @State private var showSelfCheck = false

    // 每秒刷新，只为把倒计时数字变活；这是界面，不是状态源
    @State private var now = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            main(context.date)
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(engine) }
        .sheet(isPresented: $showSelfCheck) { SelfCheckView().environmentObject(engine) }
    }

    @ViewBuilder
    private func main(_ date: Date) -> some View {
        VStack(spacing: 6) {
            statusBadge(date)
            bigNumber(date)
            Text(detail(date))
                .font(.system(size: 12))
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
            }
            .padding(.top, 2)

            Button("自检") { showSelfCheck = true; engine.runSelfCheck() }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 三档状态（验收第 10 条：不许出现会走错的数字）

    private func statusBadge(_ date: Date) -> some View {
        let lvl = engine.level(at: date)
        let (text, color): (String, Color) = {
            switch lvl {
            case .ok: return ("正常", .green)
            case .soon: return ("快到了", .yellow)
            case .overdue: return ("该动了", .red)
            case .off: return ("已关闭", .gray)
            }
        }()
        return Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
    }

    // MARK: - 主数字

    /// 只在"该动了"之后才显示活秒数 —— 此时压迫感才是重点。
    /// 平时显示"距该提醒还有 X 分钟"，由锚点现算，不会跑偏。
    private func bigNumber(_ date: Date) -> some View {
        let remaining = engine.secondsRemaining(at: date)
        if remaining <= 0 {
            let over = Int(-remaining)
            return Text(timerText(over))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.red)
        } else {
            let mins = Int(ceil(remaining / 60))
            return Text("\(mins)")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(engine.level(at: date) == .soon ? .yellow : .white)
        }
    }

    private func timerText(_ secondsOver: Int) -> String {
        let m = secondsOver / 60
        let s = secondsOver % 60
        return String(format: "+%d:%02d", m, s)
    }

    private func detail(_ date: Date) -> String {
        if case .unknown = engine.lastDecision {
            return engine.lastError.isEmpty ? "读不到步数" : engine.lastError
        }
        if !engine.config.enabled { return "已在设置里关闭" }
        if !engine.config.isActive(at: date) {
            return "生效时段 \(engine.config.startHour):00–\(engine.config.endHour):00"
        }
        let target = engine.config.targetSteps
        let cur = engine.stepsInWindow
        if engine.level(at: date) == .overdue {
            return "本轮 \(cur)/\(target) 步 · 每 \(engine.config.tickMinutes) 分钟催一次"
        }
        return "本轮 \(cur)/\(target) 步"
    }
}
