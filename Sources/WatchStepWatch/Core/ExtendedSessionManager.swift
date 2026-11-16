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

    private override init() { super.init() }

    func setDesired(_ on: Bool) {
        wantRunning = on
        if on { startIfNeeded() } else { stop() }
    }

    func startIfNeeded() {
        guard wantRunning, !isRunning, session == nil else { return }
        let s = WKExtendedRuntimeSession()
        s.delegate = self
        session = s
        s.start()
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
        isRunning = true
        segmentsStarted += 1
        lastEndReason = ""
        // 会话一起就跑一次判定，把状态立刻对齐现实
        DispatchQueue.main.async { WatchEngine.shared.tick(force: true) }
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // 到期前把通知排好，接着尝试续一段
        DispatchQueue.main.async { WatchEngine.shared.tick(force: true) }
        isRunning = false
        lastEndReason = "到期"
        scheduleRestart(after: 5)
    }

    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith error: (any Error)?) {
        isRunning = false
        lastEndReason = error?.localizedDescription ?? "被系统结束"
        // 连续被拒时不要死磕（会有 'too many sessions' 之类的限流），退避到 2 分钟
        let backoff: TimeInterval = segmentsStarted > 6 ? 120 : 15
        scheduleRestart(after: backoff)
    }
}
