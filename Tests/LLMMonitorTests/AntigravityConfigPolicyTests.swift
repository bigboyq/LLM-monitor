import Foundation
import XCTest
@testable import LLM_monitor

/// Antigravity provider 配置策略（阶段一）：
/// - `allowTokenRefresh` 强制 false：显式 true 是无效配置 → 解码报
///   `AppConfig.SchemaError.antigravityAllowTokenRefresh`（沿用配置解码错误呈现路径）
/// - 类型写错按缺失容错（false 语义）；encode 只在显式设置时落盘
final class AntigravityConfigPolicyTests: XCTestCase {
    private func decodeConfig(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    private func configJSON(_ providerJSON: String) -> String {
        """
        {"schemaVersion":3,"refreshIntervalSeconds":300,"providers":{"antigravity":\(providerJSON)}}
        """
    }

    func testAllowTokenRefreshTrueIsRejected() {
        XCTAssertThrowsError(try decodeConfig(configJSON(#"{"enabled":true,"allowTokenRefresh":true}"#))) { error in
            guard let schemaError = error as? AppConfig.SchemaError,
                  case .antigravityAllowTokenRefresh = schemaError else {
                return XCTFail("期望 SchemaError.antigravityAllowTokenRefresh，实际 \(error)")
            }
            XCTAssertEqual(
                schemaError.errorDescription,
                "无效配置：providers.antigravity.allowTokenRefresh 不允许为 true（token 由 Antigravity 客户端自行刷新）"
            )
        }
    }

    func testAllowTokenRefreshFalseAndMissingDecodeAsNil() throws {
        let explicitFalse = try decodeConfig(configJSON(#"{"enabled":true,"allowTokenRefresh":false}"#))
        XCTAssertEqual(explicitFalse.providers["antigravity"]?.allowTokenRefresh, false)

        let missing = try decodeConfig(configJSON(#"{"enabled":true}"#))
        XCTAssertNil(missing.providers["antigravity"]?.allowTokenRefresh)
    }

    func testAllowTokenRefreshTypeErrorToleratedAsMissing() throws {
        // 类型写错按缺失处理（false 语义），不进损坏恢复流程。
        let config = try decodeConfig(configJSON(#"{"enabled":true,"allowTokenRefresh":"true"}"#))
        XCTAssertNil(config.providers["antigravity"]?.allowTokenRefresh)
    }

    func testAllowTokenRefreshTrueIgnoredOnOtherProviders() throws {
        // `allowTokenRefresh` 是 antigravity 专属字段：其他 provider 下的同名键
        // 按未知键忽略——不报错、不落字段（整份配置不得被误伤拒收）。
        let codexOnly = try decodeConfig(
            #"{"schemaVersion":3,"refreshIntervalSeconds":300,"providers":{"codex_chatgpt":{"enabled":true,"allowTokenRefresh":true}}}"#
        )
        XCTAssertNil(
            codexOnly.providers["codex_chatgpt"]?.allowTokenRefresh,
            "非 antigravity 不落字段（与其他未知键同语义）"
        )
        // 忽略是双向的：重新 encode 不回写该键。
        let reencoded = try JSONEncoder().encode(codexOnly.providers["codex_chatgpt"])
        XCTAssertFalse(
            String(data: reencoded, encoding: .utf8)?.contains("allowTokenRefresh") ?? true,
            "忽略后的键不随 encode 回写"
        )

        // 混合配置：codex 带 true 不影响解码，antigravity 带 true 仍按原语义拒绝。
        XCTAssertThrowsError(
            try decodeConfig(
                #"{"schemaVersion":3,"refreshIntervalSeconds":300,"providers":{"codex_chatgpt":{"enabled":true,"allowTokenRefresh":true},"antigravity":{"enabled":true,"allowTokenRefresh":true}}}"#
            )
        ) { error in
            guard let schemaError = error as? AppConfig.SchemaError,
                  case .antigravityAllowTokenRefresh = schemaError else {
                return XCTFail("期望 SchemaError.antigravityAllowTokenRefresh，实际 \(error)")
            }
        }
    }

    func testEncodeOmitsNilAllowTokenRefresh() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let omitted = try encoder.encode(ProviderConfig(enabled: true))
        XCTAssertFalse(
            String(data: omitted, encoding: .utf8)?.contains("allowTokenRefresh") ?? true,
            "nil 字段不落盘"
        )

        let explicitFalse = try encoder.encode(ProviderConfig(enabled: true, allowTokenRefresh: false))
        XCTAssertTrue(
            String(data: explicitFalse, encoding: .utf8)?.contains(#""allowTokenRefresh" : false"#) ?? false
        )
    }

    func testDefaultProviderRefreshIntervalOnlyAppliesToAntigravity() {
        XCTAssertNotNil(AppConfig.defaultProviderRefreshInterval(for: ProviderKind.antigravity.providerID))
        XCTAssertEqual(
            AppConfig.defaultProviderRefreshInterval(for: ProviderKind.antigravity.providerID),
            300
        )
        XCTAssertNil(AppConfig.defaultProviderRefreshInterval(for: ProviderKind.minimaxTokenPlan.providerID))
        XCTAssertNil(AppConfig.defaultProviderRefreshInterval(for: ProviderKind.codexChatGpt.providerID))
        XCTAssertNil(AppConfig.defaultProviderRefreshInterval(for: ProviderKind.glmCodingPlan.providerID))
        XCTAssertNil(AppConfig.defaultProviderRefreshInterval(for: ProviderKind.deepseek.providerID))
    }
}
