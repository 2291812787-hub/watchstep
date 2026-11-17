import Foundation

/// 构建标识。CI 会在编译前用当前提交覆盖这个文件，
/// 所以它永远等于「这个包是用哪次提交编出来的」。
/// 目的只有一个：装上之后能一眼看出跑的是哪一版 ——
/// 之前三个 IPA 的版本号都是 1.0(1)，装错了完全看不出来。
enum BuildInfo {
    /// 提交短哈希。本地编出来是 "local"。
    static let commit = "local"

    /// 编译日期字符串。
    static let builtAt = "unknown"

    /// 单行展示用，例如 "39e98a0 · 11-17 15:02"。
    static var stamp: String {
        if builtAt == "unknown" { return commit }
        return "\(commit) · \(builtAt)"
    }
}
