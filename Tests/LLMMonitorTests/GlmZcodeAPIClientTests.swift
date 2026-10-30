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

    func testProviderConfigZcodePlanAndNotifyCampaign() throws {
        // 兼容解码 parseZcodeBalanceLog
        let legacyJSON = #"{"enabled":true,"parseZcodeBalanceLog":true}"#
        let legacyConfig = try JSONDecoder().decode(ProviderConfig.self, from: Data(legacyJSON.utf8))
        XCTAssertTrue(legacyConfig.isZcodePlanEnabled)

        // 新 parseZcodePlan 与 notifyCampaign
        let config = ProviderConfig(
            enabled: true,
            parseZcodePlan: true,
            notifyCampaign: .barkAndSystem
        )
        XCTAssertTrue(config.isZcodePlanEnabled)
        XCTAssertEqual(config.notifyCampaign, .barkAndSystem)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)
        XCTAssertEqual(decoded.parseZcodePlan, true)
        XCTAssertEqual(decoded.notifyCampaign, .barkAndSystem)
        XCTAssertTrue(decoded.isZcodePlanEnabled)

        // draft 同步
        var draft = SettingsFormDraft()
        draft.glmZcodePlanEnabled = decoded.isZcodePlanEnabled
        draft.glmNotifyCampaign = decoded.notifyCampaign ?? .none
        XCTAssertTrue(draft.glmZcodePlanEnabled)
        XCTAssertEqual(draft.glmNotifyCampaign, .barkAndSystem)
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
}
