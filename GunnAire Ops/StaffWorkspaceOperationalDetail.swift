import Foundation

/// Pure presentation helper for staff HostedWorkspace projection rows.
/// Decodes available/unavailable field partitions only — never reconstructs
/// owner models and never promotes `structuredFieldsJSON` extras to scalars.
enum StaffWorkspaceOperationalDetail {
    struct Summary: Equatable {
        let title: String
        let subtitle: String
        let kindBadge: String
        let badges: [String]
        let hasRestrictedFields: Bool
    }

    struct FieldRow: Identifiable, Equatable {
        var id: String { key }
        let key: String
        let label: String
        let displayValue: String
        let isRestricted: Bool
    }

    struct RecordDetail: Equatable {
        let kind: String
        let recordID: String
        let revision: Int
        let bodyKind: String
        let summary: Summary
        let fields: [FieldRow]
    }

    /// Kind-aware preference keys for title then subtitle (first present non-empty).
    /// Slash-separated tokens are alternate keys tried in order.
    static func preferenceKeys(for kind: String) -> [String] {
        switch kind {
        case "customer", "location":
            return ["name", "displayName", "companyName", "address", "city"]
        case "job", "task", "request", "activity", "milestone", "alert", "taskEvent":
            return ["title", "number", "status", "scheduledDate", "date"]
        case "estimate", "invoice":
            return ["number", "status", "total", "amount", "balanceDue"]
        case "payment":
            return ["amount", "status", "method", "paidAt", "date"]
        case "technician", "user":
            return ["name", "displayName", "email", "role"]
        case "equipment":
            return ["name", "model", "serialNumber", "manufacturer"]
        case "formTemplate", "formResponse":
            return ["title", "name", "status"]
        case "attachment":
            return ["displayName", "fileName", "contentType"]
        case "vendor", "purchaseOrder":
            return ["name", "number", "status"]
        case "vehicle", "vehicleEvent", "movement":
            return ["name", "label", "status"]
        case "expense":
            return ["title", "amount", "status"]
        case "communication":
            return ["subject", "title", "status"]
        case "item", "agreement":
            return ["name", "sku", "title"]
        default:
            return []
        }
    }

    static func summary(for row: StaffWorkspaceOperationalProjectionRecord) -> Summary {
        summary(
            kind: row.kind,
            recordID: row.recordID,
            availableFieldsJSON: row.availableFieldsJSON,
            unavailableFieldsJSON: row.unavailableFieldsJSON
        )
    }

    static func detail(for row: StaffWorkspaceOperationalProjectionRecord) -> RecordDetail {
        detail(
            kind: row.kind,
            recordID: row.recordID,
            revision: row.revision,
            bodyKind: row.bodyKind,
            availableFieldsJSON: row.availableFieldsJSON,
            unavailableFieldsJSON: row.unavailableFieldsJSON
        )
    }

    static func summary(
        kind: String,
        recordID: String,
        availableFieldsJSON: String,
        unavailableFieldsJSON: String
    ) -> Summary {
        let available = decodeAvailable(availableFieldsJSON)
        let unavailable = decodeUnavailable(unavailableFieldsJSON)
        return makeSummary(kind: kind, recordID: recordID, available: available, unavailable: unavailable)
    }

    static func detail(
        kind: String,
        recordID: String,
        revision: Int,
        bodyKind: String,
        availableFieldsJSON: String,
        unavailableFieldsJSON: String
    ) -> RecordDetail {
        let available = decodeAvailable(availableFieldsJSON)
        let unavailable = decodeUnavailable(unavailableFieldsJSON)
        let summary = makeSummary(
            kind: kind, recordID: recordID, available: available, unavailable: unavailable)
        var rows: [FieldRow] = []

        for key in available.keys.sorted() {
            let currency = Self.currencyKeys.contains(key)
            let value = available[key]!
            rows.append(FieldRow(
                key: key,
                label: humanize(key),
                displayValue: format(value, currency: currency),
                isRestricted: false
            ))
        }

        for key in unavailable.keys.sorted() {
            // Restricted placeholders only — never fill from structured owner extras.
            rows.append(FieldRow(
                key: key,
                label: humanize(key),
                displayValue: "Restricted",
                isRestricted: true
            ))
        }

        return RecordDetail(
            kind: kind,
            recordID: recordID,
            revision: revision,
            bodyKind: bodyKind,
            summary: summary,
            fields: rows
        )
    }

    // MARK: - Decoding (fail-soft)

    static func decodeAvailable(_ json: String) -> [String: StaffWorkspaceValue] {
        guard let data = json.data(using: .utf8), !data.isEmpty else { return [:] }
        do {
            return try JSONDecoder().decode([String: StaffWorkspaceValue].self, from: data)
        } catch {
            return [:]
        }
    }

    static func decodeUnavailable(_ json: String)
    -> [String: StaffWorkspaceBillingProjection.Unavailable] {
        guard let data = json.data(using: .utf8), !data.isEmpty else { return [:] }
        do {
            return try JSONDecoder().decode(
                [String: StaffWorkspaceBillingProjection.Unavailable].self, from: data)
        } catch {
            return [:]
        }
    }

    // MARK: - Formatting

    private static let currencyKeys: Set<String> = [
        "amount", "total", "balanceDue", "salesTaxAmount", "subtotal", "tax"
    ]

    static func format(_ value: StaffWorkspaceValue, currency: Bool = false) -> String {
        switch value {
        case .text(let text):
            return text
        case .number(let number):
            if currency {
                return number.formatted(.currency(code: "USD"))
            }
            if number.rounded() == number, abs(number) < 1_000_000_000 {
                return String(Int(number))
            }
            return number.formatted()
        case .integer(let integer):
            return String(integer)
        case .flag(let flag):
            return flag ? "Yes" : "No"
        case .date(let date):
            return date.formatted(date: .abbreviated, time: .shortened)
        case .identifier(let id):
            return id.uuidString
        case .null:
            return "—"
        }
    }

    static func shortRecordID(_ value: String) -> String {
        guard value.count > 12 else { return value }
        return String(value.prefix(8)) + "…" + String(value.suffix(4))
    }

    static func humanize(_ key: String) -> String {
        var pieces: [String] = []
        var current = ""
        for ch in key {
            if ch.isUppercase, !current.isEmpty {
                pieces.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func titleCasedKind(_ kind: String) -> String {
        guard !kind.isEmpty else { return "Record" }
        var pieces: [String] = []
        var current = ""
        for ch in kind {
            if ch.isUppercase, !current.isEmpty {
                pieces.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    // MARK: - Summary construction

    private static func makeSummary(
        kind: String,
        recordID: String,
        available: [String: StaffWorkspaceValue],
        unavailable: [String: StaffWorkspaceBillingProjection.Unavailable]
    ) -> Summary {
        let kindBadge = titleCasedKind(kind)
        let hasRestricted = !unavailable.isEmpty
        let keys = preferenceKeys(for: kind)
        var used: Set<String> = []
        let titleValue = firstDisplay(keys: keys, available: available, used: &used)
        let subtitleValue = firstDisplay(keys: keys, available: available, used: &used)

        let title: String
        if let titleValue, !titleValue.isEmpty {
            title = titleValue
        } else {
            title = "\(kindBadge) · \(shortRecordID(recordID))"
        }

        let subtitle = subtitleValue ?? ""

        var badges = [kindBadge]
        if hasRestricted {
            badges.append("Restricted")
        }
        return Summary(
            title: title,
            subtitle: subtitle,
            kindBadge: kindBadge,
            badges: badges,
            hasRestrictedFields: hasRestricted
        )
    }

    private static func firstDisplay(
        keys: [String],
        available: [String: StaffWorkspaceValue],
        used: inout Set<String>
    ) -> String? {
        for key in keys {
            guard !used.contains(key), let value = available[key] else { continue }
            used.insert(key)
            let currency = currencyKeys.contains(key)
            let text = displayScalar(value, currency: currency)
            if let text, !text.isEmpty { return text }
        }
        return nil
    }

    /// Non-empty display for preference picks — skips null / empty text.
    private static func displayScalar(_ value: StaffWorkspaceValue, currency: Bool) -> String? {
        switch value {
        case .null:
            return nil
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            let formatted = format(value, currency: currency)
            return formatted.isEmpty ? nil : formatted
        }
    }
}
