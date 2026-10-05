import XCTest
import Foundation
import SQLite3
@testable import LLM_monitor

/// `Services/Infra/SQLiteTempCopy.swift` 的直读 / 临时副本回退 / 指纹校验 /
/// 持久损坏记忆 / 专属临时目录与清理。
/// 拆自 `HTTPAndSQLiteTests`，逐字搬移零逻辑变化。
final class SQLiteTempCopyTests: XCTestCase {

    // MARK: - SQLiteTempCopy 清理语义

    /// `read` 把抛错的 action 透传给调用方；不管 action 成败，defer 都会清理 /tmp 副本。
    /// 这是基础保护层 —— 不管 action 内部因为什么原因抛错，临时文件都不会泄漏。
    ///
    /// 关于 ".db 成功 / -wal 失败" 这种半完成场景：要在测试里强制 -wal 复制失败
    /// 比较折腾（`fileExists` 默认跟随 symlink 让 dangling symlink 走不到 copy 分支；
    /// chmod 0 在 root / SIP 环境不生效；让 -wal 是目录会被当成目录递归复制）。
    /// 改在 `SQLiteTempCopy.swift` 的 defer 位置由代码评审保证：defer 注册在
    /// `copyToTemp` 任何文件创建之前，且覆盖 3 个 URL（db / wal / shm），抛错路径
    /// 必然进 defer 块清理。
    func testSQLiteTempCopyCleansUpAfterActionThrows() throws {
        let srcDB = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: srcDB) }

        // T2/R12: 只统计应用专属临时目录 $TMPDIR/llm-monitor-sqlite/ 的内容。
        let before = try currentAppTempEntries()

        do {
            _ = try SQLiteTempCopy.read(dbPath: srcDB, logTag: "[test]") { _ in
                throw NSError(domain: "test", code: 1)
            }
            XCTFail("expected error to propagate")
        } catch {
            // expected
        }

        let after = try currentAppTempEntries()
        XCTAssertTrue(after.isSubset(of: before),
                      "SQLiteTempCopy 在 action 抛错后未清理专属目录副本: \(after.subtracting(before))")
    }

    func testSQLiteTempCopyFallsBackOnPrepareFailedWithCantOpen() throws {
        let srcDB = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: srcDB) }

        var callCount = 0
        let result = try SQLiteTempCopy.read(dbPath: srcDB, logTag: "[test]") { url in
            callCount += 1
            if callCount == 1 {
                // 模拟直接读取时 prepare 阶段遇到 CANTOPEN 错误
                throw SQLiteConnectionError.prepareFailed(code: SQLITE_CANTOPEN, extendedCode: SQLITE_CANTOPEN, message: "unable to open database file", sql: "SELECT *")
            }
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600, "SQLite fallback 副本不能继承宽松权限")
            return "success"
        }

        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 2, "遇到 CANTOPEN prepare 错误时，应当重试/回退到临时副本（调用次数应为 2）")
    }

    func testSQLiteTempCopyFallsBackOnOpenFailedWithReadOnlyRecovery() throws {
        let srcDB = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: srcDB) }

        var callCount = 0
        let result = try SQLiteTempCopy.read(dbPath: srcDB, logTag: "[test]") { url in
            callCount += 1
            if callCount == 1 {
                // 模拟直读（SQLITE_OPEN_READONLY）遇到写入方崩溃遗留的 dirty
                // -shm/WAL：open 阶段抛 SQLITE_READONLY_RECOVERY(264)，
                // & 0xFF 后主码是 SQLITE_READONLY(8)，应触发副本回退
                // （副本以 READWRITE 打开，可在副本上完成 WAL recovery）。
                throw SQLiteConnectionError.openFailed(
                    path: srcDB.path,
                    code: SQLITE_READONLY,
                    extendedCode: SQLITE_READONLY | (1 << 8),
                    message: "attempt to write a readonly database"
                )
            }
            return "success"
        }

        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 2, "READONLY_RECOVERY(264) 应回退到临时副本（调用次数应为 2）")
    }

    func testSQLiteTempCopyUsesSourceWhenDirectReadSucceeds() throws {
        let srcDB = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: srcDB) }

        let before = try currentAppTempEntries()
        let result = try SQLiteTempCopy.read(dbPath: srcDB, logTag: "[test]") { url in
            XCTAssertEqual(url.path, srcDB.path)
            return "source"
        }
        let after = try currentAppTempEntries()

        XCTAssertEqual(result, "source")
        XCTAssertTrue(after.isSubset(of: before), "直读成功时不应创建临时副本")
    }

    func testCanOpenImmutableDecisionLogic() throws {
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("can-open-immutable-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let dbURL = baseDir.appendingPathComponent("test.db")
        let shmURL = baseDir.appendingPathComponent("test.db-shm")
        let walURL = baseDir.appendingPathComponent("test.db-wal")
        try Data("dummy-db".utf8).write(to: dbURL)

        // 1. readOnly=false 永远返回 false（副本写连接）
        XCTAssertFalse(SQLiteConnection.canOpenImmutable(path: dbURL, readOnly: false))

        // 2. readOnly=true, 无 -shm, 无 -wal -> true
        XCTAssertTrue(SQLiteConnection.canOpenImmutable(path: dbURL, readOnly: true))

        // 3. readOnly=true, 无 -shm, -wal 为 0 字节 -> true
        try Data().write(to: walURL)
        XCTAssertTrue(SQLiteConnection.canOpenImmutable(path: dbURL, readOnly: true))

        // 4. readOnly=true, 无 -shm, -wal 有未落盘数据 (>0 bytes) -> false
        try Data("dirty-wal-frame".utf8).write(to: walURL)
        XCTAssertFalse(SQLiteConnection.canOpenImmutable(path: dbURL, readOnly: true))

        // 5. readOnly=true, 有 -shm, 无论 -wal 如何 -> false
        try? FileManager.default.removeItem(at: walURL)
        try Data("shm-content".utf8).write(to: shmURL)
        XCTAssertFalse(SQLiteConnection.canOpenImmutable(path: dbURL, readOnly: true))

        // 6. readOnly=true, 有 -shm 且有非空 -wal -> false
        try Data("dirty-wal-frame".utf8).write(to: walURL)
        XCTAssertFalse(SQLiteConnection.canOpenImmutable(path: dbURL, readOnly: true))
    }

    func testSQLiteConnectionDirectReadOnCleanWALDatabaseWithoutShm() throws {
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clean-wal-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let dbURL = baseDir.appendingPathComponent("clean_wal.sqlite")

        // 建立 WAL 模式数据库并写入数据
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE items (id INT, name TEXT);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO items VALUES (1, 'item1'), (2, 'item2');", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)

        // 确保 -shm 和 -wal 被清理（模拟写端已完全退出且已 checkpoint）
        try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")
        try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")

        // 验证 SQLiteConnection(readOnly: true) 能直接以 immutable=1 打开并成功查询
        let conn = try SQLiteConnection(path: dbURL, readOnly: true)
        let rows = try conn.query(sql: "SELECT id, name FROM items ORDER BY id ASC") { stmt in
            let id = sqlite3_column_int(stmt, 0)
            let name = try SQLiteConnection.requiredText(stmt, column: 1)
            return (id, name)
        }
        conn.close()

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].0, 1)
        XCTAssertEqual(rows[0].1, "item1")
        XCTAssertEqual(rows[1].0, 2)
        XCTAssertEqual(rows[1].1, "item2")
    }

    func testSQLiteTempCopyDirectReadSucceedsWithoutCreatingTempFilesForCleanDB() throws {
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clean-wal-tempcopy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let dbURL = baseDir.appendingPathComponent("clean_wal.sqlite")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE t (cnt INT); INSERT INTO t VALUES (99);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)

        try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")
        try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")

        let before = try currentAppTempEntries()

        // 通过 SQLiteTempCopy.read 执行直读
        let value = try SQLiteTempCopy.read(dbPath: dbURL, logTag: "[test-clean-wal]") { url in
            XCTAssertEqual(url.path, dbURL.path, "直读应传入原始路径而非临时副本路径")
            let conn = try SQLiteConnection(path: url, readOnly: url.path == dbURL.path)
            defer { conn.close() }
            let rows = try conn.query(sql: "SELECT cnt FROM t") { stmt in
                sqlite3_column_int(stmt, 0)
            }
            return rows.first ?? 0
        }

        let after = try currentAppTempEntries()

        XCTAssertEqual(value, 99)
        XCTAssertTrue(after.isSubset(of: before), "clean WAL 直读成功时不应创建任何临时副本")
    }

    // MARK: - FIX6: immutable=1 打开后 -shm/-wal 竞态复检

    /// 复检函数直测：判据与 canOpenImmutable 对齐 —— -shm 存在或非空 -wal 命中；
    /// 残留 0 字节 -wal 无帧，不算命中（否则每次 immutable 直读都会被确定性
    /// 降级为 /tmp 全量拷贝）。
    func testImmutableSidecarRaceDetection() throws {
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("immutable-race-detect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let dbURL = baseDir.appendingPathComponent("test.db")
        let shmURL = baseDir.appendingPathComponent("test.db-shm")
        let walURL = baseDir.appendingPathComponent("test.db-wal")
        try Data("dummy-db".utf8).write(to: dbURL)

        // 1. 无 sidecar → 无竞态
        XCTAssertFalse(SQLiteConnection.immutableSidecarRaceDetected(path: dbURL))

        // 2. 残留 0 字节 -wal（写进程打开未写即退出）不命中：无帧，主库即完整一致快照
        try Data().write(to: walURL)
        XCTAssertFalse(SQLiteConnection.immutableSidecarRaceDetected(path: dbURL))

        // 3. 非空 -wal 命中（有待回放帧）
        try Data("frame".utf8).write(to: walURL)
        XCTAssertTrue(SQLiteConnection.immutableSidecarRaceDetected(path: dbURL))

        // 4. 仅 -shm 命中
        try? FileManager.default.removeItem(at: walURL)
        try Data("shm".utf8).write(to: shmURL)
        XCTAssertTrue(SQLiteConnection.immutableSidecarRaceDetected(path: dbURL))

        // 5. -shm 与 -wal 同时存在命中
        try Data("frame".utf8).write(to: walURL)
        XCTAssertTrue(SQLiteConnection.immutableSidecarRaceDetected(path: dbURL))
    }

    /// 连接行为：残留 0 字节 -wal（写进程打开未写即退出）时 immutable 直读应成功
    /// 打开并可查询，不误抛 lostImmutableRace；活写进程（-shm 存在）仍走标准只读
    /// 路径读实时数据；非 immutable 打开不受影响。
    func testSQLiteConnectionOpensImmutableWithResidualZeroByteWAL() throws {
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("immutable-race-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let dbURL = baseDir.appendingPathComponent("race.sqlite")
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")

        // 建立 WAL 模式库并写入数据，随后清理 sidecar（静止态）
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE t (cnt INT); INSERT INTO t VALUES (42);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")
        try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")

        // (a) 残留 0 字节 -wal：canOpenImmutable 决策放行（无帧，主库即完整一致
        //     快照），打开后的复检同判据放行 —— 连接应成功打开并完成查询，
        //     不得把每次直读确定性降级为 lostImmutableRace → /tmp 全量拷贝。
        try Data().write(to: walURL)
        XCTAssertTrue(SQLiteConnection.canOpenImmutable(path: dbURL, readOnly: true))
        XCTAssertFalse(SQLiteConnection.immutableSidecarRaceDetected(path: dbURL))
        do {
            let conn = try SQLiteConnection(path: dbURL, readOnly: true)
            let rows = try conn.query(sql: "SELECT cnt FROM t ORDER BY cnt") { stmt in
                sqlite3_column_int(stmt, 0)
            }
            conn.close()
            XCTAssertEqual(rows, [42], "immutable 直读应读到主库已 checkpoint 的数据")
        } catch {
            XCTFail("残留 0 字节 -wal 不应触发 lostImmutableRace，got \(error)")
        }

        // (b) 活写进程：-shm 存在时 canOpenImmutable 本来就返回 false、走标准只读
        //     打开（读实时 WAL），复检不适用——验证新逻辑不会误伤这条正常路径。
        try? FileManager.default.removeItem(at: walURL)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &writer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; INSERT INTO t VALUES (43);", nil, nil, nil), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: shmURL.path), "活写进程应持有 -shm")
        XCTAssertFalse(SQLiteConnection.canOpenImmutable(path: dbURL, readOnly: true), "有 -shm 时决策应走标准只读路径")
        let liveConn = try SQLiteConnection(path: dbURL, readOnly: true)
        let liveRows = try liveConn.query(sql: "SELECT cnt FROM t ORDER BY cnt") { stmt in
            sqlite3_column_int(stmt, 0)
        }
        liveConn.close()
        XCTAssertEqual(liveRows, [42, 43], "活写进程场景应经标准只读路径读到实时数据")

        // (c) 非 immutable 打开（副本写连接 / 有 sidecar 的标准只读打开）不受复检影响
        let conn = try SQLiteConnection(path: dbURL, readOnly: false)
        conn.close()
    }

    /// lostImmutableRace 从 action 直接抛出时，read 应路由进 withTempCopy 回退，
    /// 而不是当扫描失败上抛。
    func testSQLiteTempCopyFallsBackOnLostImmutableRace() throws {
        let srcDB = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: srcDB) }

        var callCount = 0
        let result = try SQLiteTempCopy.read(dbPath: srcDB, logTag: "[test]") { url in
            callCount += 1
            if callCount == 1 {
                throw SQLiteConnectionError.lostImmutableRace(path: srcDB.path)
            }
            return "success"
        }

        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 2, "lostImmutableRace 应路由进 /tmp 副本回退（调用次数应为 2）")
    }

    /// 端到端：源库残留 0 字节 -wal（写进程打开未写即退出 / 崩溃残留）→ 直连
    /// immutable 打开应一次成功，不误判竞态回退 /tmp 全量副本（大库每轮扫描
    /// 白拷 GB 级数据）。lostImmutableRace → /tmp 副本的回退路由由
    /// testSQLiteTempCopyFallsBackOnLostImmutableRace 注入式覆盖。
    func testSQLiteTempCopyDirectReadSucceedsWithResidualZeroByteWAL() throws {
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("immutable-race-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let dbURL = baseDir.appendingPathComponent("race_e2e.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE t (cnt INT); INSERT INTO t VALUES (99);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")
        try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")
        // 写进程崩溃残留：0 字节 -wal，无 -shm
        try Data().write(to: URL(fileURLWithPath: dbURL.path + "-wal"))

        let before = try currentAppTempEntries()
        var visitedPaths: [String] = []
        let value = try SQLiteTempCopy.read(dbPath: dbURL, logTag: "[test-fix6]") { url in
            visitedPaths.append(url.path)
            let conn = try SQLiteConnection(path: url, readOnly: url.path == dbURL.path)
            defer { conn.close() }
            let rows = try conn.query(sql: "SELECT cnt FROM t") { stmt in
                sqlite3_column_int(stmt, 0)
            }
            return rows.first ?? -1
        }
        let after = try currentAppTempEntries()

        XCTAssertEqual(value, 99)
        XCTAssertEqual(visitedPaths.count, 1, "残留 0 字节 -wal 不应触发 /tmp 副本回退，应一次直读完成")
        XCTAssertEqual(visitedPaths[0], dbURL.path, "应直接在源库上完成读取")
        XCTAssertTrue(after.isSubset(of: before), "直读成功时不应创建任何临时副本")
    }

    /// SQLITE_CORRUPT（主码 11）命中回退白名单：并发 checkpoint 撕裂页可能在
    /// 直读时表现为 CORRUPT，重拷一份一致快照可能自愈。
    func testSQLiteTempCopyFallsBackOnCorrupt() throws {
        let srcDB = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: srcDB) }

        var callCount = 0
        let result = try SQLiteTempCopy.read(dbPath: srcDB, logTag: "[test]") { url in
            callCount += 1
            if callCount == 1 {
                throw SQLiteConnectionError.stepFailed(
                    code: SQLITE_CORRUPT,
                    extendedCode: SQLITE_CORRUPT,
                    message: "database disk image is malformed"
                )
            }
            return "success"
        }

        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 2, "CORRUPT 应命中回退白名单（调用次数应为 2）")
    }

    // MARK: - L2: 持久损坏源库记忆

    /// 直读 CORRUPT → /tmp 副本上的读取同样 CORRUPT：判定持久损坏并记忆；
    /// 下一轮直读 CORRUPT 时跳过拷贝快速失败（不再每轮白付一次全量拷贝）。
    func testPersistentCorruptDBSkipsTempCopyAfterCopyAlsoCorrupt() throws {
        let srcDB = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: srcDB) }

        let corrupt = SQLiteConnectionError.stepFailed(
            code: SQLITE_CORRUPT,
            extendedCode: SQLITE_CORRUPT,
            message: "database disk image is malformed"
        )
        var callCount = 0
        let corruptingAction: (URL) throws -> String = { _ in
            callCount += 1
            throw corrupt
        }

        // 第一轮：源库直读 CORRUPT → 回退拷贝 → 副本读取同样 CORRUPT → 记忆 + 上抛
        XCTAssertThrowsError(
            try SQLiteTempCopy.read(dbPath: srcDB, logTag: "[test-l2]", corruptingAction)
        ) { error in
            XCTAssertTrue(error is SQLiteConnectionError, "应上抛原 CORRUPT 错误: \(error)")
        }
        XCTAssertEqual(callCount, 2, "第一轮：源库直读 + 副本读取各一次")

        // 第二轮：持久损坏记忆命中（源指纹未变）→ 跳过 /tmp 拷贝，只有直读一次
        XCTAssertThrowsError(
            try SQLiteTempCopy.read(dbPath: srcDB, logTag: "[test-l2]", corruptingAction)
        )
        XCTAssertEqual(callCount, 3, "记忆命中后不应再做 /tmp 全量拷贝")
    }

    /// 源文件变化（mtime/size 指纹变化）后记忆失效：恢复正常「直读 + 拷贝」回退。
    func testPersistentCorruptionMemoryInvalidatedWhenSourceChanges() throws {
        let srcDB = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: srcDB) }

        let corrupt = SQLiteConnectionError.stepFailed(
            code: SQLITE_CORRUPT,
            extendedCode: SQLITE_CORRUPT,
            message: "database disk image is malformed"
        )
        var callCount = 0
        let corruptingAction: (URL) throws -> String = { _ in
            callCount += 1
            throw corrupt
        }

        XCTAssertThrowsError(
            try SQLiteTempCopy.read(dbPath: srcDB, logTag: "[test-l2]", corruptingAction)
        )
        XCTAssertEqual(callCount, 2)

        // 改写源文件（mtime 变化）→ 记忆失效 → 第二轮恢复拷贝回退（直读 + 副本）
        try Data([0x09, 0x09]).write(to: srcDB)
        XCTAssertThrowsError(
            try SQLiteTempCopy.read(dbPath: srcDB, logTag: "[test-l2]", corruptingAction)
        )
        XCTAssertEqual(callCount, 4, "源文件变化后记忆失效，应恢复 /tmp 拷贝回退")
    }

    // MARK: - FIX12: withTempCopy 逐文件指纹校验与失败清理

    /// 源指纹持续变化：每轮都在「db 拷完立即复验」处被放弃——wal/shm 永远不被
    /// 拷贝，3 轮耗尽后抛 sourceChangedDuringSnapshot，且临时副本被 defer 清理。
    func testWithTempCopyAbandonsRoundAfterStaleDBCopyAndCleansUp() throws {
        let srcDB = try makeTempDBWithSidecars()
        defer {
            try? FileManager.default.removeItem(at: srcDB)
            try? FileManager.default.removeItem(atPath: srcDB.path + "-wal")
            try? FileManager.default.removeItem(atPath: srcDB.path + "-shm")
        }

        let spy = FingerprintSpy()
        SQLiteTempCopy.sourceFingerprintOverride = { _, _ in try spy.next() }
        defer { SQLiteTempCopy.sourceFingerprintOverride = nil }

        let before = try currentAppTempEntries()
        do {
            _ = try SQLiteTempCopy.read(dbPath: srcDB, logTag: "[test-fix12]") { url in
                if url.path == srcDB.path {
                    // 按既有测试模式注入 CANTOPEN，触发 withTempCopy 回退
                    throw SQLiteConnectionError.prepareFailed(
                        code: SQLITE_CANTOPEN, extendedCode: SQLITE_CANTOPEN,
                        message: "unable to open database file", sql: "SELECT 1"
                    )
                }
                XCTFail("指纹持续变化时 3 轮拷贝应全部失败，不应进入 action")
                return "unreachable"
            }
            XCTFail("expected sourceChangedDuringSnapshot")
        } catch {
            let desc = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(
                desc.hasPrefix("SQLite source changed while copying snapshot"),
                "expected sourceChangedDuringSnapshot, got \(desc)"
            )
        }
        let after = try currentAppTempEntries()

        XCTAssertTrue(after.isSubset(of: before), "3 轮耗尽抛错前必须清理本轮临时副本: \(after.subtracting(before))")
        XCTAssertFalse(spy.sawTempSidecar, "逐文件提前放弃生效：任何一轮都不应拷贝 wal/shm 副本")
        XCTAssertEqual(spy.calls, 6, "3 轮 × [before 采样 + db 拷后复验] = 6 次；无逐文件复验时每轮会有第 3 次 after 采样")
    }

    /// 瞬时变化后稳定：第 1 轮在 db 复验处放弃，第 2 轮完整拷贝成功并进入 action。
    func testWithTempCopyRetriesAndSucceedsWhenSourceStabilizes() throws {
        let srcDB = try makeTempDBWithSidecars()
        defer {
            try? FileManager.default.removeItem(at: srcDB)
            try? FileManager.default.removeItem(atPath: srcDB.path + "-wal")
            try? FileManager.default.removeItem(atPath: srcDB.path + "-shm")
        }

        // 采样序列：#1 → f1；#2（db 拷后复验）→ f2 ≠ f1，放弃第 1 轮；
        // #3 → f2（before）；#4 → f2（复验通过）；#5 → f2（after == before）→ 成功。
        let counter = CounterBox()
        SQLiteTempCopy.sourceFingerprintOverride = { _, _ in
            counter.calls += 1
            let mtime = counter.calls == 1 ? 1.0 : 2.0
            return SQLiteTempCopy.SourceFingerprint(
                db: .init(exists: true, size: 1, modificationTime: mtime),
                wal: .init(exists: true, size: 1, modificationTime: mtime),
                shm: .init(exists: true, size: 1, modificationTime: mtime)
            )
        }
        defer { SQLiteTempCopy.sourceFingerprintOverride = nil }

        let before = try currentAppTempEntries()
        var actionCalls = 0
        let result = try SQLiteTempCopy.read(dbPath: srcDB, logTag: "[test-fix12]") { url in
            if url.path == srcDB.path {
                throw SQLiteConnectionError.prepareFailed(
                    code: SQLITE_CANTOPEN, extendedCode: SQLITE_CANTOPEN,
                    message: "unable to open database file", sql: "SELECT 1"
                )
            }
            actionCalls += 1
            return "snapshot"
        }
        let after = try currentAppTempEntries()

        XCTAssertEqual(result, "snapshot", "瞬时变化后稳定的源应在第 2 轮拷贝成功")
        XCTAssertEqual(actionCalls, 1, "action 应恰好在临时副本上执行一次")
        XCTAssertEqual(counter.calls, 5, "第 1 轮放弃（2 次采样）+ 第 2 轮完整（before/复验/after = 3 次采样）")
        XCTAssertTrue(after.isSubset(of: before), "成功路径应清理临时副本")
    }

    private func makeTempDB() throws -> URL {
        let srcDB = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sqlite-temp-copy-test-\(UUID().uuidString).db")
        try Data([0x00, 0x01]).write(to: srcDB)
        return srcDB
    }

    /// 带 -wal / -shm sidecar 的源库：配合 sourceFingerprintOverride 验证
    /// 「db 复验失败时 wal/shm 不被拷贝」需要 sidecar 真实存在。
    private func makeTempDBWithSidecars() throws -> URL {
        let srcDB = try makeTempDB()
        try Data("wal".utf8).write(to: URL(fileURLWithPath: srcDB.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: srcDB.path + "-shm"))
        return srcDB
    }

    /// FIX12 测试间谍：每次指纹采样都返回不同值（= 源永远在变），并记录采样时
    /// 专属临时目录是否出现过 .db-wal/.db-shm 副本——若实现未做逐文件提前放弃，
    /// wal/shm 拷贝会发生在下一轮采样（after）之前而被观察到。
    private final class FingerprintSpy {
        private(set) var calls = 0
        private(set) var sawTempSidecar = false

        func next() throws -> SQLiteTempCopy.SourceFingerprint {
            calls += 1
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: SQLiteTempCopy.appTempDir().path)) ?? []
            if entries.contains(where: { $0.hasSuffix(".db-wal") || $0.hasSuffix(".db-shm") }) {
                sawTempSidecar = true
            }
            let mtime = Double(calls)
            return SQLiteTempCopy.SourceFingerprint(
                db: .init(exists: true, size: 1, modificationTime: mtime),
                wal: .init(exists: true, size: 1, modificationTime: mtime),
                shm: .init(exists: true, size: 1, modificationTime: mtime)
            )
        }
    }

    private final class CounterBox {
        var calls = 0
    }

    // MARK: - R12: 专属临时目录与清理

    /// 正常路径闭包退出即删；副本只出现在专属目录内。
    func testR12TempCopyLivesInAppDirAndCleansUp() throws {
        let srcDB = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: srcDB) }
        let before = try currentAppTempEntries()
        _ = try SQLiteTempCopy.read(dbPath: srcDB, logTag: "[test]") { _ in "ok" }
        let after = try currentAppTempEntries()
        XCTAssertTrue(after.isSubset(of: before), "成功路径应清理副本: \(after.subtracting(before))")
    }

    /// sweep 只清理超过 24h 的残留；23h 文件与专属目录外文件不受影响。
    func testR12SweepStaleCopiesRespectsAgeAndScope() throws {
        let fm = FileManager.default
        let dir = SQLiteTempCopy.appTempDir()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])

        let old = dir.appendingPathComponent("old-\(UUID().uuidString).db")
        let fresh = dir.appendingPathComponent("fresh-\(UUID().uuidString).db")
        try Data("old".utf8).write(to: old)
        try Data("fresh".utf8).write(to: fresh)
        // 把 old 的 mtime 调到 25 小时前，fresh 调到 23 小时前。
        let now = Date()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-25 * 3600)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-23 * 3600)], ofItemAtPath: fresh.path)
        defer {
            try? fm.removeItem(at: old)
            try? fm.removeItem(at: fresh)
        }

        // 专属目录外放一个无关 .db，sweep 不应动它。
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("r12-outside-\(UUID().uuidString).db")
        try Data("x".utf8).write(to: outside)
        defer { try? fm.removeItem(at: outside) }

        SQLiteTempCopy.sweepStaleCopies(now: now, maxAge: 24 * 3600)

        XCTAssertFalse(fm.fileExists(atPath: old.path), "25h 残留应被清理")
        XCTAssertTrue(fm.fileExists(atPath: fresh.path), "23h 文件不应被清理")
        XCTAssertTrue(fm.fileExists(atPath: outside.path), "专属目录外文件不受影响")
    }

    /// DSH 解压临时产物与 SQLite 副本同根：启动 sweep 无条件回收
    /// `llm-monitor-dsh-` 前缀的残留（单个最大 1GiB，且启动时不可能有正在使用
    /// 的解压产物），而同目录下非前缀的未过期文件仍按 24h 年龄策略保留。
    func testR12SweepRemovesDshLeftoversRegardlessOfAge() throws {
        let fm = FileManager.default
        let dir = SQLiteTempCopy.appTempDir()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])

        let leftover = dir.appendingPathComponent("\(SQLiteTempCopy.dshTempPrefix)\(UUID().uuidString)")
        let unrelated = dir.appendingPathComponent("r12-unrelated-\(UUID().uuidString)")
        try Data("decompressed".utf8).write(to: leftover)
        try Data("x".utf8).write(to: unrelated)
        defer {
            try? fm.removeItem(at: leftover)
            try? fm.removeItem(at: unrelated)
        }

        // 刚写入（mtime = now，远未到 24h）
        SQLiteTempCopy.sweepStaleCopies(now: Date(), maxAge: 24 * 3600)

        XCTAssertFalse(fm.fileExists(atPath: leftover.path), "解压残留应无条件被启动 sweep 回收")
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path), "无关的未过期文件不应被清理")
    }

    /// 解码器临时文件（DSH 解压产物）的落点：App 自有临时根内部，目录 0700。
    func testR12DecoderTempURLLivesInAppOwnedTempRoot() throws {
        let tempURL = try FileManagerBox().temporaryURL()
        let appTemp = SQLiteTempCopy.appTempDir().standardizedFileURL.path
        XCTAssertEqual(
            tempURL.deletingLastPathComponent().standardizedFileURL.path,
            appTemp,
            "解码临时文件必须落在 App 自有临时根内，否则启动 sweep 覆盖不到"
        )
        let permissions = try FileManager.default.attributesOfItem(atPath: appTemp)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o700, "App 自有临时根权限应为 0700")
    }

    /// T2/R12: 快照应用专属临时目录 `$TMPDIR/llm-monitor-sqlite/` 的内容。
    private func currentAppTempEntries() throws -> Set<String> {
        let dir = SQLiteTempCopy.appTempDir().path
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return Set(contents)
    }

    /// SQLiteTempCopy 的临时副本命名为 `<UUID>.db` / `<UUID>.db-wal` / `<UUID>.db-shm`。
    /// 只把 UUID 词干的三件套算作“本次可能产生的副本”，避免把无关 .db 误判为泄漏。
    private static func isSQLiteTempCopyName(_ name: String) -> Bool {
        let stems = [".db", ".db-wal", ".db-shm"]
        guard stems.contains(where: { name.hasSuffix($0) }) else { return false }
        let uuidRegex = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.db(-wal|-shm)?$"#
        return name.range(of: uuidRegex, options: .regularExpression) != nil
    }
}
