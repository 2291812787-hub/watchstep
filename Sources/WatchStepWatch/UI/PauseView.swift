import SwiftUI

/// 「这段时间别打扰我」——按一下暂停，选多久。
///
/// 暂停和「时段外」是两回事：时段是每天固定的作息，暂停是临时的
/// （开会、看电影、睡午觉）。两者在 Config 里各占一个字段，
/// isActive 同时认，所以暂停期间跟半夜一样：不排通知、不起会话、不查步数。
struct PauseView: View {
    @EnvironmentObject var engine: WatchEngine
    @Environment(\.dismiss) private var dismiss

    private static let options: [(String, TimeInterval)] = [
        ("30 分钟", 30 * 60),
        ("1 小时", 60 * 60),
        ("2 小时", 2 * 60 * 60),
        ("4 小时", 4 * 60 * 60)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("暂停打扰")
                    .font(.system(size: 15, weight: .semibold))

                if let until = engine.config.pausedUntil, until > Date() {
                    Text("正在暂停，到 \(Self.clock(until)) 恢复")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Button("现在恢复") {
                        engine.resumeNow()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Text("暂停期间不催、不响、不查步数；恢复后重新计时，不会立刻催你。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)

                ForEach(Self.options, id: \.0) { label, seconds in
                    Button(label) {
                        engine.pause(for: seconds)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }

                Button("到明早 \(Config.clockString(engine.config.startMinute))") {
                    engine.pauseUntilMorning()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .padding(.top, 2)

                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 2)
        }
    }

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
