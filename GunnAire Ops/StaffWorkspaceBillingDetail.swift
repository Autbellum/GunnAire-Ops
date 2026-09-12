import Foundation

/// Customer-facing facts from an already authorized staff projection. Never
/// reconstruct owner Invoice/Item models, use current catalog prices, or turn
/// displayed totals/status into publication or collection authority.
enum StaffWorkspaceBillingDetail {
    struct Fact: Identifiable, Equatable {
        let id: String
        let label: String
        let value: String
    }
    struct Link: Identifiable, Equatable {
        var id: String { route.kind + ":" + route.id }
        let route: StaffWorkspaceRecordRoute
        let label: String
        let title: String
    }
    struct Line: Identifiable, Equatable {
        let id: String
        let name: String
        let description: String?
        let quantity: Double
        let unitPrice: Double
        let amount: Double
        let taxable: Bool
        let equipment: String?
        let equipmentLink: Link?
        let catalogLink: Link?
        let parts: [Part]
        let members: [Line]
    }
    struct Part: Identifiable, Equatable {
        let id: String
        let name: String
        let quantity: Double
        let link: Link?
    }
    struct Document: Equatable {
        let title: String
        let status: String
        let summary: [Fact]
        let lines: [Line]
        let linesNotRecorded: Bool
        let legacySummary: String?
        let totals: [Fact]
        let taxNotice: String
        let connection: [Fact]
        let notes: [Fact]
        let context: [Link]
        let files: [Link]
        let messages: [Link]
        let payments: [Link]
    }

    static func load(hosted: StaffWorkspaceOperationalHostedStore, route: StaffWorkspaceRecordRoute) throws -> Document {
        try StaffWorkspaceOperationalPresentation.requireHosted(hosted)
        let records = try hosted.fetch()
        // A locally changed projection is not a new authorized snapshot.
        let order: (StaffWorkspaceOperationalImportRecord, StaffWorkspaceOperationalImportRecord) -> Bool = {
            ($0.kind, $0.id) < ($1.kind, $1.id)
        }
        guard records == hosted.plan.records.sorted(by: order) else { throw StaffReplicaDeliveryError.changed }
        return try make(route: route, records: records)
    }

    /// Pure rendering seam; callers must establish the live workspace authority.
    static func make(route: StaffWorkspaceRecordRoute, records: [StaffWorkspaceOperationalImportRecord]) throws -> Document {
        guard ["invoice", "estimate"].contains(route.kind), CloudKitStaffSetupPolicy.canonicalID(route.id),
              Set(records.map { $0.kind + ":" + $0.id }).count == records.count,
              let record = records.first(where: { $0.kind == route.kind && $0.id == route.id }),
              case .billing(let document) = record.body,
              document.kind == route.kind, document.id.uuidString.lowercased() == route.id,
              Set(document.fields.keys).isDisjoint(with: document.unavailableFields.keys) else {
            throw StaffReplicaDeliveryError.invalid
        }
        let fields = document.fields
        let index = Dictionary(uniqueKeysWithValues: records.map { ($0.kind + ":" + $0.id, $0) })
        func link(kind: String, id: UUID, label: String) -> Link? {
            let target = StaffWorkspaceRecordRoute(kind: kind, id: id.uuidString.lowercased())
            guard let value = index[kind + ":" + target.id] else { return nil }
            return .init(route: target, label: label, title: Self.title(value))
        }
        func direct(_ field: String, kind: String, label: String) -> Link? {
            guard !record.unavailableLinks.contains(field), case .identifier(let id) = fields[field] else { return nil }
            return link(kind: kind, id: id, label: label)
        }
        func related(kind: String, field: String, label: String) -> [Link] {
            records.filter { candidate in
                candidate.kind == kind && !candidate.unavailableLinks.contains(field) &&
                    available(candidate)[field] == .identifier(document.id)
            }.sorted { $0.id < $1.id }.compactMap { candidate in
                UUID(uuidString: candidate.id).flatMap { link(kind: kind, id: $0, label: label) }
            }
        }
        func fact(_ key: String, _ label: String) -> Fact? {
            guard let value = fields[key], value != .null else { return nil }
            switch value {
            case .text(let text):
                guard let value = normalized(text) else { return nil }
                return .init(id: key, label: label, value: value)
            case .date(let date):
                return .init(id: key, label: label, value: date.formatted(date: .abbreviated, time: .omitted))
            default: return nil // Never surface UUIDs, raw signatures, JSON or protocol fields.
            }
        }
        // Legacy non-itemized documents may contain historical fractional cents.
        // Show the exact saved value with review guidance, never silently round
        // or reject the entire document as if this were a new QBO write.
        let legacy: Bool
        if case .notRecorded = document.catalog { legacy = true } else { legacy = false }
        let total = try legacy ? observedMoney(fields["amount"]) : money(fields["amount"])
        let tax = try legacy ? observedMoney(fields["salesTaxAmount"]) : money(fields["salesTaxAmount"])
        guard total >= tax else { throw StaffReplicaDeliveryError.invalid }
        var totals: [Fact] = []
        var lines: [Line] = []
        let missing: Bool
        switch document.catalog {
        case .notRecorded: missing = true
        case .saved(let catalog):
            missing = false
            func sold(_ row: StaffWorkspaceBillingProjection.Line, path: String, depth: Int = 0) throws -> Line {
                guard depth <= 8, row.quantity.isFinite, row.quantity > 0,
                      row.unitPrice.isFinite, row.unitPrice >= 0, row.extendedAmount.isFinite, row.extendedAmount >= 0,
                      !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw StaffReplicaDeliveryError.invalid
                }
                return .init(id: path, name: row.name, description: normalized(row.description),
                    quantity: row.quantity, unitPrice: row.unitPrice, amount: row.extendedAmount, taxable: row.isTaxable,
                    equipment: row.servicedEquipment.map { [$0.name, $0.serialNumber].compactMap(normalized).joined(separator: " · ") },
                    equipmentLink: row.servicedEquipment.flatMap { link(kind: "equipment", id: $0.equipmentID, label: "System") },
                    catalogLink: link(kind: "item", id: row.catalogItemID, label: "Current catalog item"),
                    parts: (row.assembly?.components ?? []).enumerated().map {
                        .init(id: path + ".part." + String($0.offset), name: $0.element.name, quantity: $0.element.quantity,
                              link: link(kind: "item", id: $0.element.itemID, label: "Current catalog part"))
                    },
                    members: try (row.bundle?.members ?? []).enumerated().map {
                        try sold($0.element.line, path: path + "." + String($0.offset), depth: depth + 1)
                    })
            }
            lines = try catalog.lines.enumerated().map { try sold($0.element, path: String($0.offset)) }
            let gross = try catalog.lines.reduce(Decimal.zero) { try $0 + money(.number($1.extendedAmount)) }
            let discount: Decimal
            if let saved = catalog.discount {
                guard let amount = saved.amount(for: NSDecimalNumber(decimal: gross).doubleValue) else {
                    throw StaffReplicaDeliveryError.invalid
                }
                discount = try money(.number(amount))
            } else { discount = 0 }
            guard gross - discount + tax == total else { throw StaffReplicaDeliveryError.invalid }
            totals.append(.init(id: "gross", label: "Line subtotal", value: currency(gross)))
            if catalog.discount != nil {
                totals.append(.init(id: "discount", label: "Approved discount", value: "−" + currency(discount)))
            }
        }
        totals.append(.init(id: "tax", label: "Saved sales tax", value: currency(tax)))
        totals.append(.init(id: "total", label: "Saved total", value: currency(total)))
        // Never infer balance from visible payments or a paid/unpaid status.
        if fields["quickBooksBalanceDue"] != nil, fields["quickBooksBalanceDue"] != .null {
            let balance = try observedMoney(fields["quickBooksBalanceDue"])
            totals.append(.init(id: "balance", label: "Last QuickBooks balance", value: currency(balance)))
        }
        let taxStatus = text(fields["taxCalculationStatusRawValue"]).flatMap(BillingTaxCalculationStatus.init(rawValue:))
        var taxNotice: String
        switch taxStatus {
        case .calculatedByQuickBooks: taxNotice = "Saved QuickBooks tax calculation. Amounts shown are not a live payment balance."
        case .notApplicable: taxNotice = "Saved as tax not applicable. Amounts shown are not a live payment balance."
        case .pendingQuickBooks: taxNotice = "Sales tax is awaiting QuickBooks. This saved total is not ready for customer approval or collection."
        case .needsAttention: taxNotice = "Sales tax needs office review before customer approval or collection."
        case nil: taxNotice = "Tax calculation has not been verified in this shared record. Ask the office before approval or collection."
        }
        if legacy && ((try? money(fields["amount"])) == nil || (try? money(fields["salesTaxAmount"])) == nil) {
            taxNotice += " The legacy record includes fractional cents; the original values are shown for office review."
        }
        let connection: [Fact] = [fact("quickBooksLastSyncedAt", "Last QuickBooks update"),
                                  fact("taxCalculatedAt", "Tax calculated")].compactMap { $0 }
        let workType = text(fields["workTypeRaw"]).flatMap(InvoiceWorkType.init(rawValue:))
        let title = route.kind == "invoice" ? (workType?.documentTitle ?? "Invoice") : "Estimate"
        let documentField = route.kind == "invoice" ? "invoiceID" : "estimateID"
        return .init(title: title, status: text(fields["status"])?.capitalized ?? "Status unavailable",
            summary: [fact("createdAt", "Created"), fact("dueDate", "Due"), fact("siteAddress", "Service address"),
                      fact("projectMilestoneTitle", "Project milestone")].compactMap { $0 },
            lines: lines, linesNotRecorded: missing, legacySummary: text(fields["lineItemSummary"]),
            totals: totals, taxNotice: taxNotice, connection: connection,
            notes: [fact("notes", "Notes"), fact("completionNotes", "Completed work"),
                    fact("customerSignatureName", "Customer sign-off"), fact("customerSignedAt", "Signed"),
                    fact("customerApprovedByName", "Approved by"), fact("customerApprovedAt", "Approved")].compactMap { $0 },
            context: [direct("customer", kind: "customer", label: "Customer"),
                      direct("serviceCallID", kind: "job", label: "Job"),
                      direct("serviceLocationID", kind: "location", label: "Service location")].compactMap { $0 },
            files: related(kind: "attachment", field: documentField, label: "File"),
            messages: related(kind: "communication", field: documentField, label: "Message record"),
            payments: route.kind == "invoice" ? related(kind: "payment", field: "invoice", label: "Payment record") : [])
    }

    static func available(_ record: StaffWorkspaceOperationalImportRecord) -> [String: StaffWorkspaceValue] {
        switch record.body {
        case .billing(let document): return document.fields
        case .operational(let partition): return partition.fields
        }
    }
    private static func title(_ record: StaffWorkspaceOperationalImportRecord) -> String {
        let fields = available(record)
        for key in ["name", "displayName", "fileName", "subject", "title"] {
            if let value = text(fields[key]) { return value }
        }
        if record.kind == "payment", let amount = try? money(fields["amount"]) {
            return [currency(amount), text(fields["status"])?.capitalized].compactMap { $0 }.joined(separator: " · ")
        }
        return StaffWorkspaceOperationalDetail.titleCasedKind(record.kind)
    }
    nonisolated private static func normalized(_ value: String?) -> String? {
        guard let result = value?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else { return nil }
        return result
    }
    private static func text(_ value: StaffWorkspaceValue?) -> String? {
        guard case .text(let text) = value else { return nil }; return normalized(text)
    }
    private static func money(_ value: StaffWorkspaceValue?) throws -> Decimal {
        guard case .number(let number) = value, number >= 0,
              let decimal = QuickBooksSalesLineContract.decimal(number, places: 2) else {
            throw StaffReplicaDeliveryError.invalid
        }
        return decimal
    }
    private static func observedMoney(_ value: StaffWorkspaceValue?) throws -> Decimal {
        guard case .number(let number) = value, number.isFinite, number >= 0,
              let decimal = Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX")), !decimal.isNaN else {
            throw StaffReplicaDeliveryError.invalid
        }
        return decimal
    }
    static func observedAmountLabel(_ value: StaffWorkspaceValue?) -> String? {
        (try? observedMoney(value)).map { currency($0) }
    }
    private static func currency(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2...16)))
    }
}
