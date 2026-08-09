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

        var errorDescription: String? {
            switch self {
            case .timedOut(let executable, let seconds):
                return "\(executable) 超时（\(seconds)s）"
            }
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
        timeout: TimeInterval
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutData = LockedData()
        let stderrData = LockedData()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutData.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrData.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        let deadline = Date().addingTimeInterval(timeout)
        var terminalError: Error?
        while process.isRunning {
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

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        stdoutData.append(stdout.fileHandleForReading.readDataToEndOfFile())
        stderrData.append(stderr.fileHandleForReading.readDataToEndOfFile())

        if let terminalError {
            throw terminalError
        }
        return Result(
            terminationStatus: process.terminationStatus,
            standardOutput: String(data: stdoutData.snapshot(), encoding: .utf8) ?? "",
            standardError: String(data: stderrData.snapshot(), encoding: .utf8) ?? ""
        )
    }
}
