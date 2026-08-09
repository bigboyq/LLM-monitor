import Foundation
import Darwin

/// 用进程持有的 flock 保证同一份用户数据目录只运行一个 app 实例。
/// lock 文件可以长期存在；真正的互斥由文件描述符持有的内核锁保证，进程退出后自动释放。
final class AppInstanceLock: @unchecked Sendable {
    enum AcquisitionError: LocalizedError, Equatable {
        case createDirectoryFailed(URL, String)
        case openFailed(URL, Int32, String)
        case lockFailed(URL, Int32, String)

        var errorDescription: String? {
            switch self {
            case .createDirectoryFailed(let url, let message):
                return "无法创建单实例锁目录：\(url.path)（\(message)）"
            case .openFailed(let url, let code, let message):
                return "无法打开单实例锁文件：\(url.path)（errno=\(code)，\(message)）"
            case .lockFailed(let url, let code, let message):
                return "无法取得单实例锁：\(url.path)（errno=\(code)，\(message)）"
            }
        }
    }

    enum AcquisitionResult {
        case acquired(AppInstanceLock)
        case alreadyRunning
        case failed(AcquisitionError)
    }

    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    static func acquireDefault() -> AcquisitionResult {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let directory = support.appendingPathComponent("LLM-monitor", isDirectory: true)
        let lockURL = directory.appendingPathComponent("instance.lock")
        return acquireResult(at: lockURL)
    }

    /// 兼容测试和普通调用方的 optional API；需要区分锁竞争与 I/O 失败时使用
    /// `acquireResult(at:)`。
    static func acquire(at lockURL: URL) -> AppInstanceLock? {
        guard case .acquired(let lock) = acquireResult(at: lockURL) else { return nil }
        return lock
    }

    static func acquireResult(at lockURL: URL) -> AcquisitionResult {
        let directory = lockURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            let failure = AcquisitionError.createDirectoryFailed(directory, error.localizedDescription)
            logError("AppInstanceLock: \(failure.localizedDescription)")
            return .failed(failure)
        }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            let code = errno
            let message = String(cString: strerror(code))
            let failure = AcquisitionError.openFailed(lockURL, code, message)
            logError("AppInstanceLock: \(failure.localizedDescription)")
            return .failed(failure)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                return .alreadyRunning
            }
            let message = String(cString: strerror(code))
            let failure = AcquisitionError.lockFailed(lockURL, code, message)
            logError("AppInstanceLock: \(failure.localizedDescription)")
            return .failed(failure)
        }
        return .acquired(AppInstanceLock(fileDescriptor: descriptor))
    }

    deinit {
        _ = flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}
