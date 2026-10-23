import Foundation
import Security

// MARK: - 节点身份（§6.2）

/// 稳定节点身份：UUID 与 `lastIssuedSeq` 永远作为**同一个**持久条目读写。
struct NodeIdentity: Equatable, Sendable, Codable {
    let nodeID: UUID
    var lastIssuedSeq: Int
}

/// 持久化后端抽象：生产走 Keychain，测试注入内存 / 故障后端。
protocol NodeIdentityBackend: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// Keychain 后端。`kSecAttrSynchronizable = false`：nodeID 是机器身份，
/// 不随 iCloud Keychain 同步到其它机器（用户裁定 2026-10-24）。
final class KeychainNodeIdentityBackend: NodeIdentityBackend {
    private let service: String
    private let account: String

    init(service: String = "LLM-monitor.fleet-sync", account: String = "node-identity") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw NodeIdentityError.keychainStatus(status)
        }
    }

    func save(_ data: Data) throws {
        var query = baseQuery
        query[kSecValueData as String] = data
        // 先 add，冲突（已存在）则 update：避免 delete + add 之间的身份空窗。
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: data]
            status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw NodeIdentityError.keychainStatus(status)
        }
    }
}

enum NodeIdentityError: Error, CustomStringConvertible, Equatable {
    /// Keychain 读写失败：停止同步，不得静默换 UUID（§6.2）。
    case keychainStatus(OSStatus)
    case corruptedPayload

    var description: String {
        switch self {
        case .keychainStatus(let status):
            return "Keychain 操作失败（OSStatus \(status)）"
        case .corruptedPayload:
            return "节点身份持久化数据损坏"
        }
    }
}

/// 身份与序号的唯一入口。`allocateSeq` **先持久化递增后的序号、成功后才返回**，
/// 让 hub 的最大已接受 seq 能拒绝迟到报告，不需要 epoch 或恢复握手（§7.3）。
/// `@unchecked`：内部 NSLock 保护 `cached` 的跨线程访问。
final class NodeIdentityStore: @unchecked Sendable {
    private let backend: any NodeIdentityBackend
    private let lock = NSLock()
    private var cached: NodeIdentity?

    init(backend: any NodeIdentityBackend) {
        self.backend = backend
    }

    /// 读取（或首次生成并一次性保存）稳定身份。任何持久化失败都抛错，
    /// 调用方不得回退到临时 UUID。
    func identity() throws -> NodeIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let identity = try loadOrCreate()
        cached = identity
        return identity
    }

    /// 分配下一个报告序号：读 → +1 → 持久化 → 返回。持久化失败抛错，不发送。
    func allocateSeq() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        var identity = try loadOrCreate()
        identity.lastIssuedSeq += 1
        let payload = try encode(identity)
        try backend.save(payload)
        cached = identity
        return identity.lastIssuedSeq
    }

    /// 用户显式「强制换 UUID」：生成新身份（seq 归零），hub 侧旧 nodeID 保留，
    /// 由用户手动移除（§6.2 / §7.6）。
    func forceReset() throws -> NodeIdentity {
        lock.lock()
        defer { lock.unlock() }
        let identity = NodeIdentity(nodeID: UUID(), lastIssuedSeq: 0)
        try backend.save(try encode(identity))
        cached = identity
        return identity
    }

    private func loadOrCreate() throws -> NodeIdentity {
        if let cached { return cached }
        let data = try backend.load()
        if let data {
            guard let identity = try? FleetCodec.decode(NodeIdentity.self, from: data) else {
                throw NodeIdentityError.corruptedPayload
            }
            cached = identity
            return identity
        }
        let identity = NodeIdentity(nodeID: UUID(), lastIssuedSeq: 0)
        try backend.save(try encode(identity))
        cached = identity
        return identity
    }

    private func encode(_ identity: NodeIdentity) throws -> Data {
        try FleetCodec.encode(identity)
    }

    /// 默认节点显示名：hostname。
    static func defaultNodeName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}
