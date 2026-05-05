// Uses QuickBooksAPI.swift (in the main app target) for QuickBooks API integration.

// TODO: Restore QuickBooks integration and views after resolving QuickBooksAPI ambiguity and ObservableObject issues.

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
            isAdminUser || (item != .quickBooksManagement && item != .syncIntegrations)
        }
    }

    private var operationsItems: [SidebarItem] {
        [.timeClock, .scheduleAndJobs, .customers, .onsiteDocumentation]
            .filter { visibleSidebarItems.contains($0) }
    }

    private var backOfficeItems: [SidebarItem] {
        [.invoicesEstimates, .payments, .receiptsBills]
            .filter { visibleSidebarItems.contains($0) }
    }

    private var adminItems: [SidebarItem] {
        [.quickBooksManagement, .syncIntegrations]
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
                            CustomersSandboxView()
                        case .invoicesEstimates:
                            BillingDocumentsView()
                        case .payments:
                            PaymentsAndReceiptsView()
                        case .receiptsBills:
                            ReceiptsAndBillsView()
                        case .quickBooksManagement:
                            QuickBooksManagementView()
                        case .syncIntegrations:
                            SyncIntegrationsSandboxView()
                        case .onsiteDocumentation:
                            OnsiteDocumentationSandboxView()
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
    let call: ServiceCall
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
        
        VStack(alignment: .leading, spacing: 16) {
            Text(call.type.rawValue.capitalized)
                .font(.largeTitle)
                .foregroundColor(Color.brandGold) // Title in gold using Color
            Text("Customer: \(call.customer.name)")
                .foregroundColor(.primary)
            if let tech = call.assignedTechnician {
                Text("Technician: \(tech.name)")
                    .foregroundColor(.primary)
            }
            Text("Scheduled: \(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))")
                .foregroundColor(.primary)
            Text("Status: \(call.status.rawValue.capitalized)")
                .foregroundColor(.primary)
            if let notes = call.notes, !notes.isEmpty {
                Text("Notes: \(notes)")
                    .foregroundColor(.primary)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Call Details")
        .foregroundColor(Color.brandGold) // Navigation title in gold using Color
    }
}

// MARK: - Add Service Call View (unchanged except foregroundColor and changed NavigationView to NavigationStack)

struct AddServiceCallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var customers: [Customer]
    @Query private var technicians: [Technician]
    
    @State private var callType: ServiceCallType = .service
    @State private var customer: Customer?
    @State private var technician: Technician?
    @State private var scheduledTime: Date
    @State private var duration: TimeInterval = 3600
    @State private var notes: String = ""
    
    init(selectedDate: Date) {
        let calendar = Calendar.current
        let baseDate = calendar.startOfDay(for: selectedDate)
        let components = DateComponents(hour: 8)
        _scheduledTime = State(initialValue: calendar.date(byAdding: components, to: baseDate) ?? Date())
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
                Picker("Technician", selection: $technician) {
                    Text("Unassigned").tag(Technician?.none)
                    ForEach(technicians) { t in
                        Text(t.name).tag(Technician?.some(t))
                    }
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
    }
    
    private func addCall() {
        guard let customer else { return }
        let call = ServiceCall(
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
                fetchAndSyncGoogleData()
                DispatchQueue.main.async {
                    isGoogleAuthenticated = true
                    googleOAuthState = nil
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    presentAuthAlert(title: "Google Auth Failed", message: error.localizedDescription)
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
