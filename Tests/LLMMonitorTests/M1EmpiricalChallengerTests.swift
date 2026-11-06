import XCTest
@testable import LLM_monitor

final class M1EmpiricalChallengerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LocalUsagePriceByDay.reset()
        HolidayCalendar.applyResolved(.empty)
    }

    override func tearDown() {
        LocalUsagePriceByDay.reset()
        HolidayCalendar.applyResolved(HolidayCalendar.loadBundled())
        super.tearDown()
    }

    private func makeModelQuota(remainingPercent: Double) -> ModelQuota {
        ModelQuota(
            modelName: "deepseek-chat",
            intervalTotalCount: 100,
            intervalUsageCount: Int(100.0 - remainingPercent),
            intervalRemainingPercent: remainingPercent,
            intervalStatus: .present,
            intervalResetsAt: Date().addingTimeInterval(3600),
            intervalWindowSeconds: 18000,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 0,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
    }

    private func makeDeepSeekStatus(balance: Double?, models: [ModelQuota] = []) -> ProviderStatus {
        let balanceDetail = balance.map {
            DeepseekBalanceDetail(
                currency: "CNY",
                total: $0,
                toppedUp: $0,
                granted: 0
            )
        }
        return ProviderStatus(
            id: "deepseek",
            displayName: "DeepSeek",
            kind: .deepseek,
            iconSystemName: "brain",
            accentColor: .deepseek,
            refreshIntervalSeconds: 60,
            state: .ok(QuotaInfo(
                models: models,
                resetCredits: nil,
                planLabel: nil,
                accountEmail: nil,
                codexUsageDetails: nil,
                fetchedAt: Date(),
                balanceDetail: balanceDetail
            ))
        )
    }

    // MARK: - 1. DeepSeek Health Level Dense Grid & Boundary Stress

    func testDeepSeekHealthLevelDenseGridEquivalence() {
        // Oracle definition matching pre-M1 inline implementation in ProviderStatus.swift:
        func oracleHealth(balance: Double, critical: Double, warning: Double) -> HealthLevel {
            if balance <= 0 || balance < critical {
                return .critical
            } else if balance < warning {
                return .warning
            } else {
                return .healthy
            }
        }

        let configs: [AlertThresholdConfig] = [
            AlertThresholdConfig.default, // critical: 3.0, warning: 10.0
            AlertThresholdConfig(apiQuotaWarningPercent: 60, apiQuotaCriticalPercent: 30, deepseekBalanceWarning: 15.0, deepseekBalanceCritical: 5.0),
            AlertThresholdConfig(apiQuotaWarningPercent: 60, apiQuotaCriticalPercent: 30, deepseekBalanceWarning: 20.0, deepseekBalanceCritical: 20.0), // equal thresholds
            AlertThresholdConfig(apiQuotaWarningPercent: 60, apiQuotaCriticalPercent: 30, deepseekBalanceWarning: 0.0, deepseekBalanceCritical: 0.0),   // zero thresholds
        ]

        let testBalances: [Double] = [
            -1_000_000.0, -100.0, -1.0, -0.000001, -Double.leastNonzeroMagnitude,
            0.0,
            Double.leastNonzeroMagnitude, 0.000001, 0.5, 1.0, 2.0, 2.999999, 3.0, 3.000001,
            4.999999, 5.0, 5.000001, 7.5, 9.999999, 10.0, 10.000001,
            14.999999, 15.0, 15.000001, 19.999999, 20.0, 20.000001,
            50.0, 100.0, 999_999.0, Double.greatestFiniteMagnitude
        ]

        for config in configs {
            let crit = config.deepseekBalanceCritical
            let warn = config.deepseekBalanceWarning

            // 1. Specific boundary points
            for balance in testBalances {
                let actual = config.deepseekHealthLevel(balance: balance)
                let expected = oracleHealth(balance: balance, critical: crit, warning: warn)
                XCTAssertEqual(
                    actual,
                    expected,
                    "Mismatch for balance=\(balance) with critical=\(crit), warning=\(warn)"
                )
            }

            // 2. Dense random points in [-50, +50]
            for i in 0..<2000 {
                let r = Double(i) * 0.05 - 50.0
                let actual = config.deepseekHealthLevel(balance: r)
                let expected = oracleHealth(balance: r, critical: crit, warning: warn)
                XCTAssertEqual(
                    actual,
                    expected,
                    "Mismatch for random balance=\(r) with critical=\(crit), warning=\(warn)"
                )
            }

            // 3. Nil balance behavior
            XCTAssertEqual(
                config.deepseekHealthLevel(balance: nil),
                .critical,
                "Nil balance must always return .critical"
            )
        }
    }

    func testProviderStatusDeepSeekFullDerivation() {
        let thresholds = AlertThresholdConfig.default

        // Case A: Balance is present
        let statusHealthy = makeDeepSeekStatus(balance: 50.0)
        XCTAssertEqual(statusHealthy.aggregateHealthLevel(alertThresholds: thresholds), HealthLevel.healthy)

        let statusWarning = makeDeepSeekStatus(balance: 5.0)
        XCTAssertEqual(statusWarning.aggregateHealthLevel(alertThresholds: thresholds), HealthLevel.warning)

        let statusCritical = makeDeepSeekStatus(balance: 1.0)
        XCTAssertEqual(statusCritical.aggregateHealthLevel(alertThresholds: thresholds), HealthLevel.critical)

        let statusZeroBalance = makeDeepSeekStatus(balance: 0.0)
        XCTAssertEqual(statusZeroBalance.aggregateHealthLevel(alertThresholds: thresholds), HealthLevel.critical)

        let statusNegativeBalance = makeDeepSeekStatus(balance: -10.0)
        XCTAssertEqual(statusNegativeBalance.aggregateHealthLevel(alertThresholds: thresholds), HealthLevel.critical)

        // Case B: Balance is nil, fallback to aggregateQuotaModels
        let modelPositive = makeModelQuota(remainingPercent: 50.0)
        let statusFallbackModelPositive = makeDeepSeekStatus(balance: nil, models: [modelPositive])
        XCTAssertEqual(statusFallbackModelPositive.aggregateHealthLevel(alertThresholds: thresholds), HealthLevel.healthy)

        let modelZero = makeModelQuota(remainingPercent: 0.0)
        let statusFallbackModelZero = makeDeepSeekStatus(balance: nil, models: [modelZero])
        XCTAssertEqual(statusFallbackModelZero.aggregateHealthLevel(alertThresholds: thresholds), HealthLevel.critical)

        // Case C: Neither balance nor models present
        let statusFallbackEmpty = makeDeepSeekStatus(balance: nil, models: [])
        XCTAssertEqual(statusFallbackEmpty.aggregateHealthLevel(alertThresholds: thresholds), HealthLevel.critical)
    }

    // MARK: - 2. Start-of-Day Cutoff Invariance Across Timezones & Dates

    func testDailyUsageAggregationTodayCutoffInvariance() {
        let timezones = [
            "UTC",
            "Asia/Shanghai",
            "America/New_York",
            "Europe/London",
            "Pacific/Auckland",
            "Pacific/Honolulu",
            "Asia/Kathmandu", // +05:45 non-integer offset
            "America/St_Johns" // -03:30 Newfoundland
        ].compactMap { TimeZone(identifier: $0) }

        // Test spanning leap years, standard years, century boundaries, DST transitions:
        let testTimestamps: [TimeInterval] = [
            0.0, // 1970-01-01 00:00:00 UTC
            1577836800.0, // 2020-01-01 00:00:00 UTC (Leap year start)
            1582934400.0, // 2020-02-29 00:00:00 UTC (Leap day)
            1583020799.0, // 2020-02-29 23:59:59 UTC (Leap day end)
            1678586400.0, // 2023-03-12 (US Spring DST switch)
            1699149600.0, // 2023-11-05 (US Fall DST switch)
            1772323200.0, // 2026-03-01 00:00:00 UTC
            1772366400.0, // 2026-03-01 12:00:00 UTC
            1772409599.999 // 2026-03-01 23:59:59.999 UTC
        ]

        for tz in timezones {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz

            for ts in testTimestamps {
                let now = Date(timeIntervalSince1970: ts)

                let cutoff = DailyUsageAggregation.todayCutoff(now: now, calendar: cal)
                let oracle = cal.startOfDay(for: now)

                XCTAssertEqual(
                    cutoff,
                    oracle,
                    "Cutoff mismatch for timestamp \(ts) in timezone \(tz.identifier)"
                )

                // Verify cutoff is strictly <= now
                XCTAssertLessThanOrEqual(cutoff, now)

                // Verify cutoff plus 1 day is strictly > now
                if let nextDay = cal.date(byAdding: .day, value: 1, to: cutoff) {
                    XCTAssertGreaterThan(nextDay, now)
                }
            }
        }
    }

    // MARK: - 3. Formatters Countdown Math Oracle Equivalence

    func testRelativeCountdownOracleEquivalence() {
        // Pre-M1 Billing duration implementation
        func oracleBilling(_ seconds: TimeInterval) -> String {
            guard seconds > 0 else { return "已到期" }
            let total = Int(seconds.rounded())
            let days = total / 86400
            let hours = (total % 86400) / 3600
            let minutes = (total % 3600) / 60
            if days > 0 {
                return hours > 0 ? "\(days)天\(hours)小时后" : "\(days)天后"
            } else if hours > 0 {
                return minutes > 0 ? "\(hours)小时\(minutes)分后" : "\(hours)小时后"
            } else {
                return "\(max(minutes, 1))分后"
            }
        }

        // Pre-M1 GlmActivityPlanBalancesView.formatEffectiveCountdown implementation
        func oracleGlmEffective(_ seconds: TimeInterval) -> String {
            guard seconds > 0 else { return "已生效" }
            let total = Int(seconds.rounded())
            let days = total / 86400
            let hours = (total % 86400) / 3600
            let minutes = (total % 3600) / 60
            if days > 0 {
                return hours > 0 ? "\(days)天\(hours)小时后生效" : "\(days)天后生效"
            } else if hours > 0 {
                return minutes > 0 ? "\(hours)小时\(minutes)分后生效" : "\(hours)小时后生效"
            } else {
                return "\(max(minutes, 1))分后生效"
            }
        }

        // Pre-M1 GlmActivityPlanBalancesView.formatExpiryCountdown implementation
        func oracleGlmExpiry(_ seconds: TimeInterval) -> String {
            guard seconds > 0 else { return "已失效" }
            let total = Int(seconds.rounded())
            let days = total / 86400
            let hours = (total % 86400) / 3600
            let minutes = (total % 3600) / 60
            if days > 0 {
                return hours > 0 ? "剩余\(days)天\(hours)小时" : "剩余\(days)天"
            } else if hours > 0 {
                return minutes > 0 ? "剩余\(hours)小时\(minutes)分" : "剩余\(hours)小时"
            } else {
                return "剩余\(max(minutes, 1))分"
            }
        }

        // Pre-M1 ChatGPTApiCreditsRow.expiryCountdownText implementation
        func oracleChatGptExpiry(_ seconds: TimeInterval) -> String {
            guard seconds > 0 else { return "已到期" }
            let total = Int(seconds.rounded())
            let days = total / 86400
            let hours = (total % 86400) / 3600
            let minutes = (total % 3600) / 60
            if days > 0 {
                return "剩余\(days)天"
            } else if hours > 0 {
                return minutes > 0 ? "剩余\(hours)小时\(minutes)分" : "剩余\(hours)小时"
            } else {
                return "剩余\(max(minutes, 1))分"
            }
        }

        // Boundary seconds test vector
        var testSeconds: [Double] = [
            -1000.0, -60.0, -1.0, -0.001, 0.0,
            0.1, 0.49, 0.5, 0.51, 1.0, 29.0, 59.4, 59.5, 60.0, 60.4, 60.5, 61.0,
            119.4, 119.5, 120.0,
            3599.0, 3599.4, 3599.5, 3600.0, 3601.0,
            7199.0, 7200.0, 7201.0,
            86399.0, 86399.4, 86399.5, 86400.0, 86400.5, 86401.0,
            86400.0 + 3599.0, 86400.0 + 3600.0, 86400.0 + 3601.0,
            172800.0, 172800.0 + 7200.0, 1000000.0
        ]

        // Add dense grid around minute boundaries, hour boundaries, day boundaries
        for m in 1...120 {
            testSeconds.append(Double(m * 60))
        }
        for h in 1...48 {
            testSeconds.append(Double(h * 3600))
            testSeconds.append(Double(h * 3600) + 120.0)
        }

        for sec in testSeconds {
            // 1. Billing
            let billingActual = Formatters.formatBillingRemainingDuration(sec)
            let billingExpected = oracleBilling(sec)
            XCTAssertEqual(billingActual, billingExpected, "Billing mismatch at sec=\(sec)")

            // 2. GLM Effective
            let effActual = Formatters.formatRelativeCountdown(
                sec,
                suffix: "后生效",
                expiredText: "已生效"
            )
            let effExpected = oracleGlmEffective(sec)
            XCTAssertEqual(effActual, effExpected, "Glm effective mismatch at sec=\(sec)")

            // 3. GLM Expiry
            let expActual = Formatters.formatRelativeCountdown(
                sec,
                prefix: "剩余",
                expiredText: "已失效"
            )
            let expExpected = oracleGlmExpiry(sec)
            XCTAssertEqual(expActual, expExpected, "Glm expiry mismatch at sec=\(sec)")

            // 4. ChatGPT Expiry (includeHoursWhenDays: false)
            let gptActual = Formatters.formatRelativeCountdown(
                sec,
                prefix: "剩余",
                expiredText: "已到期",
                includeHoursWhenDays: false
            )
            let gptExpected = oracleChatGptExpiry(sec)
            XCTAssertEqual(gptActual, gptExpected, "ChatGPT expiry mismatch at sec=\(sec)")
        }
    }

    // MARK: - 4. LocalUsagePriceByDay estimateMemo Caching & Invalidation

    func testLocalUsagePriceByDayEstimatesMemoLifecycle() {
        LocalUsagePriceByDay.reset()
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 0)

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dayStarts = (0..<7).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }

        let sample1 = LocalTokenUsageSample(
            completedAt: today,
            modelName: "deepseek-chat",
            promptID: "req-1",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 200,
            reasoningOutputTokens: 0
        )

        // 1. First invocation -> miss, computeCount becomes 1
        let result1 = LocalUsagePriceByDay.estimates(
            dayStarts: dayStarts,
            recentSamples: [sample1],
            quotaProviderID: "deepseek",
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 1)
        XCTAssertFalse(result1.isEmpty)

        // 2. Second invocation with identical inputs -> hit, computeCount stays 1
        let result2 = LocalUsagePriceByDay.estimates(
            dayStarts: dayStarts,
            recentSamples: [sample1],
            quotaProviderID: "deepseek",
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 1)
        XCTAssertEqual(result1, result2)

        // 3. Invalidation by HolidayCalendar
        HolidayCalendar.applyResolved(.empty)
        let sample2 = LocalTokenUsageSample(
            completedAt: today,
            modelName: "deepseek-chat",
            promptID: "req-2",
            inputTokens: 300,
            cachedInputTokens: 50,
            outputTokens: 400,
            reasoningOutputTokens: 0
        )
        let result3 = LocalUsagePriceByDay.estimates(
            dayStarts: dayStarts,
            recentSamples: [sample1, sample2],
            quotaProviderID: "deepseek",
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 2)
        XCTAssertNotEqual(result1, result3)

        // 4. Invalidation by different quotaProviderID
        _ = LocalUsagePriceByDay.estimates(
            dayStarts: dayStarts,
            recentSamples: [sample1, sample2],
            quotaProviderID: "minimax",
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 3)

        // 5. Reset
        LocalUsagePriceByDay.reset()
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 0)
    }
}
