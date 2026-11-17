import Foundation

/// 一次判定结果。纯值，无副作用 —— 所有判断都走这一个函数，
/// 前台、后台、通知对账、开机对账，调的都是它，物理上不可能有第二套逻辑。
enum Decision: Equatable {
    case inactive   // 不在生效时段 / 已关闭
    case satisfied  // 走够了
    case waiting    // 窗口还没走完
    case nudge      // 该催
    case unknown    // 读不到步数（运动权限被拒 / 硬件不支持）
}

enum RuleEngine {

    /// 唯一判定入口。
    /// - Parameters:
    ///   - anchor: 上一次走够的时刻（唯一状态）
    ///   - steps: anchor 到 now 之间的步数；nil 表示读不到
    ///   - now: 当前时刻
    ///   - config: 阈值与时段
    static func decide(anchor: Date, steps: Int?, now: Date, config: Config) -> Decision {
        guard config.isActive(at: now) else { return .inactive }
        guard let steps = steps else { return .unknown }

        // ① 走够了 → 归零。这条永远排在最前，所以"走了 1000 步还响"不可能发生。
        if steps >= config.targetSteps { return .satisfied }

        // ② 窗口已满还没走够 → 催
        if now.timeIntervalSince(anchor) >= config.window { return .nudge }

        // ③ 窗口未满 → 静默，不打扰
        return .waiting
    }

    /// 距下一次判定还有多久（用于界面显示与通知排期）
    static func deadline(anchor: Date, config: Config) -> Date {
        anchor.addingTimeInterval(config.window)
    }

    /// 距离"该被催"还有多少秒；负数表示已经超时
    static func secondsUntilDeadline(anchor: Date, now: Date, config: Config) -> TimeInterval {
        deadline(anchor: anchor, config: config).timeIntervalSince(now)
    }

    /// 查步数该从哪一刻起算 —— 这是「每 30 分钟 200 步」成立的前提。
    ///
    /// **绝不能从锚点一路累加。** 锚点要等"走够"才会推进，所以只要一直没在
    /// 一个窗口内走够，[anchor, now] 就无限变长：坐一下午零散走出来的几百步，
    /// 会被当成"30 分钟内走了 200 步"，于是每次打开 App 都误判成功 → 窗口重开
    /// → 界面永远显示"刚好 30 分钟满格"，而且后台因为判了成功而全程不催。
    ///
    /// 起点取 max(锚点, now − 窗口)：最多只看最近一个窗口的长度。
    /// 刚归零时锚点最近，从锚点算，窗口是干净的。
    static func stepQueryStart(anchor: Date, now: Date, config: Config) -> Date {
        let floor = now.addingTimeInterval(-config.window)
        return anchor > floor ? anchor : floor
    }
}
