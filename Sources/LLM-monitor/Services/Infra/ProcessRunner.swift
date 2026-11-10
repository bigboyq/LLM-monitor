import Foundation
import Darwin

/// 小型、同步的子进程执行器。
///
/// stdout/stderr 在进程运行期间持续排空，避免 pipe 缓冲区填满后子进程与父进程
/// 相互等待。调用线程以短间隔检查超时和 Swift Task 取消；本项目只用它执行
/// `pgrep`/`lsof` 这类短命令。
enum ProcessRunner {
    struct Result: Sendable {
        let terminationStatus: Int32
        let standardOutput: String
        let standardError: String
    }

    enum RunnerError: Error, LocalizedError {
        case timedOut(executable: String, seconds: TimeInterval)
        case outputTooLarge(limit: Int)

        var errorDescription: String? {
            switch self {
            case .timedOut(let executable, let seconds):
                return "\(executable) 超时（\(seconds)s）"
            case .outputTooLarge(let limit):
                return "子进程输出超过 \(limit) bytes"
            }
        }
    }

    /// stdout 经 pipe 分块写盘；超限只保留预算内字节，并让轮询终止子进程。
    /// 回调不能抛错，写入失败在锁内保存，由调用线程统一上抛。
    private final class BoundedFileOutput: @unchecked Sendable {
        private let lock = NSLock()
        private let handle: FileHandle
        private let limit: Int
        private var written = 0
        private var failure: Error?

        init(handle: FileHandle, limit: Int) {
            self.handle = handle
            self.limit = max(limit, 0)
        }

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard failure == nil, !data.isEmpty else { return }
            let remaining = limit - written
            do {
                let count = min(data.count, remaining)
                if count > 0 {
                    try handle.write(contentsOf: data.prefix(count))
                    written += count
                }
                if data.count > remaining {
                    failure = RunnerError.outputTooLarge(limit: limit)
                }
            } catch {
                failure = error
            }
        }

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }

        func recordFailure(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            if failure == nil { failure = error }
        }
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            storage.append(data)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        standardOutputFile: URL? = nil,
        maximumOutputBytes: Int? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutData = LockedData()
        let stderrData = LockedData()
        let outputFileHandle: FileHandle?
        let boundedOutput: BoundedFileOutput?
        if let standardOutputFile {
            let fm = FileManager.default
            try? fm.removeItem(at: standardOutputFile)
            // 显式 0600：`createFile` 默认按 umask 建（实测 0644），而子进程产物
            // 是会话明文（DSH 解压输出最大 1GiB），不能继承系统 umask。
            if !fm.createFile(
                atPath: standardOutputFile.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            ) {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EIO),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "unable to create process output file: \(standardOutputFile.path)"
                    ]
                )
            }
            outputFileHandle = try FileHandle(forWritingTo: standardOutputFile)
            if let maximumOutputBytes, let outputFileHandle {
                boundedOutput = BoundedFileOutput(handle: outputFileHandle, limit: maximumOutputBytes)
                process.standardOutput = stdout
            } else {
                boundedOutput = nil
                process.standardOutput = outputFileHandle
            }
        } else {
            outputFileHandle = nil
            boundedOutput = nil
            process.standardOutput = stdout
        }
        process.standardError = stderr

        if standardOutputFile == nil {
            stdout.fileHandleForReading.readabilityHandler = { handle in
                stdoutData.append(handle.availableData)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrData.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? outputFileHandle?.close()
            throw error
        }

        let boundedReadGroup = DispatchGroup()
        if let boundedOutput {
            // 单一 reader 负责整个 stdout 到 EOF，退出时等待它完成后再关文件。
            // 不混用 readabilityHandler 与 readDataToEndOfFile，避免末块回调/关盘竞态。
            boundedReadGroup.enter()
            let reader = stdout.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                defer { boundedReadGroup.leave() }
                do {
                    while let data = try reader.read(upToCount: 64 * 1024), !data.isEmpty {
                        boundedOutput.append(data)
                    }
                } catch {
                    boundedOutput.recordFailure(error)
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var terminalError: Error?
        while process.isRunning {
            if let error = boundedOutput?.error {
                terminalError = error
                process.terminate()
                break
            }
            if Task<Never, Never>.isCancelled {
                terminalError = CancellationError()
                process.terminate()
                break
            }
            if Date() >= deadline {
                terminalError = RunnerError.timedOut(
                    executable: executable.lastPathComponent,
                    seconds: timeout
                )
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        // pgrep/lsof 会响应 SIGTERM。短暂等待让 terminationStatus 和 pipe EOF
        // 稳定下来；若极端情况下仍未退出，再发送 interrupt。
        if process.isRunning {
            let terminateDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < terminateDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                process.interrupt()
                let interruptDeadline = Date().addingTimeInterval(0.2)
                while process.isRunning && Date() < interruptDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            if process.isRunning {
                // 只针对本执行器刚启动的子进程；保证“不响应 TERM/INT”的命令
                // 也不会突破 timeout/cancellation 契约。
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        boundedReadGroup.wait()

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        if standardOutputFile == nil {
            stdoutData.append(stdout.fileHandleForReading.readDataToEndOfFile())
        }
        stderrData.append(stderr.fileHandleForReading.readDataToEndOfFile())
        try? outputFileHandle?.close()

        if let terminalError = terminalError ?? boundedOutput?.error {
            throw terminalError
        }
        return Result(
            terminationStatus: process.terminationStatus,
            standardOutput: String(data: stdoutData.snapshot(), encoding: .utf8) ?? "",
            standardError: String(data: stderrData.snapshot(), encoding: .utf8) ?? ""
        )
    }
}
