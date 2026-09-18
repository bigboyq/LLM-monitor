import Foundation

extension AntigravityFetcher {
    // MARK: - Discovery

    /// Antigravity 后端进程种类。
    ///
    /// - `ide`: `Antigravity.app` 自带的 `language_server`（需要 `--csrf_token` 鉴权）
    /// - `cli`: Antigravity CLI（`agy` / `antigravity-cli`，内嵌 language_server，不暴露 CSRF）
    enum ProcessKind: String, Sendable {
        case ide
        case cli
    }

    struct ServerInfo: Sendable {
        let pid: Int
        let httpsPort: Int
        let csrfToken: String?
        let kind: ProcessKind
    }

    struct ProcessMatch: Sendable {
        let pid: Int
        let command: String
        let kind: ProcessKind
    }

    nonisolated static func discoverServerAsync() async throws -> ServerInfo {
        try Task.checkCancellation()
        let candidates = discoverProcessCandidates()
        guard !candidates.isEmpty else {
            throw QuotaError.networkError("未发现 Antigravity 或 agy CLI 进程，请先启动 Antigravity 并完成登录")
        }

        for candidate in candidates {
            guard isUsableProcessCandidate(candidate) else {
                logInfo("[antigravity] 忽略缺少 --csrf_token 的 IDE 进程 pid=\(candidate.pid)")
                continue
            }
            let token = extractFlag(named: "--csrf_token", from: candidate.command)
            if let port = try? discoverHTTPSPort(for: candidate.pid) {
                logInfo("[antigravity] 命中 \(candidate.kind.rawValue) 进程 pid=\(candidate.pid) port=\(port)")
                return ServerInfo(
                    pid: candidate.pid,
                    httpsPort: port,
                    csrfToken: token,
                    kind: candidate.kind
                )
            }
        }

        throw QuotaError.networkError("发现 Antigravity 进程但未监听本地端口，请确认 Antigravity 或 CLI 已完成登录")
    }

    /// 分类只回答“是否像 Antigravity 进程”；真正用于 RPC 还必须满足认证前提。
    /// CLI 不使用 CSRF，IDE 必须带非空 `--csrf_token`。
    nonisolated static func isUsableProcessCandidate(_ candidate: ProcessMatch) -> Bool {
        candidate.kind == .cli
            || StringUtilities.trimmedOrNil(
                extractFlag(named: "--csrf_token", from: candidate.command)
            ) != nil
    }

    /// 默认元数据发现只供 fetcher 的初始化闭包使用，不作为公开 discovery API。
    nonisolated static func defaultMetadataServers() -> [ServerInfo] {
        let candidates = discoverProcessCandidates()
        var servers: [ServerInfo] = []
        for candidate in candidates {
            guard isUsableProcessCandidate(candidate) else {
                logInfo("[antigravity] 忽略缺少 --csrf_token 的 IDE 进程 pid=\(candidate.pid)")
                continue
            }
            let token = extractFlag(named: "--csrf_token", from: candidate.command)
            if let port = try? discoverHTTPSPort(for: candidate.pid) {
                servers.append(ServerInfo(
                    pid: candidate.pid,
                    httpsPort: port,
                    csrfToken: token,
                    kind: candidate.kind
                ))
            }
        }
        return servers
    }

    /// 扫描所有 `language_server` 进程 + `agy` / `antigravity-cli` 进程，
    /// 按 (kind 优先级, rank, pid) 排序返回。IDE 优先于 CLI（IDE 通常带完整 quota 数据）。
    private nonisolated static func discoverProcessCandidates() -> [ProcessMatch] {
        let lsLines = runPgrepLines(["-fal", "language_server"])
        let cliLines = runPgrepLines(["-fal", "agy"])
            + runPgrepLines(["-fal", "antigravity-cli"])

        var seen = Set<Int>()
        var matches: [ProcessMatch] = []

        for (rawLine, kind) in lsLines.map({ ($0, ProcessKind.ide) })
                              + cliLines.map({ ($0, ProcessKind.cli) }) {
            guard let match = parseProcessLine(rawLine, defaultKind: kind) else { continue }
            // 同一行可能被多个 pgrep 命中（同进程同时含 "language_server" + "agy" 等极端情况）
            guard !seen.contains(match.pid) else { continue }
            seen.insert(match.pid)
            matches.append(match)
        }

        return matches.sorted { lhs, rhs in
            // IDE 优先
            if lhs.kind != rhs.kind {
                return lhs.kind == .ide
            }
            let lhsRank = processRank(for: lhs.command)
            let rhsRank = processRank(for: rhs.command)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.pid < rhs.pid
        }
    }

    /// 跑一次 pgrep，返回 (trimmed line) 列表。`pgrep` 无匹配时 exit 1，按"无候选"处理。
    private nonisolated static func runPgrepLines(_ args: [String]) -> [String] {
        guard let output = try? runProcess("/usr/bin/pgrep", args) else { return [] }
        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 把 pgrep 单行解析为 ProcessMatch。`defaultKind` 由 pgrep 的 pattern 决定（IDE / CLI），
    /// 但仍然走一次 `classify` 防止误匹配。
    nonisolated static func parseProcessLine(_ line: String, defaultKind: ProcessKind) -> ProcessMatch? {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
        let command = parts[1]
        guard let classified = classify(command: command) else { return nil }
        // 只接受与 defaultKind 一致的分类，避免 pgrep "language_server" 把 agy 进程
        // （命令行里恰好也有 language_server 字样）当 IDE。
        guard classified == defaultKind else { return nil }
        return ProcessMatch(pid: pid, command: command, kind: classified)
    }

    /// 命令行分类：返回 nil 表示与 Antigravity 无关。
    ///
    /// `Antigravity IDE.app`（`--app_data_dir antigravity-ide`）已剥离支持，
    /// 命中其产品特征的命令先行排除，不再作为 quota / RPC 候选。
    nonisolated static func classify(command: String) -> ProcessKind? {
        let lower = command.lowercased()
        guard !isUnsupportedIDEAppCommand(lower) else { return nil }
        if isLanguageServerBinary(lower), lower.contains("antigravity") {
            return .ide
        }
        if isAntigravityCliBinary(lower) {
            return .cli
        }
        return nil
    }

    /// 识别已剥离支持的 `Antigravity IDE.app` 产品特征。
    ///
    /// 该产品的 language_server 一定带 `--app_data_dir antigravity-ide` 或运行在
    /// `Antigravity IDE.app` bundle 内；带架构后缀的二进制名
    /// （`language_server_macos_arm` 等）也只存在于该产品——旧版 `Antigravity.app`
    /// 始终使用裸名 `language_server`，由 `isLanguageServerBinary` 自然排除。
    nonisolated static func isUnsupportedIDEAppCommand(_ lowerCommand: String) -> Bool {
        lowerCommand.contains("antigravity ide.app")
            || lowerCommand.contains("antigravity-ide")
            || lowerCommand.range(
                of: #"(^|[/\\])language[-_]server(_[a-z0-9]+)+"#,
                options: .regularExpression
            ) != nil
    }

    /// 识别 `Antigravity.app` 自带的 `language_server` 二进制（裸名，可带 `.exe`），
    /// 装在 `Contents/Resources/bin/language_server`。
    ///
    /// 带架构/平台后缀的二进制（`language_server_macos_arm`、
    /// `language_server_macos_x64` 等）是 `Antigravity IDE.app` 专属形态，
    /// 该产品已剥离支持，这里不再识别；见 `isUnsupportedIDEAppCommand`。
    nonisolated static func isLanguageServerBinary(_ lowerCommand: String) -> Bool {
        let pattern = #"(^|[/\\])language[-_]server(\.exe)?(\s|$)"#
        return lowerCommand.range(of: pattern, options: .regularExpression) != nil
    }

    /// 识别 Antigravity CLI 二进制（`agy` / `antigravity-cli`），路径锚定避免 `stragy` 误匹配。
    /// 同时支持 macOS / Linux 的 `/` 和 Windows 的 `\`。
    private nonisolated static func isAntigravityCliBinary(_ lowerCommand: String) -> Bool {
        let agyPattern = #"(^|[/\\])agy(\.exe)?(\s|$)"#
        if lowerCommand.range(of: agyPattern, options: .regularExpression) != nil { return true }
        let cliPattern = #"(^|[/\\])(antigravity[-_]cli)(\.exe)?(\s|$)"#
        return lowerCommand.range(of: cliPattern, options: .regularExpression) != nil
    }

    private nonisolated static func processRank(for command: String) -> Int {
        // 与原逻辑一致：带 workspace + lsp + csrf 排第一；其他 csrf 排第二；其余排最后
        let hasWorkspace = command.contains("--workspace_id")
        let isLSP = command.contains("--enable_lsp")
        let hasCsrf = command.contains("--csrf_token")

        if hasWorkspace && isLSP && hasCsrf { return 0 }
        if isLSP && hasCsrf { return 1 }
        if hasCsrf { return 2 }
        return 9
    }

    private nonisolated static func discoverHTTPSPort(for pid: Int) throws -> Int? {
        let output = try runProcess("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN"])
        let lines = output
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .map(String.init)

        for line in lines {
            if let port = extractPort(from: line) {
                return port
            }
        }
        return nil
    }

    /// 在发送携带 CSRF 的请求前再次确认发现时的 PID 仍监听同一个 loopback 端口。
    /// 这不能从密码学上认证本地服务，但能显著缩小“原进程退出、端口被其他进程
    /// 抢占”这一 TOCTOU 窗口。
    nonisolated static func serverStillOwnsEndpoint(_ server: ServerInfo) -> Bool {
        guard let output = try? runProcess(
            "/usr/sbin/lsof",
            ["-nP", "-a", "-p", "\(server.pid)", "-iTCP:\(server.httpsPort)", "-sTCP:LISTEN"]
        ) else {
            return false
        }
        return output
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .map(String.init)
            .contains { extractPort(from: $0) == server.httpsPort }
    }

    private nonisolated static func extractFlag(named name: String, from command: String) -> String? {
        guard let range = command.range(of: "\(name) ") else { return nil }
        let value = command[range.upperBound...]
        return value.split(separator: " ", maxSplits: 1).first.map(String.init)
    }

    private nonisolated static func extractPort(from line: String) -> Int? {
        guard let range = line.range(of: #"127\.0\.0\.1:(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(line[range])
        guard let portString = matched.split(separator: ":").last else { return nil }
        return Int(portString)
    }

    private nonisolated static func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
        do {
            let result = try ProcessRunner.run(
                executable: URL(fileURLWithPath: executable),
                arguments: arguments,
                timeout: 3
            )
            guard result.terminationStatus == 0 else {
                let detail = result.standardError.isEmpty ? result.standardOutput : result.standardError
                throw QuotaError.networkError(
                    "\(URL(fileURLWithPath: executable).lastPathComponent) 失败: \(detail)"
                )
            }
            return result.standardOutput
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as QuotaError {
            throw error
        } catch {
            logWarn("[antigravity] 无法运行 \(executable): \(HTTPRequestLogSanitizer.networkErrorDescription(error))")
            throw QuotaError.networkError("无法运行 Antigravity 进程")
        }
    }

}
