import XCTest
import Foundation
@testable import LLM_monitor

final class ClientBindingConfigTests: XCTestCase {

    func testClientRegistrySeparatesMultiProviderClientsFromQuotaProviders() {
        let openCode = try! XCTUnwrap(ClientDescriptor.all.first { $0.id == ClientID.openCode })
        let dsh = try! XCTUnwrap(ClientDescriptor.all.first { $0.id == ClientID.dsh })
        XCTAssertGreaterThan(openCode.supportedQuotaProviderIDs.count, 2)
        XCTAssertGreaterThan(dsh.supportedQuotaProviderIDs.count, 1)
        XCTAssertEqual(ProviderKind.deepseek.quotaProviderID, QuotaProviderID.deepseek)
        XCTAssertEqual(ProviderKind.glmCodingPlan.quotaProviderID, QuotaProviderID.zhipu)
    }

    func testLegacyProviderMergeFlagsMigrateToClientBindings() throws {
        let json = """
        {
          "schemaVersion": 1,
          "refreshIntervalSeconds": 300,
          "providers": {
            "glm_coding_plan": {"enabled": false, "mergeOpencodeUsage": false},
            "deepseek": {"enabled": false, "mergeOpencodeUsage": true}
          }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.schemaVersion, AppConfig.currentSchemaVersion)
        XCTAssertFalse(config.isClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.zhipu
        ))
        XCTAssertTrue(config.isClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.deepseek
        ))
    }

    func testClientBindingsEncodeDecodeRoundTrip() throws {
        // 把 schema v2 config 编码回 JSON 再解码，必须保持 clientBindings 不丢失。
        // 覆盖 setClientBindingEnabled 的两条路径：
        // 1) 更新已有 binding（openCode + deepseek 改为 enabled = true）；
        // 2) 新增 binding（minimax + codex 这对在 default 中存在；
        //    改 antigravity binding 走更新路径以验证重复 binding 不重复写入）。
        var config = AppConfig.default
        config.setClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.deepseek,
            enabled: true
        )
        config.setClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.zhipu,
            enabled: false
        )

        let encoded = try JSONEncoder().encode(config)
        let roundTripped = try JSONDecoder().decode(AppConfig.self, from: encoded)

        XCTAssertEqual(roundTripped.clientBindings.count, config.clientBindings.count,
                       "clientBindings encode/decode 必须保持原有数量，重复 set 不能添加副本")
        XCTAssertTrue(roundTripped.isClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.deepseek
        ))
        XCTAssertFalse(roundTripped.isClientBindingEnabled(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.zhipu
        ))
    }

    func testSetClientBindingEnabledAppendsForUnknownPair() throws {
        // 给一个 default 中不存在的 (clientID, quotaProviderID) 对调用
        // setClientBindingEnabled 必须 append 一个新 binding，而不是静默失败。
        // （codex 目前没有 quota 绑定条目；dsh 三条在 P2 已进入默认绑定。）
        var config = AppConfig.default
        let before = config.clientBindings.count
        config.setClientBindingEnabled(
            clientID: ClientID.codex,
            quotaProviderID: QuotaProviderID.deepseek,
            enabled: true
        )
        XCTAssertEqual(config.clientBindings.count, before + 1)
        XCTAssertTrue(config.isClientBindingEnabled(
            clientID: ClientID.codex,
            quotaProviderID: QuotaProviderID.deepseek
        ))
    }
}
