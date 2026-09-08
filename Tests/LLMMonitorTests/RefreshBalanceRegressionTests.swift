import XCTest
import os
@testable import LLM_monitor

@MainActor
final class RefreshBalanceRegressionTests: XCTestCase {
    private actor SleepProbe {
        private var durations: [TimeInterval] = []

        func record(_ duration: TimeInterval) {
            durations.append(duration)
        }

        func allDurations() -> [TimeInterval] {
            durations
        }
    }

    /// The scheduler invokes the refresh handler before processOutcome records
    /// the regular next date.  That real path must still schedule reset+15s,
    /// rather than comparing the reset against the just-fired date.
    func testRegularRefreshSchedulesMidCycleAtResetPlusDelay() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sleepProbe = SleepProbe()
        var modes: [RefreshMode] = []
        var scheduler: ProviderRefreshScheduler?

        scheduler = ProviderRefreshScheduler(
            refreshHandler: { providerID, mode in
                modes.append(mode)
                if mode == .full {
                    scheduler?.scheduleMidCycleResetRefreshes(
                        for: providerID,
                        resetsAtDates: [now.addingTimeInterval(120)]
                    )
                } else if mode == .background {
                    scheduler?.cancelAll()
                }
                return .completed(success: true)
            },
            intervalProvider: { _ in 300 },
            now: { now },
            midCycleResetDelay: 15,
            sleep: { seconds in
                await sleepProbe.record(seconds)
                if seconds >= 200 {
                    // Keep the regular cycle asleep while the mid-cycle task
                    // wakes immediately in this deterministic test.
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        )

        scheduler?.schedule(for: "glm")
        for _ in 0..<100 where !modes.contains(.background) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertEqual(modes, [.full, .background])
        let durations = await sleepProbe.allDurations()
        XCTAssertTrue(
            durations.contains { abs($0 - 135) < 0.001 },
            "expected reset+15s sleep; got \(durations)"
        )
        scheduler?.cancelAll()
    }

    func testDisablingBalanceParsingClearsCachedBalancesButReadFailureKeepsThem() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-refresh-balance-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let scanner = GlmZcodeLocalUsageScanner(
            dbURL: URL(fileURLWithPath: "/missing-glm-db-\(UUID().uuidString)"),
            tasksDBURL: URL(fileURLWithPath: "/missing-glm-tasks-\(UUID().uuidString)"),
            cacheDir: cacheDir,
            balanceLogDirectory: URL(fileURLWithPath: "/missing-glm-logs-\(UUID().uuidString)")
        )
        let balance = GlmActivityPlanBalance(
            planID: "plan", planName: "Plan", entitlementID: "entitlement",
            showName: "GLM", modelNames: ["glm"], totalUnits: 100,
            usedUnits: 10, remainingUnits: 90,
            expiresAt: Date(timeIntervalSince1970: 1_700_086_400),
            observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let cached = GlmLocalUsage(
            today: nil, dailyTokenUsage: [], scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionCount: 0, eventCount: 0, failedSessionCount: 0,
            activityPlanBalances: [balance]
        )

        scanner.setBalanceLogParsingEnabled(false)
        let disabled = try scanner.rebaseSnapshot(cached, now: Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertNil(disabled.activityPlanBalances)

        scanner.setBalanceLogParsingEnabled(true)
        let readFailed = try scanner.rebaseSnapshot(cached, now: Date(timeIntervalSince1970: 1_700_000_002))
        XCTAssertEqual(readFailed.activityPlanBalances, [balance])
    }

    /// A manual reschedule with a still-future regular deadline must retain
    /// that deadline when deciding whether a reset deserves a fill-in refresh.
    func testManualMidCycleScheduleKeepsFutureRegularDeadline() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = OSAllocatedUnfairLock(initialState: now)
        let sleepProbe = SleepProbe()
        var scheduler: ProviderRefreshScheduler?
        scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .completed(success: true) },
            intervalProvider: { _ in 300 },
            now: { clock.withLock { $0 } },
            sleep: { seconds in
                await sleepProbe.record(seconds)
                if seconds >= 200 {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        )
        defer { scheduler?.cancelAll() }

        scheduler?.schedule(for: "glm")
        for _ in 0..<100 {
            if let next = scheduler?.earliestNextRefresh, next > now {
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(scheduler?.earliestNextRefresh, now.addingTimeInterval(300))
        // 半个周期后手动刷新。reset距原截止仅30s，不该因为重新从now算300s
        // 而误补刷新：原截止仍是base+300，不是base+450。
        clock.withLock { $0 = now.addingTimeInterval(150) }
        scheduler?.scheduleMidCycleResetRefreshes(
            for: "glm", resetsAtDates: [now.addingTimeInterval(270)]
        )
        try? await Task.sleep(nanoseconds: 30_000_000)

        let durations = await sleepProbe.allDurations()
        XCTAssertFalse(durations.contains { abs($0 - 135) < 0.001 }, "got \(durations)")
    }
}
