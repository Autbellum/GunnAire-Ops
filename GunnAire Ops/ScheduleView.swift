import SwiftUI
import SwiftData

struct ScheduleView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\ServiceCall.scheduledDate)]) private var serviceCalls: [ServiceCall]
    @Query private var recurringContracts: [RecurringMaintenanceContract]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @AppStorage("enableOnsitePayments") private var enableOnsitePayments = false
    @AppStorage("onsitePaymentProcessor") private var onsitePaymentProcessor = OnsitePaymentProcessor.none.rawValue
    @AppStorage("onsitePaymentProcessorReady") private var onsitePaymentProcessorReady = false
    
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var showingAddCallSheet = false
    @State private var documentationCall: ServiceCall?
    @State private var openDocumentationInCloseout = false
    @State private var openDocumentationInTapToPay = false
    @State private var isSyncingGoogleCalendar = false
    @State private var syncMessage: String?
    
    enum ViewMode: String, CaseIterable, Identifiable {
        case day = "Day"
        case week = "Week"
        var id: String { rawValue }
    }
    @State private var viewMode: ViewMode = .day
    
    var filteredCalls: [ServiceCall] {
        let calls = callsForSignedInUser
        switch viewMode {
        case .day:
            return calls.filter { Calendar.current.isDate($0.scheduledDate, inSameDayAs: selectedDate) }
        case .week:
            let calendar = Calendar.current
            guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: selectedDate) else { return [] }
            return calls.filter { $0.scheduledDate >= weekInterval.start && $0.scheduledDate <= weekInterval.end }
                .sorted { $0.scheduledDate < $1.scheduledDate }
        }
    }
    
    var upcomingJobs: [ServiceCall] {
        let now = Date()
        let calendar = Calendar.current
        let sevenDaysAhead = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        return callsForSignedInUser.filter { $0.scheduledDate >= now && $0.scheduledDate <= sevenDaysAhead }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var jobsNeedingDocumentation: [ServiceCall] {
        callsForSignedInUser
            .filter { call in
                call.status != .cancelled &&
                (call.documentationStartedAt == nil || (call.linkedEstimateID == nil && call.linkedInvoiceID == nil))
            }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var jobsNeedingPayment: [ServiceCall] {
        callsForSignedInUser
            .filter { call in
                guard let invoice = invoice(for: call) else { return false }
                return invoice.status != "paid"
            }
            .sorted { lhs, rhs in
                let lhsBalance = balanceDue(for: lhs) ?? 0
                let rhsBalance = balanceDue(for: rhs) ?? 0
                if lhsBalance == rhsBalance {
                    return lhs.scheduledDate < rhs.scheduledDate
                }
                return lhsBalance > rhsBalance
            }
    }

    private var overdueCollectionJobs: [ServiceCall] {
        jobsNeedingPayment
            .filter(isCollectionOverdue(for:))
            .sorted { lhs, rhs in
                let lhsDate = invoice(for: lhs)?.createdAt ?? lhs.scheduledDate
                let rhsDate = invoice(for: rhs)?.createdAt ?? rhs.scheduledDate
                return lhsDate < rhsDate
            }
    }

    private var callsForSignedInUser: [ServiceCall] {
        guard let email = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail") else {
            return serviceCalls
        }
        let matched = serviceCalls.filter { call in
            guard let technician = call.assignedTechnician else { return true }
            return technician.contactInfo?.localizedCaseInsensitiveContains(email) == true ||
                email.localizedCaseInsensitiveContains(technician.name)
        }
        return matched
    }
    
    var activeRecurringContracts: [RecurringMaintenanceContract] {
        let now = Date()
        return recurringContracts.filter { $0.nextDate >= now }
    }

    private var selectedProcessor: OnsitePaymentProcessor {
        OnsitePaymentProcessor(rawValue: onsitePaymentProcessor) ?? .none
    }

    private var tapToPayReady: Bool {
        enableOnsitePayments &&
        selectedProcessor.supportsTapToPay &&
        OnsitePaymentManager.shared.processorReady()
    }

    private var isAdminUser: Bool {
        let email = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
        return AppAccess.isAdmin(email: email, users: users)
    }
    
    var body: some View {
        ZStack {
            WatermarkBackground()
            NavigationStack {
                List {
                    Section("Dashboard") {
                        dashboardSection
                    }

                    Section("Calendar") {
                        DatePicker(
                            "Select Date",
                            selection: $selectedDate,
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.graphical)
                    }

                    Section {
                        Picker("View Mode", selection: $viewMode) {
                            ForEach(ViewMode.allCases) { mode in
                                Text(mode.rawValue).bold()
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Section(filteredCalls.isEmpty ? "No Jobs Scheduled" : "Scheduled Jobs") {
                        ForEach(filteredCalls) { call in
                            NavigationLink(value: call) {
                                serviceCallRow(for: call)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if let invoice = invoice(for: call), invoice.status != "paid" {
                                    Button {
                                        openDocumentationInCloseout = true
                                        openDocumentationInTapToPay = tapToPayReady
                                        documentationCall = call
                                    } label: {
                                        Label(tapToPayReady ? "Tap to Pay" : "Take Payment", systemImage: "creditcard")
                                    }
                                    .tint(.green)
                                }

                                Button {
                                    openDocumentationInCloseout = false
                                    openDocumentationInTapToPay = false
                                    documentationCall = call
                                } label: {
                                    Label(call.linkedEstimateID != nil || call.linkedInvoiceID != nil || call.documentationStartedAt != nil ? "Continue Docs" : "Start Docs", systemImage: "doc.text")
                                }
                                .tint(Color.brandGold)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if hasNavigableAddress(for: call) {
                                    Button {
                                        openMaps(for: call)
                                    } label: {
                                        Label("Navigate", systemImage: "map")
                                    }
                                    .tint(.blue)
                                }
                            }
                        }
                        .onDelete(perform: deleteCalls)
                    }

                    if let syncMessage {
                        Section("Sync Status") {
                            Text(syncMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if googleAuth.isAuthenticated {
                        Section("Google Calendar") {
                            Text("If Google Calendar sync was connected before the calendar permission update, disconnect Google in Settings and reconnect it once so Google can issue a new token with calendar access.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .navigationTitle("Schedule")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack {
                            Button {
                                syncGoogleCalendar()
                            } label: {
                                Label(isSyncingGoogleCalendar ? "Syncing..." : "Sync Google", systemImage: "arrow.triangle.2.circlepath")
                                    .bold()
                            }
                            .disabled(isSyncingGoogleCalendar || !googleAuth.isAuthenticated)
                            .tint(Color.brandGold)

                            Button {
                                showingAddCallSheet = true
                            } label: {
                                Label("Add Call", systemImage: "plus")
                                    .bold()
                            }
                            .tint(Color.brandGold)
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        EditButton()
                            .tint(Color.brandGold)
                    }
                }
                .navigationDestination(for: ServiceCall.self) { call in
                    ServiceCallDetailView(call: call)
                        .tint(Color.brandGold)
                }
                .sheet(isPresented: $showingAddCallSheet) {
                    AddServiceCallView(selectedDate: selectedDate) { createdCall in
                        openDocumentationInCloseout = false
                        openDocumentationInTapToPay = false
                        documentationCall = createdCall
                    }
                        .tint(Color.brandGold)
                }
                .sheet(item: $documentationCall) { call in
                    NavigationStack {
                        BillingDocumentsView(
                            initialServiceCall: call,
                            openCloseoutOnAppear: openDocumentationInCloseout,
                            openTapToPayOnAppear: openDocumentationInTapToPay
                        )
                            .tint(Color.brandGold)
                    }
                    .onDisappear {
                        openDocumentationInCloseout = false
                        openDocumentationInTapToPay = false
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var dashboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your Upcoming Jobs (Next 7 Days)")
                    .font(.headline)
                    .foregroundColor(Color.brandGold)
                if upcomingJobs.isEmpty {
                    Text("No upcoming jobs.")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(upcomingJobs.prefix(3)) { job in
                        HStack {
                            Text(job.customer.name)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Spacer()
                            Text(job.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    if upcomingJobs.count > 3 {
                        Text("And \(upcomingJobs.count - 3) more...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Needs Documentation")
                    .font(.headline)
                    .foregroundColor(Color.brandGold)
                if jobsNeedingDocumentation.isEmpty {
                    Text("No jobs are waiting on documentation.")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(jobsNeedingDocumentation.prefix(3)) { job in
                        Button {
                            openDocumentationInCloseout = false
                            openDocumentationInTapToPay = false
                            documentationCall = job
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.customer.name)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Text(job.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("Open Docs")
                                    .font(.caption)
                                    .foregroundColor(Color.brandGold)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if jobsNeedingDocumentation.count > 3 {
                        Text("And \(jobsNeedingDocumentation.count - 3) more...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Overdue Collections")
                    .font(.headline)
                    .foregroundColor(Color.brandGold)
                if overdueCollectionJobs.isEmpty {
                    Text("No overdue invoice follow-up is waiting.")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(overdueCollectionJobs.prefix(3)) { job in
                        Button {
                            openDocumentationInCloseout = true
                            openDocumentationInTapToPay = tapToPayReady
                            documentationCall = job
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.customer.name)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    if let invoice = invoice(for: job) {
                                        Text("Invoice age: \(invoiceAgeDescription(invoice))")
                                            .font(.caption2)
                                            .foregroundColor(.red)
                                    }
                                }
                                Spacer()
                                if let balanceDue = balanceDue(for: job) {
                                    Text(balanceDue, format: .currency(code: "USD"))
                                        .font(.caption)
                                        .foregroundColor(Color.brandGold)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if overdueCollectionJobs.count > 3 {
                        Text("And \(overdueCollectionJobs.count - 3) more...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Needs Payment")
                    .font(.headline)
                    .foregroundColor(Color.brandGold)
                if jobsNeedingPayment.isEmpty {
                    Text("No jobs currently have an open invoice balance.")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(jobsNeedingPayment.prefix(3)) { job in
                        Button {
                            openDocumentationInCloseout = true
                            openDocumentationInTapToPay = tapToPayReady
                            documentationCall = job
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.customer.name)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Text(job.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if let balanceDue = balanceDue(for: job) {
                                    Text(balanceDue, format: .currency(code: "USD"))
                                        .font(.caption)
                                        .foregroundColor(Color.brandGold)
                                }
                                Text(tapToPayReady ? "Tap to Pay" : "Take Payment")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if jobsNeedingPayment.count > 3 {
                        Text("And \(jobsNeedingPayment.count - 3) more...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Active Recurring Contracts")
                    .font(.headline)
                    .foregroundColor(Color.brandGold)
                if activeRecurringContracts.isEmpty {
                    Text("No active contracts.")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(activeRecurringContracts.prefix(3)) { contract in
                        HStack {
                            Text(contract.customer.name)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Spacer()
                            Text("Next Due: \(contract.nextDate.formatted(date: .abbreviated, time: .omitted))")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    if activeRecurringContracts.count > 3 {
                        Text("And \(activeRecurringContracts.count - 3) more...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func serviceCallRow(for call: ServiceCall) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(call.type.rawValue.capitalized)
                    .font(.headline)
                    .foregroundColor(Color.brandGold)
                Text("- ")
                    .foregroundColor(.primary)
                Text(call.customer.name)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Text("Time: \(call.scheduledDate.formatted(date: .omitted, time: .shortened)) - \(call.status.rawValue.capitalized)")
                .font(.caption)
                .foregroundColor(.gray)
            if let address = call.siteAddress ?? call.customer.address,
               !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text(address)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button {
                        openMaps(for: call)
                    } label: {
                        Label("Navigate", systemImage: "map")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(Color.brandGold)
                }
            }
            HStack(spacing: 8) {
                if call.googleEventID != nil {
                    Label("Google", systemImage: "calendar.badge.checkmark")
                }
                if call.documentationStartedAt != nil {
                    Label("Started", systemImage: "doc.text")
                }
                if let estimate = estimate(for: call) {
                    Label(estimate.status.capitalized, systemImage: "list.clipboard.fill")
                }
                if let invoice = invoice(for: call) {
                    Label(invoice.status.capitalized, systemImage: invoice.status == "paid" ? "checkmark.circle.fill" : "creditcard.fill")
                }
                if isCollectionOverdue(for: call) {
                    Label("Overdue", systemImage: "exclamationmark.triangle.fill")
                }
                if let balanceDue = balanceDue(for: call), balanceDue > 0 {
                    Text("Due \(balanceDue, format: .currency(code: "USD"))")
                } else if call.linkedInvoiceID != nil {
                    Text("Paid")
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)

            HStack(spacing: 10) {
                if let phoneURL = phoneURL(for: call) {
                    Button {
                        openURL(phoneURL)
                    } label: {
                        Label("Call", systemImage: "phone")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(Color.brandGold)
                }

                if let emailURL = emailURL(for: call) {
                    Button {
                        openURL(emailURL)
                    } label: {
                        Label("Email", systemImage: "envelope")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(Color.brandGold)
                }

                if hasNavigableAddress(for: call) {
                    Button {
                        openMaps(for: call)
                    } label: {
                        Label("Navigate", systemImage: "map")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(Color.brandGold)
                }

                Button {
                    openDocumentationInCloseout = false
                    openDocumentationInTapToPay = false
                    documentationCall = call
                } label: {
                    Label(call.linkedEstimateID != nil || call.linkedInvoiceID != nil || call.documentationStartedAt != nil ? "Continue Docs" : "Start Docs", systemImage: "doc.text")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundColor(Color.brandGold)

                if let invoice = invoice(for: call), invoice.status != "paid" {
                    Button {
                        openDocumentationInCloseout = true
                        openDocumentationInTapToPay = tapToPayReady
                        documentationCall = call
                    } label: {
                        Label(tapToPayReady ? "Tap to Pay" : "Take Payment", systemImage: "creditcard")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.green)

                    if let reminderURL = reminderEmailURL(for: call) {
                        Button {
                            openURL(reminderURL)
                        } label: {
                            Label("Remind", systemImage: "envelope.badge")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.orange)
                    }
                }
            }
        }
    }
    
    private func deleteCalls(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(filteredCalls[index])
            }
        }
    }

    private func syncGoogleCalendar() {
        guard googleAuth.isAuthenticated else {
            syncMessage = "Sign in with Google first."
            return
        }
        isSyncingGoogleCalendar = true
        syncMessage = "Syncing Google Calendar..."
        let signedInEmail = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
        GoogleCalendarScheduleSync.sync(
            auth: googleAuth,
            modelContext: modelContext,
            signedInEmail: signedInEmail
            ,
            isAdminUser: isAdminUser
        ) { result in
            DispatchQueue.main.async {
                isSyncingGoogleCalendar = false
                switch result {
                case .success(let message):
                    syncMessage = message
                case .failure(let error):
                    let detail = error.localizedDescription
                    if detail.localizedCaseInsensitiveContains("insufficient") ||
                        detail.localizedCaseInsensitiveContains("scope") ||
                        detail.localizedCaseInsensitiveContains("forbidden") {
                        syncMessage = "Google Calendar sync failed: \(detail) Disconnect Google in Settings and reconnect it so the app can request calendar permission."
                    } else {
                        syncMessage = "Google Calendar sync failed: \(detail)"
                    }
                }
            }
        }
    }

    private func openMaps(for call: ServiceCall) {
        let address = (call.siteAddress ?? call.customer.address)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address, !address.isEmpty else { return }
        var components = URLComponents(string: "http://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: address)]
        if let url = components?.url {
            openURL(url)
        }
    }

    private func hasNavigableAddress(for call: ServiceCall) -> Bool {
        let address = (call.siteAddress ?? call.customer.address)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(address?.isEmpty ?? true)
    }

    private func phoneURL(for call: ServiceCall) -> URL? {
        guard let phone = call.customer.phone?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !phone.isEmpty else { return nil }
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel://\(digits)")
    }

    private func emailURL(for call: ServiceCall) -> URL? {
        guard let email = call.customer.email?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        return URL(string: "mailto:\(email)")
    }

    private func invoice(for call: ServiceCall) -> Invoice? {
        guard let invoiceID = call.linkedInvoiceID else { return nil }
        return invoices.first { $0.id == invoiceID }
    }

    private func estimate(for call: ServiceCall) -> Estimate? {
        guard let estimateID = call.linkedEstimateID else { return nil }
        return estimates.first { $0.id == estimateID }
    }

    private func balanceDue(for call: ServiceCall) -> Double? {
        guard let invoice = invoice(for: call) else { return nil }
        let paid = payments
            .filter { $0.invoice.id == invoice.id }
            .reduce(0) { $0 + $1.amount }
        return max(invoice.amount - paid, 0)
    }

    private func isCollectionOverdue(for call: ServiceCall) -> Bool {
        guard let invoice = invoice(for: call),
              let balanceDue = balanceDue(for: call),
              balanceDue > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return false }
        return invoice.createdAt < cutoff
    }

    private func invoiceAgeDescription(_ invoice: Invoice) -> String {
        let days = Calendar.current.dateComponents([.day], from: invoice.createdAt, to: Date()).day ?? 0
        return days <= 0 ? "Due today" : "\(days)d old"
    }

    private func reminderEmailURL(for call: ServiceCall) -> URL? {
        guard let invoice = invoice(for: call),
              let balanceDue = balanceDue(for: call),
              balanceDue > 0,
              let email = call.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        let invoiceReference = invoice.quickBooksID?.isEmpty == false ? invoice.quickBooksID! : String(invoice.id.uuidString.prefix(8))
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Invoice Balance Due - \(invoiceReference)"),
            URLQueryItem(name: "body", value: """
Hello \(call.customer.name),

This is a reminder that your current invoice balance is \(balanceDue.formatted(.currency(code: "USD"))).

Invoice reference: \(invoiceReference)

Thank you,
GunnAire
""")
        ]
        return components.url
    }
}

#Preview {
    ScheduleView()
}
