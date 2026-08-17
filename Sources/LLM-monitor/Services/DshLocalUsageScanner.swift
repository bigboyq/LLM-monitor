import Foundation
import Combine

/// Decode the durable JSONL artifacts written by DeepSeek Harness (`dsh`).
///
/// dsh's default persistence format is a zstd-compressed append-only log. The scanner
/// keeps the filesystem path and raw event work outside the main actor, uses a small
/// fingerprint/index cache, and limits both the number of files and the amount of
/// untrusted JSON it will inspect. A decompressor is injectable so tests can exercise
/// the pure parser without requiring a zstd binary.
struct DshLocalUsageScanLimits: Sendable {
    static let production = DshLocalUsageScanLimits(
        maxSessionFiles: 1_024,
        maxTotalRawBytes: 256 * 1024 * 1024,
        maxJSONLLineBytes: 8 * 1024 * 1024,
        maxRecentSamples: 65_536
    )

    let maxSessionFiles: Int
    let maxTotalRawBytes: Int
    let maxJSONLLineBytes: Int
    let maxRecentSamples: Int
}
@MainActor
final class DshLocalUsageScanner: ObservableObject, @unchecked Sendable {
    @Published private(set) var lastResult: DshLocalUsage?
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var lastError: String?

    nonisolated static let defaultSessionsRoot: URL = {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["DSH_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".dsh", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }()

    nonisolated static let defaultCacheDir: URL = {
        let root = defaultSessionsRoot.deletingLastPathComponent()
        return root.appendingPathComponent(".token-monitor", isDirectory: true)
    }()

    typealias Decompressor = @Sendable (Data) throws -> Data

    private let sessionsRoot: URL
    private let cacheDir: URL
    private let fileManager: FileManagerBox
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let decompressor: Decompressor
    private var inFlightTask: Task<Void, Never>?
    private var latestGeneration: UInt64 = 0
    nonisolated static let pipelineMutex = AsyncMutex()

    init(
        sessionsRoot: URL = DshLocalUsageScanner.defaultSessionsRoot,
        cacheDir: URL = DshLocalUsageScanner.defaultCacheDir,
        fileManager: FileManagerBox = FileManagerBox(),
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() },
        decompressor: @escaping Decompressor = { data in try DshLogDecoder.decompress(data) }
    ) {
        self.sessionsRoot = sessionsRoot
        self.cacheDir = cacheDir
        self.fileManager = fileManager
        self.calendar = calendar
        self.now = now
        self.decompressor = decompressor
        self.lastResult = Self.loadCachedResult(
            cacheDir: cacheDir,
            fileManager: fileManager,
            calendar: calendar,
            now: Date()
        )
    }

    nonisolated static func loadCachedResult(
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: Date
    ) -> DshLocalUsage? {
        guard let index = try? loadIndex(cacheDir: cacheDir, fileManager: fileManager),
              let snapshot = index.snapshot else { return nil }
        return rebaseCached(snapshot, calendar: calendar, now: now)
    }

    func scan() {
        guard inFlightTask == nil else { return }
        isScanning = true
        latestGeneration &+= 1
        let startedGeneration = latestGeneration
        inFlightTask = Task { [weak self] in
            await self?.runScan(startedGeneration: startedGeneration)
        }
    }

    func cancelInFlight() {
        latestGeneration &+= 1
        isScanning = false
        inFlightTask?.cancel()
        inFlightTask = nil
    }

    private func runScan(startedGeneration: UInt64) async {
        defer {
            if startedGeneration == latestGeneration {
                isScanning = false
                inFlightTask = nil
            } else {
                logInfo("[dsh-scan] 旧任务 (gen=\(startedGeneration)) defer 跳过状态清理: latest=\(latestGeneration)")
            }
        }

        let sessionsRoot = self.sessionsRoot
        let cacheDir = self.cacheDir
        let fileManager = self.fileManager
        let calendar = self.calendar
        let now = self.now
        let decompressor = self.decompressor
        let work: @Sendable () async throws -> DshLocalUsage = {
            try await Self.pipelineMutex.withLock {
                try await Task.detached(priority: .utility) {
                    try Self.performScanPure(
                        sessionsRoot: sessionsRoot,
                        cacheDir: cacheDir,
                        fileManager: fileManager,
                        calendar: calendar,
                        now: now,
                        decompressor: decompressor,
                        limits: DshLocalUsageScanLimits.production
                    )
                }.value
            }
        }

        await LocalUsageScanRunner.run(
            logTag: "[dsh-scan]",
            startedGeneration: startedGeneration,
            latestGeneration: { [weak self] in self?.latestGeneration ?? 0 },
            work: work,
            applyResult: { result in
                self.lastResult = result
                self.lastError = nil
            },
            applyError: { message in
                self.lastError = message
            }
        )
    }

    /// Pure filesystem scan. The `AsyncMutex` keeps cache read/decode/write and a
    /// possible cancel-triggered rescan serialized; generation guards reject stale
    /// in-memory results.
    nonisolated static func performScanPure(
        sessionsRoot: URL,
        cacheDir: URL,
        fileManager: FileManagerBox,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        decompressor: @escaping Decompressor,
        limits: DshLocalUsageScanLimits = .production
    ) throws -> DshLocalUsage {
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            logInfo("[dsh-scan] sessions 目录不存在: \(sessionsRoot.path)")
            return DshLocalUsage(
                byProvider: [:],
                modelsByProvider: [:],
                sessionsRoot: sessionsRoot.path,
                sessionCount: 0,
                eventCount: 0,
                scannedAt: now()
            )
        }
        try fileManager.createPrivateDirectory(at: cacheDir)

        let filePaths = try fileManager.sessionFileURLs(in: sessionsRoot)
        var snapshots: [DshLogFileSnapshot] = []
        snapshots.reserveCapacity(filePaths.count)
        var currentBytes = 0
        for url in filePaths {
            if snapshots.count >= limits.maxSessionFiles { break }
            guard let snapshot = try? DshLogFileSnapshot(url: url, fileManager: fileManager) else {
                continue
            }
            guard snapshot.sizeBytes > 0 else { continue }
            currentBytes = SaturatingArithmetic.add(currentBytes, snapshot.sizeBytes)
            guard currentBytes <= limits.maxTotalRawBytes else { break }
            snapshots.append(snapshot)
        }
        guard !snapshots.isEmpty else {
            let empty = DshLocalUsage(
                byProvider: [:],
                modelsByProvider: [:],
                sessionsRoot: sessionsRoot.path,
                sessionCount: 0,
                eventCount: 0,
                scannedAt: now()
            )
            try saveIndex(
                DshCacheIndex(version: 4, files: [], snapshot: empty),
                cacheDir: cacheDir,
                fileManager: fileManager
            )
            return empty
        }

        let fingerprint = CacheFingerprint(files: snapshots.map(\.fingerprint))
        var index = try loadIndex(cacheDir: cacheDir, fileManager: fileManager)
        if index.matches(fingerprint), let cached = index.snapshot {
            let scanNow = now()
            let rebased = rebaseCached(cached, calendar: calendar, now: scanNow)
            if rebased != cached {
                index.snapshot = rebased
                try saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
            }
            return rebased
        }

        let scanNow = now()
        let aggregate = try aggregateFiles(
            snapshots: snapshots,
            sessionsRoot: sessionsRoot,
            calendar: calendar,
            decompressor: decompressor,
            limits: limits
        )
        let snapshot = buildSnapshot(
            aggregate: aggregate,
            sessionsRoot: sessionsRoot,
            calendar: calendar,
            now: scanNow,
            limits: limits
        )
        index = DshCacheIndex(version: 4, files: fingerprint.files, snapshot: snapshot)
        try saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
        logInfo(
            "[dsh-scan] ✓ sessions=\(snapshot.sessionCount), providers=\(snapshot.byProvider.count), "
                + "events=\(snapshot.eventCount)"
        )
        return snapshot
    }

    /// Reapply the current seven-day window to a cached snapshot. This keeps a
    /// healthy app from re-reading large logs just because midnight crossed.
    nonisolated static func rebaseCached(
        _ snapshot: DshLocalUsage,
        calendar: Calendar,
        now: Date
    ) -> DshLocalUsage {
        let sampleCutoff = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let rebasedProviders = snapshot.byProvider.mapValues { provider in
            let daily = DailyUsageAggregation.filterLast7Days(
                allDaily: provider.dailyTokenUsage,
                today: calendar.startOfDay(for: now),
                calendar: calendar
            )
            return DshProviderUsage(
                today: daily.last.flatMap { $0.hasActivity ? $0 : nil },
                dailyTokenUsage: daily,
                sessionCount: provider.sessionCount,
                roundCount: provider.roundCount,
                recentSamples: Array(
                    provider.recentSamples
                        .filter { $0.completedAt >= sampleCutoff }
                        .suffix(4_096)
                )
            )
        }
        return DshLocalUsage(
            byProvider: rebasedProviders,
            modelsByProvider: snapshot.modelsByProvider,
            sessionsRoot: snapshot.sessionsRoot,
            sessionCount: snapshot.sessionCount,
            eventCount: snapshot.eventCount,
            scannedAt: snapshot.scannedAt
        )
    }
}

// MARK: - LocalUsageScanner conformance

extension DshLocalUsageScanner: LocalUsageScanner {
    var lastResultPublisher: AnyPublisher<DshLocalUsage?, Never> {
        $lastResult.eraseToAnyPublisher()
    }

    var isScanningPublisher: AnyPublisher<Bool, Never> {
        $isScanning.eraseToAnyPublisher()
    }
}

// MARK: - Parsed data

private struct DshLogFileSnapshot: Sendable {
    let url: URL
    let modifiedAt: Date
    let sizeBytes: Int

    init(url: URL, fileManager: FileManagerBox) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        self.url = url
        self.modifiedAt = (attributes[.modificationDate] as? Date) ?? Date.distantPast
        self.sizeBytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    var fingerprint: DshLogFileFingerprint {
        DshLogFileFingerprint(
            path: url.path,
            modificationMs: modifiedAt.timeIntervalSince1970 * 1_000,
            sizeBytes: sizeBytes
        )
    }
}

private struct DshRawEvent: Decodable {
    let type: String
    let seq: Int?
    let time: Int?
    let data: DshRawEventData?
}

private struct DshRawEventData: Decodable {
    let turn: Int?
    let step: Int?
    let usage: DshRawUsage?
    let provider: String?
    let model: String?
    let contextWindow: Int?
}

private struct DshRawUsage: Decodable {
    let inputTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
}

private struct DshProviderContext: Sendable {
    let provider: String
    let model: String?
}

private struct DshParsedUsage: Sendable {
    let timestamp: Date
    let inputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let turn: Int?
    let step: Int?
    let seq: Int?
    let provider: String
    let model: String?
    let sessionID: String
}

private struct DshFileParseResult: Sendable {
    let usages: [DshParsedUsage]
    let activeProviders: Set<String>
}

private struct DshMutableProviderAggregate: Sendable {
    var daily: [Date: DshDailyUsage] = [:]
    var turnsByDay: [Date: Set<String>] = [:]
    var sessions: Set<String> = []
    var models: Set<String> = []
    var recentSamples: [LocalTokenUsageSample] = []
}

private struct DshAggregate: Sendable {
    var providers: [String: DshMutableProviderAggregate] = [:]
    var sessions: Set<String> = []
    var eventCount: Int = 0
    var modelProviders: [String: Set<String>] = [:]
}

// MARK: - Parsing helpers

private extension DshLocalUsageScanner {
    private nonisolated static func aggregateFiles(
        snapshots: [DshLogFileSnapshot],
        sessionsRoot: URL,
        calendar: Calendar,
        decompressor: @escaping Decompressor,
        limits: DshLocalUsageScanLimits
    ) throws -> DshAggregate {
        var aggregate = DshAggregate()
        for snapshot in snapshots.sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
            try Task.checkCancellation()
            let data: Data
            if snapshot.url.lastPathComponent.lowercased().hasSuffix(".zstd")
                || snapshot.url.lastPathComponent.lowercased().hasSuffix(".zst") {
                data = try decompressor(try Data(contentsOf: snapshot.url))
            } else {
                data = try Data(contentsOf: snapshot.url)
            }
            let result = try parseFile(
                data: data,
                sessionID: snapshot.url.deletingLastPathComponent().lastPathComponent,
                limits: limits
            )
            guard !result.usages.isEmpty else { continue }
            for usage in result.usages {
                try Task.checkCancellation()
                add(usage, to: &aggregate, calendar: calendar, limits: limits)
            }
        }
        return aggregate
    }

    private nonisolated static func parseFile(
        data: Data,
        sessionID: String,
        limits: DshLocalUsageScanLimits
    ) throws -> DshFileParseResult {
        var context: DshProviderContext?
        var usages: [DshParsedUsage] = []
        var activeProviders = Set<String>()
        var seen = Set<String>()
        let decoder = JSONDecoder()
        var offset = 0
        var lineCount = 0
        while offset < data.count {
            try Task.checkCancellation()
            let searchStart = data.index(data.startIndex, offsetBy: offset)
            let newline = data[searchStart...].firstIndex(of: 0x0A) ?? data.endIndex
            let lineLength = newline - offset
            lineCount += 1
            if lineLength > limits.maxJSONLLineBytes {
                offset = newline == data.endIndex ? data.endIndex : newline + 1
                continue
            }
            if lineLength > 0 {
                let line = data.subdata(in: offset..<newline)
                if let event = try? decoder.decode(DshRawEvent.self, from: line) {
                    if event.type == "request/context" {
                        let provider = normalizedProvider(event.data?.provider)
                        if provider != "unknown" {
                            context = DshProviderContext(
                                provider: provider,
                                model: normalizedOptionalString(event.data?.model)
                            )
                        }
                    } else if event.type == "assistant/message",
                              let usage = event.data?.usage,
                              let timestamp = event.time.map({ Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }) {
                        let provider = context?.provider ?? "unknown"
                        let key = usageKey(
                            sessionID: sessionID,
                            provider: provider,
                            turn: event.data?.turn,
                            step: event.data?.step,
                            seq: event.seq
                        )
                        guard seen.insert(key).inserted else { continue }
                        let parsed = normalizeUsage(usage)
                        usages.append(DshParsedUsage(
                            timestamp: timestamp,
                            inputTokens: parsed.input,
                            cacheReadTokens: parsed.cacheRead,
                            cacheWriteTokens: parsed.cacheWrite,
                            outputTokens: parsed.output,
                            reasoningTokens: parsed.reasoning,
                            turn: event.data?.turn,
                            step: event.data?.step,
                            seq: event.seq,
                            provider: provider,
                            model: context?.model,
                            sessionID: sessionID
                        ))
                        activeProviders.insert(provider)
                    }
                }
            }
            offset = newline == data.endIndex ? data.endIndex : newline + 1
            if lineCount > limits.maxSessionFiles * 10_000 { break }
        }
        return DshFileParseResult(usages: usages, activeProviders: activeProviders)
    }

    private nonisolated static func add(
        _ usage: DshParsedUsage,
        to aggregate: inout DshAggregate,
        calendar: Calendar,
        limits: DshLocalUsageScanLimits
    ) {
        let day = calendar.startOfDay(for: usage.timestamp)
        var provider = aggregate.providers[usage.provider, default: DshMutableProviderAggregate()]
        let existing = provider.daily[day]
            ?? DshDailyUsage(dayStart: day)
        let visibleOutput = max(
            0,
            usage.outputTokens - usage.reasoningTokens
        )
        provider.daily[day] = DshDailyUsage(
            dayStart: day,
            inputTokens: SaturatingArithmetic.add(existing.inputTokens, usage.inputTokens),
            cacheReadTokens: SaturatingArithmetic.add(existing.cacheReadTokens, usage.cacheReadTokens),
            cacheWriteTokens: SaturatingArithmetic.add(existing.cacheWriteTokens, usage.cacheWriteTokens),
            outputTokens: SaturatingArithmetic.add(existing.outputTokens, visibleOutput),
            reasoningTokens: SaturatingArithmetic.add(existing.reasoningTokens, usage.reasoningTokens),
            totalTokens: SaturatingArithmetic.add(
                existing.totalTokens,
                SaturatingArithmetic.sum(
                    usage.inputTokens,
                    usage.cacheReadTokens,
                    usage.outputTokens
                )
            ),
            turns: existing.turns,
            rounds: SaturatingArithmetic.add(existing.rounds, 1)
        )
        let turnKey = usage.turn.map { "\(usage.sessionID):turn:\($0)" } ?? "event:\(usage.sessionID):\(usage.seq ?? 0)"
        if provider.turnsByDay[day, default: []].insert(turnKey).inserted {
            provider.daily[day] = provider.daily[day]?.withIncrementedTurns()
        }
        provider.sessions.insert(usage.sessionID)
        if let model = usage.model, !model.isEmpty {
            provider.models.insert(model)
        }
        let promptID = usage.turn.map {
            "dsh:\(usage.sessionID):turn:\($0)"
        } ?? "dsh:\(usage.sessionID):event:\(usage.seq ?? 0):\(usage.timestamp.timeIntervalSince1970)"
        let sample = LocalTokenUsageSample(
            completedAt: usage.timestamp,
            modelName: usage.model,
            promptID: promptID,
            inputTokens: SaturatingArithmetic.add(usage.inputTokens, usage.cacheReadTokens),
            cachedInputTokens: usage.cacheReadTokens,
            outputTokens: visibleOutput,
            reasoningOutputTokens: usage.reasoningTokens,
            // DSH stores uncached input and cache-read tokens separately. We
            // fold them into `inputTokens` here so all scanners feed
            // `tokenComponents` with the same cache-inclusive input bucket.
            // The `sourceProviderID` marker stays so diagnostics can still
            // tell where each sample came from.
            sourceProviderID: "dsh:\(usage.provider)"
        )
        provider.recentSamples.append(sample)
        aggregate.providers[usage.provider] = provider
        aggregate.sessions.insert(usage.sessionID)
        aggregate.eventCount = SaturatingArithmetic.add(aggregate.eventCount, 1)
        if let model = usage.model, !model.isEmpty {
            aggregate.modelProviders[usage.provider, default: []].insert(model)
        }
    }

    private nonisolated static func buildSnapshot(
        aggregate: DshAggregate,
        sessionsRoot: URL,
        calendar: Calendar,
        now: Date,
        limits: DshLocalUsageScanLimits = .production
    ) -> DshLocalUsage {
        let today = calendar.startOfDay(for: now)
        var providers: [String: DshProviderUsage] = [:]
        for (providerID, mutable) in aggregate.providers {
            let allDaily = mutable.daily.values.sorted { $0.dayStart < $1.dayStart }
            let recent7 = DailyUsageAggregation.filterLast7Days(
                allDaily: allDaily,
                today: today,
                calendar: calendar
            )
            let sortedSamples = mutable.recentSamples.sorted { $0.completedAt < $1.completedAt }
            let boundedSamples = sortedSamples.count > limits.maxRecentSamples
                ? Array(sortedSamples.suffix(limits.maxRecentSamples))
                : sortedSamples
            providers[providerID] = DshProviderUsage(
                today: recent7.last.flatMap { $0.hasActivity ? $0 : nil },
                dailyTokenUsage: recent7,
                sessionCount: mutable.sessions.count,
                roundCount: SaturatingArithmetic.sum(allDaily.lazy.map(\.rounds)),
                recentSamples: boundedSamples
            )
        }
        return DshLocalUsage(
            byProvider: providers,
            modelsByProvider: aggregate.modelProviders.mapValues { $0.sorted() },
            sessionsRoot: sessionsRoot.path,
            sessionCount: aggregate.sessions.count,
            eventCount: aggregate.eventCount,
            scannedAt: now
        )
    }

    private nonisolated static func normalizeUsage(_ usage: DshRawUsage) -> (
        input: Int,
        cacheRead: Int,
        cacheWrite: Int,
        output: Int,
        reasoning: Int
    ) {
        (
            max(0, usage.inputTokens ?? 0),
            max(0, usage.cacheReadTokens ?? 0),
            max(0, usage.cacheWriteTokens ?? 0),
            max(0, usage.outputTokens ?? 0),
            max(0, usage.reasoningTokens ?? 0)
        )
    }

    private nonisolated static func usageKey(
        sessionID: String,
        provider: String,
        turn: Int?,
        step: Int?,
        seq: Int?
    ) -> String {
        [sessionID, provider, turn.map(String.init) ?? "?", step.map(String.init) ?? "?", seq.map(String.init) ?? "?"]
            .joined(separator: ":")
    }

    private nonisolated static func normalizedProvider(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "unknown" : value
    }

    private nonisolated static func normalizedOptionalString(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

private extension DshDailyUsage {
    func withIncrementedTurns() -> DshDailyUsage {
        DshDailyUsage(
            dayStart: dayStart,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            turns: SaturatingArithmetic.add(turns, 1),
            rounds: rounds
        )
    }
}

// MARK: - Fingerprint/index

private struct DshLogFileFingerprint: Codable, Equatable, Sendable {
    let path: String
    let modificationMs: Double
    let sizeBytes: Int
}

private struct CacheFingerprint: Sendable {
    let files: [DshLogFileFingerprint]

    func matches(_ other: CacheFingerprint) -> Bool {
        files == other.files
    }
}

private struct DshCacheIndex: Codable, Equatable, Sendable {
    let version: Int
    let files: [DshLogFileFingerprint]
    var snapshot: DshLocalUsage?
}

private extension DshCacheIndex {
    func matches(_ fingerprint: CacheFingerprint) -> Bool {
        version == 4 && files == fingerprint.files
    }
}

private extension DshLocalUsageScanner {
    private nonisolated static func loadIndex(
        cacheDir: URL,
        fileManager: FileManagerBox
    ) throws -> DshCacheIndex {
        try ScannerIndexIO.loadIndex(
            cacheDir: cacheDir,
            fileManager: fileManager,
            currentVersion: 4,
            empty: DshCacheIndex(version: 4, files: [], snapshot: nil),
            version: { $0.version },
            logTag: "[dsh-scan]"
        )
    }

    private nonisolated static func saveIndex(
        _ index: DshCacheIndex,
        cacheDir: URL,
        fileManager: FileManagerBox
    ) throws {
        try ScannerIndexIO.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
    }
}

// MARK: - DSH zstd decoder

/// Resolve the dsh default compression format without making a zstd CLI a hard
/// runtime dependency. A compatible zstd binary is preferred; Node 22+ is a
/// fallback because dsh itself requires modern Node and exposes zstd in zlib.
enum DshLogDecoder {
    enum DecoderError: LocalizedError {
        case unavailable
        case commandFailed(executable: String, status: Int32, stderr: String)
        case outputTooLarge(bytes: Int)
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
            case .unsupportedData:
                return "无法读取 dsh session 数据"
            }
        }
    }

    nonisolated static func decompress(_ data: Data) throws -> Data {
        let fm = FileManagerBox()
        if let zstd = existingExecutable(named: "zstd", preferred: ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]) {
            do {
                return try runZstd(data: data, executable: zstd, fileManager: fm)
            } catch {
                logWarn("[dsh-scan] zstd CLI 解压失败，尝试 Node zlib: \(error.localizedDescription)")
            }
        }
        if let node = existingExecutable(
            named: "node",
            preferred: ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        ) {
            return try runNode(data: data, executable: node, fileManager: fm)
        }
        throw DecoderError.unavailable
    }

    private static func runZstd(
        data: Data,
        executable: URL,
        fileManager: FileManagerBox
    ) throws -> Data {
        let temporary = fileManager.temporaryURL()
        try fileManager.writePrivate(data, to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        let result = try ProcessRunner.run(
            executable: executable,
            arguments: ["-q", "-d", "-c", temporary.path],
            timeout: 30
        )
        guard result.terminationStatus == 0 else {
            throw DecoderError.commandFailed(
                executable: executable.lastPathComponent,
                status: result.terminationStatus,
                stderr: result.standardError
            )
        }
        guard let output = result.standardOutput.data(using: .utf8) else {
            throw DecoderError.unsupportedData
        }
        try checkOutputSize(output.count)
        return output
    }

    private static func runNode(
        data: Data,
        executable: URL,
        fileManager: FileManagerBox
    ) throws -> Data {
        let temporary = fileManager.temporaryURL()
        try fileManager.writePrivate(data, to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        let script = """
        const fs = require("node:fs");
        const zlib = require("node:zlib");
        process.stdout.write(zlib.zstdDecompressSync(fs.readFileSync(process.argv[1])));
        """
        let result = try ProcessRunner.run(
            executable: executable,
            arguments: ["-e", script, temporary.path],
            timeout: 30
        )
        guard result.terminationStatus == 0 else {
            throw DecoderError.commandFailed(
                executable: executable.lastPathComponent,
                status: result.terminationStatus,
                stderr: result.standardError
            )
        }
        guard let output = result.standardOutput.data(using: .utf8) else {
            throw DecoderError.unsupportedData
        }
        try checkOutputSize(output.count)
        return output
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

    private static func checkOutputSize(_ bytes: Int) throws {
        let maximum = 256 * 1024 * 1024
        guard bytes <= maximum else { throw DecoderError.outputTooLarge(bytes: bytes) }
    }
}
