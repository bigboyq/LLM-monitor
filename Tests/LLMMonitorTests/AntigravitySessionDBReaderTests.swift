import XCTest
import SQLite3
@testable import LLM_monitor

/// AntigravitySessionDBReader（阶段二a：会话 .db 直读模块）的单元测试。
///
/// fixture 构造辅助已下沉到共享基类 `AntigravityTestCase`（程序化合成：手写
/// protobuf 字节 + 现场建 SQLite 库，绝不拷贝真实会话 db），供 reader 单测与
/// 阶段二b 的 scanner 扫描单测共用。字节布局对照
/// `spec/providers/antigravity.md` § Token & model data ARE in `.db` `gen_metadata`
///（2026-11-08 实测字段表）与 `spec/harnesses/agy.md` § 单次调用时长 方案 A。
///
/// 配对语义（2026-11-08 会话 22b4f174 实测校准）：连接键是
/// **`steps.idx == gen.f20.last_step_index + 1`**，事件集 = 有非空模型名 + usage +
/// 连接命中的 gen 行；无模型名（后台/副调用条目，可能有 usage）或连接不命中的行
/// 整条丢弃——「按序号配对」的早期推断被真实数据推翻（gen 侧 6 条无模型名条目会把
/// 序号整体推移）。
final class AntigravitySessionDBReaderTests: AntigravityTestCase {

    // 基类 fixture 的本测类别名（保持既有断言字面量不变）。
    private var trajectoryID: String { fixtureTrajectoryID }
    private var flashModel: String { fixtureFlashModel }
    private var argonModel: String { fixtureArgonModel }

    // MARK: - protobuf 解码器

    func testProtoFieldsCoversWireTypesAndSkipsFixedFields() {
        // wire 0 多字节 varint：field 1 value 300 → 0x08, 0xAC, 0x02
        let varintFields = AntigravitySessionDBReader.protoFields(in: Data([0x08, 0xAC, 0x02]))
        XCTAssertEqual(varintFields?.count, 1)
        XCTAssertEqual(varintFields?[0].fieldNumber, 1)
        XCTAssertEqual(varintFields?[0].wireType, 0)
        XCTAssertEqual(varintFields?[0].varint, 300)

        // wire 2 length-delim
        let lenFields = AntigravitySessionDBReader.protoFields(in: Data([0x0A, 0x03, 0x61, 0x62, 0x63]))
        XCTAssertEqual(lenFields?[0].bytes, Data("abc".utf8))

        // wire 1（fixed64）/ wire 5（fixed32）定长跳过，后续字段不受影响
        var mixed = pbVarintField(1, 11)
        mixed += [0x09] + Array(repeating: 0xAB, count: 8)          // field 1 wire 1
        mixed += [0x0D] + [0x01, 0x02, 0x03, 0x04]                  // field 1 wire 5
        mixed += pbVarintField(3, 77)
        let mixedFields = AntigravitySessionDBReader.protoFields(in: Data(mixed))
        XCTAssertEqual(mixedFields?.count, 2)
        XCTAssertEqual(mixedFields?[0].varint, 11)
        XCTAssertEqual(mixedFields?.last?.fieldNumber, 3)
        XCTAssertEqual(mixedFields?.last?.varint, 77)

        // 空输入 → 空字段序列（不是 nil）
        XCTAssertEqual(AntigravitySessionDBReader.protoFields(in: Data()), [])
    }

    func testProtoFieldsRejectsMalformedInput() {
        // group wire type（3）不可解
        XCTAssertNil(AntigravitySessionDBReader.protoFields(in: Data([0x0B])))
        // field number 0 非法
        XCTAssertNil(AntigravitySessionDBReader.protoFields(in: Data([0x00, 0x01])))
        // varint 截断（续位无后继）
        XCTAssertNil(AntigravitySessionDBReader.protoFields(in: Data([0x08, 0x80])))
        // length 越过消息末尾
        XCTAssertNil(AntigravitySessionDBReader.protoFields(in: Data([0x0A, 0x0A, 0x01, 0x02])))
        // varint 跨子消息边界（历史 trap 回归：field1 len=2 后子消息内续位 varint
        // 不得吃掉信封字节；此处子消息只作 bytes 摘取，后续 key 为 field 0 → nil）
        XCTAssertNil(
            AntigravitySessionDBReader.protoFields(
                in: Data([0x0A, 0x02, 0x12, 0x80, 0x01, 0xAA, 0xBB])
            )
        )
    }

    // MARK: - gen_metadata 行解析

    func testGeneratorMetadataEntryDecoding() throws {
        let dbURL = try makeSessionDB(
            gen: [GenRow(
                model: flashModel,
                displayName: "Gemini 3.8 Flash (Low)",
                usage: (input: 100, cacheRead: 9_000, rawOutput: 500, reasoning: 200, normalized: 300),
                attributes: [
                    (key: "model_enum", value: "MODEL_PLACEHOLDER_M319"),
                    (key: "cascade_id", value: "cascade-abc"),
                    lsi(41),
                ]
            )],
            steps: []
        )

        let entries = try AntigravitySessionDBReader.readGeneratorMetadata(dbPath: dbURL)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.idx, 1)
        XCTAssertEqual(entry.trajectoryID, trajectoryID)
        XCTAssertEqual(entry.modelName, flashModel)
        XCTAssertEqual(entry.displayName, "Gemini 3.8 Flash (Low)")
        let usage = try XCTUnwrap(entry.usage)
        XCTAssertEqual(usage.uncachedInputTokens, 100)
        XCTAssertEqual(usage.cacheReadTokens, 9_000)
        XCTAssertEqual(usage.rawOutputTokens, 500)
        XCTAssertEqual(usage.reasoningTokens, 200)
        XCTAssertEqual(usage.normalizedOutputTokens, 300)
        // spec 实测恒等式：raw output（含思考）== normalized output + reasoning
        XCTAssertEqual(usage.rawOutputTokens, usage.normalizedOutputTokens! + usage.reasoningTokens)
        XCTAssertEqual(entry.attributes["model_enum"], "MODEL_PLACEHOLDER_M319")
        XCTAssertEqual(entry.attributes["cascade_id"], "cascade-abc")
        XCTAssertEqual(entry.attributes["last_step_index"], "41")
        // 连接键来源字段：f20 map 的 last_step_index 十进制字符串 → Int
        XCTAssertEqual(entry.lastStepIndex, 41)
    }

    func testZeroValuedUsageFieldsAbsentOnWire() throws {
        // 值为 0 的字段在 wire 上常缺省：只有 f2 存在 → 其余按 0 计、f10 为 nil；
        // f4 子消息完全为空（0 字节）也视为 usage 事件（全零）。
        let base: UInt64 = 1_787_054_898
        let dbURL = try makeSessionDB(
            gen: [
                GenRow(model: flashModel, usage: (input: 42, cacheRead: 0, rawOutput: 0, reasoning: 0, normalized: nil), attributes: [lsi(0)]),
                GenRow(model: argonModel, attributes: [lsi(1)], emptyUsageSubmessage: true),
            ],
            steps: [
                StepRow(type: 15, start: (seconds: base, nanos: 0), end: (seconds: base + 1, nanos: 0)),
                StepRow(type: 15, start: (seconds: base + 2, nanos: 0), end: (seconds: base + 3, nanos: 0)),
            ]
        )

        let calls = try AntigravitySessionDBReader.readCalls(dbPath: dbURL)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].stepIndex, 1)
        XCTAssertEqual(calls[0].uncachedInputTokens, 42)
        XCTAssertEqual(calls[0].cacheReadTokens, 0)
        XCTAssertEqual(calls[0].rawOutputTokens, 0)
        XCTAssertEqual(calls[0].reasoningTokens, 0)
        XCTAssertEqual(calls[0].modelName, flashModel)
        XCTAssertEqual(calls[1].stepIndex, 2)
        XCTAssertEqual(calls[1].modelName, argonModel)
        XCTAssertNotNil(calls[1].completedAt)

        let entry = try XCTUnwrap(try AntigravitySessionDBReader.readGeneratorMetadata(dbPath: dbURL).last)
        let usage = try XCTUnwrap(entry.usage, "空 usage 子消息存在即 usage 事件")
        XCTAssertEqual(usage.uncachedInputTokens, 0)
        XCTAssertNil(usage.normalizedOutputTokens)
    }

    /// `f1.f11` timeToFirstToken（protobuf Duration）三种 wire 形态 →
    /// `Call.ttftSeconds`：完整 seconds+nanos、<1s 省略 seconds 只剩 nanos、
    /// 空子消息（proto3 双默认值缺省）→ nil；gen 行未写 f11 也 → nil。
    func testGeneratorMetadataTTFTDurationShapesReachCallTTFT() throws {
        let base: UInt64 = 1_787_054_898
        let dbURL = try makeSessionDB(
            gen: [
                // 1.669597334s（spec 实测的 seconds+nanos 完整形状）
                GenRow(model: flashModel, usage: (input: 10, cacheRead: 0, rawOutput: 5, reasoning: 0, normalized: nil),
                       attributes: [lsi(0)],
                       ttft: .secondsAndNanos(seconds: 1, nanos: 669_597_334)),
                // <1s：proto3 省略 seconds，wire 上只剩 nanos（864ms）
                GenRow(model: argonModel, usage: (input: 10, cacheRead: 0, rawOutput: 5, reasoning: 0, normalized: nil),
                       attributes: [lsi(1)],
                       ttft: .nanosOnly(864_000_000)),
                // 空子消息：两个默认值字段都缺省 → 视为未提供
                GenRow(model: flashModel, usage: (input: 10, cacheRead: 0, rawOutput: 5, reasoning: 0, normalized: nil),
                       attributes: [lsi(2)],
                       ttft: .empty),
                // 不写 f11：上游未提供 → nil
                GenRow(model: argonModel, usage: (input: 10, cacheRead: 0, rawOutput: 5, reasoning: 0, normalized: nil),
                       attributes: [lsi(3)]),
            ],
            steps: (0..<4).map { offset in
                StepRow(
                    type: 15,
                    start: (seconds: base + UInt64(offset) * 10, nanos: 0),
                    end: (seconds: base + UInt64(offset) * 10 + 6, nanos: 0)
                )
            }
        )

        let calls = try AntigravitySessionDBReader.readCalls(dbPath: dbURL)
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls[0].ttftSeconds!, 1.669597334, accuracy: 1e-9, "seconds + nanos 完整 Duration")
        XCTAssertEqual(calls[1].ttftSeconds!, 0.864, accuracy: 1e-9, "<1s 只有 nanos：按 0 秒 + nanos 处理")
        XCTAssertNil(calls[2].ttftSeconds, "空 Duration 子消息 → 未提供")
        XCTAssertNil(calls[3].ttftSeconds, "gen 行未写 f11 → 未提供")
        // TTFT 与 steps 差分时长相互独立：f11 缺失不影响 durationSeconds。
        XCTAssertEqual(calls[2].durationSeconds!, 6.0, accuracy: 1e-9)
    }

    // MARK: - steps 读取

    func testStepReadingSeparatesLLMCallsAndUserTurns() throws {
        let base: UInt64 = 1_787_054_898
        let dbURL = try makeSessionDB(
            gen: [],
            steps: [
                StepRow(type: 14, start: (seconds: base, nanos: 0)),                       // 用户轮次
                StepRow(type: 15, start: (seconds: base + 10, nanos: 123_000_000),
                        end: (seconds: base + 22, nanos: 623_000_000)),                    // LLM call
                StepRow(type: 8, start: (seconds: base + 30, nanos: 0)),                   // 工具结果，忽略
                StepRow(type: 15, nullMetadata: true),                                     // NULL metadata 仍占 idx
                StepRow(type: 15, garbageMetadata: true),                                  // 不可解析 metadata 仍占 idx
            ]
        )

        let llmSteps = try AntigravitySessionDBReader.readLLMCallSteps(dbPath: dbURL)
        XCTAssertEqual(llmSteps.count, 3, "step_type=15 才是 LLM call，其余类型不进该序列")
        XCTAssertEqual(llmSteps[0].idx, 2)
        XCTAssertEqual(llmSteps[0].startedAtSeconds ?? 0, Double(base) + 10.123, accuracy: 0.000_001)
        XCTAssertEqual(llmSteps[0].completedAtSeconds ?? 0, Double(base) + 22.623, accuracy: 0.000_001)
        XCTAssertNil(llmSteps[1].startedAtSeconds)
        XCTAssertNil(llmSteps[1].completedAtSeconds)
        XCTAssertNil(llmSteps[2].startedAtSeconds)

        let turnSteps = try AntigravitySessionDBReader.readUserTurnSteps(dbPath: dbURL)
        XCTAssertEqual(turnSteps.count, 1)
        XCTAssertEqual(turnSteps[0].idx, 1)
        XCTAssertEqual(turnSteps[0].startedAt?.timeIntervalSince1970 ?? 0, Double(base), accuracy: 0.000_001)
    }

    func testTimestampParseRejectsOutOfRangeValues() {
        let base: UInt64 = 1_787_054_898
        // nanos 越域（≥ 1e9）
        let badNanos = Data(pbLenField(1, pbTimestamp(seconds: base, nanos: 1_000_000_000)))
        XCTAssertNil(AntigravitySessionDBReader.parseStepTimestamps(metadata: badNanos).startedAt)
        // epoch 早于 2000
        let ancient = Data(pbLenField(1, pbTimestamp(seconds: 946_684_799, nanos: 0)))
        XCTAssertNil(AntigravitySessionDBReader.parseStepTimestamps(metadata: ancient).startedAt)
        // epoch ≥ 2100
        let future = Data(pbLenField(1, pbTimestamp(seconds: 4_102_444_800, nanos: 0)))
        XCTAssertNil(AntigravitySessionDBReader.parseStepTimestamps(metadata: future).startedAt)
        // 只有 field 7：startedAt nil、completedAt 正常
        let endOnly = Data(pbLenField(7, pbTimestamp(seconds: base, nanos: 500_000_000)))
        let parsed = AntigravitySessionDBReader.parseStepTimestamps(metadata: endOnly)
        XCTAssertNil(parsed.startedAt)
        XCTAssertEqual(parsed.completedAt?.timeIntervalSince1970 ?? 0, Double(base) + 0.5, accuracy: 0.000_001)
        // NULL / 空 / 乱数据 metadata → 双 nil
        XCTAssertNil(AntigravitySessionDBReader.parseStepTimestamps(metadata: nil).startedAt)
        XCTAssertNil(AntigravitySessionDBReader.parseStepTimestamps(metadata: Data()).completedAt)
        XCTAssertNil(
            AntigravitySessionDBReader.parseStepTimestamps(metadata: Data([0x0A, 0x7F, 0x99])).completedAt
        )
    }

    // MARK: - last_step_index 连接（2026-11-08 实测校准）

    func testDualModelSwitchSequencePairing() throws {
        let base: UInt64 = 1_787_054_898
        // 切换序列：flash-n ×2 → argon ×2 → flash-n ×1（run-length 与 spec 实测的
        // 「双模型切换完全一致」同构）。gen 行 lsi = 1+offset，连接到 steps idx
        // 2..6（turn 行占 idx 1）——gen idx 与 steps idx 值刻意不同，证明配对按
        // 连接键而非 idx 相等。
        let models = [flashModel, flashModel, argonModel, argonModel, flashModel]
        let gen = models.enumerated().map { offset, model in
            GenRow(
                model: model,
                displayName: "Gemini",
                usage: (
                    input: UInt64(100 + offset),
                    cacheRead: UInt64(1_000 * (offset + 1)),
                    rawOutput: UInt64(300 + offset),
                    reasoning: UInt64(100 + offset),
                    normalized: UInt64(200)
                ),
                attributes: [lsi(UInt64(1 + offset))]
            )
        }
        let steps: [StepRow] = [StepRow(type: 14, start: (seconds: base, nanos: 0))]
            + (0..<5).map { offset in
                StepRow(
                    type: 15,
                    start: (seconds: base + 60 + UInt64(offset) * 10, nanos: 250_000_000),
                    end: (seconds: base + 66 + UInt64(offset) * 10, nanos: 750_000_000)
                )
            }
        let dbURL = try makeSessionDB(gen: gen, steps: steps)

        let calls = try AntigravitySessionDBReader.readCalls(dbPath: dbURL)
        XCTAssertEqual(calls.count, 5)
        // 模型切换序列与 sessionID 一致性
        XCTAssertEqual(calls.map(\.modelName), models)
        XCTAssertTrue(calls.allSatisfy { $0.sessionID == trajectoryID })
        // 连接：stepIndex == lsi + 1 == steps 序列的第 i 个 LLM 行 idx（2..6）
        XCTAssertEqual(calls.map(\.stepIndex), [2, 3, 4, 5, 6])
        XCTAssertEqual(calls.map(\.genIndex), [1, 2, 3, 4, 5])
        for (offset, call) in calls.enumerated() {
            XCTAssertEqual(call.uncachedInputTokens, 100 + offset)
            XCTAssertEqual(call.cacheReadTokens, 1_000 * (offset + 1))
            XCTAssertEqual(call.rawOutputTokens, 300 + offset)
            XCTAssertEqual(call.reasoningTokens, 100 + offset)
            let expectedDuration = 6.5  // (66+0.75) − (60+0.25)
            XCTAssertEqual(call.durationSeconds ?? 0, expectedDuration, accuracy: 0.000_001)
            XCTAssertEqual(
                call.startedAt?.timeIntervalSince1970 ?? 0,
                Double(base) + 60 + Double(offset) * 10 + 0.25,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                call.completedAt?.timeIntervalSince1970 ?? 0,
                Double(base) + 66 + Double(offset) * 10 + 0.75,
                accuracy: 0.000_001
            )
        }
    }

    /// 实测反例形态（会话 22b4f174：gen_idx=22,23,24,25,26,30 六条无模型名副调用
    /// 条目穿插在正常事件中间）：副调用行**有 usage** 但无 f19，其
    /// last_step_index + 1 不在 steps 表中；它们不消费任何 step——后续事件的
    /// 时间戳/时长绝不错位。
    func testSideCallWithoutModelNameSkippedAndTimestampsNotShifted() throws {
        let base: UInt64 = 1_787_054_898
        let dbURL = try makeSessionDB(
            gen: [
                GenRow(idx: 21, model: flashModel,
                       usage: (input: 10, cacheRead: 0, rawOutput: 30, reasoning: 10, normalized: 20),
                       attributes: [lsi(20)]),
                // 副调用（实测形态）：无模型名、有 usage、lsi+1=22 不在 steps
                GenRow(idx: 22, model: nil,
                       usage: (input: 99, cacheRead: 99, rawOutput: 99, reasoning: 99, normalized: nil),
                       attributes: [lsi(21)]),
                GenRow(idx: 23, model: flashModel,
                       usage: (input: 20, cacheRead: 5, rawOutput: 60, reasoning: 20, normalized: 40),
                       attributes: [lsi(22)]),
                // 无模型名但 lsi+1=23 **在** steps 中：仍按「无模型名」整条跳过，
                // 且不得提前消费 step 23（模型名判定先于连接）
                GenRow(idx: 24, model: nil,
                       usage: (input: 88, cacheRead: 88, rawOutput: 88, reasoning: 88, normalized: nil),
                       attributes: [lsi(22)]),
            ],
            steps: [
                StepRow(idx: 21, type: 15, start: (seconds: base, nanos: 0), end: (seconds: base + 3, nanos: 0)),
                // idx 22 缺失：真实库 steps idx 有空洞（非 LLM step 占用）
                StepRow(idx: 23, type: 15, start: (seconds: base + 20, nanos: 0), end: (seconds: base + 25, nanos: 500_000_000)),
            ]
        )

        let calls = try AntigravitySessionDBReader.readCalls(dbPath: dbURL)
        XCTAssertEqual(calls.count, 2, "无模型名的副调用条目整条跳过")
        XCTAssertEqual(calls[0].genIndex, 21)
        XCTAssertEqual(calls[0].stepIndex, 21)
        XCTAssertEqual(calls[0].durationSeconds ?? 0, 3, accuracy: 0.000_001)
        XCTAssertEqual(calls[1].genIndex, 23)
        XCTAssertEqual(calls[1].stepIndex, 23, "连接按 last_step_index+1，副调用不推移序位")
        // 时间戳不错位：第二个事件取 step 23 的时刻（25.5s），不是第一个 step 的
        XCTAssertEqual(
            calls[1].completedAt?.timeIntervalSince1970 ?? 0,
            Double(base) + 25.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(calls[1].durationSeconds ?? 0, 5.5, accuracy: 0.000_001)
        // 副调用的 token（99/88）不计入
        XCTAssertEqual(calls.map(\.cacheReadTokens), [0, 5])
    }

    func testUnparseableGenRowDroppedAndJoinUnaffected() throws {
        // 乱数据 gen 行是占位 entry（只带 idx）：无模型名 → 被连接条件整条跳过，
        // 后面的 usage 行仍按自己的 last_step_index+1 连接自己的 step。
        let base: UInt64 = 1_787_054_898
        let dbURL = try makeSessionDB(
            gen: [
                GenRow(idx: 30, rawData: [0x0A, 0x7F]),  // 顶层 length 越界 → 不可解码
                GenRow(idx: 31, model: flashModel,
                       usage: (input: 7, cacheRead: 0, rawOutput: 9, reasoning: 3, normalized: 6),
                       attributes: [lsi(31)]),
            ],
            steps: [
                StepRow(idx: 32, type: 15, start: (seconds: base, nanos: 0), end: (seconds: base + 2, nanos: 0)),
            ]
        )

        let entries = try AntigravitySessionDBReader.readGeneratorMetadata(dbPath: dbURL)
        XCTAssertEqual(entries.count, 2)
        XCTAssertNil(entries[0].usage)
        XCTAssertNil(entries[0].modelName)
        XCTAssertNil(entries[0].trajectoryID)
        XCTAssertNil(entries[0].lastStepIndex)
        XCTAssertEqual(entries[0].attributes, [:])

        let calls = try AntigravitySessionDBReader.readCalls(dbPath: dbURL)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].genIndex, 31)
        XCTAssertEqual(calls[0].stepIndex, 32)
        XCTAssertEqual(calls[0].durationSeconds ?? 0, 2, accuracy: 0.000_001)
        XCTAssertEqual(calls[0].uncachedInputTokens, 7)
    }

    func testJoinMissAndMissingLastStepIndexDropEntries() throws {
        // 连接不命中（lsi+1 无对应 step 行）与 last_step_index 缺失的行都整条
        // 丢弃：不保留占位、不产生无时间戳样本。
        let base: UInt64 = 1_787_054_898
        let dbURL = try makeSessionDB(
            gen: [
                GenRow(model: flashModel,
                       usage: (input: 1, cacheRead: 2, rawOutput: 3, reasoning: 1, normalized: 2),
                       attributes: [lsi(0)]),
                GenRow(idx: 2, model: argonModel,
                       usage: (input: 4, cacheRead: 5, rawOutput: 6, reasoning: 2, normalized: 4),
                       attributes: [lsi(5)]),  // lsi+1=6 无 step 行 → 丢弃
                GenRow(model: flashModel,
                       usage: (input: 7, cacheRead: 8, rawOutput: 9, reasoning: 3, normalized: 6)),  // 无 lsi → 丢弃
            ],
            steps: [
                StepRow(idx: 1, type: 15, start: (seconds: base, nanos: 0), end: (seconds: base + 1, nanos: 0)),
            ]
        )

        let calls = try AntigravitySessionDBReader.readCalls(dbPath: dbURL)
        XCTAssertEqual(calls.count, 1, "连接不命中与 lsi 缺失的行不产生样本")
        XCTAssertEqual(calls[0].genIndex, 1)
        XCTAssertEqual(calls[0].stepIndex, 1)
        XCTAssertEqual(calls[0].modelName, flashModel)
        XCTAssertEqual(calls[0].uncachedInputTokens, 1)
        XCTAssertEqual(calls[0].cacheReadTokens, 2)
        XCTAssertEqual(calls[0].durationSeconds ?? 0, 1, accuracy: 0.000_001)
        XCTAssertFalse(calls.contains { $0.modelName == argonModel }, "被丢弃行的 token 不计入")
    }

    func testStepIndexCollisionFirstGenRowWins() throws {
        // 两条 gen 行连到同一 step（健康数据不会出现）：先到先得，后者丢弃，
        // 避免 step 时间戳被重复计入两个 round。
        let base: UInt64 = 1_787_054_898
        let dbURL = try makeSessionDB(
            gen: [
                GenRow(model: flashModel,
                       usage: (input: 10, cacheRead: 0, rawOutput: 30, reasoning: 10, normalized: 20),
                       attributes: [lsi(0)]),
                GenRow(model: argonModel,
                       usage: (input: 20, cacheRead: 0, rawOutput: 60, reasoning: 20, normalized: 40),
                       attributes: [lsi(0)]),
            ],
            steps: [
                StepRow(idx: 1, type: 15, start: (seconds: base, nanos: 0), end: (seconds: base + 1, nanos: 0)),
            ]
        )

        let calls = try AntigravitySessionDBReader.readCalls(dbPath: dbURL)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].modelName, flashModel)
        XCTAssertEqual(calls[0].uncachedInputTokens, 10)
        XCTAssertEqual(calls[0].stepIndex, 1)
    }

    // MARK: - probe

    func testProbeViableOnSyntheticSessionDB() throws {
        let dbURL = try makeSessionDB(
            gen: [GenRow(model: flashModel, usage: (input: 1, cacheRead: 0, rawOutput: 1, reasoning: 0, normalized: 1))],
            steps: [StepRow(type: 15)]
        )
        XCTAssertEqual(try AntigravitySessionDBReader.probe(dbPath: dbURL), .viable)
    }

    func testProbeFailsOnMissingGenMetadataTable() throws {
        let dbURL = try makeSessionDB(gen: [], steps: [StepRow(type: 15)], includeGenTable: false)
        let viability = try AntigravitySessionDBReader.probe(dbPath: dbURL)
        XCTAssertEqual(viability, .incompatible(reason: AntigravitySessionDBReader.reasonMissingGenMetadataTable))
    }

    func testProbeFailsOnEmptyGenMetadataTable() throws {
        let dbURL = try makeSessionDB(gen: [], steps: [])
        let viability = try AntigravitySessionDBReader.probe(dbPath: dbURL)
        XCTAssertEqual(viability, .incompatible(reason: AntigravitySessionDBReader.reasonEmptyGenMetadataTable))
    }

    func testProbeFailsOnGarbageFirstRow() throws {
        let dbURL = try makeSessionDB(
            gen: [
                GenRow(rawData: [0x0A, 0x7F, 0x99]),
                GenRow(model: flashModel, usage: (input: 1, cacheRead: 0, rawOutput: 1, reasoning: 0, normalized: 1)),
            ],
            steps: []
        )
        let viability = try AntigravitySessionDBReader.probe(dbPath: dbURL)
        XCTAssertEqual(viability, .incompatible(reason: AntigravitySessionDBReader.reasonUndecodableFirstRow))
    }

    func testProbeFailsWhenFirstRowHasNoModelName() throws {
        // 可解码、带 usage、但没有 f1.f19 模型名 → 不满足「首行解出 f19」门槛
        let dbURL = try makeSessionDB(
            gen: [GenRow(usage: (input: 1, cacheRead: 0, rawOutput: 1, reasoning: 0, normalized: 1))],
            steps: []
        )
        let viability = try AntigravitySessionDBReader.probe(dbPath: dbURL)
        XCTAssertEqual(viability, .incompatible(reason: AntigravitySessionDBReader.reasonNoModelNameInFirstRow))
    }

    func testProbeFailsOnNonSQLiteFile() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-session-garbage-\(UUID().uuidString).db")
        addTeardownBlock { try? FileManager.default.removeItem(at: dbURL) }
        try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01]).write(to: dbURL)

        let viability = try AntigravitySessionDBReader.probe(dbPath: dbURL)
        guard case .incompatible(let reason) = viability else {
            return XCTFail("非 SQLite 文件必须 incompatible，实际 \(viability)")
        }
        XCTAssertTrue(reason.hasPrefix("sqlite:"), "I/O 层失败折进 sqlite: 前缀 reason，实际 \(reason)")
    }

    func testProbeClassifiesPermissionFailureAsRetryable() throws {
        // 撤销读权限（mtime/size 不变的瞬时 I/O 故障形态）：probe 必须折进
        // `.retryable`（同字节下一轮可能读成功），而不是 `.incompatible`——
        // 后者会让调用方当轮采纳指纹收敛、把会话钉在漏计状态。
        let dbURL = try makeSessionDB(
            gen: [GenRow(model: flashModel, usage: (input: 1, cacheRead: 0, rawOutput: 1, reasoning: 0, normalized: 1))],
            steps: [StepRow(type: 15)]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dbURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbURL.path)
        }

        let viability = try AntigravitySessionDBReader.probe(dbPath: dbURL)
        guard case .retryable(let reason) = viability else {
            return XCTFail("权限类失败必须 retryable，实际 \(viability)")
        }
        XCTAssertTrue(reason.hasPrefix("sqlite:"), "折叠失败同样以 sqlite: 前缀携带摘要，实际 \(reason)")
    }

    // MARK: - SQLite 纪律与错误传播

    func testReaderThrowsWhenGenMetadataTableMissing() throws {
        // probe 不过的文件不得解读：读取 API 对表缺失抛 SQLiteConnectionError，
        // 由调用方的 probe 门与既有错误路径处理。
        let dbURL = try makeSessionDB(gen: [], steps: [StepRow(type: 15)], includeGenTable: false)
        XCTAssertThrowsError(try AntigravitySessionDBReader.readCalls(dbPath: dbURL))
        XCTAssertThrowsError(try AntigravitySessionDBReader.readGeneratorMetadata(dbPath: dbURL))
    }

    func testOpensOriginalPathReadOnlyAndTempCopyWritable() {
        // 与 AntigravityStepTimestampReader 同一纪律：原路径 READONLY、
        // SQLiteTempCopy /tmp 副本 READWRITE（副本上可能需 WAL recovery）。
        let original = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-session-db-original-\(UUID().uuidString).db")
        XCTAssertTrue(AntigravitySessionDBReader.opensReadOnly(dbPath: original))
        let tempCopy = SQLiteTempCopy.appTempDir()
            .appendingPathComponent("\(UUID().uuidString).db")
        XCTAssertFalse(AntigravitySessionDBReader.opensReadOnly(dbPath: tempCopy))
    }
}
