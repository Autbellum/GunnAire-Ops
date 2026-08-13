import Foundation
import SwiftData

@Model
final class CustomerEquipment {
    @Attribute(.unique) var id: UUID
    var customer: Customer?
    var equipmentTypeRaw: String?
    var name: String
    var manufacturer: String?
    var modelNumber: String?
    var serialNumber: String?
    var location: String?
    var installDate: Date?
    var warrantyExpiration: Date?
    var filterSize: String?
    var notes: String?
    var isActive: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        customer: Customer? = nil,
        equipmentType: HVACEquipmentType? = nil,
        name: String,
        manufacturer: String? = nil,
        modelNumber: String? = nil,
        serialNumber: String? = nil,
        location: String? = nil,
        installDate: Date? = nil,
        warrantyExpiration: Date? = nil,
        filterSize: String? = nil,
        notes: String? = nil,
        isActive: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.customer = customer
        self.equipmentTypeRaw = equipmentType?.rawValue
        self.name = name
        self.manufacturer = manufacturer
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.location = location
        self.installDate = installDate
        self.warrantyExpiration = warrantyExpiration
        self.filterSize = filterSize
        self.notes = notes
        self.isActive = isActive
        self.createdAt = createdAt
    }

    var equipmentType: HVACEquipmentType? {
        get {
            guard let equipmentTypeRaw else { return nil }
            return HVACEquipmentType(rawValue: equipmentTypeRaw)
        }
        set {
            equipmentTypeRaw = newValue?.rawValue
        }
    }

    var displayName: String {
        let details = [
            equipmentType?.displayName,
            manufacturer,
            modelNumber,
            serialNumber.map { "Serial \($0)" }
        ]
        .compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        .joined(separator: " • ")
        return details.isEmpty ? name : "\(name) - \(details)"
    }

    func apply(to serviceCall: ServiceCall) {
        serviceCall.customerEquipmentID = id
        serviceCall.equipmentType = equipmentType
        serviceCall.equipmentName = name
        serviceCall.equipmentManufacturer = manufacturer
        serviceCall.equipmentModel = modelNumber
        serviceCall.equipmentSerialNumber = serialNumber
        serviceCall.equipmentLocation = location
        serviceCall.equipmentInstallDate = installDate
        serviceCall.equipmentWarrantyExpiration = warrantyExpiration
        serviceCall.filterSize = filterSize
        serviceCall.equipmentNotes = notes
    }

    func matches(_ serviceCall: ServiceCall) -> Bool {
        if serviceCall.customerEquipmentID == id {
            return true
        }
        if let customer, serviceCall.customer.id != customer.id {
            return false
        }
        if let serial = normalized(serialNumber),
           let callSerial = normalized(serviceCall.equipmentSerialNumber),
           serial == callSerial {
            return true
        }
        guard let equipmentName = normalized(name),
              let callEquipmentName = normalized(serviceCall.equipmentName),
              equipmentName == callEquipmentName else {
            return false
        }
        if let model = normalized(modelNumber),
           let callModel = normalized(serviceCall.equipmentModel) {
            return model == callModel
        }
        return true
    }

    func matchingServiceCalls(in serviceCalls: [ServiceCall]) -> [ServiceCall] {
        serviceCalls
            .filter { matches($0) }
            .sorted { $0.scheduledDate > $1.scheduledDate }
    }

    func serviceHistorySummary(in serviceCalls: [ServiceCall], now: Date = Date()) -> String? {
        let matchingCalls = matchingServiceCalls(in: serviceCalls)
        guard !matchingCalls.isEmpty else { return nil }

        let lastCompleted = matchingCalls
            .filter { $0.scheduledDate <= now && $0.status != .cancelled }
            .max { $0.scheduledDate < $1.scheduledDate }
        let nextScheduled = matchingCalls
            .filter { $0.scheduledDate > now && $0.status != .cancelled }
            .min { $0.scheduledDate < $1.scheduledDate }
        let parts = [
            lastCompleted.map { "Last: \($0.scheduledDate.formatted(date: .abbreviated, time: .omitted))" },
            nextScheduled.map { "Next: \($0.scheduledDate.formatted(date: .abbreviated, time: .omitted))" },
            "\(matchingCalls.count) job\(matchingCalls.count == 1 ? "" : "s")"
        ]
        .compactMap { $0 }
        return parts.joined(separator: " • ")
    }

    func latestCompletedServiceCall(in serviceCalls: [ServiceCall], now: Date = Date()) -> ServiceCall? {
        matchingServiceCalls(in: serviceCalls)
            .filter { $0.scheduledDate <= now && $0.status != .cancelled }
            .max { $0.scheduledDate < $1.scheduledDate }
    }

    func latestTechnicalReadingsSummary(in serviceCalls: [ServiceCall], now: Date = Date()) -> String? {
        latestCompletedServiceCall(in: serviceCalls, now: now)?
            .technicalReadingServiceHistorySummary
    }

    func latestServiceContextSummary(in serviceCalls: [ServiceCall], now: Date = Date()) -> String? {
        guard let call = latestCompletedServiceCall(in: serviceCalls, now: now) else {
            return nil
        }
        let parts = [
            "Last service: \(call.scheduledDate.formatted(date: .abbreviated, time: .omitted))",
            call.serviceReportSummary.map { "Report: \($0)" },
            call.technicalReadingServiceHistorySummary.map { "Readings: \($0)" }
        ]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }

    func updateFrom(
        equipmentType: HVACEquipmentType,
        name: String,
        manufacturer: String?,
        modelNumber: String?,
        serialNumber: String?,
        location: String?,
        installDate: Date?,
        warrantyExpiration: Date?,
        filterSize: String?,
        notes: String?,
        isActive: Bool
    ) {
        self.equipmentType = equipmentType
        self.name = name
        self.manufacturer = manufacturer
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.location = location
        self.installDate = installDate
        self.warrantyExpiration = warrantyExpiration
        self.filterSize = filterSize
        self.notes = notes
        self.isActive = isActive
    }

    static func mergedNotes(existing: String?, currentProfileNote: String? = nil, serviceHistoryNote: String?) -> String? {
        let trimmedProfileNote = currentProfileNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedExisting = trimmedProfileNote.isEmpty
            ? existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            : trimmedProfileNote
        let trimmedServiceNote = serviceHistoryNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedServiceNote.isEmpty else {
            return trimmedExisting.isEmpty ? nil : trimmedExisting
        }
        guard !trimmedExisting.isEmpty else {
            return trimmedServiceNote
        }
        if trimmedExisting.localizedCaseInsensitiveContains(trimmedServiceNote) {
            return trimmedExisting
        }
        return "\(trimmedExisting)\n\n\(trimmedServiceNote)"
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
