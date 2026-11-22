import Foundation
#if canImport(Network)
import Network
#endif

/// 主动联网网关 —— 把「被动等系统允许」换成「先真发，失败了主动重连再发」。
///
/// ## 为什么必须这么改
///
/// `URLSessionConfiguration.waitsForConnectivity = true` 的语义是：
/// **不自己建连，先挂着，等系统通知路径可用再发。**
///
/// 在 watchOS 上这会形成死锁：
///
///     App 不真建连
///        → 系统没看到它在请求网络，于是不分配网络能力
///        → 路径永远不就绪
///        → 它永远在等路径就绪
///        → 请求一直 pending，直到 timeoutIntervalForResource 到点
///
/// 表现完全能对上用户看到的现象：
///   · 所有请求在**同一个毫秒数**上失败（15000ms / 30000ms 一模一样），
///     说明它们根本没发出去，只是在同一个等待终点一起超时；
///   · 失败码固定 -1001，不是 -1004（连不上）也不是 -1009（未联网）；
///   · 手表明明有 IP（en0 = 192.168.x），换 Wi-Fi、换 5G 都一样 ——
///     因为它压根没在请求网络，它在等一个只有「先请求」才会出现的许可；
///   · 偶尔「忽然就好了」，是别的进程或系统唤醒顺带把路径点亮了，
///     那一次请求被放行。这就是用户说的「有时候行，大部分时候不行」。
///
/// 所以这里反过来做：
///   1. `waitsForConnectivity = false` —— 立刻真发，让系统看见；
///   2. 超时压到 8 秒，失败得快，不占用 App 的唤醒时间；
///   3. 失败就 `invalidateAndCancel` 掉整个 session（连它缓存的那份
///      「路径不可用」判断一起扔掉），换一个全新的 session 再发 ——
///      新 session 会重新评估路径，等于主动再要一次；
///   4. 常驻一个 `NWPathMonitor`，路径一变成可用就立刻补发，
///      不用等到下一次整点或下一次超时；
///   5. 三条网络通道全部显式放开：Wi-Fi、蜂窝、昂贵/受限网络
///      （低电量模式、漫游、热点），不依赖默认值。
///
/// 面板上要能看见「重连了几次」，否则又变成猜。
final class NetGateway {

    static let shared = NetGateway()

    private let lock = NSLock()
    private var session: URLSession
    private var generation = 0
    private var monitors: [NWPathMonitor] = []

    /// 自检页显示用：这次进程里一共主动重建了几次 session。
    private(set) var rebuildCount = 0
    /// 最近一次失败的 NSURLError code（0 = 最近一次没失败）。
    private(set) var lastCode = 0
    /// 路径监听看到的最后状态，只作参考，不当判据（watchOS 上它经常骗人）。
    private(set) var lastPath = "未启动"

    private init() {
        session = Self.make()
        // 一启动就挂一路监听：路径从「不就绪」跳到「就绪」的那一刻，
        // 就是用户说的「忽然允许了」，要能立刻补发，而不是等下一个整点。
        startMonitor(0)
    }

    private static func make() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        // 核心那一行：不被动等。
        c.waitsForConnectivity = false
        // 快失败。真正的重试由下面的 fetch 负责，而不是让一个请求干挂 30 秒。
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 12
        // 三条通道全开：Wi-Fi、蜂窝、昂贵/受限网络。
        // 不显式写就是靠默认值，而「默认」正是出问题时最说不清的地方。
        c.allowsCellularAccess = true
        c.allowsExpensiveNetworkAccess = true
        c.allowsConstrainedNetworkAccess = true
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpShouldUsePipelining = true
        return URLSession(configuration: c)
    }

    func current() -> URLSession {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    /// 主动重连：扔掉旧 session（连同它记住的「路径不可用」），换新的，再挂一路监听。
    @discardableResult
    func rebuild() -> URLSession {
        lock.lock()
        let old = session
        session = Self.make()
        generation += 1
        rebuildCount += 1
        let g = generation
        lock.unlock()

        old.invalidateAndCancel()
        startMonitor(g)
        return current()
    }

    /// 路径监听。只听「变可用了」，把它当补发扳机，不当判据。
    ///
    /// watchOS 上它会报「断(无网卡)」，而同一时刻三个目标全 200 —— 这个信号
    /// 本身不可信。但它从「不就绪」跳到「就绪」的**那一刻**是有用的：
    /// 那正好就是用户说的「忽然允许了」，抓住它比等超时强。
    private func startMonitor(_ g: Int) {
        #if canImport(Network)
        lock.lock()
        monitors.forEach { $0.cancel() }
        monitors.removeAll()
        let m = NWPathMonitor()
        monitors.append(m)
        lock.unlock()

        m.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.lock.lock()
            let cur = self.generation
            self.lock.unlock()
            // 只认当前这一代 session 的监听，旧的直接丢。
            guard cur == g else { return }

            let usable = (path.status == .satisfied)
            self.lastPath = usable ? "可用" : "\(path.status)"
            if usable {
                DispatchQueue.main.async { NetGateway.notifyUsable() }
            }
        }
        m.start(queue: DispatchQueue(label: "netgw.path.\(g)"))
        #else
        lastPath = "无 Network 框架"
        #endif
    }

    // MARK: - 补发订阅

    private static var waiters: [() -> Void] = []
    private static let waiterLock = NSLock()

    /// 路径刚变可用时会被调一次。用来「一有许可就立刻补发」，而不是等下一个时点。
    static func whenUsable(_ f: @escaping () -> Void) {
        waiterLock.lock()
        waiters.append(f)
        waiterLock.unlock()
    }

    static func notifyUsable() {
        waiterLock.lock()
        let list = waiters
        waiters.removeAll()
        waiterLock.unlock()
        list.forEach { $0() }
    }

    // MARK: - 请求

    /// 打一次，不重试。给需要自己控制节奏的调用方（自检的三目标并行）。
    func fetchOnce(_ req: URLRequest, done: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        current().dataTask(with: req) { [weak self] data, resp, err in
            if let e = err as NSError? {
                self?.lock.lock(); self?.lastCode = e.code; self?.lock.unlock()
            } else {
                self?.lock.lock(); self?.lastCode = 0; self?.lock.unlock()
            }
            done(data, resp as? HTTPURLResponse, err)
        }.resume()
    }

    /// 主动重试：每次失败都换一个新 session 再打。
    ///
    /// `delays` 的第一项是第一次尝试前的等待（通常 0）。每一项之后都重建 session ——
    /// 重建不是为了「刷新连接」，是为了**扔掉那个已经判定路径不可用的 session**，
    /// 让系统重新走一遍网络分配。这是「主动要」和「被动等」的全部区别。
    func fetch(_ req: URLRequest,
               delays: [Double] = [0, 1.5, 4, 10],
               done: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        var queue = delays
        guard !queue.isEmpty else {
            fetchOnce(req, done: done)
            return
        }
        let wait = queue.removeFirst()
        let remaining = queue

        let run = { [weak self] in
            guard let self = self else { return }
            self.fetchOnce(req) { data, resp, err in
                // 只要拿到了 HTTP 响应就算通，哪怕 401/500 —— 那是服务器在说话，
                // 说明网络这一层已经成立，再重连没有意义。
                if resp != nil || err == nil {
                    done(data, resp, err)
                    return
                }
                if remaining.isEmpty {
                    done(data, resp, err)
                    return
                }
                self.rebuild()
                self.fetch(Self.rebuilt(req), delays: remaining, done: done)
            }
        }

        if wait <= 0 {
            run()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: run)
        }
    }

    /// 重建后的请求原样返回（URLRequest 是值类型，重发安全）。
    private static func rebuilt(_ r: URLRequest) -> URLRequest { r }
}
