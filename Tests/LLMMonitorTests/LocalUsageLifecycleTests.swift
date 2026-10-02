import XCTest
import CoreServices
import Darwin
@testable import LLM_monitor

/// LocalUsage 文件监听与 source 生命周期（FSEvents / vnode / 共享 monitor /
/// 事件路由 / 热集 LRU / 扫描期间 dirty 守门）。
/// 拆自 `ScannerAndLoggingTests`，逐字搬移零逻辑变化。

@MainActor
private final class DirtyDuringScanProbe: LocalUsageScannerBase<Int>, @unchecked Sendable {
    private let gate: ScanGate

    init(gate: ScanGate) {
        self.gate = gate
        super.init(logTag: "[scan-probe]", cachedResult: nil)
    }

    override func makeWork(startedGeneration: UInt64) -> @Sendable () async throws -> Int {
        let gate = self.gate
        return {
            await gate.enter()
            return 1
        }
    }
}

final class LocalUsageLifecycleTests: ScannerTestCase {

    @MainActor
    func testLocalFSEventsWatcherDoesNotEmitSyntheticEventOnStart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-fsevents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var events: [LocalFSEventsEvent] = []
        let watcher = LocalFSEventsWatcher(paths: [root]) { event in
            events.append(event)
        }
        watcher.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        watcher.stop()

        XCTAssertTrue(events.isEmpty, "注册 watcher 不应凭空产生 dirty event: \(events)")
    }

    @MainActor
    func testLocalVnodeWriteWatcherSeesAppendWhileWriterRemainsOpen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-vnode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("runtime.sqlite")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        let changed = expectation(description: "vnode write")
        let vnode = LocalVnodeWriteWatcher(path: file) {
            changed.fulfill()
        }
        vnode.start()
        let fd = open(file.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer {
            vnode.stop()
            if fd >= 0 { close(fd) }
        }
        let bytes = Array("append\n".utf8)
        let written = bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
            Darwin.write(fd, buffer.baseAddress, bytes.count)
        }
        XCTAssertEqual(written, bytes.count)
        XCTAssertEqual(fsync(fd), 0)
        // Keep fd open until after this assertion: this is the regression case
        // that FSEvents alone cannot reliably surface.
        await fulfillment(of: [changed], timeout: 2)
        let fileSize = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(fileSize, 0)
    }

    /// M8 合并窗口：首事件即时投递；窗口内后续事件合并为窗口结束时的一次
    /// 投递；窗口空闲后的新写入再次即时投递。窗口注入 0.8s（生产默认 0.25s），
    /// 让多次 100ms 间隔的 append 稳定落在同一窗口内。到达性断言用 waitUntil
    /// 轮询（不人为设投递时延上限），合并/不投递断言保持严格相等——那才是
    /// 被测语义。
    @MainActor
    func testLocalVnodeWriteWatcherCoalescesRapidAppendsIntoSingleDelivery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-vnode-coalesce-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("runtime.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        var deliveries = 0
        let vnode = LocalVnodeWriteWatcher(path: file, coalescingWindow: 0.8) {
            deliveries += 1
        }
        vnode.start()
        let fd = open(file.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { vnode.stop(); close(fd) }
        var byte: UInt8 = 1
        XCTAssertEqual(withUnsafePointer(to: &byte) { Darwin.write(fd, $0, 1) }, 1)
        XCTAssertEqual(fsync(fd), 0)
        await waitUntil(timeout: 2, message: "首事件应即时投递") { deliveries == 1 }

        // 窗口内再写两次：只记账合并，不逐条投递
        for _ in 0..<2 {
            XCTAssertEqual(withUnsafePointer(to: &byte) { Darwin.write(fd, $0, 1) }, 1)
            XCTAssertEqual(fsync(fd), 0)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(deliveries, 1, "窗口内的连续 append 不应逐条投递，实际 \(deliveries)")

        // 窗口（0.8s）结束时，窗口内的后续 append 合并为一次投递
        await waitUntil(timeout: 2, message: "窗口内的后续 append 应合并为一次投递") { deliveries == 2 }

        // 第二个窗口（0.8s）空闲到期：不应产生追加投递
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(deliveries, 2)
        XCTAssertEqual(withUnsafePointer(to: &byte) { Darwin.write(fd, $0, 1) }, 1)
        XCTAssertEqual(fsync(fd), 0)
        await waitUntil(timeout: 2, message: "窗口空闲后的新写入应再次投递") { deliveries == 3 }
    }

    /// M8 停止安全：stop() 取消合并窗口，窗口内被合并的事件不投递幽灵事件。
    @MainActor
    func testLocalVnodeWriteWatcherDropsPendingDeliveryOnStop() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-vnode-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("runtime.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        var deliveries = 0
        let vnode = LocalVnodeWriteWatcher(path: file, coalescingWindow: 2.0) {
            deliveries += 1
        }
        vnode.start()
        let fd = open(file.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var byte: UInt8 = 1
        XCTAssertEqual(withUnsafePointer(to: &byte) { Darwin.write(fd, $0, 1) }, 1)
        XCTAssertEqual(fsync(fd), 0)
        await waitUntil(timeout: 2, message: "首事件应即时投递") { deliveries == 1 }
        // 窗口内再写一次：被合并，等待窗口结束时投递
        XCTAssertEqual(withUnsafePointer(to: &byte) { Darwin.write(fd, $0, 1) }, 1)
        XCTAssertEqual(fsync(fd), 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(deliveries, 1, "窗口内的后续写入应被合并，实际 \(deliveries)")
        // stop() 取消窗口：被合并的事件不应再投递
        vnode.stop()
        // 越过 2s 窗口后确认无幽灵投递
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(deliveries, 1, "stop 后窗口内的合并事件不应投递幽灵事件")
    }

    /// M7 去抖：注册触发的全量递归枚举不立即执行，250ms 去抖后合并为一次
    /// 枚举（与 ConfigStore.scheduleConfigReload 同语义）；扫描成功后的
    /// refreshHotFiles 走同一调度入口，同样被去抖覆盖并正常落地。
    ///
    /// 候选文件在注册前 >=1.2s 创建：FSEvents 的 sinceNow 边界有 fseventsd
    /// 处理延迟，紧贴流创建的写入事件会"漏进"流里并触发即时
    /// addDynamicPath（与去抖无关的合法路径）；预留远大于处理延迟的静置期
    /// 后，该事件确定性地落在流开始之前，"进入 vnode LRU" 只能由去抖后的
    /// discovery 完成。去抖窗口内检查点取 100ms < 250ms，为确定性下界。
    @MainActor
    func testDiscoveryDebounceDelaysEnumeration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-discovery-debounce-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent("session.jsonl")
        FileManager.default.createFile(atPath: candidate.path, contents: Data())
        // 让候选文件的创建事件彻底成为"过去"（见 doc comment），排除事件
        // 即时路径对去抖断言的干扰。
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let monitor = LocalUsageFileMonitor() // autoDiscoveryEnabled 默认 true
        let source = LocalUsageSourceLifecycle(
            paths: [root], dynamicExtensions: ["jsonl"], monitor: monitor, onDirty: {}
        )
        defer { source.stop() }

        // 去抖窗口内（100ms < 250ms）：枚举尚未执行，候选未进入 vnode LRU
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(
            monitor.watchedPaths.contains(candidate.path),
            "去抖窗口内不应立即执行全量枚举: \(monitor.watchedPaths)"
        )

        // 去抖到期后：一次枚举把注册前已存在的候选补齐
        let deadline = Date().addingTimeInterval(2)
        while !monitor.watchedPaths.contains(candidate.path) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(
            monitor.watchedPaths.contains(candidate.path),
            "去抖到期后应由一次枚举发现候选文件: \(monitor.watchedPaths)"
        )
        XCTAssertEqual(monitor.vnodeWatcherCount, 1)

        // 扫描成功后的 refreshHotFiles 走同一 scheduleDiscovery 入口：去抖
        // 到期后再次枚举并 re-touch（addDynamicPath 对已在册路径也会记账）。
        let sequenceBeforeRefresh = monitor.accessSequence(for: candidate) ?? 0
        source.refreshHotFiles()
        let refreshDeadline = Date().addingTimeInterval(2)
        while (monitor.accessSequence(for: candidate) ?? 0) <= sequenceBeforeRefresh
            && Date() < refreshDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(
            monitor.accessSequence(for: candidate) ?? 0, sequenceBeforeRefresh,
            "refreshHotFiles 的去抖调度应完成一次枚举并 re-touch 热文件"
        )
    }

    @MainActor
    func testGlobalMonitorSharesVnodeOwnerAndRoutesDirty() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-shared-vnode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let monitor = LocalUsageFileMonitor(maxVnodeWatchers: 3, autoDiscoveryEnabled: false)
        let first = expectation(description: "first source dirty")
        first.assertForOverFulfill = false
        let second = expectation(description: "second source dirty")
        second.assertForOverFulfill = false
        let source1 = LocalUsageSourceLifecycle(
            paths: [root], seedDynamicFiles: [file], dynamicExtensions: ["jsonl"], monitor: monitor,
            onDirty: { first.fulfill() }
        )
        let source2 = LocalUsageSourceLifecycle(
            paths: [root], seedDynamicFiles: [file], dynamicExtensions: ["jsonl"], monitor: monitor,
            onDirty: { second.fulfill() }
        )
        XCTAssertEqual(monitor.vnodeWatcherCount, 1)
        let fd = open(file.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd); source1.stop(); source2.stop() }
        var byte: UInt8 = 1
        XCTAssertEqual(withUnsafePointer(to: &byte) { Darwin.write(fd, $0, 1) }, 1)
        XCTAssertEqual(fsync(fd), 0)
        await fulfillment(of: [first, second], timeout: 2)

        source1.stop()
        XCTAssertEqual(monitor.vnodeWatcherCount, 1)
        let generationBeforeSecondWrite = source2.eventGeneration
        let secondFDWrite = withUnsafePointer(to: &byte) { Darwin.write(fd, $0, 1) }
        XCTAssertEqual(secondFDWrite, 1)
        XCTAssertEqual(fsync(fd), 0)
        let deadline = Date().addingTimeInterval(2)
        while source2.eventGeneration == generationBeforeSecondWrite && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(source2.eventGeneration, generationBeforeSecondWrite)
        XCTAssertEqual(monitor.vnodeWatcherCount, 1)
    }

    @MainActor
    func testLocalUsageLifecycleReentrantStartAndBoundedHotSet() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixed = root.appendingPathComponent("runtime.sqlite")
        FileManager.default.createFile(atPath: fixed.path, contents: Data())
        let old = root.appendingPathComponent("old.jsonl")
        let newest = root.appendingPathComponent("new.jsonl")
        FileManager.default.createFile(atPath: old.path, contents: Data())
        FileManager.default.createFile(atPath: newest.path, contents: Data())

        var dirtyCount = 0
        let monitor = LocalUsageFileMonitor(maxVnodeWatchers: 3, autoDiscoveryEnabled: false)
        let lifecycle = LocalUsageSourceLifecycle(
            paths: [root],
            watchedFiles: [fixed],
            seedDynamicFiles: [old, newest],
            dynamicExtensions: ["jsonl"],
            monitor: monitor,
            onDirty: { dirtyCount += 1 }
        )
        lifecycle.start()
        XCTAssertEqual(monitor.vnodeWatcherCount, 3)
        lifecycle.start()
        XCTAssertEqual(monitor.vnodeWatcherCount, 3)
        XCTAssertEqual(dirtyCount, 0)

        let added = root.appendingPathComponent("added.jsonl")
        FileManager.default.createFile(atPath: added.path, contents: Data())
        monitor.handleTopologyEventForTesting(
            path: added.path,
            flags: UInt32(kFSEventStreamEventFlagItemCreated)
        )
        XCTAssertEqual(monitor.vnodeWatcherCount, 3)
        XCTAssertFalse(monitor.watchedPaths.contains(old.path))
        XCTAssertTrue(monitor.watchedPaths.contains(added.path))

        try FileManager.default.removeItem(at: added)
        monitor.handleTopologyEventForTesting(
            path: added.path,
            flags: UInt32(kFSEventStreamEventFlagItemRemoved)
        )
        XCTAssertFalse(monitor.watchedPaths.contains(added.path))
        XCTAssertEqual(monitor.vnodeWatcherCount, 2)
        lifecycle.stop()
    }

    @MainActor
    func testLocalUsageLifecycleExcludesCacheEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-exclusion-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent(".token-monitor", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheFile = cache.appendingPathComponent("index.json")
        FileManager.default.createFile(atPath: cacheFile.path, contents: Data())
        var dirtyCount = 0
        let monitor = LocalUsageFileMonitor(maxVnodeWatchers: 3, autoDiscoveryEnabled: false)
        let lifecycle = LocalUsageSourceLifecycle(
            paths: [root],
            dynamicExtensions: ["json"],
            excludedPaths: [cache],
            monitor: monitor,
            onDirty: { dirtyCount += 1 }
        )
        lifecycle.start()
        let before = lifecycle.eventGeneration
        monitor.handleTopologyEventForTesting(
            path: cacheFile.path,
            flags: UInt32(kFSEventStreamEventFlagItemCreated)
        )
        XCTAssertEqual(lifecycle.eventGeneration, before)
        XCTAssertEqual(monitor.vnodeWatcherCount, 0)
        XCTAssertEqual(dirtyCount, 0)
        lifecycle.stop()
    }

    @MainActor
    func testLocalUsageLifecycleFiltersMetadataAndSQLiteShmEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-fsevent-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let minimaxDB = root.appendingPathComponent("runtime-state.sqlite")
        let minimaxSHM = root.appendingPathComponent("runtime-state.sqlite-shm")
        let antigravityDB = root.appendingPathComponent("session.db")
        let unrelated = root.appendingPathComponent("notes.txt")
        for file in [minimaxDB, minimaxSHM, antigravityDB, unrelated] {
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }

        let monitor = LocalUsageFileMonitor(maxVnodeWatchers: 8, autoDiscoveryEnabled: false)
        var minimaxDirty = 0
        var antigravityDirty = 0
        let minimax = LocalUsageSourceLifecycle(
            paths: [root], watchedFiles: [minimaxDB], monitor: monitor,
            onDirty: { minimaxDirty += 1 }
        )
        let antigravity = LocalUsageSourceLifecycle(
            paths: [root], dynamicExtensions: ["db", "db-wal", "pb"], monitor: monitor,
            onDirty: { antigravityDirty += 1 }
        )
        defer { minimax.stop(); antigravity.stop() }

        let shmMetadata = UInt32(0x10400) // ItemIsFile | ItemInodeMetaMod
        let shmMetadataAndModified = UInt32(0x11400) // + ItemModified
        monitor.handleTopologyEventForTesting(path: minimaxSHM.path, flags: shmMetadata)
        monitor.handleTopologyEventForTesting(path: minimaxSHM.path, flags: shmMetadataAndModified)
        XCTAssertEqual(minimaxDirty, 0, "SQLite -shm 元数据/写入事件不应让 Minimax dirty")
        XCTAssertEqual(antigravityDirty, 0, "SQLite -shm 不属于 Antigravity session source")

        monitor.handleTopologyEventForTesting(
            path: minimaxDB.path,
            flags: UInt32(kFSEventStreamEventFlagItemIsFile)
                | UInt32(kFSEventStreamEventFlagItemInodeMetaMod)
        )
        XCTAssertEqual(minimaxDirty, 0, "纯 inode metadata 不应让 fixed file dirty")
        monitor.handleTopologyEventForTesting(
            path: minimaxDB.path,
            flags: UInt32(kFSEventStreamEventFlagItemIsFile)
                | UInt32(kFSEventStreamEventFlagItemModified)
        )
        XCTAssertEqual(minimaxDirty, 1, "fixed sqlite 的真实修改应标记 dirty")

        monitor.handleTopologyEventForTesting(
            path: antigravityDB.path,
            flags: UInt32(kFSEventStreamEventFlagItemIsFile)
                | UInt32(kFSEventStreamEventFlagItemXattrMod)
        )
        XCTAssertEqual(antigravityDirty, 0, "纯 xattr 修改不应让动态 session dirty")
        monitor.handleTopologyEventForTesting(
            path: unrelated.path,
            flags: UInt32(kFSEventStreamEventFlagItemIsFile)
                | UInt32(kFSEventStreamEventFlagItemModified)
        )
        XCTAssertEqual(antigravityDirty, 0, "无关扩展不应让动态 source dirty")
        monitor.handleTopologyEventForTesting(
            path: root.path,
            flags: UInt32(kFSEventStreamEventFlagItemIsDir)
                | UInt32(kFSEventStreamEventFlagItemInodeMetaMod)
        )
        XCTAssertEqual(antigravityDirty, 0, "目录 metadata 不应直接让 source dirty")
    }

    @MainActor
    func testLocalUsageLifecycleDiscoversCompoundWALAndRecoveryInvalidates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-fsevent-topology-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let db = root.appendingPathComponent("session.db")
        let wal = root.appendingPathComponent("session.db-wal")
        let protobuf = root.appendingPathComponent("session.pb")
        for file in [db, wal, protobuf] {
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }

        let monitor = LocalUsageFileMonitor(maxVnodeWatchers: 8, autoDiscoveryEnabled: false)
        var dirtyCount = 0
        let lifecycle = LocalUsageSourceLifecycle(
            paths: [root], dynamicExtensions: ["db", "db-wal", "pb"], monitor: monitor,
            onDirty: { dirtyCount += 1 }
        )
        defer { lifecycle.stop() }

        let created = UInt32(kFSEventStreamEventFlagItemIsFile)
            | UInt32(kFSEventStreamEventFlagItemCreated)
        monitor.handleTopologyEventForTesting(path: db.path, flags: created)
        monitor.handleTopologyEventForTesting(path: wal.path, flags: created)
        monitor.handleTopologyEventForTesting(path: protobuf.path, flags: created)
        XCTAssertEqual(dirtyCount, 3, "db/db-wal/pb 创建都应标记 dirty")
        XCTAssertTrue(monitor.watchedPaths.contains(db.path))
        XCTAssertTrue(monitor.watchedPaths.contains(wal.path), "compound .db-wal 应被发现并进入 vnode LRU")
        XCTAssertTrue(monitor.watchedPaths.contains(protobuf.path))

        let beforeRecovery = lifecycle.eventGeneration
        monitor.handleTopologyEventForTesting(
            path: root.path,
            flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs)
                | UInt32(kFSEventStreamEventFlagItemIsDir)
        )
        XCTAssertGreaterThan(lifecycle.eventGeneration, beforeRecovery, "FSEvents 丢失/恢复事件应保守 invalidation")
    }

    @MainActor
    func testGlobalMonitorRoutesEventsOnlyToMatchingRoots() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-routing-\(UUID().uuidString)", isDirectory: true)
        let rootA = base.appendingPathComponent("a", isDirectory: true)
        let rootB = base.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let monitor = LocalUsageFileMonitor(maxVnodeWatchers: 4, autoDiscoveryEnabled: false)
        let fileA = rootA.appendingPathComponent("a.jsonl")
        FileManager.default.createFile(atPath: fileA.path, contents: Data())
        let sourceA = LocalUsageSourceLifecycle(
            paths: [rootA], seedDynamicFiles: [fileA], dynamicExtensions: ["jsonl"], monitor: monitor, onDirty: {}
        )
        let sourceB = LocalUsageSourceLifecycle(
            paths: [rootB], dynamicExtensions: ["jsonl"], monitor: monitor, onDirty: {}
        )
        monitor.handleTopologyEventForTesting(
            path: fileA.path,
            flags: UInt32(kFSEventStreamEventFlagItemCreated)
        )
        XCTAssertGreaterThan(sourceA.eventGeneration, 0)
        XCTAssertEqual(sourceB.eventGeneration, 0)
        sourceA.stop()
        sourceB.stop()
    }

    @MainActor
    func testGlobalMonitorLRURefreshesOnHotFileTouchAndProtectsPinned() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-lru-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixed = root.appendingPathComponent("runtime.sqlite")
        let first = root.appendingPathComponent("first.jsonl")
        let second = root.appendingPathComponent("second.jsonl")
        let third = root.appendingPathComponent("third.jsonl")
        for file in [fixed, first, second] {
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }

        let monitor = LocalUsageFileMonitor(maxVnodeWatchers: 3, autoDiscoveryEnabled: false)
        let source = LocalUsageSourceLifecycle(
            paths: [root], watchedFiles: [fixed], seedDynamicFiles: [first, second],
            dynamicExtensions: ["jsonl"], monitor: monitor, onDirty: {}
        )
        // Fixed path consumes one slot. Touch first with a real vnode write,
        // then discover third: the untouched second path must be evicted.
        // The FSEvents stream may deliver registration-time topology events
        // after init, so use the monitor's recency seam to wait specifically
        // for the vnode callback rather than using the source dirty counter.
        let watcherDeadline = Date().addingTimeInterval(2)
        while (!monitor.watchedPaths.contains(first.path)
            || !monitor.watchedPaths.contains(second.path)) && Date() < watcherDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(monitor.watchedPaths.contains(first.path))
        XCTAssertTrue(monitor.watchedPaths.contains(second.path))
        let firstSequence = monitor.accessSequence(for: first) ?? 0
        let fd = open(first.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { source.stop(); return }
        defer { close(fd); source.stop() }
        var byte: UInt8 = 1
        XCTAssertEqual(withUnsafePointer(to: &byte) { Darwin.write(fd, $0, 1) }, 1)
        XCTAssertEqual(fsync(fd), 0)
        let deadline = Date().addingTimeInterval(2)
        while (monitor.accessSequence(for: first) ?? 0) <= firstSequence && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(monitor.accessSequence(for: first) ?? 0, firstSequence)
        FileManager.default.createFile(atPath: third.path, contents: Data())
        monitor.handleTopologyEventForTesting(
            path: third.path,
            flags: UInt32(kFSEventStreamEventFlagItemCreated)
        )
        XCTAssertEqual(monitor.vnodeWatcherCount, 3)
        XCTAssertTrue(monitor.watchedPaths.contains(fixed.path))
        XCTAssertTrue(monitor.watchedPaths.contains(first.path))
        XCTAssertFalse(monitor.watchedPaths.contains(second.path))

        let pinnedOnlyMonitor = LocalUsageFileMonitor(maxVnodeWatchers: 1, autoDiscoveryEnabled: false)
        let pinnedSource = LocalUsageSourceLifecycle(
            paths: [root], watchedFiles: [fixed], dynamicExtensions: ["jsonl"],
            monitor: pinnedOnlyMonitor, onDirty: {}
        )
        pinnedSource.touchHotFiles([third])
        XCTAssertEqual(pinnedOnlyMonitor.vnodeWatcherCount, 1)
        XCTAssertTrue(pinnedOnlyMonitor.watchedPaths.contains(fixed.path))
        pinnedSource.stop()
    }

    @MainActor
    func testDirtyDuringScanRemainsDirtyWithoutImmediateRescan() async throws {
        let gate = ScanGate()
        let scanner = DirtyDuringScanProbe(gate: gate)
        scanner.scan()
        await gate.waitUntilStarted()
        scanner.markFresh()
        scanner.markDirty()
        await gate.release()
        try await scanner.waitUntilSettled()

        XCTAssertEqual(scanner.lastResult, 1)
        XCTAssertTrue(scanner.isDirty, "扫描期间的新 dirty revision 不应被成功结果清掉")
        XCTAssertFalse(scanner.isScanning)
    }
}
