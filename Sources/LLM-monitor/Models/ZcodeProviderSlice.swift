import Foundation

/// ZCode 库（`~/.zcode/cli/db/db.sqlite` `model_usage`）中**非智谱** provider 的
/// 账本切片。
///
/// ZCode 和 OpenCode 一样是**多 provider 共享账本**：同一张表里既有智谱系行
/// （`builtin:bigmodel-*` / `account:bigmodel-*` / `account:zai-*` + 闲时裸值），
/// 也有用户自带的其它 provider 行。GLM 卡只消费智谱系行；这里枚举**被其它 quota
/// 卡消费**的 provider 前缀，扫描时按前缀切出分片，并入对应卡片的共享账本
/// （与 `OpencodeDBReader` 的 per-provider 切片同构）。
///
/// 前缀匹配（`provider_id LIKE 'minimax%'`）而不是等值：ZCode 侧未来出现
/// `minimax:cn-coding-plan` 之类的变体时不会被静默漏采，分类仍由本枚举决定。
/// 智谱系行不在此列——它们由 `GlmZcodeDBReader` 的智谱前缀 LIKE 单独读取，
/// 两组谓词互不重叠。
enum ZcodeProviderSlice: String, CaseIterable, Sendable {
    /// MiniMax 官方 API（model_id 形如 `MiniMax-M3.1-Flash-Preview`）
    case minimax
    /// DeepSeek 官方 API（model_id 形如 `deepseek-flash`）
    case deepseek

    /// `model_usage.provider_id` 的 LIKE 前缀（不含 `%`）。
    var providerPrefix: String { rawValue }

    /// 该分片并入的 quota 卡。
    var quotaProviderID: String {
        switch self {
        case .minimax: return QuotaProviderID.minimax
        case .deepseek: return QuotaProviderID.deepseek
        }
    }

    /// 行 → 分片。大小写不敏感；不匹配任何已登记分片时返回 nil。
    nonisolated init?(providerID: String) {
        let value = providerID.lowercased()
        guard let match = Self.allCases.first(where: { value.hasPrefix($0.providerPrefix) }) else {
            return nil
        }
        self = match
    }

    // 说明：P1 起「给分片样本加 `zcode:<provider>:` 命名空间」的规则已收口到
    // 内核的 `UsageSampleNamespace.zcodeSlice`（帧抽取时按 sourceKey 施加前缀），
    // 旧的 `namespacedSamples(for:)` 死代码已删除（P2）。绑定驱动后 zcode 分片
    // 样本前缀仍逐字等于 `zcode:<slice>:`，由 ZcodeProviderSliceTests /
    // UsageProjectionKernelTests 的命名空间用例锁住。
}
