import Foundation
import LoadSightCore

public enum ScheduleUnitConvention: String, Codable, CaseIterable, Sendable {
    case btuInternationalTablePerHour, thousandBtuInternationalTablePerHour, refrigerationTon
    case usLiquidGallonsPerMinute, imperialGallonsPerMinute
    public var title: String {
        switch self {
        case .btuInternationalTablePerHour: "International Table Btu per hour"
        case .thousandBtuInternationalTablePerHour: "1,000 International Table Btu per hour"
        case .refrigerationTon: "Refrigeration ton (12,000 Btu IT/h)"
        case .usLiquidGallonsPerMinute: "US liquid gallons per minute"
        case .imperialGallonsPerMinute: "Imperial gallons per minute"
        }
    }
    public static func available(for field: EquipmentScheduleField) -> [Self] {
        switch field {
        case .coolingTotal, .coolingSensible, .heatingCapacity, .furnaceInput, .furnaceOutput:
            [.btuInternationalTablePerHour, .thousandBtuInternationalTablePerHour, .refrigerationTon]
        case .airflow, .outdoorAir, .waterFlow: [.usLiquidGallonsPerMinute, .imperialGallonsPerMinute]
        default: []
        }
    }
    var canonicalInputUnit: String {
        switch self {
        case .btuInternationalTablePerHour: "Btu_IT/h"
        case .thousandBtuInternationalTablePerHour: "kBtu_IT/h"
        case .refrigerationTon: "tonR"
        case .usLiquidGallonsPerMinute: "USGPM"
        case .imperialGallonsPerMinute: "ImperialGPM"
        }
    }
    var literalAliases: Set<String> {
        switch self {
        case .btuInternationalTablePerHour: ["BTU/H", "BTU/HR", "BTUH"]
        case .thousandBtuInternationalTablePerHour: ["MBH", "MBTU/H", "MBTU/HR", "KBTU/H", "KBTU/HR"]
        case .refrigerationTon: ["TON", "TONS", "TR"]
        case .usLiquidGallonsPerMinute, .imperialGallonsPerMinute: ["GPM", "GAL/MIN"]
        }
    }
}
public struct ScheduleUnitDefinition: Codable, Equatable, Sendable {
    public var convention: ScheduleUnitConvention
    /// Drawing legend, specification or other evidence establishing this source's abbreviation.
    public var source: String
    public init(convention: ScheduleUnitConvention, source: String) { self.convention = convention; self.source = source }
    public func validate(field: EquipmentScheduleField, unitText: String?) throws {
        try require(!source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && source.count <= 4096,
                    "Record the drawing legend/specification evidence defining this unit convention (up to 4,096 characters).")
        try require(ScheduleUnitConvention.available(for: field).contains(convention), "Unit convention is incompatible with the mapped field.")
        guard let unitText else { throw LoadSightError.invalid("Retain the literal header unit before defining its convention.") }
        let literal = unitText.filter { !$0.isWhitespace }.uppercased()
        try require(convention.literalAliases.contains(literal), "Unit convention does not match this literal header abbreviation. Do not replace explicit or conflicting source units.")
    }
}
