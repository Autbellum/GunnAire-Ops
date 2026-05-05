import SwiftUI
import SwiftData
import Combine

final class GoogleWorkspaceSandboxCenter: ObservableObject {
    static let shared = GoogleWorkspaceSandboxCenter()

    @Published var lastSyncAt: Date?
    @Published var pushedEventsCount = 0
    @Published var generatedDraftsCount = 0
    @Published var generatedDocsCount = 0
    @Published var contactCardsPrepared = 0
    @Published var tasksGenerated = 0
    @Published var meetLinksGenerated = 0
    @Published var activity: [String] = ["Google Workspace sandbox ready."]

    func runAction(_ tool: GoogleWorkspaceTool, upcomingCount: Int) {
        lastSyncAt = Date()

        switch tool {
        case .calendar:
            pushedEventsCount = upcomingCount
            activity.insert("Calendar: queued \(upcomingCount) events.", at: 0)
        case .gmail:
            generatedDraftsCount = max(upcomingCount, 1)
            activity.insert("Gmail: created \(generatedDraftsCount) customer update drafts.", at: 0)
        case .drive:
            let generated = max(upcomingCount, 1)
            generatedDocsCount += generated
            activity.insert("Drive: generated \(generated) job summary documents.", at: 0)
        case .contacts:
            contactCardsPrepared = max(upcomingCount, 1)
            activity.insert("Contacts: prepared \(contactCardsPrepared) contact cards.", at: 0)
        case .tasks:
            tasksGenerated = max(upcomingCount, 1)
            activity.insert("Tasks: generated \(tasksGenerated) follow-up tasks.", at: 0)
        case .meet:
            meetLinksGenerated = max(upcomingCount / 2, 1)
            activity.insert("Meet: generated \(meetLinksGenerated) meeting links.", at: 0)
        }
    }

    func runFullWorkspaceSync(upcomingCount: Int) {
        runAction(.calendar, upcomingCount: upcomingCount)
        runAction(.gmail, upcomingCount: upcomingCount)
        runAction(.drive, upcomingCount: upcomingCount)
        runAction(.contacts, upcomingCount: upcomingCount)
        runAction(.tasks, upcomingCount: upcomingCount)
        runAction(.meet, upcomingCount: upcomingCount)
        activity.insert("Workspace full sync finished.", at: 0)
    }
}

struct GoogleCalendarSandboxView: View {
    @Query(sort: \ServiceCall.scheduledDate, order: .forward) private var serviceCalls: [ServiceCall]
    @ObservedObject private var workspace = GoogleWorkspaceSandboxCenter.shared
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @State private var selectedTool: GoogleWorkspaceTool = .calendar
    @State private var isLoadingGoogle = false
    @State private var googleErrorMessage: String?
    @State private var googleProfile: GoogleUserProfile?
    @State private var googleCalendars: [GoogleCalendar] = []
    @State private var googleEvents: [GoogleCalendarEvent] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Google Workspace Modules") {
                    Picker("Workspace App", selection: $selectedTool) {
                        ForEach(GoogleWorkspaceTool.allCases, id: \.self) { tool in
                            Text(tool.rawValue).tag(tool)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("\(selectedTool.rawValue) Sandbox") {
                    Text(moduleDescription)
                        .foregroundColor(.secondary)

                    Button(primaryActionTitle) {
                        runPrimaryAction()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                }

                Section("Sync Status") {
                    Text("Google Auth: \(googleAuth.isAuthenticated ? "Connected" : "Not Connected")")
                    Text("Upcoming jobs found: \(serviceCalls.filter { $0.scheduledDate >= Date() }.count)")
                    Text("Events queued for Google: \(workspace.pushedEventsCount)")
                    Text("Email drafts prepared: \(workspace.generatedDraftsCount)")
                    Text("Drive docs generated: \(workspace.generatedDocsCount)")
                    Text("Contacts prepared: \(workspace.contactCardsPrepared)")
                    Text("Tasks generated: \(workspace.tasksGenerated)")
                    Text("Meet links generated: \(workspace.meetLinksGenerated)")
                    if let lastSyncAt = workspace.lastSyncAt {
                        Text("Last simulated sync: \(lastSyncAt.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("Last simulated sync: Never")
                            .foregroundColor(.secondary)
                    }
                }

                Section("Live Google Data") {
                    if let googleProfile {
                        Text("Signed in as: \(googleProfile.email ?? googleProfile.name ?? googleProfile.sub)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let googleErrorMessage {
                        Text(googleErrorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    if isLoadingGoogle {
                        ProgressView()
                            .tint(Color.brandGold)
                    }

                    Button("Load Google Profile") {
                        loadGoogleProfile()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .disabled(!googleAuth.isAuthenticated || isLoadingGoogle)

                    Button("Load Google Calendars") {
                        loadGoogleCalendars()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!googleAuth.isAuthenticated || isLoadingGoogle)

                    Button("Load Upcoming Events") {
                        loadGoogleUpcomingEvents()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!googleAuth.isAuthenticated || isLoadingGoogle)

                    if !googleCalendars.isEmpty {
                        Text("Calendars: \(googleCalendars.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if !googleEvents.isEmpty {
                        Text("Upcoming events loaded: \(googleEvents.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Upcoming Jobs") {
                    if serviceCalls.isEmpty {
                        Text("No jobs found. Add service calls in Schedule to simulate calendar events.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(serviceCalls.prefix(10)) { call in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(call.customer.name)
                                    .font(.headline)
                                Text("\(call.type.rawValue.capitalized) - \(call.status.rawValue)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Workspace Activity Log") {
                    ForEach(Array(workspace.activity.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Google Workspace")
        }
    }

    private var moduleDescription: String {
        switch selectedTool {
        case .calendar:
            return "Push upcoming service calls to Google Calendar."
        case .gmail:
            return "Generate customer-facing service update drafts."
        case .drive:
            return "Generate job summary docs in a sandbox Drive folder."
        case .contacts:
            return "Prepare customer contacts for Workspace directory sync."
        case .tasks:
            return "Generate technician follow-up tasks."
        case .meet:
            return "Create virtual inspection meeting links."
        }
    }

    private var primaryActionTitle: String {
        switch selectedTool {
        case .calendar:
            return "Simulate Calendar Sync"
        case .gmail:
            return "Generate Email Drafts"
        case .drive:
            return "Generate Drive Docs"
        case .contacts:
            return "Prepare Contact Sync"
        case .tasks:
            return "Generate Tasks"
        case .meet:
            return "Generate Meet Links"
        }
    }

    private func runPrimaryAction() {
        let upcomingCount = serviceCalls.filter { $0.scheduledDate >= Date() }.count
        workspace.runAction(selectedTool, upcomingCount: upcomingCount)
    }

    private func loadGoogleProfile() {
        isLoadingGoogle = true
        googleErrorMessage = nil
        googleAuth.fetchUserProfile { result in
            DispatchQueue.main.async {
                isLoadingGoogle = false
                switch result {
                case .success(let profile):
                    googleProfile = profile
                case .failure(let error):
                    googleErrorMessage = "Profile load failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadGoogleCalendars() {
        isLoadingGoogle = true
        googleErrorMessage = nil
        googleAuth.fetchCalendars { result in
            DispatchQueue.main.async {
                isLoadingGoogle = false
                switch result {
                case .success(let calendars):
                    googleCalendars = calendars
                case .failure(let error):
                    googleErrorMessage = "Calendar list failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadGoogleUpcomingEvents() {
        let primaryCalendar = googleCalendars.first?.id ?? "primary"
        isLoadingGoogle = true
        googleErrorMessage = nil
        googleAuth.fetchCalendarEvents(
            calendarID: primaryCalendar,
            timeMin: Date(),
            timeMax: Calendar.current.date(byAdding: .day, value: 30, to: Date())
        ) { result in
            DispatchQueue.main.async {
                isLoadingGoogle = false
                switch result {
                case .success(let events):
                    googleEvents = events
                case .failure(let error):
                    googleErrorMessage = "Events load failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

enum GoogleWorkspaceTool: String, CaseIterable {
    case calendar = "Calendar"
    case gmail = "Gmail"
    case drive = "Drive"
    case contacts = "Contacts"
    case tasks = "Tasks"
    case meet = "Meet"
}

struct CustomersSandboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Customer.name, order: .forward) private var customers: [Customer]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared

    @State private var name = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Add Sandbox Customer") {
                    TextField("Name", text: $name)
                    TextField("Phone", text: $phone)
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)

                    Button("Save Customer") {
                        let customer = Customer(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            phone: phone.isEmpty ? nil : phone,
                            email: email.isEmpty ? nil : email
                        )
                        modelContext.insert(customer)
                        name = ""
                        phone = ""
                        email = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Google Profile Assist") {
                    Button("Use Google Profile Email") {
                        importGoogleProfile()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!googleAuth.isAuthenticated)

                    Text("Contacts API requires additional Google scopes and verification. This sandbox uses your signed-in Google profile for now.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let importMessage {
                        Text(importMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Customer List") {
                    if customers.isEmpty {
                        Text("No customers yet. Add one above to simulate customer management.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(customers) { customer in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(customer.name)
                                    .font(.headline)
                                if let phone = customer.phone, !phone.isEmpty {
                                    Text(phone)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                if let email = customer.email, !email.isEmpty {
                                    Text(email)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Customers")
        }
    }

    private func importGoogleProfile() {
        importMessage = nil
        googleAuth.fetchUserProfile { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let profile):
                    if (email.isEmpty), let profileEmail = profile.email {
                        email = profileEmail
                    }
                    if (name.isEmpty), let profileName = profile.name {
                        name = profileName
                    }
                    importMessage = "Imported profile details into customer form."
                case .failure(let error):
                    importMessage = "Google profile import failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct SyncIntegrationsSandboxView: View {
    @ObservedObject private var qbAPI = QBStubAPIClient.shared
    @ObservedObject private var workspace = GoogleWorkspaceSandboxCenter.shared
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @Query(sort: \ServiceCall.scheduledDate, order: .forward) private var serviceCalls: [ServiceCall]

    @State private var quickBooksEnabled = true
    @State private var googleEnabled = true
    @State private var syncing = false
    @State private var lastRun: Date?
    @State private var logLines: [String] = ["Sandbox ready."]

    var body: some View {
        NavigationStack {
            List {
                Section("Integrations") {
                    Toggle("QuickBooks", isOn: $quickBooksEnabled)
                    Toggle("Google", isOn: $googleEnabled)
                    Text("Google Auth: \(googleAuth.isAuthenticated ? "Connected" : "Not Connected")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Sync Engine (Sandbox)") {
                    Button(syncing ? "Running..." : "Run Simulated Sync") {
                        runSync()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .disabled(syncing || (!quickBooksEnabled && !googleEnabled))

                    if let lastRun {
                        Text("Last run: \(lastRun.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("QuickBooks records: \(qbAPI.invoices.count + qbAPI.bills.count + qbAPI.vendors.count + qbAPI.payments.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Workspace artifacts: \(workspace.pushedEventsCount + workspace.generatedDraftsCount + workspace.generatedDocsCount + workspace.contactCardsPrepared + workspace.tasksGenerated + workspace.meetLinksGenerated)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Sync Log") {
                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Sync & Integrations")
        }
    }

    private func runSync() {
        syncing = true
        logLines.insert("Starting simulated sync...", at: 0)
        let upcomingCount = serviceCalls.filter { $0.scheduledDate >= Date() }.count
        let syncGroup = DispatchGroup()
        var didRunAnyTask = false

        if quickBooksEnabled {
            didRunAnyTask = true
            syncGroup.enter()
            qbAPI.fetchInvoices()
            qbAPI.fetchBills()
            qbAPI.fetchVendors()
            qbAPI.fetchPayments()
            qbAPI.simulateFullSync { summary in
                logLines.insert("QuickBooks: \(summary)", at: 0)
                syncGroup.leave()
            }
        }

        if googleEnabled {
            didRunAnyTask = true
            workspace.runFullWorkspaceSync(upcomingCount: upcomingCount)
            logLines.insert("Google Workspace: full sync completed.", at: 0)

            if googleAuth.isAuthenticated {
                syncGroup.enter()
                googleAuth.fetchCalendars { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let calendars):
                            let primary = calendars.first?.id ?? "primary"
                            self.logLines.insert("Google: fetched \(calendars.count) calendars.", at: 0)
                            self.googleAuth.fetchCalendarEvents(calendarID: primary, timeMin: Date(), timeMax: Calendar.current.date(byAdding: .day, value: 30, to: Date())) { eventsResult in
                                DispatchQueue.main.async {
                                    switch eventsResult {
                                    case .success(let events):
                                        self.logLines.insert("Google: fetched \(events.count) upcoming events.", at: 0)
                                    case .failure(let error):
                                        self.logLines.insert("Google events failed: \(error.localizedDescription)", at: 0)
                                    }
                                    syncGroup.leave()
                                }
                            }
                        case .failure(let error):
                            self.logLines.insert("Google calendars failed: \(error.localizedDescription)", at: 0)
                            syncGroup.leave()
                        }
                    }
                }
            } else {
                logLines.insert("Google API skipped: not authenticated.", at: 0)
            }
        }

        if !didRunAnyTask {
            lastRun = Date()
            syncing = false
            return
        }

        syncGroup.notify(queue: .main) {
            lastRun = Date()
            syncing = false
        }
    }
}

struct OnsiteDocumentationSandboxView: View {
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @ObservedObject private var workspace = GoogleWorkspaceSandboxCenter.shared
    @State private var visitSummary = ""
    @State private var checklist: [ChecklistItem] = [
        ChecklistItem(title: "Thermostat tested"),
        ChecklistItem(title: "Filter inspected"),
        ChecklistItem(title: "Condenser cleaned"),
        ChecklistItem(title: "Safety checks completed")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Visit Checklist") {
                    ForEach($checklist) { $item in
                        Toggle(item.title, isOn: $item.isDone)
                    }
                }

                Section("Technician Notes") {
                    TextField("Write onsite summary...", text: $visitSummary, axis: .vertical)
                        .lineLimit(4...8)
                    Button("Simulate Save Documentation") {
                        visitSummary = visitSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                }

                Section("Google Drive Output") {
                    Button("Generate Drive Job Summary (Sandbox)") {
                        let completedCount = checklist.filter { $0.isDone }.count
                        workspace.runAction(.drive, upcomingCount: max(completedCount, 1))
                    }
                    .buttonStyle(.bordered)
                    .disabled(!googleAuth.isAuthenticated)

                    Text("Generated docs: \(workspace.generatedDocsCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Output Preview") {
                    Text("Completed checklist items: \(checklist.filter { $0.isDone }.count)/\(checklist.count)")
                    if visitSummary.isEmpty {
                        Text("No summary entered.")
                            .foregroundColor(.secondary)
                    } else {
                        Text(visitSummary)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Onsite Documentation")
        }
    }
}

struct InvoicesEstimatesSandboxView: View {
    private let termsURL = URL(string: "https://gunnaire.com/terms-of-service/")!

    @State private var selectedType: RecordType = .estimate
    @State private var customerName = ""
    @State private var amount = ""
    @State private var selectedRecord: SandboxBillingRecord?
    @State private var actionMessage: String?
    @State private var records: [SandboxBillingRecord] = [
        SandboxBillingRecord(type: .estimate, customerName: "Acme Office", amount: 4200, status: "pending"),
        SandboxBillingRecord(type: .invoice, customerName: "Maple Residence", amount: 980, status: "unpaid")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Create Sandbox Record") {
                    Picker("Type", selection: $selectedType) {
                        ForEach(RecordType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Customer name", text: $customerName)
                    TextField("Amount", text: $amount)
                        .keyboardType(.decimalPad)

                    Button("Add \(selectedType.rawValue)") {
                        guard let parsedAmount = Double(amount) else { return }
                        let status = selectedType == .estimate ? "pending" : "unpaid"
                        records.insert(
                            SandboxBillingRecord(
                                type: selectedType,
                                customerName: customerName.trimmingCharacters(in: .whitespacesAndNewlines),
                                amount: parsedAmount,
                                status: status
                            ),
                            at: 0
                        )
                        customerName = ""
                        amount = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .disabled(customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Double(amount) == nil)
                }

                Section("Sandbox Billing Queue") {
                    if records.isEmpty {
                        Text("No invoices or estimates yet.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(records) { record in
                            Button {
                                selectedRecord = record
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.customerName)
                                            .font(.headline)
                                        Text("\(record.type.rawValue) - \(record.status)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text("Terms: \(termsURL.absoluteString)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(record.amount, format: .currency(code: "USD"))
                                        .font(.subheadline)
                                        .bold()
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                        .onDelete { indexSet in
                            records.remove(atOffsets: indexSet)
                        }
                    }
                }
                if let actionMessage {
                    Section("Last Action") {
                        Text(actionMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Invoices & Estimates")
            .sheet(item: $selectedRecord) { record in
                SandboxBillingRecordDetailView(
                    record: record,
                    onTakePayment: {
                        markInvoicePaid(id: record.id)
                    },
                    onConvertToInvoice: {
                        convertEstimateToInvoice(id: record.id)
                    }
                )
            }
        }
    }

    private func markInvoicePaid(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = "paid"
        actionMessage = "Payment recorded for \(records[index].customerName)."
    }

    private func convertEstimateToInvoice(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].type = .invoice
        records[index].status = "unpaid"
        actionMessage = "Converted estimate to invoice for \(records[index].customerName)."
    }
}

enum RecordType: String, CaseIterable {
    case estimate = "Estimate"
    case invoice = "Invoice"
}

struct SandboxBillingRecord: Identifiable {
    let id = UUID()
    var type: RecordType
    var customerName: String
    var amount: Double
    var status: String
}

private struct SandboxBillingRecordDetailView: View {
    private let termsURL = URL(string: "https://gunnaire.com/terms-of-service/")!

    let record: SandboxBillingRecord
    let onTakePayment: () -> Void
    let onConvertToInvoice: () -> Void

    @State private var showingPDF = false

    var body: some View {
        NavigationStack {
            List {
                Section("Details") {
                    Text("Customer: \(record.customerName)")
                    Text("Type: \(record.type.rawValue)")
                    Text("Status: \(record.status)")
                    Text("Amount: \(record.amount, format: .currency(code: "USD"))")
                    Link("View Terms of Service", destination: termsURL)
                }

                Section("Actions") {
                    if record.type == .invoice {
                        Button("Take Customer Payment") {
                            onTakePayment()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .disabled(record.status.lowercased() == "paid")
                    } else {
                        Button("Convert Estimate to Invoice") {
                            onConvertToInvoice()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                    }

                    Button("Show \(record.type.rawValue) PDF") {
                        showingPDF = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                }
            }
            .navigationTitle("\(record.type.rawValue) Detail")
            .sheet(isPresented: $showingPDF) {
                SandboxBillingPDFView(record: record)
            }
        }
    }
}

private struct SandboxBillingPDFView: View {
    private let termsURL = URL(string: "https://gunnaire.com/terms-of-service/")!

    let record: SandboxBillingRecord

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(record.type.rawValue) PDF (Sandbox)")
                        .font(.title2)
                        .bold()
                        .foregroundColor(Color.brandGold)
                    Divider()
                    Text("Customer: \(record.customerName)")
                    Text("Amount: \(record.amount, format: .currency(code: "USD"))")
                    Text("Status: \(record.status.capitalized)")
                    Text("Document Number: \(record.id.uuidString.prefix(8))")
                    Text("Generated: \(Date().formatted(date: .abbreviated, time: .shortened))")
                    Divider()
                    Text("Line Items")
                        .font(.headline)
                    Text("HVAC Service Work - \(record.amount, format: .currency(code: "USD"))")
                    Text("Terms of Service: \(termsURL.absoluteString)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Thank you for your business.")
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("PDF Preview")
        }
    }
}

struct ChecklistItem: Identifiable {
    let id = UUID()
    let title: String
    var isDone: Bool = false
}
