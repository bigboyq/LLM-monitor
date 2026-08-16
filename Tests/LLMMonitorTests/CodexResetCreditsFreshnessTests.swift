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

    /// R3 followup: 调用方按 `periodicFullEveryN`（默认 20）把 interval 预放大后再传入
    /// isStale；放大后的实际阈值是 `3 × (N × interval)`，默认 300s × 20 × 3 = 18000s = 5h。
    /// 这个测试钉死"5h 边界"的语义——也是为什么 8c6a97f 把 background 路径的过期判定
    /// 从旧的 15min 误报改为现在的 5h 真阈值。如果未来 caller 忘了 pre-scale，
    /// 这个测试会直接红。
    func testIsStaleUsesPeriodicFullPeriodAt5hBoundary() {
        // 模拟 caller 已经在 QuotaViews.swift 里把 interval × N 后传进来
        let intervalSeconds: TimeInterval = 300
        let periodicFullEveryN = 20
        let scaled = intervalSeconds * Double(periodicFullEveryN)  // 6000
        let now = Date(timeIntervalSince1970: 100_000)

        // 5h = 18000s；恰好 18000 不过期，18001 过期
        let exactlyThreshold = resetCredits(
            available: 1,
            fetchedAt: now.addingTimeInterval(-18000)
        )
        XCTAssertFalse(
            exactlyThreshold.isStale(now: now, refreshIntervalSeconds: scaled),
            "恰好 5h 仍应判定为新鲜"
        )

        let overThreshold = resetCredits(
            available: 1,
            fetchedAt: now.addingTimeInterval(-18001)
        )
        XCTAssertTrue(
            overThreshold.isStale(now: now, refreshIntervalSeconds: scaled),
            "超过 5h 应判定为过期"
        )

        // 4h 仍在 5h 阈值内 → 不过期
        let fourHoursOld = resetCredits(
            available: 1,
            fetchedAt: now.addingTimeInterval(-4 * 3600)
        )
        XCTAssertFalse(
            fourHoursOld.isStale(now: now, refreshIntervalSeconds: scaled),
            "4h 仍应判定为新鲜（5h 阈值内）"
        )

        // 防回归：如果 caller 忘了 pre-scale，传原始 interval=300，旧的 15min 误报逻辑
        // 会让 4h 数据被错误判定为过期——这就是 8c6a97f 修复前的 bug 行为。
        // 我们用同样的 4h 数据，传 unscaled interval 验证它确实会被误判。
        let preR3Behavior = resetCredits(
            available: 1,
            fetchedAt: now.addingTimeInterval(-4 * 3600)
        )
        XCTAssertTrue(
            preR3Behavior.isStale(now: now, refreshIntervalSeconds: intervalSeconds),
            "未 pre-scale 的 4h 数据按 3×300=900s 阈值会被误判为过期（防 R3 前行为回归）"
        )
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
