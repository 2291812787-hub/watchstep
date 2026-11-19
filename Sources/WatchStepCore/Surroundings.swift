import Foundation

/// 手表此刻所处的环境。只装事实，不含判断 —— 判断在 `RuleEngine.quietReason`。
///
/// 单独抽出来是为了能在 Linux 上跑单元测试：watchOS 的电池、锁屏 API
/// 在测试环境里不存在，所以这里只留纯值。
struct Surroundings: Equatable {

    /// 插着充电线。充满后仍放在充电座上也算 —— 那时候人一样不在走。
    var charging: Bool

    /// 已摘下并且上锁。Apple Watch 靠手腕检测在上锁，
    /// 所以「摘下来放桌上」大约一分钟后就会变成 true。
    ///
    /// 注意：没设密码的手表永不落锁，这条就永远不生效 —— 属降级，不算错。
    var offWrist: Bool

    /// 电量百分比 0…100。`-1` 表示读不到。
    var batteryPercent: Int

    /// 系统低电量模式。
    var lowPowerMode: Bool

    init(charging: Bool = false,
                offWrist: Bool = false,
                batteryPercent: Int = 100,
                lowPowerMode: Bool = false) {
        self.charging = charging
        self.offWrist = offWrist
        self.batteryPercent = batteryPercent
        self.lowPowerMode = lowPowerMode
    }

    /// 读不到环境数据时的缺省：当作一切正常，不因为「不知道」就停止催。
    /// 宁可多催一次，也不要因为读数失败而整天不响。
    static let unknown = Surroundings()

    /// 电量是否真的低。`-1`（未知）不算低。
    func batteryIsLow(threshold: Int) -> Bool {
        guard batteryPercent >= 0 else { return false }
        return batteryPercent <= threshold
    }
}

/// 此刻不该打扰的原因。`nil` 表示可以催。
enum QuietReason: String, Equatable, CaseIterable {

    case disabled        // 总开关关了
    case paused          // 被「暂停」按钮按住了，或还没到恢复时刻
    case outsideWindow   // 不在生效时段
    case charging        // 在充电
    case offWrist        // 摘下来了
    case lowBattery      // 电量太低

    /// 一句话给界面看。
    var label: String {
        switch self {
        case .disabled:      return "已关闭"
        case .paused:        return "已暂停"
        case .outsideWindow: return "不在生效时段"
        case .charging:      return "充电中，暂停"
        case .offWrist:      return "手表已摘下，暂停"
        case .lowBattery:    return "电量低，暂停"
        }
    }
}

extension RuleEngine {

    /// 该不该闭嘴。**只看环境，不看步数** —— 步数是否达标由 `decide` 管。
    ///
    /// 单独一个函数而不是塞进 `decide`，是因为这两件事要分开处理：
    /// 被环境抑制时，走够了仍然要记账归零（那是好事，不该拦）。
    static func quietReason(now: Date,
                                   config: Config,
                                   surroundings s: Surroundings) -> QuietReason? {
        guard config.enabled else { return .disabled }

        // 暂停要单独判，不能只靠 isActive —— 那边的返回是「不在生效时段」，
        // 而用户按了暂停却看到「不在生效时段」会以为设置坏了。
        if config.isPaused(at: now) { return .paused }

        guard config.isActive(at: now) else { return .outsideWindow }

        if s.offWrist && config.pauseOffWrist { return .offWrist }

        // 充电排在低电量前面：插着电时电量低无所谓，反正正在补。
        if s.charging && config.pauseWhileCharging { return .charging }

        if config.pauseOnLowBattery {
            if s.lowPowerMode { return .lowBattery }
            if s.batteryIsLow(threshold: config.lowBatteryPercent) { return .lowBattery }
        }

        return nil
    }

    /// 当前这一段生效时段的起点。
    ///
    /// 存在的理由：昨天夜里攒了整宿的空档，今天 8:00 时段一开就会算出
    /// 「已经坐了 9 小时」，立刻挨骂。所以在时段起点之后第一次跑，
    /// 把锚点抬到起点，重新给一个完整窗口。
    static func windowStart(now: Date,
                                   config: Config,
                                   calendar: Calendar = .current) -> Date? {
        guard config.startMinute != config.endMinute else { return nil }  // 全天生效，没有起点
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = config.startMinute / 60
        comps.minute = config.startMinute % 60
        comps.second = 0
        guard var start = calendar.date(from: comps) else { return nil }
        if start > now {
            start = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        }
        return start
    }
}
