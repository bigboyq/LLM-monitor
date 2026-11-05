import XCTest
@testable import LLM_monitor

/// `GlmCodingPlanFetcher.fetchZcodePackageSilently` 的编排逻辑测试：
/// 通过注入 `ZcodePackageProviding` stub 验证部分失败降级、凭证缺失跳过、
/// background 跳过 reset/marketing、`anySucceeded` 判定与 merger 的衔接。
final class GlmZcodePackageOrchestrationTests: XCTestCase {

    // MARK: - Stub

    /// 单测专用 stub：可变状态只在测试线程上读写（每个用例单线程），故 @unchecked Sendable。
    private final class PackageProviderStub: ZcodePackageProviding, @unchecked Sendable {
        var balanceError: Error?
        var balanceResult: ([GlmActivityPlanBalance], [GlmActivityPlanPreview]) = ([], [])
        var resetError: Error?
        var resetResult = GlmResetCardsSnapshot(fiveHourResets: [], weekResets: [])
        var marketingError: Error?
        var marketingResult: [GlmMarketingDelivery] = []

        private(set) var balanceCalls = 0
        private(set) var resetCalls = 0
        private(set) var marketingCalls = 0
        private(set) var balanceCredentials: GlmZcodeCredentials?
        private(set) var resetCredentials: GlmZcodeCredentials?
        private(set) var marketingCredentials: GlmZcodeCredentials?

        func fetchBalance(
            credentials: GlmZcodeCredentials,
            session: URLSession,
            now: Date
        ) async throws -> ([GlmActivityPlanBalance], [GlmActivityPlanPreview]) {
            balanceCalls += 1
            balanceCredentials = credentials
            if let balanceError { throw balanceError }
            return balanceResult
        }

        func fetchResetCards(
            credentials: GlmZcodeCredentials,
            session: URLSession,
            now: Date
        ) async throws -> GlmResetCardsSnapshot {
            resetCalls += 1
            resetCredentials = credentials
            if let resetError { throw resetError }
            return resetResult
        }

        func fetchMarketingTouch(
            credentials: GlmZcodeCredentials,
            seq: Int,
            session: URLSession
        ) async throws -> [GlmMarketingDelivery] {
            marketingCalls += 1
            marketingCredentials = credentials
            if let marketingError { throw marketingError }
            return marketingResult
        }
    }

    // MARK: - Fixtures

    private let fullCredentials = GlmZcodeCredentials(
        deviceMid: "mid-1",
        jwtToken: "jwt-token",
        bigmodelAccessToken: "bigmodel-token"
    )

    private func makeBalance(entitlementID: String, used: Int) -> GlmActivityPlanBalance {
        GlmActivityPlanBalance(
            planID: "plan-1", planName: "P1", entitlementID: entitlementID,
            showName: "GLM-5", modelNames: ["glm-5"], totalUnits: 100,
            usedUnits: used, remainingUnits: 100 - used,
            expiresAt: nil, observedAt: nil
        )
    }

    private func makeFetcher(
        stub: PackageProviderStub,
        pollMarketingCampaign: Bool,
        authMode: GlmAuthMode = .credential,
        zcodeEnabled: Bool = true,
        apiKey: String = "coding-plan-key"
    ) -> GlmCodingPlanFetcher {
        GlmCodingPlanFetcher(
            authMode: authMode,
            isZcodeCredentialEnabled: zcodeEnabled,
            apiKey: apiKey,
            pollMarketingCampaign: pollMarketingCampaign,
            packageProvider: stub
        )
    }

    // MARK: - 1. 部分失败：balance 失败但 reset 成功

    func testBalanceFailureWithResetSuccessProducesPartialSnapshot() async {
        let stub = PackageProviderStub()
        stub.balanceError = QuotaError.apiError("ZCode API error code: 401")
        stub.resetResult = GlmResetCardsSnapshot(
            fiveHourResets: [GlmResetCardItem(expireAt: Date(timeIntervalSince1970: 1_800_000_000))],
            weekResets: []
        )

        let fetcher = makeFetcher(stub: stub, pollMarketingCampaign: false)
        let snapshot = await fetcher.fetchZcodePackageSilently(mode: .full, credentials: fullCredentials)

        XCTAssertNotNil(snapshot, "任一路成功即返回快照（部分失败降级）")
        XCTAssertEqual(stub.balanceCalls, 1)
        XCTAssertEqual(stub.resetCalls, 1)
        XCTAssertEqual(snapshot?.resetCards?.fiveHourResets.count, 1, "成功路的 resetCards 保留")
        XCTAssertNil(snapshot?.activityPlanBalances, "失败路的 balances 为 nil（交给 merger 回填）")
        XCTAssertNil(snapshot?.activityPlanPreviews)
    }

    /// partial 快照与 `GlmFillingMissingMerger`（RefreshResultMergers）的衔接：
    /// balance 失败（nil）时合并结果回填 previous 的 balances，reset 用新的。
    func testPartialSnapshotMergesWithPreviousViaGlmFillingMissingMerger() async {
        let stub = PackageProviderStub()
        stub.balanceError = QuotaError.apiError("ZCode API error code: 500")
        stub.resetResult = GlmResetCardsSnapshot(
            fiveHourResets: [GlmResetCardItem(expireAt: Date(timeIntervalSince1970: 1_800_000_000))],
            weekResets: []
        )

        let fetcher = makeFetcher(stub: stub, pollMarketingCampaign: false)
        let snapshot = await fetcher.fetchZcodePackageSilently(mode: .full, credentials: fullCredentials)

        let prevBalance = makeBalance(entitlementID: "ent-prev", used: 10)
        let prevPackage = GlmZcodePackageSnapshot(
            activityPlanBalances: [prevBalance],
            activityPlanPreviews: [],
            resetCards: GlmResetCardsSnapshot(fiveHourResets: [], weekResets: []),
            deliveries: [],
            fetchedAt: Date(timeIntervalSince1970: 1000)
        )
        let prevQuota = QuotaInfo(
            models: [], resetCredits: nil, planLabel: "Pro", accountEmail: nil,
            codexUsageDetails: nil, fetchedAt: Date(timeIntervalSince1970: 1000),
            glmZcodePackage: prevPackage
        )
        let newQuota = QuotaInfo(
            models: [], resetCredits: nil, planLabel: "Pro", accountEmail: nil,
            codexUsageDetails: nil, fetchedAt: Date(timeIntervalSince1970: 2000),
            glmZcodePackage: snapshot
        )

        let merger = GlmFillingMissingMerger(isZcodeCredentialEnabled: true)
        let merged = merger.merge(new: newQuota, previous: prevQuota, mode: .full)

        XCTAssertEqual(merged.glmZcodePackage?.activityPlanBalances?.first?.entitlementID, "ent-prev",
                       "balance 失败（nil）时回填 previous 的活动套餐余额")
        XCTAssertEqual(merged.glmZcodePackage?.resetCards?.fiveHourResets.count, 1,
                       "reset 成功时使用本次的新快照")
    }

    // MARK: - 2. 凭证缺失：三路全跳过返回 nil

    func testMissingCredentialsSkipsAllCallsAndReturnsNil() async {
        let stub = PackageProviderStub()
        let missingCredentials = GlmZcodeCredentials(deviceMid: "mid-1", jwtToken: nil)
        XCTAssertFalse(missingCredentials.hasCredentials)

        let fetcher = makeFetcher(stub: stub, pollMarketingCampaign: true)
        let snapshot = await fetcher.fetchZcodePackageSilently(mode: .full, credentials: missingCredentials)

        XCTAssertNil(snapshot)
        XCTAssertEqual(stub.balanceCalls, 0)
        XCTAssertEqual(stub.resetCalls, 0)
        XCTAssertEqual(stub.marketingCalls, 0, "凭证缺失时三路接口都不应被调用")
    }

    // MARK: - 3. marketing 门控：开关关闭或 background 跳过

    func testMarketingNotCalledWhenPollDisabled() async {
        let stub = PackageProviderStub()
        let fetcher = makeFetcher(stub: stub, pollMarketingCampaign: false)

        let snapshot = await fetcher.fetchZcodePackageSilently(mode: .full, credentials: fullCredentials)

        XCTAssertEqual(stub.marketingCalls, 0, "notifyCampaign 关闭时不发 marketing 请求")
        XCTAssertEqual(stub.balanceCalls, 1)
        XCTAssertEqual(stub.resetCalls, 1)
        XCTAssertNotNil(snapshot)
        XCTAssertTrue(snapshot?.deliveries.isEmpty ?? false)
    }

    func testMarketingAndResetNotCalledInBackgroundMode() async {
        let stub = PackageProviderStub()
        let fetcher = makeFetcher(stub: stub, pollMarketingCampaign: true)

        let snapshot = await fetcher.fetchZcodePackageSilently(mode: .background, credentials: fullCredentials)

        XCTAssertEqual(stub.balanceCalls, 1, "background 模式 balance 仍然拉取")
        XCTAssertEqual(stub.resetCalls, 0, "background 模式按设计跳过重置卡")
        XCTAssertEqual(stub.marketingCalls, 0, "background 模式按设计跳过营销触达")
        XCTAssertNotNil(snapshot, "background 模式即使只有 balance 成功也返回快照")
        XCTAssertNil(snapshot?.resetCards)
    }

    // MARK: - 4. 全部失败：full 返回 nil 保留既有数据，background 仍返回空快照

    func testAllCallsFailInFullModeReturnsNil() async {
        let stub = PackageProviderStub()
        stub.balanceError = QuotaError.decodingError("balance failed")
        stub.resetError = QuotaError.decodingError("reset failed")
        stub.marketingError = QuotaError.decodingError("marketing failed")

        let fetcher = makeFetcher(stub: stub, pollMarketingCampaign: true)
        let snapshot = await fetcher.fetchZcodePackageSilently(mode: .full, credentials: fullCredentials)

        XCTAssertNil(snapshot, "full 模式全部失败时返回 nil，交由上层保留既有数据")
    }

    func testAllCallsFailInBackgroundModeStillReturnsEmptySnapshot() async {
        let stub = PackageProviderStub()
        stub.balanceError = QuotaError.decodingError("balance failed")
        stub.resetError = QuotaError.decodingError("reset failed")
        stub.marketingError = QuotaError.decodingError("marketing failed")

        let fetcher = makeFetcher(stub: stub, pollMarketingCampaign: true)
        let snapshot = await fetcher.fetchZcodePackageSilently(mode: .background, credentials: fullCredentials)

        XCTAssertNotNil(snapshot, "background 模式按 `anySucceeded || mode == .background` 仍返回快照")
        XCTAssertNil(snapshot?.activityPlanBalances)
        XCTAssertNil(snapshot?.resetCards)
        XCTAssertTrue(snapshot?.deliveries.isEmpty ?? false)
    }

    func testConfiguredAPIKeyEnablesResetCardsWithoutOAuthToken() async {
        let stub = PackageProviderStub()
        let jwtOnlyCredentials = GlmZcodeCredentials(
            deviceMid: "mid-1", jwtToken: "jwt-token", bigmodelAccessToken: nil
        )
        let fetcher = makeFetcher(
            stub: stub,
            pollMarketingCampaign: false,
            authMode: .apiKey,
            zcodeEnabled: true,
            apiKey: "  coding-plan-key  "
        )

        let snapshot = await fetcher.fetchZcodePackageSilently(mode: .full, credentials: jwtOnlyCredentials)

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(stub.resetCalls, 1, "配置 API Key 后无需 OAuth BigModel token 也可尝试重置卡接口")
        XCTAssertEqual(stub.resetCredentials?.jwtToken, "jwt-token", "ZCode JWT 仍用于双凭证接口")
        XCTAssertEqual(stub.resetCredentials?.deviceMid, "mid-1")
        XCTAssertEqual(stub.resetCredentials?.bigmodelAccessToken, "coding-plan-key")
    }

    func testConfiguredAPIKeyOverridesOAuthTokenForPackageRequests() async {
        let stub = PackageProviderStub()
        let credentials = GlmZcodeCredentials(
            deviceMid: "mid-1", jwtToken: "jwt-token", bigmodelAccessToken: "expired-oauth-token"
        )
        let fetcher = makeFetcher(
            stub: stub,
            pollMarketingCampaign: true,
            authMode: .apiKey,
            zcodeEnabled: true,
            apiKey: "coding-plan-key"
        )

        _ = await fetcher.fetchZcodePackageSilently(mode: .full, credentials: credentials)

        XCTAssertEqual(stub.balanceCredentials?.jwtToken, "jwt-token")
        XCTAssertEqual(stub.balanceCredentials?.bigmodelAccessToken, "coding-plan-key")
        XCTAssertEqual(stub.resetCredentials?.bigmodelAccessToken, "coding-plan-key")
        XCTAssertEqual(stub.marketingCredentials?.jwtToken, "jwt-token")
        XCTAssertEqual(stub.marketingCredentials?.bigmodelAccessToken, "coding-plan-key")
    }

    func testConfiguredAPIKeyDoesNotCallZcodePackageWithoutJWT() async {
        let stub = PackageProviderStub()
        let credentials = GlmZcodeCredentials(
            deviceMid: "mid-1", jwtToken: nil, bigmodelAccessToken: nil
        )
        let fetcher = makeFetcher(
            stub: stub,
            pollMarketingCampaign: true,
            authMode: .apiKey,
            zcodeEnabled: true,
            apiKey: "coding-plan-key"
        )

        let snapshot = await fetcher.fetchZcodePackageSilently(mode: .full, credentials: credentials)

        XCTAssertNil(snapshot)
        XCTAssertEqual(stub.balanceCalls, 0)
        XCTAssertEqual(stub.resetCalls, 0)
        XCTAssertEqual(stub.marketingCalls, 0)
    }

    func testDisabledJWTExtensionSkipsAllPackageCalls() async {
        let stub = PackageProviderStub()
        let fetcher = makeFetcher(
            stub: stub,
            pollMarketingCampaign: true,
            authMode: .credential,
            zcodeEnabled: false,
            apiKey: "coding-plan-key"
        )

        let snapshot = await fetcher.fetchZcodePackageSilently(mode: .full, credentials: fullCredentials)

        XCTAssertNil(snapshot)
        XCTAssertEqual(stub.balanceCalls, 0)
        XCTAssertEqual(stub.resetCalls, 0)
        XCTAssertEqual(stub.marketingCalls, 0)
    }

    func testMissingAPIKeySkipsPackageEvenWhenJWTIsAvailable() async {
        let stub = PackageProviderStub()
        let fetcher = makeFetcher(
            stub: stub,
            pollMarketingCampaign: true,
            zcodeEnabled: true,
            apiKey: "  \n "
        )

        let snapshot = await fetcher.fetchZcodePackageSilently(mode: .full, credentials: fullCredentials)

        XCTAssertNil(snapshot)
        XCTAssertEqual(stub.balanceCalls, 0)
        XCTAssertEqual(stub.resetCalls, 0)
        XCTAssertEqual(stub.marketingCalls, 0)
    }
}
