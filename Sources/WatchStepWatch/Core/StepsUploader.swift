import Foundation
import CoreMotion

/// 把当天步数推到 https://watch.webchangming.top
///
/// 触发点：每天 6 个固定时刻（9:00 / 12:00 / 15:00 / 18:00 / 21:00 / 23:30）。
/// 判定放在 tick 里做 —— 手表不保证到点就醒，所以用「到点之后第一次 tick」补发，
/// 每个点只发一次（存档 date#slot），失败退避 60 秒再试。
final class StepsUploader {

    static let shared = StepsUploader()

    private let lanURL = URL(string: "http://192.168.31.82:8085/steps")!
    private let wanURL = URL(string: "https://watch.webchangming.top/steps")!
    private let token = "c7bb1f13a7b29c53e81836d66a6afded"

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

    /// 专用 session。
    /// watchOS 上 URLSession.shared 在路径没就绪时会立刻返回 -1004（150~300ms 就回来，
    /// 根本没等超时）。waitsForConnectivity 让 CFNetwork 等一条可用路径再发，
    /// 蜂窝也不被当作"昂贵网络"拒掉；这两条虽是默认值，显式写死防止以后变化。
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = true
        c.allowsExpensiveNetworkAccess = true
        c.allowsConstrainedNetworkAccess = true
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private let defaults = UserDefaults.standard
    private var inFlight = false

    /// 局域网最近一次被拒的时刻。拿不到「本地网络」权限时，每次尝试都在 ~150ms 内
    /// 返回 -1004。既然必然失败，10 分钟内就别再先撞局域网白等 6 秒。
    private var lanBlockedAt: Date?
    /// 起飞时刻。请求挂住时（watchOS 随时可能把进程冻住，回调永远不来）
    /// inFlight 会永远是 true，于是之后每次 tick 都在闸门前 return，再也不重试。
    /// 超过 45 秒一律当作已经失败。
    private var inFlightAt: Date?
    /// 局域网那次失败的原因。LAN 失败会立刻改走公网，只有公网也失败才落结果，
    /// 所以必须把 LAN 的失败码暂存下来，否则诊断信息丢一半。
    private var lanFailNote: String?
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

    /// 今天已经过去的最晚那个时点；还没到 9:00 返回 nil
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

    private func post(now: Date, slot: Int, steps: Int, key: String, note: String, lan: Bool = true) {
        // 局域网刚被系统拒过，直接走公网，不再白等。
        if lan, let t = lanBlockedAt, Date().timeIntervalSince(t) < 600 {
            post(now: now, slot: slot, steps: steps, key: key, note: note, lan: false)
            return
        }
        // inFlight 一直保持 true 到最终落定，避免回退过程中又起第二个请求。
        var req = URLRequest(url: lan ? lanURL : wanURL)
        req.httpMethod = "POST"
        req.timeoutInterval = lan ? 6 : 20
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
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Self.session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            self.inFlight = false
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let stamp = Self.clock.string(from: Date())
            if let err = err {
                // 局域网那条失败就立刻改走公网，别再等下一个 60 秒退避。
                // 家里 WiFi 永远优先，出门（蜂窝）时第一次就落到公网，只多花 6 秒。
                if lan {
                    self.inFlight = false
                    let le = err as NSError
                    // -1004 连不上 / -1009 无网络：基本就是「本地网络」权限没给。
                    if le.code == -1004 || le.code == -1009 { self.lanBlockedAt = Date() }
                    self.lanFailNote = "lan\(le.code)"
                    self.post(now: now, slot: slot, steps: steps, key: key, note: note, lan: false)
                    return
                }
                let ns = err as NSError
                let pre = self.lanFailNote.map { "\($0)→" } ?? ""
                self.lanFailNote = nil
                self.defaults.set("\(stamp) 失败 slot\(slot) \(pre)net code\(ns.code) \(err.localizedDescription)",
                                  forKey: self.kLastResult)
                return
            }
            if code == 200 || code == 201 {
                self.defaults.set(key, forKey: self.kLastSent)
                self.defaults.set(Date(), forKey: self.kLastOK)
                self.defaults.set(steps, forKey: self.kLastSteps)
                // 标注走的是哪条路：lan=家里局域网直连，net=公网兜底。
                self.defaults.set("\(stamp) 成功 slot\(slot) \(steps)步 \(lan ? "lan" : "net")",
                                  forKey: self.kLastResult)
            } else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self.defaults.set("\(stamp) HTTP\(code) slot\(slot) \(text.prefix(80))",
                                  forKey: self.kLastResult)
            }
        }.resume()
    }

    // MARK: - 自检

    /// 自检页「测试连接」用：同时问局域网和公网的 /health。
    /// 上传失败时靠它分清是「手表连不上家里这台机」还是「公网隧道坏了」。
    func probe(_ done: @escaping (String) -> Void) {
        // 具体测什么、怎么判读，全在 NetDiag 里，这里只负责落盘和回报。
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
}
