import Foundation
import SwiftData

enum EquipmentLifecycleAttention: Equatable, Sendable {
    case none
    case warrantyExpiringSoon
    case warrantyExpired
    case invalidDates
}

struct EquipmentLifecycleSnapshot: Equatable, Sendable {
    let ageSummary: String?
    let warrantySummary: String?
    let attention: EquipmentLifecycleAttention
    let validationMessage: String?

    var summary: String? {
        if validationMessage != nil {
            return "Review equipment dates"
        }
        let parts = [ageSummary, warrantySummary].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

enum EquipmentLifecyclePolicy {
    static let warrantyWarningDays = 90

    static func snapshot(
        installDate: Date?,
        warrantyExpiration: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> EquipmentLifecycleSnapshot {
        let today = calendar.startOfDay(for: now)
        let installDay = installDate.map { calendar.startOfDay(for: $0) }
        let warrantyDay = warrantyExpiration.map { calendar.startOfDay(for: $0) }

        if let installDay, installDay > today {
            return EquipmentLifecycleSnapshot(
                ageSummary: nil,
                warrantySummary: nil,
                attention: .invalidDates,
                validationMessage: "Install date cannot be in the future."
            )
        }
        if let installDay, let warrantyDay, warrantyDay < installDay {
            return EquipmentLifecycleSnapshot(
                ageSummary: installationAgeSummary(from: installDay, to: today, calendar: calendar),
                warrantySummary: nil,
                attention: .invalidDates,
                validationMessage: "Warranty expiration cannot be before the install date."
            )
        }

        let ageSummary = installDay.map {
            installationAgeSummary(from: $0, to: today, calendar: calendar)
        }
        guard let warrantyDay else {
            return EquipmentLifecycleSnapshot(
                ageSummary: ageSummary,
                warrantySummary: nil,
                attention: .none,
                validationMessage: nil
            )
        }

        let formattedWarrantyDate = warrantyDay.formatted(date: .abbreviated, time: .omitted)
        let remainingDays = calendar.dateComponents([.day], from: today, to: warrantyDay).day ?? 0
        if remainingDays < 0 {
            return EquipmentLifecycleSnapshot(
                ageSummary: ageSummary,
                warrantySummary: "Warranty expired \(formattedWarrantyDate)",
                attention: .warrantyExpired,
                validationMessage: nil
            )
        }
        if remainingDays <= warrantyWarningDays {
            return EquipmentLifecycleSnapshot(
                ageSummary: ageSummary,
                warrantySummary: "Warranty expires soon: \(formattedWarrantyDate)",
                attention: .warrantyExpiringSoon,
                validationMessage: nil
            )
        }
        return EquipmentLifecycleSnapshot(
            ageSummary: ageSummary,
            warrantySummary: "Warranty active through \(formattedWarrantyDate)",
            attention: .none,
            validationMessage: nil
        )
    }

    private static func installationAgeSummary(from installDay: Date, to today: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: installDay, to: today)
        if let years = components.year, years > 0 {
            return "Installed \(years) year\(years == 1 ? "" : "s") ago"
        }
        if let months = components.month, months > 0 {
            return "Installed \(months) month\(months == 1 ? "" : "s") ago"
        }
        let days = max(components.day ?? 0, 0)
        if days == 0 {
            return "Installed today"
        }
        return "Installed \(days) day\(days == 1 ? "" : "s") ago"
    }
}

enum EquipmentServicePlanningAttention: Equatable, Sendable {
    case none
    case followUp
    case repeatedService
    case replacementEvaluation
}

struct EquipmentServicePlanningSnapshot: Equatable, Sendable {
    let attention: EquipmentServicePlanningAttention
    let title: String?
    let summary: String?
    let guidance: String?
    let ageYears: Int?
    let evaluationAgeYears: Int?
    let recentServiceVisitCount: Int
    let recentCorrectiveVisitCount: Int
    let openFollowUpCount: Int
    let overdueFollowUpCount: Int
    let hasUnresolvedServiceConcerns: Bool

    var needsAttention: Bool {
        attention != .none && title != nil && summary != nil
    }
}

enum EquipmentServicePlanningPolicy {
    static let recentHistoryDays = 365
    static let repeatedServiceVisitCount = 3

    static func snapshot(
        equipmentType: HVACEquipmentType?,
        installDate: Date?,
        serviceCalls: [ServiceCall],
        hasUnresolvedServiceConcerns: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> EquipmentServicePlanningSnapshot {
        let today = calendar.startOfDay(for: now)
        let historyStart = calendar.date(byAdding: .day, value: -recentHistoryDays, to: today)
            ?? today.addingTimeInterval(-Double(recentHistoryDays) * 86_400)
        let completedCalls = serviceCalls.filter { call in
            call.scheduledDate >= historyStart &&
                call.scheduledDate <= now &&
                (call.status == .completed || call.status == .invoiced)
        }
        let recentServiceCalls = completedCalls.filter { $0.type == .service }
        let correctiveCalls = recentServiceCalls.filter { call in
            call.visitDisposition == .callback ||
                call.visitDisposition == .warranty ||
                call.originatingServiceCallID != nil ||
                call.correctiveWorkReason != nil
        }
        let openFollowUps = serviceCalls.filter { call in
            guard call.status != .cancelled,
                  call.followUpRequired,
                  let action = call.followUpAction?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !action.isEmpty else {
                return false
            }
            return true
        }
        let overdueFollowUpCount = openFollowUps.filter { call in
            guard let dueDate = call.followUpDueDate else { return false }
            return calendar.startOfDay(for: dueDate) < today
        }.count
        let evaluationAgeYears = replacementEvaluationAgeYears(for: equipmentType)
        let ageYears = equipmentAgeYears(installDate: installDate, now: now, calendar: calendar)
        let reachedEvaluationAge = ageYears.flatMap { age in
            evaluationAgeYears.map { age >= $0 }
        } ?? false
        let hasRepeatedService = recentServiceCalls.count >= repeatedServiceVisitCount
        let hasCorrectivePattern = correctiveCalls.count >= 2
        let repairAndReplacementReview = reachedEvaluationAge &&
            (recentServiceCalls.count >= 2 || !correctiveCalls.isEmpty)

        let attention: EquipmentServicePlanningAttention
        let title: String?
        if repairAndReplacementReview {
            attention = .replacementEvaluation
            title = "Repair vs. replacement review"
        } else if reachedEvaluationAge {
            attention = .replacementEvaluation
            title = "Plan equipment evaluation"
        } else if hasRepeatedService || hasCorrectivePattern {
            attention = .repeatedService
            title = "Review repeat service history"
        } else if !correctiveCalls.isEmpty {
            attention = .repeatedService
            title = "Review corrective work"
        } else if overdueFollowUpCount > 0 {
            attention = .followUp
            title = "Service follow-up overdue"
        } else if !openFollowUps.isEmpty || hasUnresolvedServiceConcerns {
            attention = .followUp
            title = hasUnresolvedServiceConcerns ? "Service concern needs review" : "Service follow-up open"
        } else {
            attention = .none
            title = nil
        }

        var summaryParts: [String] = []
        if reachedEvaluationAge, let ageYears, let evaluationAgeYears {
            summaryParts.append("\(ageYears) years old (evaluate at \(evaluationAgeYears))")
        }
        if !recentServiceCalls.isEmpty {
            summaryParts.append("\(recentServiceCalls.count) service visit\(recentServiceCalls.count == 1 ? "" : "s") in the past 12 months")
        }
        if !correctiveCalls.isEmpty {
            summaryParts.append("\(correctiveCalls.count) callback/warranty visit\(correctiveCalls.count == 1 ? "" : "s")")
        }
        if !openFollowUps.isEmpty {
            let overdueSuffix = overdueFollowUpCount > 0 ? ", \(overdueFollowUpCount) overdue" : ""
            summaryParts.append("\(openFollowUps.count) open follow-up\(openFollowUps.count == 1 ? "" : "s")\(overdueSuffix)")
        }
        if hasUnresolvedServiceConcerns {
            summaryParts.append("open diagnostic concerns")
        }

        return EquipmentServicePlanningSnapshot(
            attention: attention,
            title: title,
            summary: title == nil ? nil : summaryParts.joined(separator: " • "),
            guidance: title == nil
                ? nil
                : "Planning cue only—confirm the current diagnosis, repair cost, efficiency, warranty coverage, and customer priorities before presenting options.",
            ageYears: ageYears,
            evaluationAgeYears: evaluationAgeYears,
            recentServiceVisitCount: recentServiceCalls.count,
            recentCorrectiveVisitCount: correctiveCalls.count,
            openFollowUpCount: openFollowUps.count,
            overdueFollowUpCount: overdueFollowUpCount,
            hasUnresolvedServiceConcerns: hasUnresolvedServiceConcerns
        )
    }

    static func replacementEvaluationAgeYears(for equipmentType: HVACEquipmentType?) -> Int? {
        switch equipmentType {
        case .splitSystemAC, .heatPump, .airHandler, .packageUnit, .miniSplit:
            10
        case .gasFurnace, .boiler:
            15
        case .waterHeater:
            10
        case .ventilation, .iaqAccessory, .other, .none:
            nil
        }
    }

    private static func equipmentAgeYears(
        installDate: Date?,
        now: Date,
        calendar: Calendar
    ) -> Int? {
        guard let installDate else { return nil }
        let installDay = calendar.startOfDay(for: installDate)
        let today = calendar.startOfDay(for: now)
        guard installDay <= today else { return nil }
        return max(calendar.dateComponents([.year], from: installDay, to: today).year ?? 0, 0)
    }
}

@Model
final class CustomerEquipment {
    var id: UUID = UUID()
    var customer: Customer?
    /// Stable property identity; `location` remains the room/area within that property.
    var serviceLocationID: UUID?
    var equipmentTypeRaw: String?
    var name: String = ""
    var manufacturer: String?
    var modelNumber: String?
    var serialNumber: String?
    var location: String?
    var installDate: Date?
    var warrantyExpiration: Date?
    var filterSize: String?
    var notes: String?
    var technicalBaselineReadingsJSON: String?
    var isActive: Bool = true
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        customer: Customer? = nil,
        serviceLocationID: UUID? = nil,
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
        self.serviceLocationID = serviceLocationID
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

    func lifecycleSnapshot(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> EquipmentLifecycleSnapshot {
        EquipmentLifecyclePolicy.snapshot(
            installDate: installDate,
            warrantyExpiration: warrantyExpiration,
            now: now,
            calendar: calendar
        )
    }

    func apply(to serviceCall: ServiceCall) {
        serviceCall.customerEquipmentID = id
        serviceCall.serviceLocationID = serviceLocationID
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
        EquipmentOperationalEvidenceEnvelope.decode(from: technicalBaselineReadingsJSON)
            .technicalBaselines
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
        replaceTechnicalBaselines(baselines)
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

    func servicePlanningSnapshot(
        in serviceCalls: [ServiceCall],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> EquipmentServicePlanningSnapshot {
        let matchingCalls = matchingServiceCalls(in: serviceCalls)
        return EquipmentServicePlanningPolicy.snapshot(
            equipmentType: equipmentType,
            installDate: installDate,
            serviceCalls: matchingCalls,
            hasUnresolvedServiceConcerns: unresolvedServiceConcernSummary(
                in: matchingCalls,
                now: now
            ) != nil,
            now: now,
            calendar: calendar
        )
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

    func openFollowUpSummary(in serviceCalls: [ServiceCall], now: Date = Date()) -> String? {
        let followUps = matchingServiceCalls(in: serviceCalls)
            .filter { call in
                call.status != .cancelled &&
                    call.followUpRequired &&
                    call.followUpAction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            .sorted { lhs, rhs in
                switch (lhs.followUpDueDate, rhs.followUpDueDate) {
                case (.some(let lhsDate), .some(let rhsDate)):
                    return lhsDate < rhsDate
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.scheduledDate > rhs.scheduledDate
                }
            }
            .prefix(3)
            .compactMap { call -> String? in
                guard let action = call.followUpAction?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !action.isEmpty else { return nil }
                let dueLabel: String
                if let dueDate = call.followUpDueDate {
                    let prefix = dueDate < Calendar.current.startOfDay(for: now) ? "Overdue" : "Due"
                    dueLabel = "\(prefix) \(dueDate.formatted(date: .abbreviated, time: .omitted))"
                } else {
                    dueLabel = "No due date"
                }
                return "\(dueLabel): \(action)"
            }

        guard !followUps.isEmpty else { return nil }
        return followUps.joined(separator: "; ")
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
            call.serviceActionServiceHistorySummary.map { "Actions: \($0)" },
            unresolvedServiceConcernSummary(in: serviceCalls, now: now).map { "Open Concerns: \($0)" }
        ]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }

    func updateFrom(
        serviceLocationID: UUID? = nil,
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
        self.serviceLocationID = serviceLocationID
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
            return common + ["mode_tested", "indoor_head_delta_t", "communication_voltage", "inverter_frequency", "indoor_filter_condition", "indoor_coil_condition", "outdoor_coil_condition", "outdoor_fan_operation", "condensate_pump_status"]
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

extension ServiceCall {
    var equipmentLifecycleSnapshot: EquipmentLifecycleSnapshot {
        EquipmentLifecyclePolicy.snapshot(
            installDate: equipmentInstallDate,
            warrantyExpiration: equipmentWarrantyExpiration
        )
    }
}
