import Foundation

/// 全部可调参数。存 UserDefaults，重装丢失后回到默认值也不会崩。
struct Config: Codable, Equatable {
    var enabled: Bool = true
    var targetSteps: Int = 150
    var windowMinutes: Int = 30
    var tickMinutes: Int = 3

    // MARK: - 生效时段（分钟粒度）

    /// 生效时段起点，单位「一天中的第几分钟」：480 = 08:00，1350 = 22:30。
    ///
    /// 以前是整点小时，只能设 8 点、22 点这种。但「22:30 之后别吵我」
    /// 是很自然的需求 —— 睡觉时间很少正好落在整点上。
    var startMinute: Int = 8 * 60

    /// 终点。1440 = 当天结束（23:59 之后），0 = 午夜。
    /// 起点 == 终点表示全天生效。
    var endMinute: Int = 0

    // MARK: - 手动暂停

    /// 暂停到这个时刻为止。nil = 没暂停。
    ///
    /// 和「生效时段」是两回事：时段是每天都有的作息，暂停是这一次性的
    /// 「我要开会 / 我在看电影 / 别烦我两小时」。所以它存在配置里、
    /// 能被界面一眼看到剩余时间，也随时可以提前恢复。
    var pausedUntil: Date? = nil

    /// 走够时给一下轻确认（可关，关了完全不打扰）
    var confirmHapticOnReset: Bool = true

    /// 存档格式版本。**故意用来做迁移闸门**：
    ///
    /// Swift 合成的 Codable 不会给缺失的键补默认值 —— 旧存档里没有这个键，
    /// `decode` 就会抛 keyNotFound，`load()` 的 `try?` 拿到 nil，于是整体回到
    /// 本结构体的默认值。这正是我们要的：装 3 分钟/1 分钟的测试包调过参数之后，
    /// 换回正式版不该继续沿用 3/1。
    ///
    /// 4：startHour/endHour（整点）→ startMinute/endMinute（分钟），
    ///    并新增 pausedUntil。旧存档的键名对不上，自动回到默认值 —— 这是对的，
    ///    因为把「原来 8 点」硬解释成「480」需要额外迁移代码，而重装本来就不保留
    ///    配置，多写一段迁移只会多一个出错点。
    ///
    /// 以后每次改默认值，把它 +1 即可；不要把它存进 UI 可编辑的字段。
    var configVersion: Int = 4

    // MARK: 什么情况下别打扰

    /// 插着充电线时不催。充电基本等于「人不在走」，而且这时候催最烦。
    var pauseWhileCharging: Bool = true

    /// 手表摘下来（已上锁）时不催。手腕检测关掉或没设密码时这条不生效。
    var pauseOffWrist: Bool = true

    /// 电量低于 lowBatteryPercent 时不催，省着点电。
    var pauseOnLowBattery: Bool = false

    /// 低电量阈值（百分比）。
    var lowBatteryPercent: Int = 20

    var window: TimeInterval { TimeInterval(max(1, windowMinutes) * 60) }
    var tick: TimeInterval { TimeInterval(max(1, tickMinutes) * 60) }

    // MARK: - 时段判定

    /// 现在是否被人为暂停了。
    func isPaused(at date: Date) -> Bool {
        guard let until = pausedUntil else { return false }
        return date < until
    }

    /// 暂停还剩多少秒。没暂停或已过期返回 0。
    func pauseRemaining(at date: Date) -> TimeInterval {
        guard let until = pausedUntil else { return 0 }
        return max(0, until.timeIntervalSince(date))
    }

    /// 是否在生效时段内（并且没被暂停）。
    ///
    /// 暂停刻意并进这里：所有「该不该排通知 / 该不该起会话」的地方调的都是
    /// `isActive`，只要它返回 false 就全线安静。如果暂停另设一个开关，
    /// 就得保证每个调用点都记得查两次 —— 那种约定迟早漏一个。
    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        if isPaused(at: date) { return false }
        if startMinute == endMinute { return true }

        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let m = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)

        // 终点写成 1440 表示「到当天结束」，不是绕回零点。单独处理，
        // 否则 1440 == 0 会被当成「全天」。
        if endMinute >= 1440 {
            return m >= startMinute
        }
        if startMinute < endMinute {
            return m >= startMinute && m < endMinute
        }
        return m >= startMinute || m < endMinute // 跨午夜
    }

    // MARK: - 持久化

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

    // MARK: - 显示

    /// 480 → "08:00"，1440 → "24:00"
    static func clockString(_ minuteOfDay: Int) -> String {
        let m = max(0, min(1440, minuteOfDay))
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    var startClock: String { Self.clockString(startMinute) }
    var endClock: String { endMinute == 0 ? "24:00" : Self.clockString(endMinute) }

    /// 界面上那一行「08:00 – 24:00 · 共 16 小时」。
    /// 跨午夜的时段（比如 20:00 – 02:00）会额外标「跨夜」，
    /// 否则「到 02:00」读起来像是同一个上午。
    var activeSpanText: String {
        if startMinute == endMinute { return "全天生效" }
        let span = ((endMinute - startMinute) % 1440 + 1440) % 1440
        let hours = Double(span) / 60
        let hoursText = hours == hours.rounded()
            ? "\(Int(hours)) 小时"
            : String(format: "%.1f 小时", hours)
        let cross = endMinute != 0 && endMinute < startMinute ? "（跨夜）" : ""
        return "\(startClock) – \(endClock)\(cross) · 共 \(hoursText)"
    }
}
