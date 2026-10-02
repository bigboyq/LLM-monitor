import XCTest
import Foundation
@testable import LLM_monitor

/// `AntigravityFetcher` 的进程命令分类与 flag 解析规则。对应 `AntigravityFetcher`
/// 的 `classify` / `parseProcessLine` / `extractFlag` 一族。
final class ProcessClassificationTests: XCTestCase {

    // MARK: - Process Classification & Language Server

    func testProcessClassificationAndLanguageServerRules() {
        // Process Classification (.ide, .cli, nil)
        let ideCommands = [
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server --app_data_dir /Users/me/.config/Antigravity --csrf_token abc123 --enable_lsp",
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server --app_data_dir /Users/me/.gemini/antigravity"
        ]
        for cmd in ideCommands {
            XCTAssertEqual(AntigravityFetcher.classify(command: cmd), .ide, "command: \(cmd)")
        }

        // Antigravity IDE.app 已剥离支持：命中其产品特征的命令不再识别
        let strippedIDEAppCommands = [
            "/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --csrf_token abc123 --subclient_type ide",
            "/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64 --csrf_token abc --app_data_dir antigravity-ide",
            "/opt/tools/language_server_macos_arm --csrf_token abc --app_data_dir antigravity-ide",
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server --app_data_dir /Users/me/.gemini/antigravity-ide"
        ]
        for cmd in strippedIDEAppCommands {
            XCTAssertNil(AntigravityFetcher.classify(command: cmd), "command: \(cmd)")
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

        // Binary match strictness（只接受裸名 language_server / language-server，可带 .exe）
        XCTAssertTrue(AntigravityFetcher.isLanguageServerBinary("/Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token x"))
        XCTAssertTrue(AntigravityFetcher.isLanguageServerBinary("/path/to/language-server --flag"))
        XCTAssertTrue(AntigravityFetcher.isLanguageServerBinary("/opt/tools/language_server.exe --flag"))
        XCTAssertFalse(AntigravityFetcher.isLanguageServerBinary("/usr/bin/strlanguage_server --flag"))
        // 带架构后缀的二进制是已剥离的 Antigravity IDE.app 专属形态
        XCTAssertFalse(AntigravityFetcher.isLanguageServerBinary("/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --csrf_token x"))
        XCTAssertFalse(AntigravityFetcher.isLanguageServerBinary("/opt/tools/language_server_macos_x64 --flag"))
        XCTAssertNil(AntigravityFetcher.classify(command: "/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --csrf_token x"))

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

    /// L7: extractFlag 的末位取值与成对引号剥离（原实现要求 name 后紧跟空格
    /// 定界、引号原样进入值）。
    func testExtractFlagHandlesEndOfStringValueAndStripsQuotes() {
        // 既有行为兼容：常规空格定界取第一个 token
        XCTAssertEqual(
            AntigravityFetcher.extractFlag(named: "--csrf_token", from: "/bin/language_server --csrf_token abc --other x"),
            "abc"
        )
        // 值为 argv 末位 token：取到串尾
        XCTAssertEqual(
            AntigravityFetcher.extractFlag(named: "--csrf_token", from: "/bin/language_server --csrf_token abc123"),
            "abc123"
        )
        // 成对引号剥离（引号内的空白属于值本身）
        XCTAssertEqual(
            AntigravityFetcher.extractFlag(named: "--csrf_token", from: #"/bin/language_server --csrf_token "abc 123""#),
            "abc 123"
        )
        XCTAssertEqual(
            AntigravityFetcher.extractFlag(named: "--csrf_token", from: "/bin/language_server --csrf_token 'abc'"),
            "abc"
        )
        // 末位 + 引号（--app_data_dir 的常见写法）
        XCTAssertEqual(
            AntigravityFetcher.extractFlag(named: "--app_data_dir", from: #"/opt/tools/language_server --app_data_dir "antigravity-ide""#),
            "antigravity-ide"
        )
        // flag name 位于 argv 末位且无值 → nil；name 不在命令行 → nil
        XCTAssertNil(AntigravityFetcher.extractFlag(named: "--csrf_token", from: "/bin/language_server --csrf_token"))
        XCTAssertNil(AntigravityFetcher.extractFlag(named: "--csrf_token", from: "/bin/language_server --enable_lsp"))
        // 引号不成对：按字面返回 token（不剥引号）
        XCTAssertEqual(
            AntigravityFetcher.extractFlag(named: "--csrf_token", from: #"/bin/language_server --csrf_token "abc"#),
            "\"abc"
        )
    }

    /// L8: isUnsupportedIDEAppCommand 锚定匹配——工作区路径里包含产品子串的
    /// 无关进程不得被误排除；真正的产品特征仍然命中剥离规则。
    func testUnsupportedIDEAppMatchingIsAnchoredAgainstWorkspacePathFalsePositives() {
        // 反例：workspace / 父级路径包含 antigravity-ide 子串的 IDE 进程应正常识别
        let falsePositives = [
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server --workspace_id /Users/me/dev/antigravity-ide-notes/proj --csrf_token abc",
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server --app_data_dir /Users/me/.gemini/antigravity-ide-backup",
        ]
        for cmd in falsePositives {
            XCTAssertEqual(AntigravityFetcher.classify(command: cmd), .ide, "command: \(cmd)")
        }

        // 真正的产品特征仍然命中剥离规则
        let stillStripped = [
            // bundle 路径成分（antigravity ide.app）精确命中
            "/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --csrf_token x",
            // --app_data_dir 的值（末位路径组件）精确为 antigravity-ide
            "/opt/tools/language_server_macos_arm --csrf_token abc --app_data_dir antigravity-ide",
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server --app_data_dir /Users/me/.gemini/antigravity-ide",
        ]
        for cmd in stillStripped {
            XCTAssertNil(AntigravityFetcher.classify(command: cmd), "command: \(cmd)")
        }
    }
}
