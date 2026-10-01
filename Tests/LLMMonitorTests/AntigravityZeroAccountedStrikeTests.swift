import XCTest
import SQLite3
@testable import LLM_monitor

/// 零可计账全量页的有界打击收敛：三次打击后强制成功、增量页打击、session 移除与
/// 空增量 / RPC 失败时打击计数的保留或清零。
final class AntigravityZeroAccountedStrikeTests: AntigravityConvergenceTestCase {

    // MARK: - 测试

    /// 补强：持续零可计账的 full 页（解析损坏/天然全零 token）必须有界收敛，
    /// 否则 failedCount 永不归零 → 签名永不推进 → 每轮 reconcile 全量冷重建。
    /// 第 1/2 轮计失败并保留 last-good；第 3 轮收敛：写入当前文件指纹、
    /// offset 刻意保留（5）、daily/samples 保留、补写空 samples、不计失败、
    /// 签名照常推进、不打旧日历标记（非日历变更轮）。此后指纹不变不再产生
    /// plan；文件重新变化 → 重新 dirty 并从保留 offset=5 增量重取。
    /// 用"缺 samples 缓存"分支触发 full plan（cachedOffset=5 > 0 且无日历
    /// 变更时的唯一 full plan 入口），以隔离修复 2 的标记机制。
    func testZeroAccountedFullPageConvergesAfterThreeStrikes() async throws {
        let fixture = try makeConvergenceFixture(cachedOffset: 5, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // 移除 samples 缓存 → 每轮都走 full plan（offset=0），即使指纹未变。
        var seeded = try loadConvergenceIndex(fixture)
        seeded.samplesBySession?[fixture.sessionID] = nil
        try AntigravityLocalUsageScanner.saveIndex(
            seeded, cacheDir: fixture.cache, fileManager: FileManagerBox(fixture.fm)
        )

        let stub = MetadataStub { _, _ in
            (events: [], metadataEntryCount: 7)
        }
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        // 第 1、2 轮：计失败、last-good 保留、指纹/offset 不动。
        let scan1 = try await runConvergenceScan(fixture: fixture, now: base, stub: stub)
        XCTAssertEqual(scan1.failedSessionCount, 1)
        var index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(index.zeroAccountedFullStrikesBySession?[fixture.sessionID], 1)
        XCTAssertEqual(index.sessions[fixture.sessionID]?.generatorMetadataOffset, 5)
        XCTAssertEqual(index.sessions[fixture.sessionID]?.mtimeMs, fixture.liveMtimeMs - 60_000)
        XCTAssertEqual(index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 500)
        XCTAssertNil(index.samplesBySession?[fixture.sessionID])

        _ = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(60), stub: stub)
        index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(index.zeroAccountedFullStrikesBySession?[fixture.sessionID], 2)
        XCTAssertEqual(index.sessions[fixture.sessionID]?.generatorMetadataOffset, 5)

        // 第 3 轮：收敛——不计失败、指纹写入、offset 刻意保留、last-good 全保留。
        let scan3 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(120), stub: stub)
        XCTAssertEqual(scan3.failedSessionCount, 0, "收敛不计失败")
        index = try loadConvergenceIndex(fixture)
        XCTAssertNil(index.zeroAccountedFullStrikesBySession, "收敛后打击计数清零")
        let converged = try XCTUnwrap(index.sessions[fixture.sessionID])
        XCTAssertEqual(converged.mtimeMs, fixture.liveMtimeMs, "收敛采用当前文件指纹")
        XCTAssertEqual(converged.generatorMetadataOffset, 5, "offset 刻意不推进，供恢复时重取")
        XCTAssertEqual(converged.eventCount, 5)
        XCTAssertEqual(index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 500)
        XCTAssertEqual(index.samplesBySession?[fixture.sessionID]?.count, 0, "补写空 samples，避免反复触发缺缓存 full 重扫")
        XCTAssertNil(
            index.calendarRebuildPendingSessions,
            "非日历变更轮收敛不打旧日历标记"
        )
        XCTAssertEqual(
            index.calendarSignature, LocalUsageCalendarSignature.make(testCalendar),
            "收敛后签名照常推进"
        )

        // 第 4 轮：指纹未变 → 不再产生该 session 的 plan（有界收敛生效）。
        let callsAfterConverge = stub.callCount
        let scan4 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(180), stub: stub)
        XCTAssertEqual(stub.callCount, callsAfterConverge)
        XCTAssertEqual(scan4.failedSessionCount, 0)

        // 第 5 轮：文件重新变化 → 重新 dirty，从保留 offset=5 增量重取（而非
        // 再吃 full），解析恢复后正常入账。
        try Data(repeating: 2, count: 256).write(to: fixture.dbPath)
        let recoveredEvents = [makeEvent(timestamp: fixture.dayStart.addingTimeInterval(3_600), input: 42, total: 42)]
        await stub.setHandler { _, _ in
            (events: recoveredEvents, metadataEntryCount: 2)
        }
        let scan5 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(240), stub: stub)
        XCTAssertEqual(scan5.failedSessionCount, 0)
        XCTAssertEqual(stub.lastOffset, 5, "恢复路径必须是保留 offset 的增量重取")
        index = try loadConvergenceIndex(fixture)
        let recovered = try XCTUnwrap(index.sessions[fixture.sessionID])
        XCTAssertEqual(recovered.generatorMetadataOffset, 7, "5 + 2，增量消费恢复")
        XCTAssertEqual(recovered.eventCount, 6, "5 + 1，合并式入账")
        XCTAssertEqual(
            index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 542,
            "500 + 42，last-good 与新事件合并"
        )
        XCTAssertEqual(index.samplesBySession?[fixture.sessionID]?.count, 1)
    }

    /// 增量页同款防线：生产活跃 session 有缓存（offset>0、samples 完整）后永远
    /// 走增量 plan——"raw 非零但零可计账 event"的增量页不得按 raw 条数无条件
    /// 推进 offset（否则解析损坏期间这批 token 被永久吞掉）。与全量页统一走
    /// 有界打击收敛：第 1/2 轮计失败、offset/指纹/last-good 不动；第 3 轮收敛
    /// （采用当前指纹、offset 保留、不计失败、签名照常推进）；此后指纹不变不再
    /// 发 RPC；文件再变化 → 从保留 offset 增量重取，解析恢复后正常入账、打击
    /// 计数保持清空。
    func testZeroAccountedIncrementalPageConvergesAfterThreeStrikes() async throws {
        // samples 缓存保持存在（夹具默认）+ cachedOffset=5 > 0 → 走增量 plan。
        let fixture = try makeConvergenceFixture(cachedOffset: 5, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stub = MetadataStub { _, _ in
            (events: [], metadataEntryCount: 7)
        }
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        // 第 1、2 轮：计失败、保留 last-good（offset=5、旧指纹、daily=500）。
        let scan1 = try await runConvergenceScan(fixture: fixture, now: base, stub: stub)
        XCTAssertEqual(scan1.failedSessionCount, 1)
        XCTAssertEqual(stub.lastOffset, 5, "活跃 session（samples 缓存完整）必须走增量 plan")
        var index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(index.zeroAccountedFullStrikesBySession?[fixture.sessionID], 1)
        XCTAssertEqual(index.sessions[fixture.sessionID]?.generatorMetadataOffset, 5, "零可计账增量页不得推进 offset")
        XCTAssertEqual(index.sessions[fixture.sessionID]?.mtimeMs, fixture.liveMtimeMs - 60_000, "打击期内不得采用当前文件指纹")
        XCTAssertEqual(index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 500)
        XCTAssertEqual(index.samplesBySession?[fixture.sessionID]?.count, 0)

        _ = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(60), stub: stub)
        index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(index.zeroAccountedFullStrikesBySession?[fixture.sessionID], 2)
        XCTAssertEqual(index.sessions[fixture.sessionID]?.generatorMetadataOffset, 5)

        // 第 3 轮：收敛——不计失败、打击清零、采用当前指纹、offset 刻意保留。
        let scan3 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(120), stub: stub)
        XCTAssertEqual(scan3.failedSessionCount, 0, "收敛不计失败")
        index = try loadConvergenceIndex(fixture)
        XCTAssertNil(index.zeroAccountedFullStrikesBySession, "收敛后打击计数清零")
        let converged = try XCTUnwrap(index.sessions[fixture.sessionID])
        XCTAssertEqual(converged.mtimeMs, fixture.liveMtimeMs, "收敛采用当前文件指纹")
        XCTAssertEqual(converged.generatorMetadataOffset, 5, "offset 刻意不推进，供恢复时重取")
        XCTAssertEqual(converged.eventCount, 5)
        XCTAssertEqual(index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 500)
        XCTAssertEqual(index.samplesBySession?[fixture.sessionID]?.count, 0)
        XCTAssertNil(
            index.calendarRebuildPendingSessions,
            "非日历变更轮收敛不打旧日历标记"
        )
        XCTAssertEqual(
            index.calendarSignature, LocalUsageCalendarSignature.make(testCalendar),
            "收敛后签名照常推进"
        )

        // 第 4 轮：指纹未变 → 不再产生该 session 的 plan（有界收敛生效）。
        let callsAfterConverge = stub.callCount
        let scan4 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(180), stub: stub)
        XCTAssertEqual(stub.callCount, callsAfterConverge)
        XCTAssertEqual(scan4.failedSessionCount, 0)

        // 第 5 轮：文件再变化 → 从保留 offset=5 增量重取；解析恢复后正常增量
        // 入账，打击计数保持清空。
        try Data(repeating: 2, count: 256).write(to: fixture.dbPath)
        let recoveredEvents = [makeEvent(timestamp: fixture.dayStart.addingTimeInterval(3_600), input: 42, total: 42)]
        await stub.setHandler { _, _ in
            (events: recoveredEvents, metadataEntryCount: 2)
        }
        let scan5 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(240), stub: stub)
        XCTAssertEqual(scan5.failedSessionCount, 0)
        XCTAssertEqual(stub.lastOffset, 5, "恢复路径必须是保留 offset 的增量重取")
        index = try loadConvergenceIndex(fixture)
        let recovered = try XCTUnwrap(index.sessions[fixture.sessionID])
        XCTAssertEqual(recovered.generatorMetadataOffset, 7, "5 + 2，增量消费恢复")
        XCTAssertEqual(recovered.eventCount, 6, "5 + 1，合并式入账")
        XCTAssertEqual(
            index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 542,
            "500 + 42，增量合并入账"
        )
        XCTAssertNil(index.zeroAccountedFullStrikesBySession, "成功入账后打击计数保持清空")
        XCTAssertEqual(index.samplesBySession?[fixture.sessionID]?.count, 1)
    }

    /// 补强：打击观察期内任一轮 full 页恢复可入账 event → 计数清零并正常
    /// 全量重算（与零 metadata 机制的清零路径对称）。
    func testZeroAccountedStrikesClearWhenFullPageSucceeds() async throws {
        let fixture = try makeConvergenceFixture(cachedOffset: 0, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stub = MetadataStub { _, _ in
            (events: [], metadataEntryCount: 7)
        }
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        let scan1 = try await runConvergenceScan(fixture: fixture, now: base, stub: stub)
        XCTAssertEqual(scan1.failedSessionCount, 1)
        var index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(index.zeroAccountedFullStrikesBySession?[fixture.sessionID], 1)

        // 第 2 轮解析恢复：全量拿到可入账 event。
        let fullEvents = [makeEvent(timestamp: fixture.dayStart.addingTimeInterval(3_600), input: 7, total: 7)]
        await stub.setHandler { _, _ in
            (events: fullEvents, metadataEntryCount: 6)
        }
        let scan2 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(60), stub: stub)
        XCTAssertEqual(scan2.failedSessionCount, 0)
        index = try loadConvergenceIndex(fixture)
        XCTAssertNil(index.zeroAccountedFullStrikesBySession, "full 页成功入账必须清零打击计数")
        XCTAssertEqual(index.sessions[fixture.sessionID]?.generatorMetadataOffset, 6)
        XCTAssertEqual(index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 7)
    }

    /// 补强：session 被确认删除时，零可计账打击计数一并清除（镜像
    /// emptyFullStrikesBySession 的清理），不留悬挂状态。
    func testSessionRemovalClearsZeroAccountedStrikes() async throws {
        let fixture = try makeConvergenceFixture(cachedOffset: 0, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var index = try loadConvergenceIndex(fixture)
        index.zeroAccountedFullStrikesBySession = [fixture.sessionID: 2]
        try AntigravityLocalUsageScanner.saveIndex(
            index, cacheDir: fixture.cache, fileManager: FileManagerBox(fixture.fm)
        )

        try FileManager.default.removeItem(at: fixture.dbPath)
        let stub = MetadataStub { _, _ in
            (events: [], metadataEntryCount: 0)
        }
        let scan = try await runConvergenceScan(
            fixture: fixture,
            now: Date(timeIntervalSince1970: 1_790_000_000),
            stub: stub
        )
        XCTAssertEqual(scan.failedSessionCount, 0)
        index = try loadConvergenceIndex(fixture)
        XCTAssertNil(index.sessions[fixture.sessionID], "session 被确认删除")
        XCTAssertNil(index.dailyBySession[fixture.sessionID])
        XCTAssertNil(index.zeroAccountedFullStrikesBySession, "删除 session 时打击计数一并清除")
    }

    /// 零 metadata 全量页是"确定不是零可计账页"的页结果（raw 总数为 0，无从
    /// 谈起解析失败）：到达即清零零可计账打击计数。否则旧计数残留进
    /// index.json，下次零可计账事件从 3 起算、1 轮即收敛，丢失 3 轮观察期。
    func testZeroMetadataFullPageClearsZeroAccountedStrikes() async throws {
        let fixture = try makeConvergenceFixture(cachedOffset: 5, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // 移除 samples 缓存 → 走 full plan（cachedOffset=5 > 0 且无日历变更时
        // 的唯一 full plan 入口）；预置 2 轮零可计账打击（此前扫描残留）。
        var seeded = try loadConvergenceIndex(fixture)
        seeded.samplesBySession?[fixture.sessionID] = nil
        seeded.zeroAccountedFullStrikesBySession = [fixture.sessionID: 2]
        try AntigravityLocalUsageScanner.saveIndex(
            seeded, cacheDir: fixture.cache, fileManager: FileManagerBox(fixture.fm)
        )

        let stub = MetadataStub { _, _ in
            (events: [], metadataEntryCount: 0)
        }
        let scan = try await runConvergenceScan(
            fixture: fixture,
            now: Date(timeIntervalSince1970: 1_790_000_000),
            stub: stub
        )
        XCTAssertEqual(scan.failedSessionCount, 1, "零 metadata 打击轮照常计失败")
        let index = try loadConvergenceIndex(fixture)
        XCTAssertNil(index.zeroAccountedFullStrikesBySession, "零 metadata 页必须清零零可计账打击计数")
        XCTAssertEqual(index.emptyFullStrikesBySession?[fixture.sessionID], 1, "零 metadata 计数照常累计")
        XCTAssertNil(index.offsetRegressionStrikesBySession, "count=0 页由零 metadata 机制处理，不进回归计数")
        XCTAssertEqual(index.sessions[fixture.sessionID]?.generatorMetadataOffset, 5, "last-good offset 保留")
        XCTAssertEqual(
            index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 500,
            "last-good daily 保留"
        )
    }

    /// 核验收敛页（raw 总数与缓存一致、events 已在缓存入账）同样不是零可计账
    /// 页证据，到达即清零。
    func testVerificationConvergenceClearsZeroAccountedStrikes() async throws {
        let fixture = try makeConvergenceFixture(cachedOffset: 5, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stub = MetadataStub { _, offset in
            (events: [], metadataEntryCount: offset == 5 ? 0 : 5)
        }
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        // 前两轮空 suffix → 升级核验。
        _ = try await runConvergenceScan(fixture: fixture, now: base, stub: stub)
        _ = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(60), stub: stub)

        // 核验前预置 2 轮零可计账打击（此前扫描残留）。
        var seeded = try loadConvergenceIndex(fixture)
        seeded.zeroAccountedFullStrikesBySession = [fixture.sessionID: 2]
        try AntigravityLocalUsageScanner.saveIndex(
            seeded, cacheDir: fixture.cache, fileManager: FileManagerBox(fixture.fm)
        )

        // 第 3 轮：offset=0 核验返回 count=5 == 缓存 offset → 收敛并清零。
        let scan3 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(120), stub: stub)
        XCTAssertEqual(scan3.failedSessionCount, 0, "核验收敛不计失败")
        let index = try loadConvergenceIndex(fixture)
        XCTAssertNil(index.zeroAccountedFullStrikesBySession, "核验收敛页必须清零零可计账打击计数")
        XCTAssertEqual(index.sessions[fixture.sessionID]?.mtimeMs, fixture.liveMtimeMs, "收敛推进文件指纹")
        XCTAssertEqual(index.sessions[fixture.sessionID]?.generatorMetadataOffset, 5)
    }

    /// 空 suffix（.emptyIncremental）**不**清零零可计账打击计数。
    ///
    /// 计数回答的是"解析器能否产出可计账 event"，而空 suffix 页只有 0 条 raw
    /// 条目可解析——它证明的是 RPC 正常到达（传输维度），对解析质量（另一维度）
    /// 零信息，不能用来证明解析已恢复。
    ///
    /// 这一点与解析损坏的真实形态直接相关：若 token 字段改名导致解析失效，一个
    /// 活跃但间歇使用的 session 天然会在"有 raw 但零可计账"（模型在用）与
    /// "空闲无 suffix"（模型没用）之间交替。若每次空闲都清零计数，它永远凑不满
    /// `zeroAccountedFullStrikeLimit` 轮观察期 → `failedCount` 恒 > 0 →
    /// `calendarSignature` 永不推进 → 每轮 reconcile 全量冷重建，正是打击机制
    /// 要守住的不变量。
    ///
    /// 对照：核验收敛页（`metadataEntryCount == cached offset`）**仍**清零——它
    /// 是 offset=0 全量页且确认服务端没有新事件，解析结果不影响该结论，属于
    /// 正面证据。
    func testEmptyIncrementalPreservesZeroAccountedStrikes() async throws {
        let fixture = try makeConvergenceFixture(cachedOffset: 5, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var seeded = try loadConvergenceIndex(fixture)
        seeded.zeroAccountedFullStrikesBySession = [fixture.sessionID: 2]
        try AntigravityLocalUsageScanner.saveIndex(
            seeded, cacheDir: fixture.cache, fileManager: FileManagerBox(fixture.fm)
        )

        // samples 缓存完整 + cachedOffset=5 → 走增量 plan，suffix 为空。
        let stub = MetadataStub { _, _ in
            (events: [], metadataEntryCount: 0)
        }
        let scan = try await runConvergenceScan(
            fixture: fixture,
            now: Date(timeIntervalSince1970: 1_790_000_000),
            stub: stub
        )
        XCTAssertEqual(scan.failedSessionCount, 1)
        let index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(
            index.zeroAccountedFullStrikesBySession?[fixture.sessionID], 2,
            "空 suffix 不含解析证据，必须保留零可计账打击计数"
        )
        XCTAssertEqual(index.sessions[fixture.sessionID]?.consecutiveEmptySuffixes, 1)
        XCTAssertEqual(index.sessions[fixture.sessionID]?.generatorMetadataOffset, 5)
    }

    /// RPC .failure 是传输层结果、不含解析证据：刻意保留零可计账打击计数——
    /// 网络抖动若也打断计数，"解析损坏 + 网络差"的 session 永远凑不满 3 轮
    /// 观察期 → failedCount 永不归零 → 签名永不推进，破坏有界收敛不变量。
    func testRPCFailureKeepsZeroAccountedStrikes() async throws {
        let fixture = try makeConvergenceFixture(cachedOffset: 5, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var seeded = try loadConvergenceIndex(fixture)
        seeded.zeroAccountedFullStrikesBySession = [fixture.sessionID: 2]
        try AntigravityLocalUsageScanner.saveIndex(
            seeded, cacheDir: fixture.cache, fileManager: FileManagerBox(fixture.fm)
        )

        let stub = MetadataStub { _, _ in
            throw NSError(domain: "test", code: 1)
        }
        let scan = try await runConvergenceScan(
            fixture: fixture,
            now: Date(timeIntervalSince1970: 1_790_000_000),
            stub: stub
        )
        XCTAssertEqual(scan.failedSessionCount, 1)
        let index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(
            index.zeroAccountedFullStrikesBySession?[fixture.sessionID], 2,
            "RPC 失败不得清零零可计账打击计数"
        )
        XCTAssertEqual(index.sessions[fixture.sessionID]?.generatorMetadataOffset, 5)
        XCTAssertEqual(index.sessions[fixture.sessionID]?.mtimeMs, fixture.liveMtimeMs - 60_000)
    }
}
