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

    /// 手表是否已上锁。戴着时（手腕检测开着）熄屏也不算锁；
    /// 摘下放桌上大约一分钟就会落锁，所以这是目前最接近「脱腕」的公开信号。
    private static func isLocked() -> Bool {
        if #available(watchOS 9.0, *) {
            return WKApplication.shared().isDeviceLocked
        } else {
            return WKExtension.shared().isDeviceLocked
        }
    }
}
