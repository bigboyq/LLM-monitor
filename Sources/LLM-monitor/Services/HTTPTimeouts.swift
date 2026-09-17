import Foundation

/// HTTP timeout 集中地 —— 之前散落在 `HTTPClient` init 调用方（`15` / `20` /
/// `15+20` 各处），现在跟 Antigravity `URLSessionConfiguration` 放一起。
///
/// 国内/海外两档策略：
/// - 国内 quota 端点（minimax / GLM / DeepSeek）实测 600+ 样本 p99 ≤ 0.8s、
///   最慢 ~1.8s，10s 已能扛住 TCP SYN 重传（~1s/3s/7s），同时避免网络抖动
///   让 UI 长时间 stuck；
/// - 海外跨网路径（codex → chatgpt.com）抖动大，给 15s。
///
/// **不要** 直接 hardcode 超时秒数。改这里，所有 fetcher 同步生效。
enum HTTPTimeouts {
    /// 国内 quota 端点（minimax / GLM / DeepSeek）。
    static let domestic: TimeInterval = 10

    /// 海外端点（codex 的 usage / reset-credits）。
    static let overseas: TimeInterval = 15

    /// Antigravity 本地 language_server RPC：本机回环，不属于国内/海外任一档。
    /// request 略短（本地回环，5s 内不应答即视为死），
    /// resource 略宽（首次启动可能 cold start 久一些）。
    static let antigravityRequest: TimeInterval = 15
    static let antigravityResource: TimeInterval = 20
}
