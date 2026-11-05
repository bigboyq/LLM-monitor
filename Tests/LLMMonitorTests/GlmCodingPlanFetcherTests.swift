import XCTest
@testable import LLM_monitor

final class GlmCodingPlanFetcherTests: XCTestCase {

    // MARK: - GLM Coding Plan Fetcher Tests

    private let successJSON = #"""
    {
      "code": 200,
      "msg": "Operation successful",
      "success": true,
      "data": {
        "level": "lite",
        "limits": [
          {
            "type": "CREDIT_LIMIT", "unit": 3, "number": 5,
            "usage": 2000, "currentValue": 114, "remaining": 1885,
            "percentage": 5, "nextResetTime": 1785486276273
          },
          {
            "type": "CREDIT_LIMIT", "unit": 6, "number": 1,
            "usage": 10000, "currentValue": 114, "remaining": 9885,
            "percentage": 1, "nextResetTime": 1786072666998
          }
        ]
      }
    }
    """#

    func testGlmCodingPlanFetcherParsingAndWindows() throws {
        let info = try GlmCodingPlanFetcher.parse(data: Data(successJSON.utf8))
        XCTAssertEqual(info.models.count, 1)
        let model = try XCTUnwrap(info.models.first)
        XCTAssertEqual(model.modelName, "glm_coding_plan")
        XCTAssertEqual(model.displayName, "GLM Coding Plan")
        XCTAssertEqual(model.intervalTotalCount, 2000)
        XCTAssertEqual(model.weeklyTotalCount, 10_000)

        // Classify limits by metadata
        let customJSON = #"""
        { "code": 200, "success": true, "data": { "level": "pro", "limits": [
          { "type":"CREDIT_LIMIT", "unit":6, "number":1, "usage":60000, "currentValue":12000, "remaining":48000, "nextResetTime": 1111111111111 },
          { "type":"CREDIT_LIMIT", "unit":3, "number":5, "usage":12000, "currentValue":12000, "remaining":0, "nextResetTime": 9999999999999 }
        ]}}
        """#
        let model2 = try XCTUnwrap(try GlmCodingPlanFetcher.parse(data: Data(customJSON.utf8)).models.first)
        XCTAssertEqual(model2.intervalTotalCount, 12_000)
        XCTAssertEqual(model2.weeklyTotalCount, 60_000)
    }

    func testGlmFetcherErrorHandling() throws {
        let authFailure = #"{"code":1000,"msg":"身份验证失败。","success":false}"#
        XCTAssertThrowsError(try GlmCodingPlanFetcher.parse(data: Data(authFailure.utf8)))
        XCTAssertThrowsError(try GlmCodingPlanFetcher.parse(data: Data(#"{"code":200,"success":true,"data":{"level":"lite","limits":[]}}"#.utf8)))
    }

    func testGlmMissingIntervalResetUsesFiveHourFallback() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = #"""
        {
          "code": 200,
          "success": true,
          "data": {
            "level": "lite",
            "limits": [
              { "type": "CREDIT_LIMIT", "unit": 3, "number": 5,
                "usage": 2000, "currentValue": 0, "remaining": 2000 },
              { "type": "CREDIT_LIMIT", "unit": 6, "number": 1,
                "usage": 10000, "currentValue": 0, "remaining": 10000,
                "nextResetTime": 1800600000000 }
            ]
          }
        }
        """#

        let model = try XCTUnwrap(
            try GlmCodingPlanFetcher.parse(data: Data(json.utf8), now: now).models.first
        )
        XCTAssertEqual(model.intervalResetsAt, now.addingTimeInterval(5 * 3600))
        XCTAssertEqual(model.weeklyResetsAt, Date(timeIntervalSince1970: 1_800_600_000))
    }

    /// 周窗口缺 `nextResetTime` 时保持 present、reset 透传 nil：不按 7 天
    /// 合成边界伪造 reset 时间（合成值曾泄漏进 UI 阈值判定与本地分桶）。
    /// 消费面对 nil 安全降级 —— 剩余时间比例返回 nil（固定黄线），不 trap。
    func testGlmMissingWeeklyResetKeepsWindowPresentWithNilReset() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = #"""
        {
          "code": 200,
          "success": true,
          "data": {
            "level": "lite",
            "limits": [
              { "type": "CREDIT_LIMIT", "unit": 3, "number": 5,
                "usage": 2000, "currentValue": 0, "remaining": 2000,
                "nextResetTime": 1800600000000 },
              { "type": "CREDIT_LIMIT", "unit": 6, "number": 1,
                "usage": 10000, "currentValue": 0, "remaining": 10000 }
            ]
          }
        }
        """#

        let model = try XCTUnwrap(
            try GlmCodingPlanFetcher.parse(data: Data(json.utf8), now: now).models.first
        )
        XCTAssertEqual(model.weeklyStatus, .present)
        XCTAssertNil(model.weeklyResetsAt, "缺 nextResetTime 时不合成边界，透传 nil")
        // 5h 侧的既有兜底不受影响（本用例 5h 带 reset，走透传）
        XCTAssertEqual(model.intervalResetsAt, Date(timeIntervalSince1970: 1_800_600_000))

        // 消费面契约：present 而 reset 缺失时降级为 nil（固定黄线），无 trap
        XCTAssertNil(model.weeklyTimeRemainingFraction(at: now))
    }

    func testGlmCodingPlanFetcherErrorPaths() {
        let invalidCountJSON = #"""
        {
          "code": 200, "success": true,
          "data": {
            "level": "lite",
            "limits": [
              { "type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 100, "remaining": 150, "total": 100 }
            ]
          }
        }
        """#
        XCTAssertThrowsError(try GlmCodingPlanFetcher.parse(data: Data(invalidCountJSON.utf8)))
    }

    func testGlmRestoresCachedUsageOnColdStart() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-prefill-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManagerBox()
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = GlmLocalUsage(
            today: GlmDailyUsage(dayStart: day, inputTokens: 7, outputTokens: 4, rounds: 1),
            dailyTokenUsage: [GlmDailyUsage(dayStart: day, inputTokens: 7, outputTokens: 4, rounds: 1)],
            scannedAt: day, sessionCount: 1, eventCount: 1, failedSessionCount: 0,
            recentSamples: []
        )
        let index = GlmZcodeLocalUsageScanner.CacheIndex(
            // 引用当前版本常量：升版后旧缓存必须被拒读（触发重扫），冷启动恢复
            // 只对当前版本的缓存生效。
            version: GlmZcodeLocalUsageScanner.cacheIndexVersion,
            dbMtimeMs: 1,
            dbSizeBytes: 2,
            walMtimeMs: 0,
            walSizeBytes: 0,
            snapshot: snapshot,
            calendarSignature: LocalUsageCalendarSignature.make(.autoupdatingCurrent)
        )
        try GlmZcodeLocalUsageScanner.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        XCTAssertEqual(
            GlmZcodeLocalUsageScanner.loadCachedResult(
                cacheDir: cacheDir, fileManager: fileManager
            ),
            snapshot
        )
    }

    // MARK: - GLM Auth Mode & Credential Path Tests

    func testGlmAuthModeConfigAndMigration() throws {
        XCTAssertEqual(GlmAuthMode.apiKey.displayName, "API Key")
        XCTAssertEqual(GlmAuthMode.credential.displayName, "ZCode 凭证")

        // JWT 扩展开关独立于 API Key 认证方式。
        let credJSON = #"{"enabled":true,"glmAuthMode":"credential","authPath":"~/.zcode/v2"}"#
        let credConfig = try JSONDecoder().decode(ProviderConfig.self, from: Data(credJSON.utf8))
        XCTAssertEqual(credConfig.effectiveGlmAuthMode, .credential)
        XCTAssertEqual(credConfig.authPath, "~/.zcode/v2")
        XCTAssertTrue(credConfig.isZcodeCredentialEnabled)

        let apiKeyJSON = #"{"enabled":true,"glmAuthMode":"apiKey","apiKey":"my-key","zcodeJWTEnabled":true}"#
        let apiKeyConfig = try JSONDecoder().decode(ProviderConfig.self, from: Data(apiKeyJSON.utf8))
        XCTAssertEqual(apiKeyConfig.effectiveGlmAuthMode, .apiKey)
        XCTAssertTrue(apiKeyConfig.isZcodeCredentialEnabled)

        let explicitlyDisabled = #"{"enabled":true,"glmAuthMode":"credential","zcodeJWTEnabled":false}"#
        let disabledConfig = try JSONDecoder().decode(ProviderConfig.self, from: Data(explicitlyDisabled.utf8))
        XCTAssertFalse(disabledConfig.isZcodeCredentialEnabled, "显式新开关优先于旧 authMode")

        // 历史配置向后兼容迁移
        let legacy1 = try JSONDecoder().decode(ProviderConfig.self, from: Data(#"{"enabled":true,"parseZcodeCredential":true}"#.utf8))
        XCTAssertEqual(legacy1.effectiveGlmAuthMode, .credential)
        XCTAssertTrue(legacy1.isZcodeCredentialEnabled)

        let legacy2 = try JSONDecoder().decode(ProviderConfig.self, from: Data(#"{"enabled":true,"parseZcodePlan":true}"#.utf8))
        XCTAssertEqual(legacy2.effectiveGlmAuthMode, .credential)

        let legacy3 = try JSONDecoder().decode(ProviderConfig.self, from: Data(#"{"enabled":true,"parseZcodeBalanceLog":true}"#.utf8))
        XCTAssertEqual(legacy3.effectiveGlmAuthMode, .credential)

        let defaultCfg = try JSONDecoder().decode(ProviderConfig.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertEqual(defaultCfg.effectiveGlmAuthMode, .apiKey)
        XCTAssertFalse(defaultCfg.isZcodeCredentialEnabled)
    }

    func testGlmZcodeCredentialReaderURLResolution() {
        let (defaultTelemetry, defaultCreds) = GlmZcodeCredentialReader.resolveURLs(from: nil)
        XCTAssertTrue(defaultTelemetry.path.hasSuffix(".zcode/v2/telemetry-state.json"))
        XCTAssertTrue(defaultCreds.path.hasSuffix(".zcode/v2/credentials.json"))

        let (emptyTelemetry, emptyCreds) = GlmZcodeCredentialReader.resolveURLs(from: "   ")
        XCTAssertEqual(emptyTelemetry, defaultTelemetry)
        XCTAssertEqual(emptyCreds, defaultCreds)

        let (dirTelemetry, dirCreds) = GlmZcodeCredentialReader.resolveURLs(from: "/tmp/custom_zcode")
        XCTAssertEqual(dirTelemetry.path, "/tmp/custom_zcode/telemetry-state.json")
        XCTAssertEqual(dirCreds.path, "/tmp/custom_zcode/credentials.json")

        let (fileTelemetry, fileCreds) = GlmZcodeCredentialReader.resolveURLs(from: "/tmp/custom_zcode/credentials.json")
        XCTAssertEqual(fileTelemetry.path, "/tmp/custom_zcode/telemetry-state.json")
        XCTAssertEqual(fileCreds.path, "/tmp/custom_zcode/credentials.json")
    }

    func testGlmCodingPlanFetcherAuthModes() {
        let apiKeyFetcherEmpty = GlmCodingPlanFetcher(authMode: .apiKey, isZcodeCredentialEnabled: false, authPath: "/nonexistent/path/\(UUID().uuidString)", apiKey: "")
        XCTAssertFalse(apiKeyFetcherEmpty.hasLocalAuth())

        let apiKeyFetcherValid = GlmCodingPlanFetcher(authMode: .apiKey, apiKey: "valid-key")
        XCTAssertTrue(apiKeyFetcherValid.hasLocalAuth())
        XCTAssertFalse(apiKeyFetcherValid.isZcodeCredentialEnabled)

        let credFetcherNonExistent = GlmCodingPlanFetcher(authMode: .credential, isZcodeCredentialEnabled: false, authPath: "/nonexistent/path/\(UUID().uuidString)")
        XCTAssertFalse(credFetcherNonExistent.hasLocalAuth())
        XCTAssertFalse(credFetcherNonExistent.isZcodeCredentialEnabled, "legacy authMode alone cannot enable JWT extras")

        let explicitEnabledFetcher = GlmCodingPlanFetcher(
            authMode: .apiKey, isZcodeCredentialEnabled: true, apiKey: "valid-key"
        )
        XCTAssertTrue(explicitEnabledFetcher.isZcodeCredentialEnabled)
    }

    func testSettingsFormDraftGlmAuthFields() {
        let config = AppConfig(
            schemaVersion: AppConfig.currentSchemaVersion,
            refreshIntervalSeconds: 300,
            providers: [
                "glm_coding_plan": ProviderConfig(
                    enabled: true,
                    apiKey: "test-key",
                    authPath: "~/.zcode/v2",
                    glmAuthMode: .credential,
                    notifyCampaign: .barkAndSystem
                )
            ]
        )

        let descriptors = [
            FetcherDescriptor(
                id: "glm_coding_plan",
                displayName: "GLM Coding Plan",
                kind: .glmCodingPlan,
                iconSystemName: "circle",
                accentColor: .glm,
                makeFetcher: { _ in GlmCodingPlanFetcher(apiKey: "key") }
            )
        ]

        let draft = SettingsFormDraft(from: config, descriptors: descriptors)
        XCTAssertEqual(draft.glmAuthPath, "~/.zcode/v2")
        XCTAssertEqual(draft.glmApiKey, "test-key")
        XCTAssertEqual(draft.glmNotifyCampaign, .barkAndSystem)
        XCTAssertTrue(draft.glmZcodeJWTEnabled, "旧 credential 配置迁移为 JWT 扩展开启")

        // 脏检查测试
        var draft2 = draft
        XCTAssertEqual(draft, draft2)
        draft2.glmApiKey = "new-key"
        XCTAssertNotEqual(draft, draft2)

        var draft3 = draft
        draft3.glmAuthPath = "/other/path"
        XCTAssertNotEqual(draft, draft3)

        var draft4 = draft
        draft4.glmZcodeJWTEnabled = false
        XCTAssertNotEqual(draft, draft4)

        let defaultConfig = AppConfig(
            schemaVersion: AppConfig.currentSchemaVersion,
            refreshIntervalSeconds: 300,
            providers: ["glm_coding_plan": ProviderConfig(enabled: true, apiKey: "key")]
        )
        let defaultDraft = SettingsFormDraft(from: defaultConfig, descriptors: descriptors)
        XCTAssertFalse(defaultDraft.glmZcodeJWTEnabled)
    }
}

/// 在 URLSession 边界验证三类凭证的实际请求头，不读取本机登录状态。
final class GlmCodingPlanAuthenticationTests: XCTestCase {
    private final class AuthProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            let bigmodel = request.value(forHTTPHeaderField: "X-Bigmodel-Authorization")
            let body: String
            switch url.path {
            case "/quota":
                if authorization == "configured-key" {
                    body = #"{"code":200,"data":{"level":"lite","limits":[{"type":"CREDIT_LIMIT","usage":100,"remaining":80}]}}"#
                } else {
                    body = #"{"code":401,"msg":"登录状态已过期"}"#
                }
            case "/api/v1/zcode-plan/billing/balance":
                guard authorization == "Bearer jwt-token", bigmodel == "configured-key" else {
                    client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
                    return
                }
                body = #"{"code":0,"data":{"balances":[],"plans":[]}}"#
            case "/api/v1/coding-plan/reset/status":
                guard authorization == "Bearer jwt-token", bigmodel == "configured-key",
                      request.value(forHTTPHeaderField: "Bigmodel-Target-Type") == "PERSONAL" else {
                    client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
                    return
                }
                body = #"{"code":0,"data":{"available_five_hour_resets":[],"available_week_resets":[{"expire_at":4102444800000}]}}"#
            case "/api/v1/marketing/touch":
                guard authorization == "Bearer jwt-token" else {
                    client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
                    return
                }
                body = #"{"code":0,"data":{"deliveries":[{"id":"campaign-test","title":"Test campaign"}]}}"#
            default:
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func credentialsDirectory(oauth: String?, jwt: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var payload: [String: String] = [:]
        payload["oauth:bigmodel:access_token"] = oauth
        payload["zcodejwttoken"] = jwt
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: directory.appendingPathComponent("credentials.json"))
        return directory
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthProtocol.self]
        return URLSession(configuration: config)
    }

    func testAPIKeyOverridesExpiredOAuthAndKeepsAllZcodeDetailsInBothLegacyModes() async throws {
        let directory = try credentialsDirectory(oauth: "expired-oauth", jwt: "jwt-token")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        for mode in GlmAuthMode.allCases {
            let fetcher = GlmCodingPlanFetcher(
                authMode: mode, isZcodeCredentialEnabled: true, authPath: directory.path,
                apiKey: "  configured-key\n",
                endpoint: URL(string: "https://glm-test.invalid/quota")!,
                pollMarketingCampaign: true, session: session
            )
            let result = try await fetcher.fetch(mode: .full)
            XCTAssertEqual(result.models.first?.intervalRemainingPercent, 80)
            let package = try XCTUnwrap(result.glmZcodePackage)
            XCTAssertEqual(package.activityPlanBalances, [])
            XCTAssertEqual(package.resetCards?.weekResets.count, 1)
            XCTAssertEqual(package.deliveries.first?.id, "campaign-test")
        }
    }

    func testJWTAndAPIKeyFetchDetailsWithoutOAuth() async throws {
        let directory = try credentialsDirectory(oauth: nil, jwt: "jwt-token")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let fetcher = GlmCodingPlanFetcher(
            isZcodeCredentialEnabled: true, authPath: directory.path, apiKey: "configured-key",
            endpoint: URL(string: "https://glm-test.invalid/quota")!,
            pollMarketingCampaign: true, session: session
        )
        let result = try await fetcher.fetch(mode: .full)
        XCTAssertEqual(result.glmZcodePackage?.resetCards?.weekResets.count, 1)
        XCTAssertEqual(result.glmZcodePackage?.deliveries.first?.id, "campaign-test")
        let merged = fetcher.resultMerger.merge(new: result, previous: nil, mode: .full)
        XCTAssertNotNil(merged.glmZcodePackage, "历史 API Key 模式不再剥离额外信息")
    }

    func testMissingAPIKeyDoesNotFallBackToOAuthCredential() async throws {
        let directory = try credentialsDirectory(oauth: "oauth-token", jwt: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        for key in ["", " \n "] {
            let fetcher = GlmCodingPlanFetcher(
                authPath: directory.path, apiKey: key,
                endpoint: URL(string: "https://glm-test.invalid/quota")!, session: session
            )
            XCTAssertFalse(fetcher.hasLocalAuth())
            do {
                _ = try await fetcher.fetch(mode: .full)
                XCTFail("本地 OAuth token 不能替代必需的 Coding Plan API Key")
            } catch {
                XCTAssertEqual(error as? QuotaError, .missingAPIKey)
            }
        }
    }

    func testAPIKeyWithoutJWTStillFetchesStandardQuota() async throws {
        let directory = try credentialsDirectory(oauth: "expired-oauth", jwt: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let fetcher = GlmCodingPlanFetcher(
            isZcodeCredentialEnabled: false, authPath: directory.path, apiKey: "configured-key",
            endpoint: URL(string: "https://glm-test.invalid/quota")!,
            pollMarketingCampaign: true, session: session
        )
        let result = try await fetcher.fetch(mode: .full)
        XCTAssertEqual(result.models.first?.intervalRemainingPercent, 80)
        XCTAssertNil(result.glmZcodePackage)
    }

    func testJWTFlagOffSkipsPackageDespiteLegacyCredentialMode() async throws {
        let directory = try credentialsDirectory(oauth: "oauth-token", jwt: "jwt-token")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let fetcher = GlmCodingPlanFetcher(
            authMode: .credential,
            isZcodeCredentialEnabled: false,
            authPath: directory.path,
            apiKey: "configured-key",
            endpoint: URL(string: "https://glm-test.invalid/quota")!,
            pollMarketingCampaign: true,
            session: session
        )

        let result = try await fetcher.fetch(mode: .full)

        XCTAssertEqual(result.models.first?.intervalRemainingPercent, 80)
        XCTAssertNil(result.glmZcodePackage, "legacy authMode 不能越过关闭的 JWT 扩展开关")
        XCTAssertNil(fetcher.resultMerger.merge(new: result, previous: nil, mode: .full).glmZcodePackage)
    }
}
