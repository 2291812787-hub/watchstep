import Foundation

/// 全部可调参数。存 UserDefaults，重装丢失后回到默认值也不会崩。
struct Config: Codable, Equatable {
    var enabled: Bool = true
    var targetSteps: Int = 200
    var windowMinutes: Int = 30
    var tickMinutes: Int = 5
    var startHour: Int = 8
    var endHour: Int = 22
    /// 走够时给一下轻确认（可关，关了完全不打扰）
    var confirmHapticOnReset: Bool = true

    var window: TimeInterval { TimeInterval(max(1, windowMinutes) * 60) }
    var tick: TimeInterval { TimeInterval(max(1, tickMinutes) * 60) }

    /// 是否在生效时段内。同一小时视为全天。
    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        if startHour == endHour { return true }
        let h = calendar.component(.hour, from: date)
        if startHour < endHour {
            return h >= startHour && h < endHour
        }
        return h >= startHour || h < endHour // 跨午夜
    }

    static let storageKey = "ws.config"

    static func load() -> Config {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let c = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return c
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
