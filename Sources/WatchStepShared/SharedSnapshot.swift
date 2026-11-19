import Foundation

/// App 与表盘复杂功能（WidgetKit 扩展）之间的共享快照。
///
/// 两件事必须靠它：
///   1. **锚点**。本轮从什么时候开始，由主 App 在「走够 200 步」那一刻重置，
///      表盘必须知道同一个时刻，否则两边算出的进度各说各话。
///   2. **目标与窗口**。用户在 App 里改了 200 步或 30 分钟，表盘要跟着变。
///
/// 步数本身不存这里 —— 表盘自己用 CMPedometer 从锚点算到现在，
/// 所以主 App 没在运行时，表盘上的数字也是新的，而不是一张旧快照。
///
/// ## 为什么是「写多份、读第一份有数据的」
///
/// App Group 的名字取决于**安装后的 bundle id**。iloader 装完会把
/// `top.webchangming.step` 改写成 `top.webchangming.step.34AQFYMZ25`（团队后缀），
/// 于是注入的组名是 `group.top.webchangming.step.34AQFYMZ25` —— 实测过，
/// 它确实在 App 的 entitlements 里。但**扩展会不会拿到同一个组，没有验证过**。
///
/// UserDefaults(suiteName:) 对任何字符串都返回非 nil，写进去却可能落空，
/// 所以「试一个、失败就退」的写法根本发现不了问题。这里改成：发布时逐个写，
/// 读取时逐个找第一份有数据的。哪个真实有效就用哪个，不用事先知道答案。
struct SharedSnapshot: Codable {
    /// 本轮起点。nil = 还没开始过。
    var anchor: Date?
    var targetSteps: Int
    var windowMinutes: Int
    /// 写入时那一刻的本轮步数。表盘查不到计步器时用它兜底。
    var roundSteps: Int
    var enabled: Bool
    /// 暂停到什么时候。非 nil 且晚于现在 → 表盘显示「已暂停」。
    var pausedUntil: Date?
    var updatedAt: Date

    /// 候选组名，按可能性排序。第一个是 iloader 实测注入的那个。
    static let groupIDs: [String] = [
        "group.top.webchangming.step.34AQFYMZ25",
        "group.top.webchangming.step.watchkitapp",
        "group.top.webchangming.step",
    ]

    private static let key = "ws.snapshot.v1"

    /// 主 App 每轮 tick 调一次。开销是几次 JSON 编码，可以忽略。
    static func publish(anchor: Date?, target: Int, window: Int,
                        roundSteps: Int, enabled: Bool, pausedUntil: Date?) {
        let s = SharedSnapshot(
            anchor: anchor,
            targetSteps: target,
            windowMinutes: window,
            roundSteps: roundSteps,
            enabled: enabled,
            pausedUntil: pausedUntil,
            updatedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(s) else { return }
        for g in groupIDs {
            guard let d = UserDefaults(suiteName: g) else { continue }
            d.set(data, forKey: key)
            d.synchronize()
        }
    }

    static func load() -> SharedSnapshot? {
        for g in groupIDs {
            guard let d = UserDefaults(suiteName: g),
                  let data = d.data(forKey: key),
                  let s = try? JSONDecoder().decode(SharedSnapshot.self, from: data)
            else { continue }
            return s
        }
        return nil
    }
}
