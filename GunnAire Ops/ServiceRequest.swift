import Foundation
import SwiftData

enum ServiceRequestStatus: String, Codable, CaseIterable, Identifiable {
    case new
    case qualified
    case scheduled
    case declined

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

/// A request is intentionally separate from a job. Dispatch can qualify the
/// contact and promised appointment before it becomes a scheduled work order.
@Model
final class ServiceRequest {
    var id: UUID = UUID()
    var backendRequestID: String?
    var customerName: String = ""
    var phone: String?
    var email: String?
    var address: String?
    var requestedServiceTypeRaw: String = ServiceCallType.service.rawValue
    var urgencyRaw: String = ServiceRequestUrgency.normal.rawValue
    var summary: String = ""
    var preferredDate: Date?
    var statusRaw: String = ServiceRequestStatus.new.rawValue
    var qualificationNotes: String?
    var createdByEmail: String?
    var createdAt: Date = Date()
    var qualifiedAt: Date?
    var convertedCustomerID: UUID?
    var convertedServiceCallID: UUID?

    init(
        id: UUID = UUID(),
        backendRequestID: String? = nil,
        customerName: String,
        phone: String? = nil,
        email: String? = nil,
        address: String? = nil,
        requestedServiceType: ServiceCallType = .service,
        urgency: ServiceRequestUrgency = .normal,
        summary: String,
        preferredDate: Date? = nil,
        status: ServiceRequestStatus = .new,
        qualificationNotes: String? = nil,
        createdByEmail: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.backendRequestID = backendRequestID
        self.customerName = customerName
        self.phone = phone
        self.email = email
        self.address = address
        self.requestedServiceTypeRaw = requestedServiceType.rawValue
        self.urgencyRaw = urgency.rawValue
        self.summary = summary
        self.preferredDate = preferredDate
        self.statusRaw = status.rawValue
        self.qualificationNotes = qualificationNotes
        self.createdByEmail = createdByEmail
        self.createdAt = createdAt
    }

    var status: ServiceRequestStatus {
        get { ServiceRequestStatus(rawValue: statusRaw) ?? .new }
        set { statusRaw = newValue.rawValue }
    }

    var requestedServiceType: ServiceCallType {
        get { ServiceCallType(rawValue: requestedServiceTypeRaw) ?? .service }
        set { requestedServiceTypeRaw = newValue.rawValue }
    }

    var urgency: ServiceRequestUrgency {
        get { ServiceRequestUrgency(rawValue: urgencyRaw) ?? .normal }
        set { urgencyRaw = newValue.rawValue }
    }

    var canSchedule: Bool {
        status == .qualified
    }

    func markScheduled(customerID: UUID, serviceCallID: UUID, at date: Date = Date()) {
        status = .scheduled
        convertedCustomerID = customerID
        convertedServiceCallID = serviceCallID
        qualifiedAt = qualifiedAt ?? date
    }
}

enum ServiceRequestUrgency: String, Codable, CaseIterable, Identifiable {
    case normal
    case priority
    case emergency

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .priority: "Priority"
        case .emergency: "Emergency"
        }
    }

    /// Lower values sort ahead in a dispatcher-facing queue. This is a triage
    /// signal only; it never overrides a dispatcher’s committed appointment.
    var dispatchSortRank: Int {
        switch self {
        case .emergency: 0
        case .priority: 1
        case .normal: 2
        }
    }
}
