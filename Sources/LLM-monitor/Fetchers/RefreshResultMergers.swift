import Foundation

/// codex 的 reset credits + usage details 不是每次主 quota 刷新都会带回来；
/// 缺失时回退到上次的值，避免 UI 看到空白跳动。
/// models 永远用新值（主 quota 必须反映最新）。
struct CodexFillingMissingMerger: RefreshResultMerger {
    func merge(new: QuotaInfo, previous: QuotaInfo?, mode: RefreshMode) -> QuotaInfo {
        guard let previous else { return new }
        return QuotaInfo(
            models: new.models,
            resetCredits: new.resetCredits ?? previous.resetCredits,
            planLabel: new.planLabel,
            accountEmail: new.accountEmail,
            codexUsageDetails: new.codexUsageDetails ?? previous.codexUsageDetails,
            fetchedAt: new.fetchedAt
        )
    }
}
