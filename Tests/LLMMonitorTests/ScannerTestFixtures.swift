import XCTest
@testable import LLM_monitor

/// 原本是 `ScannerAndLoggingTests` 内的文件级私有 actor，被 dirty-during-scan
/// 探针（`LocalUsageLifecycleTests`）与 AsyncMutex 取消规则
/// （`AsyncMutexTests`）两组用例同时引用；拆文件时抽到这里。
/// 沿用 `GlmTestCase` 的既有约定：共享桩不留在任一测试文件里，避免重复定义。
actor ScanGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func enter() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !released {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

/// 扫描器 / 生命周期用例的共享基类：提供 `testGate` 复位（tearDown）与
/// `waitUntil` 轮询助手，调用点一个字符都不用改。
/// 它自己没有 `test*` 方法。
class ScannerTestCase: XCTestCase {

    override func tearDown() {
        MinimaxLocalUsageScanner.testGate = nil
        AntigravityLocalUsageScanner.testGate = nil
        super.tearDown()
    }

    @MainActor
    func waitUntil(
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
}
