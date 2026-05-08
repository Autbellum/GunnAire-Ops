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
    @State private var navigationPath = NavigationPath()
    @State private var openDocumentationInCloseout = false
    @State private var openDocumentationInTapToPay = false
    @State private var isSyncingGoogleCalendar = false
    @State private var syncMessage: String?
    @State private var didApplyPendingScheduleIntent = false

    private var selectedDayCalls: [ServiceCall] {
        callsForSignedInUser
            .filter { Calendar.current.isDate($0.scheduledDate, inSameDayAs: selectedDate) }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var upcomingJobs: [ServiceCall] {
        let now = Date()
        let calendar = Calendar.current
        let sevenDaysAhead = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        return callsForSignedInUser.filter { $0.scheduledDate >= now && $0.scheduledDate <= sevenDaysAhead }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var snapshotCalls: [ServiceCall] {
        Array(upcomingJobs.prefix(3))
    }

    private var followUpCalls: [ServiceCall] {
        callsForSignedInUser
            .filter { call in
                call.followUpRequired ||
                (call.type == .estimate && call.linkedInvoiceID == nil) ||
                isCollectionOverdue(for: call)
            }
            .sorted {
                let lhsDueDate = $0.followUpDueDate ?? $0.scheduledDate
                let rhsDueDate = $1.followUpDueDate ?? $1.scheduledDate
                if lhsDueDate != rhsDueDate {
                    return lhsDueDate < rhsDueDate
                }
                if $0.followUpRequired != $1.followUpRequired {
                    return $0.followUpRequired && !$1.followUpRequired
                }
                return $0.scheduledDate > $1.scheduledDate
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
            NavigationStack(path: $navigationPath) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        snapshotSection

                        VStack(alignment: .leading, spacing: 10) {
                            sectionTitle("Calendar")
                            DatePicker(
                                "Select Date",
                                selection: $selectedDate,
                                displayedComponents: [.date]
                            )
                            .labelsHidden()
                            .datePickerStyle(.graphical)
                            .padding(12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                sectionTitle(selectedDate.formatted(.dateTime.month(.wide).day().year()))
                                Spacer()
                                Text("\(selectedDayCalls.count) event\(selectedDayCalls.count == 1 ? "" : "s")")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }

                            if selectedDayCalls.isEmpty {
                                emptyDayState
                            } else {
                                LazyVStack(spacing: 10) {
                                    ForEach(selectedDayCalls) { call in
                                        NavigationLink(value: call) {
                                            serviceCallRow(for: call)
                                        }
                                        .buttonStyle(.plain)
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
                            }
                        }

                        if let syncMessage {
                            Text(syncMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)
                        }

                        if googleAuth.isAuthenticated {
                            Text("If Google Calendar sync was connected before the calendar permission update, disconnect Google in Settings and reconnect it once so the app can request fresh calendar permission.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
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
                .onAppear(perform: applyPendingScheduleIntentIfNeeded)
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

    private func applyPendingScheduleIntentIfNeeded() {
        guard !didApplyPendingScheduleIntent else { return }
        didApplyPendingScheduleIntent = true
        guard let pendingID = GunnAireAppIntentRouter.consumePendingScheduleCallID(),
              let call = callsForSignedInUser.first(where: { $0.id == pendingID }) ?? serviceCalls.first(where: { $0.id == pendingID }) else {
            return
        }
        selectedDate = Calendar.current.startOfDay(for: call.scheduledDate)
        navigationPath.append(call)
    }

    @ViewBuilder
    private var snapshotSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("Upcoming Snapshot")
                Spacer()
                if !upcomingJobs.isEmpty {
                    Text("\(upcomingJobs.count) this week")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if snapshotCalls.isEmpty {
                Text("No upcoming jobs scheduled.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshotCalls) { job in
                    Button {
                        selectedDate = Calendar.current.startOfDay(for: job.scheduledDate)
                        navigationPath.append(job)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.customer.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(job.type.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(job.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    if job.id != snapshotCalls.last?.id {
                        Divider()
                    }
                }
            }

            if !followUpCalls.isEmpty {
                Divider()
                Text("Follow-Up Queue")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandGold)

                ForEach(followUpCalls.prefix(3)) { job in
                    Button {
                        selectedDate = Calendar.current.startOfDay(for: job.scheduledDate)
                        navigationPath.append(job)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(job.customer.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(followUpReason(for: job))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(job.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func serviceCallRow(for call: ServiceCall) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(call.customer.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(call.type.rawValue.capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Color.brandGold)
                }
                Spacer()
                Text(call.scheduledDate.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(call.status.rawValue.capitalized)
                .font(.caption)
                .foregroundColor(.gray)
            if let address = call.siteAddress ?? call.customer.address,
               !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(address)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if call.googleEventID != nil {
                    Label("Google", systemImage: "calendar.badge.checkmark")
                }
                if call.documentationStartedAt != nil {
                    Label("Started", systemImage: "doc.text")
                }
                if call.followUpRequired {
                    Label("Follow-Up", systemImage: "arrow.uturn.forward.circle.fill")
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
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    
    private func deleteCalls(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(selectedDayCalls[index])
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Color.brandGold)
    }

    private var emptyDayState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No events for this date.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Choose another date on the calendar or add a new service call.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

            if !activeRecurringContracts.isEmpty {
                Divider()
                Text("Upcoming Maintenance")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandGold)
                ForEach(activeRecurringContracts.prefix(3)) { contract in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contract.customer.name)
                            .font(.subheadline.weight(.semibold))
                        Text("\(contract.schedulePattern) • next \(contract.nextDate.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
              let due = balanceDue(for: call),
              due > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return false }
        return invoice.createdAt < cutoff
    }

    private func followUpReason(for call: ServiceCall) -> String {
        if isCollectionOverdue(for: call) {
            return "Overdue payment follow-up"
        }
        if call.followUpRequired,
           let followUpAction = call.followUpAction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !followUpAction.isEmpty {
            if let dueDate = call.followUpDueDate {
                return "\(followUpAction) • due \(dueDate.formatted(date: .abbreviated, time: .omitted))"
            }
            return followUpAction
        }
        if call.type == .estimate && call.linkedInvoiceID == nil {
            return "Estimate waiting on approval"
        }
        if call.followUpRequired {
            return "Technician follow-up required"
        }
        return "Needs attention"
    }

}

#Preview {
    ScheduleView()
}
