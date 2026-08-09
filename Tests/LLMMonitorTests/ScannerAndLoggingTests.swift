import XCTest
@testable import LLM_monitor

final class ScannerAndLoggingTests: XCTestCase {

    override func tearDown() {
        MinimaxLocalUsageScanner.testGate = nil
        MinimaxLocalUsageScanner.testSaveIndexHook = nil
        AntigravityLocalUsageScanner.testGate = nil
        AntigravityLocalUsageScanner.testSaveIndexHook = nil
        super.tearDown()
    }

    // MARK: - AppLog 0600 权限 / 轮转决策 / 轮转行为

    /// AppLog 文件权限 4 in 1：新建 0600 / 收紧已有 0644 → 0600 / setLogFilePermissions 不创建 / rotate 后新建仍 0600
    func testAppLogFilePermissions() {
        // 1. 文件不存在 → ensureLogFile 后应有 0600 权限
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-create-\(UUID().uuidString).txt"
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath))

            AppLog.ensureLogFile(at: URL(fileURLWithPath: tempPath))

            XCTAssertTrue(FileManager.default.fileExists(atPath: tempPath))
            let perms = (try? FileManager.default.attributesOfItem(atPath: tempPath)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(perms, 0o600, "新建 log 文件应有 0600 权限，实际：\(perms.map { String(format: "%o", $0) } ?? "nil")")
        }
        // 2. 文件已存在 0644 → ensureLogFile 后收紧到 0600
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-tighten-\(UUID().uuidString).txt"
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            FileManager.default.createFile(
                atPath: tempPath, contents: nil,
                attributes: [.posixPermissions: NSNumber(value: 0o644)]
            )
            let prePerms = (try? FileManager.default.attributesOfItem(atPath: tempPath)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(prePerms, 0o644, "前置：预创建 0644")

            AppLog.ensureLogFile(at: URL(fileURLWithPath: tempPath))

            let postPerms = (try? FileManager.default.attributesOfItem(atPath: tempPath)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(postPerms, 0o600, "已存在文件应被收紧到 0600")
        }
        // 3. setLogFilePermissions 不创建文件（仅收紧已存在的）
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-noop-\(UUID().uuidString).txt"
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath))

            AppLog.setLogFilePermissions(URL(fileURLWithPath: tempPath))

            XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath), "setLogFilePermissions 不应创建文件")
        }
        // 4. rotate 后新 active 文件用 createFile 路径, 权限 0600
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-rotate-perm-\(UUID().uuidString).txt"
            let fileURL = URL(fileURLWithPath: tempPath)
            defer {
                try? FileManager.default.removeItem(atPath: tempPath)
                try? FileManager.default.removeItem(atPath: tempPath + ".1")
            }
            AppLog.ensureLogFile(at: fileURL)
            AppLog.rotateLogFile(at: fileURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "rotate 后 active 应不存在")
            // 重新创建 (模拟下次写入) → 仍是 0600
            AppLog.ensureLogFile(at: fileURL)
            let perms = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(perms, 0o600, "rotate 后新建的 log 文件应有 0600 权限")
        }
    }

    /// shouldRotate 决策 3 in 1：超阈值 rotate / 低于阈值不 rotate / 文件缺失不 rotate
    func testAppLogShouldRotate() throws {
        // 1. 超过阈值 → rotate
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-over-\(UUID().uuidString).txt"
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            // 1MB 文件 + 4.5MB 新内容 = 5.5MB > 5MB 阈值 → 应该 rotate
            try Data(count: 1 * 1024 * 1024).write(to: URL(fileURLWithPath: tempPath))
            XCTAssertTrue(
                AppLog.shouldRotate(fileURL: URL(fileURLWithPath: tempPath), additionalBytes: Int(4.5 * 1024 * 1024)),
                "1MB + 4.5MB > 5MB 阈值, 应该 rotate"
            )
        }
        // 2. 低于阈值 → 不 rotate
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-under-\(UUID().uuidString).txt"
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            try Data(count: 1 * 1024 * 1024).write(to: URL(fileURLWithPath: tempPath))
            XCTAssertFalse(
                AppLog.shouldRotate(fileURL: URL(fileURLWithPath: tempPath), additionalBytes: 1 * 1024 * 1024),
                "1MB + 1MB < 5MB 阈值, 不应 rotate"
            )
        }
        // 3. 文件缺失 → 不 rotate (write 路径会创建新文件)
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-miss-\(UUID().uuidString).txt"
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            XCTAssertFalse(
                AppLog.shouldRotate(fileURL: URL(fileURLWithPath: tempPath), additionalBytes: 1000)
            )
        }
    }

    /// rotate 行为 2 in 1：3 个文件全在时 shift / 只有 active 时也能正常 rotate
    func testAppLogRotateBehavior() throws {
        // 1. 初始 active + .1 + .2 → rotate 后内容 shift, 原 active 进 .1, 原 .1 进 .2
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-shift-\(UUID().uuidString).txt"
            let fileURL = URL(fileURLWithPath: tempPath)
            let backup1URL = URL(fileURLWithPath: "\(tempPath).1")
            let backup2URL = URL(fileURLWithPath: "\(tempPath).2")
            defer {
                for p in [fileURL, backup1URL, backup2URL] { try? FileManager.default.removeItem(at: p) }
            }

            try Data(count: 100).write(to: fileURL)   // active = 100
            try Data(count: 200).write(to: backup1URL) // .1 = 200
            try Data(count: 300).write(to: backup2URL) // .2 = 300

            AppLog.rotateLogFile(at: fileURL)

            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                          "active 旋转后应不存在, 下次 write 创建新的")
            XCTAssertEqual(try Data(contentsOf: backup1URL).count, 100, ".1 现在应该是原 active (100 bytes) 的内容")
            XCTAssertEqual(try Data(contentsOf: backup2URL).count, 200, ".2 现在应该是原 .1 (200 bytes) 的内容")
        }
        // 2. 单独 active (没有 .1 .2) 时 rotate 也能正常 shift
        do {
            let tempPath = NSTemporaryDirectory() + "test-applog-activeonly-\(UUID().uuidString).txt"
            let fileURL = URL(fileURLWithPath: tempPath)
            let backup1URL = URL(fileURLWithPath: "\(tempPath).1")
            defer {
                try? FileManager.default.removeItem(at: fileURL)
                try? FileManager.default.removeItem(at: backup1URL)
            }
            try Data(count: 50).write(to: fileURL)

            AppLog.rotateLogFile(at: fileURL)

            XCTAssertTrue(FileManager.default.fileExists(atPath: backup1URL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
            XCTAssertEqual(try Data(contentsOf: backup1URL).count, 50)
        }
    }

    /// os.Logger 4 个 level 走 `.private` 不崩 (实际 privacy 靠 Xcode 静态分析 / Console.app 验证)
    func testAppLogOsLogPrivateDoesNotCrash() {
        AppLog.shared.info({ "test private path info" })
        AppLog.shared.debug({ "test private path debug" })
        AppLog.shared.warn({ "test private path warn" })
        AppLog.shared.error({ "test private path error" })
    }

    // MARK: - P4.3: scanner cancel() + generation 守门

    /// 临时目录 helper, 避免污染用户的真实 ~/.minimax / ~/.gemini
    @MainActor
    private func makeTempScanner() -> MinimaxLocalUsageScanner {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scanner-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return MinimaxLocalUsageScanner(
            runtimeDBURL: tempDir.appendingPathComponent("runtime.sqlite"),
            cacheDir: tempDir.appendingPathComponent("cache")
        )
    }

    private final class SaveCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var valueStorage = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return valueStorage
        }

        func increment() {
            lock.lock()
            valueStorage += 1
            lock.unlock()
        }
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        message: String,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    // MARK: - P4.3 / P6: scanner cancel() + rescan + 终态稳定

    /// cancelInFlight 合约 3 in 1：
    /// - 协议合规 (protocol 有 cancelInFlight)
    /// - 多次 cancelInFlight 幂等 (无 in-flight 也不崩, lastResult 不变)
    /// - scan 后 cancel 不改写 lastResult (cancel 不污染已成功结果)
    @MainActor
    func testScannerCancelInFlightContract() async {
        // 1. 协议合规: 能调到 cancelInFlight 不报错
        do {
            let scanner = makeTempScanner()
            scanner.cancelInFlight()
            XCTAssertNotNil(scanner)
        }
        // 2. 多次 cancelInFlight 幂等, 无 in-flight 也不崩
        do {
            let scanner = makeTempScanner()
            scanner.cancelInFlight()
            scanner.cancelInFlight()
            scanner.cancelInFlight()
            XCTAssertNil(scanner.lastResult, "没 scan 过应无 lastResult")
        }
        // 3. scan 后 cancel 不改写 lastResult (DB 不存在 → 失败, lastResult 为 nil 但 generation 已 +1)
        do {
            let scanner = makeTempScanner()
            scanner.scan()
            await waitUntil(message: "scan should settle") { !scanner.isScanning }
            let prev = scanner.lastResult
            scanner.cancelInFlight()
            scanner.cancelInFlight()
            XCTAssertTrue(scanner.lastResult == nil || scanner.lastResult == prev,
                          "cancel 不应改写 lastResult")
        }
    }

    /// scan / cancel / rescan 终态稳定 4 in 1：
    /// - generation 在 scan + cancel 路径都递增 (二次 scan 仍正常)
    /// - cancel + 立即 rescan 终态正确 (isScanning=false, lastError=nil, lastResult 不为 nil)
    /// - 3 轮 cancel+rescan 反复 generation bump 不破坏状态机
    /// - cancel 期间扫描抛错, catch filter 仍正确忽略 cancellation (lastError 不变成 cancel 相关)
    @MainActor
    func testScannerCancelAndRescanStability() async {
        // 1. generation 守门: 连续 scan + cancel + scan 仍能正常完成
        do {
            let scanner = makeTempScanner()
            scanner.scan()
            await waitUntil(message: "scan 1 should settle") { !scanner.isScanning }
            scanner.cancelInFlight()
            scanner.scan()
            await waitUntil(message: "scan 2 should settle") { !scanner.isScanning }
            XCTAssertFalse(scanner.isScanning, "两次 scan 完成后 isScanning 应回到 false")
        }
        // 2. cancel + 立即 rescan 终态正确: isScanning=false, lastError=nil, lastResult 不为 nil
        do {
            let scanner = makeTempScanner()
            scanner.scan()
            scanner.cancelInFlight()
            scanner.scan()
            await waitUntil(message: "cancel+rescan should settle") { !scanner.isScanning }
            XCTAssertFalse(scanner.isScanning, "cancel+rescan 后最终 isScanning 应回到 false")
            XCTAssertNil(scanner.lastError, "cancel+rescan 不应产生 lastError (catch filter)")
            XCTAssertNotNil(scanner.lastResult, "新 scan 应能成功返回 result")
        }
        // 3. 3 轮 cancel+rescan 反复 generation bump 不破坏状态机
        do {
            let scanner = makeTempScanner()
            for _ in 0..<3 {
                scanner.scan()
                scanner.cancelInFlight()
                scanner.scan()
            }
            await waitUntil(message: "3 rounds of cancel+rescan should settle") { !scanner.isScanning }
            XCTAssertFalse(scanner.isScanning, "3 轮 cancel+rescan 后最终 isScanning 应回到 false")
            XCTAssertNil(scanner.lastError, "3 轮 cancel+rescan 不应累积 lastError")
        }
        // 4. cancel 期间 catch filter 仍正确忽略 cancellation
        //    用 /dev/null 当 cacheDir → performScanPure 抛错 → catch 命中
        //    配合 cancel 让 Task.isCancelled=true → 走 filter ignore 分支
        //    验证 lastError 不是 cancel 相关 message
        do {
            let brokenCacheDir = URL(fileURLWithPath: "/dev/null/scanner-test")
            let scanner = MinimaxLocalUsageScanner(
                runtimeDBURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).db"),
                cacheDir: brokenCacheDir
            )
            scanner.scan()
            await waitUntil(message: "failed scan should settle") { !scanner.isScanning }
            XCTAssertNotNil(scanner.lastError, "broken cacheDir 应让 scan 失败并写 lastError")

            scanner.cancelInFlight()
            scanner.scan()
            await waitUntil(message: "second failed scan should settle") { !scanner.isScanning }
            XCTAssertNotNil(scanner.lastError, "新 scan 仍失败, lastError 应保留")
            XCTAssertFalse(
                scanner.lastError?.lowercased().contains("cancel") ?? false,
                "cancel 路径不应让 lastError 变成取消相关 message (实际: \(scanner.lastError ?? "nil"))"
            )
        }
    }

    // MARK: - P6: CancellationFilter 单元测试

    /// filter 的纯函数测试 — 不依赖 scanner 时序, 直接验证三个分支.
    func testCancellationFilterIsCancellationError() {
        // 1. CancellationError
        XCTAssertTrue(CancellationFilter.isCancellationError(CancellationError()))

        // 2. URLError.cancelled
        XCTAssertTrue(CancellationFilter.isCancellationError(URLError(.cancelled)))

        // 3. 其他 URLError code
        XCTAssertFalse(CancellationFilter.isCancellationError(URLError(.notConnectedToInternet)))
        XCTAssertFalse(CancellationFilter.isCancellationError(URLError(.timedOut)))

        // 4. 通用 Error
        XCTAssertFalse(CancellationFilter.isCancellationError(NSError(domain: "test", code: 1)))

        // 5. 自定义 Error
        struct CustomError: Error {}
        XCTAssertFalse(CancellationFilter.isCancellationError(CustomError()))
    }

    /// shouldIgnore 组合判断: error 是取消 OR task 被 cancel.
    func testCancellationFilterShouldIgnoreCombinesTaskAndError() {
        // 1. error 是取消 + task 未 cancel → 仍 ignore
        XCTAssertTrue(CancellationFilter.shouldIgnore(CancellationError(), isTaskCancelled: false))
        XCTAssertTrue(CancellationFilter.shouldIgnore(URLError(.cancelled), isTaskCancelled: false))

        // 2. error 不是取消 + task 已 cancel → 仍 ignore
        XCTAssertTrue(CancellationFilter.shouldIgnore(NSError(domain: "test", code: 1), isTaskCancelled: true))

        // 3. 两者都不是 → 不 ignore
        XCTAssertFalse(CancellationFilter.shouldIgnore(NSError(domain: "test", code: 1), isTaskCancelled: false))
    }

    // MARK: - 真 race 测试: TestGate 注入

    /// 注入到 scanner `testGate` 的同步门, **test-only**, 字段用 `#if DEBUG` 隔离:
    /// release build 的 binary 完全不带 `testGate` (生产代码干净). 编译时测试 target
    /// 用 debug 编译 (DEBUG defined), 可以正常访问. 用 actor 串行化
    /// arrive / waitForArrival / release 三种操作, 避免 race。
    ///
    /// - `arrive()`: worker 入口调用, 计数 +1 然后阻塞, 直到 `release()` 被调
    /// - `waitForArrival(n)`: 测试调用, 阻塞直到 `arrive` 次数 >= n
    /// - `release()`: 测试调用, 放行所有阻塞的 worker
    ///
    /// 关键: `waitForArrival` 不轮询, 用 continuation 唤醒 (跟 arrive 的 resume
    /// 配对), 测试时序精确.
    private actor TestGate {
        private(set) var arrivedCount: Int = 0
        private var waitArrivalContinuations: [CheckedContinuation<Void, Never>] = []
        private var workerContinuations: [CheckedContinuation<Void, Never>] = []
        private var released: Bool = false

        func arrive() async {
            arrivedCount += 1
            // 唤醒任何在等 arrive 次数的 caller
            let arrivalWaiters = waitArrivalContinuations
            waitArrivalContinuations = []
            for cont in arrivalWaiters { cont.resume() }
            // 自己阻塞, 等 release
            if released { return }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                workerContinuations.append(cont)
            }
        }

        func waitForArrival(_ n: Int) async {
            while arrivedCount < n {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    waitArrivalContinuations.append(cont)
                }
            }
        }

        func release() {
            released = true
            let waiters = workerContinuations
            workerContinuations = []
            for cont in waiters { cont.resume() }
        }

        func reset() {
            arrivedCount = 0
            released = false
            // 不重置 continuations —— reset 时不应该还有 caller 在等
        }
    }

    /// P1 关键 regression 测试: 旧 worker 即使晚到 mutex 也不能回滚新 worker 的
    /// cache. 关键 invariant: 旧 generation 不应再次执行 saveIndex.
    ///
    /// 这个测试在 P1 fix 之前会 fail, 因为 P1 之前 read 在 mutex 外, A 可能
    /// 读 stale lastCommitted=0 然后写 A_view, 覆盖 B 的 B_view.
    ///
    /// 共享逻辑: `runP1RegressionTest` helper 处理 temp dir / save 计数 /
    /// lastCommitted 验证. caller 闭包负责 scanner 特定的 performScanPure 调用.
    /// 两个 scanner 都有对应测试, 防止其中一个修对了另一个没修.

    @MainActor
    private func runP1RegressionTest(
        cacheDirName: String,
        cacheFileName: String,
        runScan: (_ generation: UInt64) async throws -> Void,
        readLastCommitted: () -> UInt64,
        saveCounter: SaveCounter
    ) async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(cacheDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let indexURL = tempDir.appendingPathComponent(cacheFileName)

        // Step 1: 新 worker B (gen=5) 写盘 + 更新 lastCommitted=5
        try await runScan(5)
        XCTAssertEqual(readLastCommitted(), 5,
                       "新 worker B (gen=5) 应 commit, lastCommitted=5")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path), "B 写盘后 cache file 应存在")
        XCTAssertEqual(saveCounter.value, 1, "新 generation 应执行一次 saveIndex")

        // Step 2: 旧 worker A (gen=1, 老于 lastCommitted=5) 后跑
        // P1 fix 关键 invariant: A 在 mutex 内 readLastCommittedGeneration()
        // 看到的是 5 (B 更新过的), shouldSave=1>5=false, 跳过 saveIndex.
        try await runScan(1)
        XCTAssertEqual(readLastCommitted(), 5,
                       "旧 worker A (gen=1) 的 saveIndex 应被跳过, lastCommitted 保持 5")
        XCTAssertEqual(saveCounter.value, 1, "旧 generation 不应再次执行 saveIndex")
    }

    @MainActor
    func testNewWorkerWinsEvenWhenOldWorkerGetsLockFirst_Antigravity() async throws {
        // Antigravity scanner 路径: P1 fix 同时存在于 Antigravity 和 Minimax,
        // 这里跑同一套 invariant 验证. Antigravity 的 performScanPure 多一个
        // fetcher 参数 (这里用真实 AntigravityFetcher(), no DB 时不会真用).
        let conversationsDir = NSTemporaryDirectory() + "antigravity-conv-\(UUID())/"
        let cacheDirName = "scanner-p1-antigravity-\(UUID().uuidString)"
        let cacheDirURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(cacheDirName, isDirectory: true)
        let fileManager: FileManagerBox = FileManagerBox()
        let calendar: Calendar = .current
        let now: @Sendable () -> Date = { Date() }
        let fetcher = AntigravityFetcher()
        let scanner = AntigravityLocalUsageScanner(
            fetcher: fetcher,
            conversationsDirs: [URL(fileURLWithPath: conversationsDir)],
            cacheDir: cacheDirURL,
            fileManager: fileManager,
            calendar: calendar,
            now: now
        )
        let saveCounter = SaveCounter()
        AntigravityLocalUsageScanner.testSaveIndexHook = { saveCounter.increment() }
        defer { AntigravityLocalUsageScanner.testSaveIndexHook = nil }

        try await runP1RegressionTest(
            cacheDirName: cacheDirName,
            cacheFileName: "index.json",
            runScan: { gen in
                _ = try await AntigravityLocalUsageScanner.performScanPure(
                    fetcher: fetcher,
                    conversationsDirs: [URL(fileURLWithPath: conversationsDir)],
                    cacheDir: cacheDirURL,
                    fileManager: fileManager,
                    calendar: calendar,
                    now: now,
                    startedGeneration: gen,
                    scanner: scanner
                )
            },
            readLastCommitted: { scanner.readLastCommittedGeneration() },
            saveCounter: saveCounter
        )
    }

    // MARK: - P1 runScan 路径 (完整生产流程)

    /// P1/P6 invariant 完整 runScan 路径验证. 之前 `testNewWorkerWinsEvenWhenOldWorkerGetsLockFirst`
    /// 直接调 performScanPure, 验证 mutex 内部 read+write atomic. 但**不验证 runScan
    /// 编排**——如果未来 refactor 把 runScan 改回 "传 lastCommittedAtStart 快照" 模式
    /// (旧 buggy), 直接调 performScanPure 的测试还会过, 但生产路径的 race 又回来.
    ///
    /// 这里用 TestGate 让两个 worker 在 await gate 处都阻塞, 然后 release 让它们
    /// 走完整的 cancel+rescan 路径 (scanner.scan() → runScan → background runner →
    /// performScanPure), 验证:
    /// 1. 中间态 isScanning 在新 worker 阻塞时保持 true
    /// 2. 最终 lastCommitted=3 (B 的 generation, 旧 worker 跳过了)
    /// 3. 只有 B 执行 saveIndex (旧 worker 没有回滚 cache)
    ///
    /// 不依赖 TestGate 顺序的确定性 (哪个 worker 先抢到 mutex), 反而更鲁棒: 任何
    /// 顺序下, "新 worker 写盘 + 旧 worker 后跑" 都不能回滚磁盘.
    @MainActor
    func testFullRunScanFlowCancelRescanNoDiskRevert() async throws {
        let gate = TestGate()
        MinimaxLocalUsageScanner.testGate = { await gate.arrive() }
        defer {
            MinimaxLocalUsageScanner.testGate = nil
            Task { await gate.reset() }
        }
        let saveCounter = SaveCounter()
        MinimaxLocalUsageScanner.testSaveIndexHook = { saveCounter.increment() }
        defer { MinimaxLocalUsageScanner.testSaveIndexHook = nil }

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scanner-p1-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scanner = MinimaxLocalUsageScanner(
            runtimeDBURL: tempDir.appendingPathComponent("runtime.sqlite"),
            cacheDir: tempDir.appendingPathComponent("cache")
        )
        // Step 1: A 启动 (gen=1), 阻塞在 gate
        scanner.scan()
        await gate.waitForArrival(1)
        XCTAssertTrue(scanner.isScanning, "A 阻塞在 gate 时 isScanning 应为 true")

        // Step 2: cancel A, B 启动 (gen=3), 也阻塞在 gate
        scanner.cancelInFlight()
        scanner.scan()
        await gate.waitForArrival(2)
        XCTAssertTrue(scanner.isScanning, "B 阻塞在 gate 时 isScanning 应仍为 true")

        // Step 3: 释放 gate, 两个 worker 抢 mutex (顺序不确定, 但无论顺序 P1 fix 都应保证不 revert)
        await gate.release()

        // Step 4: 等两个 worker 都跑完
        await waitUntil(message: "cancel+rescan workers should settle") { !scanner.isScanning }

        // Step 5: 验证终态
        XCTAssertFalse(scanner.isScanning, "两个 worker 都跑完后 isScanning 应回到 false")
        XCTAssertNotNil(scanner.lastResult, "B 成功 (no DB) 应有 lastResult")
        XCTAssertNil(scanner.lastError, "无错误源, lastError 应为 nil")

        // Step 6: 关键 — lastCommitted 应是 B 的 gen=3 (B 成功 commit, A 跳过了)
        XCTAssertEqual(
            scanner.readLastCommittedGeneration(), 3,
            "P1 fix: B (gen=3) 应 commit, A (gen=1) 在 mutex 内 readLastCommitted 看到 3 后跳过, lastCommitted=3"
        )

        // Step 7: 验证只有 B 写盘 (不是 A 回滚)
        XCTAssertEqual(saveCounter.value, 1, "B 应写盘一次，A 不应回滚 cache")
    }

    @MainActor
    func testFullRunScanFlowCancelRescanNoDiskRevert_Antigravity() async throws {
        let gate = TestGate()
        AntigravityLocalUsageScanner.testGate = { await gate.arrive() }
        defer {
            AntigravityLocalUsageScanner.testGate = nil
            Task { await gate.reset() }
        }
        let saveCounter = SaveCounter()
        AntigravityLocalUsageScanner.testSaveIndexHook = { saveCounter.increment() }
        defer { AntigravityLocalUsageScanner.testSaveIndexHook = nil }

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scanner-p1-flow-antigravity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let conversationsDir = tempDir.appendingPathComponent("conversations")
        try? FileManager.default.createDirectory(at: conversationsDir, withIntermediateDirectories: true)
        let fetcher = AntigravityFetcher()
        let scanner = AntigravityLocalUsageScanner(
            fetcher: fetcher,
            conversationsDirs: [conversationsDir],
            cacheDir: tempDir.appendingPathComponent("cache")
        )
        // Step 1-4: 跟 Minimax 测试同样的 cancel+rescan 序列
        scanner.scan()
        await gate.waitForArrival(1)
        XCTAssertTrue(scanner.isScanning)
        scanner.cancelInFlight()
        scanner.scan()
        await gate.waitForArrival(2)
        XCTAssertTrue(scanner.isScanning)
        await gate.release()
        await waitUntil(message: "Antigravity cancel+rescan workers should settle") { !scanner.isScanning }

        // Step 5-7: 验证 P1 invariant
        XCTAssertFalse(scanner.isScanning)
        XCTAssertNotNil(scanner.lastResult)
        XCTAssertNil(scanner.lastError)
        XCTAssertEqual(
            scanner.readLastCommittedGeneration(), 3,
            "P1 fix 同样适用于 Antigravity: B (gen=3) commit, A 跳过, lastCommitted=3"
        )
        XCTAssertEqual(saveCounter.value, 1, "Antigravity B 应写盘一次，A 不应回滚 cache")
    }

    /// 真 race 测试: 失败中的 worker 被取消后，catch filter 不应写 lastError.
    /// TestGate 确保取消发生在 performScanPure 运行期间，broken cacheDir 确保
    /// worker 最终确实进入 catch，而不是把成功路径误当成 cancellation 覆盖。
    @MainActor
    func testRealCancelInFlightCatchFilterIgnoresCancellation() async throws {
        let gate = TestGate()
        MinimaxLocalUsageScanner.testGate = { await gate.arrive() }
        defer {
            MinimaxLocalUsageScanner.testGate = nil
            Task { await gate.reset() }
        }
        let scanner = MinimaxLocalUsageScanner(
            runtimeDBURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).db"),
            cacheDir: URL(fileURLWithPath: "/dev/null/scanner-test-\(UUID().uuidString)")
        )

        // 1. 启动 scan, 卡在 gate
        scanner.scan()
        await gate.waitForArrival(1)

        // 2. 取消 outer task (inFlightTask.cancel())
        scanner.cancelInFlight()
        // 此时 outer task isCancelled=true, 但 worker 仍卡在 gate 上
        // 还没进 catch 路径 —— cancel 不会自动中断 await

        // 3. 放行 worker, 让它在 broken cacheDir 上失败并进入 catch
        await gate.release()
        await waitUntil(message: "cancelled failed scan should settle") { !scanner.isScanning }

        // 4. 验证 catch filter 忽略取消，不污染 lastError 或 lastResult
        XCTAssertFalse(scanner.isScanning)
        XCTAssertNil(scanner.lastError, "取消中的失败不应写 lastError")
        XCTAssertNil(scanner.lastResult, "取消中的失败不应写 lastResult")
    }

    // MARK: - AsyncMutex: cache 串行写入 (防 cache revert)

    /// 关键 invariant 测试: 旧 generation worker 的 saveIndex 必须被跳过.
    /// 这里显式控制 generation，验证:
    /// 1. scanner.lastCommittedGeneration 只增不减 (单步跳到 B 的 generation)
    /// 2. A 的 saveIndex 跳过 (log 中能看到 "旧 generation ... 跳过")
    /// 3. 磁盘 cache 反映 B 的数据 (B 的 generation 是最新的)
    ///
    /// 真实生产里 cancel+rescan 时:
    ///   - 旧 worker A 可能因为被 cancel 唤醒后才到 mutex, 此时新 worker B 已跑完
    ///   - A 拿锁 → loadIndex(看到 B 写完的 disk) → 跑 pipeline → 准备 saveIndex
    ///   - 没有 generation 守门: A 写入旧 view, 回滚 B 的新 view ❌
    ///   - 有 generation 守门: A 跳过 saveIndex, 磁盘保留 B 的 view ✓
    ///
    /// P1 修复后 read+write 都在 mutex 内 (跨 @MainActor hop 但持锁), A 在
    /// 自己的 withLock 块里读 lastCommitted 看到 B 的更新值, shouldSave=false.
    @MainActor
    func testOldGenerationWorkerSkipsSaveIndex() async throws {
        // 直接调 performScanPure, 显式控制 startedGeneration 参数, 强制
        // "B 先跑 (gen=5), A 后跑 (gen=1) 但被跳过" 的场景. 比 testGate + scan
        // 更可控 (testGate 顺序受 race 影响, 不一定每次都触发 skip 路径).
        //
        // 用一个真实 scanner 实例 (lastCommittedGeneration 是 instance @MainActor var),
        // performScanPure 接收 scanner 参数, 在 mutex 内通过 await scanner.readLastCommittedGeneration()
        // 读, 通过 await scanner.writeLastCommittedGeneration() 写.

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scanner-gen-skip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runtimeDB = tempDir.appendingPathComponent("runtime.sqlite")
        let fileManager: FileManagerBox = FileManagerBox()
        let calendar: Calendar = .current
        let now: @Sendable () -> Date = { Date() }

        // 真实 scanner 实例, lastCommittedGeneration 初始 0
        let scanner = MinimaxLocalUsageScanner(
            runtimeDBURL: runtimeDB,
            cacheDir: tempDir,
            fileManager: fileManager,
            calendar: calendar,
            now: now
        )
        let saveCounter = SaveCounter()
        MinimaxLocalUsageScanner.testSaveIndexHook = { saveCounter.increment() }
        defer { MinimaxLocalUsageScanner.testSaveIndexHook = nil }

        // 1. 模拟 "新 worker B 先跑 (gen=5)": 写盘, scanner.lastCommitted=5
        let r1 = try await MinimaxLocalUsageScanner.performScanPure(
            
            runtimeDBURL: runtimeDB,
            cacheDir: tempDir,
            fileManager: fileManager,
            calendar: calendar,
            now: now,
            startedGeneration: 5,
            scanner: scanner
        )
        _ = r1
        XCTAssertEqual(scanner.readLastCommittedGeneration(), 5,
                       "新 worker B (gen=5) 应 commit, lastCommitted=5")
        XCTAssertEqual(saveCounter.value, 1, "gen=5 应执行一次 saveIndex")

        // 3. 模拟 "旧 worker A 后跑 (gen=1, 老于 lastCommitted=5)": saveIndex 应被跳过,
        //    save count 不变, lastCommitted 保持 5
        let r2 = try await MinimaxLocalUsageScanner.performScanPure(
            
            runtimeDBURL: runtimeDB,
            cacheDir: tempDir,
            fileManager: fileManager,
            calendar: calendar,
            now: now,
            startedGeneration: 1,  // ← 旧于 lastCommitted=5
            scanner: scanner
        )
        _ = r2
        XCTAssertEqual(scanner.readLastCommittedGeneration(), 5,
                       "旧 generation A (gen=1) 的 saveIndex 应被跳过, lastCommitted 保持 5")
        XCTAssertEqual(saveCounter.value, 1, "gen=1 不应再次执行 saveIndex")

        // 5. 验证: 用更大的 generation (gen=10) 应能 commit
        let r3 = try await MinimaxLocalUsageScanner.performScanPure(
            
            runtimeDBURL: runtimeDB,
            cacheDir: tempDir,
            fileManager: fileManager,
            calendar: calendar,
            now: now,
            startedGeneration: 10,
            scanner: scanner
        )
        _ = r3
        XCTAssertEqual(scanner.readLastCommittedGeneration(), 10,
                       "新 generation (gen=10 > 5) 应能 commit, lastCommitted 跳到 10")
        XCTAssertEqual(saveCounter.value, 2, "gen=10 应执行第二次 saveIndex")

        // 6. 验证: 比 10 小的 generation (gen=7) 仍被跳过
        let r4 = try await MinimaxLocalUsageScanner.performScanPure(
            
            runtimeDBURL: runtimeDB,
            cacheDir: tempDir,
            fileManager: fileManager,
            calendar: calendar,
            now: now,
            startedGeneration: 7,  // ← 老于 lastCommitted=10
            scanner: scanner
        )
        _ = r4
        XCTAssertEqual(scanner.readLastCommittedGeneration(), 10,
                       "gen=7 < 10 应被跳过, lastCommitted 保持 10")
        XCTAssertEqual(saveCounter.value, 2, "gen=7 不应再次执行 saveIndex")
    }

    // MARK: - AsyncMutex Tests

    func testAsyncMutexAcquireCancellationRules() async throws {
        let mutex = AsyncMutex()
        let task = Task<Bool, Never> { @Sendable in
            do {
                _ = try await mutex.withLock { true }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        task.cancel()
        let wasCancelled = await task.value
        XCTAssertTrue(wasCancelled, "Task should throw CancellationError when cancelled")
    }
}
