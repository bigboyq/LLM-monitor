import XCTest
import SQLite3
@testable import LLM_monitor

final class GlmZcodeDBReaderTests: GlmTestCase {

    /// 合并测试：行级字符分摊 + native 优先 + 无 part → reasoning=0 + malformed JSON。
    /// 分摊只在 `querySamples` 行级发生，日聚合的 output/reasoning 桶 = 该日样本
    /// 行级分摊之和（日级分摊已删除，与样本严格同源）。Day A 两行思考比例刻意
    /// 错开（75% / 25%），使行级累计（50/30）区别于旧日级分摊（80×1000/2000 =
    /// 40/40）——钉死「日聚合与样本严格同源」。三个互不重叠的日子，避免跨日稀释。
    func testGlmZcodeDBReaderCharSplitDayAggregation() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let cal = localCalendar()
        let day = Self.todayMidnight(calendar: cal)
        let yesterday = cal.date(byAdding: .day, value: -1, to: day)!
        let olderDay = cal.date(byAdding: .day, value: -2, to: day)!

        // Day A（今天）：两行思考行，比例刻意错开——
        // a0: 60 output × 750 思考/250 可见（75%）→ 45 reasoning + 15 output
        // a1: 20 output × 250 思考/750 可见（25%）→ 5 reasoning + 15 output
        // 行级按日累计 50/30；旧日级分摊把整天 80 output 按 1000/2000 拆成 40/40，
        // 与样本Σ不一致（本用例钉死两者必须一致）。
        try insert(databaseURL: db, id: "a0", sessionID: "sA", turnID: "ta0",
                   timestamp: ms(day), input: 100, output: 60,
                   assistantMessageID: "msg_a0")
        try insertPart(databaseURL: db, id: "pa_r0", messageID: "msg_a0",
                       jsonData: #"{"type":"reasoning","text":"\#(String(repeating: "x", count: 750))"}"#)
        try insertPart(databaseURL: db, id: "pa_t0", messageID: "msg_a0",
                       jsonData: #"{"type":"text","text":"\#(String(repeating: "y", count: 250))"}"#)
        try insert(databaseURL: db, id: "a1", sessionID: "sA", turnID: "ta1",
                   timestamp: ms(day) + 1, input: 100, output: 20,
                   assistantMessageID: "msg_a1")
        try insertPart(databaseURL: db, id: "pa_r1", messageID: "msg_a1",
                       jsonData: #"{"type":"reasoning","text":"\#(String(repeating: "x", count: 250))"}"#)
        try insertPart(databaseURL: db, id: "pa_t1", messageID: "msg_a1",
                       jsonData: #"{"type":"text","text":"\#(String(repeating: "y", count: 750))"}"#)
        // Day B（昨天）：native reasoning 行 → 账单值优先透传（即使 part 字符比例不同）
        try insert(databaseURL: db, id: "b1", sessionID: "sB", turnID: "tb1",
                   timestamp: ms(yesterday), input: 100, output: 50, reasoning: 20,
                   assistantMessageID: "msg_b1")
        try insertPart(databaseURL: db, id: "pb_r", messageID: "msg_b1",
                       jsonData: #"{"type":"reasoning","text":"\#(String(repeating: "x", count: 7))"}"#)
        try insertPart(databaseURL: db, id: "pb_t", messageID: "msg_b1",
                       jsonData: #"{"type":"text","text":"\#(String(repeating: "y", count: 3))"}"#)
        // Day C（前天）：assistant_message_id = NULL（无 part 可 join）+ 损坏 JSON part
        // → 都没有可分摊的思考字符 → reasoning 保持 0
        try insert(databaseURL: db, id: "c1", sessionID: "sC", turnID: "tc1",
                   timestamp: ms(olderDay), input: 100, output: 33, assistantMessageID: nil)
        try insert(databaseURL: db, id: "c2", sessionID: "sC", turnID: "tc2",
                   timestamp: ms(olderDay) + 1, input: 100, output: 33, assistantMessageID: "msg_c2")
        try insertPart(databaseURL: db, id: "pc_bad", messageID: "msg_c2", jsonData: "{invalid")

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)

        // Day A：日桶 = 该日样本行级分摊之和（45+5 reasoning、15+15 output），守恒
        let dayA = try XCTUnwrap(aggregate.perDay[day])
        XCTAssertEqual(dayA.inputTokens, 200)
        XCTAssertEqual(dayA.reasoningTokens, 50, "行级累计 45+5；旧日级分摊会得 40，与样本Σ不一致")
        XCTAssertEqual(dayA.outputTokens, 30)
        XCTAssertEqual(dayA.reasoningTokens + dayA.outputTokens, 80, "守恒")
        XCTAssertEqual(dayA.rounds, 2)
        XCTAssertEqual(dayA.totalTokens, 280, "total 不变：200 input + 0 cacheRead + 80（分摊守恒）")
        // 守恒: total = uncached input + cacheRead + tout + trsn
        XCTAssertEqual(dayA.totalTokens, dayA.inputTokens + dayA.cacheReadTokens + dayA.outputTokens + dayA.reasoningTokens)

        // Day B：native reasoning 列 > 0 → 该行账单值优先透传，不做字符分摊
        let dayB = try XCTUnwrap(aggregate.perDay[yesterday])
        XCTAssertEqual(dayB.reasoningTokens, 20, "native 优先透传")
        XCTAssertEqual(dayB.outputTokens, 50)

        // Day C：无思考字符 → reasoning = 0，output 原样保留
        let dayC = try XCTUnwrap(aggregate.perDay[olderDay])
        XCTAssertEqual(dayC.reasoningTokens, 0)
        XCTAssertEqual(dayC.outputTokens, 66, "无 part / malformed JSON 行不凭空生思考")

        // 样本行级分摊（started_at 升序：Day C → Day B → Day A）：
        // 45/15 + 5/15；native 行透传；Day C 行保持 0
        XCTAssertEqual(aggregate.samples.count, 5)
        XCTAssertEqual(aggregate.samples.map(\.reasoningOutputTokens), [0, 0, 20, 45, 5])
        XCTAssertEqual(aggregate.samples.map(\.outputTokens), [33, 33, 50, 15, 15])
        XCTAssertEqual(aggregate.samples[3].reasoningOutputTokens + aggregate.samples[3].outputTokens, 60, "行级守恒")

        // 日聚合与样本严格同源：日桶 = 该日样本行级分摊之和
        let dayASamples = aggregate.samples.filter { cal.startOfDay(for: $0.completedAt) == day }
        XCTAssertEqual(dayA.outputTokens, dayASamples.reduce(0) { $0 + $1.outputTokens })
        XCTAssertEqual(dayA.reasoningTokens, dayASamples.reduce(0) { $0 + $1.reasoningOutputTokens })
    }

    /// 一致性回归（投影膨胀修复）：同一 fixture 下，日聚合的 output/reasoning 桶
    /// 逐日等于该日样本行级分摊之和，且 totalTokens 不因对齐改变。旧实现的日级
    /// 分摊与行级分摊分桶不同（2026-11-08 真实数据：日级 703,147/1,005,504 vs
    /// 行级Σ 735,889/972,762），投影 `includingCurrentDay` 逐桶 max() 合并时
    /// Output+Reasoning 凭空膨胀 +32,742——两侧同源后 max() 退化为精确 no-op
    /// （对真实截断的来源仍是安全网）。fixture 覆盖三种日形态：比例错开的多行
    /// 思考日、native 优先日、无 part 日。
    func testGlmZcodeDailyBucketsEqualRowLevelSampleSumsPerDay() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let cal = localCalendar()
        let day = Self.todayMidnight(calendar: cal)
        let yesterday = cal.date(byAdding: .day, value: -1, to: day)!
        let olderDay = cal.date(byAdding: .day, value: -2, to: day)!

        // 今天：两行思考比例错开（行级累计 ≠ 旧日级分摊）
        try insert(databaseURL: db, id: "h1", sessionID: "s1", turnID: "t1",
                   timestamp: ms(day), input: 100, output: 60,
                   assistantMessageID: "m_h1")
        try insertPart(databaseURL: db, id: "ph_r1", messageID: "m_h1",
                       jsonData: #"{"type":"reasoning","text":"\#(String(repeating: "x", count: 750))"}"#)
        try insertPart(databaseURL: db, id: "ph_t1", messageID: "m_h1",
                       jsonData: #"{"type":"text","text":"\#(String(repeating: "y", count: 250))"}"#)
        try insert(databaseURL: db, id: "h2", sessionID: "s1", turnID: "t2",
                   timestamp: ms(day) + 1, input: 100, output: 20,
                   assistantMessageID: "m_h2")
        try insertPart(databaseURL: db, id: "ph_r2", messageID: "m_h2",
                       jsonData: #"{"type":"reasoning","text":"\#(String(repeating: "x", count: 250))"}"#)
        try insertPart(databaseURL: db, id: "ph_t2", messageID: "m_h2",
                       jsonData: #"{"type":"text","text":"\#(String(repeating: "y", count: 750))"}"#)
        // 昨天：native reasoning 行
        try insert(databaseURL: db, id: "h3", sessionID: "s2", turnID: "t3",
                   timestamp: ms(yesterday), input: 100, output: 50, reasoning: 20)
        // 前天：无 part
        try insert(databaseURL: db, id: "h4", sessionID: "s3", turnID: "t4",
                   timestamp: ms(olderDay), input: 100, output: 33)

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)

        XCTAssertEqual(aggregate.perDay.count, 3)
        for (dayStart, day) in aggregate.perDay {
            let daySamples = aggregate.samples.filter { cal.startOfDay(for: $0.completedAt) == dayStart }
            XCTAssertFalse(daySamples.isEmpty, "每个日桶都应有同源样本（两查询 WHERE 与 cutoff 一致）")
            XCTAssertEqual(
                day.outputTokens, daySamples.reduce(0) { $0 + $1.outputTokens },
                "日桶 output 必须等于该日样本行级分摊之和")
            XCTAssertEqual(
                day.reasoningTokens, daySamples.reduce(0) { $0 + $1.reasoningOutputTokens },
                "日桶 reasoning 必须等于该日样本行级分摊之和")
            // totalTokens 不变：对齐只改分桶，不改四桶合计
            XCTAssertEqual(
                day.totalTokens,
                day.inputTokens + day.cacheReadTokens + day.outputTokens + day.reasoningTokens
            )
        }
        // 今天精确值：行级累计 50/30（旧日级分摊会拆成 40/40）
        let today = try XCTUnwrap(aggregate.perDay[day])
        XCTAssertEqual(today.reasoningTokens, 50)
        XCTAssertEqual(today.outputTokens, 30)
        XCTAssertEqual(today.totalTokens, 280, "200 input + 80 output+reasoning（分摊守恒，total 不变）")
    }

    /// R9: 单行负 token 不能抵消其他行的合法正值；所有公开字段保持 0...Int.max。
    /// 混合行（input=-100, output=200，WHERE 求和=100>0 被纳入）的负 input 按 0 计。
    func testR9GlmNegativeTokensDoNotCancelPositives() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let day = Self.todayMidnight(calendar: localCalendar())
        let ts = ms(day)
        let cal = localCalendar()

        // 正行：input=100, output=50
        try insert(databaseURL: db, id: "pos", sessionID: "s", turnID: "t1", timestamp: ts,
                   input: 100, output: 50)
        // 混合行：input=-100, output=200（input+output=100>0，被纳入）
        try insert(databaseURL: db, id: "neg", sessionID: "s", turnID: "t2", timestamp: ts + 1,
                   input: -100, output: 200)

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)
        let today = try XCTUnwrap(aggregate.perDay[day])

        // input = max(100,0) + max(-100,0) = 100（不是 0）；cacheRead=0
        XCTAssertEqual(today.inputTokens, 100, "负 input 不得抵消正 input")
        // output = 50 + 200 = 250
        XCTAssertEqual(today.outputTokens, 250)
        // 所有字段非负
        XCTAssertGreaterThanOrEqual(today.inputTokens, 0)
        XCTAssertGreaterThanOrEqual(today.outputTokens, 0)
        XCTAssertGreaterThanOrEqual(today.totalTokens, 0)
    }

    /// 当上游上报异常导致 cacheRead > input 时（即 cacheRead 超过 rawInput 包络），
    /// 统一按 TokenAccountingCatalog.zcode 规范处理：
    /// effectiveCacheRead = min(cacheRead, safeInput)，uncachedInput = 0，
    /// 四桶守恒：totalTokens 恒等于 rawInput + output + reasoning。
    func testGlmCacheReadExceedingInputIsClampedAndPreservesConservation() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let day = Self.todayMidnight(calendar: localCalendar())
        let ts = ms(day)
        let cal = localCalendar()

        // 插入一行 cacheRead (250) > input (100) 的异常行
        try insert(databaseURL: db, id: "anom", sessionID: "s", turnID: "t1", timestamp: ts,
                   input: 100, output: 50, cacheRead: 250)

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)
        let today = try XCTUnwrap(aggregate.perDay[day])

        XCTAssertEqual(today.inputTokens, 0, "uncached input 必须为 0")
        XCTAssertEqual(today.cacheReadTokens, 100, "cacheRead 必须截断至 input (100)")
        XCTAssertEqual(today.outputTokens, 50)
        XCTAssertEqual(today.totalTokens, 150, "totalTokens 守恒为 100 + 50 = 150")
    }

    /// 2026-09-17 Zcode `0020_provider_model_selection` 迁移：登录账号套餐改写
    /// `account:bigmodel-` 前缀。同一天新旧前缀混写（真实迁移日的形态）时，
    /// 聚合 / totals / 样本都必须把两种前缀的智谱行都算进来，非智谱行仍排除；
    /// 已登记的 account: 套餐按显式枚举归桶（coding-plan 日常 / offpeak 闲时 /
    /// start-plan 其他）。
    func testGlmZcodeReaderIncludesAccountPrefixAfterMigration() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let day = Self.todayMidnight(calendar: localCalendar())
        let ts = ms(day)
        let cal = localCalendar()

        // 迁移前后各 2 行正式 Coding Plan（builtin: / account:）
        try insert(databaseURL: db, id: "b1", sessionID: "s1", turnID: "t1", timestamp: ts,
                   input: 100, output: 10, provider: "builtin:bigmodel-coding-plan")
        try insert(databaseURL: db, id: "b2", sessionID: "s1", turnID: "t2", timestamp: ts + 1,
                   input: 100, output: 10, provider: "builtin:bigmodel-coding-plan")
        try insert(databaseURL: db, id: "a1", sessionID: "s2", turnID: "t3", timestamp: ts + 2,
                   input: 200, output: 20, provider: "account:bigmodel-individual-coding-plan")
        try insert(databaseURL: db, id: "a2", sessionID: "s2", turnID: "t4", timestamp: ts + 3,
                   input: 200, output: 20, provider: "account:bigmodel-individual-coding-plan")
        // account: 前缀的体验套餐 → 柱图计入，额度窗口归「其他」
        try insert(databaseURL: db, id: "a3", sessionID: "s3", turnID: "t5", timestamp: ts + 4,
                   input: 1000, output: 5, provider: "account:bigmodel-start-plan")
        // 闲时任务照旧精确匹配（历史裸值）
        try insert(databaseURL: db, id: "o1", sessionID: "s3", turnID: "t6", timestamp: ts + 5,
                   input: 500, output: 5, provider: "offpeak-idle-plan")
        // 0020 迁移后账号化闲时 ID：此前只精确匹配旧裸值会被漏分类（误入其他）
        try insert(databaseURL: db, id: "o2", sessionID: "s3", turnID: "t7", timestamp: ts + 6,
                   input: 250, output: 5, provider: "account:bigmodel-offpeak-idle-plan")
        // zai 族账号套餐：经 account:zai- 前缀 LIKE 读入，归日常任务
        try insert(databaseURL: db, id: "a4", sessionID: "s2", turnID: "t8", timestamp: ts + 7,
                   input: 300, output: 30, provider: "account:zai-individual-coding-plan")
        // 非智谱 provider 不得进入 GLM 卡
        try insert(databaseURL: db, id: "x1", sessionID: "s4", turnID: "t7", timestamp: ts + 6,
                   input: 999, output: 99, provider: "builtin:other-provider")

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)
        let today = try XCTUnwrap(aggregate.perDay[day])

        // 8 行智谱全计入（x1 排除）：rounds / input / output
        XCTAssertEqual(today.rounds, 8, "account: 前缀的行不得被漏采")
        XCTAssertEqual(today.inputTokens, 100 + 100 + 200 + 200 + 1000 + 500 + 250 + 300)
        XCTAssertEqual(today.outputTokens, 10 + 10 + 20 + 20 + 5 + 5 + 5 + 30)
        // totals 同口径：roundCount 含 account: 行，session 去重 s1/s2/s3
        XCTAssertEqual(aggregate.roundCount, 8)
        XCTAssertEqual(aggregate.sessionCount, 3)

        // 样本层分类：account coding-plan 归日常，account 体验套餐归其他，
        // 账号化闲时归闲时，zai 族套餐归日常
        let samplesByProvider = Dictionary(aggregate.samples.map { ($0.sourceProviderID ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(GlmUsageCategory.classify(samplesByProvider["account:bigmodel-individual-coding-plan"]!), .normal)
        XCTAssertEqual(GlmUsageCategory.classify(samplesByProvider["account:bigmodel-start-plan"]!), .startPlan)
        XCTAssertEqual(GlmUsageCategory.classify(samplesByProvider["builtin:bigmodel-coding-plan"]!), .normal)
        XCTAssertEqual(GlmUsageCategory.classify(samplesByProvider["offpeak-idle-plan"]!), .offPeak)
        XCTAssertEqual(GlmUsageCategory.classify(samplesByProvider["account:bigmodel-offpeak-idle-plan"]!), .offPeak)
        XCTAssertEqual(GlmUsageCategory.classify(samplesByProvider["account:zai-individual-coding-plan"]!), .normal)
        XCTAssertNil(samplesByProvider["builtin:other-provider"], "非智谱 provider 不应产出样本")
    }

    /// 合并测试：native reasoning 聚合 + sample 分配 + snapshot 7 天 padding。
    /// 覆盖：账单层 reasoning_tokens 优先级（per-day + samples 同步）、promptID 命名（turn vs event fallback）、
    /// buildSnapshot 7 天窗口、today 挑选、recentSamples 保留。
    func testGlmZcodeDBReaderNativeAndSnapshot() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let day = Self.todayMidnight(calendar: localCalendar())
        let cal = localCalendar()

        // 3 行同 session 同 turn + 1 行 turn=NULL（测 event-id fallback）+ 1 行其他 turn
        try insert(databaseURL: db, id: "u1", sessionID: "s1", turnID: "t1", timestamp: ms(day),
                   input: 300, output: 10, reasoning: 5, cacheRead: 200, cacheWrite: 30)
        try insert(databaseURL: db, id: "u2", sessionID: "s1", turnID: "t1", timestamp: ms(day) + 1000,
                   input: 200, output: 8, reasoning: 2, cacheRead: 150)
        try insert(databaseURL: db, id: "u3", sessionID: "s1", turnID: "t2", timestamp: ms(day) + 2000,
                   input: 60, output: 4, reasoning: 1, cacheRead: 40)
        // 没有 assistant_message_id → 也不会被归为 reasoning,仍走 native 路径
        try insert(databaseURL: db, id: "u4", sessionID: "s2", turnID: nil, timestamp: ms(day) + 3000,
                   input: 100, output: 6, reasoning: 3, cacheRead: 50)

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)
        let today = try XCTUnwrap(aggregate.perDay[day])

        // uncached input = max(SUM(input_tokens) - SUM(cache_read_input_tokens), 0) = max(660-440, 0) = 220
        XCTAssertEqual(today.inputTokens, 220)
        // native path (reasoning_tokens > 0): tout = output_tokens 原值, trsn = reasoning_tokens 原值（独立加总, 不做"重分类"）
        XCTAssertEqual(today.outputTokens, 28, "10+8+4+6")
        XCTAssertEqual(today.reasoningTokens, 11, "5+2+1+3")
        XCTAssertEqual(today.cacheReadTokens, 440)
        XCTAssertEqual(today.cacheWriteTokens, 30)
        XCTAssertEqual(today.rounds, 4)
        // COUNT(DISTINCT turn_id) 排除 NULL: u1+u2 共 t1, u3=t2, u4=NULL → 2 distinct (t1, t2)
        XCTAssertEqual(today.turns, 2)

        // Sample 分配: 4 条 sample,promptID 命名 (turn 存在 → session:turn; null → session:event-id)
        XCTAssertEqual(aggregate.samples.count, 4)
        let promptIDs = Set(aggregate.samples.map(\.promptID))
        XCTAssertTrue(promptIDs.contains("s1:t1"))
        XCTAssertTrue(promptIDs.contains("s1:t2"))
        XCTAssertTrue(promptIDs.contains("s2:event-u4"), "turn=NULL fallback to event-<id>")
        // samples 按 started_at 升序
        XCTAssertEqual(aggregate.samples.map(\.outputTokens), [10, 8, 4, 6])

        // Snapshot 7 天 padding + today 挑选 + recentSamples 保留
        let snapshot = GlmZcodeLocalUsageScanner.buildSnapshot(
            adjustedPerDay: aggregate.perDay,
            sessionCount: 2, roundCount: 4, samples: aggregate.samples,
            offPeakWindows: [],
            calendar: cal, now: day
        )
        XCTAssertEqual(snapshot.dailyTokenUsage.count, 7)
        XCTAssertEqual(snapshot.today?.dayStart, day)
        XCTAssertEqual(snapshot.recentSamples?.count, 4)
        XCTAssertEqual(snapshot.eventCount, 4)
        XCTAssertEqual(snapshot.sessionCount, 2)
    }

    /// 回归：ZCode 闲时任务的 `model_usage` 行落在独立的 `offpeak-idle-plan` provider，
    /// 不是 `builtin:bigmodel-coding-plan`。scanner 必须两个 provider 都读，才能让
    /// 今日 / 7 天柱图包含闲时任务的真实 token 消耗；额度窗口 hover 靠 `excludeWindows`
    /// 按 off_peak 时间窗口把它们排除（不消耗 Coding Plan 积分）。
    func testGlmZcodeDBReaderIncludesOffPeakProviderRows() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let day = Self.todayMidnight(calendar: localCalendar())
        let cal = localCalendar()
        let offPeakStart = day.addingTimeInterval(3600)
        let offPeakEnd = day.addingTimeInterval(7200)

        // 2 行 coding-plan（正常交互）：input=100+200, cacheRead=50+50
        try insert(databaseURL: db, id: "c1", sessionID: "s1", turnID: "t1", timestamp: ms(day),
                   input: 100, output: 10, cacheRead: 50)
        try insert(databaseURL: db, id: "c2", sessionID: "s1", turnID: "t2", timestamp: ms(day) + 1000,
                   input: 200, output: 20, cacheRead: 50)
        // 1 行闲时任务（0020 迁移后账号化 ID，经 account:bigmodel-% 前缀 LIKE 读入）：
        // 落在 off_peak 窗口内,大额 cacheRead
        try insert(databaseURL: db, id: "o1", sessionID: "s2", turnID: "t1",
                   timestamp: ms(offPeakStart) + 500,
                   input: 1000, output: 100, cacheRead: 900,
                   provider: "account:bigmodel-offpeak-idle-plan")

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)
        let today = try XCTUnwrap(aggregate.perDay[day])

        // 今日柱图包含闲时任务：uncached input = max(1300 - 1000, 0) = 300, cacheRead = 1000
        XCTAssertEqual(today.inputTokens, 300, "coding-plan 300 + off-peak 1000 → uncached = max(1300-1000,0) = 300")
        XCTAssertEqual(today.cacheReadTokens, 1000, "50+50+900，闲时任务的 cacheRead 进入柱图")
        XCTAssertEqual(today.rounds, 3)

        // recentSamples 也包含闲时任务行
        XCTAssertEqual(aggregate.samples.count, 3)

        // 额度窗口 summary：提供 excludeWindows 时排除闲时任务行，只留 2 行 coding-plan
        let window = GlmOffPeakWindow(startedAt: offPeakStart, endedAt: offPeakEnd)
        let summary = LocalUsageSummaryBuilder.summary(
            samples: aggregate.samples,
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: day, end: day.addingTimeInterval(86400),
            excludeWindows: [window]
        )
        XCTAssertEqual(summary?.rounds, 2)
        XCTAssertEqual(summary?.cachedInputTokens, 100, "闲时任务 cacheRead 900 被排除")

        // 不带 excludeWindows → 闲时任务也会进入窗口统计（防御：若未来去掉排除要留意图层）
        let rawSummary = LocalUsageSummaryBuilder.summary(
            samples: aggregate.samples,
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: day, end: day.addingTimeInterval(86400)
        )
        XCTAssertEqual(rawSummary?.rounds, 3)
    }

    func testGlmCachedSnapshotRebaseRefreshesTimestampAndUsesOnlyActiveToday() {
        let cal = localCalendar()
        let yesterday = cal.date(byAdding: .day, value: -1, to: Self.todayMidnight(calendar: cal))!
        let now = cal.date(byAdding: .hour, value: 1, to: Self.todayMidnight(calendar: cal))!
        let oldScan = now.addingTimeInterval(-3600)
        let previousDay = GlmDailyUsage(
            dayStart: yesterday, inputTokens: 10, outputTokens: 5,
            cacheReadTokens: 0, cacheWriteTokens: 0, reasoningTokens: 0,
            totalTokens: 15, turns: 1, rounds: 1
        )
        let snapshot = GlmLocalUsage(
            today: previousDay,
            dailyTokenUsage: [previousDay],
            scannedAt: oldScan,
            sessionCount: 1,
            eventCount: 1,
            failedSessionCount: 0,
            recentSamples: []
        )

        let rebased = GlmZcodeLocalUsageScanner.rebaseCachedSnapshot(snapshot, calendar: cal, now: now)

        XCTAssertEqual(rebased.scannedAt, now)
        XCTAssertNil(rebased.today, "空的今天不应伪装成有活动的 today 快照")
        XCTAssertEqual(rebased.dailyTokenUsage.count, 7)
    }

    func testGlmReaderAppliesRecentCutoffToDailyAggregation() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let cal = localCalendar()
        let today = Self.todayMidnight(calendar: cal)
        let oldDay = cal.date(byAdding: .day, value: -10, to: today)!

        try insert(databaseURL: db, id: "old", sessionID: "s-old", turnID: "t-old", timestamp: ms(oldDay),
                   input: 100, output: 10)
        try insert(databaseURL: db, id: "recent", sessionID: "s-recent", turnID: "t-recent", timestamp: ms(today),
                   input: 200, output: 20)

        let cutoff = cal.date(byAdding: .day, value: -8, to: today)!
        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(
            dbPath: URL(fileURLWithPath: db), calendar: cal, sampleCutoff: cutoff
        )

        XCTAssertNil(aggregate.perDay[oldDay], "日聚合不应为窗口外历史数据做全表分组")
        XCTAssertNotNil(aggregate.perDay[today])
        XCTAssertEqual(aggregate.samples.map(\.promptID), ["s-recent:t-recent"])
    }

    func testGlmUsageProjectionCombinesZcodeAndOpencode() {
        let day = Self.todayMidnight(calendar: .current)
        let nativeDay = GlmDailyUsage(
            dayStart: day, inputTokens: 100, outputTokens: 50,
            cacheReadTokens: 30, cacheWriteTokens: 10, reasoningTokens: 20,
            totalTokens: 200, turns: 2, rounds: 3
        )
        let sample1 = LocalTokenUsageSample(
            completedAt: Date(), modelName: "glm-4", promptID: "native:1",
            inputTokens: 100, cachedInputTokens: 0, outputTokens: 50, reasoningOutputTokens: 0
        )
        let native = GlmLocalUsage(
            today: nativeDay, dailyTokenUsage: [nativeDay], scannedAt: Date(timeIntervalSince1970: 1000),
            sessionCount: 2, eventCount: 3, failedSessionCount: 0,
            recentSamples: [sample1]
        )

        let openDay = OpencodeDailyUsage(
            dayStart: day, inputTokens: 200, outputTokens: 80,
            cacheReadTokens: 40, cacheWriteTokens: 15, reasoningTokens: 30,
            turns: 3, rounds: 4
        )
        let sample2 = LocalTokenUsageSample(
            completedAt: Date(), modelName: "glm-4", promptID: "p1",
            inputTokens: 200, cachedInputTokens: 0, outputTokens: 80, reasoningOutputTokens: 0
        )
        let opencode = OpencodeProviderUsage(
            today: openDay, dailyTokenUsage: [openDay], roundCount: 4,
            recentSamples: [sample2]
        )

        // 生产路径：usageProjection 把 ZCode native 与 OpenCode glm 分片按日相加。
        var status = ProviderStatus(
            id: "glm", displayName: "GLM", kind: .glmCodingPlan,
            iconSystemName: "circle", accentColor: .glm,
            refreshIntervalSeconds: 300, state: .ready
        )
        status.glmLocalUsage = native
        status.opencodeUsage = OpencodeLocalUsage(
            byProvider: [OpencodeLocalUsage.glmProviderID: opencode],
            modelsByProvider: [:], dbPath: nil, scannedAt: nil
        )
        status.clientBindings = ProviderStatus.allClientBindingsEnabled()

        let projection = status.usageProjection(for: nil)
        XCTAssertEqual(projection.clientIDs, [ClientID.zcode, ClientID.openCode])
        let mergedToday = try! XCTUnwrap(projection.dailyTokenUsage.first)
        XCTAssertEqual(mergedToday.input, 300)
        XCTAssertEqual(mergedToday.output, 130)
        XCTAssertEqual(mergedToday.cacheRead, 70)
        XCTAssertEqual(mergedToday.cacheWrite, 25)
        XCTAssertEqual(mergedToday.reasoning, 50)

        // Verify recentSamples promptID namespacing。A4 起 ZCode 智谱 native 在投影层
        // 补 `zcode:` 前缀（scanner / 缓存仍是裸 ID），OpenCode 分片前缀不变。
        let sampleIDs = projection.recentSamples.map { $0.promptID }
        XCTAssertTrue(sampleIDs.contains("zcode:native:1"))
        XCTAssertTrue(sampleIDs.contains("opencode:\(OpencodeLocalUsage.glmProviderID):p1"))
    }

    /// `model_usage.duration_ms`（epoch 毫秒，显式列）写入 sample 的
    /// `durationSeconds`（秒）：正常值毫秒→秒、NULL 落 nil、负值落 nil；
    /// 智谱主样本与非智谱分片样本两个构造点同口径。
    func testGlmZcodeDBReaderWritesDurationSecondsIntoSamples() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let day = Self.todayMidnight(calendar: localCalendar())
        let ts = ms(day)
        let cal = localCalendar()

        // 正常：1250ms → 1.25s
        try insert(databaseURL: db, id: "d1", sessionID: "s1", turnID: "t1", timestamp: ts,
                   input: 100, output: 10, durationMs: 1250)
        // 缺失（NULL）：旧版本账本行 → nil
        try insert(databaseURL: db, id: "d2", sessionID: "s1", turnID: "t2", timestamp: ts + 1,
                   input: 100, output: 10)
        // 负值：账本异常 → nil
        try insert(databaseURL: db, id: "d3", sessionID: "s1", turnID: "t3", timestamp: ts + 2,
                   input: 100, output: 10, durationMs: -5)
        // 超出 1h 有效域（L0 统一校验，与 Codex / DSH 同口径）→ nil
        try insert(databaseURL: db, id: "d5", sessionID: "s1", turnID: "t5", timestamp: ts + 4,
                   input: 100, output: 10, durationMs: 3_600_001)
        // 非智谱分片行（deepseek）同样带时长
        try insert(databaseURL: db, id: "d4", sessionID: "s2", turnID: "t4", timestamp: ts + 3,
                   input: 200, output: 20, model: "deepseek-flash", provider: "deepseek",
                   durationMs: 2000)

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)

        XCTAssertEqual(aggregate.samples.count, 4)
        XCTAssertEqual(aggregate.samples[0].promptID, "s1:t1")
        XCTAssertEqual(aggregate.samples[0].durationSeconds, 1.25, "毫秒 → 秒")
        XCTAssertNil(aggregate.samples[1].durationSeconds, "duration_ms 缺失落 nil")
        XCTAssertNil(aggregate.samples[2].durationSeconds, "duration_ms 负值落 nil")
        XCTAssertNil(aggregate.samples[3].durationSeconds, "duration_ms 超 1h 有效域落 nil")

        let deepseekSamples = try XCTUnwrap(aggregate.providerSlices.samples["deepseek"])
        XCTAssertEqual(deepseekSamples.count, 1)
        XCTAssertEqual(deepseekSamples[0].durationSeconds, 2.0, "分片构造点同口径（毫秒 → 秒）")
    }

    /// `model_usage.time_to_first_token_ms`（原生逐调用 TTFT 列）写入 sample 的
    /// `ttftSeconds`（秒）：正常值毫秒→秒、NULL 落 nil、负值落 nil；
    /// 智谱主样本与非智谱分片样本两个构造点同口径。
    func testGlmZcodeDBReaderWritesTTFTSecondsIntoSamples() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let day = Self.todayMidnight(calendar: localCalendar())
        let ts = ms(day)
        let cal = localCalendar()

        // 正常：864ms → 0.864s
        try insert(databaseURL: db, id: "f1", sessionID: "s1", turnID: "t1", timestamp: ts,
                   input: 100, output: 10, ttftMs: 864)
        // 缺失（NULL）：约 29% 行账本未提供 → nil
        try insert(databaseURL: db, id: "f2", sessionID: "s1", turnID: "t2", timestamp: ts + 1,
                   input: 100, output: 10)
        // 负值：账本异常 → nil
        try insert(databaseURL: db, id: "f3", sessionID: "s1", turnID: "t3", timestamp: ts + 2,
                   input: 100, output: 10, ttftMs: -1)
        // 非智谱分片行（deepseek）同样带 TTFT
        try insert(databaseURL: db, id: "f4", sessionID: "s2", turnID: "t4", timestamp: ts + 3,
                   input: 200, output: 20, model: "deepseek-flash", provider: "deepseek",
                   ttftMs: 1_000)

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)

        XCTAssertEqual(aggregate.samples.count, 3)
        XCTAssertEqual(aggregate.samples[0].ttftSeconds, 0.864, "毫秒 → 秒")
        XCTAssertNil(aggregate.samples[1].ttftSeconds, "time_to_first_token_ms 缺失落 nil")
        XCTAssertNil(aggregate.samples[2].ttftSeconds, "time_to_first_token_ms 负值落 nil")

        let deepseekSamples = try XCTUnwrap(aggregate.providerSlices.samples["deepseek"])
        XCTAssertEqual(deepseekSamples.count, 1)
        XCTAssertEqual(deepseekSamples[0].ttftSeconds, 1.0, "分片构造点同口径（毫秒 → 秒）")
    }
}
