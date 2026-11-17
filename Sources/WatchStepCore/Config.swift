import Foundation

/// 全部可调参数。存 UserDefaults，重装丢失后回到默认值也不会崩。
struct Config: Codable, Equatable {
    var enabled: Bool = true
    var targetSteps: Int = 200
    var windowMinutes: Int = 30
    var tickMinutes: Int = 5
    var startHour: Int = 8
    /// 0 表示午夜。8→0 走跨午夜分支 =「8:00 到 23:59」。
    /// 早前默认 22，重装后一到晚上十点就静默，用户还以为是坏了。
    var endHour: Int = 0
    /// 走够时给一下轻确认（可关，关了完全不打扰）
    var confirmHapticOnReset: Bool = true

    /// 存档格式版本。**故意用来做迁移闸门**：
    ///
    /// Swift 合成的 Codable 不会给缺失的键补默认值 —— 旧存档里没有这个键，
    /// `decode` 就会抛 keyNotFound，`load()` 的 `try?` 拿到 nil，于是整体回到
    /// 本结构体的默认值。这正是我们要的：装 3 分钟/1 分钟的测试包调过参数之后，
    /// 换回正式版不该继续沿用 3/1。
    ///
    /// 以后每次改默认值，把它 +1 即可；不要把它存进 UI 可编辑的字段。
    var configVersion: Int = 2

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
