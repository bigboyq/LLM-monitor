import XCTest
import Combine
import AppKit
@testable import LLM_monitor

// 双循环架构回归测试用的替身：`DualLoopReconcileTests` 与 `DualLoopHardFullTriggerTests`
// 共用，所以不住在任何一个测试类里。原先全部是文件作用域 `private`，跨文件后放开。
actor ReconcilePassProbe {
    private var modes: [LocalUsageScanMode] = []
    private var blockSecondPass = false
    private var firstStartContinuation: CheckedContinuation<Void, Never>?
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?
    private var secondStartContinuation: CheckedContinuation<Void, Never>?
    private var secondReleaseContinuation: CheckedContinuation<Void, Never>?
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func run(_ mode: LocalUsageScanMode) async {
        modes.append(mode)
        resumeCountWaiters()
        if modes.count == 1 {
            firstStartContinuation?.resume()
            firstStartContinuation = nil
            await withCheckedContinuation { continuation in
                firstReleaseContinuation = continuation
            }
        } else if modes.count == 2, blockSecondPass {
            secondStartContinuation?.resume()
            secondStartContinuation = nil
            await withCheckedContinuation { continuation in
                secondReleaseContinuation = continuation
            }
        }
    }

    func waitForFirstStart() async {
        guard modes.isEmpty else { return }
        await withCheckedContinuation { continuation in
            firstStartContinuation = continuation
        }
    }

    func releaseFirst() {
        firstReleaseContinuation?.resume()
        firstReleaseContinuation = nil
    }

    func setBlockSecondPass(_ block: Bool) {
        blockSecondPass = block
    }

    func waitForSecondStart() async {
        guard modes.count < 2 else { return }
        await withCheckedContinuation { continuation in
            secondStartContinuation = continuation
        }
    }

    func releaseSecond() {
        secondReleaseContinuation?.resume()
        secondReleaseContinuation = nil
    }

    func waitForCount(_ expected: Int) async {
        guard modes.count < expected else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((expected, continuation))
        }
    }

    func snapshot() -> [LocalUsageScanMode] { modes }

    private func resumeCountWaiters() {
        let ready = countWaiters.filter { modes.count >= $0.0 }
        countWaiters.removeAll { modes.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

actor ScannerTestGate {
    private var entered = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitForEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
final class LifecycleProbeScanner: LocalUsageScannerBase<Int>, @unchecked Sendable {
    private let gate: ScannerTestGate
    private let lock = AsyncMutex()

    nonisolated override var pipelineLock: AsyncMutex { lock }

    init(gate: ScannerTestGate) {
        self.gate = gate
        super.init(logTag: "[test-scanner]", cachedResult: nil)
    }

    override func makeWork(
        startedGeneration: UInt64,
        mode: LocalUsageScanMode
    ) -> @Sendable () async throws -> Int {
        let gate = self.gate
        return {
            await gate.wait()
            return 1
        }
    }
}

/// 记录每轮扫描 mode 的探针 scanner：按轮次取用 gates 让第 N 轮扫描阻塞在
/// 扫描中段，供测试在 in-flight 期间注入更强请求；未提供 gate 的轮次立即完成。
@MainActor
final class ModeProbeScanner: LocalUsageScannerBase<Int>, @unchecked Sendable {
    private let lock = AsyncMutex()
    nonisolated override var pipelineLock: AsyncMutex { lock }

    private(set) var recordedModes: [LocalUsageScanMode] = []
    private let gates: [ScannerTestGate]

    init(gates: [ScannerTestGate]) {
        self.gates = gates
        super.init(logTag: "[mode-probe-scanner]", cachedResult: nil)
    }

    override func makeWork(
        startedGeneration: UInt64,
        mode: LocalUsageScanMode
    ) -> @Sendable () async throws -> Int {
        recordedModes.append(mode)
        let gate = recordedModes.count <= gates.count ? gates[recordedModes.count - 1] : nil
        return {
            if let gate { await gate.wait() }
            return 1
        }
    }
}

/// Antigravity scanner 的测试替身：scan(mode:) 只记录请求模式，不产生 I/O；
/// waitUntilSettled 挂起直到 settle()/cancelInFlight() 放行，可精确模拟
/// "in-flight 扫描未结束"与"调用方被取消"的组合。
@MainActor
final class BlockingAntigravityScanner: LocalUsageScanner {
    let resultSubject = CurrentValueSubject<AntigravityLocalUsage?, Never>(nil)
    let scanningSubject = CurrentValueSubject<Bool, Never>(false)
    private(set) var recordedModes: [LocalUsageScanMode] = []
    private var waiters: [CheckedContinuation<Void, Error>] = []

    var waiterCount: Int { waiters.count }

    func scan() { scan(mode: .dirty) }

    func scan(mode: LocalUsageScanMode) {
        recordedModes.append(mode)
    }

    var isDirty: Bool { false }
    var lastFreshAt: Date? { nil }
    func markDirty() {}
    func markFresh(at date: Date) {}

    func waitUntilSettled() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeWaiters { $0.resume(throwing: CancellationError()) }
            }
        }
        try Task.checkCancellation()
    }

    /// 取消必须以错误唤醒等待方，与 `LocalUsageScannerBase.cancelInFlight()`
    /// 的生产语义一致，且与 settle() 的成功唤醒可区分（等待方不得把"扫描被取消"
    /// 误报成"已完成"）。
    func cancelInFlight() {
        resumeWaiters { $0.resume(throwing: CancellationError()) }
    }

    /// 放行所有等待者，模拟 in-flight 扫描 settle 完成。
    func settle() {
        resumeWaiters { $0.resume(returning: ()) }
    }

    private func resumeWaiters(_ resume: (CheckedContinuation<Void, Error>) -> Void) {
        let pending = waiters
        waiters.removeAll()
        pending.forEach(resume)
    }

    var lastResultPublisher: AnyPublisher<AntigravityLocalUsage?, Never> { resultSubject.eraseToAnyPublisher() }
    var isScanningPublisher: AnyPublisher<Bool, Never> { scanningSubject.eraseToAnyPublisher() }
}

/// LocalUsage reconcile（provider-batch 架构）测试里的空写入者：只满足
/// `LocalUsageOrchestration` 的构造协议表面，不产生任何状态写入。
@MainActor
final class ReconcileNoopWriter: LocalUsageStatusWriting {
    func providerID(for kind: ProviderKind) -> String? { nil }
    func setScanningState(_ isScanning: Bool, for providerID: String) {}
    func applyAntigravityLocalUsage(_ usage: AntigravityLocalUsage?) {}
    func applyMinimaxLocalUsage(_ usage: ProviderLocalUsage?) {}
    func applyGlmLocalUsage(_ usage: GlmLocalUsage?) {}
    func applyOpencodeUsage(_ usage: OpencodeLocalUsage?) {}
    func applyDshUsage(_ usage: DshLocalUsage?) {}
    func codexEnrichmentTarget() -> (providerID: String, authPath: String?, model: ModelQuota?, fetchedAt: Date, generation: Int)? { nil }
    func codexConfiguredAuthPath() -> String? { nil }
    func applyCodexUsageDetails(_ details: CodexUsageDetails?, providerID: String, fetchedAt: Date, configurationGeneration: Int) {}
}
