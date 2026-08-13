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
}
