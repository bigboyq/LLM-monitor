import XCTest
@testable import LLM_monitor

/// `TokenBucketBar` 的纯逻辑面测试：三桶占比数学、零值 / 单桶 / 损坏输入边界
/// （总量 0 时不得产生 NaN）。GeometryReader 内的分段布局依赖渲染上下文，
/// 不在此硬造（与 `SegmentedQuotaProgressBarTests` 同一约定）。
final class TokenBucketBarTests: XCTestCase {

    // MARK: - 占比数学

    /// 段宽 = 桶 / 总量：600/300/100 → 60% / 30% / 10%。
    func testFractionsFollowBucketRatios() {
        let bar = TokenBucketBar(
            buckets: TokenUsageBuckets(input: 600, cacheRead: 300, output: 100, reasoning: 0)
        )
        let fractions = bar.segmentFractions
        XCTAssertEqual(fractions.input, 0.6, accuracy: 1e-12)
        XCTAssertEqual(fractions.cacheRead, 0.3, accuracy: 1e-12)
        XCTAssertEqual(fractions.output, 0.1, accuracy: 1e-12)
    }

    /// reasoning 按 `billableOutput` 并入 output 段（计费口径）：300/0/100/100
    /// → input 60%、output 段（100+100）/500 = 40%。
    func testReasoningFoldsIntoOutputSegment() {
        let bar = TokenBucketBar(
            buckets: TokenUsageBuckets(input: 300, cacheRead: 0, output: 100, reasoning: 100)
        )
        let fractions = bar.segmentFractions
        XCTAssertEqual(fractions.input, 0.6, accuracy: 1e-12)
        XCTAssertEqual(fractions.cacheRead, 0)
        XCTAssertEqual(fractions.output, 0.4, accuracy: 1e-12)
    }

    /// 有活动时三段占比之和恒为 1（整条铺满，无空洞）。
    func testFractionsSumToOneForPositiveBuckets() {
        let bar = TokenBucketBar(
            buckets: TokenUsageBuckets(input: 1, cacheRead: 2, output: 3, reasoning: 4)
        )
        let fractions = bar.segmentFractions
        XCTAssertEqual(fractions.input + fractions.cacheRead + fractions.output, 1.0, accuracy: 1e-12)
    }

    // MARK: - 零值与边界

    /// 零活动：三段占比全 0，条上没有任何彩色段，只剩纯灰底槽。
    func testZeroActivityProducesZeroFractions() {
        let bar = TokenBucketBar(buckets: .zero)
        let fractions = bar.segmentFractions
        XCTAssertEqual(fractions.input, 0)
        XCTAssertEqual(fractions.cacheRead, 0)
        XCTAssertEqual(fractions.output, 0)
    }

    /// 单桶 100%：只有 output 有值时占满整条，其余两段不占宽。
    func testSingleBucketTakesFullWidth() {
        let bar = TokenBucketBar(
            buckets: TokenUsageBuckets(input: 0, cacheRead: 0, output: 500, reasoning: 0)
        )
        XCTAssertEqual(bar.segmentFractions.output, 1.0, accuracy: 1e-12)
        XCTAssertEqual(bar.segmentFractions.input, 0)
        XCTAssertEqual(bar.segmentFractions.cacheRead, 0)
    }

    /// 总量为 0 是这个组件唯一的除法入口：任何输入都不得产生 NaN。
    /// 覆盖全零、正负相抵与全负（损坏输入）三类总量 0 的情况。
    func testZeroTotalNeverProducesNaN() {
        let allZero = TokenBucketBar(buckets: .zero)
        for fraction in [allZero.segmentFractions.input, allZero.segmentFractions.cacheRead, allZero.segmentFractions.output] {
            XCTAssertFalse(fraction.isNaN)
        }

        let mixed = TokenBucketBar(
            buckets: TokenUsageBuckets(input: 5, cacheRead: -5, output: 0, reasoning: 0)
        )
        for fraction in [mixed.segmentFractions.input, mixed.segmentFractions.cacheRead, mixed.segmentFractions.output] {
            XCTAssertFalse(fraction.isNaN)
        }

        let allNegative = TokenBucketBar(
            buckets: TokenUsageBuckets(input: -5, cacheRead: -5, output: -5, reasoning: -5)
        )
        let negative = allNegative.segmentFractions
        XCTAssertFalse(negative.input.isNaN)
        XCTAssertFalse(negative.cacheRead.isNaN)
        XCTAssertFalse(negative.output.isNaN)
        XCTAssertEqual(negative.input + negative.cacheRead + negative.output, 0)
    }

    /// 负桶值按 0 处理（与 7 天柱图的饱和归一化同口径），不得产生负宽或 > 1 的占比。
    func testNegativeBucketsAreClampedToZero() {
        let bar = TokenBucketBar(
            buckets: TokenUsageBuckets(input: 10, cacheRead: -5, output: 0, reasoning: 0)
        )
        let fractions = bar.segmentFractions
        XCTAssertEqual(fractions.input, 1.0, accuracy: 1e-12)
        XCTAssertEqual(fractions.cacheRead, 0)
        XCTAssertEqual(fractions.output, 0)
    }

    /// 巨大桶值不炸：分母走 Double 累加（3×Int.max ≪ Double.max），占比保持
    /// 真实比例（各 1/3）而不是被 Int 饱和和挤成 1:0:0，且不产生 NaN。
    func testHugeBucketsSaturateInsteadOfOverflowing() {
        let bar = TokenBucketBar(
            buckets: TokenUsageBuckets(
                input: Int.max, cacheRead: Int.max, output: Int.max, reasoning: Int.max
            )
        )
        let fractions = bar.segmentFractions
        XCTAssertFalse(fractions.input.isNaN)
        XCTAssertFalse(fractions.cacheRead.isNaN)
        XCTAssertFalse(fractions.output.isNaN)
        XCTAssertEqual(fractions.input, 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(fractions.cacheRead, 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(fractions.output, 1.0 / 3.0, accuracy: 1e-12)
    }

    // MARK: - 契约

    /// 标准槽高 7pt：菜单汇总行比 8pt 的额度条更矮，别悄悄改掉。
    func testStandardHeightContract() {
        XCTAssertEqual(TokenBucketBar.standardHeight, 7)
    }

    /// 三段之和与 `totalTokens` 一致（分母口径）：totalTokens = input + cacheRead
    /// + billableOutput，饱和加法溢出封顶而不是崩溃 / 翻负。
    func testSegmentDenominatorMatchesTotalTokens() {
        let ordinary = TokenUsageBuckets(input: 2, cacheRead: 3, output: 4, reasoning: 5)
        XCTAssertEqual(ordinary.totalTokens, 14)
        XCTAssertEqual(
            SaturatingArithmetic.sum(ordinary.input, ordinary.cacheRead, ordinary.billableOutput),
            ordinary.totalTokens
        )

        let saturating = TokenUsageBuckets(input: Int.max, cacheRead: 1, output: 0, reasoning: 0)
        XCTAssertEqual(saturating.totalTokens, Int.max)
    }
}
