import Foundation

/// 通知正文的唯一生成处（纯逻辑，不依赖 WatchKit，可在 Linux 上跑测试）。
///
/// 为什么只留一条：以前「该走了 / 还差 X 步」和兜底预排的「该走走了 / 起身走一走」
/// 是两条不同 id 的通知，几乎同时到达，用户一次抬腕看到两条互相矛盾的消息。
/// 现在全文共用一个 id、一段文案 —— **一条说全**：还差多少步、坐了多久、多久后再催。
enum NudgeText {

    /// 催命正文。所有数字都在这里现算，不在排程时把分钟数写死。
    /// - Parameters:
    ///   - targetSteps: 本轮目标步数
    ///   - steps: 排程时最后读到的累计步数（读不到传 nil）
    ///   - sittingMinutes: 通知**弹出那一刻**距上次走够的分钟数
    ///   - tickMinutes: 再催间隔（分钟）
    ///   - approximate: 预排通知用 true —— 它的步数是排程时的快照，
    ///     弹出时可能已经多走了一些，所以写"约"而不假装精确。
    static func reminder(targetSteps: Int,
                         steps: Int?,
                         sittingMinutes: Int,
                         tickMinutes: Int,
                         approximate: Bool = false) -> String {
        let target = max(1, targetSteps)
        let sit = max(0, sittingMinutes)
        let every = everyText(tickMinutes: tickMinutes)

        guard let s = steps else {
            return "还没走到 \(target) 步 · 已坐 \(sit) 分钟，\(every)。"
        }
        let remain = max(0, target - s)
        if remain == 0 {
            return "已满 \(target) 步，重新开始计时。"
        }
        let hint = approximate ? "还差约 \(remain) 步" : "还差 \(remain) 步"
        return "\(hint) · 已坐 \(sit) 分钟，\(every)。"
    }

    /// "1 分钟后再提醒你一次" / "5 分钟后再提醒你一次"
    static func everyText(tickMinutes: Int) -> String {
        "\(max(1, tickMinutes)) 分钟后再提醒你一次"
    }
}
