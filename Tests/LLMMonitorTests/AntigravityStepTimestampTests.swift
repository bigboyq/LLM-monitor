import XCTest
import SQLite3
@testable import LLM_monitor

/// StepTimestampReader（varint 跨边界、只读原路径 / 可写临时副本、只取 LLM steps）与
/// 旧版 per-session 缓存产物的清理目标解析。
final class AntigravityStepTimestampTests: AntigravityTestCase {

    // MARK: - 测试

    func testStepTimestampReaderParsesMetadataTimestamp() {
        func varint(_ value: UInt64) -> [UInt8] {
            var value = value
            var bytes: [UInt8] = []
            repeat {
                var byte = UInt8(value & 0x7F)
                value >>= 7
                if value != 0 { byte |= 0x80 }
                bytes.append(byte)
            } while value != 0
            return bytes
        }

        let seconds = UInt64(1_787_054_898)
        let nanos = UInt64(123_000_000)
        let timestampMessage = [UInt8(0x08)] + varint(seconds) + [UInt8(0x10)] + varint(nanos)
        let metadata = Data([0x0A, UInt8(timestampMessage.count)] + timestampMessage)
        let parsed = AntigravityStepTimestampReader.timestampForTest(from: metadata)

        XCTAssertEqual(parsed?.timeIntervalSince1970 ?? 0, 1_787_054_898.123, accuracy: 0.001)
        XCTAssertNil(AntigravityStepTimestampReader.timestampForTest(from: Data([0x08, 0x01])))
    }

    /// protobuf 边界回归：varint 一律不得越过自己的上界（外层信封 data.count /
    /// 子消息边界 end）。此前子消息末尾带续位的 varint 会吃掉后面的信封字节、
    /// 把 cursor 推过 end，`UInt64(end - cursor)`（负数）前置条件直接 trap，
    /// 进程不可恢复崩溃。断言一律返回 nil（测试能跑完即证明不再 trap）。
    func testStepTimestampReaderRejectsVarintCrossingSubmessageBoundary() {
        func varint(_ value: UInt64) -> [UInt8] {
            var value = value
            var bytes: [UInt8] = []
            repeat {
                var byte = UInt8(value & 0x7F)
                value >>= 7
                if value != 0 { byte |= 0x80 }
                bytes.append(byte)
            } while value != 0
            return bytes
        }

        // 已验证的 trap 样例（7 字节）：field1 len=2 → end=4；子消息里 12 是
        // field2 wireType=2，80 带续位让旧 readVarint 越界读到 data[4] 返回
        // 128，cursor=5 > end=4 → UInt64(-1) trap。
        XCTAssertNil(
            AntigravityStepTimestampReader.timestampForTest(
                from: Data([0x0A, 0x02, 0x12, 0x80, 0x01, 0xAA, 0xBB])
            ),
            "子消息末尾带续位的 length-delim varint 必须返回 nil 而不是 trap"
        )

        // 子消息末尾 varint 截断（续位无后继）：field1 wireType=0 的 0x80 带续位，
        // 子消息在 end 处结束。
        XCTAssertNil(
            AntigravityStepTimestampReader.timestampForTest(from: Data([0x0A, 0x03, 0x08, 0x80])),
            "子消息内截断的 varint 必须返回 nil"
        )

        // wireType 0 varint 跨越 end 边界：0x80 带续位，若无上界会吃掉子消息后
        // 的 0x2A（越界解析）。
        XCTAssertNil(
            AntigravityStepTimestampReader.timestampForTest(from: Data([0x0A, 0x03, 0x08, 0x80, 0x2A])),
            "varint 不得越过子消息边界继续读取"
        )

        // 边界正例：子消息里未知 length-delim 字段的 nestedLength 恰好等于剩余
        // 字节数 → 合法跳过，seconds 正常解析。
        let seconds = UInt64(1_787_054_898)
        let submessage = [UInt8(0x08)] + varint(seconds) + [UInt8(0x12), 0x02, 0xAA, 0xBB]
        let metadata = Data([0x0A, UInt8(submessage.count)] + submessage)
        let parsed = AntigravityStepTimestampReader.timestampForTest(from: metadata)
        XCTAssertEqual(parsed?.timeIntervalSince1970 ?? 0, 1_787_054_898, accuracy: 0.001)
    }

    func testStepTimestampReaderOpensOriginalPathReadOnlyAndTempCopyWritable() throws {
        // 直读原 .db 必须 READONLY（IDE 活动库，杜绝 WAL recovery/checkpoint
        // 写副作用）；SQLiteTempCopy 的 /tmp 副本保持 READWRITE（副本上可能
        // 需要完成 WAL recovery）。
        let original = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-step-timestamp-original-\(UUID().uuidString).db")
        XCTAssertTrue(
            AntigravityStepTimestampReader.opensReadOnly(dbPath: original),
            "原路径必须以只读连接打开"
        )

        let tempCopy = SQLiteTempCopy.appTempDir()
            .appendingPathComponent("\(UUID().uuidString).db")
        XCTAssertFalse(
            AntigravityStepTimestampReader.opensReadOnly(dbPath: tempCopy),
            "/tmp 副本路径必须保持可写以完成 WAL recovery"
        )
    }

    func testStepTimestampReaderReadsOnlyMatchingLLMSteps() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-step-timestamp-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                dbURL.path,
                &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                nil
            ),
            SQLITE_OK
        )
        guard let database else {
            XCTFail("failed to create SQLite fixture")
            return
        }
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, metadata BLOB);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        func varint(_ value: UInt64) -> [UInt8] {
            var value = value
            var bytes: [UInt8] = []
            repeat {
                var byte = UInt8(value & 0x7F)
                value >>= 7
                if value != 0 { byte |= 0x80 }
                bytes.append(byte)
            } while value != 0
            return bytes
        }

        let timestampMessage = [UInt8(0x08)] + varint(1_787_054_898)
        let metadata = Data([0x0A, UInt8(timestampMessage.count)] + timestampMessage)
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(database, "INSERT INTO steps VALUES (?, ?, ?);", -1, &statement, nil),
            SQLITE_OK
        )
        guard let statement else {
            XCTFail("failed to prepare SQLite fixture insert")
            return
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)
        metadata.withUnsafeBytes { bytes in
            sqlite3_bind_int64(statement, 1, 42)
            sqlite3_bind_int64(statement, 2, 15)
            sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(metadata.count), transient)
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)

        let timestamps = try AntigravityStepTimestampReader.timestamps(
            dbPath: dbURL,
            stepIndices: [42, 99]
        )
        XCTAssertEqual(timestamps.count, 1)
        XCTAssertEqual(timestamps[42]?.timeIntervalSince1970 ?? 0, 1_787_054_898, accuracy: 0.001)
        XCTAssertNil(timestamps[99])

        let event = AntigravityFetcher.UsageEvent(
            timestamp: nil,
            model: "gemini-3.7-flash",
            inputTokens: 100,
            outputTokens: 20,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            totalTokens: 120,
            stepIndices: [42]
        )
        let fileInfo = AntigravityDBFileInfo(
            url: dbURL,
            sizeBytes: 0,
            mtimeMs: 0,
            walSizeBytes: 0,
            walMtimeMs: 0,
            format: .sqlite
        )
        let recovered = AntigravityLocalUsageScanner.recoverMissingTimestamps(
            [event],
            fileInfo: fileInfo
        )
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(
            recovered[0].timestamp?.timeIntervalSince1970 ?? 0,
            1_787_054_898,
            accuracy: 0.001
        )
        XCTAssertEqual(recovered[0].inputTokens, 100)
    }

    func testEventCountCountsOnlyTimestampedEventsLikeDaily() {
        // 语义统一：eventCount = 成功进入日统计（有 timestamp）的 event 数。
        // 无 timestamp 的 event 不进 daily/turns/rounds/samples，也不得计入
        // eventCount，否则“事件数”与 Token 日汇总口径互相矛盾。
        let now = Date()
        let events = [
            makeEvent(timestamp: nil, input: 100, total: 100),
            makeEvent(timestamp: now, input: 5, total: 5),
            makeEvent(timestamp: now.addingTimeInterval(60), input: 7, total: 7),
            makeEvent(timestamp: nil, input: 200, total: 200),
        ]

        let stats = AntigravityLocalUsageScanner.accountedEventStats(events)
        XCTAssertEqual(stats.accounted, 2)
        XCTAssertEqual(stats.droppedTimestampless, 2)

        // 与 aggregateDaily 的一致性：daily 的 token 总量只来自 accounted 事件。
        let byDay = AntigravityLocalUsageScanner.aggregateDaily(events: events, calendar: testCalendar)
        let dailyInput = byDay.values.reduce(0) { $0 + $1.inputTokens }
        XCTAssertEqual(dailyInput, 12)
        XCTAssertEqual(stats.accounted, 2, "eventCount 与 daily 计入的事件数一致")

        // 全部有 timestamp：不丢弃。
        let allStamped = [
            makeEvent(timestamp: now, input: 1, total: 1),
            makeEvent(timestamp: now, input: 2, total: 2),
        ]
        let allStats = AntigravityLocalUsageScanner.accountedEventStats(allStamped)
        XCTAssertEqual(allStats.accounted, 2)
        XCTAssertEqual(allStats.droppedTimestampless, 0)
    }

    func testCacheInitializationRemovesLegacyPerSessionArtifacts() throws {
        // 清理基址必须是 rpc-cache 的真实历史位置（旧缓存根
        // `~/.gemini/antigravity/.token-monitor`，b24f6f9 根迁移只搬了
        // index.json、没有迁 rpc-cache），而不是从当前 provider `.json`
        // cacheDir 推导（那个位置从未存在过 rpc-cache，清理曾因此失效）。
        let fm = FileManager.default
        let cacheDir = fm.temporaryDirectory
            .appendingPathComponent("antigravity-cache-\(UUID().uuidString)", isDirectory: true)
        let legacyCacheRoot = fm.temporaryDirectory
            .appendingPathComponent("antigravity-legacy-root-\(UUID().uuidString)", isDirectory: true)
        let legacySessionDir = legacyCacheRoot
            .appendingPathComponent("rpc-cache/v1/legacy-session", isDirectory: true)
        try fm.createDirectory(at: legacySessionDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: cacheDir)
            try? fm.removeItem(at: legacyCacheRoot)
        }
        try Data("historical token detail".utf8).write(
            to: legacySessionDir.appendingPathComponent("usage.jsonl")
        )

        try AntigravityLocalUsageScanner.ensureCacheDirectoriesExist(
            cacheDir: cacheDir,
            fileManager: FileManagerBox(fm),
            legacyRPCCacheRoot: legacyCacheRoot
        )

        XCTAssertTrue(fm.fileExists(atPath: cacheDir.path), "当前 provider 缓存目录仍要确保存在")
        XCTAssertFalse(
            fm.fileExists(atPath: legacyCacheRoot.appendingPathComponent("rpc-cache").path),
            "升级后应清理生产从不读取的历史 per-session 明细"
        )
    }

    func testLegacyRPCCacheCleanupTargetResolvesToPreMigrationLegacyRoot() {
        // 生产默认清理基址必须指向根迁移前的旧缓存根；rpc-cache 挂在其下。
        let legacyRoot = TokenMonitorPaths.legacyAntigravityCacheDir
        XCTAssertEqual(
            legacyRoot.standardizedFileURL.path,
            NSHomeDirectory() + "/.gemini/antigravity/.token-monitor",
            "legacy 缓存根必须与 a65dec3 时期 scanner 写入 rpc-cache 的目录一致"
        )
        XCTAssertEqual(
            legacyRoot.appendingPathComponent("rpc-cache", isDirectory: true).standardizedFileURL.path,
            NSHomeDirectory() + "/.gemini/antigravity/.token-monitor/rpc-cache"
        )
        // 新根下的推导位置（旧实现的失效基址）不得再被使用。
        XCTAssertNotEqual(
            legacyRoot,
            TokenMonitorPaths.root,
            "legacy 根必须独立于集中式 token-monitor 新根"
        )
    }
}
