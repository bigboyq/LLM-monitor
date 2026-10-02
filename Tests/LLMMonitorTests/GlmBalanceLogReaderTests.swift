import XCTest
import SQLite3
@testable import LLM_monitor

final class GlmBalanceLogReaderTests: GlmTestCase {

    // MARK: - GLM 活动套餐余额日志解析 Tests

    /// 构造一条 `billing/balance 请求完成` 日志行。时间戳全部动态计算，
    /// 保证测试不随真实日期过期。
    private func makeBalanceLine(
        entitlementID: String = "ent_wk_test",
        observedAt: String = "2026-01-01 12:00:00.000",
        expiresAt: Int
    ) -> String {
        let json = """
        {"balanceCount":1,"code":0,"msg":"","payload":{"code":0,"msg":"","data":{"server_time":\(expiresAt),"plans":[{"plan_id":"zcode-test-plan","name":"ZCode Test Build","status":"active"}],"balances":[{"plan_id":"zcode-test-plan","entitlement_id":"\(entitlementID)","show_name":"GLM-5.3-Flash","capabilities":["model:glm-5.3-flash"],"total_units":300000000,"used_units":1000,"remaining_units":299999000,"expires_at":\(expiresAt)}]}},"success":true}
        """
        return "[\(observedAt)] [info] [usage-stats] billing/balance 请求完成 \(json)"
    }

    func testGlmBalanceLogReaderParsesBillingLine() throws {
        let now = Date()
        let expiresAt = Int(now.timeIntervalSince1970) + 86_400
        let balances = GlmZcodeBalanceLogReader.parseBalanceLine(
            makeBalanceLine(expiresAt: expiresAt), now: now
        )
        XCTAssertEqual(balances?.count, 1)
        let balance = try XCTUnwrap(balances?.first)
        XCTAssertEqual(balance.planID, "zcode-test-plan")
        XCTAssertEqual(balance.planName, "ZCode Test Build")
        XCTAssertEqual(balance.entitlementID, "ent_wk_test")
        XCTAssertEqual(balance.showName, "GLM-5.3-Flash")
        XCTAssertEqual(balance.modelNames, ["glm-5.3-flash"])
        XCTAssertEqual(balance.totalUnits, 300_000_000)
        XCTAssertEqual(balance.usedUnits, 1_000)
        XCTAssertEqual(balance.remainingUnits, 299_999_000)
        XCTAssertEqual(balance.expiresAt, Date(timeIntervalSince1970: Double(expiresAt)))
        XCTAssertNotNil(balance.observedAt, "日志行时间戳应被解析为快照观测时间")
    }

    func testGlmBalanceLogReaderPicksLastLineAndDropsExpired() {
        let now = Date()
        let expired = Int(now.timeIntervalSince1970) - 60
        let active = Int(now.timeIntervalSince1970) + 86_400
        let text = """
        noise line without marker
        \(makeBalanceLine(entitlementID: "ent_old", observedAt: "2026-01-01 11:00:00.000", expiresAt: expired))
        \(makeBalanceLine(entitlementID: "ent_new", observedAt: "2026-01-01 12:00:00.000", expiresAt: active))
        """
        // 取最后一条匹配行,且过期条目被剔除
        let balances = GlmZcodeBalanceLogReader.latestBalances(inLogText: text, now: now)
        XCTAssertEqual(balances?.map(\.entitlementID), ["ent_new"])

        // 只有已过期条目 → 解析成功但为空
        let onlyExpired = GlmZcodeBalanceLogReader.latestBalances(
            inLogText: makeBalanceLine(entitlementID: "ent_old", expiresAt: expired), now: now
        )
        XCTAssertEqual(onlyExpired, [])

        // 无标记行 → nil（无法解析,与"解析成功但为空"语义区分）
        XCTAssertNil(GlmZcodeBalanceLogReader.latestBalances(inLogText: "nothing here", now: now))
    }

    func testGlmBalanceLogReaderFallsBackToYesterdayFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-balance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        let active = Int(now.timeIntervalSince1970) + 86_400

        // 今天日志存在但没有任何 billing/balance 行 → 应回退到昨天的文件
        let todayURL = dir.appendingPathComponent(dayFormatter.string(from: now)).appendingPathExtension("log")
        try "startup noise\nno balance lines".write(to: todayURL, atomically: true, encoding: .utf8)
        let yesterdayURL = dir
            .appendingPathComponent(dayFormatter.string(from: now.addingTimeInterval(-86_400)))
            .appendingPathExtension("log")
        try makeBalanceLine(expiresAt: active)
            .write(to: yesterdayURL, atomically: true, encoding: .utf8)

        let balances = GlmZcodeBalanceLogReader.latestBalances(logDirectory: dir, now: now)
        XCTAssertEqual(balances?.first?.entitlementID, "ent_wk_test")

        // 两天都没有标记行 → nil
        try "nothing".write(to: todayURL, atomically: true, encoding: .utf8)
        try "nothing".write(to: yesterdayURL, atomically: true, encoding: .utf8)
        XCTAssertNil(GlmZcodeBalanceLogReader.latestBalances(logDirectory: dir, now: now))
    }

    @MainActor
    func testGlmScannerBalanceLogGating() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        try insert(databaseURL: db, id: "r1", sessionID: "s", turnID: "t1", timestamp: ms(Date()),
                   input: 10, output: 1)

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-scan-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-scan-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logDir) }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        let logURL = logDir.appendingPathComponent(dayFormatter.string(from: Date()))
            .appendingPathExtension("log")
        let expiresAt = Int(Date().timeIntervalSince1970) + 86_400
        try makeBalanceLine(expiresAt: expiresAt).write(to: logURL, atomically: true, encoding: .utf8)

        func makeScanner() -> GlmZcodeLocalUsageScanner {
            GlmZcodeLocalUsageScanner(
                dbURL: URL(fileURLWithPath: db),
                tasksDBURL: URL(fileURLWithPath: "/nonexistent-tasks-\(UUID().uuidString)"),
                cacheDir: cacheDir,
                balanceLogDirectory: logDir
            )
        }

        // 开关关闭（默认）→ 不读日志,快照不带活动套餐
        let disabled = makeScanner()
        let disabledSnapshot = try disabled.buildSnapshot(now: Date())
        XCTAssertNil(disabledSnapshot.activityPlanBalances)

        // 开关打开 → 快照携带解析出的余额
        let enabled = makeScanner()
        enabled.setBalanceLogParsingEnabled(true)
        let enabledSnapshot = try enabled.buildSnapshot(now: Date())
        XCTAssertEqual(enabledSnapshot.activityPlanBalances?.first?.entitlementID, "ent_wk_test")
    }

    func testGlmLocalUsageBalancesCodableBackwardCompatible() throws {
        // 旧快照 JSON 没有 activityPlanBalances 字段 → 解码为 nil,不破坏缓存
        let legacyJSON = #"{"dailyTokenUsage":[],"sessionCount":0,"eventCount":0,"failedSessionCount":0,"offPeakWindows":[]}"#
        let legacy = try JSONDecoder().decode(GlmLocalUsage.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.activityPlanBalances)

        // 含余额的新快照 round trip
        let balance = GlmActivityPlanBalance(
            planID: "zcode-test-plan", planName: "ZCode Test Build",
            entitlementID: "ent_wk_test", showName: "GLM-5.3-Flash",
            modelNames: ["glm-5.3-flash"], totalUnits: 300_000_000,
            usedUnits: 1_000, remainingUnits: 299_999_000,
            expiresAt: Date(timeIntervalSince1970: 1_788_138_000),
            observedAt: Date(timeIntervalSince1970: 1_787_922_023)
        )
        let usage = GlmLocalUsage(
            today: nil, dailyTokenUsage: [], scannedAt: nil, sessionCount: 0,
            eventCount: 0, failedSessionCount: 0, activityPlanBalances: [balance]
        )
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(GlmLocalUsage.self, from: data)
        XCTAssertEqual(decoded, usage)
    }

    func testProviderConfigParseZcodeBalanceLogDefaultsOff() throws {
        // 字段缺失 = 关闭（nil）,不写回配置文件
        let json = #"{"enabled":true}"#
        let config = try JSONDecoder().decode(ProviderConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.parseZcodeBalanceLog)

        // 开启时显式写 true 并可往返
        let encoded = try JSONEncoder().encode(
            ProviderConfig(enabled: true, parseZcodeBalanceLog: true)
        )
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: encoded)
        XCTAssertEqual(decoded.parseZcodeBalanceLog, true)
    }
    // MARK: - 解析开关对缓存余额的语义（自 ProviderRefreshSchedulerTests 归位）
    @MainActor
    func testDisablingBalanceParsingClearsCachedBalancesButReadFailureKeepsThem() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-refresh-balance-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-refresh-balance-missing-\(UUID().uuidString)", isDirectory: true)

        let scanner = GlmZcodeLocalUsageScanner(
            dbURL: missingRoot.appendingPathComponent("db.sqlite"),
            tasksDBURL: missingRoot.appendingPathComponent("tasks.sqlite"),
            cacheDir: cacheDir,
            balanceLogDirectory: missingRoot.appendingPathComponent("logs", isDirectory: true)
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
}
