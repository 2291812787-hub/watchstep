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
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
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
}
