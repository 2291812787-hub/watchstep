import Foundation

/// 唯一状态源。
///
/// 设计要点（对应那个 200 块 app 的 bug）：
/// - 全 app 只有 `anchor` 一个时间锚点，"还剩多久"永远现算，不存第二份。
/// - 不存在"前台计时器"和"后台计时器"，所以不可能出现两套逻辑。
/// - 读不到锚点就用当前时间重建：数据丢最多损失一轮窗口，绝不能崩、不能乱。
final class AnchorStore {
    static let shared = AnchorStore()

    private let d = UserDefaults.standard

    private enum K {
        static let anchor = "ws.anchor"
        static let nudgingSince = "ws.nudgingSince"
        static let lastNudgeAt = "ws.lastNudgeAt"
        static let lastResetAt = "ws.lastResetAt"
        static let day = "ws.day"
        static let nudgesToday = "ws.nudgesToday"
        static let longestIdle = "ws.longestIdle"
        static let lastTickAt = "ws.lastTickAt"
        static let lastBgTickAt = "ws.lastBgTickAt"
        static let tickCount = "ws.tickCount"
        static let bgTickCount = "ws.bgTickCount"
    }

    // MARK: - 锚点

    /// 上一次"走够"的时刻。
    var anchor: Date {
        get {
            if let t = d.object(forKey: K.anchor) as? Date { return t }
            let now = Date()
            d.set(now, forKey: K.anchor)
            return now
        }
        set { d.set(newValue, forKey: K.anchor) }
    }

    var lastResetAt: Date? {
        get { d.object(forKey: K.lastResetAt) as? Date }
        set {
            if let v = newValue { d.set(v, forKey: K.lastResetAt) }
            else { d.removeObject(forKey: K.lastResetAt) }
        }
    }

    // MARK: - 催命状态

    /// 非 nil 表示当前正处于"正在催"的状态，值是第一次开催的时刻。
    var nudgingSince: Date? {
        get { d.object(forKey: K.nudgingSince) as? Date }
        set {
            if let v = newValue { d.set(v, forKey: K.nudgingSince) }
            else { d.removeObject(forKey: K.nudgingSince) }
        }
    }

    var isNudging: Bool { nudgingSince != nil }

    /// 上一次真正发出震动的时刻，用来限制震动频率（否则每次 tick 都震）。
    var lastNudgeAt: Date? {
        get { d.object(forKey: K.lastNudgeAt) as? Date }
        set {
            if let v = newValue { d.set(v, forKey: K.lastNudgeAt) }
            else { d.removeObject(forKey: K.lastNudgeAt) }
        }
    }

    /// 上一次真正跑判定的时刻。
    /// 用来自检「中间是不是断了很久」——手表关机两天再开，
    /// 锚点是两天前，照用的话一戴就立刻挨催。
    var lastTickAt: Date? {
        get { d.object(forKey: K.lastTickAt) as? Date }
        set {
            if let v = newValue { d.set(v, forKey: K.lastTickAt) }
            else { d.removeObject(forKey: K.lastTickAt) }
        }
    }

    // MARK: - 运行痕迹（只为自检能回答"后台到底还在不在跑"）

    /// 累计跑过的判定次数，以及其中几次发生在 App 不在前台时。
    /// 前台跑得再好也不算数——问题从来只在屏幕黑掉之后。
    var tickCount: Int {
        get { d.integer(forKey: K.tickCount) }
        set { d.set(newValue, forKey: K.tickCount) }
    }

    var bgTickCount: Int {
        get { d.integer(forKey: K.bgTickCount) }
        set { d.set(newValue, forKey: K.bgTickCount) }
    }

    /// 最后一次在后台跑判定的时刻。若它一直停在"你合上屏幕那一刻"，
    /// 说明进程早被挂起了，后面所有催命都不会发生。
    var lastBgTickAt: Date? {
        get { d.object(forKey: K.lastBgTickAt) as? Date }
        set {
            if let v = newValue { d.set(v, forKey: K.lastBgTickAt) }
            else { d.removeObject(forKey: K.lastBgTickAt) }
        }
    }

    // MARK: - 当日统计

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func rollDayIfNeeded() {
        let today = Self.dayFormatter.string(from: Date())
        if d.string(forKey: K.day) != today {
            d.set(today, forKey: K.day)
            d.set(0, forKey: K.nudgesToday)
            d.set(0, forKey: K.longestIdle)
        }
    }

    var nudgesToday: Int {
        get { rollDayIfNeeded(); return d.integer(forKey: K.nudgesToday) }
        set { rollDayIfNeeded(); d.set(newValue, forKey: K.nudgesToday) }
    }

    var longestIdle: TimeInterval {
        get { rollDayIfNeeded(); return d.double(forKey: K.longestIdle) }
        set { rollDayIfNeeded(); d.set(newValue, forKey: K.longestIdle) }
    }

    func noteIdle(_ interval: TimeInterval) {
        if interval > longestIdle { longestIdle = interval }
    }

    /// 走够 → 归零。这是唯一允许写锚点的地方。
    func reset(to now: Date) {
        anchor = now
        lastResetAt = now
        nudgingSince = nil
        lastNudgeAt = nil
    }
}
