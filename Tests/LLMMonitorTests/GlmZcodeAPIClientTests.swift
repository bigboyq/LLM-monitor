import XCTest
@testable import LLM_monitor

final class GlmZcodeAPIClientTests: XCTestCase {

    // MARK: - 1. Start Plan Balance 解析测试

    func testParseBalanceResponseExtractsActiveBalancesAndPreviews() throws {
        let json = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "server_time": 1793370001,
            "plans": [
              {
                "user_plan_id": "upl_1",
                "plan_id": "zcode-wk-build",
                "name": "ZCODE WEEKEND BUILD",
                "status": "active",
                "starts_at": 1793363377,
                "ends_at": 1793581200,
                "entitlements": [
                  {
                    "entitlement_id": "ent-1",
                    "show_name": "GLM-5.3-Flash",
                    "capabilities": ["model:glm-5.3-flash"],
                    "grant_units": 500000000,
                    "effective_at": 1793372400
                  },
                  {
                    "entitlement_id": "ent-2-preview",
                    "show_name": "GLM-5.3",
                    "capabilities": ["model:glm-5.3"],
                    "grant_units": 100000000,
                    "effective_at": 1793400000
                  }
                ]
              }
            ],
            "balances": [
              {
                "plan_id": "zcode-wk-build",
                "entitlement_id": "ent-1",
                "show_name": "GLM-5.3-Flash",
                "capabilities": ["model:glm-5.3-flash"],
                "total_units": 500000000,
                "used_units": 12345,
                "remaining_units": 499987655,
                "expires_at": 1793581200
              }
            ]
          }
        }
        """

        let now = Date(timeIntervalSince1970: 1793370001)
        let (balances, previews) = try GlmZcodeAPIClient.parseBalanceResponse(
            data: Data(json.utf8),
            now: now
        )

        // 验证余额
        XCTAssertEqual(balances.count, 1)
        let b = balances[0]
        XCTAssertEqual(b.planID, "zcode-wk-build")
        XCTAssertEqual(b.planName, "ZCODE WEEKEND BUILD")
        XCTAssertEqual(b.entitlementID, "ent-1")
        XCTAssertEqual(b.showName, "GLM-5.3-Flash")
        XCTAssertEqual(b.modelNames, ["glm-5.3-flash"])
        XCTAssertEqual(b.totalUnits, 500_000_000)
        XCTAssertEqual(b.usedUnits, 12_345)
        XCTAssertEqual(b.remainingUnits, 499_987_655)
        XCTAssertEqual(b.expiresAt, Date(timeIntervalSince1970: 1793581200))

        // 验证预告（ent-1 已在 balances，不出现在预告中；ent-2-preview 在未来生效，作为预告）
        XCTAssertEqual(previews.count, 1)
        let p = previews[0]
        XCTAssertEqual(p.planID, "zcode-wk-build")
        XCTAssertEqual(p.entitlementID, "ent-2-preview")
        XCTAssertEqual(p.showName, "GLM-5.3")
        XCTAssertEqual(p.grantUnits, 100_000_000)
        XCTAssertEqual(p.effectiveAt, Date(timeIntervalSince1970: 1793400000))
    }

    func testParseBalanceResponseHandlesPayloadWrapperFormat() throws {
        let json = """
        {
          "code": 0,
          "payload": {
            "data": {
              "plans": [],
              "balances": []
            }
          }
        }
        """
        let (balances, previews) = try GlmZcodeAPIClient.parseBalanceResponse(data: Data(json.utf8))
        XCTAssertTrue(balances.isEmpty)
        XCTAssertTrue(previews.isEmpty)
    }

    func testParseBalanceResponseExcludesExpiredBalances() throws {
        let json = """
        {
          "code": 0,
          "data": {
            "plans": [],
            "balances": [
              {
                "plan_id": "expired-plan",
                "entitlement_id": "ent-exp",
                "total_units": 1000,
                "used_units": 1000,
                "remaining_units": 0,
                "expires_at": 1000
              }
            ]
          }
        }
        """
        let now = Date(timeIntervalSince1970: 2000)
        let (balances, previews) = try GlmZcodeAPIClient.parseBalanceResponse(data: Data(json.utf8), now: now)
        XCTAssertTrue(balances.isEmpty)
        XCTAssertTrue(previews.isEmpty)
    }

    // MARK: - 2. 重置卡状态解析测试

    func testParseResetCardsResponseParsesFiveHourAndWeekCards() throws {
        let json = """
        {
          "code": 0,
          "msg": "success",
          "data": {
            "available_five_hour_resets": [
              { "expire_at": 1797955199000 },
              { "expire_at": 1795000000000 }
            ],
            "available_week_resets": [
              { "expire_at": 1797955199000 }
            ],
            "latest_five_hour_reset_history": { "used_at": 1793167845000 },
            "latest_week_reset_history": { "used_at": 1793170881000 },
            "has_unread_history": false
          }
        }
        """

        let snapshot = try GlmZcodeAPIClient.parseResetCardsResponse(data: Data(json.utf8))
        XCTAssertEqual(snapshot.fiveHourResets.count, 2)
        XCTAssertEqual(snapshot.weekResets.count, 1)

        // 验证已按 expireAt 升序排列
        XCTAssertEqual(snapshot.fiveHourResets[0].expireAt, Date(timeIntervalSince1970: 1795000000))
        XCTAssertEqual(snapshot.fiveHourResets[1].expireAt, Date(timeIntervalSince1970: 1797955199))
        XCTAssertEqual(snapshot.weekResets[0].expireAt, Date(timeIntervalSince1970: 1797955199))

        XCTAssertEqual(snapshot.latestFiveHourUsedAt, Date(timeIntervalSince1970: 1793167845))
        XCTAssertEqual(snapshot.latestWeekUsedAt, Date(timeIntervalSince1970: 1793170881))
        XCTAssertEqual(snapshot.totalCardCount, 3)
    }

    func testParseResetCardsResponseHandlesEmptyCards() throws {
        let json = """
        {
          "code": 0,
          "msg": "success",
          "data": {
            "available_five_hour_resets": [],
            "available_week_resets": [],
            "latest_five_hour_reset_history": null,
            "latest_week_reset_history": null
          }
        }
        """

        let snapshot = try GlmZcodeAPIClient.parseResetCardsResponse(data: Data(json.utf8))
        XCTAssertEqual(snapshot.fiveHourResets.count, 0)
        XCTAssertEqual(snapshot.weekResets.count, 0)
        XCTAssertNil(snapshot.latestFiveHourUsedAt)
        XCTAssertNil(snapshot.latestWeekUsedAt)
        XCTAssertEqual(snapshot.totalCardCount, 0)
    }

    // MARK: - 3. 营销触达解析测试

    func testParseMarketingTouchResponseReturnsDeliveries() throws {
        let json = """
        {
          "code": 0,
          "msg": "success",
          "data": {
            "deliveries": [
              {
                "id": "delivery-1",
                "title": "周末福利礼包",
                "body": "500M 免费 tokens 待领取",
                "plan_id": "zcode-weekend-plan"
              }
            ]
          }
        }
        """

        let deliveries = try GlmZcodeAPIClient.parseMarketingTouchResponse(data: Data(json.utf8))
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries[0].id, "delivery-1")
        XCTAssertEqual(deliveries[0].title, "周末福利礼包")
        XCTAssertEqual(deliveries[0].body, "500M 免费 tokens 待领取")
        XCTAssertEqual(deliveries[0].planID, "zcode-weekend-plan")
    }

    func testParseMarketingTouchResponseHandlesEmptyList() throws {
        let json = """
        {
          "code": 0,
          "msg": "success",
          "data": {
            "deliveries": []
          }
        }
        """

        let deliveries = try GlmZcodeAPIClient.parseMarketingTouchResponse(data: Data(json.utf8))
        XCTAssertTrue(deliveries.isEmpty)
    }

    // MARK: - 4. 重置卡显示与截断 (prefix 3) 规则测试

    func testResetCardPrefix3Rule() {
        let cards = (1...5).map { i in
            GlmResetCardItem(expireAt: Date(timeIntervalSince1970: Double(1700000000 + i * 3600)))
        }

        let prefixCards = Array(cards.prefix(3))
        XCTAssertEqual(prefixCards.count, 3)
        XCTAssertEqual(prefixCards[0].expireAt, Date(timeIntervalSince1970: 1700003600))
        XCTAssertEqual(prefixCards[2].expireAt, Date(timeIntervalSince1970: 1700010800))
    }

    // MARK: - 5. ProviderConfig 与 SettingsFormDraft 属性同步测试

    func testProviderConfigZcodeCredentialAndNotifyCampaign() throws {
        // 兼容解码 parseZcodeBalanceLog
        let legacyJSON = #"{"enabled":true,"parseZcodeBalanceLog":true}"#
        let legacyConfig = try JSONDecoder().decode(ProviderConfig.self, from: Data(legacyJSON.utf8))
        XCTAssertTrue(legacyConfig.isZcodeCredentialEnabled)
        XCTAssertTrue(legacyConfig.isZcodePlanEnabled)

        // 兼容解码 parseZcodePlan
        let planJSON = #"{"enabled":true,"parseZcodePlan":true}"#
        let planConfig = try JSONDecoder().decode(ProviderConfig.self, from: Data(planJSON.utf8))
        XCTAssertTrue(planConfig.isZcodeCredentialEnabled)

        // 新 parseZcodeCredential 与 notifyCampaign
        let config = ProviderConfig(
            enabled: true,
            parseZcodeCredential: true,
            notifyCampaign: .barkAndSystem
        )
        XCTAssertTrue(config.isZcodeCredentialEnabled)
        XCTAssertEqual(config.notifyCampaign, .barkAndSystem)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)
        XCTAssertEqual(decoded.parseZcodeCredential, true)
        XCTAssertEqual(decoded.notifyCampaign, .barkAndSystem)
        XCTAssertTrue(decoded.isZcodeCredentialEnabled)

        // draft 同步
        var draft = SettingsFormDraft()
        draft.glmZcodeCredentialEnabled = decoded.isZcodeCredentialEnabled
        draft.glmNotifyCampaign = decoded.notifyCampaign ?? .none
        XCTAssertTrue(draft.glmZcodeCredentialEnabled)
        XCTAssertTrue(draft.glmZcodePlanEnabled) // 别名兼容
        XCTAssertEqual(draft.glmNotifyCampaign, .barkAndSystem)
    }

    func testMarketingCampaignNotificationCooldown() {
        var lastNotifiedTimes: [String: Date] = [:]
        let deliveryID = "campaign-1"
        let t0 = Date(timeIntervalSince1970: 10000)

        func checkShouldNotify(at time: Date) -> Bool {
            if let last = lastNotifiedTimes[deliveryID] {
                if time.timeIntervalSince(last) >= 3600 {
                    lastNotifiedTimes[deliveryID] = time
                    return true
                }
                return false
            } else {
                lastNotifiedTimes[deliveryID] = time
                return true
            }
        }

        // 首次通知：通过
        XCTAssertTrue(checkShouldNotify(at: t0))

        // 30分钟后：在 1h 冷却期内，跳过
        let t30m = t0.addingTimeInterval(1800)
        XCTAssertFalse(checkShouldNotify(at: t30m))

        // 59分59秒后：仍在冷却期内，跳过
        let t59m = t0.addingTimeInterval(3599)
        XCTAssertFalse(checkShouldNotify(at: t59m))

        // 1小时后（3600秒）：冷却结束，允许通知
        let t60m = t0.addingTimeInterval(3600)
        XCTAssertTrue(checkShouldNotify(at: t60m))

        // 再次检查冷却期：距上次刷新仅 10 秒，跳过
        XCTAssertFalse(checkShouldNotify(at: t60m.addingTimeInterval(10)))
    }

    // MARK: - 6. QuotaInfo 与 ProviderStatus 投影测试

    func testProviderStatusProjectsZcodePackage() {
        let balance = GlmActivityPlanBalance(
            planID: "plan-1", planName: "Plan 1", entitlementID: "ent-1",
            showName: "GLM-5", modelNames: ["glm-5"], totalUnits: 100,
            usedUnits: 10, remainingUnits: 90, expiresAt: nil, observedAt: nil
        )
        let preview = GlmActivityPlanPreview(
            planID: "plan-1", planName: "Plan 1", entitlementID: "ent-prev",
            showName: "GLM-5", modelNames: ["glm-5"], grantUnits: 50,
            effectiveAt: Date(), observedAt: nil
        )
        let resetCards = GlmResetCardsSnapshot(
            fiveHourResets: [GlmResetCardItem(expireAt: Date())],
            weekResets: []
        )
        let package = GlmZcodePackageSnapshot(
            activityPlanBalances: [balance],
            activityPlanPreviews: [preview],
            resetCards: resetCards
        )
        let quota = QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: "Pro",
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date(),
            glmZcodePackage: package
        )

        let status = ProviderStatus(
            id: "glm_coding_plan",
            displayName: "GLM Coding Plan",
            kind: .glmCodingPlan,
            iconSystemName: "terminal",
            accentColor: .glm,
            refreshIntervalSeconds: 300,
            state: .ok(quota)
        )

        XCTAssertEqual(status.glmActivityPlanBalances.count, 1)
        XCTAssertEqual(status.glmActivityPlanBalances[0].entitlementID, "ent-1")
        XCTAssertEqual(status.glmActivityPlanPreviews.count, 1)
        XCTAssertEqual(status.glmActivityPlanPreviews[0].entitlementID, "ent-prev")
        XCTAssertNotNil(status.glmResetCards)
        XCTAssertEqual(status.glmResetCards?.fiveHourResets.count, 1)
        XCTAssertEqual(status.glmResetCards?.weekResets.count, 0)
    }

    // MARK: - 7. 边界与健壮性测试

    func testParseBalanceWithEndsAtAndMilliseconds() throws {
        // 测试 ends_at 代替 expires_at，以及毫秒时间戳兼容（> 100_000_000_000）
        let json = """
        {
          "code": 200,
          "data": {
            "plans": [
              {
                "plan_id": "test-plan",
                "name": "Test Plan",
                "ends_at": 1797955199000
              }
            ],
            "balances": [
              {
                "plan_id": "test-plan",
                "entitlement_id": "ent-ends",
                "show_name": "GLM Model",
                "total_units": 1000,
                "used_units": 200,
                "remaining_units": 800,
                "ends_at": 1797955199000
              }
            ]
          }
        }
        """

        let now = Date(timeIntervalSince1970: 1700000000)
        let (balances, _) = try GlmZcodeAPIClient.parseBalanceResponse(data: Data(json.utf8), now: now)
        XCTAssertEqual(balances.count, 1)
        XCTAssertEqual(balances[0].entitlementID, "ent-ends")
        XCTAssertEqual(balances[0].expiresAt, Date(timeIntervalSince1970: 1797955199))
    }

    func testParseResetCardsWithExpiresAtAlias() throws {
        // 测试 expires_at 代替 expire_at
        let json = """
        {
          "code": 0,
          "msg": "success",
          "data": {
            "available_five_hour_resets": [
              { "expires_at": 1797955199000 }
            ],
            "available_week_resets": [
              { "expires_at": 1797955199000 },
              { "expire_at": 1797955199000 }
            ]
          }
        }
        """

        let snapshot = try GlmZcodeAPIClient.parseResetCardsResponse(data: Data(json.utf8))
        XCTAssertEqual(snapshot.fiveHourResets.count, 1)
        XCTAssertEqual(snapshot.weekResets.count, 2)
        XCTAssertEqual(snapshot.totalCardCount, 3)
    }

    func testGlmZcodeCredentialsHasCredentialsWithoutDeviceMid() {
        let credsWithJwtOnly = GlmZcodeCredentials(deviceMid: nil, jwtToken: "valid-jwt-token")
        XCTAssertTrue(credsWithJwtOnly.hasCredentials)
        XCTAssertFalse(credsWithJwtOnly.hasFullCredentials)

        let fullCredsWithoutMid = GlmZcodeCredentials(
            deviceMid: nil,
            jwtToken: "valid-jwt",
            bigmodelAccessToken: "valid-bigmodel"
        )
        XCTAssertTrue(fullCredsWithoutMid.hasCredentials)
        XCTAssertTrue(fullCredsWithoutMid.hasFullCredentials)

        let emptyCreds = GlmZcodeCredentials(deviceMid: "mid-only", jwtToken: nil)
        XCTAssertFalse(emptyCreds.hasCredentials)
        XCTAssertFalse(emptyCreds.hasFullCredentials)
    }

    func testResetCardsZeroCountDoesNotCountAsHasResetCards() {
        let emptySnapshot = GlmResetCardsSnapshot(fiveHourResets: [], weekResets: [])
        XCTAssertEqual(emptySnapshot.totalCardCount, 0)
        let hasResetCards = emptySnapshot.totalCardCount > 0
        XCTAssertFalse(hasResetCards)

        let snapshotWithCards = GlmResetCardsSnapshot(
            fiveHourResets: [GlmResetCardItem(expireAt: Date())],
            weekResets: []
        )
        XCTAssertEqual(snapshotWithCards.totalCardCount, 1)
        XCTAssertTrue(snapshotWithCards.totalCardCount > 0)
    }

    // MARK: - 8. GlmFillingMissingMerger 固定倍率与 Background 继承测试

    func testGlmFillingMissingMergerInheritsResetCardsInBackground() {
        let merger = GlmFillingMissingMerger()

        let prevCards = GlmResetCardsSnapshot(
            fiveHourResets: [GlmResetCardItem(expireAt: Date(timeIntervalSince1970: 1700000000))],
            weekResets: []
        )
        let prevPackage = GlmZcodePackageSnapshot(
            activityPlanBalances: [],
            activityPlanPreviews: [],
            resetCards: prevCards,
            deliveries: [GlmMarketingDelivery(id: "deliv-1", title: "周末礼包", body: "请领取")],
            fetchedAt: Date(timeIntervalSince1970: 1000)
        )
        let prevQuota = QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: "Pro",
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date(timeIntervalSince1970: 1000),
            glmZcodePackage: prevPackage
        )

        // 1. Background 模式：new 没有 resetCards（跳过查询），但有新的 balance
        let newBalance = GlmActivityPlanBalance(
            planID: "p1", planName: "P1", entitlementID: "e1",
            showName: "GLM-5", modelNames: [], totalUnits: 100,
            usedUnits: 20, remainingUnits: 80, expiresAt: nil, observedAt: nil
        )
        let newPackage = GlmZcodePackageSnapshot(
            activityPlanBalances: [newBalance],
            activityPlanPreviews: [],
            resetCards: nil, // background 按设计跳过
            deliveries: [],  // background 按设计跳过
            fetchedAt: Date(timeIntervalSince1970: 2000)
        )
        let newQuota = QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: "Pro",
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date(timeIntervalSince1970: 2000),
            glmZcodePackage: newPackage
        )

        let mergedBackground = merger.merge(new: newQuota, previous: prevQuota, mode: .background)
        XCTAssertEqual(mergedBackground.glmZcodePackage?.activityPlanBalances.count, 1)
        XCTAssertEqual(mergedBackground.glmZcodePackage?.activityPlanBalances.first?.usedUnits, 20)
        // 关键断言：继承 previous 的重置卡与运营活动列表
        XCTAssertEqual(mergedBackground.glmZcodePackage?.resetCards?.fiveHourResets.count, 1)
        XCTAssertEqual(mergedBackground.glmZcodePackage?.deliveries.count, 1)

        // 2. Full 模式：new 包含了全量刷新的 resetCards（例如卡用完了变 0 张）
        let fullEmptyCards = GlmResetCardsSnapshot(fiveHourResets: [], weekResets: [])
        let fullPackage = GlmZcodePackageSnapshot(
            activityPlanBalances: [newBalance],
            activityPlanPreviews: [],
            resetCards: fullEmptyCards,
            deliveries: [],
            fetchedAt: Date(timeIntervalSince1970: 3000)
        )
        let fullQuota = QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: "Pro",
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date(timeIntervalSince1970: 3000),
            glmZcodePackage: fullPackage
        )

        let mergedFull = merger.merge(new: fullQuota, previous: prevQuota, mode: .full)
        // Full 模式下使用权威的新重置卡（0 张）
        XCTAssertEqual(mergedFull.glmZcodePackage?.resetCards?.totalCardCount, 0)
    }

    func testGlmCodingPlanFetcherUsesGlmFillingMissingMerger() {
        let fetcher = GlmCodingPlanFetcher(apiKey: "test-key", isZcodeCredentialEnabled: true)
        XCTAssertTrue(fetcher.resultMerger is GlmFillingMissingMerger)
    }
}
