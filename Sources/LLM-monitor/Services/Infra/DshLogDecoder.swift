import Foundation

// MARK: - DSH zstd decoder

/// Resolve the dsh default compression format without making a zstd CLI a hard
/// runtime dependency. A compatible zstd binary is preferred; Node 22+ is a
/// fallback because dsh itself requires modern Node and exposes zstd in zlib.
enum DshLogDecoder {
    enum DecoderError: LocalizedError {
        case unavailable
        case commandFailed(executable: String, status: Int32, stderr: String)
        case outputTooLarge(bytes: Int)
        case inputTooLarge(bytes: Int)
        case unsupportedData

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "找不到 dsh session 的 zstd 解压器（请安装 zstd，或使用 Node 22+）"
            case .commandFailed(let executable, let status, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "zstd 解压失败（\(executable)，状态 \(status)）\(detail.isEmpty ? "" : "：\(detail)")"
            case .outputTooLarge(let bytes):
                return "zstd 解压结果过大（\(bytes) bytes）"
            case .inputTooLarge(let bytes):
                return "zstd 压缩输入过大（\(bytes) bytes）"
            case .unsupportedData:
                return "无法读取 dsh session 数据"
            }
        }
    }

    /// 流式与注入式解压共用的单文件解压结果上限。maxTotalRawBytes（1GB）是按
    /// 压缩字节口径的整轮扫描预算；zstd 压缩比高，这里允许单个 session 解压后
    /// 达到同量级（1GB 明文），否则大 session 会以 outputTooLarge 永久失败
    /// （文件被隔离且每轮重试，永远进不了统计）。
    nonisolated static let maximumDecompressedBytes = 1024 * 1024 * 1024

    /// 注入式内存解压的结果校验：与流式路径的 checkOutputSize 同一上限，
    /// 防止测试外的注入点把无界解压结果整体载入堆。
    nonisolated static func checkDecompressedByteCount(_ count: Int) throws {
        guard count <= maximumDecompressedBytes else {
            throw DecoderError.outputTooLarge(bytes: count)
        }
    }

    /// Stream decompressed output into a private temporary file. The scanner then
    /// parses that file in bounded chunks instead of keeping compressed input and
    /// decompressed JSONL in the application heap at the same time.
    nonisolated static func decompressToFile(
        input: URL,
        output: URL,
        fileManager: FileManagerBox
    ) throws {
        if let zstd = existingExecutable(named: "zstd", preferred: ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]) {
            do {
                try runZstdToFile(input: input, output: output, executable: zstd, fileManager: fileManager)
                return
            } catch {
                logWarn("[dsh-scan] zstd CLI 流式解压失败，尝试 Node zlib: \(error.localizedDescription)")
            }
        }
        if let node = existingExecutable(
            named: "node",
            preferred: ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        ) {
            try runNodeToFile(input: input, output: output, executable: node, fileManager: fileManager)
            return
        }
        throw DecoderError.unavailable
    }

    private static func runZstdToFile(
        input: URL,
        output: URL,
        executable: URL,
        fileManager: FileManagerBox
    ) throws {
        let result = try ProcessRunner.run(
            executable: executable,
            arguments: ["-q", "-d", "-c", input.path],
            timeout: 30,
            standardOutputFile: output
        )
        guard result.terminationStatus == 0 else {
            throw DecoderError.commandFailed(
                executable: executable.lastPathComponent,
                status: result.terminationStatus,
                stderr: result.standardError
            )
        }
        try checkOutputSize(fileManager.attributesOfItem(atPath: output.path)[.size] as? NSNumber)
    }

    private static func runNodeToFile(
        input: URL,
        output: URL,
        executable: URL,
        fileManager: FileManagerBox
    ) throws {
        let script = """
        const fs = require("node:fs");
        const zlib = require("node:zlib");
        const input = fs.createReadStream(process.argv[1]);
        const output = zlib.createZstdDecompress();
        output.on("error", (error) => { console.error(error.message); process.exitCode = 1; });
        input.on("error", (error) => { console.error(error.message); process.exitCode = 1; });
        output.pipe(process.stdout);
        input.pipe(output);
        """
        let result = try ProcessRunner.run(
            executable: executable,
            arguments: ["-e", script, input.path],
            timeout: 30,
            standardOutputFile: output
        )
        guard result.terminationStatus == 0 else {
            throw DecoderError.commandFailed(
                executable: executable.lastPathComponent,
                status: result.terminationStatus,
                stderr: result.standardError
            )
        }
        try checkOutputSize(fileManager.attributesOfItem(atPath: output.path)[.size] as? NSNumber)
    }

    private static func existingExecutable(
        named name: String,
        preferred: [String]
    ) -> URL? {
        let fm = FileManagerBox()
        if let override = ProcessInfo.processInfo.environment[name.uppercased()] {
            let url = URL(fileURLWithPath: override)
            if fm.fileExists(atPath: url.path) { return url }
        }
        for path in preferred where fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func checkOutputSize(_ bytes: NSNumber?) throws {
        guard let bytes else { throw DecoderError.unsupportedData }
        // 用 int64Value 比较：intValue 是 Int32，超过 2GB 时会溢出为负数绕过上限。
        guard bytes.int64Value <= Int64(maximumDecompressedBytes) else {
            throw DecoderError.outputTooLarge(bytes: Int(bytes.int64Value))
        }
    }
}
