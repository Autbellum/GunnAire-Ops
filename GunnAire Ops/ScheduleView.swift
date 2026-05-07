import SwiftUI
import SwiftData

struct ScheduleView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\ServiceCall.scheduledDate)]) private var serviceCalls: [ServiceCall]
    @Query private var recurringContracts: [RecurringMaintenanceContract]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var showingAddCallSheet = false
    @State private var documentationCall: ServiceCall?
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
                                Button {
                                    documentationCall = call
                                } label: {
                                    Label("Start Docs", systemImage: "doc.text")
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
                        documentationCall = createdCall
                    }
                        .tint(Color.brandGold)
                }
                .sheet(item: $documentationCall) { call in
                    NavigationStack {
                        BillingDocumentsView(initialServiceCall: call)
                            .tint(Color.brandGold)
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
                if call.linkedEstimateID != nil || call.linkedInvoiceID != nil {
                    Label("Docs", systemImage: "doc.text.fill")
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
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
}

#Preview {
    ScheduleView()
}
