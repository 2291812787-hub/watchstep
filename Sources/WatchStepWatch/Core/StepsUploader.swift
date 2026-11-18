import Foundation
import CoreMotion

/// 把当天步数推到 https://watch.webchangming.top
///
/// 触发点：每天 6 个固定时刻（9:00 / 12:00 / 15:00 / 18:00 / 21:00 / 23:30）。
/// 判定放在 tick 里做 —— 手表不保证到点就醒，所以用「到点之后第一次 tick」补发，
/// 每个点只发一次（存档 date#slot），失败退避 60 秒再试。
final class StepsUploader {

    static let shared = StepsUploader()

    private let endpoint = URL(string: "https://watch.webchangming.top/steps")!
    private let token = "c7bb1f13a7b29c53e81836d66a6afded"

    /// 每天推送的时点（本地时区）
    static let slots: [(hour: Int, minute: Int)] = [
        (9, 0), (12, 0), (15, 0), (18, 0), (21, 0), (23, 30)
    ]

    private let kLastSent = "upload.lastSentSlot"
    private let kLastAttempt = "upload.lastAttemptAt"
    private let kLastSlotAttempt = "upload.lastAttemptSlot"
    private let kLastResult = "upload.lastResult"
    private let kLastOK = "upload.lastOKAt"
    private let kLastSteps = "upload.lastSteps"

    private let defaults = UserDefaults.standard
    private var inFlight = false
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
        if inFlight { return }

        // 同一个点失败后退避 60 秒，别把每次 tick 都拿去撞网络
        if defaults.string(forKey: kLastSlotAttempt) == key,
           let last = defaults.object(forKey: kLastAttempt) as? Date,
           now.timeIntervalSince(last) < 60 {
            return
        }

        inFlight = true
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

    private func post(now: Date, slot: Int, steps: Int, key: String, note: String) {
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
                self.defaults.set("\(stamp) 失败 slot\(slot) \(err.localizedDescription)",
                                  forKey: self.kLastResult)
                return
            }
            if code == 200 || code == 201 {
                self.defaults.set(key, forKey: self.kLastSent)
                self.defaults.set(Date(), forKey: self.kLastOK)
                self.defaults.set(steps, forKey: self.kLastSteps)
                self.defaults.set("\(stamp) 成功 slot\(slot) \(steps)步", forKey: self.kLastResult)
            } else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self.defaults.set("\(stamp) HTTP\(code) slot\(slot) \(text.prefix(80))",
                                  forKey: self.kLastResult)
            }
        }.resume()
    }

    // MARK: - 自检

    func statusLine() -> String {
        let sent = defaults.string(forKey: kLastSent) ?? "从未"
        let result = defaults.string(forKey: kLastResult) ?? "无记录"
        return "上传 \(sent) · \(result)"
    }
}
