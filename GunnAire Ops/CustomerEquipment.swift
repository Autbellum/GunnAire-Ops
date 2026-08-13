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
    var technicalBaselineReadingsJSON: String?
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
        technicalBaselineReadingsJSON: String? = nil,
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
        self.technicalBaselineReadingsJSON = technicalBaselineReadingsJSON
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
        applyTechnicalBaselines(to: serviceCall)
    }

    var technicalBaselineReadings: [String: String] {
        guard let technicalBaselineReadingsJSON,
              let data = technicalBaselineReadingsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    @discardableResult
    func applyTechnicalBaselines(to serviceCall: ServiceCall, overwriteExisting: Bool = false) -> Int {
        guard let equipmentType = equipmentType ?? serviceCall.equipmentType else { return 0 }
        let allowedKeys = Set(equipmentType.equipmentProfileBaselineReadingKeys)
        var appliedCount = 0
        for key in allowedKeys.sorted() {
            guard let value = technicalBaselineReadings[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            if !overwriteExisting,
               !serviceCall.technicalReading(for: key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            serviceCall.setTechnicalReading(value, for: key)
            appliedCount += 1
        }
        return appliedCount
    }

    @discardableResult
    func updateTechnicalBaselines(from serviceCall: ServiceCall) -> Int {
        guard let equipmentType = serviceCall.equipmentType ?? equipmentType else { return 0 }
        let allowedKeys = Set(equipmentType.equipmentProfileBaselineReadingKeys)
        var baselines = technicalBaselineReadings
        var updatedCount = 0

        for key in allowedKeys.sorted() {
            let value = serviceCall.technicalReading(for: key).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                continue
            }
            if baselines[key] != value {
                baselines[key] = value
                updatedCount += 1
            }
        }

        baselines = baselines.filter { allowedKeys.contains($0.key) }
        if baselines.isEmpty {
            technicalBaselineReadingsJSON = nil
        } else if let data = try? JSONEncoder().encode(baselines),
                  let encoded = String(data: data, encoding: .utf8) {
            technicalBaselineReadingsJSON = encoded
        }
        return updatedCount
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

    func recentTechnicalTrendSummary(in serviceCalls: [ServiceCall], now: Date = Date()) -> String? {
        let completedCalls = matchingServiceCalls(in: serviceCalls)
            .filter { $0.scheduledDate <= now && $0.status != .cancelled }
            .sorted { $0.scheduledDate > $1.scheduledDate }
        guard let latestCall = completedCalls.first else { return nil }

        let priorCalls = Array(completedCalls.dropFirst())
        guard !priorCalls.isEmpty else { return nil }

        let latestDefinitions = Dictionary(uniqueKeysWithValues: latestCall.technicalReadingDefinitions.map { ($0.key, $0) })
        let trendKeys = Self.technicalTrendPriorityKeys(for: latestCall.equipmentType ?? equipmentType ?? .splitSystemAC)
        let trendRows = trendKeys.compactMap { key -> String? in
            let latestValue = latestCall.technicalReading(for: key).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latestValue.isEmpty else { return nil }
            guard let previous = priorCalls.compactMap({ call -> (value: String, date: Date)? in
                let value = call.technicalReading(for: key).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                return (value, call.scheduledDate)
            }).first else { return nil }
            guard !Self.trendValuesEquivalent(latestValue, previous.value) else { return nil }
            let label = latestDefinitions[key]?.label ?? key.replacingOccurrences(of: "_", with: " ").capitalized
            return "\(label): \(latestValue) (was \(previous.value) \(previous.date.formatted(date: .abbreviated, time: .omitted)))"
        }

        guard !trendRows.isEmpty else { return nil }
        return trendRows.prefix(6).joined(separator: "; ")
    }

    func latestServiceConcernSummary(in serviceCalls: [ServiceCall], now: Date = Date()) -> String? {
        guard let call = latestCompletedServiceCall(in: serviceCalls, now: now) else {
            return nil
        }
        let concernRows = call.serviceActionDefinitions.compactMap { definition -> (label: String, status: HVACServiceActionStatus)? in
            let status = call.serviceActionStatus(for: definition.key)
            switch status {
            case .needsService, .monitor:
                return (definition.label, status)
            case .notChecked, .completed, .notApplicable:
                return nil
            }
        }
        guard !concernRows.isEmpty else { return nil }
        return concernRows
            .sorted { lhs, rhs in
                if lhs.status == rhs.status {
                    return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
                }
                return lhs.status == .needsService
            }
            .prefix(5)
            .map { "\($0.label): \($0.status.label)" }
            .joined(separator: "; ")
    }

    func unresolvedServiceConcernSummary(in serviceCalls: [ServiceCall], now: Date = Date()) -> String? {
        let calls = matchingServiceCalls(in: serviceCalls)
            .filter { $0.scheduledDate <= now && $0.status != .cancelled }
            .sorted { $0.scheduledDate > $1.scheduledDate }
        var resolvedKeys: Set<String> = []
        var concerns: [(label: String, status: HVACServiceActionStatus, date: Date)] = []

        for call in calls {
            for definition in call.serviceActionDefinitions {
                guard !resolvedKeys.contains(definition.key) else { continue }
                let status = call.serviceActionStatus(for: definition.key)
                switch status {
                case .needsService, .monitor:
                    concerns.append((definition.label, status, call.scheduledDate))
                    resolvedKeys.insert(definition.key)
                case .completed, .notApplicable:
                    resolvedKeys.insert(definition.key)
                case .notChecked:
                    continue
                }
            }
        }

        guard !concerns.isEmpty else { return nil }
        return concerns
            .sorted { lhs, rhs in
                if lhs.status == rhs.status {
                    return lhs.date > rhs.date
                }
                return lhs.status == .needsService
            }
            .prefix(6)
            .map { "\($0.label): \($0.status.label) (\($0.date.formatted(date: .abbreviated, time: .omitted)))" }
            .joined(separator: "; ")
    }

    func latestServiceContextSummary(in serviceCalls: [ServiceCall], now: Date = Date()) -> String? {
        guard let call = latestCompletedServiceCall(in: serviceCalls, now: now) else {
            return nil
        }
        let parts = [
            "Last service: \(call.scheduledDate.formatted(date: .abbreviated, time: .omitted))",
            call.serviceReportSummary.map { "Report: \($0)" },
            call.technicalReadingServiceHistorySummary.map { "Readings: \($0)" },
            recentTechnicalTrendSummary(in: serviceCalls, now: now).map { "Trends: \($0)" },
            call.serviceActionServiceHistorySummary.map { "Actions: \($0)" }
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

    private static func technicalTrendPriorityKeys(for equipmentType: HVACEquipmentType) -> [String] {
        let common = [
            "temperature_split",
            "temperature_rise",
            "total_external_static",
            "superheat",
            "subcooling",
            "compressor_amps",
            "blower_amps",
            "line_voltage",
            "co_ppm"
        ]
        switch equipmentType {
        case .splitSystemAC:
            return common + ["suction_pressure", "liquid_pressure", "head_pressure", "condenser_condition", "evaporator_condition"]
        case .heatPump:
            return common + ["reversing_valve_operation", "defrost_control_status", "aux_heat_amps"]
        case .packageUnit:
            return common + ["economizer_operation", "mixed_air_temp", "outdoor_air_damper_position", "economizer_sensor_status", "heat_exchanger_condition"]
        case .miniSplit:
            return common + ["indoor_head_delta_t", "communication_voltage", "inverter_frequency", "indoor_filter_condition", "condensate_pump_status"]
        case .gasFurnace:
            return ["temperature_rise", "gas_pressure_inlet", "gas_pressure_manifold", "flame_sensor_microamps", "inducer_amps", "blower_amps", "draft_pressure", "co_ppm", "heat_exchanger_condition"]
        case .airHandler:
            return ["temperature_split", "temperature_rise", "static_pressure_return", "static_pressure_supply", "total_external_static", "blower_amps", "heat_strip_amps", "blower_wheel_condition", "duct_condition"]
        case .boiler:
            return ["water_temp_supply", "water_temp_return", "system_pressure", "expansion_tank_pressure", "gas_pressure_inlet", "gas_pressure_manifold", "circulator_amps", "co_ppm"]
        case .waterHeater:
            return ["water_temp_out", "incoming_water_temp", "gas_pressure_inlet", "gas_pressure_manifold", "draft_pressure", "tank_condition", "co_ppm"]
        case .ventilation:
            return ["airflow", "outside_air_cfm", "exhaust_air_cfm", "motor_amps", "line_voltage", "static_pressure", "belt_condition", "damper_operation"]
        case .iaqAccessory:
            return ["return_humidity", "supply_humidity", "airflow", "static_pressure", "filter_media_condition", "water_panel_condition", "uv_lamp_status", "damper_operation"]
        case .other:
            return ["temperature_split", "temperature_rise", "line_voltage"]
        }
    }

    private static func trendValuesEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        if let lhsNumber = Double(lhs.replacingOccurrences(of: ",", with: ".")),
           let rhsNumber = Double(rhs.replacingOccurrences(of: ",", with: ".")) {
            return abs(lhsNumber - rhsNumber) < 0.05
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
