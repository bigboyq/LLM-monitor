import XCTest
import Foundation
@testable import LLM_monitor

/// R3: Codex reset credits 独立新鲜度。通过 `CodexFillingMissingMerger`（纯函数）
/// 覆盖：首次失败无旧值、成功后失败、连续失败、恢复成功、background 跳过不冒充失败。
final class CodexResetCreditsFreshnessTests: XCTestCase {

    private let merger = CodexFillingMissingMerger()

    private func resetCredits(available: Int, fetchedAt: Date, failed: Bool = false) -> ResetCreditsInfo {
        ResetCreditsInfo(
            entries: (0..<available).map { i in
                ResetCreditEntry(
                    id: "c\(i)",
                    status: "available",
                    expiresAt: Date().addingTimeInterval(86_400),
                    grantedAt: nil,
                    resetType: nil,
                    title: nil,
                    description: nil
                )
            },
            serverAvailableCount: available,
            totalEarnedCount: available,
            fetchedAt: fetchedAt,
            lastAttemptFailed: failed
        )
    }

    private func quota(resetCredits: ResetCreditsInfo?, fetchedAt: Date = Date()) -> QuotaInfo {
        QuotaInfo(
            models: [],
            resetCredits: resetCredits,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: fetchedAt
        )
    }

    /// 首次 full 失败、无旧值 → 没有 resetCredits 可显示，整张卡不算失败。
    func testFirstFullFailureWithNoPreviousLeavesNoResetCredits() {
        let new = quota(resetCredits: nil)  // full 抓取但 reset credits 失败
        let merged = merger.merge(new: new, previous: nil, mode: .full)
        XCTAssertNil(merged.resetCredits, "无旧值时 reset credits 失败不应凭空产生数据")
    }

    /// 成功后失败：previous 有 fresh 值，full 抓取 reset credits 失败 → 保留旧值并标记过期。
    func testSuccessThenFullFailureMarksStale() {
        let prevFetchedAt = Date().addingTimeInterval(-300)
        let previous = quota(resetCredits: resetCredits(available: 3, fetchedAt: prevFetchedAt))
        // 下一次 full：主 quota 成功，但 reset credits 子请求失败（new.resetCredits = nil）
        let new = quota(resetCredits: nil)
        let merged = merger.merge(new: new, previous: previous, mode: .full)

        let resets = merged.resetCredits
        XCTAssertEqual(resets?.availableCount, 3, "保留上次的 reset credits 值")
        XCTAssertEqual(resets?.fetchedAt, prevFetchedAt, "保留上次的实际抓取时间，不用主 fetchedAt 冒充")
        XCTAssertTrue(resets?.lastAttemptFailed == true, "full 失败应标记过期")
    }

    /// 连续失败：旧值与过期标志继续保留。
    func testConsecutiveFullFailuresKeepStaleValue() {
        let prevFetchedAt = Date().addingTimeInterval(-600)
        let stalePrev = quota(resetCredits: resetCredits(available: 2, fetchedAt: prevFetchedAt, failed: true))
        let new = quota(resetCredits: nil)
        let merged = merger.merge(new: new, previous: stalePrev, mode: .full)

        XCTAssertEqual(merged.resetCredits?.availableCount, 2)
        XCTAssertEqual(merged.resetCredits?.fetchedAt, prevFetchedAt)
        XCTAssertTrue(merged.resetCredits?.lastAttemptFailed == true)
    }

    /// 恢复成功：full 抓取重新拿到 reset credits → 清除失败标志，更新时间。
    func testRecoveryFullSuccessClearsStale() {
        let stalePrev = quota(resetCredits: resetCredits(available: 2, fetchedAt: Date().addingTimeInterval(-600), failed: true))
        let freshAt = Date()
        let new = quota(resetCredits: resetCredits(available: 5, fetchedAt: freshAt), fetchedAt: freshAt)
        let merged = merger.merge(new: new, previous: stalePrev, mode: .full)

        XCTAssertEqual(merged.resetCredits?.availableCount, 5, "用新的成功值")
        XCTAssertEqual(merged.resetCredits?.fetchedAt, freshAt)
        XCTAssertFalse(merged.resetCredits?.lastAttemptFailed ?? true, "恢复成功应清除过期标志")
    }

    /// background 刷新按设计跳过 reset credits：保留 previous 值与新鲜度，不冒充失败。
    func testBackgroundSkipDoesNotMasqueradeAsFailure() {
        let prevFetchedAt = Date().addingTimeInterval(-120)
        let freshPrev = quota(resetCredits: resetCredits(available: 4, fetchedAt: prevFetchedAt, failed: false))
        let new = quota(resetCredits: nil)  // background 不请求 reset credits
        let merged = merger.merge(new: new, previous: freshPrev, mode: .background)

        XCTAssertEqual(merged.resetCredits?.availableCount, 4)
        XCTAssertEqual(merged.resetCredits?.fetchedAt, prevFetchedAt, "不更新时间")
        XCTAssertFalse(merged.resetCredits?.lastAttemptFailed ?? true, "background 跳过不算失败")
    }

    /// isStale：失败立即过期；成功但年龄超过 max(3×interval, 15min) 过期；新鲜不过期。
    func testIsStaleThresholds() {
        let interval: TimeInterval = 300
        let now = Date(timeIntervalSince1970: 10_000)

        // 失败 → 立即过期
        let failed = resetCredits(available: 1, fetchedAt: now, failed: true)
        XCTAssertTrue(failed.isStale(now: now, refreshIntervalSeconds: interval))

        // 新鲜 → 不过期
        let fresh = resetCredits(available: 1, fetchedAt: now.addingTimeInterval(-60))
        XCTAssertFalse(fresh.isStale(now: now, refreshIntervalSeconds: interval))

        // 年龄 > max(3×300=900, 900) = 900s → 过期；恰好 900 不过期，901 过期
        let boundary = resetCredits(available: 1, fetchedAt: now.addingTimeInterval(-900))
        XCTAssertFalse(boundary.isStale(now: now, refreshIntervalSeconds: interval))
        let over = resetCredits(available: 1, fetchedAt: now.addingTimeInterval(-901))
        XCTAssertTrue(over.isStale(now: now, refreshIntervalSeconds: interval))

        // 小间隔 provider 仍至少 15 分钟才按年龄过期：interval=10s → max(30, 900)=900
        let smallInterval = resetCredits(available: 1, fetchedAt: now.addingTimeInterval(-500))
        XCTAssertFalse(smallInterval.isStale(now: now, refreshIntervalSeconds: 10))
    }

    /// R3 Codable 向后兼容：旧格式（无 fetchedAt/lastAttemptFailed）能解码。
    func testResetCreditsCodableBackwardCompat() throws {
        let oldJSON = """
        {"entries":[],"serverAvailableCount":2,"totalEarnedCount":3}
        """
        let decoded = try JSONDecoder().decode(ResetCreditsInfo.self, from: Data(oldJSON.utf8))
        XCTAssertEqual(decoded.serverAvailableCount, 2)
        XCTAssertNil(decoded.fetchedAt, "旧数据缺省 fetchedAt 为 nil")
        XCTAssertFalse(decoded.lastAttemptFailed, "旧数据缺省 lastAttemptFailed 为 false")
    }
}
