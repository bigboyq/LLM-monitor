import CoreServices
import Foundation

/// A single-owner FSEvents stream used as a filesystem invalidation hint.
///
/// The watcher deliberately does not know how a source is scanned.  Its callback
/// is delivered on the main actor, so consumers can update lifecycle state there;
/// no SQL, RPC, or other source work belongs in the FSEvents callback.
struct LocalFSEventsEvent: Sendable, Equatable {
    let path: String
    let eventID: UInt64
    let flags: UInt32

}

/// FSEvents `info` 指针的载荷。它的所有权完全交给 FSEvents：`start()` 时
/// `passRetained` 交出一份强引用，`FSEventStreamRelease` 时由 release 回调归还。
///
/// 对 watcher 只持**弱**引用，于是 stream ↔ watcher 不成环（watcher 被丢弃后
/// deinit 仍能跑完、释放 stream，泄漏环不会形成），而 C 回调里对 watcher 的
/// 弱→强提升在 watcher 已释放时只会得到 nil：旧实现直接把 `info` 当裸指针
/// `takeUnretainedValue()`，`LocalUsageFileMonitor.stop(id)` 释放 watcher 后
/// 已派发未执行的回调理论上会命中已释放对象。
///
/// 类型保持 internal（而非 private）：测试通过 `contextForTesting` 断言 context
/// 的所有权归属，不需要自己构造它。
final class FSEventsWatcherContext {
    weak var watcher: LocalFSEventsWatcher?

    init(watcher: LocalFSEventsWatcher) {
        self.watcher = watcher
    }
}

/// Reusable, per-registration FSEvents watcher. It owns exactly the paths
/// supplied by the shared process-wide LocalUsageFileMonitor; registration
/// filtering and vnode ownership are handled by that monitor.
@MainActor
final class LocalFSEventsWatcher {
    typealias EventHandler = @MainActor @Sendable (LocalFSEventsEvent) -> Void

    private let paths: [String]
    private let preExistingRootPaths: Set<String>
    private let eventHandler: EventHandler
    private let callbackQueue = DispatchQueue(
        label: "com.llm-monitor.fsevents",
        qos: .utility
    )
    /// `nonisolated(unsafe)`：`deinit` 在 Swift 6 里是非隔离的，而 `FSEventStreamRef`
    /// 不是 Sendable，读这个属性会直接编译失败。这个指针只在 `start()` / `stop()` /
    /// `deinit` 里被碰，`deinit` 执行时已经不存在其他引用，实际不存在并发访问；
    /// 用 `(unsafe)` 明确接下这个"编译器证明不了、但由生命周期保证"的事实。
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    /// FSEvents may flush a root-directory creation event after the stream is
    /// attached even when the directory existed before registration.  Consume
    /// that one startup artifact per root; later root events remain real dirty
    /// signals.
    private var ignoredInitialRootPaths = Set<String>()
    #if DEBUG
    /// 测试钩子：当前 stream 的 context box（**弱**引用）。`start()` 后应为非 nil
    /// ——FSEvents 持有强引用，回调不会拿到悬垂指针；`stop()` / `deinit()` 后应回到
    /// nil ——FSEvents 已通过 release 回调归还。两端一起断言即锁死 retain/release
    /// 配对：缺 release 会让 context 泄漏，缺 retain 就是原来的 use-after-free。
    weak var contextForTesting: FSEventsWatcherContext?
    #endif

    init(
        paths: [URL],
        eventHandler: @escaping EventHandler
    ) {
        // FSEvents accepts directory roots. Deduplication is local to this
        // scanner instance. Keep only the highest root when roots overlap;
        // otherwise one child event can be delivered once per nested root.
        let canonicalPaths = Array(Set(paths.map(Self.canonicalPath))).sorted()
        self.paths = canonicalPaths.filter { candidate in
            !canonicalPaths.contains { other in
                other != candidate && Self.isDescendant(candidate, of: other)
            }
        }
        self.preExistingRootPaths = Set(self.paths.filter {
            FileManager.default.fileExists(atPath: $0)
        })
        self.eventHandler = eventHandler
    }

    var isRunning: Bool { stream != nil }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }

        // A scanner reuses its lifecycle object after every scan. Startup root
        // filtering must therefore be armed for each new stream, not only for
        // the first registration of this object.
        ignoredInitialRootPaths.removeAll()

        logInfo("[local-fsevents] starting paths=\(paths.joined(separator: ", "))")

        let contextBox = FSEventsWatcherContext(watcher: self)
        #if DEBUG
        contextForTesting = contextBox
        #endif
        var context = FSEventStreamContext(
            version: 0,
            // The context box (not the watcher itself) is handed to FSEvents as
            // an owned reference: it stays valid for as long as FSEvents may
            // invoke the callback, and the box's weak back-reference keeps a
            // dispatched callback from touching a released watcher.
            info: Unmanaged.passRetained(contextBox).toOpaque(),
            retain: nil,
            release: Self.contextRelease,
            copyDescription: nil
        )
        let pathArray = paths as NSArray
        // Do not use WatchRoot here.  It can emit a synthetic root event when a
        // stream is first attached; treating that event as source mutation
        // makes a successful initial full scan immediately appear dirty.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &context,
            pathArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else {
            // create 失败时没有 stream 接管 context（FSEvents 只在 create 成功
            // 时把字段拷进 stream 并接管所有权），这里不自行 release：无法确证
            // FSEvents 是否已经动过这份引用，误 release 会造成 over-release。
            // 代价是这条实际不可达的路径上多留一个空 context box。
            return
        }

        stream = created
        FSEventStreamSetDispatchQueue(created, callbackQueue)
        guard FSEventStreamStart(created) else {
            logError("[local-fsevents] failed to start paths=\(paths.joined(separator: ", "))")
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            return
        }
        logInfo("[local-fsevents] started paths=\(paths.joined(separator: ", "))")
    }

    func stop() {
        guard let stream else { return }
        logInfo("[local-fsevents] stopping paths=\(paths.joined(separator: ", "))")
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        // 归还 FSEvents 持有的 context 强引用：此后已派发的回调至多拿到一个
        // nil 的弱引用，不再触碰本 watcher，因此这里不需要在回调队列上排空
        // 在途回调（也就不会给主线程引入一次跨队列 sync）。
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // isolated deinit：stream 是 MainActor 隔离属性，非隔离 deinit 访问它在
    // Swift 6 严格并发下是错误；本类全部引用都在 MainActor 上释放，deinit
    // 实际本就运行在主 actor，标注后流销毁与 start()/stop() 完全串行。
    isolated deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// 主 actor 串行的投递入口。启动期 root 去重要变更可变状态
    /// （ignoredInitialRootPaths），必须与 start()/stop() 在同一 actor 上串行；
    /// C 回调只负责打包，状态判定与投递统一在这里完成。
    private func deliver(_ events: [LocalFSEventsEvent]) {
        for event in events {
            if shouldIgnoreInitialRootEvent(
                path: event.path,
                flags: FSEventStreamEventFlags(event.flags)
            ) {
                logDebug("[local-fsevents] ignore startup root event path=\(event.path)")
                continue
            }
            logDebug("[local-fsevents] event id=\(event.eventID) flags=0x\(String(event.flags, radix: 16)) path=\(event.path)")
            eventHandler(event)
        }
    }

    private func shouldIgnoreInitialRootEvent(
        path: String,
        flags: FSEventStreamEventFlags
    ) -> Bool {
        guard preExistingRootPaths.contains(path),
              !ignoredInitialRootPaths.contains(path),
              flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0,
              flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 else {
            return false
        }
        ignoredInitialRootPaths.insert(path)
        return true
    }

    /// 纯函数、不触碰任何 watcher 状态；C 回调在 FSEvents 队列上调用它完成
    /// 路径规范化，因此必须保持 nonisolated。
    private nonisolated static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isDescendant(_ path: String, of root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    /// FSEvents 释放 stream 时归还 `passRetained` 的那一份 context 强引用。
    /// 纯引用计数操作：只在 FSEvents 自己的线程上跑，不 hop MainActor、不阻塞
    /// 调用方（`stop()` 里 `FSEventStreamRelease` 之后不会等待它）。
    private static let contextRelease: CFAllocatorReleaseCallBack = { info in
        guard let info else { return }
        Unmanaged<FSEventsWatcherContext>.fromOpaque(info).release()
    }

    private static let eventCallback: FSEventStreamCallback = {
        _, clientCallBackInfo, numberOfEvents, eventPaths, eventFlags, eventIDs in
        guard let clientCallBackInfo else {
            return
        }
        // context box 由 FSEvents 持有（在 stream 释放前一直有效），这里取到的
        // 强引用保证回调体执行期间 box 不会被释放；watcher 只做弱→强提升，
        // 已随 stop/deinit 释放时得到 nil，回调安全空跑。
        let context = Unmanaged<FSEventsWatcherContext>
            .fromOpaque(clientCallBackInfo)
            .takeUnretainedValue()
        let watcher = context.watcher
        let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        // C 回调运行在 FSEvents 的 utility 队列上（非隔离）：这里只做字符串
        // 拷贝与事件打包，全部使用回调参数的局部值，不触碰 watcher 的可变
        // 状态；启动期 root 去重（ignoredInitialRootPaths）与最终投递统一
        // hop 到主 actor 串行执行，避免与 start() 的 removeAll() 无锁并发。
        var events: [LocalFSEventsEvent] = []
        events.reserveCapacity(numberOfEvents)
        for index in 0..<numberOfEvents {
            events.append(LocalFSEventsEvent(
                path: canonicalPath(URL(fileURLWithPath: String(cString: paths[index]))),
                eventID: UInt64(eventIDs[index]),
                flags: UInt32(eventFlags[index])
            ))
        }
        Task { @MainActor [weak watcher] in
            watcher?.deliver(events)
        }
    }
}
