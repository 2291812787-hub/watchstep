import XCTest
@testable import WatchStepCore

/// 验收第 5 条：状态只有一个锚点，任何时候算出来的都是同一个答案。
final class AnchorStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 清掉所有用到的键
        for k in ["ws.anchor", "ws.nudgingSince", "ws.lastNudgeAt", "ws.lastResetAt",
                  "ws.day", "ws.nudgesToday", "ws.longestIdle", "ws.config"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    func testAnchorIsStableAcrossReads() {
        let store = AnchorStore.shared
        let first = store.anchor
        let second = store.anchor
        XCTAssertEqual(first, second, "两次读必须是同一个值，不能每次读都捏一个新时间")
    }

    func testResetClearsNudgeState() {
        let store = AnchorStore.shared
        store.nudgingSince = Date()
        store.lastNudgeAt = Date()
        let now = Date()
        store.reset(to: now)

        XCTAssertNil(store.nudgingSince)
        XCTAssertNil(store.lastNudgeAt)
        XCTAssertEqual(store.anchor.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(store.lastResetAt?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 0.01)
    }

    func testDeadlineAlwaysDerivedFromAnchor() {
        let cfg = Config(enabled: true, targetSteps: 200, windowMinutes: 30, tickMinutes: 5,
                         startMinute: 0, endMinute: 0, confirmHapticOnReset: false)
        let store = AnchorStore.shared
        let now = Date()
        store.reset(to: now)

        let d1 = RuleEngine.deadline(anchor: store.anchor, config: cfg)
        let d2 = RuleEngine.deadline(anchor: store.anchor, config: cfg)
        XCTAssertEqual(d1, d2, "deadline 必须由 anchor 现算，两次必须一致")
        XCTAssertEqual(d1.timeIntervalSince(now), 30 * 60, accuracy: 0.5)
    }

    func testLongestIdleNeverDecreases() {
        let store = AnchorStore.shared
        store.noteIdle(600)
        XCTAssertGreaterThanOrEqual(store.longestIdle, 600)
        store.noteIdle(300) // 更短的不该覆盖
        XCTAssertGreaterThanOrEqual(store.longestIdle, 600)
        store.noteIdle(900)
        XCTAssertGreaterThanOrEqual(store.longestIdle, 900)
    }
}
