import Foundation
import Darwin

/// 网络诊断。
///
/// 先说两个**必须记住的假警报**（这两条在 watchOS 沙盒里永远不准，别被它们带偏）：
///
///   1. `NWPathMonitor` 会报「断(无网卡)」，哪怕 App 明明有 Wi-Fi 和 IP。
///      实测过：自检页显示「路径 断(无网卡)」，而同一时刻三个目标全部返回 200。
///      所以路径状态**不能**当判据，只能当参考。
///   2. 直接开 BSD socket 连出去必然 `EHOSTUNREACH`。沙盒不允许 App 自己做原始
///      网络连接，路由表对它不可见。这跟有没有网毫无关系，也是纯假警报。
///
/// 真正可信的判据只有一个：**用 URLSession 打真实目标，看 HTTP 状态码**。
/// 所以这里只留两样东西 —— 接口清单（证明系统给没给 IP）和三个目标的实测结果。
///
/// 判读规则：
///   · 三个全 200                 → 网络没问题，故障在别处（服务器/隧道/代码）
///   · 只有苹果失败               → 我们的域名或隧道有问题，跟手表无关
///   · 只有家里那条失败           → 本地网络权限没给
///   · 全失败且接口无 IP          → 真的没连网
///   · 报 -1001 且耗时几十秒      → 请求被挂住，多半是 waitsForConnectivity 之类
///                                  在等路径（这个坑踩过，能挂 39 秒）
enum NetDiag {

    /// 把 errno / NSURLError 翻成人话。光看 -1004 分不清"没权限"还是"没路由"。
    static func errName(_ e: Int32) -> String {
        switch e {
        case 1:  return "EPERM(权限被拒)"
        case 13: return "EACCES(权限被拒)"
        case 51: return "ENETUNREACH(无路由)"
        case 60: return "ETIMEDOUT"
        case 61: return "ECONNREFUSED(通了但没人听)"
        case 65: return "EHOSTUNREACH"
        default: return "errno\(e)"
        }
    }

    /// CFNetwork 会把底层 POSIX 错误藏在 NSUnderlyingErrorKey 里。
    static func posixNote(_ e: NSError) -> String {
        guard let u = e.userInfo[NSUnderlyingErrorKey] as? NSError else { return "" }
        return "/" + errName(Int32(u.code))
    }

    /// 本进程能看到的 IPv4 接口。有 192.168/10./172. 地址就说明系统确实给了网。
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

    /// 探测必须等路径，不能快速失败。
    ///
    /// 血泪教训：watchOS 上 NWPathMonitor 会报「断(无网卡)」，哪怕 en0 明明有
    /// 192.168.31.x 的 IP、三个目标全 200 —— 这个信号不可信。而
    /// waitsForConnectivity = false 时，CFNetwork 就按这个不可信的路径判定
    /// 当场拒绝，表现为三个目标一起在 150ms 左右返回 -1004（连苹果都一样）。
    ///
    /// 所以这里改成等路径：网络其实是通的，等一下就能连上。
    /// 用 timeoutIntervalForResource 兜底等待时长，避免挂死太久。
    static let probeSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 15
        c.allowsExpensiveNetworkAccess = true
        c.allowsConstrainedNetworkAccess = true
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// 三个目标一起打，谁先回来都算。这才是唯一可信的判据。
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

    /// 完整一轮：接口清单 + 三个目标实测。
    static func run(hitTimeout: Double = 10, completion: @escaping ([String]) -> Void) {
        let ifs = interfaces()
        hits(timeout: hitTimeout) { hl in
            var lines = [ifs]
            lines.append(contentsOf: hl)
            // 三条全绿就别再让人担心了，直接给个结论，省得又盯着中间状态瞎猜。
            if hl.count >= 3 && hl.allSatisfy({ !$0.contains("✗") }) {
                lines.append("结论 网络正常")
            }
            completion(lines)
        }
    }
}
