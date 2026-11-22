import Foundation
#if canImport(Network)
import Network
#endif

/// 主动联网网关 —— 把「被动等系统允许」换成「先真发，失败了主动重连再发」。
///
/// ## 为什么要这么改（4.13 及以前的根因）
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
/// 4.13 的表现完全对得上：三条自检全部 -1001、耗时同一个 15046ms
/// （= resource 15 秒），失败码不是 -1004 也不是 -1009；en0 有 192.168.x
/// 地址；上传自 18:02:58 起零请求。请求根本没发出去，只是在同一个
/// 等待终点一起超时。偶尔「忽然就好了」是别的进程顺带点亮了路径。
///
/// ## 4.14 第一版踩的坑（-999 / 18ms）
///
/// 上传和诊断共用同一个 session，任何一方失败就 `invalidateAndCancel`
/// 整条会话 —— 把另一方**正在飞**的请求一起砍了，立刻返回 -999
/// （NSURLErrorCancelled），耗时只有十几毫秒。诊断页三条同时 -999 就是
/// 被上传那边的重建误杀。
///
/// 所以现在：
///   · 上传和探针各走各的通道（`Lane`），互不 cancel；
///   · 重建用 `finishTasksAndInvalidate()`，让在飞的请求跑完再退休，
///     绝不把并发请求变成假的 -999；
///   · 只有「路径刚变可用」这种真正需要立刻补发的场景，才由监听触发。
final class NetGateway {

    static let shared = NetGateway()

    /// 两条互不干扰的通道。上传被重建不该影响诊断，反之亦然。
    enum Lane: Hashable {
        /// 步数上报。失败要重试，重试要能换 session。
        case upload
        /// 自检探针。用户手动点的诊断，绝不能被后台的续传打断。
        case probe
    }

    private let lock = NSLock()
    private var sessions: [Lane: URLSession] = [:]
    private var generation: [Lane: Int] = [:]
    private var monitors: [Lane: NWPathMonitor] = [:]
    private var rebuilds: [Lane: Int] = [:]

    /// 自检页显示用：这一路一共主动重建了几次 session。
    func rebuildCount(_ lane: Lane = .upload) -> Int {
        lock.lock(); defer { lock.unlock() }
        return rebuilds[lane] ?? 0
    }

    /// 最近一次失败的 NSURLError code（0 = 最近一次没失败）。
    private(set) var lastCode = 0
    /// 路径监听看到的最后状态，只作参考，不当判据（watchOS 上它经常骗人）。
    private(set) var lastPath = "未启动"

    private init() {
        for lane in [Lane.upload, Lane.probe] {
            sessions[lane] = Self.make()
            generation[lane] = 0
            rebuilds[lane] = 0
        }
        // 一启动就挂监听：路径从「不就绪」跳到「就绪」的那一刻，
        // 就是用户说的「忽然允许了」，要能立刻补发，而不是等下一个整点。
        startMonitor(.upload)
    }

    private static func make() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        // 核心那一行：不被动等。
        c.waitsForConnectivity = false
        // 快失败。真正的重试由 fetch 负责，而不是让一个请求干挂 30 秒。
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

    func current(_ lane: Lane = .upload) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        return sessions[lane] ?? Self.make()
    }

    /// 主动重连：换一条新会话（重新评估路径 = 再向系统要一次），旧的处理完自然退休。
    ///
    /// **不用 invalidateAndCancel。** 那是 4.14 第一版把诊断误杀成 -999 的原因：
    /// 它会把这条通道上所有正在飞的请求立刻取消。`finishTasksAndInvalidate()`
    /// 只拒绝新任务，在飞的跑完或超时，语义正好。
    @discardableResult
    func rebuild(_ lane: Lane = .upload) -> URLSession {
        lock.lock()
        let old = sessions[lane]
        sessions[lane] = Self.make()
        generation[lane, default: 0] += 1
        rebuilds[lane, default: 0] += 1
        let g = generation[lane] ?? 0
        lock.unlock()

        old?.finishTasksAndInvalidate()
        if lane == .upload { startMonitor(lane) }
        return current(lane)
    }

    /// 路径监听。只听「变可用了」，把它当补发扳机，不当判据。
    ///
    /// watchOS 上它会报「断(无网卡)」，而同一时刻三个目标全 200 —— 这个信号
    /// 本身不可信。但它从「不就绪」跳到「就绪」的**那一刻**是有用的：
    /// 那正好就是用户说的「忽然允许了」，抓住它比等超时强。
    private func startMonitor(_ lane: Lane) {
        #if canImport(Network)
        lock.lock()
        monitors[lane]?.cancel()
        let m = NWPathMonitor()
        monitors[lane] = m
        let g = generation[lane] ?? 0
        lock.unlock()

        m.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.lock.lock()
            let cur = self.generation[lane] ?? 0
            self.lock.unlock()
            // 只认当前这一代监听的结论，旧的直接丢。
            guard cur == g else { return }

            let usable = (path.status == .satisfied)
            self.lastPath = usable ? "可用" : "\(path.status)"
            if usable {
                DispatchQueue.main.async { NetGateway.notifyUsable() }
            }
        }
        m.start(queue: DispatchQueue(label: "netgw.path.\(lane.hashValue).\(g)"))
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
    func fetchOnce(_ req: URLRequest, lane: Lane = .upload,
                   done: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        current(lane).dataTask(with: req) { [weak self] data, resp, err in
            self?.lock.lock()
            if let e = err as NSError? { self?.lastCode = e.code } else { self?.lastCode = 0 }
            self?.lock.unlock()
            done(data, resp as? HTTPURLResponse, err)
        }.resume()
    }

    /// 主动重试：每次失败都换一条新会话再打。
    ///
    /// `delays` 的第一项是第一次尝试前的等待（通常 0）。每次失败都重建 ——
    /// 重建不是为了「刷新连接」，是为了**扔掉那个已经判定路径不可用的会话**，
    /// 让系统重新走一遍网络分配。这是「主动要」和「被动等」的全部区别。
    func fetch(_ req: URLRequest, lane: Lane = .upload,
               delays: [Double] = [0, 1.5, 4, 10],
               done: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        var queue = delays
        guard !queue.isEmpty else {
            fetchOnce(req, lane: lane, done: done)
            return
        }
        let wait = queue.removeFirst()
        let remaining = queue

        let run = { [weak self] in
            guard let self = self else { return }
            self.fetchOnce(req, lane: lane) { data, resp, err in
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
                self.rebuild(lane)
                self.fetch(req, lane: lane, delays: remaining, done: done)
            }
        }

        if wait <= 0 {
            run()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: run)
        }
    }
}
