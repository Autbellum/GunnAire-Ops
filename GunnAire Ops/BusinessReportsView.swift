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

    @State private var period: BusinessReportPeriod = .currentMonth
    @State private var workspace: BusinessReportWorkspace = .overview
    @State private var showingExporter = false
    @State private var exportError: String?

    private var snapshot: BusinessReportSnapshot {
        BusinessReporting.snapshot(
            period: period,
            serviceCalls: serviceCalls,
            estimates: estimates,
            invoices: invoices,
            payments: payments,
            timeEntries: timeEntries,
            technicians: technicians
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
                    .disabled(!snapshot.hasFinancialActivity && !snapshot.hasOperationalActivity)
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

            reportingCard(title: "Revenue by Work Type", systemImage: "wrench.and.screwdriver") {
                ForEach(InvoiceWorkType.allCases) { workType in
                    valueRow(workType.displayName, value: currency(snapshot.invoiceRevenueByWorkType[workType] ?? 0))
                    if workType != InvoiceWorkType.allCases.last { Divider() }
                }
            }
        }
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
        }
    }

    private var teamWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Team Activity", detail: "Recorded time and completed assigned work; internal labor costs remain office-only.")
            if snapshot.technicianRows.isEmpty {
                ContentUnavailableView(
                    "No Team Activity",
                    systemImage: "person.2",
                    description: Text("No technician assignments or completed time entries fall inside this period.")
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                ForEach(snapshot.technicianRows) { row in
                    reportingCard(title: row.name, systemImage: "person.crop.circle") {
                        HStack(spacing: 18) {
                            teamValue("Completed", value: "\(row.completedJobs)")
                            teamValue("Hours", value: String(format: "%.1f", row.recordedHours))
                            teamValue("Labor", value: row.laborCost.map(currency) ?? "Not costed")
                            Spacer()
                        }
                        if row.uncostedMinutes > 0 {
                            Label("\(row.uncostedMinutes) minutes excluded until this technician has an internal labor rate.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
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

    private func teamValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.headline)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
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
