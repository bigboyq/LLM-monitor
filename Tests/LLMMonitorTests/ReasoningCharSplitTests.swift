import XCTest
@testable import LLM_monitor

/// `ReasoningCharSplit` 是 ZCode 分片 / MiniMax Code runtime / Dsh M3 三处共用的
/// 守恒拆分公式。这里直钉契约：正常比例、无法估算的边界、极端值饱和、负值归零。
/// 公式变了三处账本的 reasoning 数字都会漂，所以单独钉死。
final class ReasoningCharSplitTests: XCTestCase {

    // MARK: - 正常比例

    /// 思考字符占 3/4 → 300 output 拆成 225 reasoning + 75 output，守恒。
    func testSplitProportionalToReasoningChars() throws {
        let result = try XCTUnwrap(ReasoningCharSplit.split(
            outputTokens: 100, reasoningChars: 750, visibleChars: 250
        ))
        XCTAssertEqual(result.reasoning, 75)
        XCTAssertEqual(result.output, 25)
        XCTAssertEqual(result.reasoning + result.output, 100, "拆分必须守恒")

        let day = try XCTUnwrap(ReasoningCharSplit.split(
            outputTokens: 300, reasoningChars: 1_500, visibleChars: 500
        ))
        XCTAssertEqual(day.reasoning, 225)
        XCTAssertEqual(day.output, 75)
    }

    /// 四舍五入按 `.rounded()`（半数远离零）：0.5 → 1，不做向下取整。
    func testSplitRoundsToNearest() throws {
        let result = try XCTUnwrap(ReasoningCharSplit.split(
            outputTokens: 10, reasoningChars: 5, visibleChars: 5
        ))
        XCTAssertEqual(result.reasoning, 5)
        XCTAssertEqual(result.output, 5)

        let odd = try XCTUnwrap(ReasoningCharSplit.split(
            outputTokens: 3, reasoningChars: 1, visibleChars: 2
        ))
        XCTAssertEqual(odd.reasoning, 1, "3 × 0.333 = 0.999 → 1")
        XCTAssertEqual(odd.output, 2)
    }

    // MARK: - 无法估算的边界

    /// 账面没有 output：无从分摊。
    func testSplitReturnsNilWhenOutputIsNotPositive() {
        XCTAssertNil(ReasoningCharSplit.split(outputTokens: 0, reasoningChars: 750, visibleChars: 250))
        XCTAssertNil(ReasoningCharSplit.split(outputTokens: -10, reasoningChars: 750, visibleChars: 250))
    }

    /// 没有思考字符：调用方保持原样（reasoning 恒 0），而不是误算成 100%。
    func testSplitReturnsNilWhenNoReasoningChars() {
        XCTAssertNil(ReasoningCharSplit.split(outputTokens: 100, reasoningChars: 0, visibleChars: 250))
        XCTAssertNil(ReasoningCharSplit.split(outputTokens: 100, reasoningChars: -5, visibleChars: 250))
    }

    // MARK: - 极端值

    /// 只有思考没可见输出：100% 记 reasoning。
    func testSplitWithZeroVisibleCharsTakesEverything() throws {
        let result = try XCTUnwrap(ReasoningCharSplit.split(
            outputTokens: 200, reasoningChars: 1_000, visibleChars: 0
        ))
        XCTAssertEqual(result.reasoning, 200)
        XCTAssertEqual(result.output, 0)
    }

    /// 负的可见字符数归 0（等价"只有思考"），不产生负分母。
    func testSplitClampsNegativeVisibleCharsToZero() throws {
        let result = try XCTUnwrap(ReasoningCharSplit.split(
            outputTokens: 50, reasoningChars: 100, visibleChars: -1_000
        ))
        XCTAssertEqual(result.reasoning, 50)
        XCTAssertEqual(result.output, 0)
    }

    /// 巨大数值不 trap：分母饱和到 Int.max，比例仍在 [0,1]，结果守恒。
    func testSplitSaturatesWithoutTrappingOnHugeValues() throws {
        let huge = try XCTUnwrap(ReasoningCharSplit.split(
            outputTokens: Int.max, reasoningChars: Int.max, visibleChars: Int.max
        ))
        XCTAssertEqual(huge.reasoning, Int.max)
        XCTAssertEqual(huge.output, 0)

        let bothHuge = try XCTUnwrap(ReasoningCharSplit.split(
            outputTokens: Int.max, reasoningChars: Int.max, visibleChars: 1
        ))
        XCTAssertEqual(bothHuge.reasoning, Int.max)
        XCTAssertEqual(bothHuge.output, 0)

        let smallOutput = try XCTUnwrap(ReasoningCharSplit.split(
            outputTokens: 10, reasoningChars: Int.max, visibleChars: Int.max
        ))
        XCTAssertLessThanOrEqual(smallOutput.reasoning, 10, "reasoning 永远不超过账面 output")
        XCTAssertEqual(smallOutput.reasoning + smallOutput.output, 10)
    }
}
