import Foundation

/// agy（Antigravity 的 CLI 分支）本地 transcript token 用量。
///
/// agy 把每个会话落盘为 `~/.gemini/antigravity-cli/brain/<uuid>/.system_generated/logs/`
/// 下的 JSONL transcript（主文件 + 滚动分块）。只有 `source == "MODEL"` 且
/// `status == "DONE"` 的行带 token 字段：
/// - `input_tokens` 是未缓存输入（uncached）；
/// - `cache_read_tokens` 是独立的缓存读桶；
/// - `output_tokens` 含思考。账本没有原生 reasoning 计数，扫描层用 `thinking`
///   文本按字符占比把 output 守恒拆成 reasoning + output
///   （`ReasoningCharSplit`，`reasoning + output == 原始 output_tokens` 恒成立）；
///   无 `thinking` 时全部记 output。
///
/// transcript 行不带模型名；扫描层用 `log/cli-*.log` 文件名时间与
/// `Resolving model <name>` 行做 join（见 scanner），无命中时模型名保持 nil，
/// 投影层归入 `ProviderHarnessProjection.unknownModelName`。
///
/// 单一 quota 归属（Google Antigravity）：帧自带 `quotaProviderID`，不再按
/// provider 切片，结构与 `DshProviderUsage` 的单 provider 形态对齐。
struct AgyLocalUsage: Equatable, Codable, Sendable {
    let dailyTokenUsage: [AgyDailyUsage]
    let models: [String]
    /// 逐次模型响应样本（已含 reasoning 分摊），供帧构造与 UI 拆行。
    let recentSamples: [LocalTokenUsageSample]
    let sessionsRoot: String?
    let sessionCount: Int
    let eventCount: Int
    let scannedAt: Date?
    /// Optional so older persisted snapshots decode unchanged. A partial
    /// result is displayable but must not be promoted to clean freshness.
    var isPartial: Bool? = nil
    /// Optional so older persisted snapshots decode unchanged. True when the
    /// transcript-file count or raw-byte budget cut the scanned source set short
    /// (oldest sessions excluded), so the totals below undercount what is on
    /// disk. Unlike `isPartial` — which marks failed reads — a truncated scan
    /// is a normal, complete scan of a deliberately reduced file set, so it is
    /// part of the result's meaning rather than a freshness flag (and unlike
    /// `isPartial` it participates in `==`).
    var isTruncated: Bool? = nil

    static let empty = AgyLocalUsage(
        dailyTokenUsage: [],
        models: [],
        recentSamples: [],
        sessionsRoot: nil,
        sessionCount: 0,
        eventCount: 0,
        scannedAt: nil
    )

    /// Exclude scan metadata from equality so a successful re-scan does not publish a
    /// new UI state solely because `scannedAt` changed. `isPartial` is excluded too:
    /// partialness travels through the freshness channel (`scanResultIsComplete`),
    /// not result content. `isTruncated` stays in equality because there is no such
    /// side channel — it qualifies the numbers themselves, so a truncation flip must
    /// be able to republish.
    static func == (lhs: AgyLocalUsage, rhs: AgyLocalUsage) -> Bool {
        lhs.dailyTokenUsage == rhs.dailyTokenUsage
            && lhs.models == rhs.models
            && lhs.recentSamples == rhs.recentSamples
            && lhs.sessionsRoot == rhs.sessionsRoot
            && lhs.sessionCount == rhs.sessionCount
            && lhs.eventCount == rhs.eventCount
            && lhs.isTruncated == rhs.isTruncated
    }
}

typealias AgyDailyUsage = LocalDailyTokenUsage
