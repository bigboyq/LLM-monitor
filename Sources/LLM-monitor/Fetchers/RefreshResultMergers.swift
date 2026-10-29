import Foundation

/// codex 的 reset credits + usage details 不是每次主 quota 刷新都会带回来；
/// 缺失时回退到上次的值，避免 UI 看到空白跳动。
/// models 永远用新值（主 quota 必须反映最新）。
///
/// R3: reset credits 有独立新鲜度语义。
/// - `new.resetCredits` 非空 → 用新值（fresh，full 抓取成功）。
/// - `new.resetCredits` 为空：
///   - `mode == .background`：按设计跳过 reset credits 请求，保留 previous 的值与
///     新鲜度（不冒充失败、不更新时间）。
///   - `mode == .full`：主 quota 成功但 reset credits 子请求失败 → 保留 previous 的
///     值与原 fetchedAt，并标记 `lastAttemptFailed`，让 UI 显示"可能过期"。
/// 不用主 `QuotaInfo.fetchedAt` 冒充 reset credits 的子接口时间。
struct CodexFillingMissingMerger: RefreshResultMerger {
    let adminApiCreditsEnabled: Bool

    init(adminApiCreditsEnabled: Bool = false) {
        self.adminApiCreditsEnabled = adminApiCreditsEnabled
    }

    func merge(new: QuotaInfo, previous: QuotaInfo?, mode: RefreshMode) -> QuotaInfo {
        guard let previous else { return new }
        let mergedResetCredits: ResetCreditsInfo?
        if new.mainQuotaError != nil {
            mergedResetCredits = previous.resetCredits
        } else if let newResets = new.resetCredits {
            mergedResetCredits = newResets
        } else if let prevResets = previous.resetCredits {
            if mode == .background {
                // 按设计跳过：保持原值与原新鲜度，既不更新时间也不标记失败。
                mergedResetCredits = prevResets
            } else {
                // full 抓取但 reset credits 失败：保留旧值，标记过期。
                mergedResetCredits = prevResets.markingStale()
            }
        } else {
            mergedResetCredits = nil
        }

        let mergedApiCredits: OpenAIApiCreditDetails?
        let mergedApiCreditsError: String?
        if !adminApiCreditsEnabled {
            mergedApiCredits = nil
            mergedApiCreditsError = nil
        } else if let newCredits = new.openAIApiCredits {
            mergedApiCredits = newCredits
            mergedApiCreditsError = nil
        } else if let previousCredits = previous.openAIApiCredits {
            if new.openAIApiCreditsError != nil {
                mergedApiCredits = previousCredits.markingStale()
            } else {
                mergedApiCredits = previousCredits
            }
            mergedApiCreditsError = new.openAIApiCreditsError
        } else {
            mergedApiCredits = nil
            mergedApiCreditsError = new.openAIApiCreditsError
        }

        let mainQuotaFailed = new.mainQuotaError != nil

        return QuotaInfo(
            models: mainQuotaFailed ? previous.models : new.models,
            resetCredits: mergedResetCredits,
            planLabel: mainQuotaFailed ? previous.planLabel : new.planLabel,
            accountEmail: mainQuotaFailed ? previous.accountEmail : new.accountEmail,
            codexUsageDetails: new.codexUsageDetails ?? previous.codexUsageDetails,
            fetchedAt: mainQuotaFailed ? previous.fetchedAt : new.fetchedAt,
            balanceDetail: new.balanceDetail ?? previous.balanceDetail,
            openAIApiCredits: mergedApiCredits,
            mainQuotaError: new.mainQuotaError,
            openAIApiCreditsError: mergedApiCreditsError
        )
    }
}
