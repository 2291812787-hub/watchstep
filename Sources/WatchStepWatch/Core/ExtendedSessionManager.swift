import Foundation
import WatchKit
import Combine

/// 延长运行时会话（self-care 类）。
///
/// 为什么需要它：挂起时 haptic 发不出去、通知也撤不回来。有了这段会话，
/// app 在屏幕熄灭后仍能跑，于是"走够就立刻停催"才成立。
///
/// 代价：1–2%/小时。所以只在生效时段内开，时段外一律不占。
/// 限制：单段最长 1 小时；到期自动续一段，续不上就退回"预排通知"兜底
/// （此时可能有一次误报 —— 这是物理成本，任何 app 都逃不掉）。
final class ExtendedSessionManager: NSObject, ObservableObject {

    static let shared = ExtendedSessionManager()

    @Published private(set) var isRunning = false
    @Published private(set) var lastEndReason: String = ""

    /// 本段会话开始时刻。self-care 会话上限 1 小时，用来看还剩多少。
    private var segmentStartedAt: Date?

    /// 估算本段会话还能跑多少分钟。0 表示已经到期或没在跑。
    var minutesLeftEstimate: Int {
        guard isRunning, let s = segmentStartedAt else { return 0 }
        let left = 60 - Int(Date().timeIntervalSince(s) / 60)
        return max(0, left)
    }
    @Published private(set) var segmentsStarted: Int = 0

    private var session: WKExtendedRuntimeSession?
    private var wantRunning = false
    private var restartWorkItem: DispatchWorkItem?
    /// 连续失败次数（成功启动即清零）。以前用 `segmentsStarted` 判断退避，
    /// 那是一辈子只增不减的累计值 —— 跑满 7 段之后，每次失败都固定等 2 分钟，
    /// 后台一断就再也接不上。
    private var consecutiveFailures = 0

    private override init() { super.init() }

    func setDesired(_ on: Bool) {
        wantRunning = on
        if on { startIfNeeded() } else { stop() }
    }

    func startIfNeeded() {
        guard wantRunning, !isRunning, session == nil else { return }

        // Apple 的硬限制：extended runtime session **只能在前台启动**。
        // 后台去 start() 必然失败，还会把 consecutiveFailures 一路推高，
        // 最后退避到 2 分钟一次的风扇式重试。后台就老实等着，
        // 靠那一条预排通知兜底；下次抬腕点开 App 时自然会重新起会话。
        guard WatchEngine.shared.isForeground else {
            lastEndReason = "待前台启动"
            return
        }

        let s = WKExtendedRuntimeSession()
        s.delegate = self
        session = s
        s.start()

        // 看门狗：系统有时既不回 didStart 也不回 didInvalidate（当时不在前台、
        // 或会话额度被拒、或正在充电）。这一挂，session 就永远非 nil，
        // 上面那句 `session == nil` 从此永远不成立 —— 会话再也不会起来，
        // 后台判定整段瘫痪，「走够了立刻停催」就永远做不到。
        // 30 秒没落地就当没起来，清掉重排。
        let watchdog = DispatchWorkItem { [weak self, weak s] in
            guard let self = self, let s = s else { return }
            guard self.session === s, !self.isRunning else { return }
            s.invalidate()
            self.session = nil
            self.consecutiveFailures += 1
            self.lastEndReason = "启动超时"
            self.scheduleRestart(after: 15)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: watchdog)
    }

    func stop() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        session?.invalidate()
        session = nil
        isRunning = false
    }

    private func scheduleRestart(after seconds: TimeInterval) {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.wantRunning else { return }
            self.session = nil
            self.startIfNeeded()
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}

extension ExtendedSessionManager: WKExtendedRuntimeSessionDelegate {

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        guard extendedRuntimeSession === session else { return }
        isRunning = true
        consecutiveFailures = 0
        segmentsStarted += 1
        lastEndReason = ""
        segmentStartedAt = Date()
        // 会话上限约 1 小时，且 Apple 只允许在前台启动它 —— 到期后自己回不来。
        // 提前 10 分钟吭一声，用户点一下就能续上；不吭声就等于"悄悄死掉"。
        NotificationPlanner.shared.scheduleRenewReminder(after: 50 * 60, minutesLeft: 50)
        // 会话一起就跑一次判定，把状态立刻对齐现实
        DispatchQueue.main.async { WatchEngine.shared.tick(force: true) }
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // 只有「当前这个」会话的回调才作数。旧会话被 stop() 之后回调是异步回来的，
        // 若不加这层身份判断，它会把刚起的新会话当成自己已经结束 —— 新会话的
        // 状态被写死成没在跑，引用也被清掉，从此再也起不来。
        guard extendedRuntimeSession === session else { return }
        DispatchQueue.main.async { WatchEngine.shared.tick(force: true) }
        isRunning = false
        lastEndReason = "到期"
        NotificationPlanner.shared.cancelRenewReminder()
        scheduleRestart(after: 5)
    }

    func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: (any Error)?
    ) {
        guard extendedRuntimeSession === session else { return }
        isRunning = false
        NotificationPlanner.shared.cancelRenewReminder()
        lastEndReason = error?.localizedDescription ?? "被系统结束(reason \(reason.rawValue))"
        consecutiveFailures += 1
        // 真正连续被拒（'too many sessions' 之类限流）才退避到 2 分钟，
        // 否则 15 秒就重来 —— 后台断线要尽快接上，接不上就等于「走够了也不吭声」。
        let backoff: TimeInterval = consecutiveFailures > 4 ? 120 : 15
        scheduleRestart(after: backoff)
    }
}
