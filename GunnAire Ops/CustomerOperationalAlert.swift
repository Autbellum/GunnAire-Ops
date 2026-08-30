import Foundation
import SwiftData

enum CustomerOperationalAlertKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case doNotService = "do_not_service"
    case safety
    case access
    case pet
    case priority
    case warranty
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .doNotService: "Do Not Service"
        case .safety: "Safety"
        case .access: "Access"
        case .pet: "Pet on Site"
        case .priority: "Priority Customer"
        case .warranty: "Warranty"
        case .other: "Other"
        }
    }

    var defaultTitle: String { displayName }

    var systemImage: String {
        switch self {
        case .doNotService: "hand.raised.fill"
        case .safety: "exclamationmark.shield.fill"
        case .access: "key.fill"
        case .pet: "pawprint.fill"
        case .priority: "star.fill"
        case .warranty: "checkmark.seal.fill"
        case .other: "tag.fill"
        }
    }

    var severity: CustomerOperationalAlertSeverity {
        switch self {
        case .doNotService: .critical
        case .safety, .access, .pet: .attention
        case .priority, .warranty, .other: .information
        }
    }

    var blocksNewScheduling: Bool { self == .doNotService }

    var requiresDetailedReason: Bool {
        self == .doNotService || self == .safety
    }
}

enum CustomerOperationalAlertSeverity: String, Codable, CaseIterable, Sendable {
    case critical
    case attention
    case information

    fileprivate var sortRank: Int {
        switch self {
        case .critical: 0
        case .attention: 1
        case .information: 2
        }
    }
}

enum CustomerOperationalAlertValidationError: LocalizedError, Equatable {
    case actorRequired
    case detailRequired(CustomerOperationalAlertKind)
    case alreadyResolved
    case resolutionNoteRequired

    var errorDescription: String? {
        switch self {
        case .actorRequired:
            "A signed-in business account is required to change operational alerts."
        case .detailRequired(let kind):
            "Enter the reason for this \(kind.displayName.lowercased()) alert so field staff know what action to take."
        case .alreadyResolved:
            "This operational alert has already been resolved."
        case .resolutionNoteRequired:
            "Enter the resolution that makes this customer or property safe to serve again."
        }
    }
}

@Model
final class CustomerOperationalAlert {
    var id: UUID = UUID()
    var creationOperationID: UUID = UUID()
    var customerID: UUID = UUID()
    var customerName: String = ""
    var serviceLocationID: UUID?
    var serviceLocationName: String?
    var kindRaw: String = CustomerOperationalAlertKind.other.rawValue
    var title: String = ""
    var detail: String?
    var createdAt: Date = Date()
    var createdByEmail: String = ""
    var updatedAt: Date = Date()
    var resolvedAt: Date?
    var resolvedByEmail: String?
    var resolutionNote: String?
    var resolutionOperationID: UUID?

    init(
        id: UUID = UUID(),
        creationOperationID: UUID = UUID(),
        customerID: UUID,
        customerName: String,
        serviceLocationID: UUID? = nil,
        serviceLocationName: String? = nil,
        kind: CustomerOperationalAlertKind,
        title: String,
        detail: String? = nil,
        createdAt: Date = Date(),
        createdByEmail: String
    ) {
        self.id = id
        self.creationOperationID = creationOperationID
        self.customerID = customerID
        self.customerName = CustomerOperationalAlertPolicy.boundedText(customerName, limit: 160)
        self.serviceLocationID = serviceLocationID
        self.serviceLocationName = CustomerOperationalAlertPolicy.optionalText(serviceLocationName, limit: 160)
        self.kindRaw = kind.rawValue
        self.title = CustomerOperationalAlertPolicy.boundedText(title, limit: CustomerOperationalAlertPolicy.titleLimit)
        self.detail = CustomerOperationalAlertPolicy.optionalText(detail, limit: CustomerOperationalAlertPolicy.detailLimit)
        self.createdAt = createdAt
        self.createdByEmail = AppAccess.normalizedEmail(createdByEmail)
        self.updatedAt = createdAt
    }

    var kind: CustomerOperationalAlertKind {
        get { CustomerOperationalAlertKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var severity: CustomerOperationalAlertSeverity { kind.severity }
    var isActive: Bool { resolvedAt == nil }
    var blocksNewScheduling: Bool { isActive && kind.blocksNewScheduling }

    var scopeDescription: String {
        if let serviceLocationName,
           !serviceLocationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return serviceLocationName
        }
        return "All service locations"
    }
}

enum CustomerOperationalAlertPolicy {
    static let titleLimit = 32
    static let detailLimit = 600
    static let resolutionNoteLimit = 600

    static func makeAlert(
        customerID: UUID,
        customerName: String,
        serviceLocationID: UUID? = nil,
        serviceLocationName: String? = nil,
        kind: CustomerOperationalAlertKind,
        title: String,
        detail: String?,
        actorEmail: String?,
        now: Date = Date(),
        creationOperationID: UUID = UUID()
    ) throws -> CustomerOperationalAlert {
        let actor = AppAccess.normalizedEmail(actorEmail ?? "")
        guard !actor.isEmpty else {
            throw CustomerOperationalAlertValidationError.actorRequired
        }
        let normalizedDetail = optionalText(detail, limit: detailLimit)
        if kind.requiresDetailedReason, normalizedDetail == nil {
            throw CustomerOperationalAlertValidationError.detailRequired(kind)
        }
        let normalizedTitle = boundedText(title, limit: titleLimit)
        return CustomerOperationalAlert(
            creationOperationID: creationOperationID,
            customerID: customerID,
            customerName: customerName,
            serviceLocationID: serviceLocationID,
            serviceLocationName: serviceLocationName,
            kind: kind,
            title: normalizedTitle.isEmpty ? kind.defaultTitle : normalizedTitle,
            detail: normalizedDetail,
            createdAt: now,
            createdByEmail: actor
        )
    }

    static func activeAlerts(
        customerID: UUID,
        serviceLocationID: UUID? = nil,
        in alerts: [CustomerOperationalAlert]
    ) -> [CustomerOperationalAlert] {
        ordered(alerts.filter { alert in
            guard alert.customerID == customerID, alert.isActive else { return false }
            guard let alertLocationID = alert.serviceLocationID else { return true }
            return alertLocationID == serviceLocationID
        })
    }

    static func allAlerts(
        customerID: UUID,
        in alerts: [CustomerOperationalAlert]
    ) -> [CustomerOperationalAlert] {
        ordered(alerts.filter { $0.customerID == customerID })
    }

    static func schedulingBlocker(
        customerID: UUID,
        serviceLocationID: UUID? = nil,
        in alerts: [CustomerOperationalAlert]
    ) -> CustomerOperationalAlert? {
        activeAlerts(
            customerID: customerID,
            serviceLocationID: serviceLocationID,
            in: alerts
        ).first(where: \CustomerOperationalAlert.blocksNewScheduling)
    }

    static func bookingRestrictionMessage(for alert: CustomerOperationalAlert) -> String {
        let detail = alert.detail.map { " \($0)" } ?? ""
        return "Do Not Service is active for \(alert.scopeDescription). Resolve it in the customer record before scheduling, rescheduling, assigning, or starting work.\(detail)"
    }

    static func resolve(
        _ alert: CustomerOperationalAlert,
        actorEmail: String?,
        note: String?,
        now: Date = Date(),
        resolutionOperationID: UUID = UUID()
    ) throws {
        guard alert.isActive else {
            throw CustomerOperationalAlertValidationError.alreadyResolved
        }
        let actor = AppAccess.normalizedEmail(actorEmail ?? "")
        guard !actor.isEmpty else {
            throw CustomerOperationalAlertValidationError.actorRequired
        }
        let normalizedNote = optionalText(note, limit: resolutionNoteLimit)
        if alert.kind.requiresDetailedReason, normalizedNote == nil {
            throw CustomerOperationalAlertValidationError.resolutionNoteRequired
        }
        alert.resolvedAt = now
        alert.resolvedByEmail = actor
        alert.resolutionNote = normalizedNote
        alert.resolutionOperationID = resolutionOperationID
        alert.updatedAt = now
    }

    static func ordered(_ alerts: [CustomerOperationalAlert]) -> [CustomerOperationalAlert] {
        alerts.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.severity.sortRank != rhs.severity.sortRank {
                return lhs.severity.sortRank < rhs.severity.sortRank
            }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func boundedText(_ value: String, limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    static func optionalText(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let normalized = boundedText(value, limit: limit)
        return normalized.isEmpty ? nil : normalized
    }
}
