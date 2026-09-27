import Darwin
import Foundation

/// File-level write/extend watcher for sources that stay open while growing.
/// It only reports dirty state; scanning remains owned by the provider cycle.
@MainActor
final class LocalVnodeWriteWatcher {
    typealias EventHandler = @MainActor @Sendable () -> Void

    /// 写事件合并窗口。本 watcher 的目标就是"持续增长的文件"（SQLite WAL /
    /// JSONL append），窗口内会连发大量微小 write/extend；逐条投递会淹没
    /// MainActor。取 0.25s，与 LocalFSEventsWatcher 的流延迟参数及
    /// ConfigStore.scheduleConfigReload 的 250ms debounce 同一量级，保持
    /// 监听层时间尺度一致。
    nonisolated static let defaultCoalescingWindow: TimeInterval = 0.25

    let path: String
    private let eventHandler: EventHandler
    private let coalescingWindow: TimeInterval
    private static let callbackQueue = DispatchQueue(
        label: "com.llm-monitor.vnode-write",
        qos: .utility
    )
    private var source: DispatchSourceFileSystemObject?
    /// 合并窗口任务：非 nil 表示处于窗口内（窗口内事件只记账不投递）。
    private var windowTask: Task<Void, Never>?
    /// 窗口内是否收到过被合并的写事件（窗口结束时合并投递一次）。
    private var hasSuppressedEvent = false

    init(
        path: URL,
        eventHandler: @escaping EventHandler,
        coalescingWindow: TimeInterval = LocalVnodeWriteWatcher.defaultCoalescingWindow
    ) {
        self.path = path.standardizedFileURL.resolvingSymlinksInPath().path
        self.eventHandler = eventHandler
        self.coalescingWindow = max(coalescingWindow, 0)
    }

    var isRunning: Bool { source != nil }

    @discardableResult
    func start() -> Bool {
        guard source == nil else { return true }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let created = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend],
            queue: Self.callbackQueue
        )
        created.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handleWriteEvent()
            }
        }
        created.setCancelHandler {
            close(descriptor)
        }
        source = created
        created.resume()
        return true
    }

    func stop() {
        guard let source else { return }
        self.source = nil
        source.cancel()
        // 停止时清掉窗口状态：窗口内被合并的事件不再投递（无幽灵事件）。
        windowTask?.cancel()
        windowTask = nil
        hasSuppressedEvent = false
    }

    deinit {
        // The dispatch source's cancel handler owns descriptor closure. A
        // direct close here would race that handler and risk descriptor reuse.
        source?.cancel()
        // windowTask 持有 weak self：deinit 后到点只做空跑，不投递。
    }

    /// 主 actor 串行的写事件入口：窗口空闲立即投递一次（首事件即时），窗口
    /// 内的后续事件只记账，窗口结束时合并投递一次并重新开窗。因此任意
    /// [投递, 投递 + window) 区间内至多投递一次，下游负载有界。
    ///
    /// 为什么首事件即时投递、而不是复核建议的纯 trailing debounce：
    /// 1) 文件被原子替换（临时文件 + rename）时，FSEvents 会对新路径报
    ///    ItemRenamed，monitor 随即停掉旧 vnode watcher 并按新 inode 重建；
    ///    纯 trailing 的延迟投递会被这次 stop 取消（或随旧实例释放而落空），
    ///    真实写入的 touch 随之丢失——LRU 测试在套件顺序运行下可稳定复现。
    ///    即时首投递保留了旧实现一跳即达的时序裕量。
    /// 2) "持续增长的文件"若一直写入，纯 trailing + 续期会让它在静默前
    ///    永不投递；固定窗口保证热文件每个窗口至少被代表一次。
    private func handleWriteEvent() {
        guard isRunning else { return }
        guard windowTask == nil else {
            hasSuppressedEvent = true
            return
        }
        eventHandler()
        startWindow()
    }

    private func startWindow() {
        hasSuppressedEvent = false
        let window = coalescingWindow
        windowTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(window))
            } catch {
                return // stop() 取消：窗口内合并的事件一并丢弃，不投递幽灵事件
            }
            // 睡眠已成功但任务可能刚被 stop() 取消（cancel 赶在恢复前生效）：
            // stop() 是本任务唯一的取消者，未取消即窗口仍归属本任务，清
            // windowTask 才是安全的；否则会把 stop/start 循环后新开的窗口
            // 任务引用清掉，破坏合并记账（陈旧任务 clobber）。
            guard let self, !Task.isCancelled else { return }
            self.windowTask = nil
            if self.hasSuppressedEvent, self.isRunning {
                self.eventHandler()
                self.startWindow()
            }
        }
    }
}
