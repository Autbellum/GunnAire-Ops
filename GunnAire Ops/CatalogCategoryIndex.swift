import Foundation

/// References, not names or colon-splitting, determine ancestry. Bad branches
/// remain discoverable under "Category needs review", never guessed into a
/// category and never substituted as billable service items.
@MainActor
struct CatalogCategoryIndex {
    struct Category: Identifiable {
        let id: UUID
        let title: String
    }
    let categories: [Category]
    let ancestorsByItem: [UUID: [UUID]]
    let reviewItemIDs: Set<UUID>

    init(items: [Item], scope: QuickBooksChangeHistoryScope?) {
        let byID = Dictionary(grouping: items, by: \.id)
        let byReference = Dictionary(grouping: items.filter { $0.quickBooksID != nil }, by: { $0.quickBooksID! })
        var ancestors: [UUID: [UUID]] = [:], review = Set<UUID>(), categories: [Category] = []
        func path(_ item: Item) -> [Item]? {
            guard byID[item.id]?.count == 1 else { return nil }
            if item.catalogDetails?.parent == nil && item.itemType != .category {
                guard item.catalogDetails?.level == nil || item.catalogDetails?.level == 0 else { return nil }
                return []
            }
            guard let scope, CatalogBundlePolicy.scope(of: item) == scope else { return nil }
            var current = item, parents: [Item] = [], seen = Set([item.id])
            while let reference = current.catalogDetails?.parent {
                guard QuickBooksSalesLineContract.validReference(reference.value),
                      let matches = byReference[reference.value], matches.count == 1, let parent = matches.first,
                      parent.itemType == .category, parent.isAvailableForNewWork,
                      byID[parent.id]?.count == 1, CatalogBundlePolicy.scope(of: parent) == scope,
                      seen.insert(parent.id).inserted, parents.count < 4 else { return nil }
                parents.append(parent); current = parent
            }
            let ordered = parents.reversed()
            for (index, parent) in ordered.enumerated() {
                guard parent.catalogDetails?.level == nil || parent.catalogDetails?.level == index else { return nil }
            }
            guard item.catalogDetails?.level == nil || item.catalogDetails?.level == parents.count,
                  item.itemType != .category || parents.count < 4 else { return nil }
            return Array(ordered)
        }
        for item in items {
            guard let parents = path(item) else { review.insert(item.id); continue }
            ancestors[item.id] = parents.map(\.id)
            if item.itemType == .category {
                categories.append(.init(id: item.id, title: (parents + [item]).map(\.name).joined(separator: " › ")))
            }
        }
        self.categories = categories.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        ancestorsByItem = ancestors; reviewItemIDs = review
    }

    func matches(_ item: Item, category: UUID?) -> Bool {
        guard let category else { return true }
        return ancestorsByItem[item.id]?.contains(category) == true
    }

    func label(for item: Item) -> String? {
        if reviewItemIDs.contains(item.id) { return "Category needs review" }
        guard let last = ancestorsByItem[item.id]?.last else { return nil }
        return categories.first { $0.id == last }?.title
    }
}
