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

    /// Flags which mean that the event history cannot safely be treated as a
    /// complete list of changed paths.  The next scan must be a full scan.
    var requiresFullScan: Bool {
        flags & LocalFSEventsWatcher.fullScanFlags != 0
    }
}

/// Reusable, per-scanner FSEvents watcher.  It owns exactly the paths supplied by
/// its scanner; there is intentionally no process-wide source/path registry.
final class LocalFSEventsWatcher: @unchecked Sendable {
    typealias EventHandler = @MainActor @Sendable (LocalFSEventsEvent) -> Void

    // These are the flags which invalidate any assumption that the stream
    // delivered every change.  MustScanSubDirs and RootChanged also require the
    // consumer to rediscover its complete source tree.
    static let fullScanFlags: UInt32 =
        UInt32(kFSEventStreamEventFlagMustScanSubDirs)
        | UInt32(kFSEventStreamEventFlagUserDropped)
        | UInt32(kFSEventStreamEventFlagKernelDropped)
        | UInt32(kFSEventStreamEventFlagEventIdsWrapped)
        | UInt32(kFSEventStreamEventFlagRootChanged)
        | UInt32(kFSEventStreamEventFlagMount)
        | UInt32(kFSEventStreamEventFlagUnmount)

    private let paths: [String]
    private let preExistingRootPaths: Set<String>
    private let eventHandler: EventHandler
    private let callbackQueue = DispatchQueue(
        label: "com.llm-monitor.fsevents",
        qos: .utility
    )
    private var stream: FSEventStreamRef?
    /// FSEvents may flush a root-directory creation event after the stream is
    /// attached even when the directory existed before registration.  Consume
    /// that one startup artifact per root; later root events remain real dirty
    /// signals.
    private var ignoredInitialRootPaths = Set<String>()

    init(
        paths: [URL],
        eventHandler: @escaping EventHandler
    ) {
        // FSEvents accepts directory roots.  Deduplication is local to this
        // scanner instance and avoids duplicate callbacks when two SQLite files
        // share a parent directory.
        self.paths = Array(Set(paths.map(Self.canonicalPath))).sorted()
        self.preExistingRootPaths = Set(self.paths.filter {
            FileManager.default.fileExists(atPath: $0)
        })
        self.eventHandler = eventHandler
    }

    var isRunning: Bool { stream != nil }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }

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
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            return
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    private func handleEvent(path: String, eventID: FSEventStreamEventId, flags: FSEventStreamEventFlags) {
        let canonicalPath = Self.canonicalPath(URL(fileURLWithPath: path))
        if shouldIgnoreInitialRootEvent(path: canonicalPath, flags: flags) {
            logDebug("[local-fsevents] ignore startup root event path=\(canonicalPath)")
            return
        }
        let event = LocalFSEventsEvent(
            path: canonicalPath,
            eventID: UInt64(eventID),
            flags: UInt32(flags)
        )
        logDebug("[local-fsevents] event id=\(event.eventID) flags=0x\(String(event.flags, radix: 16)) path=\(event.path)")
        Task { @MainActor [event, eventHandler] in
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

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
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
        for index in 0..<numberOfEvents {
            watcher.handleEvent(
                path: String(cString: paths[index]),
                eventID: eventIDs[index],
                flags: eventFlags[index]
            )
        }
    }
}
