import Foundation
import UserNotifications

/// 把真实错误写进 Documents/diag.log：装完可用 AFC 直接拉出来看。
/// 目的只有一个——不再靠猜。写失败绝不能影响主流程。
enum NetLog {
    private static let q = DispatchQueue(label: "netlog")
    private static let maxLines = 400

    static func rec(_ line: String) {
        q.async {
            guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return }
            let u = dir.appendingPathComponent("diag.log")
            var lines = (try? String(contentsOf: u, encoding: .utf8))?
                .components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
            let df = DateFormatter()
            df.dateFormat = "MM-dd HH:mm:ss"
            lines.append("\(df.string(from: Date())) \(line)")
            if lines.count > maxLines { lines = Array(lines.suffix(maxLines)) }
            try? (lines.joined(separator: "\n") + "\n").write(to: u, atomically: true, encoding: .utf8)
        }
    }

    static func mark(_ what: String) { rec("[\(what)] v\(ver())") }

    /// 冷启动记录环境：网卡地址 + 通知授权。这两样是「能发出去」与「能弹出来」的全部前提。
    static func snapshot() {
        rec("网卡: \(ifaces())")
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let m: [UNAuthorizationStatus: String] = [
                .notDetermined: "未询问", .denied: "已拒绝",
                .authorized: "已允许", .provisional: "临时"
            ]
            rec("通知授权=\(m[s.authorizationStatus] ?? "未知\(s.authorizationStatus.rawValue)")")
        }
    }

    static func describe(_ tag: String, _ err: Error?) -> String {
        guard let e = err as NSError? else { return "ok" }
        let u = e.userInfo.keys.sorted().map { k in "\(k)=\(e.userInfo[k] ?? "")" }.joined(separator: ";")
        return "err \(e.domain)/\(e.code) \(e.localizedDescription) {\(u)}"
    }

    static func ifaces() -> String {
        var out: [String] = []
        var p: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&p) == 0, let first = p else { return "读取失败" }
        defer { freeifaddrs(p) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let i = cur {
            let f = i.pointee
            let name = String(cString: f.ifa_name)
            if f.ifa_addr?.pointee.sa_family == UInt8(AF_INET), name != "lo0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(f.ifa_addr, socklen_t(f.ifa_addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    out.append("\(name)=\(String(cString: host))")
                }
            }
            cur = f.ifa_next
        }
        return out.isEmpty ? "无IPv4" : out.joined(separator: " ")
    }

    private static func ver() -> String {
        let s = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(s)(\(b))"
    }
}
