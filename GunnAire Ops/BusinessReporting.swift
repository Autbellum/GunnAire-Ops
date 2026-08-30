import Foundation

enum BusinessReportPeriod: String, CaseIterable, Identifiable {
    case currentMonth
    case previousMonth
    case last90Days
    case yearToDate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .currentMonth: "This Month"
        case .previousMonth: "Last Month"
        case .last90Days: "Last 90 Days"
        case .yearToDate: "Year to Date"
        }
    }

    func interval(containing now: Date, calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .currentMonth:
            let start = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
            return DateInterval(start: start, end: now.addingTimeInterval(1))
        case .previousMonth:
            let previous = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            return calendar.dateInterval(of: .month, for: previous) ?? DateInterval(start: previous, duration: 0)
        case .last90Days:
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -89, to: today) ?? today
            return DateInterval(start: start, end: now.addingTimeInterval(1))
        case .yearToDate:
            let start = calendar.dateInterval(of: .year, for: now)?.start ?? calendar.startOfDay(for: now)
            return DateInterval(start: start, end: now.addingTimeInterval(1))
        }
    }
}

struct TechnicianReportRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let completedJobs: Int
    let recordedHours: Double
    /// Completed customer job-labor time divided by all payable completed
    /// time in the reporting period. This is an activity mix, not sold-hour
    /// efficiency, payroll, or a compensation measure.
    let jobHours: Double
    let travelHours: Double
    let otherPaidHours: Double
    let jobTimeShare: Double?
    let laborCost: Double?
    let uncostedMinutes: Int
    /// Financial and sales metrics are intentionally attributed only to the
    /// lead technician on the linked job. Crew participation remains visible
    /// in `completedJobs` and time, but revenue is never counted twice.
    let leadCompletedJobs: Int
    let leadInvoicedRevenue: Double
    let leadInvoiceCount: Int
    let leadAverageInvoice: Double
    let leadEstimateOpportunityCount: Int
    let leadAcceptedOpportunityCount: Int
    let leadEstimateConversionRate: Double?
    let leadCorrectiveVisitCount: Int
    let leadCorrectiveVisitRate: Double?
}

/// One conservative profitability review for every job that has an invoice in
/// the selected reporting period. Revenue and material cost come from the
/// immutable invoice snapshots; labor and approved field expenses include the
/// complete linked-job history even when they predate the invoice.
struct JobProfitabilityRow: Identifiable, Equatable {
    let id: UUID
    let customerName: String
    let scheduledDate: Date
    let workType: InvoiceWorkType
    let invoiceCount: Int
    let invoicedRevenue: Double
    let materialCost: Double
    let laborCost: Double
    let approvedExpenseCost: Double
    let missingMaterialCostLineCount: Int
    let hasCompletedLaborTime: Bool
    let uncostedLaborMinutes: Int
    let knownGrossProfit: Double?
    let knownGrossMargin: Double?

    var costCoverageComplete: Bool {
        missingMaterialCostLineCount == 0 &&
            hasCompletedLaborTime &&
            uncostedLaborMinutes == 0
    }

    var needsCostReview: Bool { !costCoverageComplete }

    var costReviewDetail: String {
        var issues: [String] = []
        if missingMaterialCostLineCount > 0 {
            issues.append("\(missingMaterialCostLineCount) material cost gap\(missingMaterialCostLineCount == 1 ? "" : "s")")
        }
        if !hasCompletedLaborTime {
            issues.append("no completed labor time")
        } else if uncostedLaborMinutes > 0 {
            issues.append("\(uncostedLaborMinutes) uncosted min")
        }
        return issues.isEmpty ? "Material and labor coverage complete; approved field expenses included" : issues.joined(separator: " • ")
    }
}

/// Cohort reporting for service requests created inside the selected period.
/// Downstream estimates, invoices, and payments are attributed only when one
/// exact lead source owns the converted job. Conflicting request lineage stays
/// visible as an exception and never duplicates revenue across sources.
struct LeadSourceReportRow: Identifiable, Equatable {
    let source: ServiceRequestSource
    let requestCount: Int
    let scheduledRequestCount: Int
    let declinedRequestCount: Int
    let estimateOpportunityCount: Int
    let acceptedEstimateOpportunityCount: Int
    let invoicedRevenue: Double
    let collectedRevenue: Double

    var id: String { source.rawValue }

    var scheduledConversionRate: Double? {
        requestCount == 0 ? nil : Double(scheduledRequestCount) / Double(requestCount)
    }

    var estimateConversionRate: Double? {
        estimateOpportunityCount == 0
            ? nil
            : Double(acceptedEstimateOpportunityCount) / Double(estimateOpportunityCount)
    }
}

struct BusinessReportSnapshot {
    let period: BusinessReportPeriod
    let interval: DateInterval
    let generatedAt: Date
    let invoicedRevenue: Double
    let collectedRevenue: Double
    let openBalance: Double
    let invoiceCount: Int
    let averageInvoice: Double
    let estimateCount: Int
    let acceptedEstimateCount: Int
    let estimateConversionRate: Double?
    let openEstimatePipeline: Double
    let projectCount: Int
    let projectContractValue: Double
    let projectInvoicedAmount: Double
    let projectBacklog: Double
    let projectReadyToBillCount: Int
    let activeMaintenanceAgreementCount: Int
    let newMaintenanceAgreementCount: Int
    let renewedMaintenanceAgreementCount: Int
    let maintenanceAgreementValue: Double
    let maintenanceAgreementRenewalAttentionCount: Int
    let maintenanceAgreementVisitCount: Int
    let completedMaintenanceAgreementVisitCount: Int
    let maintenanceAgreementVisitFulfillmentRate: Double?
    let completedJobCount: Int
    let cancelledJobCount: Int
    let readyToBillCount: Int
    let correctiveVisitCount: Int
    let correctiveVisitRate: Double?
    let materialCost: Double
    let laborCost: Double
    let approvedExpenseCost: Double
    let pendingExpenseClaimCount: Int
    let pendingExpenseReimbursementAmount: Double
    let missingMaterialCostLineCount: Int
    let missingLaborTrackingJobCount: Int
    let uncostedLaborMinutes: Int
    let knownGrossProfit: Double?
    let knownGrossMargin: Double?
    let jobProfitabilityRows: [JobProfitabilityRow]
    let invoicesWithoutJobProfitabilityCount: Int
    let invoiceRevenueByWorkType: [InvoiceWorkType: Double]
    let jobCountByType: [ServiceCallType: Int]
    let technicianRows: [TechnicianReportRow]
    let leadSourceRows: [LeadSourceReportRow]
    let ambiguousLeadAttributionJobCount: Int

    var hasFinancialActivity: Bool {
        invoiceCount > 0 || estimateCount > 0 || projectCount > 0 ||
            activeMaintenanceAgreementCount > 0 || newMaintenanceAgreementCount > 0 ||
            collectedRevenue != 0 || approvedExpenseCost != 0 ||
            pendingExpenseClaimCount > 0 || pendingExpenseReimbursementAmount != 0
    }

    var hasOperationalActivity: Bool {
        completedJobCount > 0 || cancelledJobCount > 0 || readyToBillCount > 0 ||
            projectReadyToBillCount > 0 || maintenanceAgreementVisitCount > 0 ||
            maintenanceAgreementRenewalAttentionCount > 0
    }

    var hasLeadSourceActivity: Bool {
        !leadSourceRows.isEmpty || ambiguousLeadAttributionJobCount > 0
    }

    var costCoverageComplete: Bool {
        missingMaterialCostLineCount == 0 &&
            missingLaborTrackingJobCount == 0 &&
            uncostedLaborMinutes == 0
    }

    var jobProfitabilityAttentionCount: Int {
        jobProfitabilityRows.filter(\.needsCostReview).count + invoicesWithoutJobProfitabilityCount
    }
}

enum BusinessReporting {
    @MainActor
    static func snapshot(
        period: BusinessReportPeriod,
        now: Date = Date(),
        serviceCalls: [ServiceCall],
        estimates: [Estimate],
        invoices: [Invoice],
        payments: [Payment],
        timeEntries: [TimeEntry],
        technicians: [Technician],
        serviceRequests: [ServiceRequest] = [],
        projectMilestones: [ProjectMilestone] = [],
        maintenanceContracts: [RecurringMaintenanceContract] = [],
        expenseClaims: [FieldExpenseClaim] = [],
        calendar: Calendar = .current
    ) -> BusinessReportSnapshot {
        let interval = period.interval(containing: now, calendar: calendar)
        let periodCalls = uniqueServiceCalls(serviceCalls.filter { interval.contains($0.scheduledDate) })
        let periodInvoices = Invoice.displayDeduplicated(invoices).filter { interval.contains($0.createdAt) }
        let periodEstimates = Estimate.displayDeduplicated(estimates).filter { interval.contains($0.createdAt) }
        let periodPayments = payments.filter { interval.contains($0.date) }
        let periodTimeEntries = timeEntries.filter { interval.contains($0.clockIn) && $0.clockOut != nil }
        let periodServiceRequests = uniqueServiceRequests(
            serviceRequests.filter { interval.contains($0.createdAt) }
        )

        let serviceCallsByID = uniqueServiceCalls(serviceCalls).reduce(into: [UUID: ServiceCall]()) { result, call in
            result[call.id] = call
        }

        let invoicedRevenue = periodInvoices.reduce(0) { $0 + $1.amount }
        let collectedRevenue = periodPayments.reduce(0) { partial, payment in
            partial + (payment.isRefund ? -payment.amount : payment.amount)
        }
        let openBalance = periodInvoices.reduce(0) { partial, invoice in
            partial + Invoice.outstandingBalance(for: invoice, payments: payments)
        }
        let acceptedEstimates = periodEstimates.filter {
            $0.status.caseInsensitiveCompare("accepted") == .orderedSame ||
                $0.status.caseInsensitiveCompare("invoiced") == .orderedSame
        }
        let openEstimatePipeline = periodEstimates
            .filter { $0.status.caseInsensitiveCompare("pending") == .orderedSame }
            .reduce(0) { $0 + $1.amount }
        let periodCallIDs = Set(periodCalls.map(\.id))
        let periodProjectMilestones = projectMilestones.filter { periodCallIDs.contains($0.projectServiceCallID) }
        let projectGroups = Dictionary(grouping: periodProjectMilestones, by: \.projectServiceCallID)
        let projectContractValue = projectGroups.values.reduce(0) { partial, milestones in
            partial + milestones.reduce(0) { $0 + $1.plannedAmount }
        }
        let milestoneInvoiceIDs = Set(periodProjectMilestones.compactMap(\.invoiceID))
        let projectInvoices = invoices.filter { milestoneInvoiceIDs.contains($0.id) }
        let projectInvoicedAmount = projectInvoices.reduce(0) { $0 + $1.amount }
        let projectReadyToBillCount = periodProjectMilestones.filter { milestone in
            milestone.invoiceID == nil && (milestone.completedAt != nil || milestone.billingTrigger == .customerApproval)
        }.count
        let reportDay = calendar.startOfDay(for: now)
        let activeMaintenanceContracts = maintenanceContracts.filter { contract in
            guard contract.active, contract.lifecycleStatus == .active else { return false }
            return contract.termEndsOn.map { calendar.startOfDay(for: $0) >= reportDay } ?? true
        }
        let newMaintenanceAgreementCount = maintenanceContracts.filter { contract in
            contract.lifecycle?.approvedAt.map(interval.contains) == true
        }.count
        let renewedMaintenanceAgreementCount = maintenanceContracts.filter { contract in
            contract.lifecycle?.renewedAt.map(interval.contains) == true
        }.count
        let maintenanceAgreementValue = activeMaintenanceContracts.reduce(0) { partial, contract in
            partial + normalizedMaintenanceAgreementValue(contract)
        }
        let maintenanceAgreementRenewalAttentionCount = maintenanceContracts.filter { contract in
            guard contract.active,
                  contract.lifecycleStatus == .active,
                  let reminderDate = contract.renewalReminderDate else { return false }
            return reminderDate <= now
        }.count
        let maintenanceAgreementVisits = serviceCalls.filter { call in
            guard call.maintenanceAgreementID != nil else { return false }
            return interval.contains(call.maintenanceAgreementDueDate ?? call.scheduledDate)
        }
        let completedMaintenanceAgreementVisits = maintenanceAgreementVisits.filter {
            $0.status == .completed || $0.status == .invoiced
        }
        let completedCalls = periodCalls.filter { $0.status == .completed || $0.status == .invoiced }
        let correctiveVisits = completedCalls.filter { $0.visitDisposition == .callback || $0.visitDisposition == .warranty }

        var materialCost = 0.0
        var missingMaterialCostLineCount = 0
        for invoice in periodInvoices {
            let lines = invoice.catalogLineSnapshots
            if lines.isEmpty && invoice.amount > 0 {
                missingMaterialCostLineCount += 1
            }
            for line in lines {
                if let cost = line.purchaseCost {
                    materialCost += cost * line.quantity
                } else {
                    missingMaterialCostLineCount += 1
                }
            }
        }

        let invoiceJobIDs = Set(periodInvoices.compactMap(\.serviceCallID))
        let approvedJobExpenseClaims = expenseClaims.filter { claim in
            claim.isApprovedJobCost &&
                claim.serviceCallID.map(invoiceJobIDs.contains) == true
        }
        let approvedExpenseCost = approvedJobExpenseClaims.reduce(0) { $0 + $1.amount }
        let periodExpenseClaims = expenseClaims.filter { interval.contains($0.expenseDate) }
        let pendingExpenseClaimCount = periodExpenseClaims.filter(\.needsOfficeReview).count
        let pendingExpenseReimbursementAmount = periodExpenseClaims
            .filter(\.needsReimbursement)
            .reduce(0) { $0 + $1.amount }
        // Job profitability follows invoiced work, not every time entry that
        // happens to fall in the report period. Include the full completed
        // labor history for those jobs so a month-end invoice is not shown
        // without labor merely because the technician worked in a prior week.
        let invoiceJobTimeEntries = timeEntries.filter { entry in
            guard entry.clockOut != nil,
                  let serviceCallID = entry.serviceCall?.id else { return false }
            return invoiceJobIDs.contains(serviceCallID)
        }
        let laborSummary = JobLaborCosting.summary(entries: invoiceJobTimeEntries, technicians: technicians)
        let laborCost: Double = laborSummary.totalCost ?? 0
        let timeTrackedJobIDs: Set<UUID> = Set(invoiceJobTimeEntries.compactMap { entry -> UUID? in
            guard entry.activity == .job,
                  (entry.payableDurationMinutes ?? 0) > 0 else { return nil }
            return entry.serviceCall?.id
        })
        let missingLaborTrackingJobCount = invoiceJobIDs.subtracting(timeTrackedJobIDs).count
        let costCoverageComplete = missingMaterialCostLineCount == 0 &&
            missingLaborTrackingJobCount == 0 &&
            laborSummary.uncostedMinutes == 0
        let knownGrossProfit = costCoverageComplete
            ? invoicedRevenue - materialCost - laborCost - approvedExpenseCost
            : nil
        let knownGrossMargin = knownGrossProfit.flatMap { profit in
            invoicedRevenue > 0 ? profit / invoicedRevenue : nil
        }

        let jobProfitabilityRows = makeJobProfitabilityRows(
            invoices: periodInvoices,
            serviceCallsByID: serviceCallsByID,
            timeEntries: timeEntries,
            technicians: technicians,
            expenseClaims: expenseClaims
        )
        let linkedProfitabilityInvoiceIDs = Set(
            periodInvoices.compactMap { invoice -> UUID? in
                guard let serviceCallID = invoice.serviceCallID,
                      serviceCallsByID[serviceCallID] != nil else { return nil }
                return invoice.id
            }
        )
        let invoicesWithoutJobProfitabilityCount = periodInvoices.filter {
            !linkedProfitabilityInvoiceIDs.contains($0.id)
        }.count

        let invoiceRevenueByWorkType = Dictionary(grouping: periodInvoices, by: \.workType)
            .mapValues { grouped in grouped.reduce(0) { $0 + $1.amount } }
        let jobCountByType = Dictionary(grouping: periodCalls.filter { $0.status != .cancelled }, by: \.type)
            .mapValues(\.count)

        let leadTechnicianIDsByCallID = serviceCalls.reduce(into: [UUID: Set<UUID>]()) { result, call in
            if let leadID = call.assignedTechnician?.id {
                result[call.id, default: []].insert(leadID)
            }
        }
        let technicianRows = technicians.compactMap { technician -> TechnicianReportRow? in
            let technicianEntries = periodTimeEntries.filter {
                AppAccess.normalizedEmail($0.userEmail) == AppAccess.normalizedEmail(technician.contactInfo)
            }
            let technicianCalls = periodCalls.filter { $0.includesAssignedTechnician(technician.id) }
            let leadCalls = periodCalls.filter { call in
                leadTechnicianIDsByCallID[call.id] == Set([technician.id])
            }
            let leadInvoices = periodInvoices.filter { invoice in
                guard let callID = invoice.serviceCallID else { return false }
                return leadTechnicianIDsByCallID[callID] == Set([technician.id])
            }
            let leadEstimates = periodEstimates.filter { estimate in
                guard let callID = estimate.serviceCallID else { return false }
                return leadTechnicianIDsByCallID[callID] == Set([technician.id])
            }
            guard !technicianEntries.isEmpty || !technicianCalls.isEmpty ||
                    !leadInvoices.isEmpty || !leadEstimates.isEmpty else { return nil }
            let costing = JobLaborCosting.summary(entries: technicianEntries, technicians: [technician])
            let payableMinutes = technicianEntries.compactMap(\.payableDurationMinutes).reduce(0, +)
            let jobMinutes = technicianEntries
                .filter { $0.activity == .job }
                .compactMap(\.payableDurationMinutes)
                .reduce(0, +)
            let travelMinutes = technicianEntries
                .filter { $0.activity == .travel }
                .compactMap(\.payableDurationMinutes)
                .reduce(0, +)
            let otherPaidMinutes = technicianEntries
                .filter {
                    $0.activity != .job &&
                        $0.activity != .travel &&
                        $0.activity.countsTowardPayableTime
                }
                .compactMap(\.payableDurationMinutes)
                .reduce(0, +)
            let completedLeadCalls = leadCalls.filter { $0.status == .completed || $0.status == .invoiced }
            let correctiveLeadCalls = completedLeadCalls.filter {
                $0.visitDisposition == .callback || $0.visitDisposition == .warranty
            }
            let leadRevenue = leadInvoices.reduce(0) { $0 + $1.amount }
            let opportunitySummary = estimateOpportunitySummary(leadEstimates)
            return TechnicianReportRow(
                id: technician.id,
                name: technician.name,
                completedJobs: technicianCalls.filter { $0.status == .completed || $0.status == .invoiced }.count,
                recordedHours: Double(payableMinutes) / 60,
                jobHours: Double(jobMinutes) / 60,
                travelHours: Double(travelMinutes) / 60,
                otherPaidHours: Double(otherPaidMinutes) / 60,
                jobTimeShare: payableMinutes == 0 ? nil : Double(jobMinutes) / Double(payableMinutes),
                laborCost: costing.totalCost,
                uncostedMinutes: costing.uncostedMinutes,
                leadCompletedJobs: completedLeadCalls.count,
                leadInvoicedRevenue: leadRevenue,
                leadInvoiceCount: leadInvoices.count,
                leadAverageInvoice: leadInvoices.isEmpty ? 0 : leadRevenue / Double(leadInvoices.count),
                leadEstimateOpportunityCount: opportunitySummary.total,
                leadAcceptedOpportunityCount: opportunitySummary.accepted,
                leadEstimateConversionRate: opportunitySummary.total == 0
                    ? nil
                    : Double(opportunitySummary.accepted) / Double(opportunitySummary.total),
                leadCorrectiveVisitCount: correctiveLeadCalls.count,
                leadCorrectiveVisitRate: completedLeadCalls.isEmpty
                    ? nil
                    : Double(correctiveLeadCalls.count) / Double(completedLeadCalls.count)
            )
        }
        .sorted {
            if $0.completedJobs != $1.completedJobs { return $0.completedJobs > $1.completedJobs }
            if $0.leadInvoicedRevenue != $1.leadInvoicedRevenue { return $0.leadInvoicedRevenue > $1.leadInvoicedRevenue }
            if $0.recordedHours != $1.recordedHours { return $0.recordedHours > $1.recordedHours }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let leadSourceSummary = makeLeadSourceRows(
            requests: periodServiceRequests,
            estimates: Estimate.displayDeduplicated(estimates),
            invoices: Invoice.displayDeduplicated(invoices),
            payments: payments
        )

        return BusinessReportSnapshot(
            period: period,
            interval: interval,
            generatedAt: now,
            invoicedRevenue: invoicedRevenue,
            collectedRevenue: collectedRevenue,
            openBalance: openBalance,
            invoiceCount: periodInvoices.count,
            averageInvoice: periodInvoices.isEmpty ? 0 : invoicedRevenue / Double(periodInvoices.count),
            estimateCount: periodEstimates.count,
            acceptedEstimateCount: acceptedEstimates.count,
            estimateConversionRate: periodEstimates.isEmpty ? nil : Double(acceptedEstimates.count) / Double(periodEstimates.count),
            openEstimatePipeline: openEstimatePipeline,
            projectCount: projectGroups.count,
            projectContractValue: projectContractValue,
            projectInvoicedAmount: projectInvoicedAmount,
            projectBacklog: max(projectContractValue - projectInvoicedAmount, 0),
            projectReadyToBillCount: projectReadyToBillCount,
            activeMaintenanceAgreementCount: activeMaintenanceContracts.count,
            newMaintenanceAgreementCount: newMaintenanceAgreementCount,
            renewedMaintenanceAgreementCount: renewedMaintenanceAgreementCount,
            maintenanceAgreementValue: maintenanceAgreementValue,
            maintenanceAgreementRenewalAttentionCount: maintenanceAgreementRenewalAttentionCount,
            maintenanceAgreementVisitCount: maintenanceAgreementVisits.count,
            completedMaintenanceAgreementVisitCount: completedMaintenanceAgreementVisits.count,
            maintenanceAgreementVisitFulfillmentRate: maintenanceAgreementVisits.isEmpty
                ? nil
                : Double(completedMaintenanceAgreementVisits.count) / Double(maintenanceAgreementVisits.count),
            completedJobCount: completedCalls.count,
            cancelledJobCount: periodCalls.filter { $0.status == .cancelled }.count,
            readyToBillCount: periodCalls.filter(\.isReadyToCreateBillingDocument).count,
            correctiveVisitCount: correctiveVisits.count,
            correctiveVisitRate: completedCalls.isEmpty ? nil : Double(correctiveVisits.count) / Double(completedCalls.count),
            materialCost: materialCost,
            laborCost: laborCost,
            approvedExpenseCost: approvedExpenseCost,
            pendingExpenseClaimCount: pendingExpenseClaimCount,
            pendingExpenseReimbursementAmount: pendingExpenseReimbursementAmount,
            missingMaterialCostLineCount: missingMaterialCostLineCount,
            missingLaborTrackingJobCount: missingLaborTrackingJobCount,
            uncostedLaborMinutes: laborSummary.uncostedMinutes,
            knownGrossProfit: knownGrossProfit,
            knownGrossMargin: knownGrossMargin,
            jobProfitabilityRows: jobProfitabilityRows,
            invoicesWithoutJobProfitabilityCount: invoicesWithoutJobProfitabilityCount,
            invoiceRevenueByWorkType: invoiceRevenueByWorkType,
            jobCountByType: jobCountByType,
            technicianRows: technicianRows,
            leadSourceRows: leadSourceSummary.rows,
            ambiguousLeadAttributionJobCount: leadSourceSummary.ambiguousJobCount
        )
    }

    /// CloudKit can briefly surface duplicate local representations while
    /// merging. Reporting must not turn that into duplicated work counts.
    private static func uniqueServiceCalls(_ calls: [ServiceCall]) -> [ServiceCall] {
        var selected: [UUID: ServiceCall] = [:]
        for call in calls where selected[call.id] == nil {
            selected[call.id] = call
        }
        return Array(selected.values)
    }

    private static func uniqueServiceRequests(_ requests: [ServiceRequest]) -> [ServiceRequest] {
        var selected: [UUID: ServiceRequest] = [:]
        for request in requests where selected[request.id] == nil {
            selected[request.id] = request
        }
        return Array(selected.values)
    }

    @MainActor
    private static func makeLeadSourceRows(
        requests: [ServiceRequest],
        estimates: [Estimate],
        invoices: [Invoice],
        payments: [Payment]
    ) -> (rows: [LeadSourceReportRow], ambiguousJobCount: Int) {
        var sourceCandidatesByJobID: [UUID: Set<ServiceRequestSource>] = [:]
        for request in requests {
            guard let jobID = request.convertedServiceCallID else { continue }
            sourceCandidatesByJobID[jobID, default: []].insert(request.leadSource)
        }

        var sourceByJobID: [UUID: ServiceRequestSource] = [:]
        var ambiguousJobCount = 0
        for (jobID, candidates) in sourceCandidatesByJobID {
            guard candidates.count == 1, let source = candidates.first else {
                ambiguousJobCount += 1
                continue
            }
            sourceByJobID[jobID] = source
        }

        let groupedRequests = Dictionary(grouping: requests, by: \.leadSource)
        let rows = groupedRequests.compactMap { source, sourceRequests -> LeadSourceReportRow? in
            guard !sourceRequests.isEmpty else { return nil }
            let sourceJobIDs = Set(sourceByJobID.compactMap { jobID, jobSource in
                jobSource == source ? jobID : nil
            })
            let sourceEstimates = estimates.filter { estimate in
                estimate.serviceCallID.map(sourceJobIDs.contains) == true
            }
            let opportunitySummary = estimateOpportunitySummary(sourceEstimates)
            let sourceInvoices = invoices.filter { invoice in
                invoice.serviceCallID.map(sourceJobIDs.contains) == true
            }
            let sourceInvoiceIDs = Set(sourceInvoices.map(\.id))
            let sourcePayments = payments.filter { payment in
                payment.invoice.map { sourceInvoiceIDs.contains($0.id) } ?? false
            }

            return LeadSourceReportRow(
                source: source,
                requestCount: sourceRequests.count,
                scheduledRequestCount: sourceRequests.filter {
                    $0.status == .scheduled || $0.convertedServiceCallID != nil
                }.count,
                declinedRequestCount: sourceRequests.filter { $0.status == .declined }.count,
                estimateOpportunityCount: opportunitySummary.total,
                acceptedEstimateOpportunityCount: opportunitySummary.accepted,
                invoicedRevenue: sourceInvoices.reduce(0) { $0 + $1.amount },
                collectedRevenue: sourcePayments.reduce(0) { partial, payment in
                    partial + (payment.isRefund ? -payment.amount : payment.amount)
                }
            )
        }
        .sorted { lhs, rhs in
            if lhs.requestCount != rhs.requestCount { return lhs.requestCount > rhs.requestCount }
            if lhs.invoicedRevenue != rhs.invoicedRevenue { return lhs.invoicedRevenue > rhs.invoicedRevenue }
            return lhs.source.displayName.localizedCaseInsensitiveCompare(rhs.source.displayName) == .orderedAscending
        }

        return (rows, ambiguousJobCount)
    }

    @MainActor
    private static func makeJobProfitabilityRows(
        invoices: [Invoice],
        serviceCallsByID: [UUID: ServiceCall],
        timeEntries: [TimeEntry],
        technicians: [Technician],
        expenseClaims: [FieldExpenseClaim]
    ) -> [JobProfitabilityRow] {
        let invoicesByJobID = Dictionary(
            grouping: invoices.compactMap { invoice -> (UUID, Invoice)? in
                guard let serviceCallID = invoice.serviceCallID,
                      serviceCallsByID[serviceCallID] != nil else { return nil }
                return (serviceCallID, invoice)
            },
            by: { $0.0 }
        )

        return invoicesByJobID.compactMap { jobID, groupedPairs in
            guard let call = serviceCallsByID[jobID] else { return nil }
            let groupedInvoices = groupedPairs.map { $0.1 }
            let revenue = groupedInvoices.reduce(0) { $0 + $1.amount }

            var materialCost = 0.0
            var missingMaterialCostLineCount = 0
            for invoice in groupedInvoices {
                let lines = invoice.catalogLineSnapshots
                if lines.isEmpty && invoice.amount > 0 {
                    missingMaterialCostLineCount += 1
                }
                for line in lines {
                    if let cost = line.purchaseCost, cost.isFinite, cost >= 0 {
                        materialCost += cost * line.quantity
                    } else {
                        missingMaterialCostLineCount += 1
                    }
                }
            }

            let jobEntries = timeEntries.filter { entry in
                entry.clockOut != nil && entry.serviceCall?.id == jobID
            }
            let labor = JobLaborCosting.summary(entries: jobEntries, technicians: technicians)
            let hasCompletedLaborTime = labor.hasCompletedTime
            let coverageComplete = missingMaterialCostLineCount == 0 &&
                hasCompletedLaborTime &&
                labor.uncostedMinutes == 0
            let laborCost = labor.totalCost ?? 0
            let approvedExpenseCost = expenseClaims
                .filter { $0.serviceCallID == jobID && $0.isApprovedJobCost }
                .reduce(0) { $0 + $1.amount }
            let knownGrossProfit = coverageComplete
                ? revenue - materialCost - laborCost - approvedExpenseCost
                : nil
            let knownGrossMargin = knownGrossProfit.flatMap { profit in
                revenue > 0 ? profit / revenue : nil
            }

            return JobProfitabilityRow(
                id: jobID,
                customerName: normalizedDisplayName(call.customer?.name)
                    ?? normalizedDisplayName(groupedInvoices.first?.customer?.name)
                    ?? "Customer unavailable",
                scheduledDate: call.scheduledDate,
                workType: InvoiceWorkType.inferred(from: call),
                invoiceCount: groupedInvoices.count,
                invoicedRevenue: revenue,
                materialCost: materialCost,
                laborCost: laborCost,
                approvedExpenseCost: approvedExpenseCost,
                missingMaterialCostLineCount: missingMaterialCostLineCount,
                hasCompletedLaborTime: hasCompletedLaborTime,
                uncostedLaborMinutes: labor.uncostedMinutes,
                knownGrossProfit: knownGrossProfit,
                knownGrossMargin: knownGrossMargin
            )
        }
        .sorted { lhs, rhs in
            if lhs.needsCostReview != rhs.needsCostReview {
                return lhs.needsCostReview && !rhs.needsCostReview
            }
            if lhs.scheduledDate != rhs.scheduledDate {
                return lhs.scheduledDate > rhs.scheduledDate
            }
            return lhs.customerName.localizedCaseInsensitiveCompare(rhs.customerName) == .orderedAscending
        }
    }

    private static func normalizedDisplayName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// Good/Better/Best options are one sales opportunity, not three. Change
    /// orders and standalone estimates retain their own identity.
    private static func estimateOpportunitySummary(_ estimates: [Estimate]) -> (total: Int, accepted: Int) {
        var statusesByOpportunity: [String: Set<String>] = [:]
        for estimate in estimates {
            let key = estimate.proposalGroupID.map { "proposal:\($0.uuidString.lowercased())" }
                ?? "estimate:\(estimate.id.uuidString.lowercased())"
            statusesByOpportunity[key, default: []].insert(
                estimate.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }
        let accepted = statusesByOpportunity.values.filter { statuses in
            statuses.contains("accepted") || statuses.contains("invoiced")
        }.count
        return (statusesByOpportunity.count, accepted)
    }

    /// Normalizes the value of an active agreement for a comparable business
    /// report without implying that a provider has billed or collected it.
    /// Monthly and per-visit plans are annualized; annual and full-term plans
    /// retain the customer-approved amount entered on the agreement.
    private static func normalizedMaintenanceAgreementValue(_ contract: RecurringMaintenanceContract) -> Double {
        let enteredPrice = contract.agreementPrice ?? contract.pricePerVisit ?? 0
        guard enteredPrice.isFinite, enteredPrice >= 0 else { return 0 }
        switch contract.billingInterval {
        case .monthly:
            return enteredPrice * 12
        case .perVisit:
            return enteredPrice * Double(max(contract.includedVisitsPerTerm ?? 1, 1))
        case .annual, .fullTerm:
            return enteredPrice
        }
    }
}

enum BusinessReportCSV {
    static func render(_ snapshot: BusinessReportSnapshot) -> String {
        var rows: [[String]] = [
            ["GunnAire Business Report", snapshot.period.displayName],
            ["Period Start", snapshot.interval.start.formatted(.iso8601)],
            ["Period End", snapshot.interval.end.formatted(.iso8601)],
            ["Generated At", snapshot.generatedAt.formatted(.iso8601)],
            ["Data Source", "Current GunnAire operational records"],
            ["Inclusion Rules", "Invoices and estimates by created date; jobs by scheduled date; collections by payment date less refunds; open balance includes all payments linked to selected-period invoices; profitability uses immutable invoice material costs, all completed labor, and approved field expense claims linked to each selected-period invoiced job; pending claim and reimbursement totals use expense date in the selected period; lead sources use requests created in the period and linked outcomes as of generation time; conflicting job-source lineage is excluded from source revenue; technician time mix uses completed entries by activity, excludes unpaid breaks, and is not sold-hour efficiency or payroll"],
            [],
            ["Metric", "Value"],
            ["Invoiced Revenue", decimal(snapshot.invoicedRevenue)],
            ["Collected Revenue", decimal(snapshot.collectedRevenue)],
            ["Open Balance", decimal(snapshot.openBalance)],
            ["Invoice Count", String(snapshot.invoiceCount)],
            ["Average Invoice", decimal(snapshot.averageInvoice)],
            ["Estimate Count", String(snapshot.estimateCount)],
            ["Accepted Estimates", String(snapshot.acceptedEstimateCount)],
            ["Estimate Conversion", snapshot.estimateConversionRate.map(percent) ?? "Not available"],
            ["Open Estimate Pipeline", decimal(snapshot.openEstimatePipeline)],
            ["Project Count", String(snapshot.projectCount)],
            ["Project Contract Value", decimal(snapshot.projectContractValue)],
            ["Project Invoiced", decimal(snapshot.projectInvoicedAmount)],
            ["Project Backlog", decimal(snapshot.projectBacklog)],
            ["Project Milestones Ready To Bill", String(snapshot.projectReadyToBillCount)],
            ["Active Maintenance Agreements", String(snapshot.activeMaintenanceAgreementCount)],
            ["New Maintenance Agreements", String(snapshot.newMaintenanceAgreementCount)],
            ["Renewed Maintenance Agreements", String(snapshot.renewedMaintenanceAgreementCount)],
            ["Active Maintenance Agreement Value", decimal(snapshot.maintenanceAgreementValue)],
            ["Maintenance Renewals Needing Attention", String(snapshot.maintenanceAgreementRenewalAttentionCount)],
            ["Maintenance Agreement Visits", String(snapshot.maintenanceAgreementVisitCount)],
            ["Completed Maintenance Agreement Visits", String(snapshot.completedMaintenanceAgreementVisitCount)],
            ["Maintenance Agreement Visit Fulfillment", snapshot.maintenanceAgreementVisitFulfillmentRate.map(percent) ?? "Not available"],
            ["Completed Jobs", String(snapshot.completedJobCount)],
            ["Cancelled Jobs", String(snapshot.cancelledJobCount)],
            ["Ready To Bill", String(snapshot.readyToBillCount)],
            ["Callback or Warranty Visits", String(snapshot.correctiveVisitCount)],
            ["Corrective Visit Rate", snapshot.correctiveVisitRate.map(percent) ?? "Not available"],
            ["Known Material Cost", decimal(snapshot.materialCost)],
            ["Known Labor Cost", decimal(snapshot.laborCost)],
            ["Approved Field Expense Cost", decimal(snapshot.approvedExpenseCost)],
            ["Pending Expense Claims", String(snapshot.pendingExpenseClaimCount)],
            ["Approved Reimbursements Pending Payment", decimal(snapshot.pendingExpenseReimbursementAmount)],
            ["Missing Material Cost Lines", String(snapshot.missingMaterialCostLineCount)],
            ["Invoiced Jobs Missing Labor Time", String(snapshot.missingLaborTrackingJobCount)],
            ["Uncosted Labor Minutes", String(snapshot.uncostedLaborMinutes)],
            ["Known Gross Profit", snapshot.knownGrossProfit.map(decimal) ?? "Incomplete cost coverage"],
            ["Known Gross Margin", snapshot.knownGrossMargin.map(percent) ?? "Incomplete cost coverage"],
            ["Invoices Without Linked Job Profitability", String(snapshot.invoicesWithoutJobProfitabilityCount)],
            ["Ambiguous Lead Attribution Jobs", String(snapshot.ambiguousLeadAttributionJobCount)],
            [],
            [
                "Lead Source", "Requests", "Scheduled", "Request To Scheduled", "Declined",
                "Estimate Opportunities", "Accepted Opportunities", "Estimate Conversion",
                "Invoiced Revenue", "Collected Revenue"
            ]
        ]
        rows += snapshot.leadSourceRows.map { row in
            [
                row.source.displayName,
                String(row.requestCount),
                String(row.scheduledRequestCount),
                row.scheduledConversionRate.map(percent) ?? "Not available",
                String(row.declinedRequestCount),
                String(row.estimateOpportunityCount),
                String(row.acceptedEstimateOpportunityCount),
                row.estimateConversionRate.map(percent) ?? "Not available",
                decimal(row.invoicedRevenue),
                decimal(row.collectedRevenue)
            ]
        }
        rows += [
            [],
            [
                "Job Profitability", "Scheduled", "Work Type", "Invoices", "Invoiced Revenue",
                "Known Material Cost", "Known Labor Cost", "Approved Field Expense Cost", "Material Cost Gaps", "Completed Labor",
                "Uncosted Minutes", "Known Gross Profit", "Known Gross Margin", "Cost Coverage"
            ]
        ]
        rows += snapshot.jobProfitabilityRows.map { row in
            [
                row.customerName,
                row.scheduledDate.formatted(.iso8601),
                row.workType.displayName,
                String(row.invoiceCount),
                decimal(row.invoicedRevenue),
                decimal(row.materialCost),
                decimal(row.laborCost),
                decimal(row.approvedExpenseCost),
                String(row.missingMaterialCostLineCount),
                row.hasCompletedLaborTime ? "Yes" : "No",
                String(row.uncostedLaborMinutes),
                row.knownGrossProfit.map(decimal) ?? "Incomplete cost coverage",
                row.knownGrossMargin.map(percent) ?? "Incomplete cost coverage",
                row.costReviewDetail
            ]
        }
        rows += [
            [],
            [
                "Technician", "Completed Assigned Jobs", "Recorded Hours", "Job Hours", "Travel Hours",
                "Other Paid Hours", "Job Time Mix", "Known Labor Cost", "Uncosted Minutes",
                "Lead Completed Jobs", "Lead Invoiced Revenue", "Lead Invoice Count", "Lead Average Invoice",
                "Lead Estimate Opportunities", "Lead Accepted Opportunities", "Lead Estimate Conversion",
                "Lead Corrective Visits", "Lead Corrective Rate"
            ]
        ]
        rows += snapshot.technicianRows.map { row in
            [
                row.name,
                String(row.completedJobs),
                String(format: "%.2f", row.recordedHours),
                String(format: "%.2f", row.jobHours),
                String(format: "%.2f", row.travelHours),
                String(format: "%.2f", row.otherPaidHours),
                row.jobTimeShare.map(percent) ?? "Not available",
                row.laborCost.map(decimal) ?? "Not configured",
                String(row.uncostedMinutes),
                String(row.leadCompletedJobs),
                decimal(row.leadInvoicedRevenue),
                String(row.leadInvoiceCount),
                decimal(row.leadAverageInvoice),
                String(row.leadEstimateOpportunityCount),
                String(row.leadAcceptedOpportunityCount),
                row.leadEstimateConversionRate.map(percent) ?? "Not available",
                String(row.leadCorrectiveVisitCount),
                row.leadCorrectiveVisitRate.map(percent) ?? "Not available"
            ]
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    nonisolated private static func decimal(_ value: Double) -> String { String(format: "%.2f", value) }
    nonisolated private static func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
    nonisolated private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
