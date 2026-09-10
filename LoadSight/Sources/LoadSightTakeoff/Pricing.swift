import Foundation
import LoadSightCore

public struct LineCost: Codable, Sendable {
    public let id: String
    public let material: Double
    public let labor: Double
    public let subcontract: Double
    public let other: Double
    public var total: Double { material + labor + subcontract + other }
}

public struct BidReview: Codable, Sendable {
    public let includedCount: Int
    public let pricedCount: Int
    public let knownDirectCost: Double
    public let estimatedCost: Double?
    /// Deliberately unavailable until all review gates pass.
    public let releasableSellingPrice: Double?
    public let blockers: [String]
    public let lines: [LineCost]
    public var ready: Bool { blockers.isEmpty }
}

public enum EstimatePricing {
    public static func line(_ item: [String: JSONValue], laborRate: Double?) throws -> LineCost? {
        guard ["Base", "Allowance"].contains(item["scope"]?.string ?? "") else { return nil }
        guard let quantity = item["quantity"]?.number, let material = item["materialUnit"]?.number,
              let hours = item["laborHoursUnit"]?.number, let subcontract = item["subcontractUnit"]?.number,
              let other = item["otherUnit"]?.number, let waste = item["wastePct"]?.number, let laborRate else { return nil }
        try nonnegative(quantity, material, hours, subcontract, other, waste, laborRate)
        let result = LineCost(id: item["id"]?.string ?? "", material: quantity * material * (1 + waste / 100),
                              labor: quantity * hours * laborRate, subcontract: quantity * subcontract, other: quantity * other)
        try require(result.total.isFinite, "Cost overflow for \(result.id).")
        return result
    }
    public static func review(_ project: ProjectDocument) throws -> BidReview {
        try project.validate()
        try project.validateMarkupQuantities()
        let root = project.root, inputs = root["inputs"]
        let included = project.items.filter { ["Base", "Allowance"].contains($0["scope"]?.string ?? "") }
        let lines = try included.compactMap { try line($0, laborRate: inputs["laborRate"].number) }
        var blockers: [String] = []
        if root["sheets"].array?.isEmpty != false { blockers.append("No drawing/source register.") }
        if included.isEmpty { blockers.append("No included estimate items.") }
        let holds = project.items.filter { $0["scope"]?.string == "Hold" }
        if !holds.isEmpty { blockers.append("\(holds.count) scope or procurement hold rows.") }
        let openRFIs = (root["rfis"].array ?? []).filter {
            $0["status"].string != "Resolved" || !hasText($0["response"]) || !hasText($0["resolvedBy"]) || !hasText($0["resolvedDate"])
        }
        if !openRFIs.isEmpty { blockers.append("\(openRFIs.count) unanswered or undocumented RFIs.") }
        let qa = root["qa"].array ?? []
        let required = (1...12).map { String(format: "QA-%02d", $0) }
        if required.contains(where: { id in !qa.contains { $0["id"].string == id } }) { blockers.append("Required QA gate missing.") }
        let incomplete = qa.filter { $0["status"].string != "Complete" || !hasText($0["reviewer"]) || !hasText($0["date"]) }
        if !incomplete.isEmpty { blockers.append("\(incomplete.count) QA gates require completion, reviewer and date.") }
        let stale = try qa.filter { gate in
            guard gate["status"].string == "Complete" else { return false }
            return try !project.isQACurrent(gate)
        }
        if !stale.isEmpty { blockers.append("\(stale.count) QA reviews refer to an earlier project state.") }
        if included.count != lines.count { blockers.append("\(included.count - lines.count) included rows lack deliberate quantity or cost inputs.") }
        for item in included {
            if let mapping = try CatalogMaterialMapping.recorded(in: item), !mapping.matches(item) {
                blockers.append("Catalog material mapping for \(item["id"]!.string!) is stale; review the changed item or cost.")
            }
        }
        let accepted = ["Verified", "Field-verified", "Cross-checked", "Scope-defined", "Approved allowance"]
        let uncertain = included.filter { !accepted.contains($0["quantityStatus"]?.string ?? "") || !hasText($0["source"] ?? .null) || !hasText($0["unit"] ?? .null) }
        if !uncertain.isEmpty { blockers.append("\(uncertain.count) included rows lack an approved quantity basis, unit or source.") }
        if included.contains(where: { !project.isItemReviewCurrent($0) }) { blockers.append("A quantity review is stale; review the changed item evidence.") }
        if included.contains(where: { !hasText($0["priceSource"] ?? .null) }) { blockers.append("Included rows lack price or labor basis references.") }
        if included.contains(where: { $0["scope"]?.string == "Allowance" && (!hasText($0["allowanceNote"] ?? .null) || $0["quantityStatus"]?.string != "Approved allowance") }) {
            blockers.append("An allowance lacks an approved written basis.")
        }
        let completeInputs = ["laborRate", "markupPct", "taxAllowance", "jobCosts", "contingency"].allSatisfy { inputs[$0].number != nil }
        if !completeInputs { blockers.append("Project pricing inputs are incomplete.") }
        if !hasText(inputs["proposalTerms"]) { blockers.append("Commercial terms have not been entered and approved.") }
        if !hasText(inputs["customer"]) { blockers.append("Proposal customer has not been entered.") }
        if !hasText(root["reviewer"]) { blockers.append("Responsible estimator name missing.") }
        let subtotal = lines.reduce(0) { $0 + $1.total }
        try require(subtotal.isFinite, "Estimate subtotal overflow.")
        var estimatedCost: Double?
        if completeInputs && lines.count == included.count && !included.isEmpty {
            estimatedCost = subtotal + inputs["taxAllowance"].number! + inputs["jobCosts"].number! + inputs["contingency"].number!
            try require(estimatedCost!.isFinite, "Estimate cost overflow.")
        }
        var sellingPrice: Double?
        if blockers.isEmpty, let cost = estimatedCost {
            sellingPrice = cost * (1 + inputs["markupPct"].number! / 100)
            try require(sellingPrice!.isFinite, "Selling price overflow.")
        }
        return .init(includedCount: included.count, pricedCount: lines.count, knownDirectCost: subtotal,
                     estimatedCost: estimatedCost, releasableSellingPrice: sellingPrice, blockers: blockers, lines: lines)
    }
    private static func hasText(_ value: JSONValue) -> Bool {
        !(value.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum TakeoffExport {
    public static func csv(_ project: ProjectDocument) -> String {
        let fields = ["id", "category", "description", "lifecycle", "quantity", "unit", "scope", "quantityStatus", "source", "spec", "rfi", "notes"]
        let rows = project.items.map { item in fields.map { key in
            let value = item[key] ?? .null
            return cell(value.string ?? value.number.map { String($0) } ?? "")
        }.joined(separator: ",") }
        return ([fields.map(cell).joined(separator: ",")] + rows).joined(separator: "\r\n") + "\r\n"
    }
    private static func cell(_ value: String) -> String {
        // Spreadsheet formula injection protection applies to externally supplied source text.
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let guarded = first.map { "=+-@".contains($0) } == true ? "'" + value : value
        return "\"" + guarded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
