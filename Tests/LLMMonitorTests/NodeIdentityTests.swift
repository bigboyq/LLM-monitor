import XCTest
@testable import LLM_monitor

/// 节点身份与序号：稳定 UUID、先持久化再分配的 seq、失败不换身份（§6.2 / §7.3）。
final class NodeIdentityTests: XCTestCase {

    /// 内存后端：模拟 Keychain 的持久语义（同 backend = 同存储）。
    private final class InMemoryBackend: NodeIdentityBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        var failOnSave = false

        func load() throws -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return data
        }

        func save(_ data: Data) throws {
            if failOnSave { throw NodeIdentityError.keychainStatus(-34018) }
            lock.lock()
            defer { lock.unlock() }
            self.data = data
        }
    }

    private final class CorruptedBackend: NodeIdentityBackend, @unchecked Sendable {
        func load() throws -> Data? { Data("not-json".utf8) }
        func save(_ data: Data) throws {}
    }

    func testIdentityIsStableAcrossStores() throws {
        let backend = InMemoryBackend()
        let first = try NodeIdentityStore(backend: backend).identity()
        XCTAssertEqual(first.lastIssuedSeq, 0)
        // 新 store 实例（同持久层）必须读到同一身份——不静默换 UUID。
        let second = try NodeIdentityStore(backend: backend).identity()
        XCTAssertEqual(first.nodeID, second.nodeID)
    }

    func testAllocateSeqPersistsBeforeReturning() throws {
        let backend = InMemoryBackend()
        let store = NodeIdentityStore(backend: backend)
        XCTAssertEqual(try store.allocateSeq(), 1)
        XCTAssertEqual(try store.allocateSeq(), 2)
        XCTAssertEqual(try store.allocateSeq(), 3)
        // 重开（模拟进程重启）：序号延续，迟到报告可被 hub 的 high-water 拒绝。
        let reopened = NodeIdentityStore(backend: backend)
        XCTAssertEqual(try reopened.allocateSeq(), 4)
    }

    func testAllocateSeqThrowsOnPersistenceFailure() throws {
        let backend = InMemoryBackend()
        backend.failOnSave = true
        let store = NodeIdentityStore(backend: backend)
        // 首次身份生成也要落盘：失败必须抛错（不发送、不换 UUID）。
        XCTAssertThrowsError(try store.identity())
        XCTAssertThrowsError(try store.allocateSeq())
    }

    func testCorruptedPayloadThrowsInsteadOfResetting() throws {
        let store = NodeIdentityStore(backend: CorruptedBackend())
        XCTAssertThrowsError(try store.identity()) { error in
            guard case NodeIdentityError.corruptedPayload = error else {
                return XCTFail("损坏负载应报 corruptedPayload，而不是静默换新 UUID：\(error)")
            }
        }
    }

    func testForceResetIssuesNewIdentity() throws {
        let backend = InMemoryBackend()
        let store = NodeIdentityStore(backend: backend)
        let old = try store.identity()
        _ = try store.allocateSeq()
        let new = try store.forceReset()
        XCTAssertNotEqual(old.nodeID, new.nodeID, "强制换 UUID = 新节点（旧 nodeID 由 hub 保留，§7.6）")
        XCTAssertEqual(new.lastIssuedSeq, 0)
        XCTAssertEqual(try store.identity(), new)
    }

    func testDefaultNodeNameIsNonEmpty() {
        XCTAssertFalse(NodeIdentityStore.defaultNodeName().isEmpty)
    }
}
