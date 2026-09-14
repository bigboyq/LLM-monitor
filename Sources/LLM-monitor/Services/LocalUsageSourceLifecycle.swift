import Foundation

/// Shared lifecycle for a local usage source watcher.
///
/// The source owns this object, so there is no global watcher registry. All
/// watcher operations and the event generation live on MainActor; scanners use
/// the generation only to decide whether a scan stayed quiet long enough to mark
/// its result fresh.
@MainActor
final class LocalUsageSourceLifecycle {
    private let paths: [URL]
    private let onDirty: () -> Void
    private lazy var watcher = LocalFSEventsWatcher(paths: paths) { [weak self] _ in
        guard let self else { return }
        self.eventGeneration &+= 1
        self.onDirty()
    }

    private(set) var eventGeneration: UInt64 = 0

    init(paths: [URL], onDirty: @escaping () -> Void) {
        self.paths = paths
        self.onDirty = onDirty
    }

    var isRunning: Bool { watcher.isRunning }

    func start() {
        watcher.start()
    }

    func stop() {
        watcher.stop()
    }
}
