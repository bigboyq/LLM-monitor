import Foundation
import SQLite3

/// Antigravity 会话 `.db`（`~/.gemini/antigravity/conversations/<uuid>.db`，SQLite
/// WAL）直接读取模块 —— 阶段二b 起是 `AntigravityLocalUsageScanner` 的唯一
/// token/模型/时间戳/轮次数据源（本地 RPC / 进程发现 / `.pb` 已退役）。
///
/// 数据事实源：`spec/providers/antigravity.md` § Token & model data ARE in `.db`
/// `gen_metadata`（2026-11-08 实测，IDE 2.29.0）。`gen_metadata` 每行对应一次 LLM
/// call，`data` 为 protobuf；`steps` 表 `step_type=15` 行的 `metadata` 携带发起
///（field 1）与流式完成（field 7）两个 Timestamp（`spec/harnesses/agy.md`
/// § 单次调用时长 方案 A）。gen 行 ↔ `step_type=15` 行的连接键是
/// **`steps.idx == gen.f20.last_step_index + 1`**（2026-11-08 用会话 22b4f174 实测
/// 校准：含模型名的 102 行 102/102 命中、零冲突零遗漏 steps15 行；早期「各自按
/// idx 升序后按序号配对」的推断被真实数据推翻——gen 侧 6 条无模型名的后台/副调用
/// 条目会把序号整体推移，其后所有事件的时间戳/时长错位）。
///
/// **版本敏感**：schema 随 IDE 版本演进（2026-07 的版本完全没有 token 数据），任何
/// 读取前必须先 `probe(dbPath:)`；probe 不过的文件不得解读。无模型名（f19 缺失/
/// 空串）或连接不命中的 gen 行整条跳过——其 token 不计入，与当前 RPC 路径口径
/// 一致（实测会话 cache rounds=102 两侧一致）。
///
/// **SQLite 纪律**：所有公共入口内部经 `SQLiteTempCopy.read` 打开——原路径
/// READONLY（immutable 快路径 + CANTOPEN/BUSY 时 /tmp 副本兜底），与
/// `AntigravityStepTimestampReader` 的调用纪律同一套。
enum AntigravitySessionDBReader {
    /// SQLiteTempCopy 回退日志前缀。
    static let defaultLogTag = "[antigravity-session-db]"

    // MARK: - 行结构

    /// gen_metadata 单行（一次 LLM call）解析出的结构化 entry。
    ///
    /// `data` blob 缺失或无法解析时除 `idx` 外全 nil——该行随后被连接条件
    ///（模型名 + last_step_index + steps 命中）自然跳过，不影响其他行。
    ///
    /// **f11 已证伪（2026-11-08 实测，勿再接入）**：调研曾把 blob `f1.f11` 当
    /// TTFT、`f1.f12` 当 streaming 接入；本机 Antigravity 库（201 gen 行）实测
    /// f11 占 f11+f12 的 97~100%（P50 99%）、f12 仅 0.01~0.18s——对数百 tok 的
    /// 输出「流式 0.18s」物理不成立。结论：**f11 实为整段调用时长（与 steps
    /// 差分同义）、f12≈0**，不是 TTFT/streaming 对。本 reader 不解析 f11/f12；
    /// 单次调用时长一律取 steps.metadata f7−f1（`Call.durationSeconds`）。
    struct GeneratorMetadataEntry: Equatable, Sendable {
        /// usage 子消息（`f1.f4`）。**子消息存在即视为 usage 事件**（即使全零）；
        /// 值为 0 的字段在 wire 上常缺省，缺省按 0 计；cacheWrite 不在其中。
        /// 子消息存在但不可解析时按不存在处理（该行被当副调用过滤）。
        struct Usage: Equatable, Sendable {
            /// `f2`：uncached input
            let uncachedInputTokens: Int
            /// `f5`：cacheRead
            let cacheReadTokens: Int
            /// `f3`：raw output（**含思考**，实测恒等 f10 + f9）
            let rawOutputTokens: Int
            /// `f9`：reasoning
            let reasoningTokens: Int
            /// `f10`：normalized output（raw − reasoning）；字段缺省时 nil（诊断用，
            /// 参与恒等断言，不参与四桶）
            let normalizedOutputTokens: Int?
        }

        /// gen_metadata.idx
        let idx: Int
        /// 顶层 `f4`：trajectory UUID（= 会话 ID）
        let trajectoryID: String?
        /// `f1.f19`：模型名字符串（如 `gemini-3.8-flash-n`）
        let modelName: String?
        /// `f1.f21`：显示名（如 `Gemini 3.8 Flash (Low)`）
        let displayName: String?
        let usage: Usage?
        /// `f1.f20`：string→string map（model_enum / cascade_id / root_cascade_id /
        /// trajectory_id / request_id / used_claude / …），同键以最后一次出现为准。
        let attributes: [String: String]
        /// `f1.f20` map 的 `last_step_index`（十进制字符串 → Int；缺失 / 不可解析
        /// 为 nil）。连接键 = `steps.idx == lastStepIndex + 1`；nil 的行不产生 Call。
        let lastStepIndex: Int?
    }

    /// steps 表 `step_type=15` 行（LLM call）的双 Timestamp。metadata 缺失或时间戳
    /// 不可解析时对应值为 nil，**行本身仍占配对序位**。
    struct LLMCallStep: Equatable, Sendable {
        /// steps.idx
        let idx: Int
        /// metadata field 1（发起时刻），epoch 秒
        let startedAtSeconds: Double?
        /// metadata field 7（流式完成时刻），epoch 秒
        let completedAtSeconds: Double?
    }

    /// steps 表 `step_type=14` 行（用户轮次边界）。
    struct UserTurnStep: Equatable, Sendable {
        /// steps.idx
        let idx: Int
        /// metadata field 1（发起时刻）
        let startedAt: Date?
    }

    /// gen 行 ↔ `step_type=15` 行经 `steps.idx == last_step_index + 1` 连接后的
    /// 单次 LLM call。
    ///
    /// `LocalTokenUsageSample` 友好的中间结构：token 四桶是 **raw 口径**，接线方
    /// （阶段二b）经 `TokenAccountingCatalog.antigravity.normalizedBuckets` 规范化后
    /// 落 `LocalTokenUsageSample`（与 RPC 路径 `AntigravityLocalUsageAggregation
    /// .makeSample` 同一入口）。
    struct Call: Equatable, Sendable {
        /// 会话 ID（gen 顶层 `f4` trajectory UUID）
        let sessionID: String?
        /// gen_metadata.idx
        let genIndex: Int
        /// 连接命中的 steps.idx（step_type=15，== lastStepIndex + 1）。Call 只从
        /// 连接命中产生，恒有值。
        let stepIndex: Int
        let modelName: String?
        let uncachedInputTokens: Int
        let cacheReadTokens: Int
        /// 含思考的 raw output（raw == normalized + reasoning）
        let rawOutputTokens: Int
        let reasoningTokens: Int
        /// steps metadata field 1（发起）
        let startedAt: Date?
        /// steps metadata field 7（流式完成）
        let completedAt: Date?
        /// completedAt − startedAt（秒）。任一端缺失时 nil；可能为负（时钟回拨），
        /// 调用方按 (0, 3600] 有效域过滤（与窗口 token 速度过滤同口径，见
        /// `spec/harnesses/agy.md` § 单次调用时长）。
        let durationSeconds: Double?
    }

    // MARK: - probe（版本指纹门）

    /// probe 结论。失败按错误类别二分（调用方据此决定失败轮的收敛策略）：
    enum Viability: Equatable {
        /// gen_metadata 表存在且首行解出非空模型名字符串 → 文件模式可用。
        case viable
        /// **结构化不兼容**（gen_metadata 表缺失/空表、首行乱数据、无模型名、
        /// 非 SQLite 文件）：由文件字节内容决定，同一份字节重探结果恒定 →
        /// 调用方可采纳当前文件指纹收敛、下轮不再重读。
        case incompatible(reason: String)
        /// **可重试故障**（SQLite 打开 / `/tmp` 拷贝 / 查询 I/O 类：权限、锁、
        /// EIO、快照期源变化等瞬时故障）：同一份字节下一轮可能读成功 →
        /// 调用方应保留脏状态重试（见 scanner 的有界收敛）。
        case retryable(reason: String)
    }

    /// `.incompatible` 的结构化原因字面量（internal：测试与调用方诊断共用）。
    static let reasonMissingGenMetadataTable = "gen_metadata table missing"
    static let reasonEmptyGenMetadataTable = "gen_metadata table is empty"
    static let reasonUndecodableFirstRow = "first gen_metadata row is not decodable as protobuf"
    static let reasonNoModelNameInFirstRow = "first gen_metadata row carries no model name (f1.f19)"

    /// 版本指纹探测：`gen_metadata` 表存在 + 首行（idx 最小）能解出非空 `f1.f19`
    /// 模型名字符串 → `.viable`；数据形态类失败 → `.incompatible(reason:)`；
    /// I/O 类失败 → `.retryable(reason:)`。
    ///
    /// 除 `CancellationError`（原样上抛，绝不把取消伪装成数据结论）外**不抛错**：
    /// probe 内部的一切失败都折进两个失败 case，reason 以 `sqlite:` 前缀携带
    /// 错误摘要——非 `.viable` 只代表「本轮不可用，原因与类别见结果」，调用方
    /// 据此决定收敛或重试。
    static func probe(dbPath: URL, logTag: String = defaultLogTag) throws -> Viability {
        do {
            return try SQLiteTempCopy.read(dbPath: dbPath, logTag: logTag) { url in
                let connection = try SQLiteConnection(path: url, readOnly: opensReadOnly(dbPath: url))
                defer { connection.close() }
                return try probeOpen(connection: connection)
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            return classifyFoldedFailure(error)
        }
    }

    /// probe 折叠失败的类别判定：**数据形态错误**（SQLite 主码 NOTADB(26)——文件
    /// 本身不是 SQLite 库）由字节内容决定、同字节重探结果恒定，归
    /// `.incompatible`；其余（CANTOPEN / IOERR / BUSY 等打开与查询 I/O、
    /// `/tmp` 拷贝的 posix 权限错误、快照期源变化等）归 `.retryable`——同一份
    /// 字节下一轮可能读成功。CORRUPT 有意归 retryable：并发 checkpoint 撕裂页
    /// 重拷即自愈（`SQLiteTempCopy` 同款裁定），按结构化收敛会永久跳过可恢复
    /// 的 session。误分类的代价有界：误判 retryable 最多多试
    /// `AntigravityLocalUsageScanner.retryableReadFailureConvergenceLimit` 轮；
    /// 误判 incompatible 由「文件再变化即重读」兜底。
    private static func classifyFoldedFailure(_ error: Error) -> Viability {
        if isDataShapeError(error) {
            return .incompatible(reason: reasonSQLite(error))
        }
        return .retryable(reason: reasonSQLite(error))
    }

    /// 错误是否为数据形态错误（SQLite 主码 NOTADB=26）。private：分类策略只
    /// 属于 probe 的折叠路径；非 SQLiteConnectionError（posix / 快照错误等）
    /// 一律不算数据形态错误。
    private static func isDataShapeError(_ error: Error) -> Bool {
        guard let sqliteError = error as? SQLiteConnectionError else { return false }
        switch sqliteError {
        case .openFailed(_, let code, _, _),
             .prepareFailed(let code, _, _, _),
             .stepFailed(let code, _, _):
            return code & 0xFF == SQLITE_NOTADB
        case .bindFailed, .nullColumn, .lostImmutableRace:
            return false
        }
    }

    private static func probeOpen(connection: SQLiteConnection) throws -> Viability {
        let tables = try connection.query(
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'gen_metadata'",
            map: { try SQLiteConnection.requiredText($0, column: 0) }
        )
        guard !tables.isEmpty else {
            return .incompatible(reason: reasonMissingGenMetadataTable)
        }
        let rows = try connection.query(
            sql: "SELECT data FROM gen_metadata ORDER BY idx ASC LIMIT 1",
            map: { statement -> Data? in
                guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
                      let blob = sqlite3_column_blob(statement, 0) else {
                    return nil
                }
                return Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
            }
        )
        guard let data = rows.first else {
            return .incompatible(reason: reasonEmptyGenMetadataTable)
        }
        // blob 不可解码与解码后无 f19 共用一条结论：两者都说明这不是 2026-11-08
        // 实测的 gen_metadata 形态，模式不可用。
        let entry = parseGeneratorMetadataEntry(idx: 0, data: data)
        guard entry.modelName != nil else {
            if entry.trajectoryID == nil, entry.displayName == nil, entry.attributes.isEmpty {
                return .incompatible(reason: reasonUndecodableFirstRow)
            }
            return .incompatible(reason: reasonNoModelNameInFirstRow)
        }
        return .viable
    }

    // MARK: - 读取 API

    /// 读全部 gen_metadata 行（idx 升序）。表缺失 / I/O 失败照常抛
    /// `SQLiteConnectionError`——调用方应先 `probe`。
    static func readGeneratorMetadata(
        dbPath: URL,
        logTag: String = defaultLogTag
    ) throws -> [GeneratorMetadataEntry] {
        try SQLiteTempCopy.read(dbPath: dbPath, logTag: logTag) { url in
            let connection = try SQLiteConnection(path: url, readOnly: opensReadOnly(dbPath: url))
            defer { connection.close() }
            return try readGeneratorMetadataEntries(connection: connection)
        }
    }

    /// 读全部 `step_type=15` 行（idx 升序），metadata 双时间戳折成 epoch 秒。
    static func readLLMCallSteps(
        dbPath: URL,
        logTag: String = defaultLogTag
    ) throws -> [LLMCallStep] {
        try SQLiteTempCopy.read(dbPath: dbPath, logTag: logTag) { url in
            let connection = try SQLiteConnection(path: url, readOnly: opensReadOnly(dbPath: url))
            defer { connection.close() }
            return try readLLMCallSteps(connection: connection)
        }
    }

    /// 读全部 `step_type=14` 行（idx 升序，用户轮次边界）。
    static func readUserTurnSteps(
        dbPath: URL,
        logTag: String = defaultLogTag
    ) throws -> [UserTurnStep] {
        try SQLiteTempCopy.read(dbPath: dbPath, logTag: logTag) { url in
            let connection = try SQLiteConnection(path: url, readOnly: opensReadOnly(dbPath: url))
            defer { connection.close() }
            return try readUserTurnSteps(connection: connection)
        }
    }

    /// gen 行 ↔ `step_type=15` 行按连接键 `steps.idx == gen.f20.last_step_index + 1`
    /// 连接，产出事件 `Call` 序列。一次开库完成两侧读取；事件集与丢弃规则见
    /// `pair(entries:steps:)`。
    static func readCalls(dbPath: URL, logTag: String = defaultLogTag) throws -> [Call] {
        try SQLiteTempCopy.read(dbPath: dbPath, logTag: logTag) { url in
            let connection = try SQLiteConnection(path: url, readOnly: opensReadOnly(dbPath: url))
            defer { connection.close() }
            return pair(
                entries: try readGeneratorMetadataEntries(connection: connection),
                steps: try readLLMCallSteps(connection: connection)
            )
        }
    }

    /// 纯连接（internal：测试接缝）。
    ///
    /// 事件集 = 「有非空模型名（f19）**且** usage 子消息存在**且** 连接命中」的
    /// gen 行；其余整条丢弃（不保留占位、不产生无时间戳样本）。丢弃规则逐条：
    ///
    /// - 无模型名的行跳过——实测的后台/副调用条目（会话 22b4f174 的 gen_idx
    ///   22–26/30：有 usage、无 f19、`last_step_index + 1` 不在 steps 表中，也
    ///   没有自己的 step 行），其 token 不计入，与当前 RPC 路径口径一致
    ///  （cache rounds=102 两侧一致）；
    /// - `last_step_index` 缺失 / 不可解析，或 `+1` 没有对应 step_type=15 行
    ///   （连接不命中）→ 条目丢弃；
    /// - 两条 gen 行连到同一 step（冲突，健康数据不会出现）→ 先到先得，后者丢弃，
    ///   避免 step 时间戳被重复计入两个 round；
    /// - usage 子消息缺失的行跳过（RPC 侧「无 token 数据的事件」同款跳过，
    ///   避免纯零桶样本虚增 rounds）。
    ///
    /// 输出按 entries 传入顺序（即 gen idx 升序 = 时间序）。
    static func pair(
        entries: [GeneratorMetadataEntry],
        steps: [LLMCallStep]
    ) -> [Call] {
        var stepsByIndex: [Int: LLMCallStep] = [:]
        stepsByIndex.reserveCapacity(steps.count)
        for step in steps where stepsByIndex[step.idx] == nil {
            stepsByIndex[step.idx] = step
        }

        var claimedStepIndexes = Set<Int>()
        claimedStepIndexes.reserveCapacity(steps.count)
        var calls: [Call] = []
        calls.reserveCapacity(entries.count)
        for entry in entries {
            guard let modelName = entry.modelName, !modelName.isEmpty else { continue }
            guard let usage = entry.usage else { continue }
            guard let lastStepIndex = entry.lastStepIndex else { continue }
            // last_step_index + 1 用报告溢出加法：畸形大数值不得 trap，走连接不命中。
            let nextStepIndex = lastStepIndex.addingReportingOverflow(1)
            guard !nextStepIndex.overflow,
                  let step = stepsByIndex[nextStepIndex.partialValue],
                  !claimedStepIndexes.contains(step.idx) else { continue }
            claimedStepIndexes.insert(step.idx)

            let startedAt = step.startedAtSeconds.map(Date.init(timeIntervalSince1970:))
            let completedAt = step.completedAtSeconds.map(Date.init(timeIntervalSince1970:))
            let duration: Double?
            if let startedAt, let completedAt {
                duration = completedAt.timeIntervalSince1970 - startedAt.timeIntervalSince1970
            } else {
                duration = nil
            }
            calls.append(Call(
                sessionID: entry.trajectoryID,
                genIndex: entry.idx,
                stepIndex: step.idx,
                modelName: modelName,
                uncachedInputTokens: usage.uncachedInputTokens,
                cacheReadTokens: usage.cacheReadTokens,
                rawOutputTokens: usage.rawOutputTokens,
                reasoningTokens: usage.reasoningTokens,
                startedAt: startedAt,
                completedAt: completedAt,
                durationSeconds: duration
            ))
        }
        return calls
    }

    // MARK: - SQLite 查询（单连接内部形态）

    private static func readGeneratorMetadataEntries(
        connection: SQLiteConnection
    ) throws -> [GeneratorMetadataEntry] {
        let rows = try connection.query(
            sql: "SELECT idx, data FROM gen_metadata ORDER BY idx ASC",
            map: { statement -> (idx: Int, data: Data?) in
                let idx = Int(sqlite3_column_int64(statement, 0))
                guard sqlite3_column_type(statement, 1) != SQLITE_NULL,
                      let blob = sqlite3_column_blob(statement, 1) else {
                    return (idx, nil)
                }
                return (idx, Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1))))
            }
        )
        return rows.map { idx, data in
            parseGeneratorMetadataEntry(idx: idx, data: data)
        }
    }

    private static func readLLMCallSteps(connection: SQLiteConnection) throws -> [LLMCallStep] {
        let rows = try connection.query(
            sql: "SELECT idx, metadata FROM steps WHERE step_type = 15 ORDER BY idx ASC",
            map: { statement -> (idx: Int, metadata: Data?) in
                let idx = Int(sqlite3_column_int64(statement, 0))
                guard sqlite3_column_type(statement, 1) != SQLITE_NULL,
                      let blob = sqlite3_column_blob(statement, 1) else {
                    return (idx, nil)
                }
                return (idx, Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1))))
            }
        )
        return rows.map { idx, metadata in
            let timestamps = parseStepTimestamps(metadata: metadata)
            return LLMCallStep(
                idx: idx,
                startedAtSeconds: timestamps.startedAt?.timeIntervalSince1970,
                completedAtSeconds: timestamps.completedAt?.timeIntervalSince1970
            )
        }
    }

    private static func readUserTurnSteps(connection: SQLiteConnection) throws -> [UserTurnStep] {
        let rows = try connection.query(
            sql: "SELECT idx, metadata FROM steps WHERE step_type = 14 ORDER BY idx ASC",
            map: { statement -> (idx: Int, metadata: Data?) in
                let idx = Int(sqlite3_column_int64(statement, 0))
                guard sqlite3_column_type(statement, 1) != SQLITE_NULL,
                      let blob = sqlite3_column_blob(statement, 1) else {
                    return (idx, nil)
                }
                return (idx, Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1))))
            }
        )
        return rows.map { idx, metadata in
            UserTurnStep(idx: idx, startedAt: parseStepTimestamps(metadata: metadata).startedAt)
        }
    }

    /// 直读原 .db 必须 READONLY（IDE 正在实时写入的活动库）；SQLiteTempCopy 的
    /// /tmp 副本保持 READWRITE（副本上可能需要完成 WAL recovery）。判定与
    /// `AntigravityStepTimestampReader.opensReadOnly` 同一纪律（路径不在应用专属
    /// 临时目录内即原路径）。internal：测试接缝。
    static func opensReadOnly(dbPath: URL) -> Bool {
        let tempCopyDir = SQLiteTempCopy.appTempDir().standardizedFileURL.path
        return !dbPath.standardizedFileURL.path.hasPrefix(tempCopyDir + "/")
    }

    // MARK: - gen_metadata.data 解析（纯函数，测试接缝 internal）

    /// 解析 gen_metadata 单行的 `data` protobuf。blob 缺失 / 顶层不可解码 → 只有
    /// idx 的占位 entry（仍占配对序位）。
    static func parseGeneratorMetadataEntry(idx: Int, data: Data?) -> GeneratorMetadataEntry {
        guard let data, !data.isEmpty, let top = protoFields(in: data) else {
            return GeneratorMetadataEntry(
                idx: idx, trajectoryID: nil, modelName: nil, displayName: nil,
                usage: nil, attributes: [:], lastStepIndex: nil
            )
        }
        let trajectoryID = firstString(top, fieldNumber: 4)
        guard let eventBytes = firstBytes(top, fieldNumber: 1),
              let event = protoFields(in: eventBytes) else {
            return GeneratorMetadataEntry(
                idx: idx, trajectoryID: trajectoryID, modelName: nil, displayName: nil,
                usage: nil, attributes: [:], lastStepIndex: nil
            )
        }

        // f1.f4 usage 子消息：存在即 usage 事件（全零也成立）；不可解码按不存在处理。
        var usage: GeneratorMetadataEntry.Usage?
        if let usageBytes = firstBytes(event, fieldNumber: 4),
           let usageFields = protoFields(in: usageBytes) {
            usage = GeneratorMetadataEntry.Usage(
                uncachedInputTokens: tokenCount(firstVarint(usageFields, fieldNumber: 2)),
                cacheReadTokens: tokenCount(firstVarint(usageFields, fieldNumber: 5)),
                rawOutputTokens: tokenCount(firstVarint(usageFields, fieldNumber: 3)),
                reasoningTokens: tokenCount(firstVarint(usageFields, fieldNumber: 9)),
                normalizedOutputTokens: firstVarint(usageFields, fieldNumber: 10).map(Int.init(clamping:))
            )
        }

        // f1.f20 repeated string→string map（f1=键，f2=值），同键 last-wins。
        var attributes: [String: String] = [:]
        for field in event where field.fieldNumber == 20 {
            guard field.wireType == 2,
                  let entryBytes = field.bytes,
                  let mapEntry = protoFields(in: entryBytes),
                  let key = firstString(mapEntry, fieldNumber: 1) else { continue }
            attributes[key] = firstString(mapEntry, fieldNumber: 2) ?? ""
        }

        // f19：空串按缺失处理——连接与 probe 的「有模型名」口径统一为非空。
        let modelName = firstString(event, fieldNumber: 19).flatMap { $0.isEmpty ? nil : $0 }
        // 连接键来源：f20 map 的 last_step_index（十进制字符串 → Int）。
        let lastStepIndex = attributes["last_step_index"]
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        // f1.f11 / f1.f12 不解析：f11 经 2026-11-08 实测证伪——其值 ≈ 整段调用
        // 时长（97~100%）、f12≈0，不是 TTFT/streaming 对（见类型注释），接入会
        // 把调用时长误当首字延迟、令解码速度分母≈0。
        return GeneratorMetadataEntry(
            idx: idx,
            trajectoryID: trajectoryID,
            modelName: modelName,
            displayName: firstString(event, fieldNumber: 21),
            usage: usage,
            attributes: attributes,
            lastStepIndex: lastStepIndex
        )
    }

    // MARK: - steps.metadata 解析（纯函数，测试接缝 internal）

    /// steps.metadata 信封：field 1（发起）与 field 7（流式完成）两个 length-delim
    /// protobuf Timestamp（field 1 = seconds varint、field 2 = nanos varint）。
    /// metadata 缺失 / 信封不可解码 → 双 nil；单个 Timestamp 不可解码时该端为 nil。
    static func parseStepTimestamps(metadata: Data?) -> (startedAt: Date?, completedAt: Date?) {
        guard let metadata, !metadata.isEmpty, let fields = protoFields(in: metadata) else {
            return (nil, nil)
        }
        let startedAt = firstBytes(fields, fieldNumber: 1).flatMap(timestamp(from:))
        let completedAt = firstBytes(fields, fieldNumber: 7).flatMap(timestamp(from:))
        return (startedAt, completedAt)
    }

    /// protobuf Timestamp（field 1 = seconds varint、field 2 = nanos varint）→ Date。
    /// epoch 合理域与 `AntigravityStepTimestampReader` 同款（2000–2100）。
    private static func timestamp(from data: Data) -> Date? {
        guard let fields = protoFields(in: data),
              let seconds = firstVarint(fields, fieldNumber: 1) else {
            return nil
        }
        let nanos = firstVarint(fields, fieldNumber: 2) ?? 0
        guard nanos <= 999_999_999 else { return nil }
        let secondsInt = Int64(bitPattern: seconds)
        guard secondsInt >= 946_684_800, secondsInt < 4_102_444_800 else { return nil }
        return Date(
            timeIntervalSince1970: Double(secondsInt) + Double(nanos) / 1_000_000_000
        )
    }

    // MARK: - 极简 protobuf 解码（只覆盖本模块需要的 wire types）

    /// 单个字段：field number + wire type + 二选一载荷（wire 0 → varint，wire 2 → bytes）。
    struct ProtoField: Equatable, Sendable {
        let fieldNumber: Int
        let wireType: Int
        let varint: UInt64?
        let bytes: Data?
    }

    /// 解析一条 protobuf message 的顶层字段序列。
    ///
    /// 只解码 wire type 0（varint）与 2（length-delim）——本模块全部目标字段的取值
    /// 形态；wire type 1（64-bit）/ 5（32-bit）仅作定长跳过（前向容错，未知定长
    /// 字段不影响其余字段解析）；group（3/4）、field number 0 与任何截断 / 长度越界
    /// 视为整条不可解 → nil。
    ///
    /// 深度限幅：本函数不递归；子消息由调用方对 `bytes` 再次调用，而 gen / steps 的
    /// 解析路径是 ≤3 层的手写固定结构（data → f1 → f4/f20、metadata → f1/f7 →
    /// Timestamp），无递归下沉，天然限幅。varint 一律不得越过自己的消息边界（与
    /// `AntigravityStepTimestampReader.readVarint` 同一上界纪律）。
    static func protoFields(in data: Data) -> [ProtoField]? {
        var fields: [ProtoField] = []
        var cursor = 0
        while cursor < data.count {
            guard let key = readVarint(from: data, cursor: &cursor, limit: data.count) else {
                return nil
            }
            let fieldNumber = Int(key >> 3)
            let wireType = Int(key & 7)
            guard fieldNumber > 0 else { return nil }
            switch wireType {
            case 0:
                guard let value = readVarint(from: data, cursor: &cursor, limit: data.count) else {
                    return nil
                }
                fields.append(
                    ProtoField(fieldNumber: fieldNumber, wireType: 0, varint: value, bytes: nil)
                )
            case 2:
                // 先比 cursor <= count 再比 length：双保险防止 readVarint 越过消息
                // 边界后 count - cursor 变负、UInt64(负数) 前置条件 trap。
                guard cursor <= data.count,
                      let length = readVarint(from: data, cursor: &cursor, limit: data.count),
                      length <= UInt64(data.count - cursor),
                      length <= UInt64(Int.max) else {
                    return nil
                }
                let end = cursor + Int(length)
                fields.append(ProtoField(
                    fieldNumber: fieldNumber,
                    wireType: 2,
                    varint: nil,
                    bytes: data.subdata(in: cursor..<end)
                ))
                cursor = end
            case 1:
                guard cursor <= data.count - 8 else { return nil }
                cursor += 8
            case 5:
                guard cursor <= data.count - 4 else { return nil }
                cursor += 4
            default:
                return nil
            }
        }
        return fields
    }

    /// `limit` 是本条 varint 允许读取的字节上界（不含）。撞上 limit 仍未终结
    ///（截断）时返回 nil，此时 cursor 可能已停在 limit。
    private static func readVarint(from data: Data, cursor: inout Int, limit: Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < limit, shift < 64 {
            let byte = data[data.startIndex + cursor]
            cursor += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    /// 同号字段多次出现时取第一次（真实数据不重复非 repeated 字段，取首是容错选择）。
    private static func firstVarint(_ fields: [ProtoField], fieldNumber: Int) -> UInt64? {
        fields.first { $0.fieldNumber == fieldNumber && $0.wireType == 0 }?.varint
    }

    private static func firstBytes(_ fields: [ProtoField], fieldNumber: Int) -> Data? {
        fields.first { $0.fieldNumber == fieldNumber && $0.wireType == 2 }?.bytes
    }

    private static func firstString(_ fields: [ProtoField], fieldNumber: Int) -> String? {
        guard let bytes = firstBytes(fields, fieldNumber: fieldNumber) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// UInt64 token 计数 → Int 饱和（与 `SQLiteConnection.nnClamp` 同款的
    /// 「聚合值进业务模型」边界；负数 varint 本不该出现在 token 字段上）。
    private static func tokenCount(_ raw: UInt64?) -> Int {
        guard let raw else { return 0 }
        return Int(clamping: raw)
    }

    private static func reasonSQLite(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return "sqlite: \(String(text.prefix(200)))"
    }
}
