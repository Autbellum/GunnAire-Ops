import Foundation
import LoadSightKit

public struct ChangeQuantityInput: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var name = ""
    public var unit = ""
    public var original = ""
    public var originalSource = ""
    public var proposed = ""
    public var proposedSource = ""
    public init() {}
}

/// Text stays intact while typing. Invalid numbers never silently become zero or unknown.
public struct ChangeOrderFormState: Equatable, Sendable {
    public var draft = ChangeOrderDraft(number: "", originalScope: "", proposedScope: "")
    public var author = ""
    public var values: [String: String] = [:]
    public var sources: [String: String] = [:]
    public var quantities: [ChangeQuantityInput] = []
    public init() {}
    public init(draft: ChangeOrderDraft) {
        self.draft = draft
        for cost in draft.costs { values[cost.category.rawValue] = cost.delta.amount.map(String.init(describing:)) ?? ""; sources[cost.category.rawValue] = cost.delta.source }
        for (key, amount) in [("Markup percentage", draft.markupPercent), ("Tax delta", draft.tax), ("Bond delta", draft.bond)] {
            values[key] = amount.amount.map(String.init(describing:)) ?? ""; sources[key] = amount.source
        }
        quantities = draft.quantities.map { value in
            var row = ChangeQuantityInput(); row.name = value.name; row.unit = value.unit
            row.original = value.original.amount.map(String.init(describing:)) ?? ""; row.originalSource = value.original.source
            row.proposed = value.proposed.amount.map(String.init(describing:)) ?? ""; row.proposedSource = value.proposed.source
            return row
        }
    }
    public static func amount(_ text: String, source: String, label: String) throws -> ChangeAmount {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .init(source: source) }
        guard let value = Double(cleaned), value.isFinite else { throw LoadSightError.invalid("\(label): enter a finite number without currency symbols or grouping commas, or leave blank for unknown.") }
        let amount = ChangeAmount(amount: value, source: source)
        do { try amount.validate() } catch { throw LoadSightError.invalid("\(label): record a source for the supplied value, including zero.") }
        return amount
    }
    public func resolvedDraft() throws -> ChangeOrderDraft {
        var result = draft
        func amount(_ key: String) throws -> ChangeAmount { try Self.amount(values[key] ?? "", source: sources[key] ?? "", label: key) }
        result.costs = try ChangeCostCategory.allCases.map { .init(category: $0, delta: try amount($0.rawValue)) }
        result.markupPercent = try amount("Markup percentage"); result.tax = try amount("Tax delta"); result.bond = try amount("Bond delta")
        result.quantities = try quantities.map {
            .init(name: $0.name, unit: $0.unit,
                  original: try Self.amount($0.original, source: $0.originalSource, label: "\($0.name) original quantity"),
                  proposed: try Self.amount($0.proposed, source: $0.proposedSource, label: "\($0.name) proposed quantity"))
        }
        _ = try result.review()
        return result
    }
}
