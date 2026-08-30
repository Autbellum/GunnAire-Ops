// Technician.swift
// Model for technicians, ready for SwiftData
import Foundation
import SwiftData

enum TechnicianEquipmentQualification: String, Codable {
    case notRequired
    case qualified
    case reviewDueSoon
    case unverified
    case reviewRequired
    case reviewExpired

    var displayName: String {
        switch self {
        case .notRequired: "No equipment qualification needed"
        case .qualified: "Qualified for this equipment"
        case .reviewDueSoon: "Qualified; review due soon"
        case .unverified: "Equipment qualification not recorded"
        case .reviewRequired: "Equipment qualification needs review"
        case .reviewExpired: "Equipment qualification review expired"
        }
    }

    var dispatchRank: Int {
        switch self {
        case .qualified: 0
        case .reviewDueSoon: 1
        case .notRequired: 2
        case .unverified: 3
        case .reviewRequired: 4
        case .reviewExpired: 5
        }
    }

    var needsDispatchAttention: Bool {
        switch self {
        case .notRequired, .qualified:
            false
        case .reviewDueSoon, .unverified, .reviewRequired, .reviewExpired:
            true
        }
    }

    var assignmentNotice: String? {
        switch self {
        case .notRequired, .qualified:
            nil
        case .reviewDueSoon:
            "qualification review due soon"
        case .unverified:
            "qualification unverified"
        case .reviewRequired:
            "review equipment"
        case .reviewExpired:
            "qualification review expired"
        }
    }
}

struct TechnicianQualificationReview: Equatable {
    let reviewedAt: Date?
    let reviewDueAt: Date?
    let reviewedByEmail: String?

    var isTracked: Bool {
        reviewedAt != nil || reviewDueAt != nil || reviewedByEmail != nil
    }

    func validationMessage(asOf date: Date = Date(), calendar: Calendar = .current) -> String? {
        guard isTracked else { return nil }
        guard let reviewedAt, let reviewDueAt else {
            return "Record both the qualification review date and its next review due date."
        }
        let today = calendar.startOfDay(for: date)
        if calendar.startOfDay(for: reviewedAt) > today {
            return "The qualification review date cannot be in the future."
        }
        if calendar.startOfDay(for: reviewDueAt) < calendar.startOfDay(for: reviewedAt) {
            return "The next qualification review cannot be due before the recorded review."
        }
        return nil
    }
}

enum TechnicianServiceAreaMatch: Int, Comparable {
    case covered = 0
    case unconfigured = 1
    case outsideConfiguredAreas = 2

    static func < (lhs: TechnicianServiceAreaMatch, rhs: TechnicianServiceAreaMatch) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var dispatchDetail: String {
        switch self {
        case .covered: "Service area matches"
        case .unconfigured: "Service areas not configured"
        case .outsideConfiguredAreas: "Outside configured service area"
        }
    }
}

enum TechnicianQuickBooksTimeEntityKind: String, CaseIterable, Identifiable {
    case employee
    case vendor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .employee: "Employee"
        case .vendor: "Vendor"
        }
    }

    var quickBooksNameOf: String { displayName }
}

struct TechnicianQuickBooksTimeMapping: Equatable {
    let kind: TechnicianQuickBooksTimeEntityKind
    let referenceID: String
    let technicianName: String
}

@Model
final class Technician {
    private struct QualificationProfile: Codable {
        let version: Int
        var supportedEquipmentTypeRawValues: [String]
        var reviewedAt: Date?
        var reviewDueAt: Date?
        var reviewedByEmail: String?
    }

    private static let qualificationProfileVersion = 2

    var id: UUID = UUID()
    var name: String = ""
    var contactInfo: String?
    var supportedEquipmentTypesJSON: String?
    var qualificationNotes: String?
    /// City, ZIP, or named territory tokens used as a transparent dispatch cue.
    /// This is deliberately not a GPS or routing claim.
    var serviceAreasJSON: String?
    /// Internal loaded labor cost used for job-cost reporting. It is never shown on customer documents.
    var laborCostPerHour: Double?
    /// Explicit QBO worker mapping used for TimeActivity creation. A global
    /// Employee/Vendor reference is unsafe once more than one technician clocks time.
    var quickBooksTimeEntityKindRawValue: String?
    var quickBooksTimeEntityRef: String?
    @Relationship(originalName: "assignedServiceCalls", inverse: \ServiceCall.assignedTechnician) private var storedAssignedServiceCalls: [ServiceCall]?

    var assignedServiceCalls: [ServiceCall] {
        get { storedAssignedServiceCalls ?? [] }
        set { storedAssignedServiceCalls = newValue }
    }

    var jobsCount: Int {
        assignedServiceCalls.filter { $0.status != .cancelled }.count
    }
    
    init(
        id: UUID = UUID(),
        name: String,
        contactInfo: String? = nil,
        supportedEquipmentTypes: Set<HVACEquipmentType> = [],
        qualificationNotes: String? = nil,
        serviceAreas: [String] = [],
        laborCostPerHour: Double? = nil,
        quickBooksTimeEntityKind: TechnicianQuickBooksTimeEntityKind? = nil,
        quickBooksTimeEntityRef: String? = nil,
        qualificationReviewedAt: Date? = nil,
        qualificationReviewDueAt: Date? = nil,
        qualificationReviewedByEmail: String? = nil
    ) {
        self.id = id
        self.name = name
        self.contactInfo = contactInfo
        self.supportedEquipmentTypesJSON = Self.encodedQualificationProfile(
            supportedEquipmentTypes: supportedEquipmentTypes,
            reviewedAt: qualificationReviewedAt,
            reviewDueAt: qualificationReviewDueAt,
            reviewedByEmail: qualificationReviewedByEmail
        )
        self.qualificationNotes = qualificationNotes
        self.serviceAreasJSON = Self.encodedServiceAreas(serviceAreas)
        self.laborCostPerHour = laborCostPerHour
        self.quickBooksTimeEntityKindRawValue = quickBooksTimeEntityKind?.rawValue
        self.quickBooksTimeEntityRef = Self.normalizedOptionalValue(quickBooksTimeEntityRef)
    }

    var supportedEquipmentTypes: Set<HVACEquipmentType> {
        get {
            Self.decodedQualificationProfile(from: supportedEquipmentTypesJSON).supportedEquipmentTypes
        }
        set {
            let current = Self.decodedQualificationProfile(from: supportedEquipmentTypesJSON)
            supportedEquipmentTypesJSON = Self.encodedQualificationProfile(
                supportedEquipmentTypes: newValue,
                reviewedAt: current.review.reviewedAt,
                reviewDueAt: current.review.reviewDueAt,
                reviewedByEmail: current.review.reviewedByEmail
            )
        }
    }

    var qualificationReview: TechnicianQualificationReview {
        Self.decodedQualificationProfile(from: supportedEquipmentTypesJSON).review
    }

    func updateEquipmentQualifications(
        _ supportedEquipmentTypes: Set<HVACEquipmentType>,
        reviewedAt: Date?,
        reviewDueAt: Date?,
        reviewedByEmail: String?
    ) {
        supportedEquipmentTypesJSON = Self.encodedQualificationProfile(
            supportedEquipmentTypes: supportedEquipmentTypes,
            reviewedAt: reviewedAt,
            reviewDueAt: reviewDueAt,
            reviewedByEmail: reviewedByEmail
        )
    }

    var quickBooksTimeEntityKind: TechnicianQuickBooksTimeEntityKind? {
        get {
            quickBooksTimeEntityKindRawValue.flatMap(TechnicianQuickBooksTimeEntityKind.init(rawValue:))
        }
        set { quickBooksTimeEntityKindRawValue = newValue?.rawValue }
    }

    var quickBooksTimeMapping: TechnicianQuickBooksTimeMapping? {
        guard let kind = quickBooksTimeEntityKind,
              let referenceID = Self.normalizedOptionalValue(quickBooksTimeEntityRef) else { return nil }
        return TechnicianQuickBooksTimeMapping(
            kind: kind,
            referenceID: referenceID,
            technicianName: name
        )
    }

    func qualification(
        for equipmentType: HVACEquipmentType?,
        asOf date: Date = Date(),
        calendar: Calendar = .current
    ) -> TechnicianEquipmentQualification {
        guard let equipmentType else { return .notRequired }
        let supportedTypes = supportedEquipmentTypes
        guard !supportedTypes.isEmpty else { return .unverified }
        guard supportedTypes.contains(equipmentType) else { return .reviewRequired }

        let review = qualificationReview
        guard review.validationMessage(asOf: date, calendar: calendar) == nil else {
            return review.isTracked ? .reviewRequired : .qualified
        }
        guard let reviewDueAt = review.reviewDueAt else { return .qualified }

        let today = calendar.startOfDay(for: date)
        let dueDay = calendar.startOfDay(for: reviewDueAt)
        if dueDay < today {
            return .reviewExpired
        }
        let warningHorizon = calendar.date(byAdding: .day, value: 30, to: today) ?? today
        return dueDay <= warningHorizon ? .reviewDueSoon : .qualified
    }

    var serviceAreas: [String] {
        get {
            guard let serviceAreasJSON,
                  let data = serviceAreasJSON.data(using: .utf8),
                  let values = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return Self.normalizedServiceAreas(values)
        }
        set { serviceAreasJSON = Self.encodedServiceAreas(newValue) }
    }

    func serviceAreaMatch(for address: String?) -> TechnicianServiceAreaMatch {
        let configuredAreas = serviceAreas
        guard !configuredAreas.isEmpty else { return .unconfigured }
        let normalizedAddress = Self.normalizedAreaToken(address ?? "")
        guard !normalizedAddress.isEmpty else { return .unconfigured }
        return configuredAreas.contains { normalizedAddress.contains(Self.normalizedAreaToken($0)) }
            ? .covered
            : .outsideConfiguredAreas
    }

    static func serviceAreas(from input: String) -> [String] {
        normalizedServiceAreas(input.components(separatedBy: ","))
    }

    private static func encodedQualificationProfile(
        supportedEquipmentTypes: Set<HVACEquipmentType>,
        reviewedAt: Date?,
        reviewDueAt: Date?,
        reviewedByEmail: String?
    ) -> String? {
        let normalizedReviewer = normalizedOptionalValue(reviewedByEmail).map { $0.lowercased() }
        guard !supportedEquipmentTypes.isEmpty || reviewedAt != nil || reviewDueAt != nil || normalizedReviewer != nil else {
            return nil
        }
        let profile = QualificationProfile(
            version: qualificationProfileVersion,
            supportedEquipmentTypeRawValues: supportedEquipmentTypes.map(\.rawValue).sorted(),
            reviewedAt: reviewedAt,
            reviewDueAt: reviewDueAt,
            reviewedByEmail: normalizedReviewer
        )
        guard let data = try? JSONEncoder().encode(profile) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodedQualificationProfile(
        from rawValue: String?
    ) -> (supportedEquipmentTypes: Set<HVACEquipmentType>, review: TechnicianQualificationReview) {
        guard let rawValue,
              let data = rawValue.data(using: .utf8) else {
            return ([], TechnicianQualificationReview(reviewedAt: nil, reviewDueAt: nil, reviewedByEmail: nil))
        }

        if let profile = try? JSONDecoder().decode(QualificationProfile.self, from: data),
           profile.version >= qualificationProfileVersion {
            return (
                Set(profile.supportedEquipmentTypeRawValues.compactMap(HVACEquipmentType.init(rawValue:))),
                TechnicianQualificationReview(
                    reviewedAt: profile.reviewedAt,
                    reviewDueAt: profile.reviewDueAt,
                    reviewedByEmail: normalizedOptionalValue(profile.reviewedByEmail)?.lowercased()
                )
            )
        }

        // Version-one records stored only a JSON array of supported equipment
        // raw values. Treat them as current to avoid silently withdrawing an
        // existing dispatch qualification; an administrator can opt in to a
        // dated review when the profile is next maintained.
        if let rawValues = try? JSONDecoder().decode([String].self, from: data) {
            return (
                Set(rawValues.compactMap(HVACEquipmentType.init(rawValue:))),
                TechnicianQualificationReview(reviewedAt: nil, reviewDueAt: nil, reviewedByEmail: nil)
            )
        }

        return ([], TechnicianQualificationReview(reviewedAt: nil, reviewDueAt: nil, reviewedByEmail: nil))
    }

    private static func encodedServiceAreas(_ areas: [String]) -> String? {
        let normalized = normalizedServiceAreas(areas)
        guard !normalized.isEmpty,
              let data = try? JSONEncoder().encode(normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func normalizedServiceAreas(_ areas: [String]) -> [String] {
        Array(Set(areas.compactMap { area -> String? in
            let trimmed = area.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedAreaToken(trimmed).count >= 3 ? trimmed : nil
        }))
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func normalizedAreaToken(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizedOptionalValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
