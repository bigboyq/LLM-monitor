import Foundation
import Darwin

/// 小型、同步的子进程执行器。
///
/// stdout/stderr 在进程运行期间持续排空，避免 pipe 缓冲区填满后子进程与父进程
/// 相互等待。调用线程以短间隔检查超时和 Swift Task 取消；短命令与 DSH
/// 流式解压共用同一套非阻塞管道排空、输出上限和退出语义。
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

    /// stdout 经 pipe 分块写盘；超限只保留预算内字节，由同一轮询线程中止。
    private final class BoundedFileOutput {
        private let handle: FileHandle
        private let limit: Int
        private var written = 0
        private var failure: Error?

        init(handle: FileHandle, limit: Int) {
            self.handle = handle
            self.limit = max(limit, 0)
        }

        func append(_ data: Data) {
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
            failure
        }
    }

    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        standardOutputFile: URL? = nil,
        maximumOutputBytes: Int? = nil
    ) throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        var stdoutData = Data()
        var stderrData = Data()
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
        defer {
            try? outputFileHandle?.close()
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        let readStdout = standardOutputFile == nil || boundedOutput != nil
        for handle in [stdout.fileHandleForReading, stderr.fileHandleForReading] {
            let fd = handle.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }

        try process.run()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        // Read at most one bounded chunk from each pipe per turn. No blocking
        // read/group wait may outlive the same timeout/cancellation checks,
        // including when an exited process left a descendant holding a pipe.
        func readChunk(_ handle: FileHandle, consume: (Data) -> Void) throws -> (read: Bool, eof: Bool) {
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(handle.fileDescriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                consume(Data(bytes.prefix(count)))
                return (true, false)
            }
            if count == 0 { return (false, true) }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return (false, false) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let deadline = Date().addingTimeInterval(timeout)
        var terminalError: Error?
        var stdoutEOF = !readStdout
        var stderrEOF = false
        while process.isRunning || !stdoutEOF || !stderrEOF {
            if Task<Never, Never>.isCancelled {
                terminalError = CancellationError()
                break
            }
            if Date() >= deadline {
                terminalError = RunnerError.timedOut(
                    executable: executable.lastPathComponent,
                    seconds: timeout
                )
                break
            }
            var readAny = false
            do {
                if !stdoutEOF {
                    let next = try readChunk(stdout.fileHandleForReading) { data in
                        if let boundedOutput { boundedOutput.append(data) }
                        else { stdoutData.append(data) }
                    }
                    readAny = next.read
                    stdoutEOF = next.eof
                }
                if !stderrEOF {
                    let next = try readChunk(stderr.fileHandleForReading) { stderrData.append($0) }
                    readAny = readAny || next.read
                    stderrEOF = next.eof
                }
            } catch {
                terminalError = error
                break
            }
            if let error = boundedOutput?.error {
                terminalError = error
                break
            }
            if !readAny { Thread.sleep(forTimeInterval: 0.01) }
        }

        if terminalError != nil, process.isRunning { process.terminate() }

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

        if let terminalError = terminalError ?? boundedOutput?.error {
            throw terminalError
        }
        return Result(
            terminationStatus: process.terminationStatus,
            standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
            standardError: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
