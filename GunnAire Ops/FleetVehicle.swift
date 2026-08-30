import Foundation
import SwiftData

enum FleetVehicleAdministrativeStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case inService = "in_service"
    case outOfService = "out_of_service"
    case retired

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inService: "In Service"
        case .outOfService: "Out of Service"
        case .retired: "Retired"
        }
    }
}

enum FleetVehicleEventKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case created
    case assignmentChanged = "assignment_changed"
    case inspectionCompleted = "inspection_completed"
    case serviceLogged = "service_logged"
    case statusChanged = "status_changed"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .created: "Vehicle Added"
        case .assignmentChanged: "Assignment Changed"
        case .inspectionCompleted: "Inspection Completed"
        case .serviceLogged: "Service Logged"
        case .statusChanged: "Status Changed"
        }
    }
}

enum FleetInspectionItem: String, Codable, CaseIterable, Identifiable, Sendable {
    case tiresAndWheels = "tires_wheels"
    case brakesAndSteering = "brakes_steering"
    case lightsAndSignals = "lights_signals"
    case fluidsAndLeaks = "fluids_leaks"
    case windshieldAndBody = "windshield_body"
    case safetyEquipment = "safety_equipment"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiresAndWheels: "Tires & Wheels"
        case .brakesAndSteering: "Brakes & Steering"
        case .lightsAndSignals: "Lights & Signals"
        case .fluidsAndLeaks: "Fluids & Leaks"
        case .windshieldAndBody: "Windshield & Body"
        case .safetyEquipment: "Safety Equipment"
        }
    }
}

enum FleetServiceCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case preventiveMaintenance = "preventive_maintenance"
    case repair
    case tires
    case inspection
    case registration
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preventiveMaintenance: "Preventive Maintenance"
        case .repair: "Repair"
        case .tires: "Tires"
        case .inspection: "State / Safety Inspection"
        case .registration: "Registration"
        case .other: "Other"
        }
    }
}

struct FleetInspectionResult: Codable, Equatable, Sendable {
    let item: FleetInspectionItem
    let passed: Bool
}

struct FleetVehicleReadiness: Equatable, Sendable {
    let administrativeStatus: FleetVehicleAdministrativeStatus
    let inspectionDue: Bool
    let serviceDue: Bool

    var needsAttention: Bool {
        administrativeStatus != .inService || inspectionDue || serviceDue
    }

    var isDispatchReady: Bool {
        administrativeStatus == .inService && !inspectionDue && !serviceDue
    }

    var title: String {
        switch administrativeStatus {
        case .retired: return "Retired"
        case .outOfService: return "Out of Service"
        case .inService:
            if inspectionDue && serviceDue { return "Inspection & Service Due" }
            if inspectionDue { return "Inspection Due" }
            if serviceDue { return "Service Due" }
            return "Ready"
        }
    }
}

@Model
final class FleetVehicle {
    var id: UUID = UUID()
    var unitNumber: String = ""
    var vin: String?
    var licensePlate: String?
    var vehicleYear: Int?
    var make: String?
    var model: String?
    var stockLocation: String = ""
    var assignedTechnicianID: UUID?
    var assignedTechnicianName: String?
    var administrativeStatusRaw: String = FleetVehicleAdministrativeStatus.inService.rawValue
    var odometer: Double?
    var odometerUpdatedAt: Date?
    var latestInspectionAt: Date?
    var nextInspectionDueAt: Date?
    var nextServiceDueAt: Date?
    var nextServiceDueOdometer: Double?
    var notes: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var updatedByEmail: String?

    init(
        id: UUID = UUID(),
        unitNumber: String,
        vin: String? = nil,
        licensePlate: String? = nil,
        vehicleYear: Int? = nil,
        make: String? = nil,
        model: String? = nil,
        stockLocation: String,
        assignedTechnicianID: UUID? = nil,
        assignedTechnicianName: String? = nil,
        administrativeStatus: FleetVehicleAdministrativeStatus = .inService,
        odometer: Double? = nil,
        odometerUpdatedAt: Date? = nil,
        latestInspectionAt: Date? = nil,
        nextInspectionDueAt: Date? = nil,
        nextServiceDueAt: Date? = nil,
        nextServiceDueOdometer: Double? = nil,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        updatedByEmail: String? = nil
    ) {
        self.id = id
        self.unitNumber = unitNumber
        self.vin = vin
        self.licensePlate = licensePlate
        self.vehicleYear = vehicleYear
        self.make = make
        self.model = model
        self.stockLocation = stockLocation
        self.assignedTechnicianID = assignedTechnicianID
        self.assignedTechnicianName = assignedTechnicianName
        self.administrativeStatusRaw = administrativeStatus.rawValue
        self.odometer = odometer
        self.odometerUpdatedAt = odometerUpdatedAt
        self.latestInspectionAt = latestInspectionAt
        self.nextInspectionDueAt = nextInspectionDueAt
        self.nextServiceDueAt = nextServiceDueAt
        self.nextServiceDueOdometer = nextServiceDueOdometer
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedByEmail = updatedByEmail
    }

    var administrativeStatus: FleetVehicleAdministrativeStatus {
        get { FleetVehicleAdministrativeStatus(rawValue: administrativeStatusRaw) ?? .outOfService }
        set { administrativeStatusRaw = newValue.rawValue }
    }

    var displayName: String {
        let description = [vehicleYear.map(String.init), make, model]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return description.isEmpty ? unitNumber : "\(unitNumber) • \(description)"
    }

    func readiness(asOf date: Date = Date(), calendar: Calendar = .current) -> FleetVehicleReadiness {
        let today = calendar.startOfDay(for: date)
        let inspectionDue = nextInspectionDueAt.map { calendar.startOfDay(for: $0) <= today } ?? true
        let dateServiceDue = nextServiceDueAt.map { calendar.startOfDay(for: $0) <= today } ?? false
        let mileageServiceDue: Bool
        if let odometer, let nextServiceDueOdometer {
            mileageServiceDue = odometer >= nextServiceDueOdometer
        } else {
            mileageServiceDue = false
        }
        return FleetVehicleReadiness(
            administrativeStatus: administrativeStatus,
            inspectionDue: inspectionDue,
            serviceDue: dateServiceDue || mileageServiceDue
        )
    }
}

@Model
final class FleetVehicleEvent {
    var id: UUID = UUID()
    var vehicleID: UUID = UUID()
    var vehicleUnitNumber: String = ""
    var kindRaw: String = FleetVehicleEventKind.created.rawValue
    var occurredAt: Date = Date()
    var actorEmail: String = ""
    var detail: String = ""
    var odometer: Double?
    var inspectionResultsJSON: String?
    var failedInspectionItemsRaw: String?
    var serviceCategoryRaw: String?
    var serviceCost: Double?
    var serviceCenter: String?
    var invoiceNumber: String?
    var assignmentTechnicianID: UUID?
    var assignmentTechnicianName: String?
    var priorStatusRaw: String?
    var newStatusRaw: String?
    var resolvesOutOfService: Bool?

    init(
        id: UUID = UUID(),
        vehicleID: UUID,
        vehicleUnitNumber: String,
        kind: FleetVehicleEventKind,
        occurredAt: Date = Date(),
        actorEmail: String,
        detail: String,
        odometer: Double? = nil,
        inspectionResults: [FleetInspectionResult]? = nil,
        serviceCategory: FleetServiceCategory? = nil,
        serviceCost: Double? = nil,
        serviceCenter: String? = nil,
        invoiceNumber: String? = nil,
        assignmentTechnicianID: UUID? = nil,
        assignmentTechnicianName: String? = nil,
        priorStatus: FleetVehicleAdministrativeStatus? = nil,
        newStatus: FleetVehicleAdministrativeStatus? = nil,
        resolvesOutOfService: Bool? = nil
    ) {
        self.id = id
        self.vehicleID = vehicleID
        self.vehicleUnitNumber = vehicleUnitNumber
        self.kindRaw = kind.rawValue
        self.occurredAt = occurredAt
        self.actorEmail = actorEmail
        self.detail = detail
        self.odometer = odometer
        self.inspectionResultsJSON = Self.encodeInspectionResults(inspectionResults)
        self.failedInspectionItemsRaw = inspectionResults?
            .filter { !$0.passed }
            .map { $0.item.rawValue }
            .sorted()
            .joined(separator: "\n")
        self.serviceCategoryRaw = serviceCategory?.rawValue
        self.serviceCost = serviceCost
        self.serviceCenter = serviceCenter
        self.invoiceNumber = invoiceNumber
        self.assignmentTechnicianID = assignmentTechnicianID
        self.assignmentTechnicianName = assignmentTechnicianName
        self.priorStatusRaw = priorStatus?.rawValue
        self.newStatusRaw = newStatus?.rawValue
        self.resolvesOutOfService = resolvesOutOfService
    }

    var kind: FleetVehicleEventKind {
        FleetVehicleEventKind(rawValue: kindRaw) ?? .statusChanged
    }

    var serviceCategory: FleetServiceCategory? {
        serviceCategoryRaw.flatMap(FleetServiceCategory.init(rawValue:))
    }

    var inspectionResults: [FleetInspectionResult] {
        guard let inspectionResultsJSON,
              let data = inspectionResultsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([FleetInspectionResult].self, from: data)) ?? []
    }

    var failedInspectionItems: [FleetInspectionItem] {
        failedInspectionItemsRaw?
            .split(separator: "\n")
            .compactMap { FleetInspectionItem(rawValue: String($0)) } ?? []
    }

    private static func encodeInspectionResults(_ values: [FleetInspectionResult]?) -> String? {
        guard let values, !values.isEmpty,
              let data = try? JSONEncoder().encode(values) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum FleetVehiclePolicyError: Error, Equatable, LocalizedError {
    case administratorRequired
    case fleetManagerRequired
    case serviceRecorderRequired
    case actorRequired
    case unitNumberRequired
    case duplicateUnitNumber
    case invalidVIN
    case duplicateVIN
    case invalidYear
    case stockLocationRequired
    case invalidOdometer
    case invalidServiceCost
    case odometerWentBackward
    case invalidServiceInterval
    case technicianAlreadyAssigned
    case assignedVehicleRequired
    case retiredVehicle
    case inspectionIncomplete
    case inspectionFailureNoteRequired
    case passingInspectionRequired
    case vehicleNotOutOfService
    case serviceDetailRequired
    case fieldCostRestricted
    case detailRequired
    case detailTooLong

    var errorDescription: String? {
        switch self {
        case .administratorRequired: "Only an administrator can add, retire, or return a fleet vehicle to service."
        case .fleetManagerRequired: "Only Dispatch or an administrator can change a fleet assignment or operating status."
        case .serviceRecorderRequired: "This role cannot record service for this vehicle."
        case .actorRequired: "Sign in with an approved business account before changing fleet records."
        case .unitNumberRequired: "Enter a truck or vehicle unit number."
        case .duplicateUnitNumber: "That fleet unit number is already in use."
        case .invalidVIN: "Enter a valid 11- to 17-character VIN, or leave it blank."
        case .duplicateVIN: "That VIN is already assigned to another fleet vehicle."
        case .invalidYear: "Enter a vehicle year from 1980 through two years from now."
        case .stockLocationRequired: "Enter the matching truck inventory location."
        case .invalidOdometer: "Enter an odometer from 0 through 2,000,000 miles."
        case .invalidServiceCost: "Enter a service cost from 0 through 1,000,000 dollars."
        case .odometerWentBackward: "The new odometer cannot be lower than the retained reading."
        case .invalidServiceInterval: "The next service mileage must be greater than the current odometer."
        case .technicianAlreadyAssigned: "That technician already has another active fleet vehicle."
        case .assignedVehicleRequired: "A field technician can record only the vehicle assigned to their account."
        case .retiredVehicle: "A retired vehicle cannot receive new inspections, service, or assignments."
        case .inspectionIncomplete: "Record Pass or Fail for every inspection item."
        case .inspectionFailureNoteRequired: "Describe the defect before taking the vehicle out of service."
        case .passingInspectionRequired: "Record a complete passing inspection after the latest failure before returning this vehicle to service."
        case .vehicleNotOutOfService: "Only an out-of-service vehicle can be returned to service."
        case .serviceDetailRequired: "Enter the service performed."
        case .fieldCostRestricted: "Only Accounting or an administrator can record fleet service cost."
        case .detailRequired: "Enter a reason for this fleet change."
        case .detailTooLong: "Keep fleet notes and reasons to 500 characters or fewer."
        }
    }
}

enum FleetVehiclePolicy {
    static func createVehicle(
        unitNumber: String,
        vin: String?,
        licensePlate: String?,
        vehicleYear: Int?,
        make: String?,
        model: String?,
        stockLocation: String,
        odometer: Double?,
        nextInspectionDueAt: Date,
        nextServiceDueAt: Date?,
        nextServiceDueOdometer: Double?,
        notes: String?,
        existingVehicles: [FleetVehicle],
        actorEmail: String?,
        role: AppUserRole?,
        now: Date = Date()
    ) throws -> (FleetVehicle, FleetVehicleEvent) {
        guard role == .admin else { throw FleetVehiclePolicyError.administratorRequired }
        let actor = try normalizedActor(actorEmail)
        let unit = normalized(unitNumber)
        guard !unit.isEmpty else { throw FleetVehiclePolicyError.unitNumberRequired }
        guard !existingVehicles.contains(where: { $0.unitNumber.caseInsensitiveCompare(unit) == .orderedSame }) else {
            throw FleetVehiclePolicyError.duplicateUnitNumber
        }
        let normalizedVIN = normalized(vin).uppercased()
        if !normalizedVIN.isEmpty {
            let allowed = CharacterSet.alphanumerics.subtracting(CharacterSet(charactersIn: "IOQ"))
            guard (11...17).contains(normalizedVIN.count),
                  normalizedVIN.unicodeScalars.allSatisfy(allowed.contains) else {
                throw FleetVehiclePolicyError.invalidVIN
            }
            guard !existingVehicles.contains(where: { normalized($0.vin).uppercased() == normalizedVIN }) else {
                throw FleetVehiclePolicyError.duplicateVIN
            }
        }
        if let vehicleYear {
            let currentYear = Calendar.current.component(.year, from: now)
            guard (1980...(currentYear + 2)).contains(vehicleYear) else {
                throw FleetVehiclePolicyError.invalidYear
            }
        }
        let location = normalized(stockLocation)
        guard !location.isEmpty else { throw FleetVehiclePolicyError.stockLocationRequired }
        try validateOdometer(odometer)
        try validateServiceInterval(nextServiceDueOdometer, after: odometer)
        let cleanNotes = try boundedDetail(notes, required: false)
        let vehicle = FleetVehicle(
            unitNumber: unit,
            vin: normalizedVIN.nilIfEmpty,
            licensePlate: normalized(licensePlate).uppercased().nilIfEmpty,
            vehicleYear: vehicleYear,
            make: normalized(make).nilIfEmpty,
            model: normalized(model).nilIfEmpty,
            stockLocation: location,
            odometer: odometer,
            odometerUpdatedAt: odometer == nil ? nil : now,
            nextInspectionDueAt: nextInspectionDueAt,
            nextServiceDueAt: nextServiceDueAt,
            nextServiceDueOdometer: nextServiceDueOdometer,
            notes: cleanNotes,
            createdAt: now,
            updatedAt: now,
            updatedByEmail: actor
        )
        let event = FleetVehicleEvent(
            vehicleID: vehicle.id,
            vehicleUnitNumber: unit,
            kind: .created,
            occurredAt: now,
            actorEmail: actor,
            detail: "Added \(unit) with inventory location \(location).",
            odometer: odometer,
            newStatus: .inService
        )
        return (vehicle, event)
    }

    static func assign(
        _ vehicle: FleetVehicle,
        to technician: Technician?,
        existingVehicles: [FleetVehicle],
        actorEmail: String?,
        role: AppUserRole?,
        now: Date = Date()
    ) throws -> FleetVehicleEvent {
        guard role == .dispatcher || role == .admin else {
            throw FleetVehiclePolicyError.fleetManagerRequired
        }
        guard vehicle.administrativeStatus != .retired else { throw FleetVehiclePolicyError.retiredVehicle }
        let actor = try normalizedActor(actorEmail)
        if let technician {
            guard !existingVehicles.contains(where: {
                $0.id != vehicle.id &&
                    $0.administrativeStatus != .retired &&
                    $0.assignedTechnicianID == technician.id
            }) else { throw FleetVehiclePolicyError.technicianAlreadyAssigned }
        }
        let previous = vehicle.assignedTechnicianName ?? "Unassigned"
        vehicle.assignedTechnicianID = technician?.id
        vehicle.assignedTechnicianName = technician?.name
        vehicle.updatedAt = now
        vehicle.updatedByEmail = actor
        return FleetVehicleEvent(
            vehicleID: vehicle.id,
            vehicleUnitNumber: vehicle.unitNumber,
            kind: .assignmentChanged,
            occurredAt: now,
            actorEmail: actor,
            detail: technician.map { "Reassigned from \(previous) to \($0.name)." } ?? "Cleared assignment from \(previous).",
            assignmentTechnicianID: technician?.id,
            assignmentTechnicianName: technician?.name
        )
    }

    static func recordInspection(
        for vehicle: FleetVehicle,
        results: [FleetInspectionItem: Bool],
        odometer: Double,
        notes: String?,
        nextInspectionDueAt: Date,
        actorEmail: String?,
        role: AppUserRole?,
        actorTechnicianID: UUID?,
        now: Date = Date()
    ) throws -> FleetVehicleEvent {
        guard vehicle.administrativeStatus != .retired else { throw FleetVehiclePolicyError.retiredVehicle }
        guard role == .fieldTechnician || role == .dispatcher || role == .admin else {
            throw FleetVehiclePolicyError.fleetManagerRequired
        }
        if role == .fieldTechnician,
           vehicle.assignedTechnicianID == nil || vehicle.assignedTechnicianID != actorTechnicianID {
            throw FleetVehiclePolicyError.assignedVehicleRequired
        }
        let actor = try normalizedActor(actorEmail)
        guard results.count == FleetInspectionItem.allCases.count,
              FleetInspectionItem.allCases.allSatisfy({ results[$0] != nil }) else {
            throw FleetVehiclePolicyError.inspectionIncomplete
        }
        try validateOdometer(odometer)
        if let current = vehicle.odometer, odometer < current {
            throw FleetVehiclePolicyError.odometerWentBackward
        }
        let failed = FleetInspectionItem.allCases.filter { results[$0] == false }
        let detail: String?
        do {
            detail = try boundedDetail(notes, required: !failed.isEmpty)
        } catch FleetVehiclePolicyError.detailRequired {
            throw FleetVehiclePolicyError.inspectionFailureNoteRequired
        }
        let priorStatus = vehicle.administrativeStatus
        if !failed.isEmpty {
            vehicle.administrativeStatus = .outOfService
        }
        vehicle.odometer = odometer
        vehicle.odometerUpdatedAt = now
        vehicle.latestInspectionAt = now
        vehicle.nextInspectionDueAt = failed.isEmpty ? nextInspectionDueAt : now
        vehicle.updatedAt = now
        vehicle.updatedByEmail = actor
        let inspectionResults = FleetInspectionItem.allCases.map {
            FleetInspectionResult(item: $0, passed: results[$0] == true)
        }
        let eventDetail: String
        if failed.isEmpty {
            eventDetail = detail ?? "All required inspection items passed."
        } else {
            eventDetail = "Failed \(failed.map(\.displayName).joined(separator: ", ")). \(detail ?? "")"
        }
        return FleetVehicleEvent(
            vehicleID: vehicle.id,
            vehicleUnitNumber: vehicle.unitNumber,
            kind: .inspectionCompleted,
            occurredAt: now,
            actorEmail: actor,
            detail: eventDetail,
            odometer: odometer,
            inspectionResults: inspectionResults,
            priorStatus: priorStatus,
            newStatus: vehicle.administrativeStatus
        )
    }

    static func recordService(
        for vehicle: FleetVehicle,
        category: FleetServiceCategory,
        detail: String,
        odometer: Double,
        cost: Double?,
        serviceCenter: String?,
        invoiceNumber: String?,
        nextServiceDueAt: Date?,
        nextServiceDueOdometer: Double?,
        actorEmail: String?,
        role: AppUserRole?,
        actorTechnicianID: UUID?,
        now: Date = Date()
    ) throws -> FleetVehicleEvent {
        guard vehicle.administrativeStatus != .retired else { throw FleetVehiclePolicyError.retiredVehicle }
        guard role == .fieldTechnician || role == .accounting || role == .admin else {
            throw FleetVehiclePolicyError.serviceRecorderRequired
        }
        if role == .fieldTechnician,
           vehicle.assignedTechnicianID == nil || vehicle.assignedTechnicianID != actorTechnicianID {
            throw FleetVehiclePolicyError.assignedVehicleRequired
        }
        if cost != nil, role != .accounting && role != .admin {
            throw FleetVehiclePolicyError.fieldCostRestricted
        }
        let actor = try normalizedActor(actorEmail)
        let serviceDetail = try boundedDetail(detail, required: true) ?? ""
        try validateOdometer(odometer)
        if let current = vehicle.odometer, odometer < current {
            throw FleetVehiclePolicyError.odometerWentBackward
        }
        if let cost, !cost.isFinite || cost < 0 || cost > 1_000_000 {
            throw FleetVehiclePolicyError.invalidServiceCost
        }
        try validateServiceInterval(nextServiceDueOdometer, after: odometer)
        vehicle.odometer = odometer
        vehicle.odometerUpdatedAt = now
        vehicle.nextServiceDueAt = nextServiceDueAt
        vehicle.nextServiceDueOdometer = nextServiceDueOdometer
        vehicle.updatedAt = now
        vehicle.updatedByEmail = actor
        return FleetVehicleEvent(
            vehicleID: vehicle.id,
            vehicleUnitNumber: vehicle.unitNumber,
            kind: .serviceLogged,
            occurredAt: now,
            actorEmail: actor,
            detail: serviceDetail,
            odometer: odometer,
            serviceCategory: category,
            serviceCost: cost,
            serviceCenter: normalized(serviceCenter).nilIfEmpty,
            invoiceNumber: normalized(invoiceNumber).nilIfEmpty
        )
    }

    static func returnToService(
        _ vehicle: FleetVehicle,
        events: [FleetVehicleEvent],
        reason: String,
        actorEmail: String?,
        role: AppUserRole?,
        now: Date = Date()
    ) throws -> FleetVehicleEvent {
        guard role == .admin else { throw FleetVehiclePolicyError.administratorRequired }
        let actor = try normalizedActor(actorEmail)
        let detail = try boundedDetail(reason, required: true) ?? ""
        guard vehicle.administrativeStatus == .outOfService else {
            throw FleetVehiclePolicyError.vehicleNotOutOfService
        }
        let vehicleEvents = events.filter { $0.vehicleID == vehicle.id }
        let latestSafetyHoldAt = vehicleEvents
            .filter { event in
                (event.kind == .inspectionCompleted && !event.failedInspectionItems.isEmpty) ||
                    (event.kind == .statusChanged &&
                        event.newStatusRaw == FleetVehicleAdministrativeStatus.outOfService.rawValue)
            }
            .map(\.occurredAt)
            .max()
        let latestPassingInspectionAt = vehicleEvents
            .filter { event in
                event.kind == .inspectionCompleted &&
                    event.inspectionResults.count == FleetInspectionItem.allCases.count &&
                    event.failedInspectionItems.isEmpty
            }
            .map(\.occurredAt)
            .max()
        guard let latestPassingInspectionAt,
              latestSafetyHoldAt.map({ latestPassingInspectionAt > $0 }) ?? true else {
            throw FleetVehiclePolicyError.passingInspectionRequired
        }
        let priorStatus = vehicle.administrativeStatus
        vehicle.administrativeStatus = .inService
        vehicle.updatedAt = now
        vehicle.updatedByEmail = actor
        return FleetVehicleEvent(
            vehicleID: vehicle.id,
            vehicleUnitNumber: vehicle.unitNumber,
            kind: .statusChanged,
            occurredAt: now,
            actorEmail: actor,
            detail: detail,
            priorStatus: priorStatus,
            newStatus: .inService,
            resolvesOutOfService: true
        )
    }

    static func setOutOfService(
        _ vehicle: FleetVehicle,
        reason: String,
        actorEmail: String?,
        role: AppUserRole?,
        now: Date = Date()
    ) throws -> FleetVehicleEvent {
        guard role == .dispatcher || role == .admin else {
            throw FleetVehiclePolicyError.fleetManagerRequired
        }
        let actor = try normalizedActor(actorEmail)
        let detail = try boundedDetail(reason, required: true) ?? ""
        guard vehicle.administrativeStatus != .retired else { throw FleetVehiclePolicyError.retiredVehicle }
        let priorStatus = vehicle.administrativeStatus
        vehicle.administrativeStatus = .outOfService
        vehicle.updatedAt = now
        vehicle.updatedByEmail = actor
        return FleetVehicleEvent(
            vehicleID: vehicle.id,
            vehicleUnitNumber: vehicle.unitNumber,
            kind: .statusChanged,
            occurredAt: now,
            actorEmail: actor,
            detail: detail,
            priorStatus: priorStatus,
            newStatus: .outOfService
        )
    }

    static func retire(
        _ vehicle: FleetVehicle,
        reason: String,
        actorEmail: String?,
        role: AppUserRole?,
        now: Date = Date()
    ) throws -> FleetVehicleEvent {
        guard role == .admin else { throw FleetVehiclePolicyError.administratorRequired }
        let actor = try normalizedActor(actorEmail)
        let detail = try boundedDetail(reason, required: true) ?? ""
        let priorStatus = vehicle.administrativeStatus
        vehicle.administrativeStatus = .retired
        vehicle.assignedTechnicianID = nil
        vehicle.assignedTechnicianName = nil
        vehicle.updatedAt = now
        vehicle.updatedByEmail = actor
        return FleetVehicleEvent(
            vehicleID: vehicle.id,
            vehicleUnitNumber: vehicle.unitNumber,
            kind: .statusChanged,
            occurredAt: now,
            actorEmail: actor,
            detail: detail,
            priorStatus: priorStatus,
            newStatus: .retired
        )
    }

    private static func normalizedActor(_ value: String?) throws -> String {
        let actor = AppAccess.normalizedEmail(value)
        guard !actor.isEmpty else { throw FleetVehiclePolicyError.actorRequired }
        return actor
    }

    private static func validateOdometer(_ value: Double?) throws {
        guard let value else { return }
        guard value.isFinite, value >= 0, value <= 2_000_000 else {
            throw FleetVehiclePolicyError.invalidOdometer
        }
    }

    private static func validateServiceInterval(_ value: Double?, after odometer: Double?) throws {
        guard let value else { return }
        guard value.isFinite,
              value >= 0,
              value <= 2_000_000,
              odometer.map({ value > $0 }) ?? true else {
            throw FleetVehiclePolicyError.invalidServiceInterval
        }
    }

    private static func boundedDetail(_ value: String?, required: Bool) throws -> String? {
        let value = normalized(value)
        if required && value.isEmpty { throw FleetVehiclePolicyError.detailRequired }
        guard value.count <= 500 else { throw FleetVehiclePolicyError.detailTooLong }
        return value.nilIfEmpty
    }

    private static func normalized(_ value: String?) -> String {
        value?
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ") ?? ""
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
