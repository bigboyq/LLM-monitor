import Foundation
import Darwin

/// `FileManager` 的 Sendable 包装 —— Foundation 没把 `FileManager` 标 `Sendable`
/// （实测 [SR-15316](https://bugs.swift.org/browse/SR-15316) 一直没修），但
/// `FileManager` 文档保证"对单实例做并发读是安全的"。scanner 用 `AsyncMutex`
/// 串行化所有 file I/O（per-instance），ConfigStore 则受 `@MainActor` 隔离，
/// 实际无并发写竞争，所以可以走 `@unchecked Sendable` 路径。
///
/// ## 显式访问约束（access constraints）
///
/// 1. **`fileManager` 标 `private`** —— 同文件 extension 之外**无法**直接拿到
///    `FileManager` 实例，所有 file I/O 必须走下面的 extension API
///    （`func fileExists` / `func createPrivateDirectory` / ...）。防止有人
///    `box.fileManager.createDirectory(...)` 绕过我们的封装，引入未走
///    AsyncMutex 串行化的路径。
///
/// 2. **`Sendable` 责任不在类型本身** —— 这个类型不带锁，也不保证并发安全。
///    **调用方**必须保证：
///    - 同一 `FileManagerBox` 实例上的所有 file I/O 调用都在同一 actor / lock 下
///      串行化（scanner 走 `AsyncMutex.pipelineMutex` 保证）
///    - 跨 instance 不共享（每个 scanner 自己 new 一个）
///
/// 3. **使用入口约束** —— 当前调用方（scanner 全家 + ConfigStore + Dsh 解码等
///    多个文件）：scanner 跑在各自的 `pipelineMutex` 内，ConfigStore 受
///    `@MainActor` 隔离。任何新调用方必须同样在 mutex 内，或证明单线程 /
///    actor 隔离。
///
/// ## 为什么不直接用 `actor`
///
/// `actor` 会让所有调用都变 `await`，两个 scanner 的所有 I/O 都得改 async。
/// 当前 scanner 已经用 `AsyncMutex` 串行化所有 I/O，引入 `actor` 是重复锁
/// （双重 acquire）。`@unchecked Sendable` + `private` fileManager + 上述
/// 调用方约束，是**当前并发模型下**的最低成本正确性方案。
struct FileManagerBox: @unchecked Sendable {
    /// 内部 FileManager —— `private` 防止调用方绕过 extension API。
    /// 同 file 内的 extension 可以访问，**只有 extension 才能**调底层 API。
    private let fileManager: FileManager

    init(_ fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }
}

extension FileManagerBox {
    // MARK: - File I/O API（scanner 调这些；不要直接 box.fileManager.xxx()）

    func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    /// Create a private, unique temporary file URL used by local decoders.
    func temporaryURL() -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("llm-monitor-dsh-\(UUID().uuidString)")
    }

    /// 创建并收紧本地缓存目录。token 用量缓存属于用户数据，不能依赖系统 umask。
    func createPrivateDirectory(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
    }

    /// 递归列出目录下全部相对路径（dsh session 发现用）。
    func subpathsOfDirectory(atPath path: String) throws -> [String] {
        try fileManager.subpathsOfDirectory(atPath: path)
    }

    func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: options
        )
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        try fileManager.attributesOfItem(atPath: path)
    }

    /// 在目标同目录中以 0600 创建唯一临时文件，完整写入、fsync、rename，再同步父目录。
    ///
    /// 与 `Data.write(.atomic) -> chmod` 不同，临时文件从诞生起就是 owner-only，
    /// 不存在短暂继承宽松 umask 的窗口；权限设置失败也不会被忽略或留下目标文件。
    ///
    /// rename 一旦成功，目标内容已经更新，之后不能再向调用方抛错让其误以为写入失败。
    /// 因此父目录 fsync 失败采用 best effort + warning：这只表示极端断电场景下目录项
    /// 的 crash durability 可能降低，不改变本次进程可见的成功结果。
    func writePrivate(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw posixError(operation: "open", path: temporaryURL.path)
        }

        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                guard let baseAddress = rawBuffer.baseAddress else { break }
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(operation: "write", path: temporaryURL.path)
                }
                if written == 0 {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(EIO),
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "write made no progress for \(temporaryURL.path)"
                        ]
                    )
                }
                offset += written
            }
        }

        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw posixError(operation: "fchmod", path: temporaryURL.path)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError(operation: "fsync", path: temporaryURL.path)
        }
        guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
            throw posixError(operation: "rename", path: url.path)
        }
        shouldRemoveTemporary = false

        do {
            try synchronizeDirectory(at: directory)
        } catch {
            logWarn(
                "FileManagerBox: 已更新 \(url.path)，但父目录 fsync 失败；"
                    + "本次写入仍视为成功，异常断电耐久性可能降低: \(error.localizedDescription)"
            )
        }
    }

    /// rename 后同步父目录，使目录项更新跨 crash 落盘。
    /// 保持 internal 便于用真实临时目录验证平台行为；生产调用方只应使用 `writePrivate`。
    func synchronizeDirectory(at directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixError(operation: "open directory", path: directory.path)
        }
        defer { Darwin.close(descriptor) }

        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError(operation: "fsync directory", path: directory.path)
        }
    }

    private func posixError(operation: String, path: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(operation) failed for \(path): \(String(cString: strerror(code)))"
            ]
        )
    }
}
