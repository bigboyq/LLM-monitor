import Foundation

/// 本地用量「落盘前保留窗口」的唯一口径：扫描器把最近 `days` 天之外的
/// 日聚合 / 样本裁掉再写缓存（index.json、recentSamples、providerSlices…）。
///
/// 六个 scanner 共享同一窗口：Antigravity / Minimax / GLM-Zcode / OpenCode 的
/// 样本与日桶裁剪用 `seconds`，DSH 的 `boundedRecentSamples` 与 Agy 的日桶裁剪
/// 用日历天（`-(days - 1)` 天，从当天 0 点起算，避开 DST 误差）。原先这些位置
/// 各写一遍字面量 8，口径漂移无从察觉，现在统一引用本文件；契约由
/// `ScannerRetentionContractTests` 锁定——注意该契约目前逐条覆盖的是前五个
/// （Antigravity / Minimax / DSH / Opencode / GLM-Zcode），Agy 走同一常量但
/// 尚无逐条断言，补齐前不要把它算进"契约已锁"的范围。
///
/// **不要与展示层的 7 天窗口混同**：`DailyUsageAggregation.filterLast7Days`
/// 是消费面（UI 图表）只画最近 7 天（offset -6...0）；这里是落盘面，8 = 展示 7 天
/// + 1 天采样余量（跨午夜 rebase 时今天要能补全前一天的尾巴）。改本常量会同时
/// 改写缓存保留范围，契约测试会红。
enum LocalUsageRetentionWindow {
    /// 保留天数：今天 + 前 7 天。
    static let days = 8

    /// 便捷换算：窗口秒数，供 `addingTimeInterval(-seconds)` 这类边界计算使用。
    static var seconds: TimeInterval { TimeInterval(days * 24 * 60 * 60) }
}
