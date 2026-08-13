// ServiceCall.swift
// Model for scheduled jobs and service calls
import Foundation
import SwiftData

enum ServiceCallType: String, Codable, CaseIterable {
    case service
    case estimate
    case install
    case maintenance
    case meeting
    case reminder
    case siteVisit = "site visit"
    case other

    var displayName: String {
        switch self {
        case .service:
            return "Service"
        case .estimate:
            return "Estimate"
        case .install:
            return "Install"
        case .maintenance:
            return "Maintenance"
        case .meeting:
            return "Meeting"
        case .reminder:
            return "Reminder"
        case .siteVisit:
            return "Site Visit"
        case .other:
            return "Other"
        }
    }
}

enum JobStatus: String, Codable, CaseIterable {
    case scheduled, inProgress, completed, invoiced, cancelled
}

enum HVACEquipmentType: String, Codable, CaseIterable, Identifiable {
    case splitSystemAC = "split_system_ac"
    case heatPump = "heat_pump"
    case gasFurnace = "gas_furnace"
    case airHandler = "air_handler"
    case packageUnit = "package_unit"
    case miniSplit = "mini_split"
    case boiler = "boiler"
    case waterHeater = "water_heater"
    case ventilation = "ventilation"
    case other = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .splitSystemAC: return "Split System AC"
        case .heatPump: return "Heat Pump"
        case .gasFurnace: return "Gas Furnace"
        case .airHandler: return "Air Handler"
        case .packageUnit: return "Package Unit"
        case .miniSplit: return "Mini Split"
        case .boiler: return "Boiler"
        case .waterHeater: return "Water Heater"
        case .ventilation: return "Ventilation"
        case .other: return "Other"
        }
    }

    private static let refrigerantOptions = [
        "R-410A",
        "R-22",
        "R-32",
        "R-454B",
        "R-407C",
        "R-134a",
        "Other"
    ]

    private static let meteringDeviceOptions = [
        "TXV",
        "Piston",
        "EEV",
        "Capillary Tube",
        "Fixed Orifice",
        "Unknown"
    ]

    private static let conditionOptions = [
        "Normal",
        "Monitor",
        "Needs Cleaning",
        "Needs Repair",
        "Failed",
        "Not Tested",
        "Not Applicable"
    ]

    private static let blowerTypeOptions = [
        "PSC",
        "ECM Constant Torque",
        "ECM Variable Speed",
        "Belt Drive",
        "Direct Drive",
        "Unknown"
    ]

    private static let gasFuelOptions = [
        "Natural Gas",
        "Propane",
        "Oil",
        "Electric",
        "Other"
    ]

    private static let ignitionOptions = [
        "Hot Surface Ignition",
        "Spark Ignition",
        "Intermittent Pilot",
        "Standing Pilot",
        "Not Applicable"
    ]

    private static let ventingOptions = [
        "Natural Draft",
        "Induced Draft",
        "Direct Vent",
        "Power Vent",
        "Condensing",
        "Not Applicable"
    ]

    private static let tankConditionOptions = [
        "Normal",
        "Sediment Present",
        "Flushed",
        "Leaking",
        "Corroded",
        "Replacement Recommended",
        "Not Accessible"
    ]

    var readingDefinitions: [HVACTechnicalReadingDefinition] {
        let common = [
            HVACTechnicalReadingDefinition(key: "return_air_temp", label: "Return Air Temp", unit: "F"),
            HVACTechnicalReadingDefinition(key: "supply_air_temp", label: "Supply Air Temp", unit: "F"),
            HVACTechnicalReadingDefinition(key: "temperature_split", label: "Temperature Split", unit: "F"),
            HVACTechnicalReadingDefinition(key: "line_voltage", label: "Line Voltage", unit: "V"),
            HVACTechnicalReadingDefinition(key: "control_voltage", label: "Control Voltage", unit: "V")
        ]

        switch self {
        case .splitSystemAC:
            return common + coolingCircuitDefinitions + [
                HVACTechnicalReadingDefinition(key: "condenser_condition", label: "Condenser Condition", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "evaporator_condition", label: "Evaporator Condition", unit: nil, options: Self.conditionOptions)
            ]
        case .heatPump:
            return common + coolingCircuitDefinitions + [
                HVACTechnicalReadingDefinition(key: "mode_tested", label: "Mode Tested", unit: nil, options: ["Cooling", "Heating", "Both"]),
                HVACTechnicalReadingDefinition(key: "reversing_valve_operation", label: "Reversing Valve", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "defrost_control_status", label: "Defrost Control", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "aux_heat_amps", label: "Aux Heat Amps", unit: "A")
            ]
        case .packageUnit:
            return common + coolingCircuitDefinitions + [
                HVACTechnicalReadingDefinition(key: "economizer_operation", label: "Economizer", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "gas_pressure_inlet", label: "Gas Pressure Inlet", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "gas_pressure_manifold", label: "Gas Pressure Manifold", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "heat_exchanger_condition", label: "Heat Exchanger", unit: nil, options: Self.conditionOptions)
            ]
        case .miniSplit:
            return common + coolingCircuitDefinitions + [
                HVACTechnicalReadingDefinition(key: "indoor_head_delta_t", label: "Indoor Head Delta T", unit: "F"),
                HVACTechnicalReadingDefinition(key: "communication_voltage", label: "Communication Voltage", unit: "V"),
                HVACTechnicalReadingDefinition(key: "condensate_pump_status", label: "Condensate Pump", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "remote_operation", label: "Remote Operation", unit: nil, options: Self.conditionOptions)
            ]
        case .gasFurnace:
            return common + [
                HVACTechnicalReadingDefinition(key: "fuel_type", label: "Fuel Type", unit: nil, options: Self.gasFuelOptions),
                HVACTechnicalReadingDefinition(key: "ignition_type", label: "Ignition Type", unit: nil, options: Self.ignitionOptions),
                HVACTechnicalReadingDefinition(key: "venting_type", label: "Venting Type", unit: nil, options: Self.ventingOptions),
                HVACTechnicalReadingDefinition(key: "gas_pressure_inlet", label: "Gas Pressure Inlet", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "gas_pressure_manifold", label: "Gas Pressure Manifold", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "flame_sensor_microamps", label: "Flame Sensor", unit: "uA"),
                HVACTechnicalReadingDefinition(key: "inducer_amps", label: "Inducer Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "blower_amps", label: "Blower Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "temperature_rise", label: "Temperature Rise", unit: "F"),
                HVACTechnicalReadingDefinition(key: "draft_pressure", label: "Draft Pressure", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "flue_temp", label: "Flue Temp", unit: "F"),
                HVACTechnicalReadingDefinition(key: "o2_percent", label: "O2", unit: "%"),
                HVACTechnicalReadingDefinition(key: "co2_percent", label: "CO2", unit: "%"),
                HVACTechnicalReadingDefinition(key: "co_ppm", label: "CO Reading", unit: "ppm"),
                HVACTechnicalReadingDefinition(key: "heat_exchanger_condition", label: "Heat Exchanger", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "limit_switch_operation", label: "Limit Switch", unit: nil, options: Self.conditionOptions)
            ]
        case .airHandler:
            return common + [
                HVACTechnicalReadingDefinition(key: "blower_type", label: "Blower Type", unit: nil, options: Self.blowerTypeOptions),
                HVACTechnicalReadingDefinition(key: "blower_amps", label: "Blower Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "heat_strip_amps", label: "Heat Strip Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "static_pressure_return", label: "Return Static", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "static_pressure_supply", label: "Supply Static", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "total_external_static", label: "Total External Static", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "blower_wheel_condition", label: "Blower Wheel", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "duct_condition", label: "Duct Condition", unit: nil, options: Self.conditionOptions)
            ]
        case .boiler:
            return [
                HVACTechnicalReadingDefinition(key: "fuel_type", label: "Fuel Type", unit: nil, options: Self.gasFuelOptions),
                HVACTechnicalReadingDefinition(key: "water_temp_supply", label: "Supply Water Temp", unit: "F"),
                HVACTechnicalReadingDefinition(key: "water_temp_return", label: "Return Water Temp", unit: "F"),
                HVACTechnicalReadingDefinition(key: "system_pressure", label: "System Pressure", unit: "psi"),
                HVACTechnicalReadingDefinition(key: "expansion_tank_pressure", label: "Expansion Tank Pressure", unit: "psi"),
                HVACTechnicalReadingDefinition(key: "gas_pressure_inlet", label: "Gas Pressure Inlet", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "gas_pressure_manifold", label: "Gas Pressure Manifold", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "circulator_amps", label: "Circulator Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "relief_valve_status", label: "Relief Valve", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "backflow_preventer_status", label: "Backflow Preventer", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "flue_temp", label: "Flue Temp", unit: "F"),
                HVACTechnicalReadingDefinition(key: "co_ppm", label: "CO Reading", unit: "ppm")
            ]
        case .waterHeater:
            return [
                HVACTechnicalReadingDefinition(key: "fuel_type", label: "Fuel Type", unit: nil, options: Self.gasFuelOptions),
                HVACTechnicalReadingDefinition(key: "water_temp_out", label: "Outlet Water Temp", unit: "F"),
                HVACTechnicalReadingDefinition(key: "incoming_water_temp", label: "Incoming Water Temp", unit: "F"),
                HVACTechnicalReadingDefinition(key: "gas_pressure_inlet", label: "Gas Pressure Inlet", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "gas_pressure_manifold", label: "Gas Pressure Manifold", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "draft_pressure", label: "Draft Pressure", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "venting_type", label: "Venting Type", unit: nil, options: Self.ventingOptions),
                HVACTechnicalReadingDefinition(key: "tank_condition", label: "Tank Condition", unit: nil, options: Self.tankConditionOptions),
                HVACTechnicalReadingDefinition(key: "anode_rod_condition", label: "Anode Rod", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "relief_valve_status", label: "T&P Relief Valve", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "co_ppm", label: "CO Reading", unit: "ppm")
            ]
        case .ventilation:
            return [
                HVACTechnicalReadingDefinition(key: "airflow", label: "Airflow", unit: "CFM"),
                HVACTechnicalReadingDefinition(key: "outside_air_cfm", label: "Outside Air", unit: "CFM"),
                HVACTechnicalReadingDefinition(key: "exhaust_air_cfm", label: "Exhaust Air", unit: "CFM"),
                HVACTechnicalReadingDefinition(key: "motor_amps", label: "Motor Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "line_voltage", label: "Line Voltage", unit: "V"),
                HVACTechnicalReadingDefinition(key: "static_pressure", label: "Static Pressure", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "belt_condition", label: "Belt Condition", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "damper_operation", label: "Damper Operation", unit: nil, options: Self.conditionOptions)
            ]
        case .other:
            return common
        }
    }

    private var coolingCircuitDefinitions: [HVACTechnicalReadingDefinition] {
        [
            HVACTechnicalReadingDefinition(key: "refrigerant_type", label: "Refrigerant Type", unit: nil, options: Self.refrigerantOptions),
            HVACTechnicalReadingDefinition(key: "metering_device", label: "Metering Device", unit: nil, options: Self.meteringDeviceOptions),
            HVACTechnicalReadingDefinition(key: "outdoor_ambient_temp", label: "Outdoor Ambient", unit: "F"),
            HVACTechnicalReadingDefinition(key: "indoor_wet_bulb", label: "Indoor Wet Bulb", unit: "F"),
            HVACTechnicalReadingDefinition(key: "indoor_dry_bulb", label: "Indoor Dry Bulb", unit: "F"),
            HVACTechnicalReadingDefinition(key: "suction_pressure", label: "Suction Pressure", unit: "psig"),
            HVACTechnicalReadingDefinition(key: "liquid_pressure", label: "Liquid Pressure", unit: "psig"),
            HVACTechnicalReadingDefinition(key: "suction_saturation_temp", label: "Suction Saturation Temp", unit: "F"),
            HVACTechnicalReadingDefinition(key: "liquid_saturation_temp", label: "Liquid Saturation Temp", unit: "F"),
            HVACTechnicalReadingDefinition(key: "suction_line_temp", label: "Suction Line Temp", unit: "F"),
            HVACTechnicalReadingDefinition(key: "liquid_line_temp", label: "Liquid Line Temp", unit: "F"),
            HVACTechnicalReadingDefinition(key: "target_superheat", label: "Target Superheat", unit: "F"),
            HVACTechnicalReadingDefinition(key: "superheat", label: "Superheat", unit: "F"),
            HVACTechnicalReadingDefinition(key: "target_subcooling", label: "Target Subcooling", unit: "F"),
            HVACTechnicalReadingDefinition(key: "subcooling", label: "Subcooling", unit: "F"),
            HVACTechnicalReadingDefinition(key: "compressor_amps", label: "Compressor Amps", unit: "A"),
            HVACTechnicalReadingDefinition(key: "outdoor_fan_amps", label: "Outdoor Fan Amps", unit: "A"),
            HVACTechnicalReadingDefinition(key: "capacitor_rating", label: "Capacitor Rating", unit: "uF"),
            HVACTechnicalReadingDefinition(key: "capacitor_actual", label: "Capacitor Actual", unit: "uF"),
            HVACTechnicalReadingDefinition(key: "contactor_condition", label: "Contactor Condition", unit: nil, options: Self.conditionOptions)
        ]
    }
}

struct HVACTechnicalReadingDefinition: Identifiable, Hashable {
    let key: String
    let label: String
    let unit: String?
    let options: [String]

    init(key: String, label: String, unit: String? = nil, options: [String] = []) {
        self.key = key
        self.label = label
        self.unit = unit
        self.options = options
    }

    var id: String { key }
    var displayLabel: String {
        if let unit, !unit.isEmpty {
            return "\(label) (\(unit))"
        }
        return label
    }
}

struct HVACTechnicalReadingGroup: Identifiable, Hashable {
    let title: String
    let definitions: [HVACTechnicalReadingDefinition]

    var id: String { title }
}

@Model
final class ServiceCall {
    @Attribute(.unique) var id: UUID
    var googleCalendarID: String?
    var googleEventID: String?
    var googleEventManagedByApp: Bool = false
    var eventTitle: String?
    var siteAddress: String?
    var equipmentName: String?
    var equipmentManufacturer: String?
    var equipmentModel: String?
    var equipmentSerialNumber: String?
    var equipmentLocation: String?
    var equipmentInstallDate: Date?
    var equipmentWarrantyExpiration: Date?
    var customerEquipmentID: UUID?
    var equipmentTypeRaw: String?
    var serviceReportReadingsJSON: String?
    var filterSize: String?
    var filterCondition: String?
    var indoorCoilCondition: String?
    var outdoorCoilCondition: String?
    var drainLineCondition: String?
    var thermostatOperation: String?
    var serviceReportSummary: String?
    var type: ServiceCallType
    var scheduledDate: Date
    var duration: TimeInterval
    var assignedTechnician: Technician?
    var customer: Customer
    var status: JobStatus
    var notes: String?
    var findingsSummary: String?
    var recommendedWorkSummary: String?
    var followUpRequired: Bool
    var followUpAction: String?
    var followUpDueDate: Date?
    var diagnosticsCaptured: Bool
    var quoteReviewedWithCustomer: Bool
    var equipmentVerifiedChecklist: Bool
    var startupChecklistComplete: Bool
    var maintenanceChecklistComplete: Bool
    var safetyChecklistComplete: Bool
    var customerNotified: Bool
    var arrivalConfirmed: Bool
    var workCompletedChecklist: Bool
    var documentationChecklist: Bool
    var paymentCollectedChecklist: Bool
    var beforePhotoCount: Int
    var afterPhotoCount: Int
    var documentationStartedAt: Date?
    var documentationCompletedAt: Date?
    var linkedEstimateID: UUID?
    var linkedInvoiceID: UUID?
    
    init(
        id: UUID = UUID(),
        googleCalendarID: String? = nil,
        googleEventID: String? = nil,
        googleEventManagedByApp: Bool = false,
        eventTitle: String? = nil,
        siteAddress: String? = nil,
        equipmentName: String? = nil,
        equipmentManufacturer: String? = nil,
        equipmentModel: String? = nil,
        equipmentSerialNumber: String? = nil,
        equipmentLocation: String? = nil,
        equipmentInstallDate: Date? = nil,
        equipmentWarrantyExpiration: Date? = nil,
        customerEquipmentID: UUID? = nil,
        equipmentTypeRaw: String? = nil,
        serviceReportReadingsJSON: String? = nil,
        filterSize: String? = nil,
        filterCondition: String? = nil,
        indoorCoilCondition: String? = nil,
        outdoorCoilCondition: String? = nil,
        drainLineCondition: String? = nil,
        thermostatOperation: String? = nil,
        serviceReportSummary: String? = nil,
        type: ServiceCallType,
        scheduledDate: Date,
        duration: TimeInterval = 3600,
        assignedTechnician: Technician? = nil,
        customer: Customer,
        status: JobStatus = .scheduled,
        notes: String? = nil,
        findingsSummary: String? = nil,
        recommendedWorkSummary: String? = nil,
        followUpRequired: Bool = false,
        followUpAction: String? = nil,
        followUpDueDate: Date? = nil,
        diagnosticsCaptured: Bool = false,
        quoteReviewedWithCustomer: Bool = false,
        equipmentVerifiedChecklist: Bool = false,
        startupChecklistComplete: Bool = false,
        maintenanceChecklistComplete: Bool = false,
        safetyChecklistComplete: Bool = false,
        customerNotified: Bool = false,
        arrivalConfirmed: Bool = false,
        workCompletedChecklist: Bool = false,
        documentationChecklist: Bool = false,
        paymentCollectedChecklist: Bool = false,
        beforePhotoCount: Int = 0,
        afterPhotoCount: Int = 0,
        documentationStartedAt: Date? = nil,
        documentationCompletedAt: Date? = nil,
        linkedEstimateID: UUID? = nil,
        linkedInvoiceID: UUID? = nil
    ) {
        self.id = id
        self.googleCalendarID = googleCalendarID
        self.googleEventID = googleEventID
        self.googleEventManagedByApp = googleEventManagedByApp
        self.eventTitle = eventTitle
        self.siteAddress = siteAddress
        self.equipmentName = equipmentName
        self.equipmentManufacturer = equipmentManufacturer
        self.equipmentModel = equipmentModel
        self.equipmentSerialNumber = equipmentSerialNumber
        self.equipmentLocation = equipmentLocation
        self.equipmentInstallDate = equipmentInstallDate
        self.equipmentWarrantyExpiration = equipmentWarrantyExpiration
        self.customerEquipmentID = customerEquipmentID
        self.equipmentTypeRaw = equipmentTypeRaw
        self.serviceReportReadingsJSON = serviceReportReadingsJSON
        self.filterSize = filterSize
        self.filterCondition = filterCondition
        self.indoorCoilCondition = indoorCoilCondition
        self.outdoorCoilCondition = outdoorCoilCondition
        self.drainLineCondition = drainLineCondition
        self.thermostatOperation = thermostatOperation
        self.serviceReportSummary = serviceReportSummary
        self.type = type
        self.scheduledDate = scheduledDate
        self.duration = duration
        self.assignedTechnician = assignedTechnician
        self.customer = customer
        self.status = status
        self.notes = notes
        self.findingsSummary = findingsSummary
        self.recommendedWorkSummary = recommendedWorkSummary
        self.followUpRequired = followUpRequired
        self.followUpAction = followUpAction
        self.followUpDueDate = followUpDueDate
        self.diagnosticsCaptured = diagnosticsCaptured
        self.quoteReviewedWithCustomer = quoteReviewedWithCustomer
        self.equipmentVerifiedChecklist = equipmentVerifiedChecklist
        self.startupChecklistComplete = startupChecklistComplete
        self.maintenanceChecklistComplete = maintenanceChecklistComplete
        self.safetyChecklistComplete = safetyChecklistComplete
        self.customerNotified = customerNotified
        self.arrivalConfirmed = arrivalConfirmed
        self.workCompletedChecklist = workCompletedChecklist
        self.documentationChecklist = documentationChecklist
        self.paymentCollectedChecklist = paymentCollectedChecklist
        self.beforePhotoCount = beforePhotoCount
        self.afterPhotoCount = afterPhotoCount
        self.documentationStartedAt = documentationStartedAt
        self.documentationCompletedAt = documentationCompletedAt
        self.linkedEstimateID = linkedEstimateID
        self.linkedInvoiceID = linkedInvoiceID
    }
    
    var isUpcomingThisWeek: Bool {
        let now = Date()
        let oneWeekLater = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        return scheduledDate >= now && scheduledDate <= oneWeekLater
    }

    var checklistCompletedCount: Int {
        [customerNotified, arrivalConfirmed, workCompletedChecklist, documentationChecklist, paymentCollectedChecklist]
            .filter { $0 }
            .count
    }

    var checklistTotalCount: Int { 5 }

    var isExternallyLinked: Bool {
        googleEventID != nil || googleCalendarID != nil || linkedEstimateID != nil || linkedInvoiceID != nil
    }

    var equipmentSummary: String? {
        let decoratedParts: [String] = [
            equipmentType?.displayName,
            equipmentName?.trimmingCharacters(in: .whitespacesAndNewlines),
            equipmentManufacturer?.trimmingCharacters(in: .whitespacesAndNewlines),
            equipmentModel?.trimmingCharacters(in: .whitespacesAndNewlines),
            equipmentSerialNumber.flatMap { serial -> String? in
                let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : "S/N \(trimmed)"
            }
        ].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }

        guard !decoratedParts.isEmpty else { return nil }
        return decoratedParts.joined(separator: " • ")
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

    var technicalReadingDefinitions: [HVACTechnicalReadingDefinition] {
        (equipmentType ?? .splitSystemAC).readingDefinitions
    }

    var groupedTechnicalReadingDefinitions: [HVACTechnicalReadingGroup] {
        Self.groupedTechnicalReadingDefinitions(for: technicalReadingDefinitions)
    }

    static func groupedTechnicalReadingDefinitions(
        for definitions: [HVACTechnicalReadingDefinition]
    ) -> [HVACTechnicalReadingGroup] {
        let groupOrder = [
            "Air Temperatures",
            "Refrigerant Circuit",
            "Electrical",
            "Airflow & Static",
            "Combustion",
            "Hydronics",
            "Controls & Safeties",
            "Conditions",
            "General"
        ]
        var grouped: [String: [HVACTechnicalReadingDefinition]] = [:]
        for definition in definitions {
            grouped[technicalReadingGroupTitle(for: definition.key), default: []].append(definition)
        }
        return groupOrder.compactMap { title in
            guard let definitions = grouped[title], !definitions.isEmpty else { return nil }
            return HVACTechnicalReadingGroup(title: title, definitions: definitions)
        }
    }

    private static func technicalReadingGroupTitle(for key: String) -> String {
        if key.contains("refrigerant") ||
            key.contains("suction") ||
            key.contains("liquid") ||
            key.contains("superheat") ||
            key.contains("subcooling") ||
            key.contains("metering") {
            return "Refrigerant Circuit"
        }
        if key.contains("voltage") ||
            key.contains("amps") ||
            key.contains("capacitor") ||
            key.contains("contactor") ||
            key.contains("communication") ||
            key.contains("motor") ||
            key.contains("flame_sensor") {
            return "Electrical"
        }
        if key.contains("airflow") ||
            key.contains("cfm") ||
            key.contains("static") ||
            key.contains("blower") ||
            key.contains("duct") ||
            key.contains("belt") ||
            key.contains("damper") {
            return "Airflow & Static"
        }
        if key.contains("fuel") ||
            key.contains("ignition") ||
            key.contains("venting") ||
            key.contains("gas_pressure") ||
            key.contains("draft") ||
            key.contains("flue") ||
            key.contains("o2") ||
            key.contains("co2") ||
            key.contains("co_ppm") {
            return "Combustion"
        }
        if key.contains("water") ||
            key.contains("system_pressure") ||
            key.contains("expansion") ||
            key.contains("circulator") ||
            key.contains("relief") ||
            key.contains("backflow") ||
            key.contains("tank") ||
            key.contains("anode") {
            return "Hydronics"
        }
        if key.contains("temp") || key.contains("temperature") || key.contains("wet_bulb") || key.contains("dry_bulb") {
            return "Air Temperatures"
        }
        if key.contains("mode") ||
            key.contains("reversing") ||
            key.contains("defrost") ||
            key.contains("economizer") ||
            key.contains("condensate") ||
            key.contains("remote") ||
            key.contains("limit_switch") {
            return "Controls & Safeties"
        }
        if key.contains("condition") ||
            key.contains("coil") ||
            key.contains("heat_exchanger") {
            return "Conditions"
        }
        return "General"
    }

    var technicalReadings: [String: String] {
        guard let serviceReportReadingsJSON,
              let data = serviceReportReadingsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    func technicalReading(for key: String) -> String {
        technicalReadings[key] ?? ""
    }

    func setTechnicalReading(_ value: String, for key: String) {
        var readings = technicalReadings
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            readings.removeValue(forKey: key)
        } else {
            readings[key] = trimmed
            diagnosticsCaptured = true
        }
        if readings.isEmpty {
            serviceReportReadingsJSON = nil
        } else if let data = try? JSONEncoder().encode(readings),
                  let encoded = String(data: data, encoding: .utf8) {
            serviceReportReadingsJSON = encoded
        }
    }

    func calculateTemperatureSplitReading() -> Double? {
        guard let returnTemp = numericTechnicalReading(for: "return_air_temp"),
              let supplyTemp = numericTechnicalReading(for: "supply_air_temp") else {
            return nil
        }
        let split = abs(returnTemp - supplyTemp)
        setTechnicalReading(Self.formattedTechnicalReading(split), for: "temperature_split")
        return split
    }

    func calculateSuperheatReading() -> Double? {
        guard let suctionLineTemp = numericTechnicalReading(for: "suction_line_temp"),
              let suctionSaturationTemp = numericTechnicalReading(for: "suction_saturation_temp") else {
            return nil
        }
        let superheat = suctionLineTemp - suctionSaturationTemp
        setTechnicalReading(Self.formattedTechnicalReading(superheat), for: "superheat")
        return superheat
    }

    func calculateSubcoolingReading() -> Double? {
        guard let liquidLineTemp = numericTechnicalReading(for: "liquid_line_temp"),
              let liquidSaturationTemp = numericTechnicalReading(for: "liquid_saturation_temp") else {
            return nil
        }
        let subcooling = liquidSaturationTemp - liquidLineTemp
        setTechnicalReading(Self.formattedTechnicalReading(subcooling), for: "subcooling")
        return subcooling
    }

    func calculateTotalExternalStaticReading() -> Double? {
        guard let returnStatic = numericTechnicalReading(for: "static_pressure_return"),
              let supplyStatic = numericTechnicalReading(for: "static_pressure_supply") else {
            return nil
        }
        let totalExternalStatic = abs(returnStatic) + abs(supplyStatic)
        setTechnicalReading(Self.formattedTechnicalReading(totalExternalStatic), for: "total_external_static")
        return totalExternalStatic
    }

    private func numericTechnicalReading(for key: String) -> Double? {
        Double(technicalReading(for: key).replacingOccurrences(of: ",", with: "."))
    }

    private static func formattedTechnicalReading(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    var populatedTechnicalReadingRows: [(label: String, value: String)] {
        technicalReadingDefinitions.compactMap { definition in
            let value = technicalReading(for: definition.key).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return (definition.displayLabel, value)
        }
    }

    var workflowChecklistCompletedCount: Int {
        workflowChecklistValues.filter { $0 }.count
    }

    var workflowChecklistTotalCount: Int {
        workflowChecklistValues.count
    }

    private var workflowChecklistValues: [Bool] {
        switch type {
        case .service:
            return [diagnosticsCaptured, recommendedWorkSummary != nil, safetyChecklistComplete]
        case .estimate:
            return [quoteReviewedWithCustomer, recommendedWorkSummary != nil, followUpRequired]
        case .install:
            return [equipmentVerifiedChecklist, startupChecklistComplete, safetyChecklistComplete]
        case .maintenance:
            return [maintenanceChecklistComplete, safetyChecklistComplete, customerNotified]
        case .meeting, .reminder, .siteVisit, .other:
            return [arrivalConfirmed, workCompletedChecklist, documentationChecklist]
        }
    }
}
