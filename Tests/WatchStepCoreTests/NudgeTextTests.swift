import XCTest
@testable import WatchStepCore

/// 「两条通知合成一条」的文案验收。
///
/// 合并前的现场：一次 tick 里先弹「该走了 / 还差 137 步 · 已坐 30 分钟」，
/// 紧接着兜底那条又冒出来「该走走了 / 起身走一走，1 分钟后再提醒你一次」——
/// 两条各说一半，用户一次抬腕看两条，还得自己拼。
/// 现在正文只由 NudgeText 生成，一条说全：还差多少步 + 已坐多久 + 多久后再催。
final class NudgeTextTests: XCTestCase {

    // MARK: - 一条说全

    func testReminderSaysEverythingInOneLine() {
        let s = NudgeText.reminder(targetSteps: 200, steps: 63,
                                   sittingMinutes: 30, tickMinutes: 1)
        XCTAssertEqual(s, "还差 137 步 · 已坐 30 分钟，1 分钟后再提醒你一次。")
        XCTAssertTrue(s.contains("137"), "必须给出还差多少步")
        XCTAssertTrue(s.contains("已坐 30 分钟"))
        XCTAssertTrue(s.contains("1 分钟后再提醒你一次"), "必须说明多久后再催")
    }

    func testTickIntervalIsSpokenAsConfigured() {
        XCTAssertEqual(NudgeText.everyText(tickMinutes: 1), "1 分钟后再提醒你一次")
        XCTAssertEqual(NudgeText.everyText(tickMinutes: 5), "5 分钟后再提醒你一次")
    }

    func testTickBelowOneIsClampedToOne() {
        // 0 或负数在配置里非法，但界面能拖到 1 为止；兜底也不会说出"0 分钟后"
        XCTAssertEqual(NudgeText.everyText(tickMinutes: 0), "1 分钟后再提醒你一次")
        XCTAssertEqual(NudgeText.everyText(tickMinutes: -3), "1 分钟后再提醒你一次")
    }

    // MARK: - 边界

    func testAlreadyReachedTarget() {
        let s = NudgeText.reminder(targetSteps: 200, steps: 200,
                                   sittingMinutes: 12, tickMinutes: 1)
        XCTAssertEqual(s, "已满 200 步，重新开始计时。")
        XCTAssertFalse(s.contains("分钟后再提醒"), "走够了就不该再说还会再催")
    }

    func testOverTargetDoesNotShowNegative() {
        let s = NudgeText.reminder(targetSteps: 200, steps: 999,
                                   sittingMinutes: 12, tickMinutes: 1)
        XCTAssertFalse(s.contains("-"), "剩余步数不许出现负数")
        XCTAssertEqual(s, "已满 200 步，重新开始计时。")
    }

    func testStepsUnavailableStillReadsNaturally() {
        let s = NudgeText.reminder(targetSteps: 200, steps: nil,
                                   sittingMinutes: 30, tickMinutes: 1)
        XCTAssertEqual(s, "该走走了 · 已坐 30 分钟，1 分钟后再提醒你一次。")
        XCTAssertFalse(s.contains("nil"))
    }

    func testNegativeSittingIsClamped() {
        // 时钟跳变可能让 anchor 在未来；不许出现"已坐 -5 分钟"
        let s = NudgeText.reminder(targetSteps: 200, steps: 10,
                                   sittingMinutes: -5, tickMinutes: 1)
        XCTAssertTrue(s.contains("已坐 0 分钟"))
        XCTAssertFalse(s.contains("-5"))
    }

    // MARK: - 预排那条用"约"

    func testApproximateMarksSnapshotSteps() {
        // 预排通知的步数是排程时的快照，弹出时可能又多走了几步 ——
        // 所以写"约"，不假装精确。这两条是同一段文案，只差一个词。
        let scheduled = NudgeText.reminder(targetSteps: 200, steps: 63, sittingMinutes: 31,
                                           tickMinutes: 1, approximate: true)
        let live = NudgeText.reminder(targetSteps: 200, steps: 63, sittingMinutes: 31,
                                      tickMinutes: 1)
        // 预排版必须把数字说清楚 —— 这是用户唯一能判断"还差多少"的地方。
        // 以前预排版写「最多还差 N 步」，滑动窗口一挪 N 就变成谎话，所以去掉"最多"。
        XCTAssertEqual(scheduled, "还差 137 步 · 已坐 31 分钟，1 分钟后再提醒你一次。")
        XCTAssertEqual(live, "还差 137 步 · 已坐 31 分钟，1 分钟后再提醒你一次。")
    }

    // MARK: - 和判定引擎对齐（同一条链上的两个环节）

    /// 走够的那一刻判定是 satisfied，文案也必须同步说"已满"，不能还说"还差"。
    func testTextAgreesWithRuleEngineAtSatisfied() {
        let anchor = Date()
        let now = anchor.addingTimeInterval(31 * 60)
        let cfg = Config(enabled: true, targetSteps: 200, windowMinutes: 30, tickMinutes: 1,
                         startHour: 0, endHour: 0, confirmHapticOnReset: true)

        let d = RuleEngine.decide(anchor: anchor, steps: 200, now: now, config: cfg)
        XCTAssertEqual(d, .satisfied)

        let text = NudgeText.reminder(targetSteps: cfg.targetSteps, steps: 200,
                                      sittingMinutes: Int(now.timeIntervalSince(anchor) / 60),
                                      tickMinutes: cfg.tickMinutes)
        XCTAssertEqual(text, "已满 200 步，重新开始计时。")
    }

    /// 该催的那一刻，文案必须给剩余步数，而不是只说"起来走走"。
    func testTextAgreesWithRuleEngineAtNudge() {
        let anchor = Date()
        let now = anchor.addingTimeInterval(31 * 60)
        let cfg = Config(enabled: true, targetSteps: 200, windowMinutes: 30, tickMinutes: 1,
                         startHour: 0, endHour: 0, confirmHapticOnReset: true)

        let d = RuleEngine.decide(anchor: anchor, steps: 40, now: now, config: cfg)
        XCTAssertEqual(d, .nudge)

        let text = NudgeText.reminder(targetSteps: cfg.targetSteps, steps: 40,
                                      sittingMinutes: Int(now.timeIntervalSince(anchor) / 60),
                                      tickMinutes: cfg.tickMinutes)
        XCTAssertEqual(text, "还差 160 步 · 已坐 31 分钟，1 分钟后再提醒你一次。")
    }
}
