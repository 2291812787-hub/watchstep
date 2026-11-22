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

    /// **不再用 waitsForConnectivity = true。** 统一走 NetGateway：
    /// 先真发，失败就换新 session 再要一次，路径一变可用立刻补发。
    /// 那段「必须 waitsForConnectivity = true」的旧注释是错的，见 NetGateway.swift
    /// 开头：等路径会让请求根本不发出去，系统因此不分配网络能力，形成死锁。
    static var session: URLSession { NetGateway.shared.current() }

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
    /// 这个时点已经试过几次。退避分级靠它，成功即清零。
    private let kSlotTries = "upload.slotTries"

    private let defaults = UserDefaults.standard
    private var inFlight = false

    /// 路径刚变为可用时置真，让下一次 tickIfNeeded 跳过退避直接发。
    /// 用户说的「忽然就能连了」，那一下必须立刻抓住，不能被 60 秒退避挡掉。
    private var forceNext = false

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
            if let t = inFlightAt, now.timeIntervalSince(t) < 120 { return }
            // 挂太久了，当它已经死了
            inFlight = false
        }

        // 同一个点失败后退避。
        //
        // 60 秒那版太粗：路径可能在几秒后就放行，而它要等到 60 秒后才有机会再试。
        // 现在按「这个时点已经试过几次」分级：第一次失败 15 秒后再试，
        // 第二次 45 秒，第三次 120 秒，之后 300 秒 —— 越往后退越省电，
        // 但一开始绝不错过那个刚刚好的窗口。
        // forceNext 是「路径刚变可用」打的标记，直接穿透，不受退避限制。
        if !forceNext,
           defaults.string(forKey: kLastSlotAttempt) == key,
           let last = defaults.object(forKey: kLastAttempt) as? Date {
            let n = defaults.integer(forKey: kSlotTries)
            let gap: TimeInterval = n <= 1 ? 15 : (n == 2 ? 45 : (n == 3 ? 120 : 300))
            if now.timeIntervalSince(last) < gap { return }
        }
        forceNext = false

        inFlight = true
        inFlightAt = now
        if defaults.string(forKey: kLastSlotAttempt) != key {
            // 换了一个时点，计数重来
            defaults.set(0, forKey: kSlotTries)
        }
        defaults.set(defaults.integer(forKey: kSlotTries) + 1, forKey: kSlotTries)
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

    // MARK: - 待发队列（这次的核心）

    /// 一条待发记录。**先落盘，再发** —— 这是「不丢数据」的唯一保证。
    ///
    /// 为什么必须落盘：系统判定路径 unsatisfied 时（用户那台表就是，
    /// 重连 15 次、路码 -1004），请求根本出不去。如果只在内存里排一次队，
    /// 进程一被冻住就全没了。写进沙盒文件，App 下次醒来还能接着补。
    struct Pending: Codable {
        var key: String      // date#slot
        var date: String     // yyyy-MM-dd
        var slot: Int
        var steps: Int
        var note: String
        var sentAt: String
    }

    private var pendingURL: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return d.appendingPathComponent("pending_uploads.json")
    }

    private func loadPending() -> [Pending] {
        guard let d = try? Data(contentsOf: pendingURL),
              let a = try? JSONDecoder().decode([Pending].self, from: d) else { return [] }
        return a
    }

    private func savePending(_ a: [Pending]) {
        // 只留最近 48 条（两天），再多也没意义：每条都是当天累计值，
        // 后一条顶前一条。
        let trimmed = Array(a.suffix(48))
        if let d = try? JSONEncoder().encode(trimmed) {
            try? d.write(to: pendingURL, options: .atomic)
        }
    }

    func pendingCount() -> Int { loadPending().count }

    private func enqueue(_ item: Pending) {
        var a = loadPending()
        if let i = a.firstIndex(where: { $0.key == item.key }) {
            // 同一个时点重发：用新的步数覆盖，别叠两条
            a[i] = item
        } else {
            a.append(item)
        }
        savePending(a)
    }

    private func post(now: Date, slot: Int, steps: Int, key: String, note: String) {
        enqueue(Pending(key: key,
                        date: Self.dayFmt.string(from: now),
                        slot: slot,
                        steps: steps,
                        note: note,
                        sentAt: ISO8601DateFormatter().string(from: now)))
        flush()
    }

    /// 把队列里的东西尽量发出去。成功一条就顺手发下一条。
    ///
    /// 这条链路里没有任何「等系统说可以」的动作：
    ///   · 请求直接真发（NetGateway 里 waitsForConnectivity = false）
    ///   · 发不出去就换一条新会话再要，最多两轮，**不刷 15 次**（那是白耗电，
    ///     实测重连 15 次全被系统回同一个 unsatisfied）
    ///   · 还不行就留在盘里，等路径变可用的那一刻自己补
    func flush() {
        if inFlight {
            if let t = inFlightAt, Date().timeIntervalSince(t) < 120 { return }
            inFlight = false
        }
        var a = loadPending()
        guard !a.isEmpty else { return }

        let item = a.removeFirst()
        savePending(a)

        inFlight = true
        inFlightAt = Date()

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Watch-Token")

        var body: [String: Any] = [
            "steps": item.steps,
            "date": item.date,
            "slot": item.slot,
            "device": "watch",
            "sent_at": item.sentAt,
            // 补发标记：服务端日志里一眼能看出这条是离线攒下来的
            "queued": a.count,
        ]
        if !item.note.isEmpty { body["note"] = item.note }
        body["plugins"] = Self.pluginManifest()
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        NetGateway.shared.fetch(req, lane: .upload, delays: [0, 2, 6]) { [weak self] data, resp, err in
            guard let self = self else { return }
            self.inFlight = false
            self.inFlightAt = nil
            let code = resp?.statusCode ?? 0
            let stamp = Self.clock.string(from: Date())

            if let err = err {
                let ns = err as NSError
                // 失败：**放回队首**，一个字节都不丢
                var back = self.loadPending()
                back.insert(item, at: 0)
                self.savePending(back)
                self.defaults.set(
                    "\(stamp) 失败 slot\(item.slot) code\(ns.code) 待发\(self.pendingCount())条 重连\(NetGateway.shared.rebuildCount())次",
                    forKey: self.kLastResult)
                // 有通道了立刻补，不等下一个整点。
                NetGateway.whenUsable { [weak self] in
                    guard let self = self else { return }
                    self.forceNext = true
                    self.flush()
                }
                return
            }

            if code == 200 || code == 201 {
                self.defaults.set(item.key, forKey: self.kLastSent)
                self.defaults.set(0, forKey: self.kSlotTries)
                self.defaults.set(Date(), forKey: self.kLastOK)
                self.defaults.set(item.steps, forKey: self.kLastSteps)
                self.defaults.set("\(stamp) 成功 slot\(item.slot) \(item.steps)步 剩余\(self.pendingCount())条",
                                  forKey: self.kLastResult)
                // 队列没清空就接着发
                if self.pendingCount() > 0 { self.flush() }
            } else {
                // 服务器明确回了非 2xx：这是服务器的答复，说明网络已通，
                // 但这条本身被拒。留在队列里会永远卡住后面，直接丢弃并记录。
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self.defaults.set("\(stamp) HTTP\(code) slot\(item.slot) \(text.prefix(80))",
                                  forKey: self.kLastResult)
                if self.pendingCount() > 0 { self.flush() }
            }
        }
    }

    /// 自检页「强制重连」：立刻扔掉可能已经中毒的 session，并立刻补发一次。
    func forceReconnect() {
        NetGateway.shared.rebuild(.upload)
        forceNext = true
        inFlight = false
        inFlightAt = nil
        flush()
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
