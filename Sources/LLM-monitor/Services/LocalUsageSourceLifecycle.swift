import CoreServices
import Foundation

/// Process-wide realtime file monitor. FSEvents discovers topology while one
/// shared vnode source per path reports in-place writes. The 128-entry limit is
/// deliberately a notification cache; scanner fingerprints remain authoritative.
@MainActor
final class LocalUsageFileMonitor {
    static let shared = LocalUsageFileMonitor()

    private struct Registration {
        let id: UUID
        let roots: [URL]
        let rootPaths: [String]
        let fixedPaths: Set<String>
        let dynamicExtensions: Set<String>
        let excludedPaths: Set<String>
        let onEvent: @MainActor @Sendable () -> Void
        var dynamicPaths: Set<String> = []
        var fsevents: LocalFSEventsWatcher?
        var discoveryTask: Task<Void, Never>?
        var discoveryGeneration: UInt64 = 0
    }

    private let maxVnodeWatchers: Int
    private let autoDiscoveryEnabled: Bool
    private var registrations: [UUID: Registration] = [:]
    private var owners: [String: Set<UUID>] = [:]
    private var vnodeWatchers: [String: LocalVnodeWriteWatcher] = [:]
    private var pinnedPaths: Set<String> = []
    private var recency: [String: UInt64] = [:]
    private var nextSequence: UInt64 = 0

    init(maxVnodeWatchers: Int = 128, autoDiscoveryEnabled: Bool = true) {
        self.maxVnodeWatchers = max(maxVnodeWatchers, 1)
        self.autoDiscoveryEnabled = autoDiscoveryEnabled
    }

    var vnodeWatcherCount: Int { vnodeWatchers.count }
    #if DEBUG
    var watchedPaths: Set<String> { Set(vnodeWatchers.keys) }

    func accessSequence(for path: URL) -> UInt64? {
        recency[Self.canonicalPath(path)]
    }

    func handleTopologyEventForTesting(path: String, flags: UInt32) {
        let event = LocalFSEventsEvent(path: path, eventID: 0, flags: flags)
        for id in Array(registrations.keys) {
            handleFSEvent(event, registrationID: id)
        }
    }
    #endif

    func register(
        paths: [URL],
        fixedFiles: [URL],
        seedDynamicFiles: [URL],
        dynamicExtensions: Set<String>,
        excludedPaths: [URL],
        onEvent: @escaping @MainActor @Sendable () -> Void
    ) -> UUID {
        let id = UUID()
        let rootPaths = paths.map(Self.canonicalPath)
        let registration = Registration(
            id: id,
            roots: paths,
            rootPaths: rootPaths,
            fixedPaths: Set(fixedFiles.map(Self.canonicalPath)),
            dynamicExtensions: normalizedExtensions(dynamicExtensions),
            excludedPaths: Set(excludedPaths.map(Self.canonicalPath)),
            onEvent: onEvent
        )
        registrations[id] = registration
        for path in registration.fixedPaths {
            owners[path, default: []].insert(id)
            pinnedPaths.insert(path)
        }
        for url in seedDynamicFiles {
            addDynamicPath(Self.canonicalPath(url), to: id)
        }
        var registered = registrations[id]!
        registered.fsevents = LocalFSEventsWatcher(paths: paths) { [weak self] event in
            self?.handleFSEvent(event, registrationID: id)
        }
        registrations[id] = registered
        start(id)
        scheduleDiscovery(for: id)
        return id
    }

    func start(_ id: UUID) {
        guard let registration = registrations[id] else { return }
        registration.fsevents?.start()
        for path in registration.fixedPaths {
            ensureWatcher(for: path)
        }
        for path in registration.dynamicPaths {
            ensureWatcher(for: path)
        }
    }

    func stop(_ id: UUID) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        registration.discoveryTask?.cancel()
        registration.fsevents?.stop()
        for path in registration.fixedPaths.union(registration.dynamicPaths) {
            removeOwner(id, from: path)
        }
    }

    func touchHotFiles(_ files: [URL], for id: UUID) {
        guard registrations[id] != nil else { return }
        for file in files {
            addDynamicPath(Self.canonicalPath(file), to: id)
        }
    }

    func refreshHotFiles(for id: UUID) {
        // Directory enumeration/stat happens in the utility task below; the
        // MainActor only schedules/cancels and applies a bounded result.
        scheduleDiscovery(for: id)
    }

    private func handleFSEvent(_ event: LocalFSEventsEvent, registrationID: UUID) {
        guard let registration = registrations[registrationID],
              isWithinRoots(event.path, registration: registration),
              !isExcluded(event.path, by: registration.excludedPaths) else {
            return
        }
        registration.onEvent()
        let path = event.path
        if isDynamicCandidate(path, registration: registration),
           !registration.dynamicPaths.contains(path),
           FileManager.default.fileExists(atPath: path) {
            addDynamicPath(path, to: registrationID)
        }
        if event.flags & Self.topologyEventMask != 0,
           vnodeWatchers[path] != nil {
            vnodeWatchers.removeValue(forKey: path)?.stop()
        }
        if event.flags & Self.topologyEventMask != 0,
           !registration.fixedPaths.contains(path),
           !FileManager.default.fileExists(atPath: path) {
            removeDynamicPath(path, from: registrationID)
        }
        if FileManager.default.fileExists(atPath: path) {
            ensureWatcher(for: path)
        }
    }

    private func addDynamicPath(_ path: String, to id: UUID) {
        guard var registration = registrations[id],
              isDynamicCandidate(path, registration: registration),
              FileManager.default.fileExists(atPath: path) else {
            return
        }
        registration.dynamicPaths.insert(path)
        registrations[id] = registration
        owners[path, default: []].insert(id)
        touch(path)
        ensureWatcher(for: path)
    }

    private func removeDynamicPath(_ path: String, from id: UUID) {
        guard var registration = registrations[id] else { return }
        registration.dynamicPaths.remove(path)
        registrations[id] = registration
        removeOwner(id, from: path)
    }

    private func removeOwner(_ id: UUID, from path: String) {
        owners[path]?.remove(id)
        guard owners[path]?.isEmpty != false else {
            if registrations.values.contains(where: { $0.fixedPaths.contains(path) }) {
                pinnedPaths.insert(path)
            } else {
                pinnedPaths.remove(path)
            }
            return
        }
        owners.removeValue(forKey: path)
        pinnedPaths.remove(path)
        recency.removeValue(forKey: path)
        vnodeWatchers.removeValue(forKey: path)?.stop()
    }

    private func ensureWatcher(for path: String) {
        guard FileManager.default.fileExists(atPath: path),
              owners[path]?.isEmpty == false,
              vnodeWatchers[path] == nil else { return }
        while vnodeWatchers.count >= maxVnodeWatchers {
            guard let victim = recency
                .filter({ !pinnedPaths.contains($0.key) && vnodeWatchers[$0.key] != nil })
                .min(by: { $0.value < $1.value })?.key else {
                return
            }
            evict(victim)
        }
        let watcher = LocalVnodeWriteWatcher(path: URL(fileURLWithPath: path)) { [weak self] in
            self?.handleVnodeEvent(path: path)
        }
        guard watcher.start() else { return }
        vnodeWatchers[path] = watcher
    }

    private func evict(_ path: String) {
        guard !pinnedPaths.contains(path) else { return }
        vnodeWatchers.removeValue(forKey: path)?.stop()
        recency.removeValue(forKey: path)
        let sourceIDs = owners.removeValue(forKey: path) ?? []
        for id in sourceIDs {
            guard var registration = registrations[id] else { continue }
            registration.dynamicPaths.remove(path)
            registrations[id] = registration
        }
    }

    private func handleVnodeEvent(path: String) {
        guard vnodeWatchers[path] != nil else { return }
        touch(path)
        for id in owners[path] ?? [] {
            registrations[id]?.onEvent()
        }
    }

    private struct DiscoverySnapshot: Sendable {
        let id: UUID
        let generation: UInt64
        let roots: [URL]
        let rootPaths: [String]
        let extensions: Set<String>
        let exclusions: Set<String>
    }

    private func scheduleDiscovery(for id: UUID) {
        guard autoDiscoveryEnabled, var registration = registrations[id],
              !registration.dynamicExtensions.isEmpty else { return }
        registration.discoveryGeneration &+= 1
        let snapshot = DiscoverySnapshot(
            id: id,
            generation: registration.discoveryGeneration,
            roots: registration.roots,
            rootPaths: registration.rootPaths,
            extensions: registration.dynamicExtensions,
            exclusions: registration.excludedPaths
        )
        registration.discoveryTask?.cancel()
        registration.discoveryTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                Self.discover(snapshot)
            }
            let files = await withTaskCancellationHandler(operation: {
                await worker.value
            }, onCancel: {
                worker.cancel()
            })
            guard !Task.isCancelled else { return }
            self?.applyDiscovery(files, for: snapshot.id, generation: snapshot.generation)
        }
        registrations[id] = registration
    }

    private func applyDiscovery(_ files: [URL], for id: UUID, generation: UInt64) {
        guard let registration = registrations[id],
              registration.discoveryGeneration == generation else { return }
        for file in files {
            addDynamicPath(Self.canonicalPath(file), to: id)
        }
    }

    nonisolated private static func discover(_ snapshot: DiscoverySnapshot) -> [URL] {
        var candidates: [(URL, Date)] = []
        let cutoff = Date().addingTimeInterval(-48 * 60 * 60)
        for root in snapshot.roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard !Task.isCancelled else { return [] }
                let path = Self.canonicalPath(url)
                guard snapshot.extensions.contains(url.pathExtension.lowercased()),
                      !Self.isExcluded(path, by: snapshot.exclusions),
                      snapshot.rootPaths.contains(where: { rootPath in
                          path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
                      }),
                      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt >= cutoff else { continue }
                candidates.append((url, modifiedAt))
            }
        }
        let recent = candidates.sorted { $0.1 > $1.1 }.prefix(128)
        return recent.sorted { $0.1 < $1.1 }.map(\.0)
    }

    private func isDynamicCandidate(_ path: String, registration: Registration) -> Bool {
        guard registration.dynamicExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
              !isExcluded(path, by: registration.excludedPaths) else { return false }
        return isWithinRoots(path, registration: registration)
    }

    private func isWithinRoots(_ path: String, registration: Registration) -> Bool {
        registration.rootPaths.contains { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    private func isExcluded(_ path: String, by exclusions: Set<String>) -> Bool {
        exclusions.contains { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    nonisolated private static func isExcluded(_ path: String, by exclusions: Set<String>) -> Bool {
        exclusions.contains { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    private func touch(_ path: String) {
        nextSequence &+= 1
        recency[path] = nextSequence
    }

    private func normalizedExtensions(_ extensions: Set<String>) -> Set<String> {
        Set(extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
    }

    private static let topologyEventMask: UInt32 =
        UInt32(kFSEventStreamEventFlagItemCreated)
            | UInt32(kFSEventStreamEventFlagItemRemoved)
            | UInt32(kFSEventStreamEventFlagItemRenamed)

    nonisolated private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Lightweight per-source registration handle. It owns freshness generation,
/// while all FSEvents/vnode state and the global LRU live in LocalUsageFileMonitor.
@MainActor
final class LocalUsageSourceLifecycle {
    private weak var monitor: LocalUsageFileMonitor?
    private let paths: [URL]
    private let watchedFiles: [URL]
    private let seedDynamicFiles: [URL]
    private let dynamicExtensions: Set<String>
    private let excludedPaths: [URL]
    private let onDirty: () -> Void
    private var registrationID: UUID?

    private(set) var eventGeneration: UInt64 = 0

    init(
        paths: [URL],
        watchedFiles: [URL] = [],
        seedDynamicFiles: [URL] = [],
        dynamicExtensions: Set<String> = [],
        excludedPaths: [URL] = [],
        monitor: LocalUsageFileMonitor? = nil,
        onDirty: @escaping () -> Void
    ) {
        self.paths = paths
        self.watchedFiles = watchedFiles
        self.seedDynamicFiles = seedDynamicFiles
        self.dynamicExtensions = dynamicExtensions
        self.excludedPaths = excludedPaths
        self.monitor = monitor ?? LocalUsageFileMonitor.shared
        self.onDirty = onDirty
        start()
    }

    isolated deinit {
        if let registrationID, let monitor {
            monitor.stop(registrationID)
        }
    }

    var isRunning: Bool { registrationID != nil }

    func start() {
        guard let monitor else { return }
        if let registrationID {
            monitor.start(registrationID)
            return
        }
        registrationID = monitor.register(
            paths: paths,
            fixedFiles: watchedFiles,
            seedDynamicFiles: seedDynamicFiles,
            dynamicExtensions: dynamicExtensions,
            excludedPaths: excludedPaths
        ) { [weak self] in
            guard let self else { return }
            self.eventGeneration &+= 1
            self.onDirty()
        }
    }

    func stop() {
        guard let registrationID, let monitor else { return }
        monitor.stop(registrationID)
        self.registrationID = nil
    }

    func touchHotFiles(_ files: [URL]) {
        guard let registrationID else { return }
        monitor?.touchHotFiles(files, for: registrationID)
    }

    func refreshHotFiles() {
        guard let registrationID else { return }
        monitor?.refreshHotFiles(for: registrationID)
    }
}
