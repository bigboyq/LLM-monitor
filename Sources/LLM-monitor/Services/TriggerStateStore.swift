import Foundation

/// 通知触发器基线的单模型窗口快照（与 `ModelQuota` 的两个窗口对齐）。
struct QuotaWindowBaseline: Codable, Equatable, Sendable {
    var intervalPresent: Bool
    var intervalRemainingPercent: Double
    var weeklyPresent: Bool
    var weeklyRemainingPercent: Double
}

/// 一个 provider 的触发器基线：modelName（lowercased）→ 窗口基线。
/// 只持久化判定所需的最小标量，schema 演化与 `QuotaInfo` 解耦。
struct QuotaSnapshot: Codable, Equatable, Sendable {
    var models: [String: QuotaWindowBaseline]
    var updatedAt: Date

    init(models: [String: QuotaWindowBaseline], updatedAt: Date = Date()) {
        self.models = models
        self.updatedAt = updatedAt
    }

    /// 从一次成功的 `QuotaInfo` 提取基线。key 与 `QuotaEventDetector` 的匹配键
    /// 一致（`modelName.lowercased()`，冲突取 first）。DeepSeek 等非窗口类
    /// provider 的门控在 AppState（`windowedKinds`），本层不做 kind 判断。
    init(from info: QuotaInfo, updatedAt: Date = Date()) {
        var models: [String: QuotaWindowBaseline] = [:]
        for model in info.models {
            guard model.hasIntervalWindow || model.hasWeeklyWindow else { continue }
            let key = model.modelName.lowercased()
            guard models[key] == nil else { continue }
            models[key] = QuotaWindowBaseline(
                intervalPresent: model.hasIntervalWindow,
                intervalRemainingPercent: model.intervalRemainingPercent,
                weeklyPresent: model.hasWeeklyWindow,
                weeklyRemainingPercent: model.weeklyRemainingPercent
            )
        }
        self.init(models: models, updatedAt: updatedAt)
    }
}

/// 触发器基线的落盘执行器（actor）。
///
/// MainActor 只负责复制一份 `[providerID: QuotaSnapshot]` 值类型快照并排一次
/// `enqueue`；JSON 编码与 `FileManagerBox.writePrivate`（0600 / 临时文件 /
/// fsync / rename）都在 actor 的串行执行器上跑，不阻塞主线程。串行执行从构造上
/// 消除并发写竞态（与 `LastRefreshStore` 同一设计）。
///
/// 写入策略：**每次更新都真正写盘，不做防抖合并**（与原同步直写同频、同内容）。
/// `seq` 只用于防御乱序到达：快照是全量状态字典，旧快照若晚于新快照落盘会把
/// 文件回退，所以 seq 小于已写 seq 的 enqueue 直接丢弃。写失败只 logWarn，
/// 不影响内存基线与通知语义。
actor TriggerStateWriter {
    private let url: URL
    private let fileManager: FileManagerBox
    /// 已经写过的最大 seq；比它小的 enqueue 是迟到的旧快照，必须丢弃。
    private var writtenSeq: UInt64 = 0
    /// 同步兜底落盘（`TriggerStateStore.flushSynchronously`）推高的高水位：
    /// 兜底写完之后，排在 actor 队列里、seq 不更新的旧快照不得再落盘，否则
    /// 会把文件回退到兜底之前的内容。`@unchecked Sendable` + NSLock 让 MainActor
    /// 侧的同步写与 actor 侧的判定共享同一份高水位。
    private let syncFloor: TriggerWriteFloor

    init(
        url: URL,
        fileManager: FileManagerBox = FileManagerBox(),
        syncFloor: TriggerWriteFloor = TriggerWriteFloor()
    ) {
        self.url = url
        self.fileManager = fileManager
        self.syncFloor = syncFloor
    }

    func enqueue(_ snapshots: [String: QuotaSnapshot], seq: UInt64) {
        guard seq > writtenSeq, !syncFloor.supersedes(seq) else { return }
        writtenSeq = seq
        do {
            try fileManager.writePrivate(Self.encode(snapshots), to: url)
        } catch {
            logWarn("[trigger-state] 触发器基线写盘失败: \(error.localizedDescription)")
        }
    }

    /// 落盘字节的唯一编码入口：异步写与同步兜底写必须逐字一致，否则"后写无害"
    /// 的论证不成立。
    nonisolated static func encode(_ snapshots: [String: QuotaSnapshot]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshots)
    }
}

/// 同步兜底落盘的高水位门。`flushSynchronously` 把已落盘的 seq 记进来，writer
/// actor 由此丢弃更早的排队快照，保证"兜底写完不会再被旧写覆盖"。
final class TriggerWriteFloor: @unchecked Sendable {
    private let lock = NSLock()
    private var floorSeq: UInt64 = 0

    /// `seq` 是否已被同步兜底写覆盖（≤ 已落盘高水位即视为过时）。
    func supersedes(_ seq: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seq <= floorSeq
    }

    func advance(to seq: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        floorSeq = max(floorSeq, seq)
    }
}

/// 触发器基线持久化（`notification-state.json`）。
///
/// 通知检测的 previous 单一来源：相比内存 `statuses.lastSuccess`，基线跨重启
/// 连续 —— app 停机期间发生的耗尽/恢复事件，重启后第一次刷新即可补报，而不是
/// 静默重建基线漏掉。写盘用 `FileManagerBox.writePrivate`
/// （0600 / 临时文件 / fsync / rename 原子替换）；坏文件容错降级为空基线，
/// 不进损坏恢复流程。
///
/// 写入策略：**每次更新都落盘，不做防抖合并**（每 provider 每刷新周期一次），
/// 但**不在主线程做**：encode + fsync 全部交给 `TriggerStateWriter` actor 串行
/// 执行。内存 `snapshots` 仍是 MainActor 上的权威副本，`update` 返回后
/// `snapshot(for:)` 立刻能读到新基线（检测器用的 previous 不受落盘时序影响）。
/// 停机（`AppState.stop()`）额外走一次 `flushSynchronously()` 同步兜底，避免
/// 进程在异步写的毫秒级窗口里退出时丢掉最后一次基线。
@MainActor
final class TriggerStateStore {
    private let writer: TriggerStateWriter
    private let fileURL: URL
    private let fileManager: FileManagerBox
    private let syncFloor: TriggerWriteFloor
    private var snapshots: [String: QuotaSnapshot]
    /// 单调递增的落盘序号：既用于丢弃迟到的旧快照，也让 `waitForPendingWrites`
    /// 能确定性地等到"本次 update 排的那次写"完成。
    private var writeSeq: UInt64 = 0
    private var latestWrite: Task<Void, Never>?

    init(configURL: URL) {
        let fileURL = configURL.deletingLastPathComponent()
            .appendingPathComponent("notification-state.json")
        let syncFloor = TriggerWriteFloor()
        self.writer = TriggerStateWriter(url: fileURL, syncFloor: syncFloor)
        self.fileURL = fileURL
        self.fileManager = FileManagerBox()
        self.syncFloor = syncFloor
        self.snapshots = Self.load(from: fileURL)
    }

    func snapshot(for providerID: String) -> QuotaSnapshot? {
        snapshots[providerID]
    }

    /// 成功刷新后更新基线并排一次异步落盘。无条件写（与是否配置了触发器无关），
    /// 保证"先开监控、后开触发器"的边沿语义一致。返回时内存基线已是新值。
    func update(providerID: String, info: QuotaInfo) {
        snapshots[providerID] = QuotaSnapshot(from: info)
        scheduleWrite()
    }

    /// provider 进入 `.notConfigured` 时丢弃基线：重新配置后回到
    /// "首帧只建基线不通知"语义，不拿陈旧基线误报。
    func reset(providerID: String) {
        guard snapshots.removeValue(forKey: providerID) != nil else { return }
        scheduleWrite()
    }

    /// 等待已排队的写盘完成（测试与停机收尾用）。`update` 同步创建了这次写的
    /// Task，所以 await 它返回时这次基线一定已落盘。
    func waitForPendingWrites() async {
        await latestWrite?.value
    }

    /// 进程退出前的**同步兜底落盘**（`AppState.stop()` 调）。
    ///
    /// 正常路径的写盘排在 `TriggerStateWriter` actor 上，是异步的：进程在
    /// "encode + fsync"那几毫秒里被杀掉，最后一次基线就丢了，而基线正是重启
    /// 后补报停机期间耗尽/恢复的 previous。停机路径是同步的（`stop()` 不是
    /// async），没法 await actor，所以这里在 MainActor 上直接把当前内存快照
    /// 编码后经 `FileManagerBox.writePrivate`（0600 / 临时文件 / fsync / rename）
    /// 同步写完再返回。
    ///
    /// 与 actor 上排队的写的关系：写完立刻把 `writeSeq` 推进 `syncFloor`，此后
    /// seq 不更新的排队快照一律被 writer 丢弃——不会出现"兜底写完又被旧快照
    /// 覆盖回退"。若某次排队写此刻正在 actor 上执行并晚于兜底完成，那它与本次
    /// 兜底写的内容逐字相同（同一个 `snapshots` 值类型快照、同一个 encode 入口），
    /// 重复 rename 覆盖同一份字节，无害。
    func flushSynchronously() {
        // 从没排过写 = 没有待落盘的基线，不要凭空造出一个空基线文件。
        guard writeSeq > 0 else { return }
        do {
            try fileManager.writePrivate(TriggerStateWriter.encode(snapshots), to: fileURL)
        } catch {
            logWarn("[trigger-state] 停机同步兜底落盘失败: \(error.localizedDescription)")
        }
        syncFloor.advance(to: writeSeq)
    }

    /// MainActor 只做值类型快照拷贝 + 排一个 Task；encode / fsync / rename 全部
    /// 在 writer actor 上跑。
    private func scheduleWrite() {
        writeSeq &+= 1
        let seq = writeSeq
        let snapshot = snapshots
        let writer = writer
        latestWrite = Task { await writer.enqueue(snapshot, seq: seq) }
    }

    private nonisolated static func load(from url: URL) -> [String: QuotaSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([String: QuotaSnapshot].self, from: data)
        } catch {
            logWarn("[trigger-state] 触发器基线文件解析失败，按空基线处理: \(error.localizedDescription)")
            return [:]
        }
    }
}
