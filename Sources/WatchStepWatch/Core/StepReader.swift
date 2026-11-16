import CoreMotion
import Foundation

/// 计步读取。
///
/// 关键事实：这里的步数是"系统账本"，不是"我记的账"。
/// CMPedometer 会缓存历史数据，app 挂起、被系统杀掉、手表重启之后都能把
/// 这段时间的步数完整查回来 —— 所以"判断"永远不需要 app 活着。
final class StepReader {
    static let shared = StepReader()

    private let pedometer = CMPedometer()
    private let lock = NSLock()

    private var cachedValue: Int?
    private var cachedFrom: Date?
    private var cachedTo: Date?

    var isAvailable: Bool { CMPedometer.isStepCountingAvailable() }

    /// 查 [from, to] 区间的累计步数。completion 一定在主线程回调。
    func steps(from: Date, to: Date, completion: @escaping (Int?) -> Void) {
        guard isAvailable else {
            completion(nil)
            return
        }
        guard to > from else {
            completion(0)
            return
        }

        // 同一锚点、且只往前挪了一点点，直接用缓存，避免同一秒内多次查询打数据库
        lock.lock()
        if let v = cachedValue, let f = cachedFrom, let t = cachedTo,
           abs(f.timeIntervalSince(from)) < 1.0,
           to >= t,
           to.timeIntervalSince(t) < 45.0 {
            lock.unlock()
            completion(v)
            return
        }
        lock.unlock()

        pedometer.queryPedometerData(from: from, to: to) { [weak self] data, _ in
            guard let self = self else { return }
            let value = data?.numberOfSteps.intValue
            if let value = value {
                self.lock.lock()
                self.cachedValue = value
                self.cachedFrom = from
                self.cachedTo = to
                self.lock.unlock()
            } else {
                self.lock.lock()
                self.cachedValue = nil
                self.cachedFrom = nil
                self.cachedTo = nil
                self.lock.unlock()
            }
            DispatchQueue.main.async { completion(value) }
        }
    }

    /// 直接读"现在"的总步数（相对某个起点），用于界面展示。
    func invalidateCache() {
        lock.lock()
        cachedValue = nil
        cachedFrom = nil
        cachedTo = nil
        lock.unlock()
    }
}
