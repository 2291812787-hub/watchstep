import Foundation
import Network
import Darwin

/// 网络诊断。
///
/// 先把话说清楚：iOS / watchOS **没有**公开 API 能直接读「本 App 的无线数据（WiFi/蜂窝）
/// 有没有开」「本地网络权限有没有给」这两个开关。系统不提供查询，问就是查不到。
/// 所以这里不假装能读，而是量四样**真实可测**的东西，靠它们反推权限状态：
///
///   1. 系统给的网络路径 —— 有没有一条可用路径、走的是哪张网卡
///   2. 本进程能看到的网络接口和 IP —— 沙盒不隔离这个，有 IP 就说明网络栈是通的
///   3. BSD 原始 socket 直连 —— 绕过 URLSession 和 ATS，直接看内核怎么回答
///   4. 三个目标的 URLSession 连通性 —— 家里电脑 / 我们的公网域名 / 苹果自家探测页
///
/// 判读规则（写死在注释里，免得以后又凭感觉猜）：
///   · 接口里有 192.168/10./172. 的 IP，但 raw socket 报 EPERM/EACCES
///        → 内核级的"禁止出网"，不是没网，是权限被拒
///   · 接口里没 IP，raw socket 报 ENETUNREACH/EHOSTUNREACH
///        → 确实没有可用路由
///   · raw socket 通，但 URLSession 报 -1004
///        → 问题在 URLSession/ATS 这层
///   · 只有苹果那条失败 → 我们的服务器/隧道的问题，跟手表无关
///   · 只有家里那条失败 → 本地网络权限没给（局域网被系统拦）
enum NetDiag {

    /// 把 errno 翻成人话。光看 -1004 永远分不清"没权限"还是"没路由"。
    static func errName(_ e: Int32) -> String {
        switch e {
        case 1:  return "EPERM(权限被拒)"
        case 13: return "EACCES(权限被拒)"
        case 51: return "ENETUNREACH(无路由)"
        case 60: return "ETIMEDOUT"
        case 61: return "ECONNREFUSED(通了但没人听)"
        case 64: return "EHOSTDOWN"
        case 65: return "EHOSTUNREACH(主机不可达)"
        default: return "errno\(e)"
        }
    }

    /// CFNetwork 会把底层 POSIX 错误藏在 NSUnderlyingErrorKey 里。
    static func posixNote(_ e: NSError) -> String {
        guard let u = e.userInfo[NSUnderlyingErrorKey] as? NSError else { return "" }
        return "/" + errName(Int32(u.code))
    }

    /// 取一次网络路径快照。系统有时压根不给回调，所以带超时。
    static func pathLine(timeout: Double, completion: @escaping (String) -> Void) {
        let monitor = NWPathMonitor()
        let q = DispatchQueue(label: "watchstep.netdiag.path")
        var done = false
        let lock = NSLock()

        func once(_ line: String) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            lock.unlock()
            monitor.cancel()
            completion(line)
        }

        monitor.pathUpdateHandler = { p in
            var ifs: [String] = []
            if p.usesInterfaceType(.wifi) { ifs.append("wifi") }
            if p.usesInterfaceType(.cellular) { ifs.append("蜂窝") }
            if p.usesInterfaceType(.wiredEthernet) { ifs.append("有线") }
            let name = ifs.isEmpty ? "无网卡" : ifs.joined(separator: "+")
            if p.status == .satisfied {
                var s = "路径 通(\(name))"
                if p.isExpensive { s += " 计费" }
                if p.isConstrained { s += " 省流" }
                once(s)
            } else {
                once("路径 断(\(name))")
            }
        }
        monitor.start(queue: q)
        q.asyncAfter(deadline: .now() + timeout) { once("路径 状态未知") }
    }

    /// 本进程能看到的网络接口。沙盒不隔离 getifaddrs，
    /// 所以这里要是有 IP、连接却还是失败，就说明不是"没网"，是"不让出去"。
    static func interfaces() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "接口 读不到" }
        defer { freeifaddrs(ifaddr) }

        var parts: [String] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let f = cur.pointee
            if let a = f.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let rc = getnameinfo(a, socklen_t(a.pointee.sa_len),
                                     &host, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST)
                if rc == 0 {
                    let name = String(cString: f.ifa_name)
                    let ip = String(cString: host)
                    if !ip.hasPrefix("127.") { parts.append("\(name)=\(ip)") }
                }
            }
            p = f.ifa_next
        }
        return parts.isEmpty ? "接口 无IPv4" : "接口 " + parts.joined(separator: " ")
    }

    /// 绕过 URLSession/ATS，直接开 BSD socket 连过去，看内核给什么 errno。
    /// 这是唯一能区分「沙盒禁止出网」和「没有路由」的办法。
    static func rawConnect(_ ip: String, _ port: UInt16, _ label: String,
                           timeoutMs: Int32 = 5000) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return "\(label) socket失败 \(errName(errno))" }
        defer { close(fd) }

        var sa = sockaddr_in()
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        if inet_pton(AF_INET, ip, &sa.sin_addr) != 1 {
            return "\(label) 地址解析失败"
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = withUnsafePointer(to: &sa) { sp in
            sp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return "\(label) 通" }
        let e = errno
        if e != EINPROGRESS { return "\(label) 被拒 \(errName(e))" }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let s = poll(&pfd, 1, timeoutMs)
        if s == 0 { return "\(label) 超时" }
        if s < 0 { return "\(label) poll失败 \(errName(errno))" }

        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0 ? "\(label) 通" : "\(label) 被拒 \(errName(err))"
    }

    /// 三个目标一起打，谁先回来都算。
    /// 注意这里**不能**用上传那个 session：它开了 waitsForConnectivity，
    /// 没有可用路径时会一直等着，把 150ms 的失败拖成 39 秒（实测过）。
    /// 探测必须快速失败，才能看清错误码。
    static let probeSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 10
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func hits(timeout: Double, completion: @escaping ([String]) -> Void) {
        let targets: [(String, String)] = [
            ("局域", "http://192.168.31.82:8085/health"),
            ("公网", "https://watch.webchangming.top/health"),
            ("苹果", "https://captive.apple.com/hotspot-detect.html"),
        ]
        var out = [String](repeating: "", count: targets.count)
        let lock = NSLock()
        let group = DispatchGroup()

        for (i, t) in targets.enumerated() {
            guard let url = URL(string: t.1) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = timeout
            req.cachePolicy = .reloadIgnoringLocalCacheData
            group.enter()
            let t0 = Date()
            probeSession.dataTask(with: req) { _, resp, err in
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                var line: String
                if let e = err as NSError? {
                    line = "\(t.0) ✗\(e.code)\(posixNote(e)) \(ms)ms"
                } else if let h = resp as? HTTPURLResponse {
                    line = "\(t.0) \(h.statusCode) \(ms)ms"
                } else {
                    line = "\(t.0) ? \(ms)ms"
                }
                lock.lock(); out[i] = line; lock.unlock()
                group.leave()
            }.resume()
        }

        group.notify(queue: .main) { completion(out.filter { !$0.isEmpty }) }
    }

    /// 完整一轮：路径 → 接口 → 原始socket直连 → 三个目标。
    /// 底层直连最多各 5 秒，所以放后台队列，别卡住界面。
    static func run(hitTimeout: Double = 12, completion: @escaping ([String]) -> Void) {
        pathLine(timeout: 2.0) { pl in
            DispatchQueue.global(qos: .userInitiated).async {
                let ifs = interfaces()
                let raw = [
                    rawConnect("192.168.31.82", 8085, "直连家里"),
                    rawConnect("1.1.1.1", 443, "直连1.1.1.1"),
                    rawConnect("223.5.5.5", 53, "直连223.5.5.5"),
                ]
                hits(timeout: hitTimeout) { hl in
                    completion([pl, ifs] + raw + hl)
                }
            }
        }
    }
}
