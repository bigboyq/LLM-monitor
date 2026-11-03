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
enum AntigravityModelKind: String, Sendable, CaseIterable, Equatable {
    case geminiModels = "gemini_models"
    case geminiArgon = "gemini_argon"
    case claudeAndGptModels = "claude_and_gpt_models"

    var displayName: String {
        switch self {
        case .geminiModels: return "Gemini Models"
        case .geminiArgon: return "Gemini 4 Argon"
        case .claudeAndGptModels: return "Claude and GPT models"
        }
    }

    /// Maps a local sample model ID to the quota pool it belongs to.
    /// Argon is checked first because its IDs also contain "gemini".
    static func pool(forSampleModelName modelName: String?) -> Self? {
        let model = modelName?.lowercased() ?? ""
        guard !model.isEmpty else { return nil }
        if model.contains("argon") { return .geminiArgon }
        if model.contains("claude") || model.contains("gpt")
            || model.contains("anthropic") || model.contains("openai") {
            return .claudeAndGptModels
        }
        if model.contains("gemini") { return .geminiModels }
        return nil
    }
}
