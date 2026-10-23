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

/// Keychain 后端：**优先 Data Protection Keychain**（`kSecUseDataProtectionKeychain`，
/// 现代「无密码」形态——条目不进经典文件钥匙串、无 ACL 授权弹窗，重建/重签后
/// 自建自读也永不要求 login 密码），**缺 entitlement 时透明回退经典钥匙串**：
/// ad-hoc 签名的本地构建（`swift build` / build-app.sh 的 `-` identity）没有
/// keychain entitlement，DP 钥匙串返回 `errSecMissingEntitlement(-34018)`——
/// 经典钥匙串里自建自读同样静默，只是同一台机器换了签名身份再访问旧条目
/// 可能弹授权框（开发期重建即如此；正式 Developer ID 构建走 DP 不受影响）。
///
/// `kSecAttrSynchronizable = false`（DP 形态下再叠加 `ThisDeviceOnly`）：
/// nodeID 是机器身份，不随 iCloud 同步（用户裁定 2026-10-24）。
final class KeychainNodeIdentityBackend: NodeIdentityBackend {
    private let service: String
    private let account: String
    /// 进程内缓存的 DP 可用性：首次操作探测，之后固定走同一种形态，
    /// 避免「写入走 DP、读取走经典」永远读不到对方条目。
    private var dataProtectionAvailable: Bool?

    init(service: String = "LLM-monitor.fleet-sync", account: String = "node-identity") {
        self.service = service
        self.account = account
    }

    private func baseQuery(useDataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return query
    }

    /// 读：按已缓存形态优先；`ItemNotFound` 时再把另一种形态也查一遍——
    /// 条目可能由旧构建写在另一种形态里，直接判「不存在」会静默换 UUID。
    func load() throws -> Data? {
        for useDP in candidateForms() {
            var search = baseQuery(useDataProtection: useDP)
            search[kSecReturnData as String] = true
            search[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(search as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                if dataProtectionAvailable == nil { dataProtectionAvailable = useDP }
                return item as? Data
            case errSecItemNotFound:
                continue
            case errSecMissingEntitlement:
                // DP 形态不可用（无 entitlement 的本地构建）：固定走经典。
                dataProtectionAvailable = false
                continue
            default:
                throw NodeIdentityError.keychainStatus(status)
            }
        }
        return nil
    }

    /// 写：按已缓存形态执行；add 冲突则 update（避免 delete + add 的身份空窗）。
    func save(_ data: Data) throws {
        for useDP in candidateForms() {
            let query = baseQuery(useDataProtection: useDP)
            var add = query
            add[kSecValueData as String] = data
            var status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                let update = [kSecValueData as String: data]
                status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            }
            if status == errSecMissingEntitlement {
                dataProtectionAvailable = false
                continue
            }
            guard status == errSecSuccess else {
                throw NodeIdentityError.keychainStatus(status)
            }
            if dataProtectionAvailable == nil { dataProtectionAvailable = useDP }
            return
        }
        throw NodeIdentityError.keychainStatus(errSecMissingEntitlement)
    }

    /// 探测顺序：已缓存 → 只试缓存形态；未缓存 → [DP, 经典]。
    /// 后续形态固定，避免「写进 DP、读走经典」永远错开。
    private func candidateForms() -> [Bool] {
        if let known = dataProtectionAvailable {
            return [known]
        }
        return [true, false]
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
