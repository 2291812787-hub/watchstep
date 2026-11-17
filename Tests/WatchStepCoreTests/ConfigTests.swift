import XCTest
@testable import WatchStepCore

/// 正式默认值 + 存档迁移的验收。
///
/// 现场：为了五分钟内验完机制，包里曾把默认值改成窗口 3 分钟 / 间隔 1 分钟。
/// 换回正式版时有个坑 —— 覆盖安装**不会**清 UserDefaults，旧参数会继续生效。
/// 所以 Config 里加了一个 `configVersion` 当迁移闸门：旧存档缺这个键，
/// 解码失败，整体回落到本版默认值。
final class ConfigTests: XCTestCase {

    private let key = Config.storageKey

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    // MARK: - 正式默认值

    func testOfficialDefaults() {
        let c = Config()
        XCTAssertEqual(c.targetSteps, 200)
        XCTAssertEqual(c.windowMinutes, 30, "30 分钟一轮")
        XCTAssertEqual(c.tickMinutes, 5, "没走够每 5 分钟催一次")
        XCTAssertTrue(c.enabled)
    }

    func testDefaultWindowRunsFromEightUntilMidnight() {
        let c = Config()
        func at(_ hour: Int) -> Date {
            Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        }
        XCTAssertFalse(c.isActive(at: at(7)), "早上八点前不该催")
        XCTAssertTrue(c.isActive(at: at(8)))
        XCTAssertTrue(c.isActive(at: at(15)))
        XCTAssertTrue(c.isActive(at: at(23)), "十点之后就静默是旧默认值的 bug，现在要管到午夜")
    }

    // MARK: - 迁移闸门

    /// 装过测试包留下的存档：没有 configVersion 键，参数是 3/1。
    /// 覆盖安装后必须回到 30/5，不能继续沿用测试值。
    func testLegacyArchiveWithoutVersionFallsBackToDefaults() {
        let legacy = #"{"enabled":true,"targetSteps":200,"windowMinutes":3,"tickMinutes":1,"startHour":1,"endHour":0,"confirmHapticOnReset":true}"#
        UserDefaults.standard.set(Data(legacy.utf8), forKey: key)

        let c = Config.load()
        XCTAssertEqual(c.windowMinutes, 30, "旧存档必须被丢弃，回正式默认值")
        XCTAssertEqual(c.tickMinutes, 5)
        XCTAssertEqual(c.startHour, 8)
        XCTAssertEqual(c.configVersion, Config().configVersion,
                       "解码失败时整份回到本版默认值，版本号自然等于本版")
    }

    /// 本版存下去的存档要能原样读回（否则每次启动都被重置，用户改的东西全白改）。
    func testSavedConfigRoundTrips() {
        var c = Config()
        c.windowMinutes = 45
        c.tickMinutes = 7
        c.startHour = 9
        c.targetSteps = 300
        c.save()

        let back = Config.load()
        XCTAssertEqual(back, c)
        XCTAssertEqual(back.windowMinutes, 45, "用户自己调过的值不许被闸门冲掉")
    }

    /// 用户把设置改回默认值时，也要真的等于默认值（避免「看起来一样但差个字段」）。
    func testSaveThenLoadKeepsDefaultsIntact() {
        Config().save()
        XCTAssertEqual(Config.load(), Config())
    }

    // MARK: - 时段边界

    func testEightToMidnightIsNotAllDay() {
        var c = Config()
        c.startHour = 8
        c.endHour = 0
        // 8→0 走跨午夜分支：h >= 8 || h < 0 —— 凌晨那几小时必须关掉
        func at(_ hour: Int) -> Date {
            Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        }
        XCTAssertFalse(c.isActive(at: at(0)))
        XCTAssertFalse(c.isActive(at: at(6)))
        XCTAssertTrue(c.isActive(at: at(20)))
    }
}
