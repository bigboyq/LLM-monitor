import Foundation

/// Antigravity provider 内部分类常量。
///
/// Antigravity 远程 quota 响应按模型族分组返回（如 `gemini_models` /
/// `claude_and_gpt_models`）。这些 string 散落在 Antigravity fetcher、QuotaInfo
/// displayName、LocalTokenUsageSample 模型匹配、ProviderCardView accent 分流
/// 等 5+ 处；本 enum 是 single source of truth，避免漂移。
///
/// wire format 保持原样（`"gemini_models"` / `"claude_and_gpt_models"`），
/// `RawRepresentable: String` 让 initializer `AntigravityModelKind(rawValue:)`
/// 安全校验外部输入。
enum AntigravityModelKind: String, Sendable, CaseIterable {
    case geminiModels = "gemini_models"
    case claudeAndGptModels = "claude_and_gpt_models"
}
