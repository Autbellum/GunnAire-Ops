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

    var readingDefinitions: [HVACTechnicalReadingDefinition] {
        let common = [
            HVACTechnicalReadingDefinition(key: "return_air_temp", label: "Return Air Temp", unit: "F"),
            HVACTechnicalReadingDefinition(key: "supply_air_temp", label: "Supply Air Temp", unit: "F"),
            HVACTechnicalReadingDefinition(key: "temperature_split", label: "Temperature Split", unit: "F"),
            HVACTechnicalReadingDefinition(key: "line_voltage", label: "Line Voltage", unit: "V"),
            HVACTechnicalReadingDefinition(key: "control_voltage", label: "Control Voltage", unit: "V")
        ]

        switch self {
        case .splitSystemAC, .heatPump, .packageUnit, .miniSplit:
            return common + [
                HVACTechnicalReadingDefinition(key: "refrigerant_type", label: "Refrigerant Type", unit: nil),
                HVACTechnicalReadingDefinition(key: "suction_pressure", label: "Suction Pressure", unit: "psig"),
                HVACTechnicalReadingDefinition(key: "liquid_pressure", label: "Liquid Pressure", unit: "psig"),
                HVACTechnicalReadingDefinition(key: "superheat", label: "Superheat", unit: "F"),
                HVACTechnicalReadingDefinition(key: "subcooling", label: "Subcooling", unit: "F"),
                HVACTechnicalReadingDefinition(key: "compressor_amps", label: "Compressor Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "outdoor_fan_amps", label: "Outdoor Fan Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "capacitor_rating", label: "Capacitor Rating", unit: "uF"),
                HVACTechnicalReadingDefinition(key: "capacitor_actual", label: "Capacitor Actual", unit: "uF")
            ]
        case .gasFurnace:
            return common + [
                HVACTechnicalReadingDefinition(key: "gas_pressure_inlet", label: "Gas Pressure Inlet", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "gas_pressure_manifold", label: "Gas Pressure Manifold", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "flame_sensor_microamps", label: "Flame Sensor", unit: "uA"),
                HVACTechnicalReadingDefinition(key: "inducer_amps", label: "Inducer Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "blower_amps", label: "Blower Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "temperature_rise", label: "Temperature Rise", unit: "F"),
                HVACTechnicalReadingDefinition(key: "co_ppm", label: "CO Reading", unit: "ppm")
            ]
        case .airHandler:
            return common + [
                HVACTechnicalReadingDefinition(key: "blower_amps", label: "Blower Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "heat_strip_amps", label: "Heat Strip Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "static_pressure_return", label: "Return Static", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "static_pressure_supply", label: "Supply Static", unit: "in. w.c.")
            ]
        case .boiler, .waterHeater:
            return [
                HVACTechnicalReadingDefinition(key: "water_temp_in", label: "Water Temp In", unit: "F"),
                HVACTechnicalReadingDefinition(key: "water_temp_out", label: "Water Temp Out", unit: "F"),
                HVACTechnicalReadingDefinition(key: "system_pressure", label: "System Pressure", unit: "psi"),
                HVACTechnicalReadingDefinition(key: "gas_pressure_inlet", label: "Gas Pressure Inlet", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "gas_pressure_manifold", label: "Gas Pressure Manifold", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "co_ppm", label: "CO Reading", unit: "ppm")
            ]
        case .ventilation:
            return [
                HVACTechnicalReadingDefinition(key: "airflow", label: "Airflow", unit: "CFM"),
                HVACTechnicalReadingDefinition(key: "motor_amps", label: "Motor Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "line_voltage", label: "Line Voltage", unit: "V"),
                HVACTechnicalReadingDefinition(key: "static_pressure", label: "Static Pressure", unit: "in. w.c.")
            ]
        case .other:
            return common
        }
    }
}

struct HVACTechnicalReadingDefinition: Identifiable, Hashable {
    let key: String
    let label: String
    let unit: String?

    var id: String { key }
    var displayLabel: String {
        if let unit, !unit.isEmpty {
            return "\(label) (\(unit))"
        }
        return label
    }
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
    var equipmentModel: String?
    var equipmentSerialNumber: String?
    var equipmentWarrantyExpiration: Date?
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
        equipmentModel: String? = nil,
        equipmentSerialNumber: String? = nil,
        equipmentWarrantyExpiration: Date? = nil,
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
        self.equipmentModel = equipmentModel
        self.equipmentSerialNumber = equipmentSerialNumber
        self.equipmentWarrantyExpiration = equipmentWarrantyExpiration
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
