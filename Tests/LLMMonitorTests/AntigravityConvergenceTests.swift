import XCTest
import SQLite3
@testable import LLM_monitor

/// 空后缀 / 零 metadata 的升级与收敛（问题 A/B/C），以及全量页「有 metadata 但零可计账
/// event」的不信任判定。
final class AntigravityConvergenceTests: AntigravityConvergenceTestCase {

    // MARK: - 测试

    /// 问题 A：连续两次空 suffix 后升级 offset=0 全量核验；核验确认 metadata
    /// 总数未变 → 按成功收敛（不计失败、指纹推进、计数清零），之后文件不再
    /// 变化就不再发 RPC；文件真实变化时增量 suffix 照常抓到新事件。
    func testEmptySuffixEscalatesToVerificationAndConverges() async throws {
        let fixture = try makeConvergenceFixture(cachedOffset: 5, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stub = MetadataStub { _, offset in
            (events: [], metadataEntryCount: offset == 5 ? 0 : 5)
        }
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        // 第 1、2 轮：空 suffix → 计数递增、计失败、保留 last-good。
        let scan1 = try await runConvergenceScan(fixture: fixture, now: base, stub: stub)
        XCTAssertEqual(scan1.failedSessionCount, 1)
        var index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(index.sessions[fixture.sessionID]?.consecutiveEmptySuffixes, 1)
        XCTAssertNotNil(index.sessions[fixture.sessionID]?.lastEmptySuffixAt)
        XCTAssertEqual(index.sessions[fixture.sessionID]?.generatorMetadataOffset, 5, "空 suffix 不得推进 offset/指纹")

        _ = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(60), stub: stub)
        index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(index.sessions[fixture.sessionID]?.consecutiveEmptySuffixes, 2)

        // 第 3 轮：升级为 offset=0 核验，总数仍为 5 → 收敛。
        let callsBeforeVerification = stub.callCount
        let scan3 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(120), stub: stub)
        XCTAssertEqual(stub.callCount, callsBeforeVerification + 1, "核验轮只发一次 RPC")
        XCTAssertEqual(stub.lastOffset, 0, "核验请求必须使用 offset=0")
        XCTAssertEqual(scan3.failedSessionCount, 0, "核验收敛不计失败")
        index = try loadConvergenceIndex(fixture)
        let converged = try XCTUnwrap(index.sessions[fixture.sessionID])
        XCTAssertEqual(converged.mtimeMs, fixture.liveMtimeMs, "收敛必须推进文件指纹")
        XCTAssertEqual(converged.sizeBytes, fixture.liveSizeBytes)
        XCTAssertEqual(converged.consecutiveEmptySuffixes, 0, "收敛必须清零空 suffix 计数")
        XCTAssertNil(converged.lastEmptySuffixAt)
        XCTAssertEqual(converged.generatorMetadataOffset, 5, "收敛不得改变 offset")
        XCTAssertEqual(converged.eventCount, 5)
        XCTAssertEqual(
            index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 500,
            "last-good daily 必须保留"
        )

        // 第 4 轮：指纹已推进且文件未变 → 不再发 RPC（source fresh）。
        let callsAfterConverge = stub.callCount
        let scan4 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(180), stub: stub)
        XCTAssertEqual(stub.callCount, callsAfterConverge, "收敛后不得再发 RPC")
        XCTAssertEqual(scan4.failedSessionCount, 0)

        // 第 5 轮：文件真实变化 → 增量 suffix 正常抓到新事件（验收约束 3）。
        try Data(repeating: 2, count: 256).write(to: fixture.dbPath)
        // 注意：URL 对象会缓存已取过的 resource values，必须走 FileManager 拿新 size。
        let grownAttributes = try FileManager.default.attributesOfItem(atPath: fixture.dbPath.path)
        let grownSize = (grownAttributes[.size] as? NSNumber)?.intValue ?? 0
        let eventDate = fixture.dayStart.addingTimeInterval(3_600)
        let newEvents = [makeEvent(timestamp: eventDate, input: 100, total: 100)]
        await stub.setHandler { _, offset in
            (events: offset == 5 ? newEvents : [], metadataEntryCount: offset == 5 ? 1 : 0)
        }
        let scan5 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(240), stub: stub)
        XCTAssertEqual(scan5.failedSessionCount, 0)
        index = try loadConvergenceIndex(fixture)
        let updated = try XCTUnwrap(index.sessions[fixture.sessionID])
        XCTAssertEqual(updated.generatorMetadataOffset, 6)
        XCTAssertEqual(updated.eventCount, 6)
        XCTAssertEqual(updated.sizeBytes, grownSize)
        XCTAssertEqual(
            index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 600,
            "收敛后再变化必须能正常增量入账"
        )
    }

    /// 问题 A 的另一分支：核验发现 server 端总数已变化（追上或截断）→ 走正常
    /// 全量重算路径，整体替换 daily/samples 并推进 offset，不产生失败。
    func testVerificationWithChangedMetadataTotalRunsNormalFullRebuild() async throws {
        let fixture = try makeConvergenceFixture(cachedOffset: 5, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stub = MetadataStub { _, _ in
            (events: [], metadataEntryCount: 0)  // 前两轮：空 suffix
        }
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        _ = try await runConvergenceScan(fixture: fixture, now: base, stub: stub)
        _ = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(60), stub: stub)

        // 第 3 轮核验：server 追上，raw 总数 8（其中 3 个可入账 event）。
        let eventDate = fixture.dayStart.addingTimeInterval(3_600)
        let fullEvents = (0..<3).map {
            makeEvent(timestamp: eventDate.addingTimeInterval(Double($0 * 60)), input: 10, output: 5, total: 15)
        }
        await stub.setHandler { _, _ in
            (events: fullEvents, metadataEntryCount: 8)
        }
        let scan3 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(120), stub: stub)
        XCTAssertEqual(scan3.failedSessionCount, 0, "正常全量重算是成功轮")

        let index = try loadConvergenceIndex(fixture)
        let entry = try XCTUnwrap(index.sessions[fixture.sessionID])
        XCTAssertEqual(entry.generatorMetadataOffset, 8, "offset 必须按 raw metadata 总数重置")
        XCTAssertEqual(entry.eventCount, 3)
        XCTAssertEqual(entry.consecutiveEmptySuffixes, 0)
        XCTAssertEqual(
            index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 30,
            "offset=0 全量重算必须整体替换旧日桶（500 → 30）"
        )
        XCTAssertNil(index.emptyFullStrikesBySession)
    }

    /// 问题 B：零 metadata 全量结果保留 last-good 并累计打击；连续 3 轮后按
    /// 成功收敛——指纹采用当前文件、eventCount/daily 保留，不再计失败，
    /// 之后文件不变就不再发全量 RPC。
    func testZeroMetadataFullConvergesAfterThreeStrikesKeepingLastGood() async throws {
        let fixture = try makeConvergenceFixture(cachedOffset: 0, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stub = MetadataStub { _, _ in
            (events: [], metadataEntryCount: 0)
        }
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        let scan1 = try await runConvergenceScan(fixture: fixture, now: base, stub: stub)
        XCTAssertEqual(scan1.failedSessionCount, 1)
        var index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(index.emptyFullStrikesBySession?[fixture.sessionID], 1)
        XCTAssertEqual(
            index.sessions[fixture.sessionID]?.mtimeMs, fixture.liveMtimeMs - 60_000,
            "strike 轮不得推进指纹"
        )
        XCTAssertEqual(index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 500, "last-good 保留")

        _ = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(60), stub: stub)
        index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(index.emptyFullStrikesBySession?[fixture.sessionID], 2)

        let scan3 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(120), stub: stub)
        XCTAssertEqual(scan3.failedSessionCount, 0, "第 3 轮收敛，不计失败")
        index = try loadConvergenceIndex(fixture)
        XCTAssertNil(index.emptyFullStrikesBySession, "收敛后打击计数清零")
        XCTAssertNil(
            index.calendarRebuildPendingSessions,
            "非日历变更轮收敛不打旧日历重建标记（daily 仍是当前日历分桶）"
        )
        let entry = try XCTUnwrap(index.sessions[fixture.sessionID])
        XCTAssertEqual(entry.mtimeMs, fixture.liveMtimeMs, "收敛采用当前文件指纹")
        XCTAssertEqual(entry.eventCount, 5, "last-good eventCount 保留")
        XCTAssertEqual(entry.generatorMetadataOffset, 0)
        XCTAssertEqual(index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 500, "last-good daily 保留")

        let callsAfterConverge = stub.callCount
        let scan4 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(180), stub: stub)
        XCTAssertEqual(stub.callCount, callsAfterConverge, "收敛后文件不变不得再发 RPC")
        XCTAssertEqual(scan4.failedSessionCount, 0)
    }

    /// 问题 B：打击观察期内任一轮拿到非零 metadata → 计数清零，回到正常路径。
    func testZeroMetadataStrikesClearWhenDataArrives() async throws {
        let fixture = try makeConvergenceFixture(cachedOffset: 0, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stub = MetadataStub { _, _ in
            (events: [], metadataEntryCount: 0)
        }
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        _ = try await runConvergenceScan(fixture: fixture, now: base, stub: stub)
        var index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(index.emptyFullStrikesBySession?[fixture.sessionID], 1)

        // 第 2 轮 server 恢复：全量拿到数据。
        let fullEvents = [makeEvent(timestamp: fixture.dayStart.addingTimeInterval(3_600), input: 7, total: 7)]
        await stub.setHandler { _, _ in
            (events: fullEvents, metadataEntryCount: 6)
        }
        let scan2 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(60), stub: stub)
        XCTAssertEqual(scan2.failedSessionCount, 0)
        index = try loadConvergenceIndex(fixture)
        XCTAssertNil(index.emptyFullStrikesBySession, "拿到非零 metadata 必须清零打击计数")
        XCTAssertEqual(index.sessions[fixture.sessionID]?.generatorMetadataOffset, 6)
        XCTAssertEqual(index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 7)
    }

    /// 修复 1(a)：全量页有 raw metadata 但零可入账 event（如 token 字段改名 →
    /// 每条 entry 解析为 nil）时不可信：计失败、完全保留 last-good
    /// （daily/samples/eventCount/文件指纹），offset 不推进，签名不推进。
    func testFullPageWithMetadataButZeroEventsIsUntrusted() async throws {
        let fixture = try makeConvergenceFixture(cachedOffset: 0, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stub = MetadataStub { _, _ in
            (events: [], metadataEntryCount: 7)
        }
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        let scan = try await runConvergenceScan(fixture: fixture, now: base, stub: stub)
        XCTAssertEqual(scan.failedSessionCount, 1, "零可计账 event 的全量页必须计失败")

        let index = try loadConvergenceIndex(fixture)
        let entry = try XCTUnwrap(index.sessions[fixture.sessionID])
        XCTAssertEqual(entry.generatorMetadataOffset, 0, "不可信全量页不得推进 offset，否则该批数据被增量永久跳过")
        XCTAssertEqual(entry.eventCount, 5, "last-good eventCount 保留")
        XCTAssertEqual(entry.mtimeMs, fixture.liveMtimeMs - 60_000, "不可信全量页不得推进文件指纹")
        XCTAssertEqual(
            index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 500,
            "last-good daily 保留，不得被空聚合整体替换"
        )
        XCTAssertEqual(
            index.calendarSignature, LocalUsageCalendarSignature.make(testCalendar),
            "failedCount > 0 时签名不得推进"
        )
        XCTAssertNil(index.emptyFullStrikesBySession, "raw metadata 非零不进零 metadata 打击计数")
        XCTAssertEqual(
            index.zeroAccountedFullStrikesBySession?[fixture.sessionID], 1,
            "零可计账全量页进入有界打击计数"
        )
    }

    /// 修复 1(b)：全量页 events 全部缺失 timestamp（本地回填后仍为零可计账）
    /// 同样不可信——聚合产出为零时不得整体替换 last-good。
    func testFullPageWithOnlyTimestamplessEventsIsUntrusted() async throws {
        let fixture = try makeConvergenceFixture(cachedOffset: 0, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let timestampless = [makeEvent(timestamp: nil, input: 300, output: 100, total: 400)]
        let stub = MetadataStub { _, _ in
            (events: timestampless, metadataEntryCount: 7)
        }
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        let scan = try await runConvergenceScan(fixture: fixture, now: base, stub: stub)
        XCTAssertEqual(scan.failedSessionCount, 1, "零可计账 event 的全量页必须计失败")

        let index = try loadConvergenceIndex(fixture)
        let entry = try XCTUnwrap(index.sessions[fixture.sessionID])
        XCTAssertEqual(entry.generatorMetadataOffset, 0)
        XCTAssertEqual(entry.eventCount, 5)
        XCTAssertEqual(
            index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 500,
            "全部无 timestamp 的全量页不得清空日桶"
        )
        XCTAssertEqual(entry.mtimeMs, fixture.liveMtimeMs - 60_000, "不可信全量页不得推进文件指纹")
    }

    /// 修复 1(c)：可计账 event > 0 的正常全量页行为不变——整体替换 daily、
    /// offset 按 raw 条数推进、eventCount 只计可入账 event、计成功。部分
    /// event 缺 timestamp 也不影响可信判定。
    func testFullPageWithAccountedEventsStillRebuildsNormally() async throws {
        let fixture = try makeConvergenceFixture(cachedOffset: 0, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let eventDate = fixture.dayStart.addingTimeInterval(3_600)
        let fullEvents = [
            makeEvent(timestamp: eventDate, input: 30, total: 30),
            makeEvent(timestamp: nil, input: 500, total: 500),
        ]
        let stub = MetadataStub { _, _ in
            (events: fullEvents, metadataEntryCount: 7)
        }
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        let scan = try await runConvergenceScan(fixture: fixture, now: base, stub: stub)
        XCTAssertEqual(scan.failedSessionCount, 0)

        let index = try loadConvergenceIndex(fixture)
        let entry = try XCTUnwrap(index.sessions[fixture.sessionID])
        XCTAssertEqual(entry.generatorMetadataOffset, 7, "offset 按 raw metadata 条数推进")
        XCTAssertEqual(entry.eventCount, 1, "eventCount 只计可入账 event")
        XCTAssertEqual(entry.mtimeMs, fixture.liveMtimeMs, "正常全量页推进文件指纹")
        XCTAssertEqual(
            index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 30,
            "全量成功整体替换 daily（500 → 30）"
        )
        XCTAssertEqual(index.samplesBySession?[fixture.sessionID]?.count, 1)
        XCTAssertEqual(
            index.calendarSignature, LocalUsageCalendarSignature.make(testCalendar),
            "成功轮签名照常推进"
        )
    }
}
