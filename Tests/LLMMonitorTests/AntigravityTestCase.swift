import XCTest
import SQLite3
@testable import LLM_monitor

/// Antigravity 本地用量测试的共享基类：只放被 9 个测试类共同使用的两个 fixture。
/// 拆自原 3315 行的 `AntigravityLocalUsageTests` 单体类。
class AntigravityTestCase: XCTestCase {

    // MARK: - 共享 fixture
    //
    // 这些成员刻意不是 `private`：10 个测试类都继承本基类且分布在不同文件，
    // `private` 在跨文件时不可见。原先它们是同一个类里的 private，拆分后必须放开。

    func makeEvent(
        timestamp: Date?,
        model: String? = nil,
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int = 0,
        total: Int = 0,
        stepIndices: [Int]? = nil,
        missingComponents: [String]? = nil
    ) -> AntigravityFetcher.UsageEvent {
        AntigravityFetcher.UsageEvent(
            timestamp: timestamp,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            reasoningTokens: reasoning,
            totalTokens: total,
            stepIndices: stepIndices,
            missingComponents: missingComponents
        )
    }

    var testCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
}
