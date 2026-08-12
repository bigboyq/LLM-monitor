import Foundation

/// R1: 把 last-refresh.json 的 encode + fsync 写盘移出 MainActor。
///
/// MainActor 只负责复制一份 `[providerID: Date]` 值类型快照，再 `enqueue` 到本
/// actor；真正的 JSON 编码与 `FileManagerBox.writePrivate`（0600 / 原子 rename /
/// fsync）都在 actor 执行器上跑，不阻塞 UI。
///
/// 用约 250ms 合并窗口吸收同一批 provider 连续成功刷新：每次 enqueue 取消上一个
/// pending flush 并安排新的，只有最后一次 enqueue 之后 250ms 仍有效的 flush 才
/// 真正写盘；`scheduledSeq` 让任何漏网的旧 flush 立即 no-op。崩溃最多丢失最近一个
/// 合并窗口的“显示时间”，不影响额度数据或配置。写失败只 logWarn，不回滚 UI 成功。
actor LastRefreshStore {
    private let url: URL
    private let coalesceSeconds: TimeInterval
    private let fileManager: FileManagerBox
    private var latestSnapshot: [String: Date]?
    private var scheduledSeq: UInt64 = 0
    private var pendingFlush: Task<Void, Never>?

    init(
        url: URL,
        coalesceSeconds: TimeInterval = 0.25,
        fileManager: FileManagerBox = FileManagerBox()
    ) {
        self.url = url
        self.coalesceSeconds = coalesceSeconds
        self.fileManager = fileManager
    }

    /// MainActor 复制快照后调用。值类型拷贝，调用方之后改 dict 不影响排队中的写。
    func enqueue(_ snapshot: [String: Date]) {
        latestSnapshot = snapshot
        scheduledSeq &+= 1
        let mySeq = scheduledSeq
        pendingFlush?.cancel()
        let delay = coalesceSeconds
        pendingFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.performFlush(expectedSeq: mySeq)
        }
    }

    /// 立即落盘当前快照（取消合并窗口）。供测试与停机时同步写盘。
    func flushNow() async {
        pendingFlush?.cancel()
        pendingFlush = nil
        guard let snapshot = latestSnapshot else { return }
        latestSnapshot = nil
        scheduledSeq &+= 1  // 让任何漏网的 performFlush 失效
        Self.write(snapshot, to: url, fileManager: fileManager)
    }

    private func performFlush(expectedSeq: UInt64) async {
        guard expectedSeq == scheduledSeq else { return }
        guard let snapshot = latestSnapshot else { return }
        latestSnapshot = nil
        Self.write(snapshot, to: url, fileManager: fileManager)
    }

    /// 纯写盘：encode + writePrivate（0600 / 原子 rename / fsync）。
    /// nonisolated：不在 actor 执行器上排队，直接在调用方上下文执行；由 actor
    /// 内部串行调用，天然互斥。
    private nonisolated static func write(
        _ snapshot: [String: Date],
        to url: URL,
        fileManager: FileManagerBox
    ) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try fileManager.writePrivate(data, to: url)
        } catch {
            logWarn("LastRefreshStore: 保存 last-refresh.json 失败: \(error.localizedDescription)")
        }
    }
}
