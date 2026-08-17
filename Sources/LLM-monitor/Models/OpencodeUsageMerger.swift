import Foundation

/// OpenCode sample 的命名空间规则。
///
/// 卡片层的用量合并入口是 `ProviderStatus.usageProjection`：它把每个 client
/// （Codex / Antigravity / MiniMax Code / ZCode / DSH / OpenCode）的日用量转成
/// `ClientUsageContribution` 后按日相加，不再经过本类型的历史 `merge*` 函数。
/// 这里只保留 promptID 命名空间 helper：OpenCode 的 sample ID 加
/// `opencode:<provider>:` 前缀，避免与 native 账本的 ID 碰撞后被错误去重。
enum OpencodeUsageMerger {
    static func opencodeSamples(
        _ usage: OpencodeProviderUsage?,
        providerID: String
    ) -> [LocalTokenUsageSample] {
        guard let usage else { return [] }
        let prefix = "opencode:\(providerID):"
        return usage.recentSamples.map { $0.withPromptIDPrefix(prefix) }
    }

    static func mergeSamples(
        native: [LocalTokenUsageSample],
        opencode: OpencodeProviderUsage?,
        providerID: String
    ) -> [LocalTokenUsageSample] {
        native + opencodeSamples(opencode, providerID: providerID)
    }

}
