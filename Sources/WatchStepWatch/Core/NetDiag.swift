import Foundation
import Network

/// 网络诊断。
///
/// 先把话说清楚：iOS / watchOS **没有**公开 API 能直接读「本 App 的无线数据（WiFi/蜂窝）
/// 有没有开」「本地网络权限有没有给」这两个开关。系统不提供查询，问就是查不到。
/// 所以这里不假装能读，而是量三样**真实可测**的东西，靠它们反推权限状态：
///
///   1. 系统给的网络路径 —— 有没有一条可用路径、走的是哪张网卡
///   2. 三个目标的真实连通性 —— 家里电脑(局域网) / 我们自己的公网域名 / 苹果自家探测页
///   3. 失败时的底层 errno —— 区分"没权限"和"没有路"
///
/// 判读规则（写死在注释里，免得以后又凭感觉猜）：
///   · 苹果那条也失败  → 这个进程根本发不出任何网络请求 = 权限层被拒
///   · 只有家里那条失败 → 本地网络权限没给（局域网被系统拦）
///   · 只有公网域名失败 → 隧道或服务器的问题，跟手表无关
///   · 路径断且无网卡  → 确实没连网（这才会同时打不通所有目标）
///   · errno 是 EPERM/EACCES → 权限被拒；ENETUNREACH/EHOSTUNREACH → 没有路由
enum NetDiag {

    /// CFNetwork 把底层的 POSIX 错误藏在 NSUnderlyingErrorKey 里。
    /// 光看 -1004 永远分不清"没权限"还是"没路由"，加上 errno 就能分。
    static func posixNote(_ e: NSError) -> String {
        guard let u = e.userInfo[NSUnderlyingErrorKey] as? NSError else { return "" }
        let s: String
        switch u.code {
        case 1:  s = "EPERM"          // 权限被拒
        case 13: s = "EACCES"         // 权限被拒
        case 51: s = "ENETUNREACH"    // 没有可用路由
        case 60: s = "ETIMEDOUT"
        case 61: s = "ECONNREFUSED"   // 通了但对面没人听
        case 65: s = "EHOSTUNREACH"
        default: s = "errno\(u.code)"
        }
        return "/\(s)"
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
                var s = "网络 通(\(name))"
                if p.isExpensive { s += " 计费" }
                if p.isConstrained { s += " 省流" }
                // 走蜂窝说明无线数据是通的；走 wifi 说明 wifi 那侧没问题。
                once(s)
            } else {
                once("网络 断(\(name))")
            }
        }
        monitor.start(queue: q)
        q.asyncAfter(deadline: .now() + timeout) { once("网络 状态未知") }
    }

    /// 三个目标一起打，谁先回来都算。
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
            StepsUploader.session.dataTask(with: req) { _, resp, err in
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

    /// 完整一轮：先看路径，再打三个目标。
    static func run(hitTimeout: Double = 12, completion: @escaping ([String]) -> Void) {
        pathLine(timeout: 2.0) { pl in
            hits(timeout: hitTimeout) { hl in
                completion([pl] + hl)
            }
        }
    }
}
