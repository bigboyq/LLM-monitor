import Foundation

/// 渲染期派生值的 memo：**键逐字相等**就复用上次算出的值，不等就重算。
///
/// 存在的唯一理由是 `DisplayClock`（`Views/DisplayClock.swift`）：provider 卡片
/// 的 body 由展示时钟**每秒**重 eval（dock 详情浮层与菜单兜底行的 hover 卡都在
/// `DisplayClockScope` 内），而卡片 body 里的投影（per-model 四桶 + 逐条计价，
/// DeepSeek 还要逐条按北京时间判峰谷）与 7 天金额都是 **O(samples)** 的迭代 ——
/// DSH 账本的 `recentSamples` 上限是 65536，于是「底层数据一秒没变」也要把万级
/// 迭代 + 逐条日历判定重跑一遍，浮层可见期间表现为主线程周期性卡顿。
/// （命中判断本身便宜：键里的样本数组走 `Array ==` 的 COW buffer identity 快路径，
/// 共享 buffer 时是指针比较而非逐元素——实测 ~0.16 µs/次；被消掉的大头是"重跑 compute"。）
///
/// 失效策略：**键由全部输入值构成**，没有另外的脏标记 / 广播通道。任何输入变化
/// 都必须体现在键里——漏掉一次的后果是界面显示过期数字，而且不崩溃、不报错、
/// 没有日志，因此宁可多算一次（本类在"值其实没变"的键上也会重算，见下）。
///
/// 有界：`entries` 按调用方给的 `Slot` 分槽（卡片按 provider id），每槽**只留**
/// 最近一次的 (key, value)，条目数 = 出现过的 slot 数，不随 tick 数增长。
/// `@unchecked Sendable`：全部可变状态（`entries` 与计数）都在 `lock` 内读写，
/// 跨隔离域共享安全；这是 Swift 6 模式下 `static let memo` 能编译的前提。
/// `Value` 自身的跨线程安全仍由调用方保证——当前两个使用点都只从 MainActor 访问。
final class DerivedValueMemo<Slot: Hashable, Key: Equatable, Value>: @unchecked Sendable {
    private struct Entry {
        let key: Key
        let value: Value
    }

    private let lock = NSLock()
    private var entries: [Slot: Entry] = [:]

    /// 真正算过几次（"算"= 跑了 `compute`）。留给测试钉"tick 没有重算"——
    /// 这类断言没法从返回值上观察，只能数次数（与
    /// `Services/ClientUsageAggregation.swift` 的 `HarnessSummaryCache.computeCount`
    /// 同一思路）。读也走锁：`@unchecked Sendable` 的承诺必须名副其实。
    var computeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return computeCountStorage
    }

    private var computeCountStorage: Int = 0

    /// 当前占用的槽数（测试口径：证明缓存有界、不随 tick 增长）。
    var slotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// 命中返回上次的值；未命中（首次 / 键变了）才跑 `compute` 并覆盖该槽。
    func value(for slot: Slot, key: Key, compute: () -> Value) -> Value {
        lock.lock()
        let cached = entries[slot]
        lock.unlock()
        if let cached, cached.key == key {
            return cached.value
        }

        // 重算放在锁外：`compute` 自身不读写本 memo（无重入），不必让并发的
        // 另一个渲染线程等一遍 O(samples) 的迭代。
        let computed = compute()

        lock.lock()
        entries[slot] = Entry(key: key, value: computed)
        computeCountStorage &+= 1
        lock.unlock()
        return computed
    }

    /// 清空（测试用）：槽位与计数一起归零，好让每个用例从 0 起算。
    /// 生产路径**没有**手动失效入口：键变了自然失效，
    /// 少一个"忘了调 invalidate"的失效面。
    func reset() {
        lock.lock()
        entries.removeAll()
        computeCountStorage = 0
        lock.unlock()
    }
}
