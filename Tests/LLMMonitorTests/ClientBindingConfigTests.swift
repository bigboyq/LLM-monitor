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

    // MARK: - clientBindings 解码合并（老配置补齐新增默认绑定）

    /// 组装一份最小可解码的 config.json 字典，附带调用方给的 clientBindings 数组。
    private func makeConfigJSON(
        clientBindings: [[String: Any]]? = nil,
        schemaVersion: Int? = nil
    ) -> Data {
        var json: [String: Any] = [
            "refreshIntervalSeconds": 300,
            "providers": [String: Any]()
        ]
        if let schemaVersion { json["schemaVersion"] = schemaVersion }
        if let clientBindings { json["clientBindings"] = clientBindings }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func decodeConfig(_ data: Data) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: data)
    }

    private func bindingEntry(
        clientID: String,
        quotaProviderID: String,
        sourceProviderAliases: [String],
        enabled: Bool
    ) -> [String: Any] {
        [
            "clientID": clientID,
            "quotaProviderID": quotaProviderID,
            "sourceProviderAliases": sourceProviderAliases,
            "enabled": enabled
        ]
    }

    /// 老用户配置：数组已存在、只有 5 条 opencode 绑定，且 opencode → deepseek 被
    /// 用户显式打开（默认是 false）。解码后必须补上 zcode（2 条）与 dsh（3 条）
    /// 默认绑定，同时用户的显式值原样保留——不能被默认值覆盖。
    func testDecodeAddsNewDefaultBindingsToExistingLegacyArray() throws {
        let existing: [[String: Any]] = [
            bindingEntry(
                clientID: ClientID.openCode,
                quotaProviderID: QuotaProviderID.minimax,
                sourceProviderAliases: [OpencodeLocalUsage.minimaxCodingPlanProviderID],
                enabled: false
            ),
            bindingEntry(
                clientID: ClientID.openCode,
                quotaProviderID: QuotaProviderID.openAI,
                sourceProviderAliases: [OpencodeLocalUsage.openAIProviderID],
                enabled: false
            ),
            bindingEntry(
                clientID: ClientID.openCode,
                quotaProviderID: QuotaProviderID.antigravity,
                sourceProviderAliases: OpencodeLocalUsage.antigravityProviderIDs,
                enabled: false
            ),
            bindingEntry(
                clientID: ClientID.openCode,
                quotaProviderID: QuotaProviderID.zhipu,
                sourceProviderAliases: [OpencodeLocalUsage.glmProviderID],
                enabled: true
            ),
            bindingEntry(
                clientID: ClientID.openCode,
                quotaProviderID: QuotaProviderID.deepseek,
                sourceProviderAliases: [OpencodeLocalUsage.deepseekProviderID],
                enabled: true
            )
        ]
        let config = try decodeConfig(makeConfigJSON(clientBindings: existing))

        XCTAssertEqual(
            config.clientBindings.count, 10,
            "5 条 opencode + 2 条 zcode + 3 条 dsh 默认绑定"
        )
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.minimax),
            "老配置应补上 zcode → minimax 默认绑定（enabled=true）"
        )
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.deepseek),
            "老配置应补上 zcode → deepseek 默认绑定（enabled=true）"
        )
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.openCode, quotaProviderID: QuotaProviderID.deepseek),
            "用户显式打开的 opencode → deepseek 不应被默认值(false)覆盖"
        )
        // 补齐只追加到尾部，opencode 段落顺序与来源别名保持原样。
        XCTAssertEqual(
            config.clientBindings.prefix(5).map { "\($0.clientID):\($0.quotaProviderID)" },
            existing.map { "\($0["clientID"] as! String):\($0["quotaProviderID"] as! String)" }
        )
        XCTAssertEqual(
            config.clientBindings.first?.sourceProviderAliases,
            [OpencodeLocalUsage.minimaxCodingPlanProviderID]
        )
    }

    /// 已经包含全部默认绑定的配置解码后不应重复，也不应重排。
    func testDecodeDoesNotDuplicateOrReorderCompleteDefaultBindings() throws {
        let encoded = try JSONEncoder().encode(AppConfig.defaultClientBindings)
        let bindings = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])

        let config = try decodeConfig(makeConfigJSON(clientBindings: bindings))

        XCTAssertEqual(config.clientBindings, AppConfig.defaultClientBindings)
        XCTAssertEqual(config.clientBindings.count, AppConfig.defaultClientBindings.count)
    }

    /// 用户把某条默认绑定显式关掉后解码不能复活它（补齐只针对"缺失的组合"）。
    func testDecodeKeepsExplicitlyDisabledDefaultBindingDisabled() throws {
        let encoded = try JSONEncoder().encode(AppConfig.defaultClientBindings)
        var bindings = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        for index in bindings.indices {
            if bindings[index]["clientID"] as? String == ClientID.zcode,
               bindings[index]["quotaProviderID"] as? String == QuotaProviderID.minimax {
                bindings[index]["enabled"] = false
            }
        }

        let config = try decodeConfig(makeConfigJSON(clientBindings: bindings))

        XCTAssertFalse(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.minimax),
            "用户关掉的 zcode → minimax 不应被默认值复活"
        )
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.deepseek)
        )
        XCTAssertEqual(config.clientBindings.count, AppConfig.defaultClientBindings.count)
    }

    /// clientBindings 字段缺失（schema 0 legacy 路径）同样要经过合并，不能停在
    /// 5 条 opencode 上。
    func testDecodeWithoutClientBindingsFieldFallsBackToFullDefaults() throws {
        let config = try decodeConfig(makeConfigJSON())

        XCTAssertEqual(config.clientBindings, AppConfig.defaultClientBindings)
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.minimax)
        )
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.deepseek)
        )
    }

    /// schema 1（有 clientBindings、无 zcode 新条目的老用户）走的是同一合并逻辑。
    func testSchema1ConfigAlsoReceivesNewDefaultBindings() throws {
        let existing: [[String: Any]] = [
            bindingEntry(
                clientID: ClientID.openCode,
                quotaProviderID: QuotaProviderID.zhipu,
                sourceProviderAliases: [OpencodeLocalUsage.glmProviderID],
                enabled: true
            )
        ]
        let config = try decodeConfig(
            makeConfigJSON(clientBindings: existing, schemaVersion: 1)
        )

        XCTAssertEqual(config.schemaVersion, AppConfig.currentSchemaVersion)
        XCTAssertEqual(config.clientBindings.count, AppConfig.defaultClientBindings.count)
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.minimax)
        )
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.deepseek)
        )
        XCTAssertTrue(
            config.isClientBindingEnabled(clientID: ClientID.openCode, quotaProviderID: QuotaProviderID.zhipu),
            "原有条目不应被改写"
        )
    }
}
