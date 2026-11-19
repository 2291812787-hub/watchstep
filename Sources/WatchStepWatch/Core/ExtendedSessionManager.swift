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
    @Published private(set) var segmentsStarted: Int = 0

    private var session: WKExtendedRuntimeSession?
    private var wantRunning = false
    private var restartWorkItem: DispatchWorkItem?

    /// 独立的时段闸门，由引擎注入。
    ///
    /// 为什么需要它：原来「关会话」只有一条链——
    /// `tick → CMPedometer 回调 → reconcileNotifications → setDesired(false)`。
    /// 但**续期不走这条链**：`WillExpire → scheduleRestart → guard wantRunning`。
    /// 只要那条链有一次没走通（查询回调没回来、busy 卡住、进程被冻结），
    /// `wantRunning` 就一直是 true，会话一小时接一小时地续，整夜都在跑。
    /// 1–2%/小时的代价，睡一觉就是十几个点。
    ///
    /// 这道闸门直接读 Config 的生效时段，不经过任何 tick 链路，
    /// 所以任何时候续期都会先被它挡住。
    var shouldRun: (() -> Bool)?

    /// 此刻到底该不该占着延长运行时。两道条件缺一不可。
    private func allowedNow() -> Bool {
        guard wantRunning else { return false }
        if let gate = shouldRun, !gate() { return false }
        return true
    }
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
        // 闸门先过一遍：wantRunning 可能是几小时前设的，此刻早已出了生效时段。
        guard allowedNow(), !isRunning, session == nil else { return }
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
            guard let self = self else { return }
            // 闸门在这里再挡一次：这是「整夜耗电」的最后一个缺口。
            // 到期回调 → 5 秒后重启 → 如果此刻已经出了生效时段，必须就此收手，
            // 否则每小时续一段，睡一觉 8 小时全在跑。
            guard self.allowedNow() else {
                self.session = nil
                self.isRunning = false
                self.lastEndReason = "时段外，不续"
                return
            }
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
        scheduleRestart(after: 5)
    }

    func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: (any Error)?
    ) {
        guard extendedRuntimeSession === session else { return }
        isRunning = false
        lastEndReason = error?.localizedDescription ?? "被系统结束(reason \(reason.rawValue))"
        consecutiveFailures += 1
        // 真正连续被拒（'too many sessions' 之类限流）才退避到 2 分钟，
        // 否则 15 秒就重来 —— 后台断线要尽快接上，接不上就等于「走够了也不吭声」。
        let backoff: TimeInterval = consecutiveFailures > 4 ? 120 : 15
        scheduleRestart(after: backoff)
    }
}
