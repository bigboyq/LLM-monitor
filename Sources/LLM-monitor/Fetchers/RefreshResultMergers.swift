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
            if mode == .background,
               newCredits.organizationName == nil,
               let previousOrganizationName = previous.openAIApiCredits?.organizationName {
                mergedApiCredits = OpenAIApiCreditDetails(
                    organizationName: previousOrganizationName,
                    totalQuota: newCredits.totalQuota,
                    usedAmount: newCredits.usedAmount,
                    cycleStart: newCredits.cycleStart,
                    cycleEnd: newCredits.cycleEnd,
                    fetchedAt: newCredits.fetchedAt,
                    lastAttemptFailed: newCredits.lastAttemptFailed
                )
            } else {
                mergedApiCredits = newCredits
            }
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

/// GLM Coding Plan 的套餐快照合并器：
/// - 活动套餐余额（balance）：与 GLM 默认 Interval 保持一致，每次刷新都拉取；若本次请求失败，回退保留 previous 的数据。
/// - 额度重置卡（resetCards）：类似 Codex 重置卡，走固定倍率回退，仅在 .full 模式拉取；.background 模式按设计跳过，回退保留 previous 的重置卡快照。
/// - 运营活动（deliveries）：仅在开启通知且 .full 模式下轮询；.background 模式保留 previous 的活动列表。
struct GlmFillingMissingMerger: RefreshResultMerger {
    let isZcodeCredentialEnabled: Bool

    init(isZcodeCredentialEnabled: Bool = true) {
        self.isZcodeCredentialEnabled = isZcodeCredentialEnabled
    }

    func merge(new: QuotaInfo, previous: QuotaInfo?, mode: RefreshMode) -> QuotaInfo {
        if !isZcodeCredentialEnabled {
            return new.enriched(with: nil as GlmZcodePackageSnapshot?)
        }

        guard let previous else { return new }
        let prevPackage = previous.glmZcodePackage

        guard let newPackage = new.glmZcodePackage else {
            // 如果 new 没有 ZCode package（例如本次 ZCode API 整体失败），保留 previous 的 package
            return prevPackage != nil ? new.enriched(with: prevPackage) : new
        }

        // resetCards：若 newPackage 为 nil（如 background 跳过），从 prevPackage 继承
        let mergedResetCards = newPackage.resetCards ?? prevPackage?.resetCards

        // deliveries：若 newPackage 为空且是 background 模式，从 prevPackage 继承
        let mergedDeliveries = (newPackage.deliveries.isEmpty && mode == .background)
            ? (prevPackage?.deliveries ?? [])
            : newPackage.deliveries

        // activityPlanBalances：若 newPackage 抓到了则用新的；若本次接口失败或跳过（nil）则回退保留 previous 的数据
        let mergedBalances = newPackage.activityPlanBalances ?? prevPackage?.activityPlanBalances ?? []
        let mergedPreviews = newPackage.activityPlanPreviews ?? prevPackage?.activityPlanPreviews ?? []

        let mergedPackage = GlmZcodePackageSnapshot(
            activityPlanBalances: mergedBalances,
            activityPlanPreviews: mergedPreviews,
            resetCards: mergedResetCards,
            deliveries: mergedDeliveries,
            fetchedAt: newPackage.fetchedAt
        )

        return new.enriched(with: mergedPackage)
    }
}

/// Antigravity 的账号与套餐信息只在全量刷新时读取；后台刷新只提供最新额度。
/// background 保留上次账号/套餐，full 完全采用本次元数据（包括 nil，用于清除旧账号信息）。
struct AntigravityFillingMissingMerger: RefreshResultMerger {
    func merge(new: QuotaInfo, previous: QuotaInfo?, mode: RefreshMode) -> QuotaInfo {
        guard let previous, mode == .background else { return new }

        return QuotaInfo(
            models: new.models,
            resetCredits: new.resetCredits,
            planLabel: previous.planLabel,
            accountEmail: previous.accountEmail,
            codexUsageDetails: new.codexUsageDetails,
            fetchedAt: new.fetchedAt,
            balanceDetail: new.balanceDetail,
            openAIApiCredits: new.openAIApiCredits,
            glmZcodePackage: new.glmZcodePackage,
            mainQuotaError: new.mainQuotaError,
            openAIApiCreditsError: new.openAIApiCreditsError
        )
    }
}
