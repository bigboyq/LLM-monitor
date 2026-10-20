import SwiftUI
import AppKit

// MARK: - ChatGPT Plan 专用行

/// ChatGPT Plan：模型名 hover 看 Last Prompt，各 API 用量窗口 hover 看本地 token 明细
struct ChatGPTPlanModelRow: View {
    let model: ModelQuota
    let usageDetails: CodexUsageDetails?
    let localSamples: [LocalTokenUsageSample]
    let tint: Color
    /// 夹在进度条块与下方**本地用量**之间的卡片级信息（重置卡、高峰期），见
    /// `ModelQuotaDockBlock.between`。只有第一个 model 行会拿到非空值。
    var between: AnyView = AnyView(EmptyView())

    /// 直接渲染 dock 形态。此前是 `if isDockLayout { dockBlock } else { menuLayout }`：
    /// 判据 `ProviderCardLayout.liftsProgressBar(mode:)` 恒为真（生产路径上唯一的宿主
    /// 就是这张卡，而两个宿主都注入 `.alwaysVisible`——`EdgeDockController.popoverContent` /
    /// `HarnessUsageMenuView.cardRevealMode`），所以菜单那一支跑不到，连同它的独占
    /// 子视图（`QuotaCombinedUsageRow` / `QuotaSingleUsageRow` /
    /// `LastPromptHoverSummaryView`）一并删除。
    /// 新的渲染宿主若要换形态，届时是**恢复分支**而不是从死代码里挑。
    var body: some View {
        dockBlock
    }

    // MARK: dock：条 + 元信息行（与通用 model 行同构）

    /// ChatGPT 的周等效倍率。与 `QuotaInfo.weeklyEquivalentMultiplier` 的
    /// `.codexChatGpt` 分支同值——这一整块是 **ChatGPT Plan 专用行**，倍率对它
    /// 是常量，不该走那个按 provider 分派的函数（走一遍只会得到同样的 6，
    /// 却让人以为这里也支持别的 provider）。
    private static let weeklyEquivalentMultiplier = 6

    /// dock 侧只有额度条这一块，明细（三列统计）已撤掉：条 + 元信息行回答
    /// "还剩多少、什么时候重置"，用量明细交给菜单侧的 hover 浮层。菜单侧仍然
    /// 用 `title` 当那行的名字。
    ///
    /// 三个分支的差别只在"哪些窗口存在"→ 传哪两个 label；`between`
    /// 三处完全一样，所以先算出来再各建一次 `ModelQuotaDockBlock`。
    @ViewBuilder
    private var dockBlock: some View {
        if let pair = dockWindowLabels {
            ModelQuotaDockBlock(
                bar: QuotaBarWithMetadata(
                    model: model,
                    primaryLabel: pair.primary,
                    secondaryLabel: pair.secondary,
                    weeklyEquivalentMultiplier: Self.weeklyEquivalentMultiplier,
                    tint: tint
                ),
                between: between
            )
        } else {
            Text("额度窗口不可用")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    /// dock 形态下这一行展示哪两个窗口，及其标签。两个窗口都有就都展示；只有一个就
    /// 把它当主窗口（次窗口传空串）。一个都没有返回 nil，由 `dockBlock` 走占位文案。
    private var dockWindowLabels: (primary: String, secondary: String)? {
        if hasPrimaryWindow && hasSecondaryWindow {
            return (primaryLabel, secondaryLabel)
        }
        if hasPrimaryWindow { return (primaryLabel, "") }
        if hasSecondaryWindow { return (secondaryLabel, "") }
        return nil
    }

    private var primaryLabel: String { Formatters.codexWindowLabel(seconds: model.intervalWindowSeconds) }
    private var secondaryLabel: String { Formatters.codexWindowLabel(seconds: model.weeklyWindowSeconds) }
    private var hasPrimaryWindow: Bool { model.hasIntervalWindow }
    private var hasSecondaryWindow: Bool { model.hasWeeklyWindow }

    /// 两个额度窗口的本地用量，**额度行与卡片级「额度窗口用量」区块共用这一份**。
    ///
    /// ChatGPT 的窗口用量有特殊口径（`codexUsageDetails` 预聚合 + OpenCode 补充），
    /// 两条消费路径必须逐字段一致；写成两个 `static` 之后，模型行与卡片区块
    /// 不可能各算一套。
    static func windowUsages(
        model: ModelQuota,
        usageDetails: CodexUsageDetails?,
        samples: [LocalTokenUsageSample]
    ) -> (interval: UsageMetricSummary?, weekly: UsageMetricSummary?) {
        (
            intervalUsage(model: model, usageDetails: usageDetails, samples: samples),
            weeklyUsage(model: model, usageDetails: usageDetails, samples: samples)
        )
    }

    static func intervalUsage(
        model: ModelQuota,
        usageDetails: CodexUsageDetails?,
        samples: [LocalTokenUsageSample]
    ) -> UsageMetricSummary? {
        let bounds = LocalUsageSummaryBuilder.windowBounds(
            resetsAt: model.intervalResetsAt,
            explicitWindowSeconds: model.intervalWindowSeconds,
            fallbackSeconds: 5 * 60 * 60
        )
        return preferUsageDetails(
            usageDetails?.primary,
            localUsage(
                samples: samples,
                quotaModelName: model.modelName,
                start: bounds?.start,
                end: bounds?.end
            ),
            externalUsage: openCodeUsageSummary(
                samples: samples,
                quotaModelName: model.modelName,
                start: bounds?.start,
                end: bounds?.end
            )
        )
    }

    static func weeklyUsage(
        model: ModelQuota,
        usageDetails: CodexUsageDetails?,
        samples: [LocalTokenUsageSample]
    ) -> UsageMetricSummary? {
        let bounds = LocalUsageSummaryBuilder.windowBounds(
            resetsAt: model.weeklyResetsAt,
            explicitWindowSeconds: model.weeklyWindowSeconds,
            fallbackSeconds: 7 * 24 * 60 * 60
        )
        return preferUsageDetails(
            usageDetails?.secondary,
            localUsage(
                samples: samples,
                quotaModelName: model.modelName,
                start: bounds?.start,
                end: bounds?.end
            ),
            externalUsage: openCodeUsageSummary(
                samples: samples,
                quotaModelName: model.modelName,
                start: bounds?.start,
                end: bounds?.end
            )
        )
    }

    static func localUsage(
        samples: [LocalTokenUsageSample],
        quotaModelName: String,
        start: Date?,
        end: Date?
    ) -> UsageMetricSummary? {
        return LocalUsageSummaryBuilder.summary(
            samples: samples,
            providerKind: .codexChatGpt,
            quotaModelName: quotaModelName,
            start: start,
            end: end
        )
    }

    static func openCodeUsageSummary(
        samples: [LocalTokenUsageSample],
        quotaModelName: String,
        start: Date?,
        end: Date?
    ) -> UsageMetricSummary? {
        let prefix = "opencode:\(OpencodeLocalUsage.openAIProviderID):"
        let openCodeSamples = samples.filter { $0.promptID.hasPrefix(prefix) }
        guard openCodeSamples.isEmpty == false else { return nil }
        return LocalUsageSummaryBuilder.summary(
            samples: openCodeSamples,
            providerKind: .codexChatGpt,
            quotaModelName: quotaModelName,
            start: start,
            end: end
        )
    }

    /// `usageDetails` 已由同一批 Codex session samples 聚合而来；不能再与
    /// `localUsage` 相加，否则窗口内的 input/cache/output 会全部重复计算。
    /// 有详情时仅追加已启用的 OpenCode 来源；详情尚未生成时从合并 samples 回退。
    static func preferUsageDetails(
        _ usageDetails: UsageMetricSummary?,
        _ localFallback: @autoclosure () -> UsageMetricSummary?,
        externalUsage: @autoclosure () -> UsageMetricSummary? = nil
    ) -> UsageMetricSummary? {
        guard let usageDetails else { return localFallback() }
        guard let externalUsage = externalUsage() else { return usageDetails }
        return usageDetails + externalUsage
    }
}
