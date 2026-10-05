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
        try await Task.sleep(nanoseconds: 150_000_000)
        watcher.stop()

        XCTAssertTrue(events.isEmpty, "注册 watcher 不应凭空产生 dirty event: \(events)")
    }

    /// FSEvents context 的所有权归属：stream 存活期间 context 由 FSEvents 持有
    /// （回调不会拿到悬垂指针），`stop()` 释放 stream 后 FSEvents 通过 release
    /// 回调归还（context 不泄漏）。context 只弱引用 watcher，所以 watcher ↔ stream
    /// 不成环——丢掉最后一个强引用就能释放。
    @MainActor
    func testFSEventsContextIsRetainedWhileRunningAndReleasedOnStop() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-fsevents-ctx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var events: [LocalFSEventsEvent] = []
        weak var weakWatcher: LocalFSEventsWatcher?
        do {
            let watcher = LocalFSEventsWatcher(paths: [root]) { event in
                events.append(event)
            }
            weakWatcher = watcher
            // scanner 每轮扫描复用同一生命周期对象：start/stop 多轮，每轮都要
            // 重新配对一次 context 的 retain/release。
            for _ in 0..<2 {
                watcher.start()
                XCTAssertNotNil(watcher.contextForTesting, "FSEvents 应持有 context 强引用")
                watcher.stop()
                await waitUntil(timeout: 2, message: "stop 后 FSEvents 应归还 context 引用") {
                    watcher.contextForTesting == nil
                }
                XCTAssertFalse(watcher.isRunning, "stop 后 stream 不应仍在运行")
            }
        }
        XCTAssertNil(weakWatcher, "context 不得把 watcher 强引用住形成泄漏环")
        // 让主 actor 把已派发的回调 Task 跑完：此时 context 已释放，回调至多
        // 拿到 nil 的弱引用——不应崩溃，也不再产生投递。
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(events.isEmpty, "未写入被监听目录，不应有事件: \(events)")
    }

    @MainActor
    func testLocalVnodeWriteWatcherSeesAppendWhileWriterRemainsOpen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-vnode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("runtime.sqlite")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        var deliveries = 0
        let vnode = LocalVnodeWriteWatcher(path: file) {
            deliveries += 1
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
        // 与本文件其余 vnode 用例一致改用 waitUntil 轮询（不用 `fulfillment`）：
        // 共享主 actor 上前序用例遗留的 Task / DispatchSource 可能占满主 actor，
        // 硬超时预算会被吃掉；轮询只在条件成立时才消耗预算。
        await waitUntil(timeout: 2, message: "append 事件未到：writer 保持打开时 vnode 写入应投递 dirty") {
            deliveries == 1
        }
        let fileSize = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(fileSize, 0)
    }

    /// M8 合并窗口：首事件即时投递；窗口内后续事件合并为窗口结束时的一次
    /// 投递；窗口空闲后的新写入再次即时投递。窗口注入 0.3s（生产默认 0.25s），
    /// 让多次 40ms 间隔的 append 稳定落在同一窗口内。到达性断言用 waitUntil
    /// 轮询（不人为设投递时延上限），合并/不投递断言保持严格相等——那才是
    /// 被测语义。生产默认窗口的同机制冒烟见下一个用例。
    @MainActor
    func testLocalVnodeWriteWatcherCoalescesRapidAppendsIntoSingleDelivery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-vnode-coalesce-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("runtime.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        var deliveries = 0
        let vnode = LocalVnodeWriteWatcher(path: file, coalescingWindow: 0.3) {
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
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTAssertEqual(deliveries, 1, "窗口内的连续 append 不应逐条投递，实际 \(deliveries)")

        // 窗口（0.3s）结束时，窗口内的后续 append 合并为一次投递
        await waitUntil(timeout: 2, message: "窗口内的后续 append 应合并为一次投递") { deliveries == 2 }

        // 第二个窗口（0.3s）空闲到期：不应产生追加投递。负向断言只能靠足额静置
        // （> 窗口）而不是条件等待——条件等待会立即返回。
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(deliveries, 2)
        XCTAssertEqual(withUnsafePointer(to: &byte) { Darwin.write(fd, $0, 1) }, 1)
        XCTAssertEqual(fsync(fd), 0)
        await waitUntil(timeout: 2, message: "窗口空闲后的新写入应再次投递") { deliveries == 3 }
    }

    /// 冒烟：合并机制在较宽窗口（0.5s，与本文件压缩版同量级、贴近生产默认
    /// 0.25s 的放大值）下同样成立——守住"窗口空闲后的新写入再次即时投递"这条
    /// 与窗口取值无关的语义，防止压缩窗口的用例掩盖真实行为差异。
    @MainActor
    func testLocalVnodeWriteWatcherCoalescesAtProductionScaleWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-vnode-coalesce-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("runtime.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        var deliveries = 0
        let vnode = LocalVnodeWriteWatcher(path: file, coalescingWindow: 0.5) {
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

        // 窗口内再写一次：合并，不逐条投递
        XCTAssertEqual(withUnsafePointer(to: &byte) { Darwin.write(fd, $0, 1) }, 1)
        XCTAssertEqual(fsync(fd), 0)
        XCTAssertEqual(deliveries, 1, "窗口内的后续写入应被合并，实际 \(deliveries)")

        // 窗口结束时合并为一次投递
        await waitUntil(timeout: 2, message: "窗口内的后续 append 应合并为一次投递") { deliveries == 2 }
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
        let vnode = LocalVnodeWriteWatcher(path: file, coalescingWindow: 0.4) {
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
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(deliveries, 1, "窗口内的后续写入应被合并，实际 \(deliveries)")
        // stop() 取消窗口：被合并的事件不应再投递
        vnode.stop()
        // 越过 0.4s 窗口后确认无幽灵投递。负向断言只能靠足额静置（> 窗口）
        // 而不是条件等待——条件等待会立即返回。
        try await Task.sleep(nanoseconds: 600_000_000)
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

    /// 静置：等"注册期"FSEvents 拓扑事件排空，返回时这些 source 的
    /// `eventGeneration` 已连续 `quietWindow` 秒不再增长。
    ///
    /// 为什么必须静置：`LocalUsageSourceLifecycle.init` 里就 `start()` 了流，
    /// 根目录 / seed 文件都是刚创建的，它们的创建事件会在注册后被
    /// fseventsd 补投并推进 `eventGeneration`。若直接快照 generation 再写入，
    /// 后续 `eventGeneration > 快照` 的等待会被这些**注册期**事件满足——
    /// 真实写入即使完全不发生，用例照样绿，断言失去意义（静置前已实测复现）。
    /// 静置把快照点挪到注册期事件之后，等待条件才重新只由被测写入满足。
    ///
    /// 有界性：整体不超过 `timeout`；每次观察到 generation 变化就重置安静窗口
    /// 计时。超时即 XCTFail 并说明"注册期事件未排空"，不会挂死也不会静默跳过。
    /// 边界值：`quietWindow` 0.6s 明显大于 FSEvents 的 0.25s 流延迟
    /// （`LocalFSEventsWatcher.start` 的 latency 参数）+ fseventsd 调度抖动，
    /// 所以"安静窗口内无事件"等价于"注册期事件已排空"；`timeout` 4s 给系统负载
    /// 高时留足余量，又远小于等待写入的 5s 预算，不会把用例拖成超时失败源。
    @MainActor
    private func settleSourceEvents(
        _ sources: [LocalUsageSourceLifecycle],
        quietWindow: TimeInterval = 0.6,
        timeout: TimeInterval = 4
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        var lastGenerations = sources.map(\.eventGeneration)
        var quietSince = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            let now = Date()
            let generations = sources.map(\.eventGeneration)
            if generations != lastGenerations {
                // 仍有注册期事件在到达：重新计时，直到它们彻底排空。
                lastGenerations = generations
                quietSince = now
            } else if now.timeIntervalSince(quietSince) >= quietWindow {
                return
            }
        }
        XCTFail(
            "注册期事件未在 \(Int(timeout)) 秒内排空"
                + "（安静窗口 \(quietWindow)s，最后一次 generation 变化发生在 \(lastGenerations)）"
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
        let source1 = LocalUsageSourceLifecycle(
            paths: [root], seedDynamicFiles: [file], dynamicExtensions: ["jsonl"], monitor: monitor,
            onDirty: {}
        )
        let source2 = LocalUsageSourceLifecycle(
            paths: [root], seedDynamicFiles: [file], dynamicExtensions: ["jsonl"], monitor: monitor,
            onDirty: {}
        )
        XCTAssertEqual(monitor.vnodeWatcherCount, 1)
        let fd = open(file.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd); source1.stop(); source2.stop() }
        var byte: UInt8 = 1
        // 不用 `fulfillment`（与 testGlobalMonitorLRURefreshesOnHotFileTouchAndProtectsPinned
        // 同理由）：共享主 actor 上前序用例遗留的 Task / DispatchSource 可能占满
        // 主 actor，硬 2s 预算会被吃掉。改为按 generation 轮询——`eventGeneration`
        // 在 `onDirty` 之前自增，等价于"dirty 回调至少发生过一次"。
        // 快照之前先静置：注册期拓扑事件也会推进 generation，不静置的话它们会
        // 直接满足下面的等待（删掉真实写入用例仍然绿）。见 settleSourceEvents。
        await settleSourceEvents([source1, source2])
        let generationBeforeFirstWrite1 = source1.eventGeneration
        let generationBeforeFirstWrite2 = source2.eventGeneration
        XCTAssertEqual(withUnsafePointer(to: &byte) { Darwin.write(fd, $0, 1) }, 1)
        XCTAssertEqual(fsync(fd), 0)
        await waitUntil(
            timeout: 5,
            message: "第 1 个事件未到：source1 应因共享 vnode 写入而 dirty（快照 generation=\(generationBeforeFirstWrite1)）"
        ) { source1.eventGeneration > generationBeforeFirstWrite1 }
        await waitUntil(
            timeout: 5,
            message: "第 2 个事件未到：source2 应因共享 vnode 写入而 dirty（快照 generation=\(generationBeforeFirstWrite2)）"
        ) { source2.eventGeneration > generationBeforeFirstWrite2 }

        source1.stop()
        XCTAssertEqual(monitor.vnodeWatcherCount, 1)
        let generationBeforeSecondWrite = source2.eventGeneration
        let secondFDWrite = withUnsafePointer(to: &byte) { Darwin.write(fd, $0, 1) }
        XCTAssertEqual(secondFDWrite, 1)
        XCTAssertEqual(fsync(fd), 0)
        await waitUntil(
            timeout: 5,
            message: "第 3 个事件未到：source1 停止后 source2 仍应独立收到 vnode 写入（快照 generation=\(generationBeforeSecondWrite)）"
        ) { source2.eventGeneration > generationBeforeSecondWrite }
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
