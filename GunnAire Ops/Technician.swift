// Technician.swift
// Model for technicians, ready for SwiftData
import Foundation
import SwiftData

enum TechnicianEquipmentQualification: String, Codable {
    case notRequired
    case qualified
    case unverified
    case reviewRequired

    var displayName: String {
        switch self {
        case .notRequired: "No equipment qualification needed"
        case .qualified: "Qualified for this equipment"
        case .unverified: "Equipment qualification not recorded"
        case .reviewRequired: "Equipment qualification needs review"
        }
    }

    var dispatchRank: Int {
        switch self {
        case .qualified: 0
        case .notRequired: 1
        case .unverified: 2
        case .reviewRequired: 3
        }
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

@Model
final class Technician {
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
        laborCostPerHour: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.contactInfo = contactInfo
        self.supportedEquipmentTypesJSON = Self.encodedEquipmentTypes(supportedEquipmentTypes)
        self.qualificationNotes = qualificationNotes
        self.serviceAreasJSON = Self.encodedServiceAreas(serviceAreas)
        self.laborCostPerHour = laborCostPerHour
    }

    var supportedEquipmentTypes: Set<HVACEquipmentType> {
        get {
            guard let supportedEquipmentTypesJSON,
                  let data = supportedEquipmentTypesJSON.data(using: .utf8),
                  let rawValues = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return Set(rawValues.compactMap(HVACEquipmentType.init(rawValue:)))
        }
        set {
            supportedEquipmentTypesJSON = Self.encodedEquipmentTypes(newValue)
        }
    }

    func qualification(for equipmentType: HVACEquipmentType?) -> TechnicianEquipmentQualification {
        guard let equipmentType else { return .notRequired }
        let supportedTypes = supportedEquipmentTypes
        guard !supportedTypes.isEmpty else { return .unverified }
        return supportedTypes.contains(equipmentType) ? .qualified : .reviewRequired
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

    private static func encodedEquipmentTypes(_ types: Set<HVACEquipmentType>) -> String? {
        guard !types.isEmpty,
              let data = try? JSONEncoder().encode(types.map(\.rawValue).sorted()) else { return nil }
        return String(data: data, encoding: .utf8)
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
}
