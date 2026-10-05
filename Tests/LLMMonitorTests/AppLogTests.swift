import XCTest
@testable import LLM_monitor

/// AppLog 的 0600 权限 / 轮转决策 / 轮转行为 / os.Logger 隐私路径。
/// 拆自 `ScannerAndLoggingTests`，逐字搬移零逻辑变化。
final class AppLogTests: XCTestCase {

    /// AppLog 文件权限 4 in 1：新建 0600 / 收紧已有 0644 → 0600 / setLogFilePermissions 不创建 / rotate 后新建仍 0600
    func testAppLogFilePermissions() {
        // 1. 文件不存在 → ensureLogFile 后应有 0600 权限
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-create-\(UUID().uuidString).txt"
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath))

            AppLog.ensureLogFile(at: URL(fileURLWithPath: tempPath))

            XCTAssertTrue(FileManager.default.fileExists(atPath: tempPath))
            let perms = (try? FileManager.default.attributesOfItem(atPath: tempPath)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(perms, 0o600, "新建 log 文件应有 0600 权限，实际：\(perms.map { String(format: "%o", $0) } ?? "nil")")
        }
        // 2. 文件已存在 0644 → ensureLogFile 后收紧到 0600
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-tighten-\(UUID().uuidString).txt"
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            FileManager.default.createFile(
                atPath: tempPath, contents: nil,
                attributes: [.posixPermissions: NSNumber(value: 0o644)]
            )
            let prePerms = (try? FileManager.default.attributesOfItem(atPath: tempPath)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(prePerms, 0o644, "前置：预创建 0644")

            AppLog.ensureLogFile(at: URL(fileURLWithPath: tempPath))

            let postPerms = (try? FileManager.default.attributesOfItem(atPath: tempPath)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(postPerms, 0o600, "已存在文件应被收紧到 0600")
        }
        // 3. setLogFilePermissions 不创建文件（仅收紧已存在的）
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-noop-\(UUID().uuidString).txt"
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath))

            AppLog.setLogFilePermissions(URL(fileURLWithPath: tempPath))

            XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath), "setLogFilePermissions 不应创建文件")
        }
        // 4. rotate 后新 active 文件用 createFile 路径, 权限 0600
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-rotate-perm-\(UUID().uuidString).txt"
            let fileURL = URL(fileURLWithPath: tempPath)
            defer {
                try? FileManager.default.removeItem(atPath: tempPath)
                try? FileManager.default.removeItem(atPath: tempPath + ".1")
            }
            AppLog.ensureLogFile(at: fileURL)
            AppLog.rotateLogFile(at: fileURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "rotate 后 active 应不存在")
            // 重新创建 (模拟下次写入) → 仍是 0600
            AppLog.ensureLogFile(at: fileURL)
            let perms = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(perms, 0o600, "rotate 后新建的 log 文件应有 0600 权限")
        }
    }

    /// shouldRotate 决策 3 in 1：超阈值 rotate / 低于阈值不 rotate / 文件缺失不 rotate
    func testAppLogShouldRotate() throws {
        // 1. 超过阈值 → rotate
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-over-\(UUID().uuidString).txt"
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            // 1MB 文件 + 4.5MB 新内容 = 5.5MB > 5MB 阈值 → 应该 rotate
            try Data(count: 1 * 1024 * 1024).write(to: URL(fileURLWithPath: tempPath))
            XCTAssertTrue(
                AppLog.shouldRotate(fileURL: URL(fileURLWithPath: tempPath), additionalBytes: Int(4.5 * 1024 * 1024)),
                "1MB + 4.5MB > 5MB 阈值, 应该 rotate"
            )
        }
        // 2. 低于阈值 → 不 rotate
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-under-\(UUID().uuidString).txt"
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            try Data(count: 1 * 1024 * 1024).write(to: URL(fileURLWithPath: tempPath))
            XCTAssertFalse(
                AppLog.shouldRotate(fileURL: URL(fileURLWithPath: tempPath), additionalBytes: 1 * 1024 * 1024),
                "1MB + 1MB < 5MB 阈值, 不应 rotate"
            )
        }
        // 3. 文件缺失 → 不 rotate (write 路径会创建新文件)
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-miss-\(UUID().uuidString).txt"
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            XCTAssertFalse(
                AppLog.shouldRotate(fileURL: URL(fileURLWithPath: tempPath), additionalBytes: 1000)
            )
        }
    }

    /// rotate 行为 2 in 1：3 个文件全在时 shift / 只有 active 时也能正常 rotate
    func testAppLogRotateBehavior() throws {
        // 1. 初始 active + .1 + .2 → rotate 后内容 shift, 原 active 进 .1, 原 .1 进 .2
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-shift-\(UUID().uuidString).txt"
            let fileURL = URL(fileURLWithPath: tempPath)
            let backup1URL = URL(fileURLWithPath: "\(tempPath).1")
            let backup2URL = URL(fileURLWithPath: "\(tempPath).2")
            defer {
                for p in [fileURL, backup1URL, backup2URL] { try? FileManager.default.removeItem(at: p) }
            }

            try Data(count: 100).write(to: fileURL)   // active = 100
            try Data(count: 200).write(to: backup1URL) // .1 = 200
            try Data(count: 300).write(to: backup2URL) // .2 = 300

            AppLog.rotateLogFile(at: fileURL)

            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                          "active 旋转后应不存在, 下次 write 创建新的")
            XCTAssertEqual(try Data(contentsOf: backup1URL).count, 100, ".1 现在应该是原 active (100 bytes) 的内容")
            XCTAssertEqual(try Data(contentsOf: backup2URL).count, 200, ".2 现在应该是原 .1 (200 bytes) 的内容")
        }
        // 2. 单独 active (没有 .1 .2) 时 rotate 也能正常 shift
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-activeonly-\(UUID().uuidString).txt"
            let fileURL = URL(fileURLWithPath: tempPath)
            let backup1URL = URL(fileURLWithPath: "\(tempPath).1")
            defer {
                try? FileManager.default.removeItem(at: fileURL)
                try? FileManager.default.removeItem(at: backup1URL)
            }
            try Data(count: 50).write(to: fileURL)

            AppLog.rotateLogFile(at: fileURL)

            XCTAssertTrue(FileManager.default.fileExists(atPath: backup1URL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
            XCTAssertEqual(try Data(contentsOf: backup1URL).count, 50)
        }
    }

    /// os.Logger 4 个 level 走 `.private` 不崩 (实际 privacy 靠 Xcode 静态分析 / Console.app 验证)
    func testAppLogOsLogPrivateDoesNotCrash() {
        AppLog.shared.info({ "test private path info" })
        AppLog.shared.debug({ "test private path debug" })
        AppLog.shared.warn({ "test private path warn" })
        AppLog.shared.error({ "test private path error" })
    }

    /// P2 回归：裸 `swift test`（不带 `LLM_MONITOR_LOG_PATH` 覆盖）曾把 fixture 日志
    /// 写进用户真实的 `~/Library/Application Support/LLM-monitor/log.txt`（实测污染
    /// 2000+ 行并触发两次轮转）。测试进程必须改写到临时目录；显式覆盖优先级最高、
    /// 生产路径不变。
    func testLogPathResolvesToTemporaryDirectoryInTestProcess() throws {
        XCTAssertTrue(AppLog.isRunningUnderTest, "本用例跑在 XCTest 进程里，应被识别为测试环境")
        let supportDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )

        let underTest = AppLog.resolveLogFileURL(environment: [:], isUnderTest: true)
        XCTAssertTrue(
            underTest.path.hasPrefix(NSTemporaryDirectory()),
            "测试日志应落在临时目录，实际：\(underTest.path)"
        )
        XCTAssertFalse(
            underTest.path.hasPrefix(supportDirectory.path),
            "测试日志不得落在用户 Application Support 下，实际：\(underTest.path)"
        )

        let production = AppLog.resolveLogFileURL(environment: [:], isUnderTest: false)
        XCTAssertEqual(
            production.path,
            supportDirectory.appendingPathComponent("LLM-monitor", isDirectory: true)
                .appendingPathComponent("log.txt").path,
            "非测试环境必须仍是生产路径"
        )

        // 显式覆盖优先级最高（测试环境同样认），并按空白裁剪。
        let overridden = AppLog.resolveLogFileURL(
            environment: ["LLM_MONITOR_LOG_PATH": "  /tmp/llm-monitor-override.log  "],
            isUnderTest: true
        )
        XCTAssertEqual(overridden.path, "/tmp/llm-monitor-override.log")
        // 纯空白视作未设置。
        XCTAssertEqual(
            AppLog.resolveLogFileURL(environment: ["LLM_MONITOR_LOG_PATH": "   "], isUnderTest: true).path,
            underTest.path
        )
    }
}
