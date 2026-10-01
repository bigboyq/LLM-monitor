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

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
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

    private static let eventCallback: FSEventStreamCallback = {
        _, clientCallBackInfo, numberOfEvents, eventPaths, eventFlags, eventIDs in
        guard let clientCallBackInfo else {
            return
        }
        let watcher = Unmanaged<LocalFSEventsWatcher>
            .fromOpaque(clientCallBackInfo)
            .takeUnretainedValue()
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
