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
    @State private var selectedSidebarItem: SidebarItem? = .scheduleAndJobs
    
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
    
    var body: some View {
        ZStack {
            WatermarkBackground()
            
            NavigationSplitView {
                List(selection: $selectedSidebarItem) {
                    Section(header: Text("Menu")
                        .font(.headline)
                        .bold()
                        .foregroundColor(Color.brandGold)
                    ) {
                        ForEach(SidebarItem.allCases) { item in
                            NavigationLink(value: item) {
                                Label(item.rawValue, systemImage: iconName(for: item))
                                    .font(.headline)
                                    .bold()
                                    // Use foregroundColor with Color instead of ShapeStyle to ensure proper type usage
                                    .foregroundColor(Color.brandGold)
                            }
                            .listRowBackground(Color.primaryBlack)
                        }
                    }
                }
                .listStyle(.sidebar)
                .background(Color.primaryBlack) // Sidebar background in brand black
                .scrollContentBackground(.hidden) // Hide default background to show black
                .navigationTitle("QuickTech")
                .foregroundColor(Color.brandGold) // Navigation title in gold using Color
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                                .bold()
                        }
                        .tint(Color.brandGold) // Toolbar button tint in gold
                    }
                }
            } detail: {
                Group {
                    switch selectedSidebarItem {
                    case .scheduleAndJobs:
                        ScheduleView()
                    case .googleCalendar:
                        Text("Missing view: GoogleCalendarView")
                            .foregroundColor(.secondary)
                    case .customers:
                        Text("Missing view: CustomersView")
                            .foregroundColor(.secondary)
                    case .invoicesEstimates:
                        Text("Missing view: InvoicesAndEstimatesView")
                            .foregroundColor(.secondary)
                    case .paymentsReceipts:
                        PaymentsAndReceiptsView()
                    case .receiptsBills:
                        ReceiptsAndBillsView()
                    case .quickBooksManagement:
                        QuickBooksManagementView()
                    case .syncIntegrations:
                        Text("Missing view: SyncAndIntegrationsView")
                            .foregroundColor(.secondary)
                    case .onsiteDocumentation:
                        Text("Missing view: OnsiteDocumentationView")
                            .foregroundColor(.secondary)
                    case .none:
                        Text("Select a menu item")
                            .foregroundColor(.secondary)
                    }
                }
                .tint(Color.brandGold) // Accent color for links/buttons in detail using Color
            }
            // Settings Sheet accessible from toolbar
            .sheet(isPresented: $showingSettings) {
                SettingsView(isQuickBooksAuthenticated: $isQuickBooksAuthenticated, isGoogleAuthenticated: $isGoogleAuthenticated, authenticateQuickBooks: authenticateQuickBooks, authenticateGoogle: authenticateGoogle, dismiss: { showingSettings = false })
                    .tint(Color.brandGold) // Settings sheet accent color gold using Color
            }
            // Alerts for OAuth authentication
            .alert(authAlertTitle, isPresented: $showAuthAlert, actions: {
                Button("OK", role: .cancel) {}
            }, message: {
                Text(authAlertMessage)
            })
            .tint(Color.brandGold) // Apply gold accent color app-wide for links/buttons using Color
        }
        // Make watermark and content fill entire iPad screen edge-to-edge, ignoring safe area
        .ignoresSafeArea()
    }
    
    private func iconName(for item: SidebarItem) -> String {
        switch item {
        case .scheduleAndJobs: return "calendar"
        case .googleCalendar: return "calendar.badge.plus"
        case .customers: return "person.3"
        case .invoicesEstimates: return "doc.text"
        case .paymentsReceipts: return "creditcard"
        case .receiptsBills: return "tray.and.arrow.up"
        case .quickBooksManagement: return "banknote"
        case .syncIntegrations: return "arrow.triangle.2.circlepath"
        case .onsiteDocumentation: return "book"
        }
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
        // Use ASWebAuthenticationSession to start OAuth flow for QuickBooks
        
        let clientId = Config.QuickBooks.clientID
        let redirectURI = Config.QuickBooks.redirectURI
        let scopes = "com.intuit.quickbooks.accounting"
        let state = UUID().uuidString
        quickBooksOAuthState = state
        
        guard var components = URLComponents(string: "https://appcenter.intuit.com/connect/oauth2") else {
            presentAuthAlert(title: "QuickBooks Auth Error", message: "Invalid OAuth URL")
            return
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state)
        ]
        
        guard let authURL = components.url else {
            presentAuthAlert(title: "QuickBooks Auth Error", message: "Failed to build auth URL")
            return
        }
        
        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: URL(string: redirectURI)?.scheme) { callbackURL, error in
            if let error = error {
                presentAuthAlert(title: "QuickBooks Auth Failed", message: error.localizedDescription)
                return
            }
            
            guard let callbackURL = callbackURL,
                  let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
                  let code = queryItems.first(where: { $0.name == "code" })?.value else {
                presentAuthAlert(title: "QuickBooks Auth Failed", message: "No authorization code received")
                return
            }
            guard let callbackState = queryItems.first(where: { $0.name == "state" })?.value,
                  callbackState == quickBooksOAuthState else {
                presentAuthAlert(title: "QuickBooks Auth Failed", message: "OAuth state validation failed")
                return
            }
            
            _ = code
            fetchAndSyncQuickBooksData()
            
            DispatchQueue.main.async {
                isQuickBooksAuthenticated = true
                quickBooksOAuthState = nil
                presentAuthAlert(title: "QuickBooks Auth Success", message: "Successfully authenticated with QuickBooks.")
            }
        }
        
        session.presentationContextProvider = authPresentationContextProvider
        if !session.start() {
            presentAuthAlert(title: "QuickBooks Auth Error", message: "Failed to start authentication session.")
        }
    }
    
    // MARK: - Google OAuth Authentication
    func authenticateGoogle() {
        let clientId = Config.Google.clientID
        let redirectURI = Config.Google.redirectURI
        let scopes = ["openid", "profile", "email"].joined(separator: " ")
        let state = UUID().uuidString
        googleOAuthState = state
        
        guard var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth") else {
            presentAuthAlert(title: "Google Auth Error", message: "Invalid OAuth URL")
            return
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state)
        ]
        
        guard let authURL = components.url else {
            presentAuthAlert(title: "Google Auth Error", message: "Failed to build auth URL")
            return
        }
        
        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: URL(string: redirectURI)?.scheme) { callbackURL, error in
            if let error = error {
                presentAuthAlert(title: "Google Auth Failed", message: error.localizedDescription)
                return
            }
            
            guard let callbackURL = callbackURL,
                  let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
                  let code = queryItems.first(where: { $0.name == "code" })?.value else {
                presentAuthAlert(title: "Google Auth Failed", message: "No authorization code received")
                return
            }
            guard let callbackState = queryItems.first(where: { $0.name == "state" })?.value,
                  callbackState == googleOAuthState else {
                presentAuthAlert(title: "Google Auth Failed", message: "OAuth state validation failed")
                return
            }
            
            _ = code
            fetchAndSyncGoogleData()
            
            DispatchQueue.main.async {
                isGoogleAuthenticated = true
                googleOAuthState = nil
                presentAuthAlert(title: "Google Auth Success", message: "Successfully authenticated with Google.")
            }
        }
        
        session.presentationContextProvider = authPresentationContextProvider
        if !session.start() {
            presentAuthAlert(title: "Google Auth Error", message: "Failed to start authentication session.")
        }
    }
    
    private func presentAuthAlert(title: String, message: String) {
        DispatchQueue.main.async {
            authAlertTitle = title
            authAlertMessage = message
            showAuthAlert = true
        }
    }
    
    // MARK: - Stub: Fetch and Sync QuickBooks data
    func fetchAndSyncQuickBooksData() {
        // TODO: Implement fetching QuickBooks data using API endpoints
        // Use the OAuth tokens obtained during authentication
        // Sync data with local modelContext
        // Refer to Config.swift for endpoints and credentials
        
        print("fetchAndSyncQuickBooksData() called - implement API calls here")
    }
    
    // MARK: - Stub: Fetch and Sync Google data
    func fetchAndSyncGoogleData() {
        // TODO: Implement fetching Google data using API endpoints
        // Use the OAuth tokens obtained during authentication
        // Sync data such as calendar events, contacts etc. with local modelContext
        
        print("fetchAndSyncGoogleData() called - implement API calls here")
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

        Self.dlog("No UIWindowScene available for presentation anchor")
        preconditionFailure("No UIWindowScene available for ASWebAuthenticationSession presentation anchor.")
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [ServiceCall.self, Customer.self, Technician.self, RecurringMaintenanceContract.self], inMemory: true)
}
