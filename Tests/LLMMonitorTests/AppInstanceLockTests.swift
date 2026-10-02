import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// 单实例锁（`AppInstanceLock`）的排他性与错误分类。对应 `AppInstanceLock`。
final class AppInstanceLockTests: StateTestCase {

    // MARK: - App Instance Lock

    @MainActor
    func testAppInstanceLockAllowsOnlyOneOwner() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-instance-lock-\(UUID().uuidString)", isDirectory: true)
        let lockURL = directory.appendingPathComponent("instance.lock")

        do {
            let first = AppInstanceLock.acquire(at: lockURL)
            XCTAssertNotNil(first)
            XCTAssertNil(AppInstanceLock.acquire(at: lockURL))
        }

        XCTAssertNotNil(AppInstanceLock.acquire(at: lockURL))
    }
    @MainActor
    func testAppInstanceLockResultDistinguishesContentionFromFilesystemFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-instance-lock-result-\(UUID().uuidString)", isDirectory: true)
        let lockURL = directory.appendingPathComponent("instance.lock")
        defer { try? FileManager.default.removeItem(at: directory) }

        guard case .acquired(let firstLock) = AppInstanceLock.acquireResult(at: lockURL) else {
            return XCTFail("首个实例应取得锁")
        }
        let contentionResult = withExtendedLifetime(firstLock) {
            AppInstanceLock.acquireResult(at: lockURL)
        }
        guard case .alreadyRunning = contentionResult else {
            return XCTFail("第二个实例应被识别为锁竞争")
        }

        let parentFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-lock-parent-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: parentFile)
        defer { try? FileManager.default.removeItem(at: parentFile) }

        guard case .failed(.createDirectoryFailed) = AppInstanceLock.acquireResult(
            at: parentFile.appendingPathComponent("instance.lock")
        ) else {
            return XCTFail("锁目录创建失败不应伪装成已有实例")
        }
    }
}
