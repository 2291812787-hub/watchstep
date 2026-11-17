import XCTest
@testable import WatchStepCore

/// 验收标准逐条落成可执行测试。
/// 这些测试在 Linux runner 上跑，不需要苹果账号、不需要 Mac。
final class RuleEngineTests: XCTestCase {

    // 固定一个"在时段内"的基准时刻：2026-11-16 14:00 本地时间
    private func date(hour: Int, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 16
        c.hour = hour; c.minute = minute; c.second = 0
        return Calendar.current.date(from: c)!
    }

    private var cfg: Config {
        Config(enabled: true, targetSteps: 200, windowMinutes: 30, tickMinutes: 5,
               startHour: 8, endHour: 22, confirmHapticOnReset: true)
    }

    // MARK: - 验收 1：走够 → 归零，不震

    func testSatisfiedWhenStepsReachTarget() {
        let anchor = date(hour: 14, minute: 0)
        let now = date(hour: 14, minute: 10)
        let d = RuleEngine.decide(anchor: anchor, steps: 200, now: now, config: cfg)
        XCTAssertEqual(d, .satisfied)
    }

    func testSatisfiedIgnoresElapsedTime() {
        // 关键回归：走了 1000 步、已经过了 40 分钟，仍然必须判定"已走够"。
        // 那个 200 块的 app 在这里回 .nudge —— 也就是它"走了 1000 步还响 30 分钟提醒"的 bug。
        let anchor = date(hour: 14, minute: 0)
        let now = date(hour: 14, minute: 40)
        let d = RuleEngine.decide(anchor: anchor, steps: 1000, now: now, config: cfg)
        XCTAssertEqual(d, .satisfied, "走够了就不许再响，无论过了多久")
    }

    func testNotSatisfiedOneStepShort() {
        let anchor = date(hour: 14, minute: 0)
        let now = date(hour: 14, minute: 10)
        let d = RuleEngine.decide(anchor: anchor, steps: 199, now: now, config: cfg)
        XCTAssertEqual(d, .waiting)
    }

    // MARK: - 验收 2：静坐 30 分钟 → 该催

    func testNudgeExactlyAtWindow() {
        let anchor = date(hour: 14, minute: 0)
        let now = date(hour: 14, minute: 30)
        let d = RuleEngine.decide(anchor: anchor, steps: 10, now: now, config: cfg)
        XCTAssertEqual(d, .nudge)
    }

    func testWaitingBeforeWindow() {
        let anchor = date(hour: 14, minute: 0)
        let now = date(hour: 14, minute: 29)
        let d = RuleEngine.decide(anchor: anchor, steps: 10, now: now, config: cfg)
        XCTAssertEqual(d, .waiting)
    }

    // MARK: - 验收 3：催命期间持续催（不吞）

    func testKeepsNudgingDuringNudgePhase() {
        let anchor = date(hour: 14, minute: 0)
        for minutes in [35, 40, 45, 50, 60] {
            let now = date(hour: 14, minute: 60).addingTimeInterval(0)
            _ = now
            let t = anchor.addingTimeInterval(TimeInterval(minutes * 60))
            let d = RuleEngine.decide(anchor: anchor, steps: 30, now: t, config: cfg)
            XCTAssertEqual(d, .nudge, "第 \(minutes) 分钟仍应判定该催")
        }
    }

    // MARK: - 验收 4：走动后立刻停止

    func testStopsImmediatelyAfterWalking() {
        let anchor = date(hour: 14, minute: 0)
        // 第 40 分钟还在催
        let during = anchor.addingTimeInterval(40 * 60)
        XCTAssertEqual(RuleEngine.decide(anchor: anchor, steps: 50, now: during, config: cfg), .nudge)
        // 同一时刻走了 200 步 → 立刻转为已走够（调用方据此归零并撤销通知）
        XCTAssertEqual(RuleEngine.decide(anchor: anchor, steps: 250, now: during, config: cfg), .satisfied)
    }

    // MARK: - 时段

    func testInactiveOutsideWindow() {
        let anchor = date(hour: 23, minute: 0)
        let now = date(hour: 23, minute: 40)
        let d = RuleEngine.decide(anchor: anchor, steps: 0, now: now, config: cfg)
        XCTAssertEqual(d, .inactive)
    }

    func testInactiveWhenDisabled() {
        var c = cfg
        c.enabled = false
        let anchor = date(hour: 14, minute: 0)
        let now = date(hour: 14, minute: 40)
        XCTAssertEqual(RuleEngine.decide(anchor: anchor, steps: 0, now: now, config: c), .inactive)
    }

    func testCrossMidnightWindow() {
        var c = cfg
        c.startHour = 22
        c.endHour = 6
        XCTAssertTrue(c.isActive(at: date(hour: 23)))
        XCTAssertTrue(c.isActive(at: date(hour: 2)))
        XCTAssertFalse(c.isActive(at: date(hour: 12)))
    }

    func testFullDayWhenStartEqualsEnd() {
        var c = cfg
        c.startHour = 0
        c.endHour = 0
        XCTAssertTrue(c.isActive(at: date(hour: 3)))
        XCTAssertTrue(c.isActive(at: date(hour: 23)))
    }

    // MARK: - 读不到步数

    func testUnknownWhenStepsUnavailable() {
        let anchor = date(hour: 14, minute: 0)
        let now = date(hour: 14, minute: 40)
        XCTAssertEqual(RuleEngine.decide(anchor: anchor, steps: nil, now: now, config: cfg), .unknown)
    }

    // MARK: - 时间计算

    func testDeadlineAndRemaining() {
        let anchor = date(hour: 14, minute: 0)
        let deadline = RuleEngine.deadline(anchor: anchor, config: cfg)
        XCTAssertEqual(deadline.timeIntervalSince(anchor), 30 * 60)

        let now = date(hour: 14, minute: 20)
        XCTAssertEqual(RuleEngine.secondsUntilDeadline(anchor: anchor, now: now, config: cfg), 10 * 60)

        let later = date(hour: 14, minute: 45)
        XCTAssertEqual(RuleEngine.secondsUntilDeadline(anchor: anchor, now: later, config: cfg), -15 * 60)
    }

    // MARK: - 全流程模拟（一轮完整闭环）

    /// 模拟：前 12 分钟完全静坐，第 13 分钟起每分钟走 8 步（走得很慢，凑不够 200）。
    /// 预期：第 30 分钟进入该催（累计 144 步）；第 37 分钟累计满 200 → 归零，之后不再该催。
    func testFullCycleSimulation() {
        var anchor = date(hour: 14, minute: 0)
        var nudgeMinute: Int?
        var resetMinute: Int?
        var nudgeCount = 0

        for m in 0...120 {
            let now = anchor.addingTimeInterval(TimeInterval(m * 60))
            let elapsed = Int(now.timeIntervalSince(anchor) / 60)
            let cumSteps = elapsed <= 12 ? 0 : (elapsed - 12) * 8

            let d = RuleEngine.decide(anchor: anchor, steps: cumSteps, now: now, config: cfg)
            switch d {
            case .nudge:
                if nudgeMinute == nil { nudgeMinute = m }
                nudgeCount += 1
            case .satisfied:
                if resetMinute == nil { resetMinute = m }
                anchor = now
            default:
                break
            }
            if resetMinute != nil { break }
        }

        XCTAssertEqual(nudgeMinute, 30, "第 30 分钟应开始催")
        XCTAssertEqual(nudgeCount, 7, "第 30~36 分钟共催 7 次，一次都不许吞")
        XCTAssertEqual(resetMinute, 37, "累计满 200 步那一刻必须归零")
    }

    /// 全静坐一小时：每一分钟都必须判该催，不许出现"催一次就沉默"。
    func testNeverSilentlyStopsNudging() {
        let anchor = date(hour: 14, minute: 0)
        var silentAfterNudge = false
        var hasNudged = false
        for m in 0...60 {
            let now = anchor.addingTimeInterval(TimeInterval(m * 60))
            let d = RuleEngine.decide(anchor: anchor, steps: 0, now: now, config: cfg)
            if d == .nudge { hasNudged = true }
            if hasNudged && d == .waiting { silentAfterNudge = true }
        }
        XCTAssertTrue(hasNudged)
        XCTAssertFalse(silentAfterNudge, "开始催之后不许退回静默")
    }

    // MARK: - 回归：查询区间不能无限累加

    /// 锚点停在 3 小时前（一直没走够），查询起点必须只回看一个窗口。
    /// 否则 3 小时里零散走的 400 步会被当成"30 分钟走了 200 步"，
    /// 打开 App 立刻误判成功、窗口重开 —— 用户看到的就是"一打开刚好 30 分钟"。
    func testQueryStartNeverLooksBackMoreThanOneWindow() {
        let now = date(hour: 17, minute: 0)
        let anchor = now.addingTimeInterval(-3 * 3600)
        let start = RuleEngine.stepQueryStart(anchor: anchor, now: now, config: cfg)
        XCTAssertEqual(start, now.addingTimeInterval(-30 * 60))
        XCTAssertLessThanOrEqual(now.timeIntervalSince(start), 30 * 60 + 0.001)
    }

    /// 刚归零时锚点比窗口起点更近，从锚点算 —— 新窗口从零开始。
    func testQueryStartUsesAnchorWhenWithinWindow() {
        let now = date(hour: 14, minute: 20)
        let anchor = date(hour: 14, minute: 10)
        XCTAssertEqual(RuleEngine.stepQueryStart(anchor: anchor, now: now, config: cfg), anchor)
    }

    /// 锚点正好等于窗口边界时也算一个完整窗口。
    func testQueryStartAtExactWindowBoundary() {
        let now = date(hour: 14, minute: 30)
        let anchor = date(hour: 14, minute: 0)
        XCTAssertEqual(RuleEngine.stepQueryStart(anchor: anchor, now: now, config: cfg), anchor)
    }

    /// 坐一下午：累计 400 步但最近 30 分钟只有 50 步 —— 必须判"该催"，不许判走够。
    func testLongIdleWithCumulativeStepsStillNudges() {
        let now = date(hour: 17, minute: 0)
        let anchor = now.addingTimeInterval(-3 * 3600)
        // 从早先的累计里"看到" 400 步是错的；正确起点只看最近 30 分钟 = 50 步
        let recentSteps = 50
        XCTAssertEqual(
            RuleEngine.decide(anchor: anchor, steps: recentSteps, now: now, config: cfg),
            .nudge
        )
    }
}
