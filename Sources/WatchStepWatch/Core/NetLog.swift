import Foundation

/// 把真实错误落成文件，装完可以直接用 AFC 拉出来看。
/// 目的是不再靠「路径 unsatisfied」这种自己都标过「不可信」的信号下结论，
/// 而是要 NSError 的 domain / code / userInfo 原件。
enum NetLog {
    private static let url: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return d.appendingPathComponent("diag.log")
    }()

    private static let q = DispatchQueue(label: "netlog")

    static func add(_ msg: String) {
        let line = "\(stamp()) \(msg)\n"
        q.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8) ?? Data())
                try? h.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    /// 把 NSError 拆成能直接判读的一行。
    static func describe(_ tag: String, _ err: Error?) -> String {
        guard let e = err as NSError? else { return "\(tag) ok" }
        var extra = ""
        if let u = e.userInfo as? [String: Any] {
            let keys = ["NSURLErrorFailingURLStringErrorKey",
                        "_NSURLErrorFailingURLStringErrorKey",
                        "NSErrorPeerAddressKey",
                        "_kCFStreamErrorDomainKey",
                        "_kCFStreamErrorCodeKey"]
            let parts = keys.compactMap { k -> String? in
                guard let v = u[k] else { return nil }
                return "\(k)=\(v)"
            }
            if !parts.isEmpty { extra = " | " + parts.joined(separator: " ") }
        }
        return "\(tag) ERR domain=\(e.domain) code=\(e.code) desc=\(e.localizedDescription)\(extra)"
    }

    /// 当前所有网卡的名字与地址，用来确认 en0 到底有没拿到 IP。
    static func ifaces() -> String {
        var out: [String] = []
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return "ifaces=?" }
        defer { freeifaddrs(addrs) }
        var p = first
        while true {
            let i = p.pointee
            let name = String(cString: i.ifa_name)
            if let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    out.append("\(name)=\(String(cString: host))")
                }
            }
            guard let n = i.ifa_next else { break }
            p = n
        }
        return out.sorted().joined(separator: " ")
    }
}
