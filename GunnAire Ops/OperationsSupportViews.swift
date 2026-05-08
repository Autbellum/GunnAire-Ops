import SwiftUI
import SwiftData

struct CustomersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Customer.name, order: .forward) private var customers: [Customer]
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]

    @State private var newCustomerName = ""
    @State private var newCustomerEmail = ""
    @State private var newCustomerPhone = ""
    @State private var newCustomerAddress = ""
    @State private var selectedCustomer: Customer?
    @State private var didLoadPendingIntentCustomer = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Add Customer") {
                    TextField("Customer Name", text: $newCustomerName)
                    TextField("Address", text: $newCustomerAddress, axis: .vertical)
                        .lineLimit(2...3)
                    TextField("Email", text: $newCustomerEmail)
                        .keyboardType(.emailAddress)
                    TextField("Phone", text: $newCustomerPhone)
                        .keyboardType(.phonePad)

                    Button("Save Customer") {
                        let customer = Customer(
                            name: newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines),
                            phone: newCustomerPhone.nilIfBlank,
                            email: newCustomerEmail.nilIfBlank,
                            address: newCustomerAddress.nilIfBlank
                        )
                        modelContext.insert(customer)
                        newCustomerName = ""
                        newCustomerEmail = ""
                        newCustomerPhone = ""
                        newCustomerAddress = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .disabled(newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Customer Directory") {
                    if customers.isEmpty {
                        Text("No customers saved yet.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(customers) { customer in
                            Button {
                                selectedCustomer = customer
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(customer.name)
                                            .font(.headline)
                                        Spacer()
                                        if let quickBooksID = customer.quickBooksID, !quickBooksID.isEmpty {
                                            Label("QuickBooks", systemImage: "link")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    if let address = customer.address, !address.isEmpty {
                                        Text(address)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if let email = customer.email, !email.isEmpty {
                                        Text(email)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if let phone = customer.phone, !phone.isEmpty {
                                        Text(phone)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Text("\(serviceCallCount(for: customer)) jobs • \(invoiceCount(for: customer)) invoices")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Customers")
            .onAppear(perform: applyPendingIntentCustomerIfNeeded)
            .sheet(item: $selectedCustomer) { customer in
                CustomerEditorView(customer: customer)
            }
        }
    }

    private func applyPendingIntentCustomerIfNeeded() {
        guard !didLoadPendingIntentCustomer else { return }
        didLoadPendingIntentCustomer = true
        guard let pendingID = GunnAireAppIntentRouter.consumePendingCustomerID(),
              let customer = customers.first(where: { $0.id == pendingID }) else {
            return
        }
        selectedCustomer = customer
    }

    private func serviceCallCount(for customer: Customer) -> Int {
        serviceCalls.filter { $0.customer.id == customer.id }.count
    }

    private func invoiceCount(for customer: Customer) -> Int {
        invoices.filter { $0.customer.id == customer.id }.count
    }
}

struct SyncIntegrationsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \ServiceCall.scheduledDate, order: .forward) private var serviceCalls: [ServiceCall]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared

    @State private var availableCalendars: [GoogleCalendar] = []
    @State private var loadingCalendars = false
    @State private var calendarStatusMessage: String?
    @State private var newTechnicianName = ""
    @State private var newTechnicianCalendarEmail = ""
    @State private var selectedTechnician: Technician?
    @State private var technicianMessage: String?

    private var quickBooksConnected: Bool {
        QuickBooksDataAPI.shared.isAuthenticated
    }

    private var availableCalendarIDs: Set<String> {
        Set(availableCalendars.map(\.id) + ["primary"])
    }

    private var writableCalendarIDs: Set<String> {
        Set(availableCalendars.filter(\.isWritable).map(\.normalizedID) + ["primary"])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sync Status") {
                    statusRow("QuickBooks", value: quickBooksConnected ? "Connected" : "Disconnected")
                    statusRow("Google", value: googleAuth.isAuthenticated ? "Connected" : "Disconnected")
                }

                Section("Google Calendar Diagnostics") {
                    Button(loadingCalendars ? "Loading..." : "Refresh Calendar Access") {
                        refreshCalendarAccess()
                    }
                    .disabled(!googleAuth.isAuthenticated || loadingCalendars)

                    if !googleAuth.isAuthenticated {
                        Text("Connect Google in Settings before checking calendar access.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if let calendarStatusMessage {
                        Text(calendarStatusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !availableCalendars.isEmpty {
                        ForEach(technicians) { technician in
                            Button {
                                selectedTechnician = technician
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(technician.name)
                                        Text(technician.contactInfo ?? "No calendar email")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text("\(assignedJobCount(for: technician)) assigned jobs")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(calendarAccessLabel(for: technician))
                                        .foregroundColor(calendarAccessColor(for: technician))
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Technician Directory") {
                    TextField("Technician name", text: $newTechnicianName)
                    TextField("Calendar email", text: $newTechnicianCalendarEmail)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)

                    Button {
                        addTechnician()
                    } label: {
                        Label("Add Technician", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)

                    if let technicianMessage {
                        Text(technicianMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if technicians.isEmpty {
                        Text("No technicians added yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(technicians) { technician in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(technician.name)
                                    Text(technician.contactInfo ?? "No calendar email")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Delete", role: .destructive) {
                                    modelContext.delete(technician)
                                }
                                .disabled(assignedJobCount(for: technician) > 0)
                            }
                        }
                        Text("Technicians with assigned jobs must be reassigned before they can be deleted.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Operational Notes") {
                    Text("QuickBooks sync is managed from the QuickBooks Management screen.")
                    Text("Google account and calendar access are managed from Settings.")
                    Text("Mail now uses the connected Google account with Gmail API access.")
                    Text("Technician events can be created from Schedule by assigning a technician whose calendar email is accessible to the connected Google account.")
                    Text("Receipts, bills, invoices, payments, and catalog records now use the live QuickBooks integration path.")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .navigationTitle("Sync & Integrations")
            .onAppear {
                if googleAuth.isAuthenticated && availableCalendars.isEmpty {
                    refreshCalendarAccess()
                }
            }
            .sheet(item: $selectedTechnician) { technician in
                TechnicianEditorView(technician: technician)
            }
        }
    }

    @ViewBuilder
    private func statusRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }

    private func refreshCalendarAccess() {
        guard googleAuth.isAuthenticated else { return }
        loadingCalendars = true
        calendarStatusMessage = "Checking accessible calendars..."
        googleAuth.fetchCalendars { result in
            DispatchQueue.main.async {
                loadingCalendars = false
                switch result {
                case .success(let calendars):
                    availableCalendars = calendars
                    calendarStatusMessage = "Loaded \(calendars.count) accessible calendars."
                case .failure(let error):
                    availableCalendars = []
                    calendarStatusMessage = "Calendar diagnostics failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func calendarAccessLabel(for technician: Technician) -> String {
        guard let email = technician.contactInfo?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            return "No email"
        }
        if availableCalendars.contains(where: { $0.isWritable && $0.matchesTechnicianEmail(email) }) {
            return "Writable"
        }
        if availableCalendars.contains(where: { $0.matchesTechnicianEmail(email) }) {
            return "Read-only"
        }
        return "Not shared"
    }

    private func calendarAccessColor(for technician: Technician) -> Color {
        switch calendarAccessLabel(for: technician) {
        case "Writable":
            return .green
        case "Read-only":
            return .orange
        case "No email":
            return .secondary
        default:
            return .red
        }
    }

    private func assignedJobCount(for technician: Technician) -> Int {
        serviceCalls.filter { $0.assignedTechnician?.id == technician.id }.count
    }

    private func addTechnician() {
        let name = newTechnicianName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            technicianMessage = "Enter a technician name first."
            return
        }
        let email = AppAccess.normalizedEmail(newTechnicianCalendarEmail).nilIfBlank
        if let email, technicians.contains(where: { AppAccess.normalizedEmail($0.contactInfo) == email }) {
            technicianMessage = "A technician with that calendar email already exists."
            return
        }
        modelContext.insert(Technician(name: name, contactInfo: email))
        newTechnicianName = ""
        newTechnicianCalendarEmail = ""
        technicianMessage = "Added \(name)."
    }
}

struct OnsiteDocumentationView: View {
    @Query(sort: \ServiceCall.scheduledDate, order: .forward) private var serviceCalls: [ServiceCall]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]

    private var quickBooksConnected: Bool {
        QuickBooksDataAPI.shared.isAuthenticated
    }

    private var openJobs: [ServiceCall] {
        serviceCalls.filter { $0.status != .completed && $0.status != .cancelled }
    }

    private var jobsNeedingDocumentation: [ServiceCall] {
        openJobs.filter { $0.linkedInvoiceID == nil && $0.linkedEstimateID == nil }
    }

    private var invoicesAwaitingCloseout: [Invoice] {
        invoices.filter { $0.status != "paid" || $0.finalizedAt == nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Documentation Queue") {
                    if jobsNeedingDocumentation.isEmpty {
                        Text("No active jobs are waiting for documentation.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(jobsNeedingDocumentation) { call in
                            NavigationLink {
                                BillingDocumentsView(initialServiceCall: call)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(call.customer.name)
                                        .font(.headline)
                                    Text(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(call.type.rawValue.capitalized)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("Checklist \(call.checklistCompletedCount)/\(call.checklistTotalCount)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Invoices Awaiting Closeout") {
                    if invoicesAwaitingCloseout.isEmpty {
                        Text("All invoices are finalized and paid.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(invoicesAwaitingCloseout) { invoice in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(invoice.customer.name)
                                    .font(.headline)
                                Text("\(invoice.amount, format: .currency(code: "USD")) • \(invoice.status.capitalized)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if invoice.finalizedAt == nil {
                                    Text("Missing final signature or closeout details.")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                }

                Section("Workflow Notes") {
                    Text("Open a scheduled call from Schedule or this queue to start documentation, build the invoice or estimate, and capture closeout details.")
                    Text("Use Receipts & Bills to attach PDFs, photos, and vendor documents.")
                    Text("Use Payments to review or sync recorded payments after invoice closeout.")
                    Text(quickBooksConnected ? "QuickBooks is connected and ready for live billing document workflows." : "Connect QuickBooks in Settings before expecting live billing document sync.")
                }
                .foregroundColor(.secondary)
            }
            .navigationTitle("Onsite Documentation")
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CustomerEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let customer: Customer

    @State private var name: String
    @State private var address: String
    @State private var email: String
    @State private var phone: String

    init(customer: Customer) {
        self.customer = customer
        _name = State(initialValue: customer.name)
        _address = State(initialValue: customer.address ?? "")
        _email = State(initialValue: customer.email ?? "")
        _phone = State(initialValue: customer.phone ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Customer Name", text: $name)
                TextField("Address", text: $address, axis: .vertical)
                    .lineLimit(2...3)
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                TextField("Phone", text: $phone)
                    .keyboardType(.phonePad)
                if let quickBooksID = customer.quickBooksID, !quickBooksID.isEmpty {
                    Text("QuickBooks ID: \(quickBooksID)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Edit Customer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        customer.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        customer.address = address.nilIfBlank
                        customer.email = email.nilIfBlank
                        customer.phone = phone.nilIfBlank
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(Color.brandGold)
    }
}

private struct TechnicianEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let technician: Technician

    @State private var name: String
    @State private var calendarEmail: String

    init(technician: Technician) {
        self.technician = technician
        _name = State(initialValue: technician.name)
        _calendarEmail = State(initialValue: technician.contactInfo ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Technician name", text: $name)
                TextField("Calendar email", text: $calendarEmail)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
            }
            .navigationTitle("Edit Technician")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        technician.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        technician.contactInfo = AppAccess.normalizedEmail(calendarEmail).nilIfBlank
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(Color.brandGold)
    }
}
