import Foundation

/// 基于哈希表与双向链表实现的通用 $O(1)$ LRU (Least Recently Used) 缓存容器。
///
/// 内部通过双向链表维护访问时序，结合字典映射实现常数时间复杂度的查找、插入、更新与淘汰：
/// - `value(forKey:)` / 下标读取：$O(1)$ 查找并自动将命中节点移至链表尾部（最新访问）；
/// - `setValue(_:forKey:)`：$O(1)$ 插入或更新；若超出 `capacity`，直接淘汰链表头部（最久未访问）节点；
/// - `removeValue(forKey:)`：$O(1)$ 精确移除指定节点；
/// - `removeAll(except:)`：支持按白名单键集合批量裁剪，保留活跃项；
/// - 动态调整 `capacity`：若缩小容量，立即自动剔除超量的陈旧节点。
///
/// - Note: 本容器为基础非并发数据结构，并发保护应由持有者（例如 actor 或锁）负责。
public final class LRUCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var prev: Node?
        var next: Node?

        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    private var table: [Key: Node] = [:]
    private var head: Node? // 最久未访问 (LRU)
    private var tail: Node? // 最新访问 (MRU)

    /// 缓存的最大容量。当容量被缩小时，会自动剔除最久未使用的项。
    public var capacity: Int {
        didSet {
            precondition(capacity > 0, "LRUCache capacity must be greater than 0")
            trimToCapacity()
        }
    }

    /// 当前缓存中的条目数。
    public var count: Int {
        table.count
    }

    /// 缓存是否为空。
    public var isEmpty: Bool {
        table.isEmpty
    }

    /// 按从最久未访问到最新访问的顺序返回所有键（常用于单测与调试检查）。
    public var keysOrderedByRecency: [Key] {
        var result: [Key] = []
        result.reserveCapacity(table.count)
        var current = head
        while let node = current {
            result.append(node.key)
            current = node.next
        }
        return result
    }

    public init(capacity: Int) {
        precondition(capacity > 0, "LRUCache capacity must be greater than 0")
        self.capacity = capacity
    }

    /// 获取指定键对应的值。若命中，会将该项移至最新访问位置。
    public func value(forKey key: Key) -> Value? {
        guard let node = table[key] else { return nil }
        moveToTail(node)
        return node.value
    }

    /// 插入或更新键值对。若超出容量，则自动淘汰最久未访问的条目。
    public func setValue(_ value: Value, forKey key: Key) {
        if let existing = table[key] {
            existing.value = value
            moveToTail(existing)
            return
        }

        let node = Node(key: key, value: value)
        table[key] = node
        appendToTail(node)
        trimToCapacity()
    }

    /// 便利下标访问：获取时更新访问顺序；赋值为 nil 时删除对应键。
    public subscript(key: Key) -> Value? {
        get {
            value(forKey: key)
        }
        set {
            if let newValue {
                setValue(newValue, forKey: key)
            } else {
                removeValue(forKey: key)
            }
        }
    }

    /// 移除指定键及其对应的值。
    @discardableResult
    public func removeValue(forKey key: Key) -> Value? {
        guard let node = table.removeValue(forKey: key) else { return nil }
        removeNode(node)
        return node.value
    }

    /// 清空所有已缓存的条目。
    public func removeAll() {
        table.removeAll()
        head = nil
        tail = nil
    }

    /// 保留集合中指定的键，移除其余所有条目。
    public func removeAll(except keysToKeep: Set<Key>) {
        var current = head
        while let node = current {
            let next = node.next
            if !keysToKeep.contains(node.key) {
                table.removeValue(forKey: node.key)
                removeNode(node)
            }
            current = next
        }
    }

    // MARK: - 内部链表操作

    private func appendToTail(_ node: Node) {
        if let currentTail = tail {
            currentTail.next = node
            node.prev = currentTail
            node.next = nil
            tail = node
        } else {
            head = node
            tail = node
            node.prev = nil
            node.next = nil
        }
    }

    private func removeNode(_ node: Node) {
        if let prev = node.prev {
            prev.next = node.next
        } else {
            head = node.next
        }

        if let next = node.next {
            next.prev = node.prev
        } else {
            tail = node.prev
        }

        node.prev = nil
        node.next = nil
    }

    private func moveToTail(_ node: Node) {
        guard node !== tail else { return }
        removeNode(node)
        appendToTail(node)
    }

    private func trimToCapacity() {
        while table.count > capacity, let oldest = head {
            table.removeValue(forKey: oldest.key)
            removeNode(oldest)
        }
    }
}
