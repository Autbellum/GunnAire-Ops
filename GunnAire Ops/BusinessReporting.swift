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
    let laborCost: Double?
    let uncostedMinutes: Int
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
    let completedJobCount: Int
    let cancelledJobCount: Int
    let readyToBillCount: Int
    let correctiveVisitCount: Int
    let correctiveVisitRate: Double?
    let materialCost: Double
    let laborCost: Double
    let missingMaterialCostLineCount: Int
    let missingLaborTrackingJobCount: Int
    let uncostedLaborMinutes: Int
    let knownGrossProfit: Double?
    let knownGrossMargin: Double?
    let invoiceRevenueByWorkType: [InvoiceWorkType: Double]
    let jobCountByType: [ServiceCallType: Int]
    let technicianRows: [TechnicianReportRow]

    var hasFinancialActivity: Bool {
        invoiceCount > 0 || estimateCount > 0 || collectedRevenue != 0
    }

    var hasOperationalActivity: Bool {
        completedJobCount > 0 || cancelledJobCount > 0 || readyToBillCount > 0
    }

    var costCoverageComplete: Bool {
        missingMaterialCostLineCount == 0 &&
            missingLaborTrackingJobCount == 0 &&
            uncostedLaborMinutes == 0
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
        calendar: Calendar = .current
    ) -> BusinessReportSnapshot {
        let interval = period.interval(containing: now, calendar: calendar)
        let periodCalls = serviceCalls.filter { interval.contains($0.scheduledDate) }
        let periodInvoices = Invoice.displayDeduplicated(invoices).filter { interval.contains($0.createdAt) }
        let periodEstimates = Estimate.displayDeduplicated(estimates).filter { interval.contains($0.createdAt) }
        let periodPayments = payments.filter { interval.contains($0.date) }
        let periodTimeEntries = timeEntries.filter { interval.contains($0.clockIn) && $0.clockOut != nil }

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

        let laborSummary = JobLaborCosting.summary(entries: periodTimeEntries, technicians: technicians)
        let laborCost = laborSummary.totalCost ?? 0
        let invoiceJobIDs = Set(periodInvoices.compactMap(\.serviceCallID))
        let timeTrackedJobIDs = Set(periodTimeEntries.compactMap { $0.serviceCall?.id })
        let missingLaborTrackingJobCount = invoiceJobIDs.subtracting(timeTrackedJobIDs).count
        let costCoverageComplete = missingMaterialCostLineCount == 0 &&
            missingLaborTrackingJobCount == 0 &&
            laborSummary.uncostedMinutes == 0
        let knownGrossProfit = costCoverageComplete ? invoicedRevenue - materialCost - laborCost : nil
        let knownGrossMargin = knownGrossProfit.flatMap { profit in
            invoicedRevenue > 0 ? profit / invoicedRevenue : nil
        }

        let invoiceRevenueByWorkType = Dictionary(grouping: periodInvoices, by: \.workType)
            .mapValues { grouped in grouped.reduce(0) { $0 + $1.amount } }
        let jobCountByType = Dictionary(grouping: periodCalls.filter { $0.status != .cancelled }, by: \.type)
            .mapValues(\.count)

        let technicianRows = technicians.compactMap { technician -> TechnicianReportRow? in
            let technicianEntries = periodTimeEntries.filter {
                AppAccess.normalizedEmail($0.userEmail) == AppAccess.normalizedEmail(technician.contactInfo)
            }
            let technicianCalls = periodCalls.filter { $0.includesAssignedTechnician(technician.id) }
            guard !technicianEntries.isEmpty || !technicianCalls.isEmpty else { return nil }
            let costing = JobLaborCosting.summary(entries: technicianEntries, technicians: [technician])
            let minutes = technicianEntries.compactMap(\.durationMinutes).reduce(0, +)
            return TechnicianReportRow(
                id: technician.id,
                name: technician.name,
                completedJobs: technicianCalls.filter { $0.status == .completed || $0.status == .invoiced }.count,
                recordedHours: Double(minutes) / 60,
                laborCost: costing.totalCost,
                uncostedMinutes: costing.uncostedMinutes
            )
        }
        .sorted {
            if $0.completedJobs != $1.completedJobs { return $0.completedJobs > $1.completedJobs }
            if $0.recordedHours != $1.recordedHours { return $0.recordedHours > $1.recordedHours }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

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
            completedJobCount: completedCalls.count,
            cancelledJobCount: periodCalls.filter { $0.status == .cancelled }.count,
            readyToBillCount: periodCalls.filter(\.isReadyToCreateBillingDocument).count,
            correctiveVisitCount: correctiveVisits.count,
            correctiveVisitRate: completedCalls.isEmpty ? nil : Double(correctiveVisits.count) / Double(completedCalls.count),
            materialCost: materialCost,
            laborCost: laborCost,
            missingMaterialCostLineCount: missingMaterialCostLineCount,
            missingLaborTrackingJobCount: missingLaborTrackingJobCount,
            uncostedLaborMinutes: laborSummary.uncostedMinutes,
            knownGrossProfit: knownGrossProfit,
            knownGrossMargin: knownGrossMargin,
            invoiceRevenueByWorkType: invoiceRevenueByWorkType,
            jobCountByType: jobCountByType,
            technicianRows: technicianRows
        )
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
            ["Inclusion Rules", "Invoices and estimates by created date; jobs by scheduled date; collections by payment date less refunds; open balance includes all payments linked to selected-period invoices"],
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
            ["Completed Jobs", String(snapshot.completedJobCount)],
            ["Cancelled Jobs", String(snapshot.cancelledJobCount)],
            ["Ready To Bill", String(snapshot.readyToBillCount)],
            ["Callback or Warranty Visits", String(snapshot.correctiveVisitCount)],
            ["Corrective Visit Rate", snapshot.correctiveVisitRate.map(percent) ?? "Not available"],
            ["Known Material Cost", decimal(snapshot.materialCost)],
            ["Known Labor Cost", decimal(snapshot.laborCost)],
            ["Missing Material Cost Lines", String(snapshot.missingMaterialCostLineCount)],
            ["Invoiced Jobs Missing Labor Time", String(snapshot.missingLaborTrackingJobCount)],
            ["Uncosted Labor Minutes", String(snapshot.uncostedLaborMinutes)],
            ["Known Gross Profit", snapshot.knownGrossProfit.map(decimal) ?? "Incomplete cost coverage"],
            ["Known Gross Margin", snapshot.knownGrossMargin.map(percent) ?? "Incomplete cost coverage"],
            [],
            ["Technician", "Completed Jobs", "Recorded Hours", "Known Labor Cost", "Uncosted Minutes"]
        ]
        rows += snapshot.technicianRows.map { row in
            [
                row.name,
                String(row.completedJobs),
                String(format: "%.2f", row.recordedHours),
                row.laborCost.map(decimal) ?? "Not configured",
                String(row.uncostedMinutes)
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
