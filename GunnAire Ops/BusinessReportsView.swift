import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private enum BusinessReportWorkspace: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case sales = "Sales"
    case operations = "Operations"
    case team = "Team"

    var id: String { rawValue }
}

private struct BusinessReportCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var content: String

    init(content: String) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        content = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(content.utf8))
    }
}

struct BusinessReportsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \TimeEntry.clockIn, order: .reverse) private var timeEntries: [TimeEntry]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \ServiceRequest.createdAt, order: .reverse) private var serviceRequests: [ServiceRequest]
    @Query(sort: \ProjectMilestone.plannedDate, order: .forward) private var projectMilestones: [ProjectMilestone]
    @Query(sort: \RecurringMaintenanceContract.nextDate, order: .forward) private var maintenanceContracts: [RecurringMaintenanceContract]

    @State private var period: BusinessReportPeriod = .currentMonth
    @State private var workspace: BusinessReportWorkspace = .overview
    @State private var showingExporter = false
    @State private var exportError: String?
    @State private var jobProfitabilityExpanded = false
    @State private var leadSourcePerformanceExpanded = false

    private var snapshot: BusinessReportSnapshot {
        BusinessReporting.snapshot(
            period: period,
            serviceCalls: serviceCalls,
            estimates: estimates,
            invoices: invoices,
            payments: payments,
            timeEntries: timeEntries,
            technicians: technicians,
            serviceRequests: serviceRequests,
            projectMilestones: projectMilestones,
            maintenanceContracts: maintenanceContracts
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    reportHeader

                    Picker("Report Workspace", selection: $workspace) {
                        ForEach(BusinessReportWorkspace.allCases) { section in
                            Text(section.rawValue).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("BusinessReportWorkspacePicker")

                    Group {
                        switch workspace {
                        case .overview: overviewWorkspace
                        case .sales: salesWorkspace
                        case .operations: operationsWorkspace
                        case .team: teamWorkspace
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: workspace)
                }
                .padding()
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Business Reports")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingExporter = true
                    } label: {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                    .disabled(
                        !snapshot.hasFinancialActivity &&
                            !snapshot.hasOperationalActivity &&
                            !snapshot.hasLeadSourceActivity
                    )
                }
            }
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: BusinessReportCSVDocument(content: BusinessReportCSV.render(snapshot)),
            contentType: .commaSeparatedText,
            defaultFilename: "GunnAire-\(period.rawValue)-report"
        ) { result in
            if case let .failure(error) = result { exportError = error.localizedDescription }
        }
        .alert("Report Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "The report could not be exported.")
        }
    }

    private var reportHeader: some View {
        Group {
            if horizontalSizeClass == .compact {
                VStack(alignment: .leading, spacing: 10) { reportHeaderContents }
            } else {
                HStack(alignment: .center, spacing: 16) { reportHeaderContents }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var reportHeaderContents: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Decision-ready reporting", systemImage: "chart.bar.xaxis")
                .font(.headline)
                .foregroundStyle(Color.brandGold)
            Text(periodSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Source: current GunnAire operational records • refreshes as app data changes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Picker("Reporting Period", selection: $period) {
            ForEach(BusinessReportPeriod.allCases) { reportPeriod in
                Text(reportPeriod.displayName).tag(reportPeriod)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("BusinessReportPeriodPicker")
    }

    private var overviewWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Financial Pulse", detail: "Invoice, collection, and cost coverage for the selected period.")
            metricGrid([
                ("Invoiced", currency(snapshot.invoicedRevenue), "\(snapshot.invoiceCount) invoices", "doc.text", Color.brandGold),
                ("Collected", currency(snapshot.collectedRevenue), "payments less refunds", "banknote", .green),
                ("Open Balance", currency(snapshot.openBalance), "selected-period invoices", "tray.full", snapshot.openBalance > 0 ? .orange : .green),
                ("Known Gross Margin", snapshot.knownGrossMargin.map(percent) ?? "Incomplete", costCoverageDetail, "chart.line.uptrend.xyaxis", snapshot.costCoverageComplete ? .green : .orange)
            ])

            reportingCard(title: "Cost Coverage", systemImage: "checklist.checked") {
                costCoverageRows
            }

            if !snapshot.jobProfitabilityRows.isEmpty || snapshot.invoicesWithoutJobProfitabilityCount > 0 {
                reportingCard(title: "Job Profitability", systemImage: "briefcase.fill") {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(snapshot.jobProfitabilityRows.count) linked job\(snapshot.jobProfitabilityRows.count == 1 ? "" : "s")")
                                .font(.subheadline.weight(.semibold))
                            Text("Invoices in this period; material snapshots and full completed job labor.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if snapshot.jobProfitabilityAttentionCount > 0 {
                            Label("\(snapshot.jobProfitabilityAttentionCount) need review", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        } else {
                            Label("Costed", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }

                    if snapshot.invoicesWithoutJobProfitabilityCount > 0 {
                        Label(
                            "\(snapshot.invoicesWithoutJobProfitabilityCount) invoice\(snapshot.invoicesWithoutJobProfitabilityCount == 1 ? " is" : "s are") not linked to an available job. It remains in period totals but cannot receive a job margin.",
                            systemImage: "link.badge.plus"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    if !snapshot.jobProfitabilityRows.isEmpty {
                        DisclosureGroup(isExpanded: $jobProfitabilityExpanded) {
                            LazyVStack(spacing: 10) {
                                ForEach(snapshot.jobProfitabilityRows) { row in
                                    JobProfitabilityReportRowView(row: row)
                                }
                            }
                            .padding(.top, 10)
                        } label: {
                            Text(jobProfitabilityExpanded ? "Hide job costing" : "Review job costing")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityIdentifier("JobProfitabilityDisclosure")
                    }
                }
                .accessibilityIdentifier("JobProfitabilityReportCard")
            }
        }
    }

    private var salesWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Sales Performance", detail: "Estimate conversion and invoiced work mix without changing accounting records.")
            metricGrid([
                ("Estimate Conversion", snapshot.estimateConversionRate.map(percent) ?? "—", "\(snapshot.acceptedEstimateCount) of \(snapshot.estimateCount) accepted", "checkmark.seal", Color.brandGold),
                ("Open Pipeline", currency(snapshot.openEstimatePipeline), "pending estimates", "doc.text.magnifyingglass", .blue),
                ("Average Invoice", currency(snapshot.averageInvoice), "\(snapshot.invoiceCount) invoices", "sum", .green),
                ("Collected", currency(snapshot.collectedRevenue), "payments less refunds", "creditcard", .green)
            ])

            if snapshot.hasLeadSourceActivity {
                reportingCard(title: "Lead Source Performance", systemImage: "point.3.connected.trianglepath.dotted") {
                    DisclosureGroup(isExpanded: $leadSourcePerformanceExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Requests are grouped by the date they entered the pipeline. Linked estimate, invoice, and collection outcomes are current as of report generation.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if snapshot.ambiguousLeadAttributionJobCount > 0 {
                                Label(
                                    "\(snapshot.ambiguousLeadAttributionJobCount) converted job\(snapshot.ambiguousLeadAttributionJobCount == 1 ? "" : "s") have conflicting source records. Their downstream revenue is excluded until the lead history is corrected.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }

                            ForEach(snapshot.leadSourceRows) { row in
                                leadSourceReportRow(row)
                            }
                        }
                        .padding(.top, 10)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(snapshot.leadSourceRows.reduce(0) { $0 + $1.requestCount }) request\(snapshot.leadSourceRows.reduce(0) { $0 + $1.requestCount } == 1 ? "" : "s")")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(snapshot.leadSourceRows.count) active source\(snapshot.leadSourceRows.count == 1 ? "" : "s") in this cohort")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(leadSourcePerformanceExpanded ? "Hide" : "Review")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.brandGold)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Review lead source performance")
                        .accessibilityValue(leadSourcePerformanceExpanded ? "Expanded" : "Collapsed")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("LeadSourcePerformanceReportCard")
            }

            reportingCard(title: "Revenue by Work Type", systemImage: "wrench.and.screwdriver") {
                ForEach(InvoiceWorkType.allCases) { workType in
                    valueRow(workType.displayName, value: currency(snapshot.invoiceRevenueByWorkType[workType] ?? 0))
                    if workType != InvoiceWorkType.allCases.last { Divider() }
                }
            }

            if snapshot.projectCount > 0 {
                reportingCard(title: "Project Billing", systemImage: "building.2") {
                    valueRow("Projects", value: "\(snapshot.projectCount)")
                    Divider()
                    valueRow("Approved contracts", value: currency(snapshot.projectContractValue))
                    Divider()
                    valueRow("Progress invoiced", value: currency(snapshot.projectInvoicedAmount))
                    Divider()
                    valueRow("Remaining backlog", value: currency(snapshot.projectBacklog))
                    if snapshot.projectReadyToBillCount > 0 {
                        Divider()
                        Label("\(snapshot.projectReadyToBillCount) milestone\(snapshot.projectReadyToBillCount == 1 ? "" : "s") ready for billing review.", systemImage: "doc.badge.plus")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .accessibilityIdentifier("ProjectBillingReportCard")
            }

            if snapshot.activeMaintenanceAgreementCount > 0 ||
                snapshot.newMaintenanceAgreementCount > 0 ||
                snapshot.renewedMaintenanceAgreementCount > 0 {
                reportingCard(title: "Maintenance Agreements", systemImage: "arrow.triangle.2.circlepath") {
                    valueRow("Active agreements", value: "\(snapshot.activeMaintenanceAgreementCount)")
                    Divider()
                    valueRow("New approvals", value: "\(snapshot.newMaintenanceAgreementCount)")
                    Divider()
                    valueRow("Renewed", value: "\(snapshot.renewedMaintenanceAgreementCount)")
                    Divider()
                    valueRow("Active agreement value", value: currency(snapshot.maintenanceAgreementValue))
                    Text("Monthly and per-visit plans are annualized; annual and full-term plans retain their approved amount. This is contracted value, not provider-confirmed billing or collection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if snapshot.maintenanceAgreementRenewalAttentionCount > 0 {
                        Divider()
                        Label(
                            "\(snapshot.maintenanceAgreementRenewalAttentionCount) agreement\(snapshot.maintenanceAgreementRenewalAttentionCount == 1 ? "" : "s") need renewal review.",
                            systemImage: "calendar.badge.exclamationmark"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                .accessibilityIdentifier("MaintenanceAgreementSalesReportCard")
            }
        }
    }

    private func leadSourceReportRow(_ row: LeadSourceReportRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.source.displayName)
                    .font(.headline)
                    .foregroundStyle(Color.brandGold)
                Spacer()
                Text("\(row.scheduledRequestCount) of \(row.requestCount) scheduled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                scorecardMetric(
                    "Request Conversion",
                    value: row.scheduledConversionRate.map(percent) ?? "—",
                    detail: "\(row.requestCount) request\(row.requestCount == 1 ? "" : "s")"
                )
                scorecardMetric(
                    "Estimate Close",
                    value: row.estimateConversionRate.map(percent) ?? "—",
                    detail: "\(row.acceptedEstimateOpportunityCount) of \(row.estimateOpportunityCount) opportunities"
                )
                scorecardMetric(
                    "Invoiced",
                    value: currency(row.invoicedRevenue),
                    detail: "linked job revenue"
                )
                scorecardMetric(
                    "Collected",
                    value: currency(row.collectedRevenue),
                    detail: "payments less refunds"
                )
            }

            if row.declinedRequestCount > 0 {
                Label(
                    "\(row.declinedRequestCount) request\(row.declinedRequestCount == 1 ? "" : "s") declined with retained reason evidence.",
                    systemImage: "xmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("LeadSourceReportRow-\(row.source.rawValue)")
    }

    private var operationsWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Operations Quality", detail: "Completion, billing readiness, and corrective-work trends.")
            metricGrid([
                ("Completed Jobs", "\(snapshot.completedJobCount)", "completed or invoiced", "checkmark.circle", .green),
                ("Ready To Bill", "\(snapshot.readyToBillCount)", "documentation complete", "doc.badge.plus", snapshot.readyToBillCount > 0 ? .orange : .green),
                ("Corrective Rate", snapshot.correctiveVisitRate.map(percent) ?? "—", "\(snapshot.correctiveVisitCount) callback or warranty", "arrow.uturn.backward.circle", snapshot.correctiveVisitCount > 0 ? .orange : .green),
                ("Cancelled", "\(snapshot.cancelledJobCount)", "selected period", "xmark.circle", snapshot.cancelledJobCount > 0 ? .orange : .secondary)
            ])

            reportingCard(title: "Job Mix", systemImage: "square.grid.2x2") {
                ForEach(ServiceCallType.allCases, id: \.rawValue) { type in
                    valueRow(type.displayName, value: "\(snapshot.jobCountByType[type] ?? 0)")
                    if type != ServiceCallType.allCases.last { Divider() }
                }
            }

            if snapshot.maintenanceAgreementVisitCount > 0 ||
                snapshot.maintenanceAgreementRenewalAttentionCount > 0 {
                reportingCard(title: "Agreement Delivery", systemImage: "checkmark.seal") {
                    valueRow("Visits due in period", value: "\(snapshot.maintenanceAgreementVisitCount)")
                    Divider()
                    valueRow("Completed visits", value: "\(snapshot.completedMaintenanceAgreementVisitCount)")
                    Divider()
                    valueRow(
                        "Visit fulfillment",
                        value: snapshot.maintenanceAgreementVisitFulfillmentRate.map(percent) ?? "—"
                    )
                    if snapshot.maintenanceAgreementRenewalAttentionCount > 0 {
                        Divider()
                        valueRow("Renewals needing attention", value: "\(snapshot.maintenanceAgreementRenewalAttentionCount)")
                    }
                    Text("Agreement visits are grouped by their stored obligation due date. Cancelled or unfinished visits remain unfulfilled so missed obligations are not hidden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("MaintenanceAgreementOperationsReportCard")
            }
        }
    }

    private var teamWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Team Scorecards", detail: "Assigned work, lead-job sales, quality, and recorded time in one reviewable lane.")
            if snapshot.technicianRows.isEmpty {
                ContentUnavailableView(
                    "No Team Activity",
                    systemImage: "person.2",
                    description: Text("No technician assignments or completed time entries fall inside this period.")
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                Label(
                    "Sales and callback metrics use the lead technician on the linked job. Crew participation still counts toward assigned work and time without counting revenue twice.",
                    systemImage: "person.2.badge.gearshape"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("Job Time Mix is completed customer Job Labor divided by all payable completed time. Travel and other paid activity stay visible; unpaid breaks are excluded. It is not sold-hour efficiency or payroll.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(snapshot.technicianRows) { row in
                    technicianScorecard(row)
                }
            }
        }
    }

    private func technicianScorecard(_ row: TechnicianReportRow) -> some View {
        DisclosureGroup {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                scorecardMetric(
                    "Assigned Completed",
                    value: "\(row.completedJobs)",
                    detail: "lead or crew"
                )
                scorecardMetric(
                    "Lead Completed",
                    value: "\(row.leadCompletedJobs)",
                    detail: "quality denominator"
                )
                scorecardMetric(
                    "Lead Invoiced",
                    value: currency(row.leadInvoicedRevenue),
                    detail: "\(row.leadInvoiceCount) invoice\(row.leadInvoiceCount == 1 ? "" : "s")"
                )
                scorecardMetric(
                    "Average Invoice",
                    value: row.leadInvoiceCount == 0 ? "—" : currency(row.leadAverageInvoice),
                    detail: "lead-linked jobs"
                )
                scorecardMetric(
                    "Estimate Close",
                    value: row.leadEstimateConversionRate.map(percent) ?? "—",
                    detail: "\(row.leadAcceptedOpportunityCount) of \(row.leadEstimateOpportunityCount) opportunities"
                )
                scorecardMetric(
                    "Corrective Rate",
                    value: row.leadCorrectiveVisitRate.map(percent) ?? "—",
                    detail: "\(row.leadCorrectiveVisitCount) callback or warranty"
                )
                scorecardMetric(
                    "Recorded Hours",
                    value: String(format: "%.1f", row.recordedHours),
                    detail: "completed time entries"
                )
                scorecardMetric(
                    "Job Time Mix",
                    value: row.jobTimeShare.map(percent) ?? "—",
                    detail: "\(hours(row.jobHours)) job of \(hours(row.recordedHours))"
                )
                scorecardMetric(
                    "Known Labor",
                    value: row.laborCost.map(currency) ?? "Not costed",
                    detail: "internal only"
                )
            }
            .padding(.top, 10)

            if row.recordedHours > 0 {
                Label(
                    "\(hours(row.travelHours)) travel • \(hours(row.otherPaidHours)) other paid",
                    systemImage: "clock.arrow.2.circlepath"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            }

            if row.uncostedMinutes > 0 {
                Label("\(row.uncostedMinutes) minutes excluded until this technician has an internal labor rate.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
        } label: {
            HStack(spacing: 12) {
                Label(row.name, systemImage: "person.crop.circle")
                    .font(.headline)
                    .foregroundStyle(Color.brandGold)
                Spacer()
                Text("\(row.completedJobs) jobs • \(String(format: "%.1f", row.recordedHours))h")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("TechnicianScorecard-\(row.id.uuidString)")
    }

    private func scorecardMetric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func hours(_ value: Double) -> String {
        String(format: "%.1fh", value)
    }

    private func metricGrid(_ metrics: [(String, String, String, String, Color)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: metric.3)
                        .foregroundStyle(metric.4)
                        .font(.title3)
                    Text(metric.1)
                        .font(.title2.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(metric.0)
                        .font(.subheadline.weight(.semibold))
                    Text(metric.2)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
                .padding(15)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func reportingCard<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(Color.brandGold)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var costCoverageRows: some View {
        valueRow("Known material cost", value: currency(snapshot.materialCost))
        Divider()
        valueRow("Known labor cost", value: currency(snapshot.laborCost))
        Divider()
        valueRow("Missing material costs", value: "\(snapshot.missingMaterialCostLineCount)")
        Divider()
        valueRow("Invoices missing labor time", value: "\(snapshot.missingLaborTrackingJobCount)")
        Divider()
        valueRow("Uncosted labor", value: "\(snapshot.uncostedLaborMinutes) min")
        if !snapshot.costCoverageComplete {
            Label("Profit and margin stay hidden until every invoiced line has a cost and every invoiced job has fully costed labor time. This prevents a partial margin from being mistaken for final job profitability.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 4)
        } else if let profit = snapshot.knownGrossProfit {
            Divider()
            valueRow("Known gross profit", value: currency(profit))
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title2.bold())
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func valueRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 2)
    }

    private var costCoverageDetail: String {
        if snapshot.costCoverageComplete { return "material + labor covered" }
        let gaps = snapshot.missingMaterialCostLineCount + snapshot.missingLaborTrackingJobCount
        return "\(gaps) cost gaps • \(snapshot.uncostedLaborMinutes) uncosted min"
    }

    private var periodSummary: String {
        let start = snapshot.interval.start.formatted(date: .abbreviated, time: .omitted)
        let end = snapshot.interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted)
        return "\(period.displayName) • \(start) – \(end)"
    }

    private func currency(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
    private func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(1))) }
}

private struct JobProfitabilityReportRowView: View {
    let row: JobProfitabilityRow

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                metric("Invoiced", value: currency(row.invoicedRevenue), detail: "\(row.invoiceCount) invoice\(row.invoiceCount == 1 ? "" : "s")")
                metric("Known materials", value: currency(row.materialCost), detail: materialDetail)
                metric("Known labor", value: currency(row.laborCost), detail: laborDetail)
                metric(
                    "Gross profit",
                    value: row.knownGrossProfit.map(currency) ?? "Incomplete",
                    detail: row.knownGrossMargin.map(percent) ?? "cost review required"
                )
            }
            .padding(.top, 10)

            Label(
                row.costReviewDetail,
                systemImage: row.costCoverageComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(row.costCoverageComplete ? .green : .orange)
            .padding(.top, 8)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.customerName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(row.workType.displayName) • \(row.scheduledDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(currency(row.invoicedRevenue))
                        .font(.subheadline.weight(.semibold))
                    Text(row.knownGrossMargin.map(percent) ?? "Cost review")
                        .font(.caption)
                        .foregroundStyle(row.costCoverageComplete ? .green : .orange)
                }
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("JobProfitabilityRow-\(row.id.uuidString)")
    }

    private var materialDetail: String {
        row.missingMaterialCostLineCount == 0
            ? "snapshot covered"
            : "\(row.missingMaterialCostLineCount) missing cost\(row.missingMaterialCostLineCount == 1 ? "" : "s")"
    }

    private var laborDetail: String {
        if !row.hasCompletedLaborTime { return "no completed time" }
        if row.uncostedLaborMinutes > 0 { return "\(row.uncostedLaborMinutes) uncosted min" }
        return "completed time covered"
    }

    private func metric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func currency(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
    private func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(1))) }
}
