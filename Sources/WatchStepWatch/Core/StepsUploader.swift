import Foundation
import CoreMotion

/// 把当天步数推到 https://watch.webchangming.top
///
/// 触发点：8:00–23:30 每小时一个点（共 17 个）。判定放在 tick 里做 ——
/// 手表不保证到点就醒，所以用「到点之后第一次 tick」补发，每个点只发一次
/// （存档 date#slot），失败退避 60 秒再试。
///
/// 网络这块刻意保持 2.4(14) 的样子：只走 HTTPS 公网，一个 endpoint，
/// URLSession.shared，超时 20 秒。那一版是实测能通的（服务器收到了
/// 09:55 / 10:23 两条，src_ip 127.0.0.1，说明走的就是云隧道）。
/// 后来加过「局域网明文直连 + ATS 放开」，结果 ATS 那个 NSAllowsLocalNetworking
/// 会把 NSAllowsArbitraryLoads 顶掉，局域网反而一直连不上，还把配置搞复杂了。
/// 现在不再碰局域网。
final class StepsUploader {

    static let shared = StepsUploader()

    private let endpoint = URL(string: "https://watch.webchangming.top/steps")!
    private let token = "c7bb1f13a7b29c53e81836d66a6afded"

    /// 专用 session：**必须** waitsForConnectivity = true。
    ///
    /// 这台手表的路径状态会波动：NWPathMonitor 经常报「无网卡」，但同一时刻
    /// 实测三个目标全 200（3.1 的截图就是这样）。把 waitsForConnectivity 关掉后，
    /// 一旦路径被判未就绪，请求立刻被拒，表现为 150ms 就返回 -1004，连
    /// captive.apple.com 都连不上 —— 看起来像"全断"，其实网络是好的，只是没人等。
    ///
    /// 之前那个 38.9 秒挂死是另一回事：等路径期间 timeoutIntervalForRequest
    /// 不生效，必须靠 timeoutIntervalForResource 兜底。所以两个都设。
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }()

    /// 每天推送的时点（本地时区）
    /// 8:00–23:00 每小时整点，末尾补 23:30。
    /// 原来只有 6 个点（9/12/15/18/21/23:30）：手表靠系统唤醒，某个点醒不来就少报
    /// 3~6 小时。改成每小时之后最多只差 1 小时；而且每条上报的都是当天累计值，
    /// 后一条天然顶掉前一条，漏点不需要补。
    static let slots: [(hour: Int, minute: Int)] = {
        var out: [(hour: Int, minute: Int)] = []
        for h in 8...23 { out.append((h, 0)) }
        out.append((23, 30))
        return out
    }()

    private let kLastSent = "upload.lastSentSlot"
    private let kLastAttempt = "upload.lastAttemptAt"
    private let kLastSlotAttempt = "upload.lastAttemptSlot"
    private let kLastResult = "upload.lastResult"
    private let kLastOK = "upload.lastOKAt"
    private let kLastSteps = "upload.lastSteps"

    private let defaults = UserDefaults.standard
    private var inFlight = false

    /// 起飞时刻。请求挂住时（watchOS 随时可能把进程冻住，回调永远不来）
    /// inFlight 会永远是 true，于是之后每次 tick 都在闸门前 return，再也不重试。
    /// 超过 45 秒一律当作已经失败。
    private var inFlightAt: Date?
    private let pedometer = CMPedometer()

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        f.timeZone = .current
        return f
    }()

    // MARK: - tick 入口

    func tickIfNeeded(now: Date) {
        guard CMPedometer.isStepCountingAvailable() else { return }
        guard let slot = latestPassedSlot(now: now) else { return }

        let key = "\(Self.dayFmt.string(from: now))#\(slot)"
        if defaults.string(forKey: kLastSent) == key { return }
        if inFlight {
            if let t = inFlightAt, now.timeIntervalSince(t) < 45 { return }
            // 挂太久了，当它已经死了
            inFlight = false
        }

        // 同一个点失败后退避 60 秒，别把每次 tick 都拿去撞网络
        if defaults.string(forKey: kLastSlotAttempt) == key,
           let last = defaults.object(forKey: kLastAttempt) as? Date,
           now.timeIntervalSince(last) < 60 {
            return
        }

        inFlight = true
        inFlightAt = now
        defaults.set(key, forKey: kLastSlotAttempt)
        defaults.set(now, forKey: kLastAttempt)

        let start = Calendar.current.startOfDay(for: now)
        pedometer.queryPedometerData(from: start, to: now) { [weak self] data, error in
            guard let self = self else { return }
            let steps = data?.numberOfSteps.intValue ?? -1
            var note = ""
            if let error = error {
                note = "pedometer error: \(error.localizedDescription)"
            } else if steps < 0 {
                note = "no pedometer data"
            }
            self.post(now: now, slot: slot, steps: max(steps, 0), key: key, note: note)
        }
    }

    /// 今天已经过去的最晚那个时点；还没到 8:00 返回 nil
    private func latestPassedSlot(now: Date) -> Int? {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        var found: Int? = nil
        for (i, s) in Self.slots.enumerated() where minutes >= s.hour * 60 + s.minute {
            found = i
        }
        return found
    }

    private func post(now: Date, slot: Int, steps: Int, key: String, note: String) {
        // inFlight 一直保持 true 到回调回来，避免重复发。
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Watch-Token")

        var body: [String: Any] = [
            "steps": steps,
            "date": Self.dayFmt.string(from: now),
            "slot": slot,
            "device": "watch",
        ]
        if !note.isEmpty { body["note"] = note }
        body["sent_at"] = ISO8601DateFormatter().string(from: now)
        // 诊断：把表上主 bundle 的 PlugIns 目录列出来随上报带走。
        // 表盘复杂功能是 appex，装在 WatchStepWatch.app/PlugIns 下。
        // iloader 的二进制里没有 "appex" 字样，它很可能不单独签名扩展；
        // 未签名的扩展系统会拒绝加载 → 表盘那一格渲染不出来。
        // 这一行能让服务端日志直接回答「appex 到没到表上」，不用靠猜。
        body["plugins"] = Self.pluginManifest()
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Self.session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            self.inFlight = false
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let stamp = Self.clock.string(from: Date())
            if let err = err {
                let ns = err as NSError
                self.defaults.set("\(stamp) 失败 slot\(slot) code\(ns.code) \(err.localizedDescription)",
                                  forKey: self.kLastResult)
                return
            }
            if code == 200 || code == 201 {
                self.defaults.set(key, forKey: self.kLastSent)
                self.defaults.set(Date(), forKey: self.kLastOK)
                self.defaults.set(steps, forKey: self.kLastSteps)
                self.defaults.set("\(stamp) 成功 slot\(slot) \(steps)步",
                                  forKey: self.kLastResult)
            } else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self.defaults.set("\(stamp) HTTP\(code) slot\(slot) \(text.prefix(80))",
                                  forKey: self.kLastResult)
            }
        }.resume()
    }

    // MARK: - 自检

    /// 自检页「测网络」用。具体测什么、怎么判读，全在 NetDiag 里。
    func probe(_ done: @escaping (String) -> Void) {
        NetDiag.run { lines in
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            let stamp = f.string(from: Date())
            let s = lines.joined(separator: "；")
            self.defaults.set("\(stamp) 探测 \(s)", forKey: self.kLastResult)
            done(s)
        }
    }

    func statusLine() -> String {
        let sent = defaults.string(forKey: kLastSent) ?? "从未"
        let result = defaults.string(forKey: kLastResult) ?? "无记录"
        return "上传 \(sent) · \(result)"
    }

    /// 表上扩展的实际落地情况，随上报一起发出去，服务端日志里就能看出来。
    ///
    /// 为什么需要这个：免费签名 + 第三方装机工具（iloader）装带 appex 的包时，
    /// 扩展有可能根本没被签进手表 —— iloader 的二进制里连 "appex" 这个字符串
    /// 都没有，它只认 "embedded Watch app"。要是不核实就改代码，会一直在
    /// 错误的方向上反复试。用这个字段做一次性确认，比再装一遍便宜得多。
    static func pluginManifest() -> String {
        let fm = FileManager.default
        let dir = Bundle.main.bundlePath + "/PlugIns"
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else {
            return "no-plugins-dir"
        }
        if items.isEmpty { return "empty" }
        // 只报名字 + appex 有没有自己的二进制，够判断了，别把日志撑爆。
        return items.map { name -> String in
            let bin = dir + "/" + name + "/" + (name as NSString).deletingPathExtension
            return fm.fileExists(atPath: bin) ? "\(name)+bin" : name
        }.joined(separator: ",")
    }
}
