// Uses QuickBooksAPI.swift (in the main app target) for QuickBooks API integration.

import SwiftUI
import SwiftData
import AuthenticationServices
import Combine
import UniformTypeIdentifiers
import Foundation
import UIKit
import os

// MARK: - Brand colors moved to BrandColors.swift

// MARK: - SidebarItem moved to SidebarItem.swift

// MARK: - ContentView with NavigationSplitView Sidebar

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("hasAuthenticatedUser") private var hasAuthenticatedUser = false
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared

    @State private var selectedSidebarItem: SidebarItem? = .timeClock
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    
    @State private var showingSettings = false
    
    // Authentication states
    @State private var isQuickBooksAuthenticated = false
    @State private var isGoogleAuthenticated = false
    
    // Alert handling state for OAuth flows
    @State private var showAuthAlert = false
    @State private var authAlertTitle = ""
    @State private var authAlertMessage = ""
    @State private var quickBooksOAuthState: String?
    @State private var googleOAuthState: String?
    
    // Strong reference to presentation context provider to avoid deallocation
    private let authPresentationContextProvider = ContentViewPresentationContextProvider()

    private var currentUserEmail: String? {
        googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
    }

    private var isAdminUser: Bool {
        AppAccess.isAdmin(email: currentUserEmail, users: users)
    }

    private var visibleSidebarItems: [SidebarItem] {
        SidebarItem.allCases.filter { item in
            switch item {
            case .quickBooksManagement:
                return isAdminUser
            case .syncIntegrations:
                return true
            default:
                return true
            }
        }
    }

    private var operationsItems: [SidebarItem] {
        [.timeClock, .scheduleAndJobs, .customers, .onsiteDocumentation]
            .filter { visibleSidebarItems.contains($0) }
    }

    private var backOfficeItems: [SidebarItem] {
        [.mail, .invoicesEstimates, .payments, .receiptsBills]
            .filter { visibleSidebarItems.contains($0) }
    }

    private var integrationItems: [SidebarItem] {
        [.syncIntegrations]
            .filter { visibleSidebarItems.contains($0) }
    }

    private var adminItems: [SidebarItem] {
        [.quickBooksManagement]
            .filter { visibleSidebarItems.contains($0) }
    }
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selectedSidebarItem) {
                Section("Operations") {
                    sidebarRows(for: operationsItems)
                }

                Section("Back Office") {
                    sidebarRows(for: backOfficeItems)
                }

                if !integrationItems.isEmpty {
                    Section("Integrations") {
                        sidebarRows(for: integrationItems)
                    }
                }

                if isAdminUser, !adminItems.isEmpty {
                    Section("Administrator") {
                        sidebarRows(for: adminItems)
                    }
                }

                Section("Account") {
                    Label(currentUserEmail ?? "Signed in", systemImage: isAdminUser ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if isAdminUser {
                        Label("Administrator", systemImage: "key.fill")
                            .font(.footnote)
                            .foregroundColor(Color.brandGold)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.automatic)
            .navigationTitle("GunnAire Ops")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .tint(Color.brandGold)
                }
            }
        } detail: {
            ZStack {
                WatermarkBackground()
                Group {
                    if let selectedSidebarItem, visibleSidebarItems.contains(selectedSidebarItem) {
                        switch selectedSidebarItem {
                        case .timeClock:
                            TimeClockView()
                        case .scheduleAndJobs:
                            ScheduleView()
                        case .customers:
                            CustomersView()
                        case .mail:
                            GmailView()
                        case .invoicesEstimates:
                            BillingDocumentsView()
                        case .payments:
                            PaymentsAndReceiptsView()
                        case .receiptsBills:
                            ReceiptsAndBillsView()
                        case .quickBooksManagement:
                            QuickBooksManagementView()
                        case .syncIntegrations:
                            SyncIntegrationsView()
                        case .onsiteDocumentation:
                            OnsiteDocumentationView()
                        }
                    } else {
                        Text("Select a menu item")
                            .foregroundColor(.secondary)
                    }
                }
                .tint(Color.brandGold)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            if UIDevice.current.userInterfaceIdiom == .pad {
                columnVisibility = .doubleColumn
            }
            QuickBooksDataAPI.shared.loadTokens()
            isQuickBooksAuthenticated = QuickBooksDataAPI.shared.tokens != nil && QuickBooksDataAPI.shared.realmID != nil
            isGoogleAuthenticated = GoogleAuthManager.shared.isAuthenticated
            ensurePrimaryAdminExists()
            refreshGoogleAccountIdentityIfNeeded()
            if let selectedSidebarItem, !visibleSidebarItems.contains(selectedSidebarItem) {
                self.selectedSidebarItem = .timeClock
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                isQuickBooksAuthenticated: $isQuickBooksAuthenticated,
                isGoogleAuthenticated: $isGoogleAuthenticated,
                authenticateQuickBooks: authenticateQuickBooks,
                authenticateGoogle: authenticateGoogle,
                disconnectQuickBooks: {
                    QuickBooksAuthAPI.shared.signOut()
                },
                disconnectGoogle: {
                    GoogleAuthManager.shared.signOut()
                },
                signOutOfApp: {
                    QuickBooksAuthAPI.shared.signOut()
                    GoogleAuthManager.shared.signOut()
                    isGoogleAuthenticated = false
                    isQuickBooksAuthenticated = false
                    showingSettings = false
                    hasAuthenticatedUser = false
                },
                dismiss: { showingSettings = false }
            )
                .tint(Color.brandGold)
        }
        .alert(authAlertTitle, isPresented: $showAuthAlert, actions: {
            Button("OK", role: .cancel) {}
        }, message: {
            Text(authAlertMessage)
        })
        .tint(Color.brandGold)
    }

    @ViewBuilder
    private func sidebarRows(for items: [SidebarItem]) -> some View {
        ForEach(items) { item in
            Label(item.rawValue, systemImage: iconName(for: item))
                .font(.body)
                .fontWeight(selectedSidebarItem == item ? .semibold : .regular)
                .foregroundColor(selectedSidebarItem == item ? Color.brandGold : .primary)
                .tag(item)
                .listRowBackground(selectedSidebarItem == item ? Color.brandGold.opacity(0.12) : Color.clear)
        }
    }
    
    private func iconName(for item: SidebarItem) -> String {
        switch item {
        case .timeClock: return "clock"
        case .scheduleAndJobs: return "calendar"
        case .customers: return "person.3"
        case .mail: return "envelope"
        case .invoicesEstimates: return "doc.text"
        case .payments: return "creditcard"
        case .receiptsBills: return "tray.and.arrow.up"
        case .quickBooksManagement: return "banknote"
        case .syncIntegrations: return "arrow.triangle.2.circlepath"
        case .onsiteDocumentation: return "book"
        }
    }

    private func ensurePrimaryAdminExists() {
        guard !users.contains(where: { $0.email == AppAccess.primaryAdminEmail }) else { return }
        modelContext.insert(AppUser(email: AppAccess.primaryAdminEmail, role: .admin))
    }
}

// MARK: - QuickBooks stub types moved to QuickBooksStub.swift

// QuickBooksManagementView moved to QuickBooksManagementView.swift

// NewInvoiceView moved to NewInvoiceView.swift

// NewBillView moved to NewBillView.swift

// NewVendorView moved to NewVendorView.swift

// NewPaymentView moved to NewPaymentView.swift

// ScheduleView moved to ScheduleView.swift

// ReceiptsAndBillsView moved to ReceiptsAndBillsView.swift

// PaymentsAndReceiptsView moved to PaymentsAndReceiptsView.swift

// MARK: - Remaining Views unchanged except for minor clarifications and comments

// ... rest of the file remains unchanged ...

// MARK: - Service Call Detail View (unchanged except foregroundColor)

struct ServiceCallDetailView: View {
    @Environment(\.openURL) private var openURL
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @AppStorage("requireJobCompletionChecklist") private var requireJobCompletionChecklist = true
    @AppStorage("enablePhotoDocumentation") private var enablePhotoDocumentation = true
    let call: ServiceCall
    @State private var showingEditSheet = false

    private var resolvedAddress: String? {
        let address = call.siteAddress ?? call.customer.address
        guard let address, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return address
    }

    private var mapsURL: URL? {
        guard let resolvedAddress else { return nil }
        var components = URLComponents(string: "http://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: resolvedAddress)]
        return components?.url
    }

    private var linkedPayments: [Payment] {
        guard let invoiceID = call.linkedInvoiceID else { return [] }
        return payments.filter { $0.invoice.id == invoiceID }
    }

    private var linkedInvoice: Invoice? {
        guard let invoiceID = call.linkedInvoiceID else { return nil }
        return invoices.first { $0.id == invoiceID }
    }

    private var linkedEstimate: Estimate? {
        guard let estimateID = call.linkedEstimateID else { return nil }
        return estimates.first { $0.id == estimateID }
    }

    private var totalPaid: Double {
        linkedPayments.reduce(0) { $0 + $1.amount }
    }

    private var balanceLabel: String? {
        guard let invoice = linkedPayments.first?.invoice else { return nil }
        let balance = max(invoice.amount - totalPaid, 0)
        return balance.formatted(.currency(code: "USD"))
    }

    private var checklistIsComplete: Bool {
        call.customerNotified &&
        call.arrivalConfirmed &&
        call.workCompletedChecklist &&
        call.documentationChecklist &&
        call.paymentCollectedChecklist
    }

    var body: some View {
        ZStack {
            WatermarkBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(call.type.rawValue.capitalized)
                        .font(.largeTitle)
                        .foregroundColor(Color.brandGold)

                    Group {
                        Text("Customer: \(call.customer.name)")
                        if let phone = call.customer.phone, !phone.isEmpty {
                            Text("Phone: \(phone)")
                        }
                        if let email = call.customer.email, !email.isEmpty {
                            Text("Email: \(email)")
                        }
                        if let tech = call.assignedTechnician {
                            Text("Technician: \(tech.name)")
                        }
                        Text("Scheduled: \(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))")
                        Text("Duration: \(Int(call.duration / 60)) minutes")
                        Text("Status: \(call.status.rawValue.capitalized)")
                        if let calendarID = call.googleCalendarID, !calendarID.isEmpty {
                            Text("Calendar: \(calendarID == "primary" ? "Primary Calendar" : calendarID)")
                        }
                        if let resolvedAddress {
                            Text("Address: \(resolvedAddress)")
                        }
                        if let notes = call.notes, !notes.isEmpty {
                            Text("Notes: \(notes)")
                        }
                    }
                    .foregroundColor(.primary)

                    GroupBox("Documentation") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(call.linkedEstimateID == nil && call.linkedInvoiceID == nil ? "No estimate or invoice linked yet." : "This job already has linked billing documentation.")
                                .foregroundColor(.secondary)
                            if let linkedEstimate {
                                Text("Estimate: \(linkedEstimate.amount, format: .currency(code: "USD")) • \(linkedEstimate.status.capitalized)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let linkedInvoice {
                                Text("Invoice: \(linkedInvoice.amount, format: .currency(code: "USD")) • \(linkedInvoice.status.capitalized)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let quickBooksID = linkedInvoice.quickBooksID, !quickBooksID.isEmpty {
                                    Text("QuickBooks invoice ID: \(quickBooksID)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text("Checklist: \(call.checklistCompletedCount)/\(call.checklistTotalCount)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if enablePhotoDocumentation {
                                Text("Photos: \(call.beforePhotoCount) before • \(call.afterPhotoCount) after")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let startedAt = call.documentationStartedAt {
                                Text("Started: \(startedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let completedAt = call.documentationCompletedAt {
                                Text("Completed: \(completedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if !linkedPayments.isEmpty {
                                Text("Payments recorded: \(linkedPayments.count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let balanceLabel {
                                    Text("Remaining balance: \(balanceLabel)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    GroupBox("Completion Checklist") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Customer notified", isOn: Binding(
                                get: { call.customerNotified },
                                set: { call.customerNotified = $0 }
                            ))
                            Toggle("Technician arrived on site", isOn: Binding(
                                get: { call.arrivalConfirmed },
                                set: { call.arrivalConfirmed = $0 }
                            ))
                            Toggle("Work completed", isOn: Binding(
                                get: { call.workCompletedChecklist },
                                set: { call.workCompletedChecklist = $0 }
                            ))
                            Toggle("Documentation captured", isOn: Binding(
                                get: { call.documentationChecklist },
                                set: { call.documentationChecklist = $0 }
                            ))
                            Toggle("Payment or billing follow-up handled", isOn: Binding(
                                get: { call.paymentCollectedChecklist },
                                set: { call.paymentCollectedChecklist = $0 }
                            ))

                            if enablePhotoDocumentation {
                                Stepper("Before photos: \(call.beforePhotoCount)", value: Binding(
                                    get: { call.beforePhotoCount },
                                    set: { call.beforePhotoCount = max(0, $0) }
                                ), in: 0...50)
                                Stepper("After photos: \(call.afterPhotoCount)", value: Binding(
                                    get: { call.afterPhotoCount },
                                    set: { call.afterPhotoCount = max(0, $0) }
                                ), in: 0...50)
                            }

                            if requireJobCompletionChecklist && !checklistIsComplete {
                                Text("Complete the checklist before marking this job done.")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    }

                    GroupBox("Job Actions") {
                        VStack(spacing: 12) {
                            Button {
                                showingEditSheet = true
                            } label: {
                                Label("Edit Call Details", systemImage: "square.and.pencil")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            HStack {
                                if call.status == .scheduled {
                                    Button {
                                        call.status = .inProgress
                                        call.documentationStartedAt = call.documentationStartedAt ?? Date()
                                    } label: {
                                        Label("Start Job", systemImage: "play.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                } else if call.status == .inProgress {
                                    Button {
                                        call.status = .completed
                                        call.documentationCompletedAt = Date()
                                    } label: {
                                        Label("Mark Complete", systemImage: "checkmark.circle.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(requireJobCompletionChecklist && !checklistIsComplete)
                                } else if call.status == .completed {
                                    Button {
                                        call.status = .inProgress
                                    } label: {
                                        Label("Reopen Job", systemImage: "arrow.uturn.backward.circle")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                        }
                    }

                    if let mapsURL {
                        Button {
                            openURL(mapsURL)
                        } label: {
                            Label("Open in Maps", systemImage: "map")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                    }

                    NavigationLink {
                        BillingDocumentsView(initialServiceCall: call)
                    } label: {
                        Label(call.linkedEstimateID != nil || call.linkedInvoiceID != nil ? "Continue Documentation" : "Start Documentation", systemImage: "doc.text")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)

                    Spacer(minLength: 0)
                }
                .padding()
            }
        }
        .navigationTitle("Call Details")
        .foregroundColor(Color.brandGold)
        .sheet(isPresented: $showingEditSheet) {
            EditServiceCallView(call: call)
        }
    }
}

// MARK: - Add Service Call View (unchanged except foregroundColor and changed NavigationView to NavigationStack)

struct AddServiceCallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var customers: [Customer]
    @Query private var technicians: [Technician]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @AppStorage("defaultJobDurationMinutes") private var defaultJobDurationMinutes = 90
    
    @State private var callType: ServiceCallType = .service
    @State private var customer: Customer?
    @State private var technician: Technician?
    @State private var scheduledTime: Date
    @State private var duration: TimeInterval = 3600
    @State private var siteAddress: String = ""
    @State private var notes: String = ""
    @State private var accessibleCalendarIDs: Set<String> = ["primary"]
    @State private var selectedCalendarID: String = "primary"
    
    init(selectedDate: Date) {
        let calendar = Calendar.current
        let baseDate = calendar.startOfDay(for: selectedDate)
        let components = DateComponents(hour: 8)
        _scheduledTime = State(initialValue: calendar.date(byAdding: components, to: baseDate) ?? Date())
        _duration = State(initialValue: 90 * 60)
    }
    
    var body: some View {
        ZStack {
            // Watermark: App logo as subtle background behind content
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .opacity(0.08)
                .blur(radius: 1)
                // Remove fixed frame constraints to fill entire screen
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .ignoresSafeArea() // Fill entire iPad screen edge-to-edge
        
        NavigationStack {
            Form {
                Picker("Type", selection: $callType) {
                    ForEach(ServiceCallType.allCases, id: \.self) { type in
                        Text(type.rawValue.capitalized).tag(type)
                    }
                }
                Picker("Customer", selection: $customer) {
                    Text("Select").tag(Customer?.none)
                    ForEach(customers) { c in
                        Text(c.name).tag(Customer?.some(c))
                    }
                }
                TextField("Service Address", text: $siteAddress, axis: .vertical)
                    .lineLimit(2...3)
                Picker("Technician", selection: $technician) {
                    Text("Unassigned").tag(Technician?.none)
                    ForEach(technicians) { t in
                        Text(t.name).tag(Technician?.some(t))
                    }
                }
                Picker("Calendar", selection: $selectedCalendarID) {
                    ForEach(availableCalendars, id: \.id) { calendar in
                        Text(calendar.label).tag(calendar.id)
                    }
                }
                if let technician {
                    Text(calendarRoutingMessage(for: technician))
                        .font(.caption)
                        .foregroundColor(calendarRoutingColor(for: technician))
                }
                DatePicker("Scheduled Time", selection: $scheduledTime, displayedComponents: [.date, .hourAndMinute])
                Stepper(value: $duration, in: 1800...8*3600, step: 900) {
                    Text("Duration: \(Int(duration/60)) min")
                }
                TextField("Notes", text: $notes, axis: .vertical)
            }
            .scrollContentBackground(.hidden)
            .background(Color.primaryBlack)
            .navigationTitle("New Service Call")
            .foregroundColor(Color.brandGold) // Title and labels in gold using Color
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Color.brandGold)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addCall()
                    }.disabled(customer == nil)
                    .tint(Color.brandGold)
                }
            }
        }
        .tint(Color.brandGold) // Accent color gold for form controls using Color
        .onAppear {
            duration = TimeInterval(defaultJobDurationMinutes * 60)
            loadAccessibleCalendarsIfNeeded()
        }
        .onChange(of: technician) { _, newTechnician in
            selectedCalendarID = preferredCalendarID(for: newTechnician) ?? "primary"
        }
        .onChange(of: customer) { _, newCustomer in
            guard siteAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            siteAddress = newCustomer?.address ?? ""
        }
    }
    
    private func addCall() {
        guard let customer else { return }
        let call = ServiceCall(
            googleCalendarID: selectedCalendarID,
            siteAddress: siteAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? customer.address : siteAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            type: callType,
            scheduledDate: scheduledTime,
            duration: duration,
            assignedTechnician: technician,
            customer: customer,
            status: .scheduled,
            notes: notes.isEmpty ? nil : notes
        )
        modelContext.insert(call)
        dismiss()
    }

    private func loadAccessibleCalendarsIfNeeded() {
        guard googleAuth.isAuthenticated else { return }
        googleAuth.fetchCalendars { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let calendars):
                    accessibleCalendarIDs = Set(calendars.map(\.id) + ["primary"])
                    if !availableCalendars.contains(where: { $0.id == selectedCalendarID }) {
                        selectedCalendarID = preferredCalendarID(for: technician) ?? "primary"
                    }
                case .failure:
                    break
                }
            }
        }
    }

    private func preferredCalendarID(for technician: Technician?) -> String? {
        guard let technicianEmail = technician?.contactInfo?.trimmingCharacters(in: .whitespacesAndNewlines),
              !technicianEmail.isEmpty else {
            return "primary"
        }
        if accessibleCalendarIDs.contains(technicianEmail) {
            return technicianEmail
        }
        if accessibleCalendarIDs.contains(technicianEmail.lowercased()) {
            return technicianEmail.lowercased()
        }
        return "primary"
    }

    private var availableCalendars: [(id: String, label: String)] {
        Array(accessibleCalendarIDs)
            .sorted()
            .map { id in
                if id == "primary" {
                    return (id: id, label: "Primary Calendar")
                }
                return (id: id, label: id)
            }
    }

    private func calendarRoutingMessage(for technician: Technician) -> String {
        guard let technicianEmail = technician.contactInfo?.trimmingCharacters(in: .whitespacesAndNewlines), !technicianEmail.isEmpty else {
            return selectedCalendarID == "primary"
                ? "This technician has no calendar email. The event will sync to the connected account's primary calendar."
                : "This technician has no calendar email. The event will sync to the selected calendar."
        }
        if selectedCalendarID == technicianEmail || selectedCalendarID == technicianEmail.lowercased() {
            return "This event will sync to \(selectedCalendarID)'s Google Calendar."
        }
        if accessibleCalendarIDs.contains(technicianEmail) || accessibleCalendarIDs.contains(technicianEmail.lowercased()) {
            return "This technician calendar is accessible. Current target: \(selectedCalendarID == "primary" ? "Primary Calendar" : selectedCalendarID)."
        }
        return "\(technicianEmail) is not currently shared with the connected Google account. The event will sync to the primary calendar unless access is granted."
    }

    private func calendarRoutingColor(for technician: Technician) -> Color {
        guard let technicianEmail = technician.contactInfo?.trimmingCharacters(in: .whitespacesAndNewlines), !technicianEmail.isEmpty else {
            return .orange
        }
        if selectedCalendarID == technicianEmail || selectedCalendarID == technicianEmail.lowercased() {
            return .green
        }
        return accessibleCalendarIDs.contains(technicianEmail) || accessibleCalendarIDs.contains(technicianEmail.lowercased()) ? .yellow : .orange
    }
}

struct EditServiceCallView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var customers: [Customer]
    @Query private var technicians: [Technician]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared

    let call: ServiceCall

    @State private var callType: ServiceCallType
    @State private var customer: Customer?
    @State private var technician: Technician?
    @State private var scheduledTime: Date
    @State private var duration: TimeInterval
    @State private var status: JobStatus
    @State private var siteAddress: String
    @State private var notes: String
    @State private var accessibleCalendarIDs: Set<String> = ["primary"]
    @State private var selectedCalendarID: String

    init(call: ServiceCall) {
        self.call = call
        _callType = State(initialValue: call.type)
        _customer = State(initialValue: call.customer)
        _technician = State(initialValue: call.assignedTechnician)
        _scheduledTime = State(initialValue: call.scheduledDate)
        _duration = State(initialValue: call.duration)
        _status = State(initialValue: call.status)
        _siteAddress = State(initialValue: call.siteAddress ?? call.customer.address ?? "")
        _notes = State(initialValue: call.notes ?? "")
        _selectedCalendarID = State(initialValue: call.googleCalendarID ?? "primary")
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $callType) {
                    ForEach(ServiceCallType.allCases, id: \.self) { type in
                        Text(type.rawValue.capitalized).tag(type)
                    }
                }
                Picker("Customer", selection: $customer) {
                    ForEach(customers) { customer in
                        Text(customer.name).tag(Customer?.some(customer))
                    }
                }
                Picker("Technician", selection: $technician) {
                    Text("Unassigned").tag(Technician?.none)
                    ForEach(technicians) { technician in
                        Text(technician.name).tag(Technician?.some(technician))
                    }
                }
                Picker("Status", selection: $status) {
                    ForEach(JobStatus.allCases, id: \.self) { status in
                        Text(status.rawValue.capitalized).tag(status)
                    }
                }
                Picker("Calendar", selection: $selectedCalendarID) {
                    ForEach(availableCalendars, id: \.id) { calendar in
                        Text(calendar.label).tag(calendar.id)
                    }
                }
                TextField("Service Address", text: $siteAddress, axis: .vertical)
                    .lineLimit(2...3)
                DatePicker("Scheduled Time", selection: $scheduledTime, displayedComponents: [.date, .hourAndMinute])
                Stepper(value: $duration, in: 1800...8*3600, step: 900) {
                    Text("Duration: \(Int(duration / 60)) min")
                }
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
            }
            .navigationTitle("Edit Service Call")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(customer == nil)
                }
            }
        }
        .tint(Color.brandGold)
        .onAppear(perform: loadAccessibleCalendarsIfNeeded)
        .onChange(of: technician) { _, newTechnician in
            if selectedCalendarID == "primary" || !availableCalendars.contains(where: { $0.id == selectedCalendarID }) {
                selectedCalendarID = preferredCalendarID(for: newTechnician) ?? "primary"
            }
        }
    }

    private func saveChanges() {
        guard let customer else { return }
        call.type = callType
        call.customer = customer
        call.assignedTechnician = technician
        call.status = status
        call.googleCalendarID = selectedCalendarID
        call.siteAddress = siteAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? customer.address : siteAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        call.scheduledDate = scheduledTime
        call.duration = duration
        call.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if status == .inProgress && call.documentationStartedAt == nil {
            call.documentationStartedAt = Date()
        }
        if status == .completed || status == .invoiced {
            call.documentationCompletedAt = call.documentationCompletedAt ?? Date()
        }
        dismiss()
    }

    private func loadAccessibleCalendarsIfNeeded() {
        guard googleAuth.isAuthenticated else { return }
        googleAuth.fetchCalendars { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let calendars):
                    accessibleCalendarIDs = Set(calendars.map(\.id) + ["primary"])
                    if !availableCalendars.contains(where: { $0.id == selectedCalendarID }) {
                        selectedCalendarID = preferredCalendarID(for: technician) ?? "primary"
                    }
                case .failure:
                    break
                }
            }
        }
    }

    private func preferredCalendarID(for technician: Technician?) -> String? {
        guard let technicianEmail = technician?.contactInfo?.trimmingCharacters(in: .whitespacesAndNewlines),
              !technicianEmail.isEmpty else {
            return "primary"
        }
        if accessibleCalendarIDs.contains(technicianEmail) {
            return technicianEmail
        }
        if accessibleCalendarIDs.contains(technicianEmail.lowercased()) {
            return technicianEmail.lowercased()
        }
        return "primary"
    }

    private var availableCalendars: [(id: String, label: String)] {
        Array(accessibleCalendarIDs)
            .sorted()
            .map { id in
                id == "primary" ? (id: id, label: "Primary Calendar") : (id: id, label: id)
            }
    }
}

// MARK: - Placeholder Views for Sidebar Sections with Comments and Example Actions

// ... (GoogleCalendarView, CustomersView, AddCustomerView, InvoicesAndEstimatesView, SyncAndIntegrationsView, OnsiteDocumentationView, SettingsView remain unchanged) ...

// MARK: - OAuth Authentication Extensions for ContentView

extension ContentView {
    // MARK: - QuickBooks OAuth Authentication
    func authenticateQuickBooks() {
        QuickBooksAPI.shared.startSignIn(presentationContext: authPresentationContextProvider) { result in
            switch result {
            case .success:
                fetchAndSyncQuickBooksData()
                DispatchQueue.main.async {
                    isQuickBooksAuthenticated = true
                    quickBooksOAuthState = nil
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    presentAuthAlert(title: "QuickBooks Auth Failed", message: error.localizedDescription)
                }
            }
        }
    }
    
    // MARK: - Google OAuth Authentication
    func authenticateGoogle() {
        GoogleAuthManager.shared.startSignIn(presentationContext: authPresentationContextProvider) { result in
            switch result {
            case .success:
                GoogleAuthManager.shared.validateSignedInDomain { validationResult in
                    switch validationResult {
                    case .success:
                        DispatchQueue.main.async {
                            isGoogleAuthenticated = true
                            googleOAuthState = nil
                            fetchAndSyncGoogleData()
                        }
                    case .failure(let error):
                        DispatchQueue.main.async {
                            isGoogleAuthenticated = false
                            presentAuthAlert(title: "Google Auth Failed", message: error.localizedDescription)
                        }
                    }
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    presentAuthAlert(title: "Google Auth Failed", message: error.localizedDescription)
                }
            }
        }
    }

    private func refreshGoogleAccountIdentityIfNeeded() {
        guard GoogleAuthManager.shared.isAuthenticated, GoogleAuthManager.shared.signedInEmail == nil else {
            return
        }
        GoogleAuthManager.shared.validateSignedInDomain { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    isGoogleAuthenticated = true
                case .failure:
                    isGoogleAuthenticated = false
                }
            }
        }
    }
    
    private func presentAuthAlert(title: String, message: String) {
        DispatchQueue.main.async {
            authAlertTitle = title
            authAlertMessage = message
            showAuthAlert = true
        }
    }
    
    // MARK: - Fetch and Sync QuickBooks data
    func fetchAndSyncQuickBooksData() {
        let group = DispatchGroup()
        var failures: [String] = []
        var invoiceCount = 0
        var billCount = 0
        var vendorCount = 0
        var paymentCount = 0

        group.enter()
        QuickBooksAPI.shared.fetchInvoices { result in
            switch result {
            case .success(let invoices):
                invoiceCount = invoices.count
            case .failure(let error):
                failures.append("Invoices: \(error.localizedDescription)")
            }
            group.leave()
        }

        group.enter()
        QuickBooksAPI.shared.fetchBills { result in
            switch result {
            case .success(let bills):
                billCount = bills.count
            case .failure(let error):
                failures.append("Bills: \(error.localizedDescription)")
            }
            group.leave()
        }

        group.enter()
        QuickBooksAPI.shared.fetchVendors { result in
            switch result {
            case .success(let vendors):
                vendorCount = vendors.count
            case .failure(let error):
                failures.append("Vendors: \(error.localizedDescription)")
            }
            group.leave()
        }

        group.enter()
        QuickBooksAPI.shared.fetchPayments { result in
            switch result {
            case .success(let payments):
                paymentCount = payments.count
            case .failure(let error):
                failures.append("Payments: \(error.localizedDescription)")
            }
            group.leave()
        }

        group.notify(queue: .main) {
            if failures.isEmpty {
                presentAuthAlert(
                    title: "QuickBooks Sync Complete",
                    message: "Loaded \(invoiceCount) invoices, \(billCount) bills, \(vendorCount) vendors, \(paymentCount) payments."
                )
            } else {
                presentAuthAlert(
                    title: "QuickBooks Sync Partial",
                    message: failures.joined(separator: "\n")
                )
            }
        }
    }
    
    // MARK: - Fetch and Sync Google data
    func fetchAndSyncGoogleData() {
        let group = DispatchGroup()
        var failures: [String] = []
        var profileEmail: String?
        var calendarCount = 0
        var eventCount = 0
        var primaryCalendarID: String?

        group.enter()
        GoogleAuthManager.shared.fetchUserProfile { result in
            switch result {
            case .success(let profile):
                profileEmail = profile.email
            case .failure(let error):
                failures.append("Profile: \(error.localizedDescription)")
            }
            group.leave()
        }

        group.enter()
        GoogleAuthManager.shared.fetchCalendars { result in
            switch result {
            case .success(let calendars):
                calendarCount = calendars.count
                primaryCalendarID = calendars.first?.id ?? "primary"
            case .failure(let error):
                failures.append("Calendars: \(error.localizedDescription)")
            }
            group.leave()
        }

        group.notify(queue: .main) {
            guard let calendarID = primaryCalendarID else {
                if failures.isEmpty {
                    presentAuthAlert(
                        title: "Google Sync Complete",
                        message: "Loaded profile \(profileEmail ?? "unknown"), \(calendarCount) calendars."
                    )
                } else {
                    presentAuthAlert(title: "Google Sync Partial", message: failures.joined(separator: "\n"))
                }
                return
            }

            GoogleAuthManager.shared.fetchCalendarEvents(
                calendarID: calendarID,
                timeMin: Date(),
                timeMax: Calendar.current.date(byAdding: .day, value: 30, to: Date())
            ) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let events):
                        eventCount = events.count
                    case .failure(let error):
                        failures.append("Events: \(error.localizedDescription)")
                    }
                    if failures.isEmpty {
                        presentAuthAlert(
                            title: "Google Sync Complete",
                            message: "Loaded profile \(profileEmail ?? "unknown"), \(calendarCount) calendars, \(eventCount) events."
                        )
                    } else {
                        presentAuthAlert(title: "Google Sync Partial", message: failures.joined(separator: "\n"))
                    }
                }
            }
        }
    }
}

// Provide a presentation anchor for ASWebAuthenticationSession
class ContentViewPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "App", category: "AuthAnchor")
    
    @inline(__always)
    private static func dlog(_ message: String) {
        #if DEBUG
        logger.debug("\(message, privacy: .public)")
        #endif
    }
    
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Prefer a key window from the active window scene
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) {
            
            // If there's an existing key window, return it
            if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                Self.dlog("Returning keyWindow from foreground scene")
                return keyWindow
            }
            // Fallback: return the first available window in the scene
            if let anyWindow = windowScene.windows.first {
                Self.dlog("Returning first window from foreground scene")
                return anyWindow
            }
            // As a last resort, create a temporary window attached to the scene using the non-deprecated initializer
            Self.dlog("Creating temp window from foreground scene via init(windowScene:)")
            let tempWindow = UIWindow(windowScene: windowScene)
            return tempWindow
        }

        // If no suitable window was found above, try to create one from any foreground scene first.
        if let fgScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) {
            Self.dlog("Creating temp window from foreground scene (fallback)")
            let tempWindow = UIWindow(windowScene: fgScene)
            return tempWindow
        }

        // As a broader fallback, use any available scene.
        if let anyScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first {
            Self.dlog("Creating temp window from any available scene (broad fallback)")
            let tempWindow = UIWindow(windowScene: anyScene)
            return tempWindow
        }

        // Preview/runtime fallback: avoid terminating the process when no scene is available yet.
        // On iOS 26+, avoid deprecated ASPresentationAnchor init(); prefer a temp window from any scene if possible.
        if let anyScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first {
            Self.dlog("Creating temp window from any available scene (ultimate fallback)")
            let tempWindow = UIWindow(windowScene: anyScene)
            return tempWindow
        }
        // If no scenes exist (e.g., SwiftUI previews very early), as a last resort return a minimal anchor.
        if #available(iOS 26.0, *) {
            // Avoid deprecated UIWindow.init() on iOS 26+. Return a temporary unattached window to satisfy ASPresentationAnchor.
            Self.dlog("No UIWindowScene available on iOS 26+; returning temporary UIWindow(frame: .zero) anchor")
            return UIWindow(frame: .zero)
        } else {
            Self.dlog("No UIWindowScene available; returning empty ASPresentationAnchor for iOS < 26")
            return ASPresentationAnchor()
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [ServiceCall.self, Customer.self, Technician.self, RecurringMaintenanceContract.self], inMemory: true)
}

#Preview("Canvas Sanity") {
    Text("Canvas is rendering.")
        .padding()
}
