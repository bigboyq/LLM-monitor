import SwiftUI

/// 水平三段占比条（input / cacheRead / output），为 Harness（客户端视角）
/// 菜单的「今日 token 汇总」设计，也可用于任意单行 token 构成展示。
///
/// 输入直接收 `TokenAccounting` 的归一化桶 `TokenUsageBuckets`（四桶），展示为
/// **三个计费段**：input / cacheRead / `billableOutput`（output + reasoning，
/// 计费口径把 reasoning 并入 output；与 7 天柱图的 `outputTotal` 同口径）。
/// 分母即三段之和 = `totalTokens`，段宽 = 桶 / 总。
///
/// 视觉契约：
/// - 高 7pt，两端 `Capsule` 裁剪；
/// - 段宽 = 桶 / 总量，段间无间隙（相邻段直接相接）；
/// - 底槽 `Color.primary.opacity(0.08)`，零活动（总量 0）时只剩纯灰底槽；
/// - 默认取 `tokenInputTint` / `tokenCacheReadTint` / `tokenOutputTint`，
///   与 7 天柱图的桶色一致（同一 token 桶在不同视图里同色）。
struct TokenBucketBar: View {
    let buckets: TokenUsageBuckets
    var height: CGFloat = TokenBucketBar.standardHeight
    var inputTint: Color = .tokenInputTint
    var cacheReadTint: Color = .tokenCacheReadTint
    var outputTint: Color = .tokenOutputTint

    /// 标准槽高。汇总行比 8pt 的 `SegmentedQuotaProgressBar` 更矮。
    static let standardHeight: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                HStack(spacing: 0) {
                    segment(inputTint, segmentFractions.input, width: width)
                    segment(cacheReadTint, segmentFractions.cacheRead, width: width)
                    segment(outputTint, segmentFractions.output, width: width)
                }
            }
            .frame(width: width, height: height)
            .clipShape(Capsule())
        }
        .frame(height: height)
    }

    private func segment(_ tint: Color, _ fraction: Double, width: CGFloat) -> some View {
        Rectangle()
            .fill(tint)
            .frame(width: width * CGFloat(fraction))
    }

    /// 三段占比（0...1）。归一化与 7 天柱图同口径（`LocalUsageChartDayMetrics`
    /// 的饱和归一）：负桶值按 0 处理；总量 ≤ 0 时三段全 0——零活动退回纯灰底，
    /// 且保证任何输入（含总量 0 的 0/0 除法）都不产生 NaN 或负宽。
    ///
    /// 分母用 Double 累加而不是 Int 饱和和：三桶同爆 `Int.max` 时饱和和会把
    /// 占比挤成 1:0:0，Double 对 3×Int.max（≈2.8e19 ≪ Double.max）既不溢出也
    /// 不产生 NaN；常规量级（< 2^53）下两种算法逐位一致。
    ///
    /// `internal`（非 `private`）：纯计算、无渲染依赖，测试直接断言占比数学。
    var segmentFractions: (input: Double, cacheRead: Double, output: Double) {
        let safeInput = max(0, buckets.input)
        let safeCacheRead = max(0, buckets.cacheRead)
        let safeOutput = buckets.billableOutput
        let total = Double(safeInput) + Double(safeCacheRead) + Double(safeOutput)
        guard total > 0 else { return (input: 0, cacheRead: 0, output: 0) }
        return (
            input: Double(safeInput) / total,
            cacheRead: Double(safeCacheRead) / total,
            output: Double(safeOutput) / total
        )
    }
}
