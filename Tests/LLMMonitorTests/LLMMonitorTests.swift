import XCTest
import SQLite3
import Combine
import AppKit
@testable import LLM_monitor

final class LLMMonitorTests: XCTestCase {

    func testBuiltInProviderIDsAreStableConfigurationKeys() {
        XCTAssertEqual(ProviderKind.minimaxTokenPlan.providerID, "minimax_token_plan")
        XCTAssertEqual(ProviderKind.codexChatGpt.providerID, "codex_chatgpt")
        XCTAssertEqual(ProviderKind.antigravity.providerID, "antigravity")
        XCTAssertEqual(ProviderKind.glmCodingPlan.providerID, "glm_coding_plan")
    }

    // MARK: - Formatters / Equivalent Quota Allocation

    /// 数字格式化 2 in 1：formatTokenCountCompact (K/M) + formatPercent (% / 小数位)
    func testFormattersTokenAndPercent() {
        // formatTokenCountCompact: 999 / 3,000 / 30K / 1,234K / 3,000K / 30M / 1,234M
        XCTAssertEqual(Formatters.formatTokenCountCompact(999), "999")
        XCTAssertEqual(Formatters.formatTokenCountCompact(3_000), "3,000")
        XCTAssertEqual(Formatters.formatTokenCountCompact(30_000), "30K")
        XCTAssertEqual(Formatters.formatTokenCountCompact(1_234_567), "1,234K")
        XCTAssertEqual(Formatters.formatTokenCountCompact(3_000_000), "3,000K")
        XCTAssertEqual(Formatters.formatTokenCountCompact(30_000_000), "30M")
        XCTAssertEqual(Formatters.formatTokenCountCompact(1_234_567_890), "1,234M")
        // formatPercent: 默认整数 / digits=1 一位小数
        XCTAssertEqual(Formatters.formatPercent(0.44), "44%")
        XCTAssertEqual(Formatters.formatPercent(0.6432, digits: 1), "64.3%")
    }

    /// 时间格式化 2 in 1：formatResetSuffix (5 阶梯压缩) + formatClock (跨日切月日)
    func testFormattersTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // formatResetSuffix 5 阶梯: 3d / 1d5h / 5h / 1h23m / 23m / 已过期
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(3 * 86400), now: now), "3d")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(7 * 86400 + 3600), now: now), "7d")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(1 * 86400 + 5 * 3600), now: now), "1d5h")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(2 * 86400), now: now), "2d0h")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(5 * 3600), now: now), "5h")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(1 * 3600 + 23 * 60), now: now), "1h23m")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(1 * 3600), now: now), "1h00m")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(23 * 60), now: now), "23m")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(1 * 60), now: now), "1m")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now, now: now), "已过期")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(-3600), now: now), "已过期")
        // formatClock: 同日只显示 HH:MM, 跨日显示 MM-DD HH:MM
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let baseTime = formatter.date(from: "2026-07-08 12:00:00")!
        let sameDay = formatter.date(from: "2026-07-08 21:32:00")!
        let diffDay = formatter.date(from: "2026-07-09 21:32:00")!
        XCTAssertEqual(Formatters.formatClock(sameDay, now: baseTime), "21:32")
        XCTAssertEqual(Formatters.formatClock(diffDay, now: baseTime), "07-09 21:32")
    }

    /// EquivalentQuotaAllocation.segmentFills 3 in 1：
    /// - weekly < primary*segments → weekly 限死 (binding constraint), primary 切小
    /// - primary + 后续 weekly 占用 2 段以上 → 分离
    /// - 后续段从 primary 紧接 (无 gap)
    func testEquivalentQuotaAllocationSegmentFills() {
        // 1. 周限 < 当前 primary 总量: primary 被切到 weekly 限额, 后续段全 0
        do {
            let fills = EquivalentQuotaAllocation.segmentFills(
                primaryFraction: 1, weeklyFraction: 0.08, segments: 10
            )
            XCTAssertEqual(fills.count, 10)
            XCTAssertEqual(fills[0], 0.8, accuracy: 0.000_001)
            XCTAssertTrue(fills.dropFirst().allSatisfy { $0 == 0 },
                          "weekly=0.08 比 primary 限死 0.8, 后续段全 0")
        }
        // 2. 当前 + 后续 weekly 各占独立段, 不重叠
        do {
            let fills = EquivalentQuotaAllocation.segmentFills(
                primaryFraction: 0.8, weeklyFraction: 0.12, segments: 10
            )
            XCTAssertEqual(fills.count, 10)
            XCTAssertEqual(fills[0], 0.8, accuracy: 0.000_001)
            XCTAssertEqual(fills[1], 0.4, accuracy: 0.000_001)
            XCTAssertTrue(fills.dropFirst(2).allSatisfy { $0 == 0 })
        }
        // 3. weekly 余量足够时, 后续段紧接 primary 满格, 最后一个段 = 剩余 weekly
        do {
            let fills = EquivalentQuotaAllocation.segmentFills(
                primaryFraction: 0.8, weeklyFraction: 0.42, segments: 10
            )
            XCTAssertEqual(fills.count, 10)
            XCTAssertEqual(fills[0], 0.8, accuracy: 0.000_001)
            XCTAssertEqual(Array(fills[1...3]), [1.0, 1.0, 1.0], "后续 3 段 weekly 余量足, 满格")
            XCTAssertEqual(fills[4], 0.4, accuracy: 0.000_001, "最后一段 = 剩余 weekly 比例")
            XCTAssertTrue(fills.dropFirst(5).allSatisfy { $0 == 0 })
        }
    }

    // MARK: - Minimax Parsing Tests
    
    func testMinimaxParse() throws {
        let minimaxJson = """
        {
          "model_remains": [
            {
              "start_time": 1783234800000,
              "end_time": 1783252800000,
              "remains_time": 10629565,
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "model_name": "general",
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "weekly_start_time": 1782662400000,
              "weekly_end_time": 1783267200000,
              "weekly_remains_time": 25029565,
              "current_interval_status": 1,
              "current_interval_remaining_percent": 54,
              "current_weekly_status": 1,
              "current_weekly_remaining_percent": 64
            }
          ],
          "base_resp": {
            "status_code": 0,
            "status_msg": "success"
          }
        }
        """
        
        let data = minimaxJson.data(using: .utf8)!
        let info = try MinimaxTokenPlanFetcher.parse(data: data)

        XCTAssertEqual(info.models.count, 1)
        XCTAssertEqual(info.models[0].modelName, "general")
        XCTAssertEqual(info.models[0].intervalRemainingPercent, 54.0)
        XCTAssertEqual(info.models[0].weeklyRemainingPercent, 64.0)
    }

    /// base_resp.status_code=1004 应映射为 401，其他非零业务码仍抛 decodingError。
    /// 之前用 JSONSerialization 时这路径是手写 if-else，现在走 JSONDecoder + custom init。
    func testMinimaxParseBaseRespError() {
        let errorJson = """
        {
          "model_remains": [],
          "base_resp": { "status_code": 1004, "status_msg": "login fail: Please carry the API secret key" }
        }
        """
        let data = errorJson.data(using: .utf8)!
        do {
            _ = try MinimaxTokenPlanFetcher.parse(data: data)
            XCTFail("expected QuotaError.httpError, got success")
        } catch let error as QuotaError {
            if case .httpError(let status, let body) = error {
                XCTAssertEqual(status, 401)
                XCTAssertTrue(body.contains("1004") == false, "用户错误文案不应依赖内部业务码: \(body)")
                XCTAssertTrue(body.contains("API Key"))
            } else {
                XCTFail("expected .httpError, got \(error)")
            }
        } catch {
            XCTFail("expected QuotaError, got \(error)")
        }
    }

    /// model_remains 数组为空 → 抛 .decodingError("model_remains 数组为空")。
    /// 即便 base_resp 成功也不行（minimax 返回空 list 说明服务端数据异常）。
    func testMinimaxParseEmptyModelRemains() {
        let emptyJson = """
        {
          "model_remains": [],
          "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """
        let data = emptyJson.data(using: .utf8)!
        do {
            _ = try MinimaxTokenPlanFetcher.parse(data: data)
            XCTFail("expected QuotaError, got success")
        } catch let error as QuotaError {
            if case .decodingError(let msg) = error {
                XCTAssertTrue(msg.contains("model_remains"), "expected msg to mention model_remains, got: \(msg)")
            } else {
                XCTFail("expected .decodingError, got \(error)")
            }
        } catch {
            XCTFail("expected QuotaError, got \(error)")
        }
    }

    /// 单条 record 缺 `model_name` → 这条 record 跳过，其他正常 record 仍能进。
    /// 之前用 JSONSerialization 跟 `guard let modelName = ... else { continue }` 实现，
    /// 现在用 JSONDecoder 的 `init(from:)` 抛 keyNotFound 后由 `compactMap` 过滤。
    func testMinimaxParseRecordMissingModelNameSkipped() throws {
        let mixedJson = """
        {
          "model_remains": [
            {
              "model_name": "general",
              "end_time": 1783252800000,
              "weekly_end_time": 1783267200000,
              "current_interval_remaining_percent": 50,
              "current_weekly_remaining_percent": 60
            },
            {
              "end_time": 1783252800000,
              "current_interval_remaining_percent": 30,
              "current_weekly_remaining_percent": 40
            },
            {
              "model_name": "video",
              "end_time": 1783252800000,
              "weekly_end_time": 1783267200000,
              "current_interval_remaining_percent": 70,
              "current_weekly_remaining_percent": 80
            }
          ],
          "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """
        let data = mixedJson.data(using: .utf8)!
        let info = try MinimaxTokenPlanFetcher.parse(data: data)
        XCTAssertEqual(info.models.count, 2)
        XCTAssertEqual(info.models.map(\.modelName), ["general", "video"])
        XCTAssertEqual(info.models[0].intervalRemainingPercent, 50.0)
        XCTAssertEqual(info.models[1].intervalRemainingPercent, 70.0)
    }

    /// 计数字段的严格 JSON 数字校验（在 `MinimaxModelRemain.init(from:)` 内完成）：
    /// - 小数（1.5）/ 负数 / 布尔 / 字符串 → 抛 decodingError
    /// - 缺失 → 按历史兼容路径视为 0，整体解析成功
    func testMinimaxParseStrictCountValidation() throws {
        func makeData(countField: String, value: String) -> Data {
            """
            {
              "model_remains": [
                {
                  "model_name": "general",
                  "end_time": 1783252800000,
                  "weekly_end_time": 1783267200000,
                  "current_interval_remaining_percent": 50,
                  "current_weekly_remaining_percent": 60,
                  "\(countField)": \(value)
                }
              ],
              "base_resp": { "status_code": 0, "status_msg": "success" }
            }
            """.data(using: .utf8)!
        }

        // 非法值一律拒绝
        for (field, value) in [
            ("current_interval_total_count", "1.5"),
            ("current_interval_total_count", "-3"),
            ("current_interval_total_count", "true"),
            ("current_interval_total_count", "\"12\""),
            ("current_weekly_usage_count", "1e400")
        ] {
            do {
                _ = try MinimaxTokenPlanFetcher.parse(data: makeData(countField: field, value: value))
                XCTFail("expected decodingError for \(field)=\(value)")
            } catch let error as QuotaError {
                guard case .decodingError(let msg) = error,
                      msg.contains("非负整数") else {
                    XCTFail("unexpected error for \(field)=\(value): \(error)")
                    return
                }
            }
        }

        // 整数值合法；字段缺失仍按 0 处理
        let info = try MinimaxTokenPlanFetcher.parse(data: makeData(countField: "current_interval_total_count", value: "120"))
        XCTAssertEqual(info.models.first?.intervalTotalCount, 120)
        let missingJSON = """
        {
          "model_remains": [
            {
              "model_name": "general",
              "end_time": 1783252800000,
              "weekly_end_time": 1783267200000,
              "current_interval_remaining_percent": 50,
              "current_weekly_remaining_percent": 60
            }
          ],
          "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """
        let missing = try MinimaxTokenPlanFetcher.parse(data: missingJSON.data(using: .utf8)!)
        XCTAssertEqual(missing.models.first?.intervalTotalCount, 0)
    }

    // MARK: - Binding Reset Date & Window Label Consolidation Tests

    func testBindingResetDateRules() {
        let primary = Date(timeIntervalSince1970: 1_000_000)
        let weekly = Date(timeIntervalSince1970: 2_000_000)

        // 1. Weekly is binding when weekly fraction * segments < primary fraction
        XCTAssertEqual(EquivalentQuotaAllocation.bindingResetDate(primaryFraction: 0.80, weeklyFraction: 0.12, primaryResetsAt: primary, weeklyResetsAt: weekly, segments: 6), weekly)

        // 2. Primary is binding when primary fraction < weekly fraction * segments
        XCTAssertEqual(EquivalentQuotaAllocation.bindingResetDate(primaryFraction: 0.08, weeklyFraction: 0.10, primaryResetsAt: primary, weeklyResetsAt: weekly, segments: 6), primary)

        // 3. Fallbacks when reset dates are missing
        XCTAssertEqual(EquivalentQuotaAllocation.bindingResetDate(primaryFraction: 0.80, weeklyFraction: 0.10, primaryResetsAt: primary, weeklyResetsAt: nil, segments: 6), primary)
        XCTAssertEqual(EquivalentQuotaAllocation.bindingResetDate(primaryFraction: 0.05, weeklyFraction: 0.50, primaryResetsAt: nil, weeklyResetsAt: weekly, segments: 6), weekly)
        XCTAssertNil(EquivalentQuotaAllocation.bindingResetDate(primaryFraction: 0.10, weeklyFraction: 0.50, primaryResetsAt: nil, weeklyResetsAt: nil, segments: 6))
        XCTAssertEqual(EquivalentQuotaAllocation.bindingResetDate(primaryFraction: 0.50, weeklyFraction: 0.10, primaryResetsAt: primary, weeklyResetsAt: weekly, segments: 3), weekly)
    }

    private func makeModel(name: String) -> ModelQuota {
        ModelQuota(
            modelName: name,
            intervalTotalCount: 0, intervalUsageCount: 0, intervalRemainingPercent: 50, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: nil,
            weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 50, weeklyStatus: .present, weeklyResetsAt: Date(timeIntervalSince1970: 4_102_444_800), weeklyWindowSeconds: nil
        )
    }

    func testWeeklyMultiplierAndWindowLabelRules() {
        // Multipliers
        XCTAssertEqual(QuotaSummary.weeklyEquivalentMultiplier(providerKind: .minimaxTokenPlan, model: makeModel(name: "video")), 7)
        for name in ["general", "image", "speech", "music", "tts", "Video", "VIDEO"] {
            let expected = name.lowercased() == "video" ? 7 : 10
            XCTAssertEqual(QuotaSummary.weeklyEquivalentMultiplier(providerKind: .minimaxTokenPlan, model: makeModel(name: name)), expected)
        }
        XCTAssertEqual(QuotaSummary.weeklyEquivalentMultiplier(providerKind: .codexChatGpt, model: makeModel(name: "chatgpt_plan")), 6)
        XCTAssertEqual(QuotaSummary.weeklyEquivalentMultiplier(providerKind: .antigravity, model: makeModel(name: "gemini_models")), 6)
        XCTAssertEqual(QuotaSummary.weeklyEquivalentMultiplier(providerKind: .antigravity, model: makeModel(name: "claude_and_gpt_models")), 3)

        // Window labels
        XCTAssertEqual(QuotaSummary.primaryWindowLabel(providerKind: .minimaxTokenPlan, model: makeModel(name: "video")), "日")
        XCTAssertEqual(QuotaSummary.primaryWindowLabel(providerKind: .minimaxTokenPlan, model: makeModel(name: "general")), "5h")
        XCTAssertEqual(QuotaSummary.primaryWindowLabel(providerKind: .codexChatGpt, model: makeModel(name: "chatgpt_plan")), "5h")
    }

    func testQuotaHoverPrimaryBindingTextUsesOrdinaryWindowLabel() {
        XCTAssertEqual(
            QuotaWindowsHoverPresentation.bindingConstraintText(
                primaryLabel: "5h",
                weeklyIsBinding: false,
                weeklyEquivalentMultiplier: 10,
                weeklyLabel: "周"
            ),
            "主行 reset time 取5h窗口（5h是 binding constraint,比周额度先耗尽）。顶部红三角 ▼ = 周 reset 进度,仅作时间标记"
        )
    }

    func testQuotaHoverPrimaryBindingTextUsesVideoDayWindowLabel() {
        XCTAssertEqual(
            QuotaWindowsHoverPresentation.bindingConstraintText(
                primaryLabel: "日",
                weeklyIsBinding: false,
                weeklyEquivalentMultiplier: 7,
                weeklyLabel: "周"
            ),
            "主行 reset time 取日窗口（日是 binding constraint,比周额度先耗尽）。顶部红三角 ▼ = 周 reset 进度,仅作时间标记"
        )
    }

    func testQuotaHoverNormalizesNonFinitePercentForSafePresentation() {
        XCTAssertEqual(QuotaWindowsHoverPresentation.normalizedPercent(.nan), 0)
        XCTAssertEqual(QuotaWindowsHoverPresentation.normalizedPercent(.infinity), 0)
        XCTAssertEqual(QuotaWindowsHoverPresentation.normalizedPercent(-1), 0)
        XCTAssertEqual(QuotaWindowsHoverPresentation.normalizedPercent(101), 100)
        XCTAssertEqual(QuotaWindowsHoverPresentation.normalizedPercent(42.5), 42.5)
    }

    // MARK: - Provider state label freshness

    func testProviderStateLabelFreshnessPresentationBoundaries() {
        let refreshedAt = Date(timeIntervalSince1970: 1_000_000)
        let info = QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: refreshedAt
        )
        let status = ProviderStatus(
            id: "test",
            displayName: "Test",
            kind: .codexChatGpt,
            iconSystemName: "circle",
            accentColor: .custom,
            refreshIntervalSeconds: 10,
            state: .ok(info),
            lastRefreshedAt: refreshedAt
        )
        let label = ProviderStateLabel(status: status)

        XCTAssertEqual(label.presentation(at: refreshedAt.addingTimeInterval(3)).tone, .green)
        XCTAssertEqual(label.presentation(at: refreshedAt.addingTimeInterval(3.001)).tone, .secondary)
        XCTAssertEqual(label.presentation(at: refreshedAt.addingTimeInterval(8)).tone, .secondary)
        XCTAssertEqual(label.presentation(at: refreshedAt.addingTimeInterval(8.001)).tone, .yellow)
        XCTAssertEqual(label.presentation(at: refreshedAt.addingTimeInterval(10)).tone, .yellow)
        XCTAssertEqual(label.presentation(at: refreshedAt.addingTimeInterval(10.001)).tone, .red)
    }

    func testProviderStateLabelTimelineCoversMinimumIntervalFirstThreshold() {
        let minimumRefreshInterval: TimeInterval = 10
        XCTAssertLessThanOrEqual(
            ProviderStateLabel.timelineIntervalSeconds,
            minimumRefreshInterval * 0.3
        )
    }

    // MARK: - ChatGPT Plan Row & Pill Label Consolidated Tests

    func testChatGPTPlanRowAndPillLabelRules() {
        // ChatGPT plan row rules
        XCTAssertTrue(QuotaSummary.shouldUseChatGPTPlanRow(providerKind: .codexChatGpt, model: makeModel(name: "chatgpt_plan")))
        XCTAssertTrue(QuotaSummary.shouldUseChatGPTPlanRow(providerKind: .codexChatGpt, model: makeModel(name: "ChatGPT_Plan")))
        XCTAssertFalse(QuotaSummary.shouldUseChatGPTPlanRow(providerKind: .minimaxTokenPlan, model: makeModel(name: "general")))
        XCTAssertFalse(QuotaSummary.shouldUseChatGPTPlanRow(providerKind: .codexChatGpt, model: makeModel(name: "gpt-4")))

        // Plan pill label rules
        XCTAssertEqual(QuotaSummary.planPillLabel(providerKind: .antigravity, planLabel: "Google AI Pro"), "AI Pro")
        XCTAssertEqual(QuotaSummary.planPillLabel(providerKind: .antigravity, planLabel: "Antigravity Pro"), "Pro")
        XCTAssertEqual(QuotaSummary.planPillLabel(providerKind: .antigravity, planLabel: "Free"), "Free")
        XCTAssertNil(QuotaSummary.planPillLabel(providerKind: .antigravity, planLabel: nil))
        XCTAssertNil(QuotaSummary.planPillLabel(providerKind: .antigravity, planLabel: ""))
        XCTAssertEqual(QuotaSummary.planPillLabel(providerKind: .codexChatGpt, planLabel: "Team"), "Team")
        XCTAssertNil(QuotaSummary.planPillLabel(providerKind: .codexChatGpt, planLabel: nil))
    }

    // MARK: - Process Classification & Language Server Consolidated Tests

    func testProcessClassificationAndLanguageServerRules() {
        // Process Classification (.ide, .cli, nil)
        let ideCommands = [
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server --app_data_dir /Users/me/.config/Antigravity --csrf_token abc123 --enable_lsp",
            "/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --csrf_token abc123 --subclient_type ide",
            "/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64 --csrf_token abc --app_data_dir antigravity-ide",
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server --app_data_dir /Users/me/.gemini/antigravity"
        ]
        for cmd in ideCommands {
            XCTAssertEqual(AntigravityFetcher.classify(command: cmd), .ide, "command: \(cmd)")
        }

        let cliCommands = [
            "/Users/me/.local/bin/agy --some-flag value",
            "/opt/homebrew/bin/antigravity_cli chat",
            "/usr/local/bin/antigravity-cli --interactive",
            "C:\\Users\\me\\AppData\\Local\\Programs\\antigravity-cli\\antigravity-cli.exe --interactive"
        ]
        for cmd in cliCommands {
            XCTAssertEqual(AntigravityFetcher.classify(command: cmd), .cli, "command: \(cmd)")
        }

        XCTAssertNil(AntigravityFetcher.classify(command: "/Applications/Visual Studio Code.app/Contents/MacOS/Code"))
        XCTAssertNil(AntigravityFetcher.classify(command: "/usr/bin/stragytool --run"))
        XCTAssertNil(AntigravityFetcher.classify(command: ""))

        // Binary match strictness
        XCTAssertTrue(AntigravityFetcher.isLanguageServerBinary("/Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token x"))
        XCTAssertTrue(AntigravityFetcher.isLanguageServerBinary("/path/to/language-server --flag"))
        XCTAssertFalse(AntigravityFetcher.isLanguageServerBinary("/usr/bin/strlanguage_server --flag"))

        // Known binaries spec contract
        let known = AntigravityFetcher.knownLanguageServerBinaries
        XCTAssertTrue(known.contains("language_server"))
        XCTAssertTrue(known.contains("language_server_macos_arm"))

        // parseProcessLine
        let matchIde = AntigravityFetcher.parseProcessLine("12345 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token secret", defaultKind: .ide)
        XCTAssertEqual(matchIde?.pid, 12345)
        XCTAssertEqual(matchIde?.kind, .ide)

        let matchCli = AntigravityFetcher.parseProcessLine("9876 /Users/me/.local/bin/agy chat", defaultKind: .cli)
        XCTAssertEqual(matchCli?.pid, 9876)
        XCTAssertEqual(matchCli?.kind, .cli)

        XCTAssertNil(AntigravityFetcher.parseProcessLine("12345 /Users/me/.local/bin/agy --helper", defaultKind: .ide))
        XCTAssertNil(AntigravityFetcher.parseProcessLine("invalid", defaultKind: .ide))
    }

    // MARK: - User Account & Date Parsing Consolidated Tests

    func testParseAccountAndDateParserRules() {
        // User account parsing
        let statusUserTierWins = UserStatus(email: "alice@example.com", userTier: UserTier(name: "Free"), planStatus: PlanStatus(planInfo: PlanInfo(planDisplayName: "Pro Max")))
        let acc1 = AntigravityFetcher.parseAccount(userStatus: statusUserTierWins, fallbackTier: nil)
        XCTAssertEqual(acc1.planLabel, "Free")
        XCTAssertEqual(acc1.accountEmail, "alice@example.com")

        let statusFallback = UserStatus(email: "carol@example.com", userTier: nil, planStatus: nil)
        let acc2 = AntigravityFetcher.parseAccount(userStatus: statusFallback, fallbackTier: "Antigravity Free")
        XCTAssertEqual(acc2.planLabel, "Antigravity Free")

        let accNil = AntigravityFetcher.parseAccount(userStatus: nil, fallbackTier: nil)
        XCTAssertNil(accNil.planLabel)

        // String utilities
        XCTAssertEqual(StringUtilities.trimmedOrNil("  Free  "), "Free")
        XCTAssertNil(StringUtilities.trimmedOrNil("   "))
        XCTAssertEqual(StringUtilities.firstTrimmed(nil, "", "  ", "Pro"), "Pro")

        // DateParser ms & ISO8601
        let msDate = DateParser.parseMsTimestamp("1783234800000")
        XCTAssertNotNil(msDate)
        XCTAssertNotNil(DateParser.parseMsTimestamp(500.0))
    }

    func testDateParserParseMsNumberLarge() {
        let ms = 1_783_234_800_000.0
        let date = DateParser.parseMsTimestamp(NSNumber(value: ms))!
        XCTAssertEqual(date.timeIntervalSince1970, ms / 1000.0, accuracy: 0.001)
    }

    func testDateParserParseMsInt() {
        let ms: Int = 1_783_234_800_000
        let date = DateParser.parseMsTimestamp(ms)!
        XCTAssertEqual(date.timeIntervalSince1970, Double(ms) / 1000.0, accuracy: 0.001)
    }

    func testDateParserParseISO8601Fractional() {
        // 先用系统算参考值，避免手算
        let refString = "2026-07-18T00:47:58Z"
        let plain = DateParser.parse(refString)!
        // 把 plain 时刻 + 0.918242 秒（"小数日"的分数部分）作为期望值
        let expected = plain.addingTimeInterval(0.918242)
        let date = DateParser.parse("2026-07-18T00:47:58.918242Z")!
        XCTAssertEqual(date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testDateParserParseISO8601Plain() {
        let date = DateParser.parse("2026-07-18T00:47:58Z")!
        let refString = "2026-07-18T00:47:58+00:00"
        let expected = DateParser.parse(refString)!
        XCTAssertEqual(date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)

        let padded = DateParser.parse("  2026-07-18T00:47:58Z  ")!
        XCTAssertEqual(padded.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
        let paddedMs = DateParser.parseMsTimestamp("  1783234800000  ")!
        XCTAssertEqual(paddedMs.timeIntervalSince1970, 1_783_234_800, accuracy: 0.001)
    }

    func testDateParserParseUnixSeconds() {
        // < 1e12 = 秒
        let date = DateParser.parse(NSNumber(value: 1_700_000_000.0))!
        XCTAssertEqual(date.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testDateParserParseUnixMillisAuto() {
        // > 1e12 = 毫秒
        let date = DateParser.parse(NSNumber(value: 1_700_000_000_000.0))!
        XCTAssertEqual(date.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }


}
