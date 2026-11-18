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

    // MARK: - 预排那条绝不写步数

    func testPreScheduledNeverCarriesSteps() {
        // 这条测试锁的是一个**产品判断**，不是措辞：
        // 一条链一次排 60 条，正文全在排程那一刻冻死；App 在后台不醒就永不刷新。
        // 用户走了一小时后抬腕，看到的还是排程时的快照 —— 而且**必然偏低**，
        // 因为后面的步数一条都没算进去。他会以为白走了。
        // 一个必然错、且总往"还没走够"方向错的数字，比没有数字坏得多。
        let scheduled = NudgeText.reminder(targetSteps: 200, steps: 63, sittingMinutes: 31,
                                           tickMinutes: 1, approximate: true)
        XCTAssertEqual(scheduled, "该走走了 · 已坐 31 分钟，1 分钟后再提醒你一次。")
        XCTAssertFalse(scheduled.contains("137"), "预排通知不许出现冻结的步数")
        XCTAssertFalse(scheduled.contains("还差"), "预排通知不许声称还差多少步")

        // 步数读不到时，预排版和它一模一样 —— 它本来就不依赖步数。
        let noSteps = NudgeText.reminder(targetSteps: 200, steps: nil, sittingMinutes: 31,
                                         tickMinutes: 1, approximate: true)
        XCTAssertEqual(noSteps, scheduled)

        // 前台实时那条相反：数字是刚读的，写在通知里不会过期，必须带上。
        let live = NudgeText.reminder(targetSteps: 200, steps: 63, sittingMinutes: 31,
                                      tickMinutes: 1)
        XCTAssertEqual(live, "还差 137 步 · 已坐 31 分钟，1 分钟后再提醒你一次。")
        XCTAssertNotEqual(scheduled, live, "排程与立刻弹的措辞要能区分")
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
