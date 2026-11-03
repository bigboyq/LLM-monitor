import XCTest
import Foundation
@testable import LLM_monitor

final class ClientBindingConfigTests: XCTestCase {
    func testClientRegistrySeparatesMultiProviderClientsFromQuotaProviders() throws {
        let openCode = try XCTUnwrap(ClientDescriptor.all.first { $0.id == ClientID.openCode })
        let dsh = try XCTUnwrap(ClientDescriptor.all.first { $0.id == ClientID.dsh })
        XCTAssertGreaterThan(openCode.supportedQuotaProviderIDs.count, 2)
        XCTAssertGreaterThan(dsh.supportedQuotaProviderIDs.count, 1)
        XCTAssertEqual(ProviderKind.deepseek.quotaProviderID, QuotaProviderID.deepseek)
        XCTAssertEqual(ProviderKind.glmCodingPlan.quotaProviderID, QuotaProviderID.zhipu)
    }

    func testLegacyDisabledBindingsDoNotDisableAutomaticAttribution() throws {
        let json = #"{"schemaVersion":2,"refreshIntervalSeconds":300,"providers":{},"clientBindings":[{"clientID":"opencode","quotaProviderID":"deepseek","sourceProviderAliases":["wrong-alias"],"enabled":false}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.schemaVersion, AppConfig.currentSchemaVersion)
        XCTAssertEqual(config.clientBindings, ClientProviderBinding.defaultBindings)
        XCTAssertTrue(config.clientBindings.allSatisfy(\.enabled))
        XCTAssertTrue(config.isClientBindingEnabled(clientID: ClientID.openCode, quotaProviderID: QuotaProviderID.deepseek))
        XCTAssertEqual(
            config.clientBindings.first { $0.clientID == ClientID.openCode && $0.quotaProviderID == QuotaProviderID.deepseek }?.sourceProviderAliases,
            ["deepseek"]
        )
    }

    func testLegacyProviderMergeFlagIsIgnoredAndNotSaved() throws {
        let json = #"{"schemaVersion":1,"refreshIntervalSeconds":300,"providers":{"glm_coding_plan":{"enabled":true,"mergeOpencodeUsage":false},"deepseek":{"enabled":true,"mergeOpencodeUsage":false}}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.isClientBindingEnabled(clientID: ClientID.openCode, quotaProviderID: QuotaProviderID.zhipu))
        XCTAssertTrue(config.isClientBindingEnabled(clientID: ClientID.openCode, quotaProviderID: QuotaProviderID.deepseek))
        let encoded = try JSONEncoder().encode(config)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let providers = try XCTUnwrap(root["providers"] as? [String: [String: Any]])
        XCTAssertNil(providers["glm_coding_plan"]?["mergeOpencodeUsage"])
        XCTAssertNil(providers["deepseek"]?["mergeOpencodeUsage"])
    }

    func testSavedConfigOmitsAttributionOptionsAndRestoresBuiltInRoutes() throws {
        let encoded = try JSONEncoder().encode(AppConfig.default)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(root["clientBindings"], "自动归因路由不是用户配置项")
        let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
        XCTAssertEqual(decoded.clientBindings, ClientProviderBinding.defaultBindings)
        XCTAssertTrue(decoded.clientBindings.allSatisfy(\.enabled))
    }

    func testMalformedRemovedAttributionOptionsDoNotBreakConfigLoading() throws {
        let json = #"{"refreshIntervalSeconds":180,"providers":{"glm_coding_plan":{"enabled":true,"mergeOpencodeUsage":"removed"}},"clientBindings":"removed"}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.refreshIntervalSeconds, 180)
        XCTAssertEqual(config.clientBindings, ClientProviderBinding.defaultBindings)
        XCTAssertEqual(config.providers["glm_coding_plan"]?.enabled, true)
    }
}
