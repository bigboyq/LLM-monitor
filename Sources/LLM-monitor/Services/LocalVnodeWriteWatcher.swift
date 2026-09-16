import Darwin
import Foundation

/// File-level write/extend watcher for sources that stay open while growing.
/// It only reports dirty state; scanning remains owned by the provider cycle.
@MainActor
final class LocalVnodeWriteWatcher {
    typealias EventHandler = @MainActor @Sendable () -> Void

    let path: String
    private let eventHandler: EventHandler
    private static let callbackQueue = DispatchQueue(
        label: "com.llm-monitor.vnode-write",
        qos: .utility
    )
    private var source: DispatchSourceFileSystemObject?

    init(path: URL, eventHandler: @escaping EventHandler) {
        self.path = path.standardizedFileURL.resolvingSymlinksInPath().path
        self.eventHandler = eventHandler
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
                self?.eventHandler()
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
    }

    deinit {
        // The dispatch source's cancel handler owns descriptor closure. A
        // direct close here would race that handler and risk descriptor reuse.
        source?.cancel()
    }
}
