import Foundation

/// Shared ordering helper for user-facing lists.
///
/// A persisted order is only a preference: missing, duplicated, or removed
/// IDs are ignored, while newly available items are appended in the supplied
/// default order. This keeps configuration stable when providers are added or
/// renamed without making display names part of the persisted identity.
enum DisplayOrder {
    static func ordered<Item>(
        _ items: [Item],
        preferredIDs: [String]?,
        id: (Item) -> String,
        by defaultComparator: (Item, Item) -> Bool
    ) -> [Item] {
        // 逐个塞而不是 `Dictionary(uniqueKeysWithValues:)`：后者遇到重复 id 直接
        // trap（`Fatal error: Duplicate values for key`），而 id 重复不该让整条
        // 渲染/命中链路崩掉。保留**先出现**的那个，与字典语义一致。
        var itemsByID: [String: Item] = [:]
        itemsByID.reserveCapacity(items.count)
        for item in items where itemsByID[id(item)] == nil {
            itemsByID[id(item)] = item
        }
        var result: [Item] = []
        var seen = Set<String>()

        for preferredID in preferredIDs ?? [] {
            guard let item = itemsByID[preferredID], seen.insert(preferredID).inserted else {
                continue
            }
            result.append(item)
        }

        for item in items.sorted(by: defaultComparator) {
            let itemID = id(item)
            guard seen.insert(itemID).inserted else { continue }
            result.append(item)
        }
        return result
    }

    static func normalizedIDs<Item>(
        _ items: [Item],
        preferredIDs: [String]?,
        id: (Item) -> String,
        by defaultComparator: (Item, Item) -> Bool
    ) -> [String] {
        ordered(
            items,
            preferredIDs: preferredIDs,
            id: id,
            by: defaultComparator
        ).map(id)
    }
}
