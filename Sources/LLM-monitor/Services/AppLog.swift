import Foundation
import os.log

/// 全局日志器：stdout + 日志文件 + os.Logger（Console.app）
/// 三路都写，方便不同场景下抓取
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    private let osLog = os.Logger(subsystem: "com.llm-monitor", category: "general")
    private let fileURL: URL
    private let queue = DispatchQueue(label: "llm-monitor.logger")
    /// 只在 `queue` 上访问；复用 handle 和字节计数，避免每条日志 stat/open/seek/close。
    private var appendHandle: FileHandle?
    private var currentFileSize: Int = 0
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    /// 单个日志文件大小阈值（5 MB）。超过就 rotate 成 .1, .2, ..., 最多保留 3 份
    /// (active + 2 backup = log.txt, log.txt.1, log.txt.2), 老的删除。
    /// 5 MB 够 24h+ 常规使用, 不会无限涨。
    static let maxLogFileSize: Int = 5 * 1024 * 1024
    static let maxLogBackups: Int = 2
    private init() {
        let overridePath = ProcessInfo.processInfo.environment["LLM_MONITOR_LOG_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFileURL: URL
        if let overridePath, !overridePath.isEmpty {
            resolvedFileURL = URL(fileURLWithPath: overridePath)
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
            resolvedFileURL = support
                .appendingPathComponent("LLM-monitor", isDirectory: true)
                .appendingPathComponent("log.txt")
        }
        let dir = resolvedFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: dir.path
        )

        self.fileURL = resolvedFileURL

        // 同步创建 / 收紧日志文件为 0600，避开"async 写日志的 race"：
        // 之前先 info() → queue.async data.write(to:) 才会创建文件，
        // 而 init 末尾的 setLogFilePermissions 同步 fileExists 检查
        // 看到"不存在"就 early return；之后 async 队列用默认 0644 创建文件。
        // 同步 createFile + 显式 .posixPermissions=0600 一举解决。
        Self.ensureLogFile(at: fileURL)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = (attrs[.size] as? NSNumber)?.intValue {
            self.currentFileSize = size
        }

        // 启动时打个 banner + 路径，方便定位
        info({ "========== LLM Monitor 启动 ==========" })
        info({ "日志文件: \(fileURL.path)" })
    }

    /// 同步创建 / 收紧日志文件为 0600（仅 owner 可读写），跟 config.json 对齐。
    /// 拆成 static + 显式 URL 参数让测试可以用临时路径验证。
    static func ensureLogFile(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            let attrs: [FileAttributeKey: Any] = [
                .posixPermissions: NSNumber(value: 0o600)
            ]
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: attrs
            )
        } else {
            setLogFilePermissions(url)
        }
    }

    /// 收紧日志文件权限到 0600（仅 owner 可读写），跟 config.json 对齐。
    /// log 可能含 provider id / model name / 错误堆栈，避免其他用户读到。
    static func setLogFilePermissions(_ url: URL) {
        let attrs: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: 0o600)
        ]
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        }
    }

    // MARK: - 轮转

    /// 决定是否该 rotate。`additionalBytes` 是这次要写的新内容字节数。
    /// 单一来源：当前文件实际大小 + 这次新内容 > `maxLogFileSize` → rotate。
    /// 这个静态版本读取实际 file size，供独立单元测试与诊断使用；运行时热路径
    /// 使用 queue-owned `currentFileSize`，避免每条日志都 stat。
    static func shouldRotate(fileURL: URL, additionalBytes: Int) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.intValue else { return false }
        return size + additionalBytes > maxLogFileSize
    }

    /// 把当前 `log.txt` rotate 成 `log.txt.1`，老的 `.1` → `.2`，以此类推。
    /// 多于 `maxLogBackups` 的备份直接删掉（active + 2 backups = 3 份）。
    /// 在 queue 串行调用, FileManager.moveItem 是原子的, 不会半成品。
    /// 失败时保留可用文件；调用方会重新读取实际大小，下一条日志继续尝试轮转。
    static func rotateLogFile(at fileURL: URL) {
        let fm = FileManager.default
        // 1. 先把最老的备份删掉（如果有 .maxLogBackups 则删）
        let oldestBackup = backupURL(for: fileURL, index: maxLogBackups)
        if fm.fileExists(atPath: oldestBackup.path) {
            try? fm.removeItem(at: oldestBackup)
        }
        // 2. 中间备份依次 shift: .N-1 → .N
        for i in stride(from: maxLogBackups - 1, through: 1, by: -1) {
            let src = backupURL(for: fileURL, index: i)
            let dst = backupURL(for: fileURL, index: i + 1)
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }
        // 3. 当前 active → .1
        let firstBackup = backupURL(for: fileURL, index: 1)
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.moveItem(at: fileURL, to: firstBackup)
        }
        // 4. 新 active 文件由调用方立即以 0600 创建。
    }

    /// `log.txt` → `log.txt.1` / `log.txt.2` / ...
    /// 不用 `appendingPathExtension` —— 那个会替换现有 extension (foo.txt → foo.1)。
    /// 这里要保留完整 filename, 直接字符串拼最稳。
    private static func backupURL(for fileURL: URL, index: Int) -> URL {
        URL(fileURLWithPath: "\(fileURL.path).\(index)")
    }

    // MARK: - 公开 API

    /// 最低记录级别。Release build 只记 info 及以上；Debug build 全部记录。
    /// 在公开 API 入口检查，避免 `@autoclosure` 仍然求值带来的开销。
    private static let minLevel: Level = {
        #if DEBUG
        return .debug
        #else
        return .info
        #endif
    }()

    func debug(_ msg: () -> String,
               file: String = #file, line: Int = #line) {
        guard Level.debug >= Self.minLevel else { return }
        write(.debug, msg(), file: file, line: line)
    }

    func info(_ msg: () -> String,
              file: String = #file, line: Int = #line) {
        guard Level.info >= Self.minLevel else { return }
        write(.info, msg(), file: file, line: line)
    }

    func warn(_ msg: () -> String,
              file: String = #file, line: Int = #line) {
        guard Level.warn >= Self.minLevel else { return }
        write(.warn, msg(), file: file, line: line)
    }

    func error(_ msg: () -> String,
               file: String = #file, line: Int = #line) {
        guard Level.error >= Self.minLevel else { return }
        write(.error, msg(), file: file, line: line)
    }

    /// 暴露日志文件路径给 UI / 帮助菜单
    var logFilePath: String { fileURL.path }

    // MARK: - 内部

    private enum Level: String, Comparable {
        case debug = "DEBUG", info = "INFO ", warn = "WARN ", error = "ERROR"

        var rank: Int {
            switch self {
            case .debug: return 0
            case .info:  return 1
            case .warn:  return 2
            case .error: return 3
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    private func write(_ level: Level, _ msg: String, file: String, line: Int) {
        let timestamp = Date().formatted(Self.timestampStyle)
        let fileName = (file as NSString).lastPathComponent
        let entry = "[\(timestamp)] [\(level.rawValue)] [\(fileName):\(line)] \(msg)\n"

        // stdout + 文件写入都离开调用线程；queue 保证两路顺序一致。
        let data = Data(entry.utf8)
        queue.async { [weak self] in
            FileHandle.standardOutput.write(data)
            self?.appendToLogFile(data)
        }

        // 3. os.Logger（Console.app 里按 subsystem="com.llm-monitor" 过滤）
        // 全部用 `.private` —— log 内容含 provider id / model name / 错误堆栈 /
        // response body, 其他用户在 Console.app 看的是脱敏占位符, 只有本机用户
        // 显式 unlock 才能看到完整内容。如果有需要广而告之的事件 (比如启动 banner),
        // 单独用 .public 标, 不要全局放开。
        switch level {
        case .debug: osLog.debug("\(msg, privacy: .private)")
        case .info:  osLog.info("\(msg, privacy: .private)")
        case .warn:  osLog.warning("\(msg, privacy: .private)")
        case .error: osLog.error("\(msg, privacy: .private)")
        }
    }

    /// 仅在 `queue` 上调用。
    private func appendToLogFile(_ data: Data) {
        if currentFileSize + data.count > Self.maxLogFileSize {
            try? appendHandle?.close()
            appendHandle = nil
            Self.rotateLogFile(at: fileURL)
            Self.ensureLogFile(at: fileURL)
            currentFileSize = Self.fileSize(at: fileURL)
        }

        if appendHandle == nil {
            appendHandle = try? FileHandle(forWritingTo: fileURL)
            _ = try? appendHandle?.seekToEnd()
        }
        guard let handle = appendHandle else { return }
        do {
            try handle.write(contentsOf: data)
            currentFileSize += data.count
        } catch {
            try? handle.close()
            appendHandle = nil
        }
    }

    private static func fileSize(at url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            return 0
        }
        return size
    }
}

/// 全局便捷函数（少打字）
///
/// `@autoclosure` 包裹 `msg` 透传到 `AppLog`，由 `AppLog` 内部的 `minLevel` guard 决定
/// release build 是否真求值。这样 `logDebug("expensive: \(computeX())")` 在 release 里
/// 不会触发 `computeX()`。
func logDebug(_ msg: @autoclosure () -> String, file: String = #file, line: Int = #line) {
    AppLog.shared.debug(msg, file: file, line: line)
}
func logInfo(_ msg: @autoclosure () -> String, file: String = #file, line: Int = #line) {
    AppLog.shared.info(msg, file: file, line: line)
}
func logWarn(_ msg: @autoclosure () -> String, file: String = #file, line: Int = #line) {
    AppLog.shared.warn(msg, file: file, line: line)
}
func logError(_ msg: @autoclosure () -> String, file: String = #file, line: Int = #line) {
    AppLog.shared.error(msg, file: file, line: line)
}
