import Foundation

public enum ChangeEntitlement: String, Codable, CaseIterable, Sendable {
    case ownerChange = "Owner change", hiddenCondition = "Hidden condition", documentConflict = "Document conflict"
    case codeInterpretation = "Code interpretation", designRevision = "Design revision", fieldCondition = "Field condition", scheduleAcceleration = "Schedule acceleration"
}
public enum ChangeCostCategory: String, Codable, CaseIterable, Sendable { case labor, material, equipment, subcontractor }
public enum ChangeMarkupBasis: String, Codable, Sendable { case signedNetCosts, positiveAdditionsOnly }

/// Nil means unknown. A supplied zero is evidence of no cost, and still needs its source.
public struct ChangeAmount: Codable, Equatable, Sendable {
    public var amount: Double?
    public var source: String
    public init(amount: Double? = nil, source: String = "") { self.amount = amount; self.source = source }
    public func validate() throws {
        if let amount { try require(amount.isFinite && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Known change amounts require a finite value and source, including zero.") }
    }
}
public struct ChangeCost: Codable, Equatable, Sendable {
    public var category: ChangeCostCategory
    public var delta: ChangeAmount
    public init(category: ChangeCostCategory, delta: ChangeAmount) { self.category = category; self.delta = delta }
}
public struct ChangeQuantity: Codable, Equatable, Sendable {
    public var name: String
    public var unit: String
    public var original: ChangeAmount
    public var proposed: ChangeAmount
    public init(name: String, unit: String, original: ChangeAmount, proposed: ChangeAmount) {
        self.name = name; self.unit = unit; self.original = original; self.proposed = proposed
    }
    public var delta: Double? { guard let a = original.amount, let b = proposed.amount else { return nil }; return b - a }
}
public struct ChangeOrderDraft: Codable, Equatable, Sendable {
    public var number: String
    public var date: String
    public var customer: String
    public var entitlement: ChangeEntitlement?
    public var entitlementBasis: String
    public var originalScope: String
    public var proposedScope: String
    public var drawingRevision: String
    public var rfiIDs: [String]
    public var auditReference: String
    public var quantities: [ChangeQuantity]
    public var costs: [ChangeCost]
    /// Percentage on the explicitly selected basis, not a margin on selling price.
    public var markupPercent: ChangeAmount
    public var markupBasis: ChangeMarkupBasis?
    public var tax: ChangeAmount
    public var bond: ChangeAmount
    public var timeImpact: String
    public var exclusions: String
    public var approvalLanguage: String
    public init(number: String, originalScope: String, proposedScope: String) {
        self.number = number; self.originalScope = originalScope; self.proposedScope = proposedScope
        date = ""; customer = ""; entitlement = nil; entitlementBasis = ""; drawingRevision = ""; rfiIDs = []; auditReference = ""; quantities = []
        costs = ChangeCostCategory.allCases.map { .init(category: $0, delta: .init()) }
        markupPercent = .init(); markupBasis = nil; tax = .init(); bond = .init(); timeImpact = ""; exclusions = ""; approvalLanguage = ""
    }
    public func review() throws -> ChangeOrderReview {
        for value in [number, originalScope, proposedScope] { try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Change number and original/proposed scope are required.") }
        try RFICommunication(date: date).validate()
        try require(costs.count == 4 && Set(costs.map(\.category)).count == 4, "Record each of labor, material, equipment and subcontractor exactly once; use unknown amounts where needed.")
        try require(Set(rfiIDs).count == rfiIDs.count && rfiIDs.allSatisfy { !$0.isEmpty }, "Change RFI links must be unique, nonempty identities.")
        for cost in costs { try cost.delta.validate() }
        for value in [markupPercent, tax, bond] { try value.validate() }
        if let percent = markupPercent.amount { try nonnegative(percent) }
        var unknown: [String] = []
        for (label, value) in [("Date", date), ("Customer / GC", customer), ("Entitlement basis", entitlementBasis), ("Drawing / specification revision", drawingRevision), ("Time impact", timeImpact), ("Exclusions", exclusions), ("Approval language", approvalLanguage)] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { unknown.append(label) }
        if entitlement == nil { unknown.append("Entitlement classification") }
        if rfiIDs.isEmpty && auditReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { unknown.append("Originating RFI / audit reference") }
        if quantities.isEmpty { unknown.append("Quantity ledger") }
        for (index, quantity) in quantities.enumerated() {
            try require(!quantity.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !quantity.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Quantity name and unit are required.")
            try quantity.original.validate(); try quantity.proposed.validate()
            for amount in [quantity.original.amount, quantity.proposed.amount].compactMap({ $0 }) { try nonnegative(amount) }
            if quantity.delta == nil { unknown.append("Quantity \(index + 1) original / proposed") }
        }
        var known = 0.0, positive = 0.0
        for cost in costs {
            if let value = cost.delta.amount { known += value; positive += max(0, value) }
            else { unknown.append("\(cost.category.rawValue) cost") }
        }
        try require(known.isFinite && positive.isFinite, "Change cost subtotal overflow.")
        let subtotal: Double? = costs.allSatisfy { $0.delta.amount != nil } ? known : nil
        if markupPercent.amount == nil { unknown.append("Markup percentage") }
        if markupBasis == nil { unknown.append("Markup basis") }
        if tax.amount == nil { unknown.append("Tax delta") }
        if bond.amount == nil { unknown.append("Bond delta") }
        var markup: Double?, total: Double?
        if let subtotal, let percent = markupPercent.amount, let basis = markupBasis {
            markup = (basis == .signedNetCosts ? subtotal : positive) * (percent / 100)
            try require(markup!.isFinite, "Change markup overflow.")
            if let tax = tax.amount, let bond = bond.amount {
                total = subtotal + markup! + tax + bond
                try require(total!.isFinite, "Change total overflow.")
            }
        }
        return .init(knownCostDelta: known, costDelta: subtotal, markupDelta: markup, totalDelta: total, quantityDeltas: quantities.map(\.delta), unknownFields: unknown)
    }
}
public struct ChangeOrderReview: Encodable, Sendable {
    public let currency = "USD"
    public let status = "Draft"
    public let knownCostDelta: Double
    public let costDelta: Double?
    public let markupDelta: Double?
    public let totalDelta: Double?
    public let quantityDeltas: [Double?]
    public let unknownFields: [String]
    public let limitations = "Draft cost arithmetic only. Quoted cost deltas are independent of quantity deltas. Unknown amounts withhold the total. A calculated total does not establish scope completeness, entitlement, approval or authorization to perform work."
}
public struct ChangeOrderRecord: Codable, Identifiable, Sendable {
    public let version: Int
    public let id: String
    public let project: String
    public let author: String
    public let createdAt: String
    public let status: String
    public let draft: ChangeOrderDraft
}
public extension ProjectDocument {
    func changeOrders() throws -> [ChangeOrderRecord] {
        guard root.object?["changeOrders"] != nil else { return [] }
        let records = try JSONDecoder().decode([ChangeOrderRecord].self, from: JSONEncoder().encode(root["changeOrders"]))
        try require(Set(records.map(\.id)).count == records.count, "Duplicate change-order IDs.")
        let numbers = records.map { $0.draft.number.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        try require(Set(numbers).count == numbers.count, "Duplicate change-order numbers.")
        for record in records { try record.validate() }
        return records
    }
    @discardableResult
    mutating func createChangeOrder(_ draft: ChangeOrderDraft, author: String) throws -> String {
        _ = try draft.review()
        let known = Set(root["rfis"].array!.compactMap { $0["id"].string })
        try require(draft.rfiIDs.allSatisfy { known.contains($0) }, "Change order must link existing RFIs.")
        let record = ChangeOrderRecord(version: 1, id: "CO-" + UUID().uuidString, project: name, author: author, createdAt: Date().ISO8601Format(), status: "Draft", draft: draft)
        let row = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(record))
        var object = root.object!, rows = root["changeOrders"].array ?? []
        rows.append(row); object["changeOrders"] = .array(rows)
        object["qa"] = .array(root["qa"].array!.map { entry in
            var gate = entry.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string(""); return .object(gate)
        })
        self = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(object)))
        return record.id
    }
}
