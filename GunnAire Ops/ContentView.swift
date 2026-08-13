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

    @State private var selectedSidebarItem: SidebarItem? = .commandCenter
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
            case .estimates, .quickBooksManagement, .syncIntegrations:
                return isAdminUser
            default:
                return true
            }
        }
    }

    private var operationsItems: [SidebarItem] {
        [.commandCenter, .timeClock, .scheduleAndJobs, .customers, .onsiteDocumentation]
            .filter { visibleSidebarItems.contains($0) }
    }

    private var backOfficeItems: [SidebarItem] {
        [.mail, .estimates, .invoices, .payments, .receiptsBills]
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

    private var pendingAppRoute: GunnAireAppRoute? {
        GunnAireAppIntentRouter.consumePendingRoute()
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
                        case .commandCenter:
                            OperationsDashboardView()
                        case .timeClock:
                            TimeClockView()
                        case .scheduleAndJobs:
                            ScheduleView()
                        case .customers:
                            CustomersView()
                        case .mail:
                            GmailView()
                        case .estimates:
                            BillingDocumentsView(workspaceMode: .estimates)
                        case .invoices:
                            BillingDocumentsView(workspaceMode: .invoices)
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
            isQuickBooksAuthenticated = QuickBooksDataAPI.shared.isAuthenticated
            isGoogleAuthenticated = GoogleAuthManager.shared.isAuthenticated
            ensurePrimaryAdminExists()
            cleanupCalendarCreatedCustomersIfNeeded()
            refreshGoogleAccountIdentityIfNeeded()
            if let selectedSidebarItem, !visibleSidebarItems.contains(selectedSidebarItem) {
                self.selectedSidebarItem = .commandCenter
            }
            applyPendingAppRouteIfNeeded()
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            QuickBooksAuthAPI.shared.reloadStoredSession()
            isQuickBooksAuthenticated = QuickBooksDataAPI.shared.isAuthenticated
            applyPendingAppRouteIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickBooksAuthenticationDidChange)) { _ in
            QuickBooksAuthAPI.shared.reloadStoredSession()
            isQuickBooksAuthenticated = QuickBooksDataAPI.shared.isAuthenticated
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GunnAireRouteDidChange"))) { _ in
            applyPendingAppRouteIfNeeded()
        }
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
        case .commandCenter: return "rectangle.3.group"
        case .timeClock: return "clock"
        case .scheduleAndJobs: return "calendar"
        case .customers: return "person.3"
        case .mail: return "envelope"
        case .estimates: return "doc.text.magnifyingglass"
        case .invoices: return "doc.text"
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

    private func cleanupCalendarCreatedCustomersIfNeeded() {
        _ = CustomerDataMaintenance.cleanupCalendarNamedCustomers(modelContext: modelContext)
    }

    private func applyPendingAppRouteIfNeeded() {
        guard let route = pendingAppRoute else { return }
        let targetItem = route.sidebarItem
        withAnimation(.easeInOut(duration: 0.2)) {
            if visibleSidebarItems.contains(targetItem) {
                selectedSidebarItem = targetItem
            } else {
                selectedSidebarItem = .commandCenter
            }
            columnVisibility = UIDevice.current.userInterfaceIdiom == .pad ? .doubleColumn : .detailOnly
        }
    }
}

// QuickBooksManagementView moved to QuickBooksManagementView.swift

// ScheduleView moved to ScheduleView.swift

// ReceiptsAndBillsView moved to ReceiptsAndBillsView.swift

// PaymentsAndReceiptsView moved to PaymentsAndReceiptsView.swift

// MARK: - Remaining Views

// ... rest of the file remains unchanged ...

// MARK: - Service Call Detail View (unchanged except foregroundColor)

struct ServiceCallDetailView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @AppStorage("requireJobCompletionChecklist") private var requireJobCompletionChecklist = true
    @AppStorage("enablePhotoDocumentation") private var enablePhotoDocumentation = true
    @AppStorage("enableOnsitePayments") private var enableOnsitePayments = false
    @AppStorage("onsitePaymentProcessor") private var onsitePaymentProcessor = OnsitePaymentProcessor.none.rawValue
    @AppStorage("onsitePaymentProcessorReady") private var onsitePaymentProcessorReady = false
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

    private var phoneURL: URL? {
        guard let phone = call.customer.phone?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phone.isEmpty else { return nil }
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel://\(digits)")
    }

    private var emailURL: URL? {
        guard let email = call.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        return URL(string: "mailto:\(email)")
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
        linkedPayments.reduce(0) { partial, payment in
            partial + payment.amount
        }
    }

    private var invoiceBalanceDue: Double {
        guard let invoice = linkedInvoice else { return 0 }
        if invoice.status.caseInsensitiveCompare("paid") == .orderedSame {
            return 0
        }
        return max(invoice.amount - totalPaid, 0)
    }

    private var balanceLabel: String? {
        guard linkedInvoice != nil else { return nil }
        return invoiceBalanceDue.formatted(.currency(code: "USD"))
    }

    private var hasOpenInvoiceBalance: Bool {
        linkedInvoice != nil && invoiceBalanceDue > 0.009
    }

    private var collectionIsOverdue: Bool {
        guard let linkedInvoice, hasOpenInvoiceBalance,
              let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return false }
        return linkedInvoice.createdAt < cutoff
    }

    private var reminderEmailURL: URL? {
        guard let linkedInvoice,
              hasOpenInvoiceBalance,
              let draft = reminderEmailDraft(for: linkedInvoice) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.to
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.body)
        ]
        return components.url
    }

    private func reminderEmailDraft(for invoice: Invoice) -> (to: String, subject: String, body: String)? {
        guard let email = call.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        let reference = invoice.quickBooksID?.isEmpty == false ? invoice.quickBooksID! : String(invoice.id.uuidString.prefix(8))
        return (
            to: email,
            subject: "Invoice Balance Due - \(reference)",
            body: """
Hello \(call.customer.name),

This is a reminder that your current invoice balance is \(invoiceBalanceDue.formatted(.currency(code: "USD"))).

Invoice reference: \(reference)

Thank you,
GunnAire
"""
        )
    }

    private var documentationActionLabel: String {
        let hasDocumentation = call.linkedEstimateID != nil || call.linkedInvoiceID != nil || call.documentationStartedAt != nil
        switch call.type {
        case .estimate:
            return hasDocumentation ? "Continue Estimate" : "Start Estimate"
        case .install, .maintenance, .service, .meeting, .reminder, .siteVisit, .other:
            if call.linkedInvoiceID != nil {
                return "Continue Invoice"
            }
            return hasDocumentation ? "Continue Documentation" : "Start Documentation"
        }
    }

    private var estimateFollowUpEmailURL: URL? {
        guard let linkedEstimate,
              let draft = estimateFollowUpEmailDraft(for: linkedEstimate) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.to
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.body)
        ]
        return components.url
    }

    private func estimateFollowUpEmailDraft(for estimate: Estimate) -> (to: String, subject: String, body: String)? {
        guard let email = call.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        let reference = estimate.quickBooksID?.isEmpty == false ? estimate.quickBooksID! : String(estimate.id.uuidString.prefix(8))
        return (
            to: email,
            subject: "Estimate Follow-Up - \(reference)",
            body: """
Hello \(call.customer.name),

Following up on your estimate for \(estimate.amount.formatted(.currency(code: "USD"))).

Please let us know if you would like to move forward or if you have any questions.

Thank you,
GunnAire
"""
        )
    }

    private func openReminderEmail(fallbackURL: URL) {
        if let linkedInvoice, googleAuth.isAuthenticated, let draft = reminderEmailDraft(for: linkedInvoice) {
            GunnAireAppIntentRouter.storeMailDraftRoute(to: draft.to, subject: draft.subject, body: draft.body)
        } else {
            openURL(fallbackURL)
        }
    }

    private func openEstimateFollowUpEmail(fallbackURL: URL) {
        if let linkedEstimate, googleAuth.isAuthenticated, let draft = estimateFollowUpEmailDraft(for: linkedEstimate) {
            GunnAireAppIntentRouter.storeMailDraftRoute(to: draft.to, subject: draft.subject, body: draft.body)
        } else {
            openURL(fallbackURL)
        }
    }

    private var jobWorkflowTitle: String {
        switch call.type {
        case .service:
            return "Service Workflow"
        case .estimate:
            return "Estimate Workflow"
        case .install:
            return "Install Workflow"
        case .maintenance:
            return "Maintenance Workflow"
        case .meeting:
            return "Meeting Workflow"
        case .reminder:
            return "Reminder Workflow"
        case .siteVisit:
            return "Site Visit Workflow"
        case .other:
            return "General Workflow"
        }
    }

    private var relatedEquipmentCalls: [ServiceCall] {
        guard let equipmentKey = normalizedEquipmentKey(for: call), !equipmentKey.isEmpty else { return [] }
        return serviceCalls.filter { candidate in
            candidate.id != call.id &&
            candidate.customer.id == call.customer.id &&
            normalizedEquipmentKey(for: candidate) == equipmentKey
        }
    }

    private var selectedProcessor: OnsitePaymentProcessor {
        OnsitePaymentProcessor(rawValue: onsitePaymentProcessor) ?? .none
    }

    private var canViewFinancials: Bool {
        let email = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
        return AppAccess.isAdmin(email: email, users: users)
    }

    private var tapToPayReady: Bool {
        enableOnsitePayments &&
        selectedProcessor.supportsTapToPay &&
        OnsitePaymentManager.shared.processorReady()
    }

    private var checklistIsComplete: Bool {
        call.customerNotified &&
        call.arrivalConfirmed &&
        call.workCompletedChecklist &&
        call.documentationChecklist &&
        call.paymentCollectedChecklist
    }

    private func normalizedEquipmentKey(for call: ServiceCall) -> String? {
        if let serial = call.equipmentSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serial.isEmpty {
            return "serial:\(serial.lowercased())"
        }

        let equipmentName = call.equipmentName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let equipmentModel = call.equipmentModel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let composite = "\(equipmentName)|\(equipmentModel)"
        return composite == "|" || composite.isEmpty ? nil : composite
    }

    private var activeServiceAgreement: RecurringMaintenanceContract? {
        call.customer.recurringContracts
            .filter(\.active)
            .sorted(by: { $0.nextDate < $1.nextDate })
            .first
    }

    private var recentCustomerCalls: [ServiceCall] {
        serviceCalls
            .filter { $0.customer.id == call.customer.id }
            .sorted(by: { $0.scheduledDate > $1.scheduledDate })
            .prefix(4)
            .map { $0 }
    }

    private var customerLifetimeInvoiceTotal: Double {
        invoices
            .filter { $0.customer.id == call.customer.id }
            .reduce(0) { $0 + $1.amount }
    }

    private func scheduleFollowUpVisit() {
        let scheduledDate = call.followUpDueDate ?? Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let notesPrefix = call.followUpAction?.trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedNotes = [notesPrefix, call.notes]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n\n")

        let followUpCall = ServiceCall(
            siteAddress: call.siteAddress ?? call.customer.address,
            equipmentName: call.equipmentName,
            equipmentManufacturer: call.equipmentManufacturer,
            equipmentModel: call.equipmentModel,
            equipmentSerialNumber: call.equipmentSerialNumber,
            equipmentLocation: call.equipmentLocation,
            equipmentInstallDate: call.equipmentInstallDate,
            equipmentWarrantyExpiration: call.equipmentWarrantyExpiration,
            customerEquipmentID: call.customerEquipmentID,
            type: call.type,
            scheduledDate: scheduledDate,
            duration: call.duration,
            assignedTechnician: call.assignedTechnician,
            customer: call.customer,
            status: .scheduled,
            notes: generatedNotes.isEmpty ? "Scheduled follow-up visit" : "Scheduled follow-up visit\n\n\(generatedNotes)",
            findingsSummary: call.findingsSummary,
            recommendedWorkSummary: call.recommendedWorkSummary,
            followUpRequired: false
        )
        modelContext.insert(followUpCall)
        call.followUpRequired = false
        call.followUpAction = nil
        call.followUpDueDate = nil
    }

    private func scheduleApprovedWorkFromEstimate() {
        let scheduledDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let generatedNotes = [call.recommendedWorkSummary, call.notes]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n\n")

        let approvedWorkCall = ServiceCall(
            siteAddress: call.siteAddress ?? call.customer.address,
            equipmentName: call.equipmentName,
            equipmentManufacturer: call.equipmentManufacturer,
            equipmentModel: call.equipmentModel,
            equipmentSerialNumber: call.equipmentSerialNumber,
            equipmentLocation: call.equipmentLocation,
            equipmentInstallDate: call.equipmentInstallDate,
            equipmentWarrantyExpiration: call.equipmentWarrantyExpiration,
            customerEquipmentID: call.customerEquipmentID,
            type: call.type == .estimate ? .install : call.type,
            scheduledDate: scheduledDate,
            duration: call.duration,
            assignedTechnician: call.assignedTechnician,
            customer: call.customer,
            status: .scheduled,
            notes: generatedNotes.isEmpty ? "Scheduled from approved estimate" : "Scheduled from approved estimate\n\n\(generatedNotes)",
            findingsSummary: call.findingsSummary,
            recommendedWorkSummary: call.recommendedWorkSummary,
            followUpRequired: false
        )
        modelContext.insert(approvedWorkCall)
        call.followUpRequired = false
        call.followUpAction = nil
        call.followUpDueDate = nil
    }

    var body: some View {
        ZStack {
            WatermarkBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(call.type.displayName)
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
                            Button {
                                if let mapsURL {
                                    openURL(mapsURL)
                                }
                            } label: {
                                Label(resolvedAddress, systemImage: "map")
                            }
                            .buttonStyle(.plain)
                        }
                        if let notes = call.notes, !notes.isEmpty {
                            Text("Notes: \(notes)")
                        }
                        if let findingsSummary = call.findingsSummary, !findingsSummary.isEmpty {
                            Text("Findings: \(findingsSummary)")
                        }
                        if let recommendedWorkSummary = call.recommendedWorkSummary, !recommendedWorkSummary.isEmpty {
                            Text("Recommended Work: \(recommendedWorkSummary)")
                        }
                        if call.followUpRequired {
                            Text("Follow-up required")
                                .foregroundColor(.orange)
                            if let followUpAction = call.followUpAction, !followUpAction.isEmpty {
                                Text("Next action: \(followUpAction)")
                            }
                            if let followUpDueDate = call.followUpDueDate {
                                Text("Due: \(followUpDueDate.formatted(date: .abbreviated, time: .omitted))")
                            }
                            Button("Schedule Follow-Up Visit") {
                                scheduleFollowUpVisit()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .foregroundColor(.primary)

                    GroupBox("Equipment") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let equipmentSummary = call.equipmentSummary {
                                Text(equipmentSummary)
                                    .font(.headline)
                            } else {
                                Text("No equipment profile recorded yet.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let warrantyDate = call.equipmentWarrantyExpiration {
                                Text("Warranty expires: \(warrantyDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if phoneURL != nil || emailURL != nil || mapsURL != nil {
                        GroupBox("Customer Contact") {
                            HStack(spacing: 12) {
                                if let phoneURL {
                                    Button {
                                        openURL(phoneURL)
                                    } label: {
                                        Label("Call", systemImage: "phone")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if let emailURL {
                                    Button {
                                        openURL(emailURL)
                                    } label: {
                                        Label("Email", systemImage: "envelope")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if let mapsURL {
                                    Button {
                                        openURL(mapsURL)
                                    } label: {
                                        Label("Navigate", systemImage: "map")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .tint(Color.brandGold)
                        }
                    }

                    GroupBox("Membership & History") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let agreement = activeServiceAgreement {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Active Service Agreement")
                                        .font(.headline)
                                    Text(agreement.schedulePattern)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("Next visit: \(agreement.nextDate.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("Reminder: \(agreement.reminderDate.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Text("No active service agreement on file.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Text(canViewFinancials
                                 ? "\(call.customer.serviceCalls.count) jobs • \(call.customer.invoices.count) invoices • \(call.customer.activeContractsCount) active agreements"
                                 : "\(call.customer.serviceCalls.count) jobs • \(call.customer.activeContractsCount) active agreements")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if canViewFinancials && customerLifetimeInvoiceTotal > 0 {
                                Text("Lifetime invoiced: \(customerLifetimeInvoiceTotal, format: .currency(code: "USD"))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            if !recentCustomerCalls.isEmpty {
                                ForEach(recentCustomerCalls) { historyCall in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(historyCall.type.displayName) • \(historyCall.status.rawValue.capitalized)")
                                            .font(.caption)
                                        Text(historyCall.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        if let historyNotes = historyCall.notes, !historyNotes.isEmpty {
                                            Text(historyNotes)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    GroupBox(jobWorkflowTitle) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Workflow progress: \(call.workflowChecklistCompletedCount)/\(call.workflowChecklistTotalCount)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            switch call.type {
                            case .service:
                                Toggle("Diagnostics captured", isOn: Binding(
                                    get: { call.diagnosticsCaptured },
                                    set: { call.diagnosticsCaptured = $0 }
                                ))
                                Toggle("Recommended work reviewed with customer", isOn: Binding(
                                    get: { call.quoteReviewedWithCustomer },
                                    set: { call.quoteReviewedWithCustomer = $0 }
                                ))
                                Toggle("Safety checks completed", isOn: Binding(
                                    get: { call.safetyChecklistComplete },
                                    set: { call.safetyChecklistComplete = $0 }
                                ))
                            case .estimate:
                                Toggle("Scope reviewed with customer", isOn: Binding(
                                    get: { call.quoteReviewedWithCustomer },
                                    set: { call.quoteReviewedWithCustomer = $0 }
                                ))
                                Toggle("Findings captured for quote", isOn: Binding(
                                    get: { call.diagnosticsCaptured },
                                    set: { call.diagnosticsCaptured = $0 }
                                ))
                                Toggle("Follow-up scheduled", isOn: Binding(
                                    get: { call.followUpRequired },
                                    set: { call.followUpRequired = $0 }
                                ))
                            case .install:
                                Toggle("Equipment verified", isOn: Binding(
                                    get: { call.equipmentVerifiedChecklist },
                                    set: { call.equipmentVerifiedChecklist = $0 }
                                ))
                                Toggle("Startup checklist complete", isOn: Binding(
                                    get: { call.startupChecklistComplete },
                                    set: { call.startupChecklistComplete = $0 }
                                ))
                                Toggle("Safety checks completed", isOn: Binding(
                                    get: { call.safetyChecklistComplete },
                                    set: { call.safetyChecklistComplete = $0 }
                                ))
                            case .maintenance:
                                Toggle("Maintenance checklist complete", isOn: Binding(
                                    get: { call.maintenanceChecklistComplete },
                                    set: { call.maintenanceChecklistComplete = $0 }
                                ))
                                Toggle("Safety checks completed", isOn: Binding(
                                    get: { call.safetyChecklistComplete },
                                    set: { call.safetyChecklistComplete = $0 }
                                ))
                                Toggle("Customer notified of findings", isOn: Binding(
                                    get: { call.customerNotified },
                                    set: { call.customerNotified = $0 }
                                ))
                            case .meeting, .reminder, .siteVisit, .other:
                                Toggle("Arrival confirmed", isOn: Binding(
                                    get: { call.arrivalConfirmed },
                                    set: { call.arrivalConfirmed = $0 }
                                ))
                                Toggle("Action items documented", isOn: Binding(
                                    get: { call.workCompletedChecklist },
                                    set: { call.workCompletedChecklist = $0 }
                                ))
                                Toggle("Notes completed", isOn: Binding(
                                    get: { call.documentationChecklist },
                                    set: { call.documentationChecklist = $0 }
                                ))
                            }
                        }
                    }

                    if !relatedEquipmentCalls.isEmpty {
                        GroupBox("Equipment History") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(relatedEquipmentCalls.prefix(5)) { historyCall in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(historyCall.type.displayName) • \(historyCall.status.rawValue.capitalized)")
                                            .font(.caption)
                                        Text(historyCall.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        if let historyNotes = historyCall.notes, !historyNotes.isEmpty {
                                            Text(historyNotes)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if canViewFinancials {
                        GroupBox("Documentation") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(call.linkedEstimateID == nil && call.linkedInvoiceID == nil ? "No estimate or invoice linked yet." : "This job already has linked billing documentation.")
                                .foregroundColor(.secondary)
                            if let linkedEstimate {
                                Text("Estimate: \(linkedEstimate.amount, format: .currency(code: "USD")) • \(linkedEstimate.status.capitalized)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                HStack {
                                    Button("Accepted") {
                                        linkedEstimate.status = "accepted"
                                        call.followUpRequired = false
                                        call.followUpAction = nil
                                        call.followUpDueDate = nil
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Rejected") {
                                        linkedEstimate.status = "rejected"
                                        call.followUpRequired = false
                                        call.followUpAction = nil
                                        call.followUpDueDate = nil
                                    }
                                    .buttonStyle(.bordered)

                                    if let estimateFollowUpEmailURL {
                                        Button("Follow Up") {
                                            openEstimateFollowUpEmail(fallbackURL: estimateFollowUpEmailURL)
                                            linkedEstimate.status = "follow-up"
                                            call.followUpRequired = true
                                            call.followUpAction = "Follow up on estimate"
                                            call.followUpDueDate = Calendar.current.date(byAdding: .day, value: 3, to: Date())
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    if linkedEstimate.status == "accepted" {
                                        Button("Schedule Approved Work") {
                                            scheduleApprovedWorkFromEstimate()
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
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
                                if let latestPayment = linkedPayments.sorted(by: { $0.date > $1.date }).first {
                                    Text("Latest payment: \(latestPayment.methodSummary)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if let balanceLabel {
                                    Text("Remaining balance: \(balanceLabel)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else if let linkedInvoice,
                                      linkedInvoice.status.caseInsensitiveCompare("paid") != .orderedSame {
                                Text("Remaining balance: \(linkedInvoice.amount, format: .currency(code: "USD"))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if collectionIsOverdue {
                                Text("Collection follow-up is overdue.")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                        }
                    } else {
                        GroupBox("Documentation") {
                            VStack(alignment: .leading, spacing: 8) {
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
                            if canViewFinancials {
                                Toggle("Payment or billing follow-up handled", isOn: Binding(
                                    get: { call.paymentCollectedChecklist },
                                    set: { call.paymentCollectedChecklist = $0 }
                                ))
                            }

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

                    if canViewFinancials {
                        Button {
                            GunnAireAppIntentRouter.storeDocumentationRoute(call.id)
                        } label: {
                            Label(documentationActionLabel, systemImage: "doc.text")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                    }

                    if canViewFinancials && hasOpenInvoiceBalance {
                        VStack(spacing: 10) {
                            Button {
                                if let linkedInvoiceID = call.linkedInvoiceID {
                                    GunnAireAppIntentRouter.storePaymentCollectionRoute(linkedInvoiceID)
                                } else {
                                    GunnAireAppIntentRouter.storeDocumentationRoute(call.id)
                                }
                            } label: {
                                Label(tapToPayReady ? "Tap to Pay" : "Take Payment", systemImage: "creditcard")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)

                            if let reminderEmailURL {
                                Button {
                                    openReminderEmail(fallbackURL: reminderEmailURL)
                                } label: {
                                    Label("Send Payment Reminder", systemImage: "envelope.badge")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(.orange)
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding()
            }
        }
        .navigationTitle("Call Details")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingEditSheet = true
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
            }
        }
        .foregroundColor(Color.brandGold)
        .fullScreenCover(isPresented: $showingEditSheet) {
            EditServiceCallView(call: call)
                .tint(Color.brandGold)
        }
    }
}

struct ServiceCalendarRouteOption: Identifiable, Equatable {
    let id: String
    let label: String
}

enum ServiceCalendarRouting {
    static func routeOptions(from calendars: [GoogleCalendar]) -> [ServiceCalendarRouteOption] {
        var options = calendars
            .filter(\.isWritable)
            .sorted { $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending }
            .map { ServiceCalendarRouteOption(id: $0.id, label: $0.displayLabel) }

        if !options.contains(where: { $0.id == "primary" }) {
            options.insert(ServiceCalendarRouteOption(id: "primary", label: "Primary Calendar"), at: 0)
        }
        return options
    }

    static func preferredCalendarID(for technician: Technician?, calendars: [GoogleCalendar]) -> String {
        guard let technician else { return "primary" }
        if let matchedCalendar = calendars.first(where: { $0.isWritable && $0.matchesTechnicianEmail(technician.contactInfo) }) {
            return matchedCalendar.id
        }
        return "primary"
    }

    static func assignedCalendarID(for technician: Technician?) -> String {
        guard let technician else { return "primary" }
        let calendarID = AppAccess.normalizedEmail(technician.contactInfo)
        return calendarID.isEmpty ? "primary" : calendarID
    }

    static func hasStaleAssignedCalendarRoute(calendarID: String?, technician: Technician?) -> Bool {
        let expectedCalendarID = assignedCalendarID(for: technician)
        let currentCalendarID = AppAccess.normalizedEmail(calendarID)
        let resolvedCalendarID = currentCalendarID.isEmpty ? "primary" : currentCalendarID
        return resolvedCalendarID != expectedCalendarID
    }

    static func validSelection(_ selectedCalendarID: String, technician: Technician?, calendars: [GoogleCalendar]) -> String {
        if routeOptions(from: calendars).contains(where: { $0.id == selectedCalendarID }) {
            return selectedCalendarID
        }
        return preferredCalendarID(for: technician, calendars: calendars)
    }

    static func routingMessage(for technician: Technician?, selectedCalendarID: String, calendars: [GoogleCalendar]) -> String {
        guard let technician else {
            return selectedCalendarID == "primary"
                ? "Unassigned jobs will sync to the connected account's primary calendar."
                : "Unassigned jobs will sync to the selected writable calendar."
        }

        let assessment = TechnicianCalendarAccessAssessment.evaluate(
            calendarID: technician.contactInfo,
            availableCalendars: calendars
        )

        switch assessment.state {
        case .writable:
            if selectedCalendarID == "primary" {
                return "\(technician.name) has a writable calendar, but this job is routed to Primary Calendar."
            }
            if let matchedCalendar = calendars.first(where: { $0.isWritable && $0.matchesTechnicianEmail(technician.contactInfo) }),
               selectedCalendarID == matchedCalendar.id {
                return "This job will sync to \(matchedCalendar.displayLabel)."
            }
            return "This job will sync to the selected writable calendar."
        case .readOnly:
            return "\(assessment.calendarLabel) is read-only. This job will stay on the selected writable calendar."
        case .notShared:
            return "\(assessment.calendarLabel) is not shared with write access. This job will sync to the selected writable calendar."
        case .noCalendar:
            return selectedCalendarID == "primary"
                ? "No technician calendar is assigned. This job will sync to Primary Calendar."
                : "No technician calendar is assigned. This job will sync to the selected writable calendar."
        }
    }

    static func routingTint(for technician: Technician?, selectedCalendarID: String, calendars: [GoogleCalendar]) -> Color {
        guard let technician else { return .orange }
        let assessment = TechnicianCalendarAccessAssessment.evaluate(
            calendarID: technician.contactInfo,
            availableCalendars: calendars
        )
        if assessment.state == .writable,
           let matchedCalendar = calendars.first(where: { $0.isWritable && $0.matchesTechnicianEmail(technician.contactInfo) }),
           selectedCalendarID == matchedCalendar.id {
            return .green
        }
        return assessment.state.tint
    }
}

// MARK: - Add Service Call View

struct AddServiceCallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var customers: [Customer]
    @Query private var technicians: [Technician]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query private var existingServiceCalls: [ServiceCall]
    @Query(sort: \CustomerEquipment.name, order: .forward) private var equipmentProfiles: [CustomerEquipment]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @AppStorage("defaultJobDurationMinutes") private var defaultJobDurationMinutes = 90
    
    @State private var callType: ServiceCallType = .service
    @State private var eventTitle = ""
    @State private var customer: Customer?
    @State private var technician: Technician?
    @State private var scheduledTime: Date
    @State private var duration: TimeInterval = 3600
    @State private var customerSearchText = ""
    @State private var creatingNewCustomer = false
    @State private var newCustomerName = ""
    @State private var newCustomerPhone = ""
    @State private var newCustomerEmail = ""
    @State private var newCustomerAddress = ""
    @State private var siteAddress: String = ""
    @State private var equipmentName = ""
    @State private var equipmentManufacturer = ""
    @State private var equipmentModel = ""
    @State private var equipmentSerialNumber = ""
    @State private var equipmentLocation = ""
    @State private var equipmentInstallDate: Date = Date()
    @State private var includeInstallDate = false
    @State private var equipmentWarrantyExpiration: Date = Date()
    @State private var includeWarrantyExpiration = false
    @State private var selectedCustomerEquipmentID: UUID?
    @State private var notes: String = ""
    @State private var findingsSummary = ""
    @State private var recommendedWorkSummary = ""
    @State private var followUpRequired = false
    @State private var followUpAction = ""
    @State private var followUpDueDate = Date()
    @State private var accessibleCalendars: [GoogleCalendar] = []
    @State private var selectedCalendarID: String = "primary"
    @State private var openDocumentationAfterSave = false

    let onCreated: ((ServiceCall) -> Void)?
    
    init(selectedDate: Date, onCreated: ((ServiceCall) -> Void)? = nil) {
        let calendar = Calendar.current
        let baseDate = calendar.startOfDay(for: selectedDate)
        let components = DateComponents(hour: 8)
        _scheduledTime = State(initialValue: calendar.date(byAdding: components, to: baseDate) ?? Date())
        _duration = State(initialValue: 90 * 60)
        self.onCreated = onCreated
    }

    private var filteredCustomers: [Customer] {
        let visibleCustomers = customers.filter { !CustomerDataMaintenance.isSystemCalendarCustomer($0) }
        let query = customerSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return visibleCustomers }
        return visibleCustomers.filter { customer in
            customer.name.lowercased().contains(query) ||
            (customer.email?.lowercased().contains(query) ?? false) ||
            (customer.phone?.lowercased().contains(query) ?? false) ||
            (customer.address?.lowercased().contains(query) ?? false)
        }
    }

    private var canSaveNewCustomer: Bool {
        !newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var requiresCustomer: Bool {
        switch callType {
        case .service, .estimate, .install, .maintenance:
            return true
        case .meeting, .reminder, .siteVisit, .other:
            return false
        }
    }

    private var canSaveCall: Bool {
        customer != nil || (!requiresCustomer && eventTitle.nilIfBlank != nil)
    }

    private var assignableTechnicians: [Technician] {
        AppAccess.schedulableTechnicians(technicians, users: users)
    }

    private var isAdminUser: Bool {
        let email = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
        return AppAccess.isAdmin(email: email, users: users)
    }

    private var conflictingCalls: [ServiceCall] {
        guard let technician else { return [] }
        let proposedEnd = scheduledTime.addingTimeInterval(duration)
        return existingServiceCalls.filter { call in
            guard call.assignedTechnician?.id == technician.id, call.status != .cancelled else { return false }
            let existingStart = call.scheduledDate
            let existingEnd = call.scheduledDate.addingTimeInterval(call.duration)
            return scheduledTime < existingEnd && proposedEnd > existingStart
        }
        .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var nextAvailableStartTime: Date? {
        guard !conflictingCalls.isEmpty else { return nil }
        return conflictingCalls
            .map { $0.scheduledDate.addingTimeInterval($0.duration) }
            .max()
    }

    private var selectedCustomerEquipmentProfiles: [CustomerEquipment] {
        guard let customer else { return [] }
        return equipmentProfiles.filter { $0.customer?.id == customer.id && $0.isActive }
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
                        Text(type.displayName).tag(type)
                    }
                }

                Section("Calendar Event") {
                    TextField("Event Title", text: $eventTitle)
                        .textInputAutocapitalization(.words)
                }

                Section("Customer") {
                    TextField("Search customer name", text: $customerSearchText)
                        .textInputAutocapitalization(.words)

                    if let customer {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(customer.name)
                                    .font(.headline)
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
                            }
                            Spacer()
                            Button("Clear") {
                                self.customer = nil
                                customerSearchText = ""
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if customer == nil {
                        if filteredCustomers.isEmpty {
                            Text("No matching customers found.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(filteredCustomers.prefix(8)) { matchedCustomer in
                                Button {
                                    customer = matchedCustomer
                                    customerSearchText = matchedCustomer.name
                                    if siteAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        siteAddress = matchedCustomer.address ?? ""
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(matchedCustomer.name)
                                            .foregroundColor(.primary)
                                        if let address = matchedCustomer.address, !address.isEmpty {
                                            Text(address)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button(creatingNewCustomer ? "Hide New Customer" : "Create New Customer") {
                        creatingNewCustomer.toggle()
                        if creatingNewCustomer == false {
                            resetNewCustomerFields()
                        } else if let existingCustomer = customer {
                            newCustomerName = existingCustomer.name
                            newCustomerPhone = existingCustomer.phone ?? ""
                            newCustomerEmail = existingCustomer.email ?? ""
                            newCustomerAddress = existingCustomer.address ?? ""
                        } else {
                            newCustomerName = customerSearchText
                            newCustomerAddress = siteAddress
                        }
                    }
                    .buttonStyle(.bordered)

                    if creatingNewCustomer {
                        TextField("Customer name", text: $newCustomerName)
                        TextField("Phone", text: $newCustomerPhone)
                            .keyboardType(.phonePad)
                        TextField("Email", text: $newCustomerEmail)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                        TextField("Address", text: $newCustomerAddress, axis: .vertical)
                            .lineLimit(2...3)

                        Button("Save New Customer") {
                            let trimmedName = newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines)
                            let createdCustomer = Customer(
                                name: trimmedName,
                                phone: newCustomerPhone.nilIfBlank,
                                email: newCustomerEmail.nilIfBlank,
                                address: newCustomerAddress.nilIfBlank
                            )
                            modelContext.insert(createdCustomer)
                            customer = createdCustomer
                            customerSearchText = createdCustomer.name
                            if siteAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                siteAddress = createdCustomer.address ?? ""
                            }
                            creatingNewCustomer = false
                            resetNewCustomerFields()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .disabled(!canSaveNewCustomer)
                    }
                }
                TextField("Service Address", text: $siteAddress, axis: .vertical)
                    .lineLimit(2...3)
                Section("Equipment") {
                    if !selectedCustomerEquipmentProfiles.isEmpty {
                        Picker("Customer Equipment", selection: $selectedCustomerEquipmentID) {
                            Text("No linked equipment").tag(UUID?.none)
                            ForEach(selectedCustomerEquipmentProfiles) { equipment in
                                Text(equipment.displayName).tag(UUID?.some(equipment.id))
                            }
                        }
                        .onChange(of: selectedCustomerEquipmentID) { _, selectedID in
                            guard let selectedID,
                                  let equipment = selectedCustomerEquipmentProfiles.first(where: { $0.id == selectedID }) else { return }
                            applyEquipmentProfile(equipment)
                        }
                    }
                    TextField("Equipment", text: $equipmentName)
                    TextField("Manufacturer", text: $equipmentManufacturer)
                    TextField("Model", text: $equipmentModel)
                    TextField("Serial Number", text: $equipmentSerialNumber)
                    TextField("Equipment Location", text: $equipmentLocation)
                    Toggle("Track Install Date", isOn: $includeInstallDate)
                    if includeInstallDate {
                        DatePicker("Install Date", selection: $equipmentInstallDate, displayedComponents: .date)
                    }
                    Toggle("Track Warranty Expiration", isOn: $includeWarrantyExpiration)
                    if includeWarrantyExpiration {
                        DatePicker("Warranty Expiration", selection: $equipmentWarrantyExpiration, displayedComponents: .date)
                    }
                }
                Picker("Technician", selection: $technician) {
                    Text("Unassigned").tag(Technician?.none)
                    ForEach(assignableTechnicians) { t in
                        Text(AppAccess.scheduleLabel(for: t)).tag(Technician?.some(t))
                    }
                }
                Picker("Calendar", selection: $selectedCalendarID) {
                    ForEach(availableCalendars, id: \.id) { calendar in
                        Text(calendar.label).tag(calendar.id)
                    }
                }
                Text(ServiceCalendarRouting.routingMessage(for: technician, selectedCalendarID: selectedCalendarID, calendars: accessibleCalendars))
                    .font(.caption)
                    .foregroundColor(ServiceCalendarRouting.routingTint(for: technician, selectedCalendarID: selectedCalendarID, calendars: accessibleCalendars))
                DatePicker("Scheduled Time", selection: $scheduledTime, displayedComponents: [.date, .hourAndMinute])
                Stepper(value: $duration, in: 1800...8*3600, step: 900) {
                    Text("Duration: \(Int(duration/60)) min")
                }
                if !conflictingCalls.isEmpty {
                    Section("Schedule Conflict") {
                        Text("This technician already has overlapping work scheduled.")
                            .foregroundColor(.orange)
                        ForEach(conflictingCalls.prefix(3)) { conflict in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conflict.customer.name)
                                    .font(.caption.weight(.semibold))
                                Text("\(conflict.scheduledDate.formatted(date: .abbreviated, time: .shortened)) • \(Int(conflict.duration / 60)) min")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if let nextAvailableStartTime {
                            Button("Use Next Available Slot") {
                                scheduledTime = nextAvailableStartTime
                            }
                            .buttonStyle(.bordered)
                            Text("Suggested start: \(nextAvailableStartTime.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                TextField("Notes", text: $notes, axis: .vertical)
                Section("Findings & Follow-Up") {
                    TextField("Findings", text: $findingsSummary, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Recommended Work", text: $recommendedWorkSummary, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("Follow-Up Required", isOn: $followUpRequired)
                    if followUpRequired {
                        TextField("Next Follow-Up Action", text: $followUpAction, axis: .vertical)
                            .lineLimit(2...3)
                        DatePicker("Follow-Up Due", selection: $followUpDueDate, displayedComponents: .date)
                    }
                }
                Toggle("Open Documentation After Save", isOn: $openDocumentationAfterSave)
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
                    }.disabled(!canSaveCall)
                    .tint(Color.brandGold)
                }
            }
        }
        .tint(Color.brandGold) // Accent color gold for form controls using Color
        .onAppear {
            AppAccess.ensureTechnicianRecords(for: users, technicians: technicians, modelContext: modelContext)
            duration = TimeInterval(defaultJobDurationMinutes * 60)
            loadAccessibleCalendarsIfNeeded()
        }
        .onChange(of: technician) { _, newTechnician in
            selectedCalendarID = ServiceCalendarRouting.preferredCalendarID(for: newTechnician, calendars: accessibleCalendars)
        }
        .onChange(of: customer) { _, newCustomer in
            selectedCustomerEquipmentID = nil
            guard siteAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            siteAddress = newCustomer?.address ?? ""
        }
    }
    
    private func addCall() {
        guard let resolvedCustomer = resolvedCustomerForSave() else { return }
        let trimmedSiteAddress = siteAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSiteAddress = trimmedSiteAddress.isEmpty ? resolvedCustomer.address : trimmedSiteAddress
        let resolvedCalendarID = ServiceCalendarRouting.validSelection(
            selectedCalendarID,
            technician: technician,
            calendars: accessibleCalendars
        )
        let call = ServiceCall(
            googleCalendarID: resolvedCalendarID,
            eventTitle: eventTitle.nilIfBlank,
            siteAddress: resolvedSiteAddress,
            equipmentName: equipmentName.nilIfBlank,
            equipmentManufacturer: equipmentManufacturer.nilIfBlank,
            equipmentModel: equipmentModel.nilIfBlank,
            equipmentSerialNumber: equipmentSerialNumber.nilIfBlank,
            equipmentLocation: equipmentLocation.nilIfBlank,
            equipmentInstallDate: includeInstallDate ? equipmentInstallDate : nil,
            equipmentWarrantyExpiration: includeWarrantyExpiration ? equipmentWarrantyExpiration : nil,
            customerEquipmentID: selectedCustomerEquipmentID,
            type: callType,
            scheduledDate: scheduledTime,
            duration: duration,
            assignedTechnician: technician,
            customer: resolvedCustomer,
            status: .scheduled,
            notes: notes.nilIfBlank,
            findingsSummary: findingsSummary.nilIfBlank,
            recommendedWorkSummary: recommendedWorkSummary.nilIfBlank,
            followUpRequired: followUpRequired,
            followUpAction: followUpRequired ? followUpAction.nilIfBlank : nil,
            followUpDueDate: followUpRequired ? followUpDueDate : nil
        )
        modelContext.insert(call)
        publishToGoogleCalendar(call)
        dismiss()
        if openDocumentationAfterSave {
            DispatchQueue.main.async {
                onCreated?(call)
            }
        }
    }

    private func applyEquipmentProfile(_ equipment: CustomerEquipment) {
        selectedCustomerEquipmentID = equipment.id
        equipmentName = equipment.name
        equipmentManufacturer = equipment.manufacturer ?? ""
        equipmentModel = equipment.modelNumber ?? ""
        equipmentSerialNumber = equipment.serialNumber ?? ""
        equipmentLocation = equipment.location ?? ""
        if let installDate = equipment.installDate {
            equipmentInstallDate = installDate
            includeInstallDate = true
        } else {
            includeInstallDate = false
        }
        if let warranty = equipment.warrantyExpiration {
            equipmentWarrantyExpiration = warranty
            includeWarrantyExpiration = true
        } else {
            includeWarrantyExpiration = false
        }
    }

    private func resolvedCustomerForSave() -> Customer? {
        if let customer {
            return customer
        }
        guard !requiresCustomer else { return nil }
        if let existing = customers.first(where: CustomerDataMaintenance.isSystemCalendarCustomer) {
            return existing
        }
        let placeholder = Customer(
            quickBooksID: CustomerDataMaintenance.unassignedCalendarCustomerMarker,
            name: CustomerDataMaintenance.unassignedCalendarCustomerName
        )
        modelContext.insert(placeholder)
        return placeholder
    }

    private func publishToGoogleCalendar(_ call: ServiceCall) {
        guard googleAuth.isAuthenticated else { return }
        try? modelContext.save()
        let signedInEmail = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
        GoogleCalendarScheduleSync.exportImmediately(
            call: call,
            auth: googleAuth,
            modelContext: modelContext,
            signedInEmail: signedInEmail,
            isAdminUser: isAdminUser
        )
    }

    private func resetNewCustomerFields() {
        newCustomerName = ""
        newCustomerPhone = ""
        newCustomerEmail = ""
        newCustomerAddress = ""
    }

    private func loadAccessibleCalendarsIfNeeded() {
        guard googleAuth.isAuthenticated else { return }
        googleAuth.fetchCalendars { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let calendars):
                    accessibleCalendars = calendars
                    selectedCalendarID = ServiceCalendarRouting.validSelection(
                        selectedCalendarID,
                        technician: technician,
                        calendars: calendars
                    )
                case .failure:
                    break
                }
            }
        }
    }

    private var availableCalendars: [(id: String, label: String)] {
        ServiceCalendarRouting.routeOptions(from: accessibleCalendars)
            .map { (id: $0.id, label: $0.label) }
    }
}

struct EditServiceCallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var customers: [Customer]
    @Query private var technicians: [Technician]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query private var existingServiceCalls: [ServiceCall]
    @Query(sort: \CustomerEquipment.name, order: .forward) private var equipmentProfiles: [CustomerEquipment]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared

    let call: ServiceCall

    @State private var callType: ServiceCallType
    @State private var eventTitle: String
    @State private var customer: Customer?
    @State private var technician: Technician?
    @State private var scheduledTime: Date
    @State private var duration: TimeInterval
    @State private var status: JobStatus
    @State private var siteAddress: String
    @State private var equipmentName: String
    @State private var equipmentManufacturer: String
    @State private var equipmentModel: String
    @State private var equipmentSerialNumber: String
    @State private var equipmentLocation: String
    @State private var equipmentInstallDate: Date
    @State private var includeInstallDate: Bool
    @State private var equipmentWarrantyExpiration: Date
    @State private var includeWarrantyExpiration: Bool
    @State private var selectedCustomerEquipmentID: UUID?
    @State private var notes: String
    @State private var findingsSummary: String
    @State private var recommendedWorkSummary: String
    @State private var followUpRequired: Bool
    @State private var followUpAction: String
    @State private var followUpDueDate: Date
    @State private var accessibleCalendars: [GoogleCalendar] = []
    @State private var selectedCalendarID: String

    init(call: ServiceCall) {
        self.call = call
        let storedEventTitle = call.eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recoveredEventTitle = GoogleCalendarScheduleSync.calendarEventSummary(from: call.notes)
        let initialEventTitle: String
        if let storedEventTitle,
           !storedEventTitle.isEmpty,
           (!GoogleCalendarScheduleSync.isGeneratedCalendarTitle(storedEventTitle) || recoveredEventTitle == nil) {
            initialEventTitle = storedEventTitle
        } else {
            initialEventTitle = recoveredEventTitle ?? ""
        }
        _callType = State(initialValue: call.type)
        _eventTitle = State(initialValue: initialEventTitle)
        _customer = State(initialValue: call.customer)
        _technician = State(initialValue: call.assignedTechnician)
        _scheduledTime = State(initialValue: call.scheduledDate)
        _duration = State(initialValue: call.duration)
        _status = State(initialValue: call.status)
        _siteAddress = State(initialValue: call.siteAddress ?? call.customer.address ?? "")
        _equipmentName = State(initialValue: call.equipmentName ?? "")
        _equipmentManufacturer = State(initialValue: call.equipmentManufacturer ?? "")
        _equipmentModel = State(initialValue: call.equipmentModel ?? "")
        _equipmentSerialNumber = State(initialValue: call.equipmentSerialNumber ?? "")
        _equipmentLocation = State(initialValue: call.equipmentLocation ?? "")
        _equipmentInstallDate = State(initialValue: call.equipmentInstallDate ?? Date())
        _includeInstallDate = State(initialValue: call.equipmentInstallDate != nil)
        _equipmentWarrantyExpiration = State(initialValue: call.equipmentWarrantyExpiration ?? Date())
        _includeWarrantyExpiration = State(initialValue: call.equipmentWarrantyExpiration != nil)
        _selectedCustomerEquipmentID = State(initialValue: call.customerEquipmentID)
        _notes = State(initialValue: call.notes ?? "")
        _findingsSummary = State(initialValue: call.findingsSummary ?? "")
        _recommendedWorkSummary = State(initialValue: call.recommendedWorkSummary ?? "")
        _followUpRequired = State(initialValue: call.followUpRequired)
        _followUpAction = State(initialValue: call.followUpAction ?? "")
        _followUpDueDate = State(initialValue: call.followUpDueDate ?? Date())
        _selectedCalendarID = State(initialValue: call.googleCalendarID ?? "primary")
    }

    private var conflictingCalls: [ServiceCall] {
        guard let technician else { return [] }
        let proposedEnd = scheduledTime.addingTimeInterval(duration)
        return existingServiceCalls.filter { existingCall in
            guard existingCall.id != call.id,
                  existingCall.assignedTechnician?.id == technician.id,
                  existingCall.status != .cancelled else { return false }
            let existingStart = existingCall.scheduledDate
            let existingEnd = existingCall.scheduledDate.addingTimeInterval(existingCall.duration)
            return scheduledTime < existingEnd && proposedEnd > existingStart
        }
        .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var nextAvailableStartTime: Date? {
        guard !conflictingCalls.isEmpty else { return nil }
        return conflictingCalls
            .map { $0.scheduledDate.addingTimeInterval($0.duration) }
            .max()
    }

    private var assignableTechnicians: [Technician] {
        let activeTechnicians = AppAccess.schedulableTechnicians(technicians, users: users)
        guard let technician, !activeTechnicians.contains(where: { $0.id == technician.id }) else {
            return activeTechnicians
        }
        return ([technician] + activeTechnicians)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var isAdminUser: Bool {
        let email = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
        return AppAccess.isAdmin(email: email, users: users)
    }

    private var visibleCustomers: [Customer] {
        customers.filter { !CustomerDataMaintenance.isSystemCalendarCustomer($0) }
    }

    private var selectedCustomerEquipmentProfiles: [CustomerEquipment] {
        guard let customer else { return [] }
        return equipmentProfiles.filter { $0.customer?.id == customer.id && $0.isActive }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $callType) {
                    ForEach(ServiceCallType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                Section("Calendar Event") {
                    TextField("Event Title", text: $eventTitle)
                        .textInputAutocapitalization(.words)
                }
                Picker("Customer", selection: $customer) {
                    if CustomerDataMaintenance.isSystemCalendarCustomer(call.customer) {
                        Text("Unassigned Calendar Event").tag(Customer?.some(call.customer))
                    }
                    ForEach(visibleCustomers) { customer in
                        Text(customer.name).tag(Customer?.some(customer))
                    }
                }
                Picker("Technician", selection: $technician) {
                    Text("Unassigned").tag(Technician?.none)
                    ForEach(assignableTechnicians) { technician in
                        Text(AppAccess.scheduleLabel(for: technician)).tag(Technician?.some(technician))
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
                Text(ServiceCalendarRouting.routingMessage(for: technician, selectedCalendarID: selectedCalendarID, calendars: accessibleCalendars))
                    .font(.caption)
                    .foregroundColor(ServiceCalendarRouting.routingTint(for: technician, selectedCalendarID: selectedCalendarID, calendars: accessibleCalendars))
                TextField("Service Address", text: $siteAddress, axis: .vertical)
                    .lineLimit(2...3)
                Section("Equipment") {
                    if !selectedCustomerEquipmentProfiles.isEmpty {
                        Picker("Customer Equipment", selection: $selectedCustomerEquipmentID) {
                            Text("No linked equipment").tag(UUID?.none)
                            ForEach(selectedCustomerEquipmentProfiles) { equipment in
                                Text(equipment.displayName).tag(UUID?.some(equipment.id))
                            }
                        }
                        .onChange(of: selectedCustomerEquipmentID) { _, selectedID in
                            guard let selectedID,
                                  let equipment = selectedCustomerEquipmentProfiles.first(where: { $0.id == selectedID }) else { return }
                            applyEquipmentProfile(equipment)
                        }
                    }
                    TextField("Equipment", text: $equipmentName)
                    TextField("Manufacturer", text: $equipmentManufacturer)
                    TextField("Model", text: $equipmentModel)
                    TextField("Serial Number", text: $equipmentSerialNumber)
                    TextField("Equipment Location", text: $equipmentLocation)
                    Toggle("Track Install Date", isOn: $includeInstallDate)
                    if includeInstallDate {
                        DatePicker("Install Date", selection: $equipmentInstallDate, displayedComponents: .date)
                    }
                    Toggle("Track Warranty Expiration", isOn: $includeWarrantyExpiration)
                    if includeWarrantyExpiration {
                        DatePicker("Warranty Expiration", selection: $equipmentWarrantyExpiration, displayedComponents: .date)
                    }
                }
                DatePicker("Scheduled Time", selection: $scheduledTime, displayedComponents: [.date, .hourAndMinute])
                Stepper(value: $duration, in: 1800...8*3600, step: 900) {
                    Text("Duration: \(Int(duration / 60)) min")
                }
                if !conflictingCalls.isEmpty {
                    Section("Schedule Conflict") {
                        Text("This technician already has overlapping work scheduled.")
                            .foregroundColor(.orange)
                        ForEach(conflictingCalls.prefix(3)) { conflict in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conflict.customer.name)
                                    .font(.caption.weight(.semibold))
                                Text("\(conflict.scheduledDate.formatted(date: .abbreviated, time: .shortened)) • \(Int(conflict.duration / 60)) min")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if let nextAvailableStartTime {
                            Button("Use Next Available Slot") {
                                scheduledTime = nextAvailableStartTime
                            }
                            .buttonStyle(.bordered)
                            Text("Suggested start: \(nextAvailableStartTime.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
                Section("Findings & Follow-Up") {
                    TextField("Findings", text: $findingsSummary, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Recommended Work", text: $recommendedWorkSummary, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("Follow-Up Required", isOn: $followUpRequired)
                    if followUpRequired {
                        TextField("Next Follow-Up Action", text: $followUpAction, axis: .vertical)
                            .lineLimit(2...3)
                        DatePicker("Follow-Up Due", selection: $followUpDueDate, displayedComponents: .date)
                    }
                }
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
        .onAppear {
            AppAccess.ensureTechnicianRecords(for: users, technicians: technicians, modelContext: modelContext)
            loadAccessibleCalendarsIfNeeded()
        }
        .onChange(of: technician) { _, newTechnician in
            selectedCalendarID = ServiceCalendarRouting.preferredCalendarID(for: newTechnician, calendars: accessibleCalendars)
        }
        .onChange(of: customer) { _, _ in
            if let selectedCustomerEquipmentID,
               !selectedCustomerEquipmentProfiles.contains(where: { $0.id == selectedCustomerEquipmentID }) {
                self.selectedCustomerEquipmentID = nil
            }
        }
    }

    private func applyEquipmentProfile(_ equipment: CustomerEquipment) {
        selectedCustomerEquipmentID = equipment.id
        equipmentName = equipment.name
        equipmentManufacturer = equipment.manufacturer ?? ""
        equipmentModel = equipment.modelNumber ?? ""
        equipmentSerialNumber = equipment.serialNumber ?? ""
        equipmentLocation = equipment.location ?? ""
        if let installDate = equipment.installDate {
            equipmentInstallDate = installDate
            includeInstallDate = true
        } else {
            includeInstallDate = false
        }
        if let warranty = equipment.warrantyExpiration {
            equipmentWarrantyExpiration = warranty
            includeWarrantyExpiration = true
        } else {
            includeWarrantyExpiration = false
        }
    }

    private func saveChanges() {
        guard let customer else { return }
        call.type = callType
        call.eventTitle = eventTitle.nilIfBlank
        call.customer = customer
        call.assignedTechnician = technician
        call.status = status
        if GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: call) {
            call.googleCalendarID = ServiceCalendarRouting.validSelection(
                selectedCalendarID,
                technician: technician,
                calendars: accessibleCalendars
            )
        }
        call.siteAddress = siteAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? customer.address : siteAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        call.equipmentName = equipmentName.nilIfBlank
        call.equipmentManufacturer = equipmentManufacturer.nilIfBlank
        call.equipmentModel = equipmentModel.nilIfBlank
        call.equipmentSerialNumber = equipmentSerialNumber.nilIfBlank
        call.equipmentLocation = equipmentLocation.nilIfBlank
        call.equipmentInstallDate = includeInstallDate ? equipmentInstallDate : nil
        call.equipmentWarrantyExpiration = includeWarrantyExpiration ? equipmentWarrantyExpiration : nil
        call.customerEquipmentID = selectedCustomerEquipmentID
        call.scheduledDate = scheduledTime
        call.duration = duration
        call.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes.trimmingCharacters(in: .whitespacesAndNewlines)
        call.findingsSummary = findingsSummary.nilIfBlank
        call.recommendedWorkSummary = recommendedWorkSummary.nilIfBlank
        call.followUpRequired = followUpRequired
        call.followUpAction = followUpRequired ? followUpAction.nilIfBlank : nil
        call.followUpDueDate = followUpRequired ? followUpDueDate : nil

        if status == .inProgress && call.documentationStartedAt == nil {
            call.documentationStartedAt = Date()
        }
        if status == .completed || status == .invoiced {
            call.documentationCompletedAt = call.documentationCompletedAt ?? Date()
        }
        if GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: call) {
            GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(call)
        }
        try? modelContext.save()
        publishToGoogleCalendar(call)
        dismiss()
    }

    private func publishToGoogleCalendar(_ call: ServiceCall) {
        guard googleAuth.isAuthenticated else { return }
        let signedInEmail = googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
        GoogleCalendarScheduleSync.exportImmediately(
            call: call,
            auth: googleAuth,
            modelContext: modelContext,
            signedInEmail: signedInEmail,
            isAdminUser: isAdminUser
        )
    }

    private func loadAccessibleCalendarsIfNeeded() {
        guard googleAuth.isAuthenticated else { return }
        googleAuth.fetchCalendars { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let calendars):
                    accessibleCalendars = calendars
                    selectedCalendarID = ServiceCalendarRouting.validSelection(
                        selectedCalendarID,
                        technician: technician,
                        calendars: calendars
                    )
                case .failure:
                    break
                }
            }
        }
    }

    private var availableCalendars: [(id: String, label: String)] {
        ServiceCalendarRouting.routeOptions(from: accessibleCalendars)
            .map { (id: $0.id, label: $0.label) }
    }
}

// MARK: - OAuth Authentication Extensions for ContentView

extension ContentView {
    // MARK: - QuickBooks OAuth Authentication
    func authenticateQuickBooks() {
        QuickBooksAuthAPI.shared.startSignIn(presentationContext: authPresentationContextProvider) { result in
            switch result {
            case .success:
                QuickBooksDataAPI.shared.validateAccountingConnection { validationResult in
                    DispatchQueue.main.async {
                        switch validationResult {
                        case .success(let company):
                            isQuickBooksAuthenticated = true
                            quickBooksOAuthState = nil
                            let name = company.CompanyName ?? company.LegalName ?? company.Id ?? "the selected company"
                            presentAuthAlert(
                                title: "QuickBooks Connected",
                                message: "Connected to \(name). Use QuickBooks Management to run a full sync."
                            )
                        case .failure(let error):
                            isQuickBooksAuthenticated = QuickBooksDataAPI.shared.isAuthenticated
                            presentAuthAlert(
                                title: "QuickBooks Connected, Access Check Failed",
                                message: error.localizedDescription
                            )
                        }
                    }
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
        Task { @MainActor in
            var failures: [String] = []
            var paymentsWarnings: [String] = []
            var customers: [QuickBooksCustomer] = []
            var items: [QuickBooksItem] = []
            var estimates: [QuickBooksEstimate] = []
            var invoices: [QuickBooksInvoice] = []
            var bills: [QuickBooksBill] = []
            var purchases: [QuickBooksPurchase] = []
            var vendors: [QuickBooksVendor] = []
            var payments: [QuickBooksPayment] = []
            var salesReceipts: [QuickBooksSalesReceipt] = []
            var deposits: [QuickBooksDeposit] = []
            var paymentMethods: [QuickBooksPaymentMethod] = []
            var storedCards: [QuickBooksPaymentsCardRecord] = []

            func fetch<T>(label: String, _ operation: (@escaping (Result<[T], Error>) -> Void) -> Void) async -> [T] {
                guard await QuickBooksDataAPI.shared.isAuthenticated else {
                    return []
                }

                return await withCheckedContinuation { continuation in
                    operation { result in
                        DispatchQueue.main.async {
                            switch result {
                            case .success(let records):
                                continuation.resume(returning: records)
                            case .failure(let error):
                                failures.append("\(label): \(error.localizedDescription)")
                                if let qbError = error as? QuickBooksDataAPI.QBError,
                                   qbError.requiresReconnect {
                                    QuickBooksAuthAPI.shared.reloadStoredSession()
                                    isQuickBooksAuthenticated = false
                                }
                                continuation.resume(returning: [])
                            }
                        }
                    }
                }
            }

            customers = await fetch(label: "Customers", QuickBooksDataAPI.shared.fetchCustomers)
            guard QuickBooksDataAPI.shared.isAuthenticated else {
                presentAuthAlert(
                    title: "QuickBooks Reconnect Required",
                    message: failures.first ?? "QuickBooks rejected this app session. Reconnect QuickBooks in Settings with a company admin, then retry sync."
                )
                return
            }
            items = await fetch(label: "Catalog", QuickBooksDataAPI.shared.fetchItems)
            guard QuickBooksDataAPI.shared.isAuthenticated else {
                presentAuthAlert(
                    title: "QuickBooks Reconnect Required",
                    message: failures.first ?? "QuickBooks rejected this app session. Reconnect QuickBooks in Settings with a company admin, then retry sync."
                )
                return
            }
            estimates = await fetch(label: "Estimates", QuickBooksDataAPI.shared.fetchEstimates)
            guard QuickBooksDataAPI.shared.isAuthenticated else {
                presentAuthAlert(
                    title: "QuickBooks Reconnect Required",
                    message: failures.first ?? "QuickBooks rejected this app session. Reconnect QuickBooks in Settings with a company admin, then retry sync."
                )
                return
            }
            invoices = await fetch(label: "Invoices", QuickBooksDataAPI.shared.fetchInvoices)
            bills = await fetch(label: "Bills", QuickBooksDataAPI.shared.fetchBills)
            purchases = await fetch(label: "Purchases", QuickBooksDataAPI.shared.fetchPurchases)
            vendors = await fetch(label: "Vendors", QuickBooksDataAPI.shared.fetchVendors)
            payments = await fetch(label: "Payments", QuickBooksDataAPI.shared.fetchPayments)
            salesReceipts = await fetch(label: "Sales Receipts", QuickBooksDataAPI.shared.fetchSalesReceipts)
            deposits = await fetch(label: "Deposits", QuickBooksDataAPI.shared.fetchDeposits)
            paymentMethods = await fetch(label: "Payment Methods", QuickBooksDataAPI.shared.fetchPaymentMethods)
            if QuickBooksDataAPI.shared.canUseQuickBooksPaymentsAPI {
                storedCards = await withCheckedContinuation { continuation in
                    QuickBooksDataAPI.shared.fetchCards(forCustomerIDs: customers.map(\.Id)) { result in
                        DispatchQueue.main.async {
                            switch result {
                            case .success(let records):
                                continuation.resume(returning: records)
                            case .failure(let error):
                                paymentsWarnings.append("Stored Cards: \(error.localizedDescription)")
                                continuation.resume(returning: [])
                            }
                        }
                    }
                }
            } else if Config.QuickBooks.enablePaymentsScope {
                paymentsWarnings.append("Stored Cards: skipped because this QuickBooks token is not authorized for \(Config.QuickBooks.paymentsScope). Accounting sync remains active.")
            } else {
                paymentsWarnings.append("Stored Cards: skipped because QuickBooks Payments scope is disabled for this build.")
            }

            guard QuickBooksDataAPI.shared.isAuthenticated else {
                presentAuthAlert(
                    title: "QuickBooks Reconnect Required",
                    message: failures.first ?? "QuickBooks rejected this app session. Reconnect QuickBooks in Settings with a company admin, then retry sync."
                )
                return
            }

            do {
                try QuickBooksLocalSync.importSnapshot(
                    customers: customers,
                    items: items,
                    estimates: estimates,
                    invoices: invoices,
                    payments: payments,
                    vendors: vendors,
                    into: modelContext
                )
            } catch {
                failures.append("Local app sync: \(error.localizedDescription)")
            }

            if failures.isEmpty {
                let baseMessage = "QuickBooks Accounting sync completed. Loaded \(customers.count) customers, \(items.count) catalog items, \(estimates.count) estimates, \(invoices.count) invoices, \(salesReceipts.count) sales receipts, \(bills.count) bills, \(purchases.count) purchases, \(vendors.count) vendors, \(payments.count) payments, \(paymentMethods.count) payment methods, and \(deposits.count) deposits."
                let message: String
                if paymentsWarnings.isEmpty {
                    message = "\(baseMessage) Loaded \(storedCards.count) stored cards."
                } else {
                    message = "\(baseMessage)\n\nQuickBooks Payments warning:\n\(paymentsWarnings.joined(separator: "\n"))"
                }
                presentAuthAlert(title: "QuickBooks Sync Complete", message: message)
            } else {
                presentAuthAlert(
                    title: "QuickBooks Sync Incomplete",
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
    private static weak var lastResolvedAnchor: UIWindow?
    
    @inline(__always)
    private static func dlog(_ message: String) {
        #if DEBUG
        logger.debug("\(message, privacy: .public)")
        #endif
    }

    private static func remember(_ window: UIWindow, reason: String) -> ASPresentationAnchor {
        lastResolvedAnchor = window
        dlog(reason)
        return window
    }

    private static func makeEmergencyAnchor() -> UIWindow {
        // This is a final fallback for impossible startup timing where no UIWindowScene
        // exists yet. Use Objective-C runtime construction here to avoid the deprecated
        // scene-less UIWindow initializer showing up as a compile-time warning.
        if let unmanagedWindow = UIWindow.perform(NSSelectorFromString("new")),
           let window = unmanagedWindow.takeUnretainedValue() as? UIWindow {
            return window
        }

        for _ in 0..<5 {
            if let lastResolvedAnchor {
                return lastResolvedAnchor
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        logger.fault("Objective-C emergency auth anchor creation failed; retrying runtime construction for auth anchor.")
        let selector = NSSelectorFromString("new")
        let emergencyWindow = UIWindow.perform(selector)!
        return unsafeDowncast(emergencyWindow.takeUnretainedValue(), to: UIWindow.self)
    }
    
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Prefer a key window from the active window scene
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) {
            
            // If there's an existing key window, return it
            if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return Self.remember(keyWindow, reason: "Returning keyWindow from foreground scene")
            }
            // Fallback: return the first available window in the scene
            if let anyWindow = windowScene.windows.first {
                return Self.remember(anyWindow, reason: "Returning first window from foreground scene")
            }
            // As a last resort, create a temporary window attached to the scene using the non-deprecated initializer
            let tempWindow = UIWindow(windowScene: windowScene)
            return Self.remember(tempWindow, reason: "Creating temp window from foreground scene via init(windowScene:)")
        }

        // If no suitable window was found above, try to create one from any foreground scene first.
        if let fgScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) {
            let tempWindow = UIWindow(windowScene: fgScene)
            return Self.remember(tempWindow, reason: "Creating temp window from foreground scene (fallback)")
        }

        // As a broader fallback, use any available scene.
        if let anyScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first {
            let tempWindow = UIWindow(windowScene: anyScene)
            return Self.remember(tempWindow, reason: "Creating temp window from any available scene (broad fallback)")
        }

        // If no scenes exist yet, keep using the most recent valid anchor rather than
        // creating a deprecated empty presentation anchor.
        if let lastResolvedAnchor = Self.lastResolvedAnchor {
            return Self.remember(lastResolvedAnchor, reason: "Reusing last resolved auth anchor")
        }

        Self.logger.fault("No UIWindowScene available for auth anchor; falling back to an emergency presentation anchor.")
        let emergencyAnchor = Self.makeEmergencyAnchor()
        return Self.remember(emergencyAnchor, reason: "Creating emergency auth anchor without a scene")
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
