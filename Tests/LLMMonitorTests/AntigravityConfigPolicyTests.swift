import Foundation
import XCTest
@testable import LLM_monitor

/// Antigravity provider 凭据策略开关（2.5.0）：
/// - `allowTokenRefresh` 语义翻正为真开关：缺省 **true**（过期时允许运行 agy
///   models 代理刷新）；2.4.0 的「true 抛 SchemaError」路径已删除
/// - `accessTokenFallback`（新增）：keychain → 远端兜底开关，缺省 **true**
/// - 两个键都是 antigravity 专属：其他 provider 下的同名键按未知键忽略
/// - 类型写错按缺失容错（缺省语义）；encode 只在显式设置时落盘
final class AntigravityConfigPolicyTests: XCTestCase {
    private func decodeConfig(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    private func configJSON(_ providerJSON: String) -> String {
        """
        {"schemaVersion":3,"refreshIntervalSeconds":300,"providers":{"antigravity":\(providerJSON)}}
        """
    }

    // MARK: - allowTokenRefresh（语义翻正，缺省 true）

    func testAllowTokenRefreshDefaultsToTrueAndAcceptsExplicitTrue() throws {
        // 缺省 → true（2.4.0 起的「true 抛 SchemaError」路径已删除）。
        let missing = try decodeConfig(configJSON(#"{"enabled":true}"#))
        XCTAssertTrue(missing.providers["antigravity"]?.effectiveAllowTokenRefresh ?? false)

        // 显式 true 合法（2.5.0 语义翻正）。
        let explicitTrue = try decodeConfig(configJSON(#"{"enabled":true,"allowTokenRefresh":true}"#))
        XCTAssertEqual(explicitTrue.providers["antigravity"]?.allowTokenRefresh, true)
        XCTAssertTrue(explicitTrue.providers["antigravity"]?.effectiveAllowTokenRefresh ?? false)
    }

    func testAllowTokenRefreshExplicitFalseStillDecodes() throws {
        // 旧 json 里的显式 false（2.4.x 唯一合法形态）继续按关闭语义生效。
        let explicitFalse = try decodeConfig(configJSON(#"{"enabled":true,"allowTokenRefresh":false}"#))
        XCTAssertEqual(explicitFalse.providers["antigravity"]?.allowTokenRefresh, false)
        XCTAssertFalse(explicitFalse.providers["antigravity"]?.effectiveAllowTokenRefresh ?? true)
    }

    func testAllowTokenRefreshTypeErrorToleratedAsMissing() throws {
        // 类型写错按缺失处理（缺省 true 语义），不进损坏恢复流程。
        let config = try decodeConfig(configJSON(#"{"enabled":true,"allowTokenRefresh":"true"}"#))
        XCTAssertNil(config.providers["antigravity"]?.allowTokenRefresh)
        XCTAssertTrue(config.providers["antigravity"]?.effectiveAllowTokenRefresh ?? false)
    }

    // MARK: - accessTokenFallback（2.5.0 新增，缺省 true）

    func testAccessTokenFallbackDefaultsToTrue() throws {
        let missing = try decodeConfig(configJSON(#"{"enabled":true}"#))
        XCTAssertNil(missing.providers["antigravity"]?.accessTokenFallback)
        XCTAssertTrue(missing.providers["antigravity"]?.effectiveAccessTokenFallback ?? false)
    }

    func testAccessTokenFallbackExplicitValuesDecode() throws {
        let explicitTrue = try decodeConfig(configJSON(#"{"enabled":true,"accessTokenFallback":true}"#))
        XCTAssertEqual(explicitTrue.providers["antigravity"]?.accessTokenFallback, true)

        let explicitFalse = try decodeConfig(configJSON(#"{"enabled":true,"accessTokenFallback":false}"#))
        XCTAssertEqual(explicitFalse.providers["antigravity"]?.accessTokenFallback, false)
        XCTAssertFalse(explicitFalse.providers["antigravity"]?.effectiveAccessTokenFallback ?? true)
    }

    func testAccessTokenFallbackTypeErrorToleratedAsMissing() throws {
        let config = try decodeConfig(configJSON(#"{"enabled":true,"accessTokenFallback":"yes"}"#))
        XCTAssertNil(config.providers["antigravity"]?.accessTokenFallback)
        XCTAssertTrue(config.providers["antigravity"]?.effectiveAccessTokenFallback ?? false)
    }

    // MARK: - antigravity 专属键在其他 provider 下按未知键忽略

    func testAntigravityKeysIgnoredOnOtherProviders() throws {
        // 两个键都是 antigravity 专属：其他 provider 下的同名键按未知键忽略——
        // 不报错、不落字段（整份配置不得被误伤拒收）。
        let codexOnly = try decodeConfig(
            #"{"schemaVersion":3,"refreshIntervalSeconds":300,"providers":{"codex_chatgpt":{"enabled":true,"allowTokenRefresh":true,"accessTokenFallback":false}}}"#
        )
        let codexConfig = codexOnly.providers["codex_chatgpt"]
        XCTAssertNil(codexConfig?.allowTokenRefresh, "非 antigravity 不落字段（与其他未知键同语义）")
        XCTAssertNil(codexConfig?.accessTokenFallback, "非 antigravity 不落字段（与其他未知键同语义）")
        // 忽略是双向的：重新 encode 不回写该键。
        let reencoded = try JSONEncoder().encode(codexConfig)
        let reencodedString = String(data: reencoded, encoding: .utf8) ?? ""
        XCTAssertFalse(reencodedString.contains("allowTokenRefresh"), "忽略后的键不随 encode 回写")
        XCTAssertFalse(reencodedString.contains("accessTokenFallback"), "忽略后的键不随 encode 回写")

        // 混合配置：codex 带同名键不影响解码，antigravity 的开关正常生效。
        let mixed = try decodeConfig(
            #"{"schemaVersion":3,"refreshIntervalSeconds":300,"providers":{"codex_chatgpt":{"enabled":true,"allowTokenRefresh":true},"antigravity":{"enabled":true,"allowTokenRefresh":false,"accessTokenFallback":false}}}"#
        )
        XCTAssertTrue(mixed.providers["codex_chatgpt"]?.effectiveAllowTokenRefresh ?? false)
        XCTAssertFalse(mixed.providers["antigravity"]?.effectiveAllowTokenRefresh ?? true)
        XCTAssertFalse(mixed.providers["antigravity"]?.effectiveAccessTokenFallback ?? true)
    }

    // MARK: - encode

    func testEncodeOmitsNilSwitches() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let omitted = try encoder.encode(ProviderConfig(enabled: true))
        let omittedString = String(data: omitted, encoding: .utf8) ?? ""
        XCTAssertFalse(omittedString.contains("allowTokenRefresh"), "nil 字段不落盘")
        XCTAssertFalse(omittedString.contains("accessTokenFallback"), "nil 字段不落盘")

        let explicit = try encoder.encode(ProviderConfig(enabled: true, allowTokenRefresh: false, accessTokenFallback: false))
        let explicitString = String(data: explicit, encoding: .utf8) ?? ""
        XCTAssertTrue(explicitString.contains(#""allowTokenRefresh" : false"#))
        XCTAssertTrue(explicitString.contains(#""accessTokenFallback" : false"#))
    }

    // MARK: - 默认刷新间隔

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
