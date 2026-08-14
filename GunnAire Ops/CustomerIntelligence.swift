import Foundation

enum CustomerIntelligenceAction: Equatable {
    case collectPayment(UUID)
    case openDocumentation(UUID)
    case openSchedule(UUID)
    case openPayments
    case completeProfile(UUID)
    case openCustomer(UUID)

    var title: String {
        switch self {
        case .collectPayment:
            return "Collect"
        case .openDocumentation:
            return "Open Docs"
        case .openSchedule:
            return "Schedule"
        case .openPayments:
            return "Review"
        case .completeProfile:
            return "Update"
        case .openCustomer:
            return "Open"
        }
    }

    var systemImage: String {
        switch self {
        case .collectPayment:
            return "creditcard"
        case .openDocumentation:
            return "doc.text"
        case .openSchedule:
            return "calendar"
        case .openPayments:
            return "arrow.triangle.2.circlepath"
        case .completeProfile:
            return "person.text.rectangle"
        case .openCustomer:
            return "person.crop.circle"
        }
    }
}

struct CustomerIntelligenceSnapshot: Identifiable {
    let id: UUID
    let customer: Customer
    let healthScore: Int
    let healthLabel: String
    let openBalance: Double
    let openInvoiceCount: Int
    let overdueInvoiceCount: Int
    let openEstimateTotal: Double
    let openEstimateCount: Int
    let readyToBillCount: Int
    let followUpCount: Int
    let syncAttentionCount: Int
    let missingContactDetailCount: Int
    let activeContractCount: Int
    let nextContract: RecurringMaintenanceContract?
    let nextJob: ServiceCall?
    let lastCompletedJob: ServiceCall?
    let primaryAction: CustomerIntelligenceAction
    let actionDetail: String
    let priorityScore: Double

    var hasOpenWork: Bool {
        nextJob != nil || readyToBillCount > 0 || followUpCount > 0
    }

    var hasRisk: Bool {
        healthScore < 70 || openBalance > 0 || overdueInvoiceCount > 0 || syncAttentionCount > 0
    }
}

enum CustomerIntelligence {
    static func matchesOperationalSearch(
        customer: Customer,
        query: String,
        serviceCalls: [ServiceCall],
        equipmentProfiles: [CustomerEquipment],
        contracts: [RecurringMaintenanceContract] = [],
        now: Date = Date()
    ) -> Bool {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !search.isEmpty else { return true }

        let customerCalls = serviceCalls.filter { $0.customer.id == customer.id }
        let customerEquipment = equipmentProfiles.filter { $0.customer?.id == customer.id }
        let customerContracts = contracts.filter { $0.customer.id == customer.id && $0.active }

        var values: [String?] = [
            customer.name,
            customer.phone,
            customer.email,
            customer.address
        ]

        for equipment in customerEquipment {
            values.append(contentsOf: [
                equipment.name,
                equipment.displayName,
                equipment.equipmentType?.displayName,
                equipment.manufacturer,
                equipment.modelNumber,
                equipment.serialNumber,
                equipment.location,
                equipment.filterSize,
                equipment.notes,
                equipment.serviceHistorySummary(in: customerCalls, now: now),
                equipment.openFollowUpSummary(in: customerCalls, now: now),
                equipment.unresolvedServiceConcernSummary(in: customerCalls, now: now),
                equipment.latestServiceContextSummary(in: customerCalls, now: now)
            ])
        }

        for call in customerCalls {
            values.append(contentsOf: [
                call.type.displayName,
                call.status.rawValue,
                call.eventTitle,
                call.siteAddress,
                call.equipmentName,
                call.equipmentManufacturer,
                call.equipmentModel,
                call.equipmentSerialNumber,
                call.equipmentLocation,
                call.filterSize,
                call.serviceReportSummary,
                call.recommendedWorkSummary,
                call.findingsSummary,
                call.notes,
                call.followUpAction,
                call.nextServiceReportActionLabel,
                call.serviceReportActionSummary,
                call.serviceReportReadinessSummary,
                call.technicalReadingServiceHistorySummary,
                call.serviceActionServiceHistorySummary
            ])
            values.append(contentsOf: call.openServiceConcernRows.map { "\($0.label) \($0.value)" })
        }

        for contract in customerContracts {
            values.append(contentsOf: [
                contract.schedulePattern,
                "maintenance agreement",
                "service agreement"
            ])
        }

        return values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .contains(search)
    }

    static func snapshots(
        customers: [Customer],
        serviceCalls: [ServiceCall],
        invoices: [Invoice],
        estimates: [Estimate],
        payments: [Payment],
        contracts: [RecurringMaintenanceContract],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [CustomerIntelligenceSnapshot] {
        customers
            .map {
                snapshot(
                    for: $0,
                    serviceCalls: serviceCalls,
                    invoices: invoices,
                    estimates: estimates,
                    payments: payments,
                    contracts: contracts,
                    now: now,
                    calendar: calendar
                )
            }
            .sorted { lhs, rhs in
                if lhs.priorityScore != rhs.priorityScore {
                    return lhs.priorityScore > rhs.priorityScore
                }
                return lhs.customer.name.localizedCaseInsensitiveCompare(rhs.customer.name) == .orderedAscending
            }
    }

    static func snapshot(
        for customer: Customer,
        serviceCalls: [ServiceCall],
        invoices: [Invoice],
        estimates: [Estimate],
        payments: [Payment],
        contracts: [RecurringMaintenanceContract],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CustomerIntelligenceSnapshot {
        let customerCalls = serviceCalls
            .filter { $0.customer.id == customer.id }
            .sorted { $0.scheduledDate > $1.scheduledDate }
        let customerInvoices = invoices
            .filter { $0.customer.id == customer.id }
            .sorted { $0.createdAt > $1.createdAt }
        let invoiceIDs = Set(customerInvoices.map(\.id))
        let customerPayments = payments.filter { invoiceIDs.contains($0.invoice.id) }
        let customerEstimates = estimates.filter { $0.customer.id == customer.id }
        let customerContracts = contracts
            .filter { $0.customer.id == customer.id }
            .ifEmpty(customer.recurringContracts)

        let openInvoiceBalances = customerInvoices.compactMap { invoice -> (invoice: Invoice, balance: Double)? in
            let balance = outstandingBalance(for: invoice, payments: customerPayments)
            guard balance > 0 else { return nil }
            return (invoice, balance)
        }
        let openBalance = openInvoiceBalances.reduce(0) { $0 + $1.balance }
        let overdueCutoff = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let overdueInvoices = openInvoiceBalances.filter { $0.invoice.createdAt <= overdueCutoff }

        let openEstimates = customerEstimates.filter {
            let status = $0.status.lowercased()
            return status != "rejected" && status != "invoiced"
        }

        let readyToBillCalls = customerCalls.filter(\.isReadyToCreateBillingDocument)

        let followUpCalls = customerCalls.filter { call in
            call.followUpRequired || (call.type == .estimate && call.linkedInvoiceID == nil)
        }

        let activeContracts = customerContracts.filter(\.active)
        let nextContract = activeContracts.sorted { $0.nextDate < $1.nextDate }.first
        let contractNeedsAttention = activeContracts.contains {
            $0.isOverdue || $0.isUpcoming || $0.needsReminder
        }

        let nextJob = customerCalls
            .filter { $0.status != .completed && $0.status != .cancelled }
            .sorted { lhs, rhs in
                let lhsPast = lhs.scheduledDate < now
                let rhsPast = rhs.scheduledDate < now
                if lhsPast != rhsPast { return !lhsPast }
                return lhs.scheduledDate < rhs.scheduledDate
            }
            .first

        let lastCompletedJob = customerCalls
            .filter { $0.status == .completed || $0.documentationCompletedAt != nil }
            .sorted { $0.scheduledDate > $1.scheduledDate }
            .first

        let syncAttentionCount = customerPayments.filter(\.needsQuickBooksAttention).count
        let missingContactDetailCount = missingContactDetails(for: customer)

        let healthScore = healthScore(
            openBalance: openBalance,
            overdueInvoiceCount: overdueInvoices.count,
            followUpCount: followUpCalls.count,
            readyToBillCount: readyToBillCalls.count,
            syncAttentionCount: syncAttentionCount,
            missingContactDetailCount: missingContactDetailCount,
            hasActiveContract: !activeContracts.isEmpty,
            contractNeedsAttention: contractNeedsAttention,
            nextJobIsUnassigned: nextJob?.assignedTechnician == nil && nextJob != nil
        )

        let action = primaryAction(
            customer: customer,
            openInvoiceBalances: openInvoiceBalances,
            overdueInvoices: overdueInvoices,
            readyToBillCalls: readyToBillCalls,
            followUpCalls: followUpCalls,
            contractNeedsAttention: contractNeedsAttention,
            nextContract: nextContract,
            nextJob: nextJob,
            syncAttentionCount: syncAttentionCount,
            missingContactDetailCount: missingContactDetailCount
        )

        let priorityScore = Double(100 - healthScore)
            + min(openBalance / 500, 30)
            + Double(overdueInvoices.count * 12)
            + Double(readyToBillCalls.count * 8)
            + Double(followUpCalls.count * 6)
            + Double(syncAttentionCount * 6)
            + (contractNeedsAttention ? 8 : 0)

        return CustomerIntelligenceSnapshot(
            id: customer.id,
            customer: customer,
            healthScore: healthScore,
            healthLabel: healthLabel(for: healthScore),
            openBalance: openBalance,
            openInvoiceCount: openInvoiceBalances.count,
            overdueInvoiceCount: overdueInvoices.count,
            openEstimateTotal: openEstimates.reduce(0) { $0 + $1.amount },
            openEstimateCount: openEstimates.count,
            readyToBillCount: readyToBillCalls.count,
            followUpCount: followUpCalls.count,
            syncAttentionCount: syncAttentionCount,
            missingContactDetailCount: missingContactDetailCount,
            activeContractCount: activeContracts.count,
            nextContract: nextContract,
            nextJob: nextJob,
            lastCompletedJob: lastCompletedJob,
            primaryAction: action.action,
            actionDetail: action.detail,
            priorityScore: priorityScore
        )
    }

    static func outstandingBalance(for invoice: Invoice, payments: [Payment]) -> Double {
        Invoice.outstandingBalance(for: invoice, payments: payments)
    }

    private static func primaryAction(
        customer: Customer,
        openInvoiceBalances: [(invoice: Invoice, balance: Double)],
        overdueInvoices: [(invoice: Invoice, balance: Double)],
        readyToBillCalls: [ServiceCall],
        followUpCalls: [ServiceCall],
        contractNeedsAttention: Bool,
        nextContract: RecurringMaintenanceContract?,
        nextJob: ServiceCall?,
        syncAttentionCount: Int,
        missingContactDetailCount: Int
    ) -> (action: CustomerIntelligenceAction, detail: String) {
        if let overdue = overdueInvoices.sorted(by: { $0.balance > $1.balance }).first {
            return (.collectPayment(overdue.invoice.id), "Overdue balance \(overdue.balance.formatted(.currency(code: "USD")))")
        }
        if let open = openInvoiceBalances.sorted(by: { $0.balance > $1.balance }).first {
            return (.collectPayment(open.invoice.id), "Collect open balance \(open.balance.formatted(.currency(code: "USD")))")
        }
        if let call = readyToBillCalls.sorted(by: { $0.scheduledDate > $1.scheduledDate }).first {
            return (.openDocumentation(call.id), "Build billing document for \(call.type.rawValue)")
        }
        if let call = followUpCalls.sorted(by: { ($0.followUpDueDate ?? $0.scheduledDate) < ($1.followUpDueDate ?? $1.scheduledDate) }).first {
            return (.openSchedule(call.id), "Follow up on \(call.type.rawValue)")
        }
        if contractNeedsAttention, let nextContract {
            return (.openCustomer(customer.id), "Service agreement due \(nextContract.nextDate.formatted(date: .abbreviated, time: .omitted))")
        }
        if let nextJob, nextJob.assignedTechnician == nil {
            return (.openSchedule(nextJob.id), "Assign upcoming work")
        }
        if syncAttentionCount > 0 {
            return (.openPayments, "Review payment sync status")
        }
        if missingContactDetailCount > 0 {
            return (.completeProfile(customer.id), "Complete contact profile")
        }
        if let nextJob {
            return (.openSchedule(nextJob.id), "Next job \(nextJob.scheduledDate.formatted(date: .abbreviated, time: .shortened))")
        }
        return (.openCustomer(customer.id), "Review customer record")
    }

    private static func healthScore(
        openBalance: Double,
        overdueInvoiceCount: Int,
        followUpCount: Int,
        readyToBillCount: Int,
        syncAttentionCount: Int,
        missingContactDetailCount: Int,
        hasActiveContract: Bool,
        contractNeedsAttention: Bool,
        nextJobIsUnassigned: Bool
    ) -> Int {
        let balancePenalty = openBalance > 0 ? min(24, 8 + Int(openBalance / 500)) : 0
        let overduePenalty = min(36, overdueInvoiceCount * 18)
        let followUpPenalty = min(18, followUpCount * 6)
        let readyToBillPenalty = min(12, readyToBillCount * 4)
        let syncPenalty = min(16, syncAttentionCount * 8)
        let contactPenalty = min(12, missingContactDetailCount * 4)
        let contractPenalty = contractNeedsAttention ? 8 : (hasActiveContract ? 0 : 4)
        let assignmentPenalty = nextJobIsUnassigned ? 5 : 0

        return max(
            0,
            100 - balancePenalty - overduePenalty - followUpPenalty - readyToBillPenalty - syncPenalty - contactPenalty - contractPenalty - assignmentPenalty
        )
    }

    private static func healthLabel(for score: Int) -> String {
        switch score {
        case 85...100:
            return "Excellent"
        case 70..<85:
            return "Stable"
        case 50..<70:
            return "Watch"
        default:
            return "At Risk"
        }
    }

    private static func missingContactDetails(for customer: Customer) -> Int {
        [customer.phone, customer.email, customer.address]
            .filter { value in
                value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            }
            .count
    }
}

private extension Array {
    func ifEmpty(_ fallback: [Element]) -> [Element] {
        isEmpty ? fallback : self
    }
}
