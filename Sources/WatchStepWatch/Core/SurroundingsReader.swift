import Foundation
import WatchKit

/// 把 watchOS 的真实状态翻译成纯值 `Surroundings`。
///
/// 这一层故意很薄：只有系统 API，没有判断。判断全在 `RuleEngine.quietReason`，
/// 那边能在 Linux 上跑测试，这边不能 —— 所以别把逻辑写在这儿。
enum SurroundingsReader {

    static func read() -> Surroundings {
        let device = WKInterfaceDevice.current()

        // 电池监控默认关着，关了就读到 -1
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
        }

        let raw = Double(device.batteryLevel)          // 0…1，-1 表示未知
        let percent = raw < 0 ? -1 : Int((raw * 100).rounded())

        // .full = 充满了但还坐在充电座上，和插着电是同一件事：
        // 人不在走，而且这时候催最没意义。
        let state = device.batteryState
        let charging = (state == .charging || state == .full)

        return Surroundings(
            charging: charging,
            offWrist: isLocked(),
            batteryPercent: percent,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

        /// watchOS 没有公开的「脱腕 / 锁屏」查询接口 —— WKApplication 和 WKExtension
    /// 都没有 isDeviceLocked（Apple 文档里查不到这个符号），编译期就会报错。
    /// 而且摘下手表时没有皮肤接触，震动本来也传不到人身上，
    /// 所以这里不做脱腕判断，直接当作戴着。
    private static func isLocked() -> Bool { false }
}
