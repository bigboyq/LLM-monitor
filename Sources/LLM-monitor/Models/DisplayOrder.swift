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
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { (id($0), $0) })
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
