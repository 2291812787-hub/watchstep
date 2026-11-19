import XCTest
@testable import WatchStepCore

final class SurroundingsTests: XCTestCase {

    private func at(_ h: Int, _ m: Int = 0) -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = h
        c.minute = m
        c.second = 0
        return Calendar.current.date(from: c)!
    }

    private func base() -> Config {
        var c = Config()
        c.startMinute = 0
        c.endMinute = 0
        return c
    }

    func testEverythingNormalIsNotQuiet() {
        XCTAssertNil(RuleEngine.quietReason(now: at(10), config: base(), surroundings: Surroundings()))
    }

    func testChargingPauses() {
        let s = Surroundings(charging: true)
        XCTAssertEqual(RuleEngine.quietReason(now: at(10), config: base(), surroundings: s), .charging)
    }

    func testChargingCanBeTurnedOff() {
        var c = base()
        c.pauseWhileCharging = false
        let s = Surroundings(charging: true)
        XCTAssertNil(RuleEngine.quietReason(now: at(10), config: c, surroundings: s))
    }

    func testOffWristPauses() {
        let s = Surroundings(offWrist: true)
        XCTAssertEqual(RuleEngine.quietReason(now: at(10), config: base(), surroundings: s), .offWrist)
    }

    func testLowBatteryPauses() {
        var c = base()
        c.lowBatteryPercent = 20
        let s = Surroundings(batteryPercent: 15)
        XCTAssertEqual(RuleEngine.quietReason(now: at(10), config: c, surroundings: s), .lowBattery)
    }

    func testLowBatteryAboveThresholdIsFine() {
        var c = base()
        c.lowBatteryPercent = 20
        let s = Surroundings(batteryPercent: 45)
        XCTAssertNil(RuleEngine.quietReason(now: at(10), config: c, surroundings: s))
    }

    func testUnknownBatteryIsNotTreatedAsEmpty() {
        // -1 表示读不到，不能当成 0% 而永久静音
        var c = base()
        c.lowBatteryPercent = 20
        let s = Surroundings(batteryPercent: -1)
        XCTAssertNil(RuleEngine.quietReason(now: at(10), config: c, surroundings: s))
    }

    func testChargingWinsOverLowBattery() {
        // 插着电时电量低无所谓，不该报「电量低」
        var c = base()
        c.lowBatteryPercent = 20
        let s = Surroundings(charging: true, batteryPercent: 5)
        XCTAssertEqual(RuleEngine.quietReason(now: at(10), config: c, surroundings: s), .charging)
    }

    func testSwitchesTurnPausingOff() {
        var c = base()
        c.pauseWhileCharging = false
        c.pauseOffWrist = false
        c.pauseOnLowBattery = false
        let s = Surroundings(charging: true, offWrist: true, batteryPercent: 3)
        XCTAssertNil(RuleEngine.quietReason(now: at(10), config: c, surroundings: s))
    }

    func testDisabledBeatsEverything() {
        var c = base()
        c.enabled = false
        let s = Surroundings(charging: true, offWrist: true, batteryPercent: 1)
        XCTAssertEqual(RuleEngine.quietReason(now: at(10), config: c, surroundings: s), .disabled)
    }

    func testOutsideWindowBeatsHardwareState() {
        var c = base()
        c.startMinute = 8 * 60
        c.endMinute = 22 * 60
        let s = Surroundings(charging: true)
        XCTAssertEqual(RuleEngine.quietReason(now: at(23), config: c, surroundings: s), .outsideWindow)
    }

    func testOffWristBeatsCharging() {
        var c = base()
        let s = Surroundings(charging: true, offWrist: true)
        XCTAssertEqual(RuleEngine.quietReason(now: at(10), config: c, surroundings: s), .offWrist)
    }

    func testWindowStartIsTodayWhenPastStart() {
        var c = base()
        c.startMinute = 8 * 60
        c.endMinute = 0
        let now = at(10, 30)
        let start = RuleEngine.windowStart(now: now, config: c)
        XCTAssertNotNil(start)
        XCTAssertEqual(Calendar.current.component(.hour, from: start!), 8)
        XCTAssertLessThanOrEqual(start!, now)
    }

    func testWindowStartRollsBackAcrossMidnight() {
        var c = base()
        c.startMinute = 22 * 60
        c.endMinute = 6 * 60
        let now = at(2)
        let start = RuleEngine.windowStart(now: now, config: c)
        XCTAssertNotNil(start)
        XCTAssertLessThan(start!, now)
        XCTAssertEqual(Calendar.current.component(.hour, from: start!), 22)
    }

    func testWindowStartIsNilWhenAlwaysOn() {
        var c = base()
        c.startMinute = 0
        c.endMinute = 0
        XCTAssertNil(RuleEngine.windowStart(now: at(10), config: c))
    }
}
