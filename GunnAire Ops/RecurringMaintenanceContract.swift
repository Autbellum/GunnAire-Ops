// RecurringMaintenanceContract.swift
// Model for recurring maintenance contracts
import Foundation
import SwiftData

nonisolated enum MaintenanceAgreementLifecycleStatus: String, Codable, CaseIterable, Identifiable {
    case draft
    case pendingApproval
    case active
    case renewed
    case declined
    case cancelled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .draft: "Draft"
        case .pendingApproval: "Pending Approval"
        case .active: "Active"
        case .renewed: "Renewed"
        case .declined: "Declined"
        case .cancelled: "Cancelled"
        }
    }
}

nonisolated enum MaintenanceAgreementBillingInterval: String, Codable, CaseIterable, Identifiable {
    case perVisit
    case monthly
    case annual
    case fullTerm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .perVisit: "Per Visit"
        case .monthly: "Monthly"
        case .annual: "Annual"
        case .fullTerm: "Full Term"
        }
    }
}

/// One immutable link between a customer-approved agreement billing cycle and
/// the local invoice created for it. The ledger lives inside `lifecycleJSON`,
/// which keeps this addition compatible with the deployed CloudKit record type.
nonisolated struct MaintenanceAgreementBillingEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let cycleDueDate: Date
    let serviceCallID: UUID?
    let amount: Double
    let invoiceID: UUID
    let generatedAt: Date
    let generatedByEmail: String

    init(
        id: UUID = UUID(),
        cycleDueDate: Date,
        serviceCallID: UUID?,
        amount: Double,
        invoiceID: UUID,
        generatedAt: Date,
        generatedByEmail: String
    ) {
        self.id = id
        self.cycleDueDate = cycleDueDate
        self.serviceCallID = serviceCallID
        self.amount = amount
        self.invoiceID = invoiceID
        self.generatedAt = generatedAt
        self.generatedByEmail = generatedByEmail
    }
}

nonisolated struct MaintenanceAgreementBillingCandidate: Equatable, Identifiable, Sendable {
    let agreementID: UUID
    let customerID: UUID
    let cycleDueDate: Date
    let serviceCallID: UUID?
    let amount: Double
    let billingCatalogItemID: UUID
    let interval: MaintenanceAgreementBillingInterval

    var id: String {
        let cycleIdentity = serviceCallID?.uuidString
            ?? String(Int64(cycleDueDate.timeIntervalSinceReferenceDate.rounded()))
        return "\(agreementID.uuidString.lowercased()):\(cycleIdentity.lowercased())"
    }
}

nonisolated struct MaintenanceAgreementLifecycle: Codable, Equatable, Sendable {
    var schemaVersion: Int = 2
    var status: MaintenanceAgreementLifecycleStatus
    var agreementPrice: Double? = nil
    var billingInterval: MaintenanceAgreementBillingInterval
    var billingCatalogItemID: UUID? = nil
    var billingAnchorDate: Date? = nil
    var billingConfiguredAt: Date? = nil
    var billingConfiguredByEmail: String? = nil
    var billingEvents: [MaintenanceAgreementBillingEvent]? = nil
    var memberDiscountPercent: Double? = nil
    var autoRenews: Bool
    var termsSummary: String? = nil
    var createdAt: Date
    var createdByEmail: String? = nil
    var offeredAt: Date? = nil
    var offeredByEmail: String? = nil
    var sourceServiceCallID: UUID? = nil
    var approvedAt: Date? = nil
    var approvedByName: String? = nil
    var approvalMethodRaw: String? = nil
    var approvalReference: String? = nil
    var approvalSignatureImageBase64: String? = nil
    var approvalRecordedByEmail: String? = nil
    var declinedAt: Date? = nil
    var declinedByName: String? = nil
    var cancelledAt: Date? = nil
    var cancelledByEmail: String? = nil
    var cancellationReason: String? = nil
    var generatedDocumentAttachmentID: UUID? = nil
    var renewalOfContractID: UUID? = nil
    var pendingRenewalContractID: UUID? = nil
    var renewalStartedAt: Date? = nil
    var renewalStartedByEmail: String? = nil
    var supersededByContractID: UUID? = nil
    var renewedAt: Date? = nil
    var renewedByEmail: String? = nil

}

enum MaintenanceAgreementLifecycleError: LocalizedError, Equatable {
    case customerNameRequired
    case signatureRequired
    case approvalReferenceRequired
    case renewalRequiresActiveAgreement
    case renewalCannotReferenceSameAgreement
    case renewalAlreadyStarted(existingID: UUID)
    case renewalSourceMismatch
    case renewalSourceUnavailable
    case billingConfigurationUnavailable
    case invalidBillingCandidate
    case billingCycleAlreadyInvoiced

    var errorDescription: String? {
        switch self {
        case .customerNameRequired:
            "Enter the approving customer's name."
        case .signatureRequired:
            "Capture the customer's signature before activating this agreement."
        case .approvalReferenceRequired:
            "Enter the email, text, or verbal approval reference before activating this agreement."
        case .renewalRequiresActiveAgreement:
            "Only an active agreement can be renewed."
        case .renewalCannotReferenceSameAgreement:
            "An agreement cannot renew itself."
        case .renewalAlreadyStarted:
            "A renewal draft already exists for this agreement."
        case .renewalSourceMismatch:
            "This renewal does not match the pending agreement renewal."
        case .renewalSourceUnavailable:
            "The original agreement for this renewal is unavailable."
        case .billingConfigurationUnavailable:
            "Configure an approved billing item and first billing date before issuing agreement invoices."
        case .invalidBillingCandidate:
            "This agreement billing cycle is no longer eligible for invoicing. Refresh the queue and try again."
        case .billingCycleAlreadyInvoiced:
            "This agreement billing cycle already has an invoice."
        }
    }
}

enum MaintenanceAgreementBillingPolicy {
    static let maximumScheduledCycles = 240

    static func isEligibleForBilling(
        _ agreement: RecurringMaintenanceContract,
        asOf date: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard agreement.active,
              agreement.lifecycleStatus == .active,
              agreement.lifecycle?.approvedAt != nil else { return false }
        guard let termEndsOn = agreement.termEndsOn else { return true }
        return calendar.startOfDay(for: termEndsOn) >= calendar.startOfDay(for: date)
    }

    static func firstDueCandidate(
        for agreement: RecurringMaintenanceContract,
        serviceCalls: [ServiceCall],
        asOf date: Date = Date(),
        calendar: Calendar = .current
    ) -> MaintenanceAgreementBillingCandidate? {
        guard isEligibleForBilling(agreement, asOf: date, calendar: calendar),
              let amount = agreement.agreementPrice,
              amount.isFinite,
              amount > 0.009,
              let billingCatalogItemID = agreement.billingCatalogItemID else { return nil }

        switch agreement.billingInterval {
        case .perVisit:
            return firstUnbilledVisit(
                for: agreement,
                serviceCalls: serviceCalls,
                amount: amount,
                billingCatalogItemID: billingCatalogItemID,
                asOf: date,
                calendar: calendar
            )
        case .monthly, .annual, .fullTerm:
            return firstUnbilledScheduledCycle(
                for: agreement,
                amount: amount,
                billingCatalogItemID: billingCatalogItemID,
                asOf: date,
                calendar: calendar
            )
        }
    }

    static func hasRecordedCycle(
        _ candidate: MaintenanceAgreementBillingCandidate,
        in agreement: RecurringMaintenanceContract,
        calendar: Calendar = .current
    ) -> Bool {
        agreement.billingEvents.contains { event in
            if let serviceCallID = candidate.serviceCallID {
                return event.serviceCallID == serviceCallID
            }
            return event.serviceCallID == nil &&
                calendar.isDate(event.cycleDueDate, inSameDayAs: candidate.cycleDueDate)
        }
    }

    private static func firstUnbilledVisit(
        for agreement: RecurringMaintenanceContract,
        serviceCalls: [ServiceCall],
        amount: Double,
        billingCatalogItemID: UUID,
        asOf date: Date,
        calendar: Calendar
    ) -> MaintenanceAgreementBillingCandidate? {
        let today = calendar.startOfDay(for: date)
        let termEnd = agreement.termEndsOn.map { calendar.startOfDay(for: $0) }
        let billedVisitIDs = Set(agreement.billingEvents.compactMap(\.serviceCallID))

        return serviceCalls
            .filter { call in
                guard call.maintenanceAgreementID == agreement.id,
                      call.type == .maintenance,
                      call.status == .completed || call.status == .invoiced,
                      call.linkedInvoiceID == nil,
                      !billedVisitIDs.contains(call.id) else { return false }
                let cycleDate = calendar.startOfDay(
                    for: call.maintenanceAgreementDueDate ?? call.scheduledDate
                )
                guard cycleDate <= today else { return false }
                return termEnd.map { cycleDate <= $0 } ?? true
            }
            .sorted {
                let lhsDate = $0.maintenanceAgreementDueDate ?? $0.scheduledDate
                let rhsDate = $1.maintenanceAgreementDueDate ?? $1.scheduledDate
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return $0.id.uuidString < $1.id.uuidString
            }
            .first
            .map { call in
                MaintenanceAgreementBillingCandidate(
                    agreementID: agreement.id,
                    customerID: agreement.customer.id,
                    cycleDueDate: calendar.startOfDay(
                        for: call.maintenanceAgreementDueDate ?? call.scheduledDate
                    ),
                    serviceCallID: call.id,
                    amount: amount,
                    billingCatalogItemID: billingCatalogItemID,
                    interval: .perVisit
                )
            }
    }

    private static func firstUnbilledScheduledCycle(
        for agreement: RecurringMaintenanceContract,
        amount: Double,
        billingCatalogItemID: UUID,
        asOf date: Date,
        calendar: Calendar
    ) -> MaintenanceAgreementBillingCandidate? {
        guard let billingAnchorDate = agreement.billingAnchorDate else { return nil }
        let today = calendar.startOfDay(for: date)
        let termEnd = agreement.termEndsOn.map { calendar.startOfDay(for: $0) }
        var cycleDate = calendar.startOfDay(for: billingAnchorDate)

        for _ in 0..<maximumScheduledCycles {
            if cycleDate > today || termEnd.map({ cycleDate > $0 }) == true { return nil }
            let candidate = MaintenanceAgreementBillingCandidate(
                agreementID: agreement.id,
                customerID: agreement.customer.id,
                cycleDueDate: cycleDate,
                serviceCallID: nil,
                amount: amount,
                billingCatalogItemID: billingCatalogItemID,
                interval: agreement.billingInterval
            )
            if !hasRecordedCycle(candidate, in: agreement, calendar: calendar) {
                return candidate
            }
            guard agreement.billingInterval != .fullTerm,
                  let nextCycle = calendar.date(
                    byAdding: agreement.billingInterval == .monthly ? .month : .year,
                    value: 1,
                    to: cycleDate
                  ),
                  nextCycle > cycleDate else { return nil }
            cycleDate = nextCycle
        }
        return nil
    }
}

@Model
final class RecurringMaintenanceContract {
    var id: UUID = UUID()
    var customer: Customer!
    var planName: String?
    var schedulePattern: String = "every 6 months" // e.g., 'every 6 months'
    var nextDate: Date = Date()
    var active: Bool = true
    var termEndsOn: Date?
    var pricePerVisit: Double?
    var includedVisitsPerTerm: Int?
    var renewalReminderDays: Int = 30
    var coveredEquipmentIDsJSON: String?
    /// Versioned lifecycle evidence keeps a draft or offer from becoming an
    /// active recurring obligation until customer authorization is recorded.
    var lifecycleJSON: String?
    
    init(
        id: UUID = UUID(),
        customer: Customer,
        planName: String? = nil,
        schedulePattern: String,
        nextDate: Date,
        active: Bool = true,
        termEndsOn: Date? = nil,
        pricePerVisit: Double? = nil,
        includedVisitsPerTerm: Int? = nil,
        renewalReminderDays: Int = 30,
        coveredEquipmentIDs: Set<UUID> = [],
        lifecycle: MaintenanceAgreementLifecycle? = nil
    ) {
        self.id = id
        self.customer = customer
        self.planName = planName
        self.schedulePattern = schedulePattern
        self.nextDate = nextDate
        self.active = active
        self.termEndsOn = termEndsOn
        self.pricePerVisit = pricePerVisit
        self.includedVisitsPerTerm = includedVisitsPerTerm
        self.renewalReminderDays = max(1, renewalReminderDays)
        self.coveredEquipmentIDsJSON = Self.encodeCoveredEquipmentIDs(coveredEquipmentIDs)
        self.lifecycleJSON = Self.encodeLifecycle(lifecycle)
    }
    
    var isUpcoming: Bool {
        let now = Date()
        let thirtyDaysAhead = Calendar.current.date(byAdding: .day, value: 30, to: now)!
        return nextDate >= now && nextDate <= thirtyDaysAhead
    }

    var isOverdue: Bool {
        nextDate < Calendar.current.startOfDay(for: Date())
    }

    var needsReminder: Bool {
        reminderDate <= Date() && nextDate >= Calendar.current.startOfDay(for: Date())
    }

    var displayName: String {
        let value = planName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Maintenance Agreement" : value
    }

    var coveredEquipmentIDs: Set<UUID> {
        guard let coveredEquipmentIDsJSON,
              let data = coveredEquipmentIDsJSON.data(using: .utf8),
              let values = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(values)
    }

    var renewalReminderDate: Date? {
        guard let termEndsOn else { return nil }
        return Calendar.current.date(byAdding: .day, value: -max(1, renewalReminderDays), to: termEndsOn)
    }

    var isExpired: Bool {
        guard let termEndsOn else { return false }
        return termEndsOn < Calendar.current.startOfDay(for: Date())
    }

    var needsRenewalAttention: Bool {
        guard canScheduleVisit, let renewalReminderDate else { return false }
        return renewalReminderDate <= Date()
    }

    var canScheduleVisit: Bool {
        active && lifecycleStatus == .active && !isExpired
    }

    var lifecycle: MaintenanceAgreementLifecycle? {
        guard let lifecycleJSON,
              let data = lifecycleJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MaintenanceAgreementLifecycle.self, from: data)
    }

    /// Agreements created before lifecycle evidence existed retain their
    /// historical active/inactive state and are clearly identified in the UI.
    var isLegacyAgreement: Bool { lifecycle == nil }

    var lifecycleStatus: MaintenanceAgreementLifecycleStatus {
        lifecycle?.status ?? (active ? .active : .cancelled)
    }

    var lifecycleStatusDisplayName: String {
        if lifecycleStatus == .active && isExpired { return "Expired" }
        return lifecycleStatus.displayName
    }

    var agreementPrice: Double? { lifecycle?.agreementPrice }

    var billingInterval: MaintenanceAgreementBillingInterval {
        lifecycle?.billingInterval ?? .perVisit
    }

    var billingCatalogItemID: UUID? { lifecycle?.billingCatalogItemID }

    var billingAnchorDate: Date? { lifecycle?.billingAnchorDate }

    var billingEvents: [MaintenanceAgreementBillingEvent] {
        lifecycle?.billingEvents ?? []
    }

    var requiresBillingConfiguration: Bool {
        guard let agreementPrice, agreementPrice > 0.009 else { return false }
        if billingCatalogItemID == nil { return true }
        return billingInterval != .perVisit && billingAnchorDate == nil
    }

    var memberDiscountPercent: Double? { lifecycle?.memberDiscountPercent }

    var autoRenews: Bool { lifecycle?.autoRenews ?? false }

    var termsSummary: String? { lifecycle?.termsSummary }

    var approvalSignatureImageBase64: String? {
        lifecycle?.approvalSignatureImageBase64
    }

    var approvalMethod: EstimateApprovalMethod? {
        lifecycle?.approvalMethodRaw.flatMap(EstimateApprovalMethod.init(rawValue:))
    }

    func configureDraft(
        agreementPrice: Double?,
        billingInterval: MaintenanceAgreementBillingInterval,
        billingCatalogItemID: UUID? = nil,
        billingAnchorDate: Date? = nil,
        memberDiscountPercent: Double?,
        autoRenews: Bool,
        termsSummary: String?,
        createdByEmail: String?,
        sourceServiceCallID: UUID?,
        renewalOfContractID: UUID? = nil,
        createdAt: Date = Date(),
        calendar: Calendar = .current
    ) {
        active = false
        storeLifecycle(
            MaintenanceAgreementLifecycle(
                status: .draft,
                agreementPrice: Self.normalizedNonnegative(agreementPrice),
                billingInterval: billingInterval,
                billingCatalogItemID: billingCatalogItemID,
                billingAnchorDate: billingInterval == .perVisit
                    ? nil
                    : billingAnchorDate.map { calendar.startOfDay(for: $0) },
                memberDiscountPercent: Self.normalizedPercent(memberDiscountPercent),
                autoRenews: autoRenews,
                termsSummary: Self.normalizedText(termsSummary),
                createdAt: createdAt,
                createdByEmail: Self.normalizedEmail(createdByEmail),
                sourceServiceCallID: sourceServiceCallID,
                renewalOfContractID: renewalOfContractID
            )
        )
    }

    func configureBilling(
        catalogItemID: UUID,
        anchorDate: Date?,
        byEmail: String?,
        configuredAt: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        guard var value = lifecycle,
              value.agreementPrice.map({ $0.isFinite && $0 > 0.009 }) == true else {
            throw MaintenanceAgreementLifecycleError.billingConfigurationUnavailable
        }
        value.schemaVersion = max(value.schemaVersion, 2)
        value.billingCatalogItemID = catalogItemID
        value.billingAnchorDate = value.billingInterval == .perVisit
            ? nil
            : anchorDate.map { calendar.startOfDay(for: $0) }
        guard value.billingInterval == .perVisit || value.billingAnchorDate != nil else {
            throw MaintenanceAgreementLifecycleError.billingConfigurationUnavailable
        }
        value.billingConfiguredAt = configuredAt
        value.billingConfiguredByEmail = Self.normalizedEmail(byEmail)
        storeLifecycle(value)
    }

    func recordBillingInvoice(
        _ candidate: MaintenanceAgreementBillingCandidate,
        invoiceID: UUID,
        generatedByEmail: String?,
        generatedAt: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        guard candidate.agreementID == id,
              candidate.customerID == customer.id,
              candidate.billingCatalogItemID == billingCatalogItemID,
              abs(candidate.amount - (agreementPrice ?? -1)) < 0.005,
              candidate.amount > 0.009,
              var value = lifecycle,
              value.status == .active,
              active else {
            throw MaintenanceAgreementLifecycleError.invalidBillingCandidate
        }
        if MaintenanceAgreementBillingPolicy.hasRecordedCycle(candidate, in: self, calendar: calendar) {
            throw MaintenanceAgreementLifecycleError.billingCycleAlreadyInvoiced
        }
        let actor = Self.normalizedEmail(generatedByEmail)
        guard let actor else {
            throw MaintenanceAgreementLifecycleError.invalidBillingCandidate
        }
        var events = value.billingEvents ?? []
        events.append(
            MaintenanceAgreementBillingEvent(
                cycleDueDate: calendar.startOfDay(for: candidate.cycleDueDate),
                serviceCallID: candidate.serviceCallID,
                amount: candidate.amount,
                invoiceID: invoiceID,
                generatedAt: generatedAt,
                generatedByEmail: actor
            )
        )
        value.schemaVersion = max(value.schemaVersion, 2)
        value.billingEvents = events
        storeLifecycle(value)
    }

    func beginRenewal(
        with successorID: UUID,
        byEmail: String?,
        at date: Date = Date()
    ) throws {
        guard successorID != id else {
            throw MaintenanceAgreementLifecycleError.renewalCannotReferenceSameAgreement
        }
        var value = lifecycle ?? legacyLifecycleSnapshot(createdAt: date)
        guard value.status == .active else {
            throw MaintenanceAgreementLifecycleError.renewalRequiresActiveAgreement
        }
        if let existingID = value.pendingRenewalContractID {
            guard existingID == successorID else {
                throw MaintenanceAgreementLifecycleError.renewalAlreadyStarted(existingID: existingID)
            }
            return
        }
        value.pendingRenewalContractID = successorID
        value.renewalStartedAt = date
        value.renewalStartedByEmail = Self.normalizedEmail(byEmail)
        storeLifecycle(value)
    }

    func validateRenewalCompletion(by successorID: UUID) throws {
        guard successorID != id else {
            throw MaintenanceAgreementLifecycleError.renewalCannotReferenceSameAgreement
        }
        guard lifecycleStatus == .active else {
            throw MaintenanceAgreementLifecycleError.renewalRequiresActiveAgreement
        }
        guard lifecycle?.pendingRenewalContractID == successorID else {
            throw MaintenanceAgreementLifecycleError.renewalSourceMismatch
        }
    }

    @discardableResult
    func clearPendingRenewal(successorID: UUID) -> Bool {
        guard var value = lifecycle,
              value.pendingRenewalContractID == successorID else { return false }
        value.pendingRenewalContractID = nil
        value.renewalStartedAt = nil
        value.renewalStartedByEmail = nil
        storeLifecycle(value)
        return true
    }

    func markRenewed(
        by successorID: UUID,
        byEmail: String?,
        at date: Date = Date()
    ) throws {
        try validateRenewalCompletion(by: successorID)
        guard var value = lifecycle else {
            throw MaintenanceAgreementLifecycleError.renewalSourceMismatch
        }
        value.status = .renewed
        value.pendingRenewalContractID = nil
        value.supersededByContractID = successorID
        value.renewedAt = date
        value.renewedByEmail = Self.normalizedEmail(byEmail)
        active = false
        storeLifecycle(value)
    }

    func markPendingApproval(
        offeredByEmail: String?,
        sourceServiceCallID: UUID? = nil,
        offeredAt: Date = Date()
    ) {
        var value = lifecycle ?? legacyLifecycleSnapshot(createdAt: offeredAt)
        value.status = .pendingApproval
        value.offeredAt = offeredAt
        value.offeredByEmail = Self.normalizedEmail(offeredByEmail)
        value.sourceServiceCallID = sourceServiceCallID ?? value.sourceServiceCallID
        value.approvedAt = nil
        value.approvedByName = nil
        value.approvalMethodRaw = nil
        value.approvalReference = nil
        value.approvalSignatureImageBase64 = nil
        value.approvalRecordedByEmail = nil
        active = false
        storeLifecycle(value)
    }

    func recordCustomerApproval(
        customerName: String,
        method: EstimateApprovalMethod,
        reference: String?,
        signatureImageBase64: String?,
        recordedByEmail: String?,
        approvedAt: Date = Date()
    ) throws {
        let normalizedName = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw MaintenanceAgreementLifecycleError.customerNameRequired
        }
        let normalizedReference = Self.normalizedText(reference)
        let normalizedSignature = Self.normalizedText(signatureImageBase64)
        if method.requiresSignature && normalizedSignature == nil {
            throw MaintenanceAgreementLifecycleError.signatureRequired
        }
        if !method.requiresSignature && normalizedReference == nil {
            throw MaintenanceAgreementLifecycleError.approvalReferenceRequired
        }

        var value = lifecycle ?? legacyLifecycleSnapshot(createdAt: approvedAt)
        value.status = .active
        value.offeredAt = value.offeredAt ?? approvedAt
        value.offeredByEmail = value.offeredByEmail ?? Self.normalizedEmail(recordedByEmail)
        value.approvedAt = approvedAt
        value.approvedByName = normalizedName
        value.approvalMethodRaw = method.rawValue
        value.approvalReference = normalizedReference
        value.approvalSignatureImageBase64 = normalizedSignature
        value.approvalRecordedByEmail = Self.normalizedEmail(recordedByEmail)
        value.declinedAt = nil
        value.declinedByName = nil
        value.cancelledAt = nil
        value.cancelledByEmail = nil
        value.cancellationReason = nil
        active = true
        storeLifecycle(value)
    }

    func recordDecline(customerName: String?, declinedAt: Date = Date()) {
        var value = lifecycle ?? legacyLifecycleSnapshot(createdAt: declinedAt)
        value.status = .declined
        value.declinedAt = declinedAt
        value.declinedByName = Self.normalizedText(customerName)
        active = false
        storeLifecycle(value)
    }

    func cancel(byEmail: String?, reason: String?, cancelledAt: Date = Date()) {
        var value = lifecycle ?? legacyLifecycleSnapshot(createdAt: cancelledAt)
        value.status = .cancelled
        value.cancelledAt = cancelledAt
        value.cancelledByEmail = Self.normalizedEmail(byEmail)
        value.cancellationReason = Self.normalizedText(reason)
        active = false
        storeLifecycle(value)
    }

    func linkGeneratedDocument(_ attachmentID: UUID) {
        var value = lifecycle ?? legacyLifecycleSnapshot(createdAt: Date())
        value.generatedDocumentAttachmentID = attachmentID
        storeLifecycle(value)
    }

    func updateCoveredEquipmentIDs(_ ids: Set<UUID>) {
        coveredEquipmentIDsJSON = Self.encodeCoveredEquipmentIDs(ids)
    }

    var reminderDate: Date {
        Calendar.current.date(byAdding: .day, value: -7, to: nextDate) ?? nextDate
    }

    func scheduledVisit(forDueDate dueDate: Date, in serviceCalls: [ServiceCall], calendar: Calendar = .current) -> ServiceCall? {
        serviceCalls
            .filter { call in
                call.maintenanceAgreementID == id &&
                call.status != .cancelled &&
                call.maintenanceAgreementDueDate.map { calendar.isDate($0, inSameDayAs: dueDate) } == true
            }
            .sorted { lhs, rhs in
                if lhs.status == .completed || lhs.status == .invoiced {
                    return false
                }
                if rhs.status == .completed || rhs.status == .invoiced {
                    return true
                }
                return lhs.scheduledDate < rhs.scheduledDate
            }
            .first
    }

    @discardableResult
    func recordCompletedVisit(_ serviceCall: ServiceCall, calendar: Calendar = .current) -> Bool {
        guard serviceCall.maintenanceAgreementID == id,
              serviceCall.type == .maintenance,
              (serviceCall.status == .completed || serviceCall.status == .invoiced),
              let fulfilledDueDate = serviceCall.maintenanceAgreementDueDate else {
            return false
        }

        let originalNextDate = nextDate
        while nextDate <= fulfilledDueDate || calendar.isDate(nextDate, inSameDayAs: fulfilledDueDate) {
            advanceNextDate(calendar: calendar)
            if nextDate <= originalNextDate { break }
        }
        return nextDate > originalNextDate
    }

    func advanceNextDate(calendar: Calendar = .current) {
        let lowercasedPattern = schedulePattern.lowercased()

        if lowercasedPattern.contains("quarter") || lowercasedPattern.contains("3 month") {
            nextDate = calendar.date(byAdding: .month, value: 3, to: nextDate) ?? nextDate
            return
        }
        if lowercasedPattern.contains("6 month") || lowercasedPattern.contains("semi") {
            nextDate = calendar.date(byAdding: .month, value: 6, to: nextDate) ?? nextDate
            return
        }
        if lowercasedPattern.contains("year") || lowercasedPattern.contains("annual") || lowercasedPattern.contains("12 month") {
            nextDate = calendar.date(byAdding: .year, value: 1, to: nextDate) ?? nextDate
            return
        }
        if lowercasedPattern.contains("month") {
            nextDate = calendar.date(byAdding: .month, value: 1, to: nextDate) ?? nextDate
            return
        }
        nextDate = calendar.date(byAdding: .month, value: 6, to: nextDate) ?? nextDate
    }

    private static func encodeCoveredEquipmentIDs(_ ids: Set<UUID>) -> String? {
        guard !ids.isEmpty,
              let data = try? JSONEncoder().encode(ids.sorted { $0.uuidString < $1.uuidString }) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func legacyLifecycleSnapshot(createdAt: Date) -> MaintenanceAgreementLifecycle {
        MaintenanceAgreementLifecycle(
            status: active ? .active : .cancelled,
            agreementPrice: nil,
            billingInterval: .perVisit,
            memberDiscountPercent: nil,
            autoRenews: false,
            termsSummary: nil,
            createdAt: createdAt,
            createdByEmail: nil,
            sourceServiceCallID: nil
        )
    }

    private func storeLifecycle(_ lifecycle: MaintenanceAgreementLifecycle) {
        lifecycleJSON = Self.encodeLifecycle(lifecycle)
    }

    private static func encodeLifecycle(_ lifecycle: MaintenanceAgreementLifecycle?) -> String? {
        guard let lifecycle,
              let data = try? JSONEncoder().encode(lifecycle) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func normalizedNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func normalizedPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 100)
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        normalizedText(value)?.lowercased()
    }

    private static func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
