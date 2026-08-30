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

enum ServiceRequestSource: String, Codable, CaseIterable, Identifiable {
    case phone
    case website
    case googleBusinessProfile
    case referral
    case repeatCustomer
    case maintenanceAgreement
    case vendorPartner
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .phone: "Phone"
        case .website: "Website / Online Booking"
        case .googleBusinessProfile: "Google Business Profile"
        case .referral: "Referral"
        case .repeatCustomer: "Repeat Customer"
        case .maintenanceAgreement: "Maintenance Agreement"
        case .vendorPartner: "Vendor / Partner"
        case .other: "Other"
        }
    }

    var requiresDetail: Bool { self == .other }
}

enum ServiceRequestLostReason: String, Codable, CaseIterable, Identifiable {
    case unableToReach
    case outsideServiceArea
    case workNotOffered
    case scheduleUnavailable
    case priceOrFinancing
    case customerChoseAnotherProvider
    case duplicate
    case spamOrInvalid
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unableToReach: "Unable to Reach"
        case .outsideServiceArea: "Outside Service Area"
        case .workNotOffered: "Work Not Offered"
        case .scheduleUnavailable: "Schedule Unavailable"
        case .priceOrFinancing: "Price / Financing"
        case .customerChoseAnotherProvider: "Chose Another Provider"
        case .duplicate: "Duplicate Request"
        case .spamOrInvalid: "Spam / Invalid"
        case .other: "Other"
        }
    }

    var requiresNotes: Bool { self == .other }
}

enum ServiceRequestPipelinePolicy {
    /// Overdue commitments come first, followed by emergency/priority triage and
    /// then the oldest request. This keeps the compact five-card queue honest.
    static func sortedOpenRequests(_ requests: [ServiceRequest], now: Date = Date()) -> [ServiceRequest] {
        requests
            .filter { $0.status == .new || $0.status == .qualified }
            .sorted { lhs, rhs in
                let lhsOverdue = lhs.isFollowUpOverdue(at: now)
                let rhsOverdue = rhs.isFollowUpOverdue(at: now)
                if lhsOverdue != rhsOverdue { return lhsOverdue && !rhsOverdue }
                if lhs.urgency.dispatchSortRank != rhs.urgency.dispatchSortRank {
                    return lhs.urgency.dispatchSortRank < rhs.urgency.dispatchSortRank
                }
                let lhsCommitment = lhs.nextFollowUpAt ?? lhs.createdAt
                let rhsCommitment = rhs.nextFollowUpAt ?? rhs.createdAt
                if lhsCommitment != rhsCommitment { return lhsCommitment < rhsCommitment }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }
}

/// A request is intentionally separate from a job. Dispatch can qualify the
/// contact and promised appointment before it becomes a scheduled work order.
@Model
final class ServiceRequest {
    private struct WorkflowEnvelope: Codable {
        let version: Int
        var sourceRaw: String
        var sourceDetail: String?
        var notes: String?
        var nextFollowUpAt: Date?
        var lastContactedAt: Date?
        var lastContactedByEmail: String?
        var lostReasonRaw: String?
        var declinedAt: Date?
        var declinedByEmail: String?
    }

    private static let workflowEnvelopePrefix = "GUNNAIRE_REQUEST_METADATA_V1:"

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
        source: ServiceRequestSource? = nil,
        sourceDetail: String? = nil,
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

        let initialSource = source ?? Self.fallbackSource(
            backendRequestID: backendRequestID,
            createdByEmail: createdByEmail
        )
        let envelope = WorkflowEnvelope(
            version: 1,
            sourceRaw: initialSource.rawValue,
            sourceDetail: Self.normalized(sourceDetail),
            notes: Self.normalized(qualificationNotes),
            nextFollowUpAt: nil,
            lastContactedAt: nil,
            lastContactedByEmail: nil,
            lostReasonRaw: nil,
            declinedAt: nil,
            declinedByEmail: nil
        )
        if let encoded = Self.encodedWorkflowEnvelope(envelope) {
            self.qualificationNotes = encoded
        }
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

    var leadSource: ServiceRequestSource {
        guard let rawValue = decodedWorkflowEnvelope?.sourceRaw,
              let source = ServiceRequestSource(rawValue: rawValue) else {
            return Self.fallbackSource(backendRequestID: backendRequestID, createdByEmail: createdByEmail)
        }
        return source
    }

    var leadSourceDetail: String? {
        Self.normalized(decodedWorkflowEnvelope?.sourceDetail)
    }

    var leadSourceSummary: String {
        guard let leadSourceDetail else { return leadSource.displayName }
        return "\(leadSource.displayName) • \(leadSourceDetail)"
    }

    /// Legacy plain-text notes remain readable while new structured workflow
    /// evidence is stored inside the existing CloudKit-backed String field.
    var intakeQualificationNotes: String? {
        if let envelope = decodedWorkflowEnvelope {
            return Self.normalized(envelope.notes)
        }
        guard qualificationNotes?.hasPrefix(Self.workflowEnvelopePrefix) != true else { return nil }
        return Self.normalized(qualificationNotes)
    }

    var nextFollowUpAt: Date? { decodedWorkflowEnvelope?.nextFollowUpAt }
    var lastContactedAt: Date? { decodedWorkflowEnvelope?.lastContactedAt }
    var lastContactedByEmail: String? { Self.normalized(decodedWorkflowEnvelope?.lastContactedByEmail) }
    var lostReason: ServiceRequestLostReason? {
        decodedWorkflowEnvelope?.lostReasonRaw.flatMap(ServiceRequestLostReason.init(rawValue:))
    }
    var declinedAt: Date? { decodedWorkflowEnvelope?.declinedAt }
    var declinedByEmail: String? { Self.normalized(decodedWorkflowEnvelope?.declinedByEmail) }

    func isFollowUpOverdue(at date: Date = Date()) -> Bool {
        guard status == .qualified, let nextFollowUpAt else { return false }
        return nextFollowUpAt < date
    }

    @discardableResult
    func recordQualification(
        source: ServiceRequestSource,
        sourceDetail: String?,
        notes: String?,
        nextFollowUpAt: Date?,
        actorEmail: String?,
        at date: Date = Date()
    ) -> Bool {
        let normalizedDetail = Self.normalized(sourceDetail)
        guard !source.requiresDetail || normalizedDetail != nil else { return false }
        guard nextFollowUpAt == nil || nextFollowUpAt! >= date else { return false }

        var envelope = workflowEnvelopeForMutation
        envelope.sourceRaw = source.rawValue
        envelope.sourceDetail = normalizedDetail
        envelope.notes = Self.normalized(notes)
        envelope.nextFollowUpAt = nextFollowUpAt
        envelope.lastContactedAt = date
        envelope.lastContactedByEmail = Self.normalizedEmail(actorEmail)
        envelope.lostReasonRaw = nil
        envelope.declinedAt = nil
        envelope.declinedByEmail = nil
        guard storeWorkflowEnvelope(envelope) else { return false }

        status = .qualified
        qualifiedAt = qualifiedAt ?? date
        return true
    }

    @discardableResult
    func recordDecline(
        reason: ServiceRequestLostReason,
        notes: String?,
        actorEmail: String?,
        at date: Date = Date()
    ) -> Bool {
        let normalizedNotes = Self.normalized(notes)
        guard !reason.requiresNotes || normalizedNotes != nil else { return false }

        var envelope = workflowEnvelopeForMutation
        envelope.notes = normalizedNotes
        envelope.nextFollowUpAt = nil
        envelope.lastContactedAt = date
        envelope.lastContactedByEmail = Self.normalizedEmail(actorEmail)
        envelope.lostReasonRaw = reason.rawValue
        envelope.declinedAt = date
        envelope.declinedByEmail = Self.normalizedEmail(actorEmail)
        guard storeWorkflowEnvelope(envelope) else { return false }

        status = .declined
        return true
    }

    func markScheduled(customerID: UUID, serviceCallID: UUID, at date: Date = Date()) {
        status = .scheduled
        convertedCustomerID = customerID
        convertedServiceCallID = serviceCallID
        qualifiedAt = qualifiedAt ?? date
    }

    private var workflowEnvelopeForMutation: WorkflowEnvelope {
        decodedWorkflowEnvelope ?? WorkflowEnvelope(
            version: 1,
            sourceRaw: Self.fallbackSource(
                backendRequestID: backendRequestID,
                createdByEmail: createdByEmail
            ).rawValue,
            sourceDetail: nil,
            notes: intakeQualificationNotes,
            nextFollowUpAt: nil,
            lastContactedAt: nil,
            lastContactedByEmail: nil,
            lostReasonRaw: nil,
            declinedAt: nil,
            declinedByEmail: nil
        )
    }

    @discardableResult
    private func storeWorkflowEnvelope(_ envelope: WorkflowEnvelope) -> Bool {
        guard let encoded = Self.encodedWorkflowEnvelope(envelope) else { return false }
        qualificationNotes = encoded
        return true
    }

    private var decodedWorkflowEnvelope: WorkflowEnvelope? {
        guard let qualificationNotes,
              qualificationNotes.hasPrefix(Self.workflowEnvelopePrefix) else { return nil }
        let encoded = String(qualificationNotes.dropFirst(Self.workflowEnvelopePrefix.count))
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(WorkflowEnvelope.self, from: data)
    }

    private static func encodedWorkflowEnvelope(_ envelope: WorkflowEnvelope) -> String? {
        guard let data = try? JSONEncoder().encode(envelope) else { return nil }
        return workflowEnvelopePrefix + data.base64EncodedString()
    }

    private static func fallbackSource(backendRequestID: String?, createdByEmail: String?) -> ServiceRequestSource {
        if backendRequestID != nil || normalizedEmail(createdByEmail) == "online-booking" {
            return .website
        }
        return .phone
    }

    private static func normalized(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        normalized(value)?.lowercased()
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
