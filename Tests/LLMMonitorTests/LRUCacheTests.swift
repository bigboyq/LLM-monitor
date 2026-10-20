import XCTest
@testable import LLM_monitor

final class LRUCacheTests: XCTestCase {
    func testBasicStoreAndRetrieve() {
        let cache = LRUCache<String, Int>(capacity: 3)
        XCTAssertTrue(cache.isEmpty)
        XCTAssertEqual(cache.count, 0)

        cache.setValue(100, forKey: "a")
        cache.setValue(200, forKey: "b")

        XCTAssertEqual(cache.count, 2)
        XCTAssertFalse(cache.isEmpty)
        XCTAssertEqual(cache.value(forKey: "a"), 100)
        XCTAssertEqual(cache.value(forKey: "b"), 200)
        XCTAssertNil(cache.value(forKey: "c"))
    }

    func testCapacityEviction() {
        let cache = LRUCache<String, String>(capacity: 2)

        cache.setValue("1", forKey: "k1")
        cache.setValue("2", forKey: "k2")
        XCTAssertEqual(cache.keysOrderedByRecency, ["k1", "k2"])

        // 插入第 3 个，最久未用的 k1 应被淘汰
        cache.setValue("3", forKey: "k3")
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.value(forKey: "k1"))
        XCTAssertEqual(cache.value(forKey: "k2"), "2")
        XCTAssertEqual(cache.value(forKey: "k3"), "3")
        XCTAssertEqual(cache.keysOrderedByRecency, ["k2", "k3"])
    }

    func testAccessPromotesRecency() {
        let cache = LRUCache<String, Int>(capacity: 3)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        cache.setValue(3, forKey: "c")
        XCTAssertEqual(cache.keysOrderedByRecency, ["a", "b", "c"])

        // 读取 "a"，使 "a" 提升至最新访问 (尾部)
        XCTAssertEqual(cache.value(forKey: "a"), 1)
        XCTAssertEqual(cache.keysOrderedByRecency, ["b", "c", "a"])

        // 插入 "d"，此时最久未访问的是 "b"，淘汰 "b" 而非 "a"
        cache.setValue(4, forKey: "d")
        XCTAssertNil(cache.value(forKey: "b"))
        XCTAssertEqual(cache.value(forKey: "a"), 1)
        XCTAssertEqual(cache.value(forKey: "c"), 3)
        XCTAssertEqual(cache.value(forKey: "d"), 4)
    }

    func testUpdateExistingKey() {
        let cache = LRUCache<String, String>(capacity: 2)
        cache.setValue("old-a", forKey: "a")
        cache.setValue("b", forKey: "b")

        // 更新 "a"，值被替换且位置刷新到最新
        cache.setValue("new-a", forKey: "a")
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.value(forKey: "a"), "new-a")
        XCTAssertEqual(cache.keysOrderedByRecency, ["b", "a"])

        // 插入 "c"，应淘汰 "b"
        cache.setValue("c", forKey: "c")
        XCTAssertNil(cache.value(forKey: "b"))
        XCTAssertEqual(cache.value(forKey: "a"), "new-a")
    }

    func testSubscriptSyntax() {
        let cache = LRUCache<String, Int>(capacity: 2)
        cache["x"] = 42
        cache["y"] = 84

        XCTAssertEqual(cache["x"], 42)
        XCTAssertEqual(cache["y"], 84)

        // 通过下标置 nil 移除
        cache["x"] = nil
        XCTAssertNil(cache["x"])
        XCTAssertEqual(cache.count, 1)
    }

    func testRemoveValue() {
        let cache = LRUCache<String, Int>(capacity: 3)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        cache.setValue(3, forKey: "c")

        let removed = cache.removeValue(forKey: "b")
        XCTAssertEqual(removed, 2)
        XCTAssertNil(cache.value(forKey: "b"))
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.keysOrderedByRecency, ["a", "c"])

        let removeMissing = cache.removeValue(forKey: "non-existent")
        XCTAssertNil(removeMissing)
    }

    func testRemoveAll() {
        let cache = LRUCache<String, Int>(capacity: 3)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")

        cache.removeAll()
        XCTAssertTrue(cache.isEmpty)
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.value(forKey: "a"))
        XCTAssertNil(cache.value(forKey: "b"))
    }

    func testRemoveAllExceptWhitelist() {
        let cache = LRUCache<String, Int>(capacity: 5)
        cache.setValue(1, forKey: "s1")
        cache.setValue(2, forKey: "s2")
        cache.setValue(3, forKey: "s3")
        cache.setValue(4, forKey: "s4")

        // 仅保留 s2 和 s4
        cache.removeAll(except: ["s2", "s4"])
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.value(forKey: "s1"))
        XCTAssertEqual(cache.value(forKey: "s2"), 2)
        XCTAssertNil(cache.value(forKey: "s3"))
        XCTAssertEqual(cache.value(forKey: "s4"), 4)
        XCTAssertEqual(cache.keysOrderedByRecency, ["s2", "s4"])
    }

    func testDynamicCapacityShrink() {
        let cache = LRUCache<String, Int>(capacity: 4)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        cache.setValue(3, forKey: "c")
        cache.setValue(4, forKey: "d")

        // 缩容至 2，应剔除最老的 a 和 b
        cache.capacity = 2
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.value(forKey: "a"))
        XCTAssertNil(cache.value(forKey: "b"))
        XCTAssertEqual(cache.value(forKey: "c"), 3)
        XCTAssertEqual(cache.value(forKey: "d"), 4)
        XCTAssertEqual(cache.keysOrderedByRecency, ["c", "d"])
    }
}
