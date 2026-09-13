import Foundation

public enum ChangeOrderWordDocument {
    public static func docx(_ project: ProjectDocument, changeOrderID: String, generatedAt: Date = Date()) throws -> Data {
        try require(generatedAt.timeIntervalSince1970.isFinite, "Change-order generation time must be finite.")
        try project.validatePortableProject()
        guard let record = try project.changeOrders().first(where: { $0.id == changeOrderID }) else { throw LoadSightError.invalid("Select an existing change order to export.") }
        let draft = record.draft, review = try draft.review()
        let history = try project.changeOrderHistory().filter { $0.changeOrderID == record.id }
        var blocks: [WordBlock] = []
        func add(_ text: String, _ style: String = "Normal") { blocks.append(.paragraph(text, style)) }
        func text(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Not recorded" : value }
        func field(_ label: String, _ value: String) { add(label + ": " + text(value), "Metadata") }
        func number(_ value: Double?) -> String { value.map { String($0) } ?? "Unknown" }
        func money(_ value: Double?) -> String {
            value.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "Unknown"
        }
        add("Change order draft", "Title"); add(record.project, "Subtitle")
        add("Review copy awaiting approval", "Emphasis")
        field("CO number", draft.number); field("Date", draft.date); field("Customer / GC", draft.customer)
        field("Recorded by", record.author); field("Record created", record.createdAt)
        if let latest = history.last {
            field("Latest revision author", latest.author); field("Latest revision date", latest.recordedAt)
            field("Latest revision reason", latest.reason)
        }
        add("Original contract scope", "Heading1"); add(text(draft.originalScope))
        add("Proposed revised scope", "Heading1"); add(text(draft.proposedScope))
        add("Basis for proposed change", "Heading1")
        field("Supplied entitlement classification", draft.entitlement?.rawValue ?? "")
        field("Entitlement basis and source", draft.entitlementBasis)
        field("Drawing / specification revision", draft.drawingRevision)
        field("Originating audit reference", draft.auditReference)
        if draft.rfiIDs.isEmpty { field("Originating RFI", "") }
        for id in draft.rfiIDs {
            let rfi = project.root["rfis"].array?.first { $0["id"].string == id }
            field("Originating RFI", id)
            if let rfi {
                field("Current RFI subject", rfi["title"].string ?? "")
                field("Current RFI status", rfi["status"].string ?? "")
                field("Current RFI source", rfi["source"].string ?? "")
            } else { add("The linked RFI is no longer present in the current project.", "Small") }
        }
        add("Entitlement classification is the recorded basis for the request, not a determination of contractual rights. An RFI response does not authorize this change.", "Small")
        add("Time impact exclusions and approval", "Heading1")
        field("Time impact", draft.timeImpact); field("Exclusions", draft.exclusions); field("Required approval language", draft.approvalLanguage)
        add("This draft does not authorize work or change the base estimate. Approval has not been recorded by this workflow.", "Small")
        if !review.unknownFields.isEmpty { add("Information still required", "Heading1"); add(review.unknownFields.joined(separator: "; ")) }
        add("Record basis", "Heading1")
        field("Record identity", record.id); field("Exported", generatedAt.ISO8601Format())
        add("Project review fingerprint: " + (try project.qaFingerprint()), "Small")
        add("This copy reflects the saved record and current linked-RFI metadata at export. Editing Word does not update the project, authorize work or record approval. Supporting files are not embedded.", "Small")
        add("Quantities and cost impact", "Heading1")
        if draft.quantities.isEmpty { add("Quantity ledger: Unknown. No original/proposed quantities have been recorded.") }
        else {
            blocks.append(.table(headers: ["Quantity and unit", "Original", "Proposed", "Delta"], rows: draft.quantities.map { [$0.name + " (" + $0.unit + ")", number($0.original.amount), number($0.proposed.amount), number($0.delta)] }, widths: [3600,2160,2160,2160]))
            for (index, q) in draft.quantities.enumerated() {
                add("Quantity \(index + 1) · " + q.name, "Emphasis")
                field("Original source", q.original.source); field("Proposed source", q.proposed.source)
            }
        }
        add("Quoted cost deltas in USD", "Heading1")
        blocks.append(.table(headers: ["Cost category", "Delta USD", "Source"], rows: draft.costs.map { [$0.category.rawValue.capitalized, money($0.delta.amount), text($0.delta.source)] }, widths: [2160,1800,6120]))
        add("Positive costs add to the change; negative costs are credits. Quoted cost deltas are independent of quantity deltas. Unknown amounts are not zero.", "Small")
        add("Markup tax and bond", "Heading1")
        field("Markup percentage", draft.markupPercent.amount.map { number($0) + "%" } ?? "Unknown")
        field("Markup source", draft.markupPercent.source)
        field("Markup basis", draft.markupBasis.map { $0 == .signedNetCosts ? "Signed net costs, including credits" : "Positive category deltas only" } ?? "Unknown")
        field("Tax delta USD", money(draft.tax.amount)); field("Tax source", draft.tax.source)
        field("Bond delta USD", money(draft.bond.amount)); field("Bond source", draft.bond.source)
        add("Draft cost summary", "Heading1")
        blocks.append(.table(headers: ["Component", "USD"], rows: [
            ["Known cost entries only", money(review.knownCostDelta)],
            ["Complete cost delta", money(review.costDelta)],
            ["Markup delta", money(review.markupDelta)],
            ["Draft total delta", review.totalDelta == nil ? "Unknown — withheld" : money(review.totalDelta)]
        ], widths: [7560,2520]))
        add("Total = complete cost delta + markup delta + tax delta + bond delta. Displayed amounts are rounded to cents; intermediate arithmetic is not rounded. Known entries alone are not a complete cost subtotal. A calculated total does not establish scope completeness or approval.", "Small")
        if !history.isEmpty {
            add("Recorded revisions", "HistoryHeading")
            add("Changed fields are shown below. Complete before/after snapshots remain in the project. Recorded authorship is not authenticated approval.", "Small")
            for (index, event) in history.enumerated() {
                add("Revision \(index + 1)", "Heading1")
                field("Recorded by", event.author); field("Recorded at", event.recordedAt); field("Reason", event.reason)
                let before = try event.record(before: true).draft, after = try event.record(before: false).draft
                add("Before total USD: " + money(try before.review().totalDelta) + "    After total USD: " + money(try after.review().totalDelta), "Metadata")
                if before == after { add("No recorded draft fields changed.") }
                for (label, a, b) in [("CO number", before.number, after.number), ("Date", before.date, after.date), ("Customer / GC", before.customer, after.customer), ("Entitlement classification", before.entitlement?.rawValue ?? "", after.entitlement?.rawValue ?? ""), ("Entitlement basis", before.entitlementBasis, after.entitlementBasis), ("Original scope", before.originalScope, after.originalScope), ("Proposed scope", before.proposedScope, after.proposedScope), ("Drawing revision", before.drawingRevision, after.drawingRevision), ("RFI identities", before.rfiIDs.joined(separator: ", "), after.rfiIDs.joined(separator: ", ")), ("Audit reference", before.auditReference, after.auditReference), ("Markup basis", before.markupBasis.map { $0 == .signedNetCosts ? "Signed net costs" : "Positive category deltas only" } ?? "", after.markupBasis.map { $0 == .signedNetCosts ? "Signed net costs" : "Positive category deltas only" } ?? ""), ("Time impact", before.timeImpact, after.timeImpact), ("Exclusions", before.exclusions, after.exclusions), ("Approval language", before.approvalLanguage, after.approvalLanguage)] where a != b {
                    add(label, "Emphasis"); field("Before", a); field("After", b)
                }
                for (label, a, b) in [("Markup percentage", before.markupPercent, after.markupPercent), ("Tax delta USD", before.tax, after.tax), ("Bond delta USD", before.bond, after.bond)] where a != b {
                    add(label, "Emphasis")
                    field("Before", number(a.amount) + " · Source: " + text(a.source)); field("After", number(b.amount) + " · Source: " + text(b.source))
                }
                if before.costs != after.costs {
                    for (label, costs) in [("Before cost deltas", before.costs), ("After cost deltas", after.costs)] {
                        add(label, "Heading2")
                        blocks.append(.table(headers: ["Category", "USD", "Source"], rows: costs.map { [$0.category.rawValue.capitalized, money($0.delta.amount), text($0.delta.source)] }, widths: [2160,1800,6120]))
                    }
                }
                if before.quantities != after.quantities {
                    for (label, quantities) in [("Before quantities", before.quantities), ("After quantities", after.quantities)] {
                        add(label, "Heading2")
                        if quantities.isEmpty { add("No quantity ledger recorded.") }
                        for q in quantities {
                            add(q.name + " (" + q.unit + ")", "Emphasis")
                            field("Original", number(q.original.amount) + " · Source: " + text(q.original.source))
                            field("Proposed", number(q.proposed.amount) + " · Source: " + text(q.proposed.source))
                            field("Delta", number(q.delta))
                        }
                    }
                }
            }
        }
        return try WordPackage.encodeBlocks(blocks)
    }
}
