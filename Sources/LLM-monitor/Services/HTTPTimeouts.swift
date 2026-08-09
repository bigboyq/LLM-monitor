import Foundation

/// HTTP timeout 集中地 —— 之前散落在 `HTTPClient` init 调用方（`15` / `20` /
/// `15+20` 各处），现在跟 Antigravity `URLSessionConfiguration` 放一起。
///
/// **不要** 直接 hardcode 超时秒数。改这里，所有 fetcher 同步生效。
enum HTTPTimeouts {
    /// minimax / codex 主 quota + reset-credits 默认值。
    /// 收紧自 URLRequest 默认 60s，避免网络抖动导致 UI 长时间 stuck。
    static let request: TimeInterval = 15

    /// codex 的 reset-credits / usage 拉取稍宽（20s），给 codex 服务慢响应留余量。
    static let codex: TimeInterval = 20

    /// Antigravity 本地 language_server RPC：request 略短（本地回环，5s 内不应答即视为死），
    /// resource 略宽（首次启动可能 cold start 久一些）。
    static let antigravityRequest: TimeInterval = 15
    static let antigravityResource: TimeInterval = 20
}
