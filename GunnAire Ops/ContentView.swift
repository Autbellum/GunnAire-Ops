// Uses QuickBooksAPI.swift (in the main app target) for QuickBooks API integration.

import SwiftUI
import SwiftData
import AuthenticationServices
import Combine
import UniformTypeIdentifiers
import Foundation
import UIKit
import os
import CloudKit

// MARK: - Brand colors moved to BrandColors.swift

// MARK: - SidebarItem moved to SidebarItem.swift

/// Keeps repeatable App Store assets free of a signed-in person's identity
/// without changing the account context shown during normal app use.
struct AppStoreScreenshotPrivacyPolicy: Equatable, Sendable {
    static let fixtureArgument = "-appStoreScreenshotFixtures"

    static func sidebarIdentity(
        email: String?,
        processArguments: [String]
    ) -> String? {
        guard !processArguments.contains(fixtureArgument) else { return nil }
        let normalized = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? "Signed in" : normalized
    }
}

// MARK: - ContentView with NavigationSplitView Sidebar

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var cloudKitEventMonitor: GunnAireCloudKitEventMonitor
    @AppStorage("hasAuthenticatedUser") private var hasAuthenticatedUser = false
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \ServiceDocumentAttachment.createdAt, order: .reverse) private var attachments: [ServiceDocumentAttachment]
    @Query(sort: \CustomerCommunication.createdAt, order: .reverse) private var customerCommunications: [CustomerCommunication]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared

    @State private var selectedSidebarItem: SidebarItem? = .commandCenter
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    
    @State private var showingSettings = false
    @State private var restrictedRouteTitle: String?
    @State private var appWideFieldCollectionPrompt: BackendFieldPaymentAssignmentRecord?
    @State private var isCheckingFieldCollectionPrompts = false
    @State private var didLoadFieldCollectionPromptFixture = false
    @State private var isRetryingCustomerCommunicationUploads = false
    @State private var cloudKitReadiness: GunnAireCloudKit.AccountReadiness?
    @State private var showingCloudKitContinuityDetails = false
    
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
        AppIdentity.currentEmail
    }

    private var sidebarAccountIdentity: String? {
        AppStoreScreenshotPrivacyPolicy.sidebarIdentity(
            email: currentUserEmail,
            processArguments: ProcessInfo.processInfo.arguments
        )
    }

    @MainActor
    private var cloudKitContinuityNotice: CloudKitContinuityNotice? {
        cloudKitReadiness.flatMap {
            OperationalDataContinuity.cloudKitNotice(
                for: $0,
                mirroringState: cloudKitEventMonitor.state
            )
        }
    }

    private var isAdminUser: Bool {
        AppAccess.isAdmin(email: currentUserEmail, users: users)
    }

    private var isFieldTechnician: Bool {
        AppAccess.activeRole(email: currentUserEmail, users: users) == .fieldTechnician
    }

    private var fieldCollectionPromptPollingKey: String? {
        if fieldCollectionPromptFixtureRequested {
            return "ui-test-field-collection"
        }
        guard isFieldTechnician,
              GunnAireBackendService.isConfigured else { return nil }
        let email = AppAccess.normalizedEmail(currentUserEmail)
        return email.isEmpty ? nil : email
    }

    private var fieldCollectionPromptFixtureRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uiTestSeedFieldCollectionPrompt")
        #else
        false
        #endif
    }

    private var visibleSidebarItems: [SidebarItem] {
        SidebarItem.allCases.filter { item in
            AppAccess.canAccessSidebarItem(item, email: currentUserEmail, users: users)
        }
    }

    private var operationsItems: [SidebarItem] {
        [.commandCenter, .timeClock, .scheduleAndJobs, .customers, .onsiteDocumentation]
            .filter { visibleSidebarItems.contains($0) }
    }

    private var backOfficeItems: [SidebarItem] {
        [.mail, .estimates, .invoices, .payments, .reports, .receiptsBills]
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

    private var prefersPersistentSidebar: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selectedSidebarItem) {
                if let cloudKitContinuityNotice {
                    Section("Continuity") {
                        Button {
                            showingCloudKitContinuityDetails = true
                        } label: {
                            Label(
                                cloudKitContinuityNotice.title,
                                systemImage: cloudKitContinuityNotice.systemImage
                            )
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("CloudKitContinuityNotice")
                        .accessibilityHint("Shows why cross-device continuity needs attention and how to recover.")
                    }
                }

                if !operationsItems.isEmpty {
                    Section("Operations") {
                        sidebarRows(for: operationsItems)
                    }
                }

                if !backOfficeItems.isEmpty {
                    Section("Back Office") {
                        sidebarRows(for: backOfficeItems)
                    }
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
                    if let sidebarAccountIdentity {
                        Label(sidebarAccountIdentity, systemImage: isAdminUser ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("SidebarAccountIdentity")
                    }
                    if visibleSidebarItems.isEmpty {
                        Label("Account setup required", systemImage: "person.badge.key")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
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
                    if visibleSidebarItems.isEmpty {
                        ContentUnavailableView(
                            "Account setup required",
                            systemImage: "person.badge.key",
                            description: Text("Your signed-in business account has not been assigned an active role. Ask an administrator to activate your access, then reopen GunnAire Ops.")
                        )
                    } else if let selectedSidebarItem, visibleSidebarItems.contains(selectedSidebarItem) {
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
                        case .reports:
                            BusinessReportsView()
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
        .overlay(alignment: .top) {
            appWideFieldCollectionPromptBanner
        }
        .onAppear {
            if prefersPersistentSidebar {
                columnVisibility = .doubleColumn
            }
            QuickBooksDataAPI.shared.loadTokens()
            isQuickBooksAuthenticated = QuickBooksDataAPI.shared.isAuthenticated
            isGoogleAuthenticated = GoogleAuthManager.shared.isAuthenticated
            ensurePrimaryAdminExists()
            collapseCloudKitUserDuplicatesIfNeeded()
            cleanupCalendarCreatedCustomersIfNeeded()
            refreshGoogleAccountIdentityIfNeeded()
            retryPendingSharedCompanyDocumentUploadsIfNeeded()
            retryPendingCustomerCommunicationUploadsIfNeeded()
            selectedSidebarItem = SidebarNavigationPolicy.resolvedSelection(
                selectedSidebarItem,
                visibleItems: visibleSidebarItems
            )
            applyPendingAppRouteIfNeeded()
        }
        .onChange(of: visibleSidebarItems) { _, updatedItems in
            let resolvedSelection = SidebarNavigationPolicy.resolvedSelection(
                selectedSidebarItem,
                visibleItems: updatedItems
            )
            guard resolvedSelection != selectedSidebarItem else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedSidebarItem = resolvedSelection
            }
        }
        .task(id: fieldCollectionPromptPollingKey) {
            guard fieldCollectionPromptPollingKey != nil else { return }
            while !Task.isCancelled {
                await refreshAppWideFieldCollectionPrompt()
                do {
                    try await Task.sleep(for: .seconds(45))
                } catch {
                    return
                }
            }
        }
        .task {
            await refreshCloudKitContinuityReadiness()
            await StaffPushNotificationManager.shared.activateForCurrentSessionIfNeeded()
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
                    StaffPushNotificationManager.shared.prepareForSignOut()
                    FieldPaymentHandoff.shared.end()
                    GunnAireAppIntentRouter.discardAllPendingPayloads()
                    QuickBooksAuthAPI.shared.signOut()
                    GoogleAuthManager.shared.signOut()
                    AppleAuthManager.shared.signOut()
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
        .alert("Access Restricted", isPresented: Binding(
            get: { restrictedRouteTitle != nil },
            set: { if !$0 { restrictedRouteTitle = nil } }
        ), actions: {
            Button("OK", role: .cancel) {
                restrictedRouteTitle = nil
            }
        }, message: {
            Text("Your business account does not have access to \(restrictedRouteTitle ?? "this workspace"). Contact an administrator if you need access.")
        })
        .alert(
            cloudKitContinuityNotice?.title ?? "Cloud Sync",
            isPresented: $showingCloudKitContinuityDetails,
            actions: {
                Button("Check Again") {
                    showingCloudKitContinuityDetails = false
                    Task {
                        await refreshCloudKitContinuityReadiness()
                    }
                }
                Button("OK", role: .cancel) {}
            },
            message: {
                if let cloudKitContinuityNotice {
                    Text("\(cloudKitContinuityNotice.statusDetail)\n\n\(cloudKitContinuityNotice.recoveryDetail)")
                }
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            QuickBooksAuthAPI.shared.reloadStoredSession()
            isQuickBooksAuthenticated = QuickBooksDataAPI.shared.isAuthenticated
            retryPendingSharedCompanyDocumentUploadsIfNeeded()
            retryPendingCustomerCommunicationUploadsIfNeeded()
            applyPendingAppRouteIfNeeded()
            Task {
                await refreshAppWideFieldCollectionPrompt()
                await refreshCloudKitContinuityReadiness()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickBooksAuthenticationDidChange)) { _ in
            QuickBooksAuthAPI.shared.reloadStoredSession()
            isQuickBooksAuthenticated = QuickBooksDataAPI.shared.isAuthenticated
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            Task {
                await refreshCloudKitContinuityReadiness()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GunnAireRouteDidChange"))) { _ in
            applyPendingAppRouteIfNeeded()
        }
        .onContinueUserActivity(FieldPaymentHandoff.activityType) { activity in
            guard let invoiceID = FieldPaymentHandoff.invoiceID(from: activity) else { return }
            GunnAireAppIntentRouter.storePaymentCollectionRoute(
                invoiceID,
                prefersContactlessGuide: true
            )
            applyPendingAppRouteIfNeeded()
        }
        .tint(Color.brandGold)
    }

    @MainActor
    private func refreshCloudKitContinuityReadiness() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiTestSeedCloudKitUnavailable") {
            cloudKitReadiness = .unavailable
            return
        }
        if arguments.contains("-uiTestSeedCloudKitExportFailure") {
            cloudKitReadiness = .available
            if cloudKitEventMonitor.state.attentionFailure?.operation != .exportRecords {
                cloudKitEventMonitor.record(
                    CloudKitMirroringEventSnapshot(
                        operation: .exportRecords,
                        outcome: .failed
                    )
                )
            }
            return
        }
        if arguments.contains("-disableCloudKitForTesting") {
            // The unsigned UI-test host deliberately has no CloudKit
            // entitlement. Keep ordinary fixtures quiet and use the explicit
            // unavailable fixture above to exercise the real presentation.
            cloudKitReadiness = .available
            return
        }
        #endif

        cloudKitReadiness = await GunnAireCloudKit.accountReadiness()
    }

    @ViewBuilder
    private var appWideFieldCollectionPromptBanner: some View {
        if let assignment = appWideFieldCollectionPrompt {
            HStack(spacing: 12) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.title2)
                    .foregroundStyle(Color.brandGold)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Field collection assigned")
                        .font(.headline)
                    Text("\(assignment.customerName) • \(assignment.amount.formatted(.currency(code: "USD")))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button("View Task") {
                    openAppWideFieldCollectionPrompt(assignment)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brandGold)
                .foregroundStyle(Color.primaryBlack)

                Button {
                    appWideFieldCollectionPrompt = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Later")
            }
            .padding(12)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.brandGold.opacity(0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("AppWideFieldCollectionPrompt")
        }
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
        case .reports: return "chart.bar.xaxis"
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

    private func collapseCloudKitUserDuplicatesIfNeeded() {
        _ = AppUserDataMaintenance.collapseCloudKitDuplicates(users, modelContext: modelContext)
    }

    private func cleanupCalendarCreatedCustomersIfNeeded() {
        guard AppAccess.canDeleteCustomerRecords(email: currentUserEmail, users: users) else { return }
        _ = CustomerDataMaintenance.cleanupCalendarNamedCustomers(modelContext: modelContext)
    }

    private func retryPendingSharedCompanyDocumentUploadsIfNeeded() {
        guard GunnAireBackendService.isConfigured else { return }
        let pending = Array(attachments.filter(\.needsSharedCompanyStorageUpload).prefix(10))
        guard !pending.isEmpty else { return }
        Task {
            for attachment in pending {
                do {
                    let response = try await GunnAireBackendService.retrySharedCompanyDocumentUpload(attachment)
                    await MainActor.run {
                        attachment.markSharedCompanyStored(id: response.id)
                        try? modelContext.save()
                    }
                } catch {
                    await MainActor.run {
                        attachment.markSharedCompanyUploadFailed(error.localizedDescription)
                        try? modelContext.save()
                    }
                }
            }
        }
    }

    private func retryPendingCustomerCommunicationUploadsIfNeeded() {
        guard GunnAireBackendService.isConfigured,
              !isRetryingCustomerCommunicationUploads else { return }
        let pending = Array(customerCommunications.filter(\.needsSharedCompanySync).prefix(10))
        guard !pending.isEmpty else { return }
        isRetryingCustomerCommunicationUploads = true
        Task {
            for communication in pending {
                do {
                    let response = try await GunnAireBackendService.uploadCustomerCommunication(communication)
                    await MainActor.run {
                        communication.markSharedCompanySynced(id: response.id)
                        try? modelContext.save()
                    }
                } catch {
                    await MainActor.run {
                        communication.markSharedCompanySyncFailed(error.localizedDescription)
                        try? modelContext.save()
                    }
                }
            }
            await MainActor.run {
                isRetryingCustomerCommunicationUploads = false
            }
        }
    }

    @MainActor
    private func refreshAppWideFieldCollectionPrompt() async {
        guard fieldCollectionPromptPollingKey != nil,
              appWideFieldCollectionPrompt == nil,
              !isCheckingFieldCollectionPrompts else { return }

        #if DEBUG
        if fieldCollectionPromptFixtureRequested {
            guard !didLoadFieldCollectionPromptFixture else { return }
            didLoadFieldCollectionPromptFixture = true
            appWideFieldCollectionPrompt = BackendFieldPaymentAssignmentRecord(
                id: "ui-test-field-collection-assignment",
                invoiceID: "A1000000-0000-4000-8000-000000000003",
                customerName: "UI Test Collectible Customer",
                amount: 189,
                assignedTo: GunnAireUITestIdentity.technicianEmail,
                assignedBy: AppAccess.primaryAdminEmail,
                status: "pending",
                createdAt: "2026-08-27T12:00:00Z",
                acceptedAt: nil,
                cancelledAt: nil,
                collectedAmount: nil,
                completedAt: nil,
                completedBy: nil,
                completionPaymentID: nil
            )
            return
        }
        #endif

        guard GunnAireBackendService.isConfigured else { return }
        isCheckingFieldCollectionPrompts = true
        defer { isCheckingFieldCollectionPrompts = false }

        do {
            let signedInEmail = AppAccess.normalizedEmail(currentUserEmail)
            let assignments = try await GunnAireBackendService.fetchFieldPaymentAssignments()
                .filter {
                    AppAccess.normalizedEmail($0.assignedTo) == signedInEmail
                }
            let announcedIDs = Set(
                UserDefaults.standard.stringArray(
                    forKey: FieldPaymentAssignmentPromptQueue.announcedIDsDefaultsKey
                ) ?? []
            )
            guard let assignment = FieldPaymentAssignmentPromptQueue.nextUnannouncedPendingAssignment(
                from: assignments,
                announcedIDs: announcedIDs
            ) else { return }

            UserDefaults.standard.set(
                FieldPaymentAssignmentPromptQueue.recordingAnnouncement(
                    for: assignment.id,
                    previouslyAnnouncedIDs: announcedIDs
                ),
                forKey: FieldPaymentAssignmentPromptQueue.announcedIDsDefaultsKey
            )
            appWideFieldCollectionPrompt = assignment
        } catch {
            // The technician can still refresh the durable task list in
            // Payments. A transient background check must not interrupt work.
        }
    }

    private func openAppWideFieldCollectionPrompt(_ assignment: BackendFieldPaymentAssignmentRecord) {
        appWideFieldCollectionPrompt = nil
        guard let invoiceID = assignment.invoiceUUID else {
            authAlertTitle = "Collection unavailable"
            authAlertMessage = "This server assignment does not contain a valid invoice identifier. Ask dispatch to replace the task."
            showAuthAlert = true
            return
        }
        GunnAireAppIntentRouter.storePaymentCollectionRoute(
            invoiceID,
            prefersContactlessGuide: true
        )
        applyPendingAppRouteIfNeeded()
    }

    private func applyPendingAppRouteIfNeeded() {
        guard let route = pendingAppRoute else { return }
        let targetItem = route.sidebarItem
        withAnimation(.easeInOut(duration: 0.2)) {
            if visibleSidebarItems.contains(targetItem) {
                selectedSidebarItem = targetItem
            } else {
                GunnAireAppIntentRouter.discardPendingPayload(for: route)
                selectedSidebarItem = SidebarNavigationPolicy.resolvedSelection(
                    nil,
                    visibleItems: visibleSidebarItems
                )
                restrictedRouteTitle = targetItem.rawValue
            }
            columnVisibility = prefersPersistentSidebar ? .doubleColumn : .detailOnly
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
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \FieldFormTemplate.createdAt, order: .forward) private var fieldFormTemplates: [FieldFormTemplate]
    @Query(sort: \FieldFormResponse.completedAt, order: .reverse) private var fieldFormResponses: [FieldFormResponse]
    @Query(sort: \ServiceCallActivity.occurredAt, order: .reverse) private var serviceCallActivities: [ServiceCallActivity]
    @Query(sort: \ServiceDocumentAttachment.createdAt, order: .reverse) private var fieldFormAttachments: [ServiceDocumentAttachment]
    @Query(sort: \CustomerServiceLocation.name, order: .forward) private var serviceLocations: [CustomerServiceLocation]
    @Query(sort: \CustomerEquipment.name, order: .forward) private var equipmentProfiles: [CustomerEquipment]
    @Query(sort: \CustomerCommunication.createdAt, order: .reverse) private var customerCommunications: [CustomerCommunication]
    @Query(sort: \Item.name, order: .forward) private var items: [Item]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \FieldExpenseClaim.expenseDate, order: .reverse) private var fieldExpenseClaims: [FieldExpenseClaim]
    @Query(sort: \CustomerOperationalAlert.createdAt, order: .reverse) private var operationalAlerts: [CustomerOperationalAlert]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @AppStorage("requireJobCompletionChecklist") private var requireJobCompletionChecklist = true
    @AppStorage("requireWorkPerformedLogForCloseout") private var requireWorkPerformedLogForCloseout = true
    @AppStorage("enablePhotoDocumentation") private var enablePhotoDocumentation = true
    @AppStorage("enableOnsitePayments") private var enableOnsitePayments = false
    @AppStorage("onsitePaymentProcessor") private var onsitePaymentProcessor = OnsitePaymentProcessor.none.rawValue
    @AppStorage("onsitePaymentProcessorReady") private var onsitePaymentProcessorReady = false
    @AppStorage("enableMarketingCampaigns") private var enableMarketingCampaigns = false
    @AppStorage("customerReviewURL") private var customerReviewURL = ""
    let call: ServiceCall
    @State private var showingEditSheet = false
    @State private var showingCustomerPortalComposer = false
    @State private var selectedEstimateForApproval: Estimate?
    @State private var selectedEstimateForScheduling: Estimate?
    @State private var showingMaintenanceAgreementOffer = false
    @State private var selectedMaintenanceAgreementForApproval: RecurringMaintenanceContract?
    @State private var maintenanceAgreementMessage: String?
    @State private var warrantyClaimsEquipment: CustomerEquipment?
    @State private var showingEnRouteHandoff = false
    @State private var showingFieldExpenseClaim = false
    @State private var showingWorkPerformedLog = false
    @State private var showingCustomerWorkSummary = false
    @State private var expandedWorkLogHistory = false
    @State private var activeServiceTextDraft: CustomerServiceTextDraft?
    @State private var customerTextStatus: String?
    @State private var jobActionStatus: String?
    @State private var selectedWorkspace: ServiceCallDetailWorkspace = .overview
    @State private var hasSelectedInitialWorkspace = false
    private var resolvedAddress: String? {
        let address = call.siteAddress ?? call.customer.address
        guard let address, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return address
    }

    private var serviceLocation: CustomerServiceLocation? {
        CustomerServiceLocationPolicy.location(
            id: call.serviceLocationID,
            customerID: call.customer.id,
            in: serviceLocations,
            includeInactive: true
        )
    }

    private var activeOperationalAlerts: [CustomerOperationalAlert] {
        CustomerOperationalAlertPolicy.activeAlerts(
            customerID: call.customer.id,
            serviceLocationID: call.serviceLocationID,
            in: operationalAlerts
        )
    }

    private var callActivity: [ServiceCallActivity] {
        serviceCallActivities.filter { $0.serviceCallID == call.id }
    }

    private var workPerformedEntries: [ServiceCallActivity] {
        ServiceWorkLogPolicy.workPerformedEntries(for: call.id, in: serviceCallActivities)
    }

    private var customerWorkSummaryRevisions: [ServiceCallActivity] {
        ServiceWorkLogPolicy.customerSummaryRevisions(for: call.id, in: serviceCallActivities)
    }

    private var currentCustomerWorkSummary: String? {
        ServiceWorkLogPolicy.latestCustomerSummary(for: call, in: serviceCallActivities)
    }

    private var suggestedCustomerWorkSummary: String {
        ServiceWorkLogPolicy.suggestedCustomerSummary(from: workPerformedEntries)
    }

    private var workLogCloseoutMissingItem: String? {
        ServiceWorkLogPolicy.closeoutMissingItem(
            for: call,
            activities: serviceCallActivities,
            isRequired: requireWorkPerformedLogForCloseout
        )
    }

    private var originatingCall: ServiceCall? {
        guard let sourceID = call.originatingServiceCallID else { return nil }
        return serviceCalls.first { $0.id == sourceID }
    }

    private var scheduledFollowUpCall: ServiceCall? {
        guard let followUpID = call.scheduledFollowUpServiceCallID else { return nil }
        return serviceCalls.first { $0.id == followUpID }
    }

    private var availableFieldFormTemplates: [FieldFormTemplate] {
        fieldFormTemplates.filter { $0.isActive && $0.applies(to: call.type) }
    }

    private var completedFieldFormResponses: [FieldFormResponse] {
        fieldFormResponses.filter { $0.serviceCallID == call.id }
    }

    private var fieldFormCloseoutReadiness: FieldFormCloseoutReadiness {
        FieldFormCloseoutPolicy.readiness(
            serviceCallID: call.id,
            serviceType: call.type,
            templates: fieldFormTemplates,
            responses: fieldFormResponses
        )
    }

    private func fieldFormAttachment(for response: FieldFormResponse) -> ServiceDocumentAttachment? {
        let marker = "[FieldFormResponse:\(response.id.uuidString)]"
        return fieldFormAttachments.first {
            $0.serviceCallID == call.id && ($0.caption?.contains(marker) ?? false)
        }
    }

    private var currentActivityActor: String? {
        AppIdentity.currentEmail
    }

    private var mapsURL: URL? {
        AppleMapsDirections.destinationURL(address: resolvedAddress)
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

    private var reviewRequestDraft: (to: String, subject: String, body: String)? {
        guard call.isEligibleForReviewRequest,
              !hasSentReviewRequest,
              enableMarketingCampaigns,
              call.customer.allowsMarketing,
              let email = call.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty,
              let reviewURL = validReviewRequestURL else { return nil }
        let work = call.recommendedWorkSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let visitDescription = work?.isEmpty == false ? work! : call.type.displayName.lowercased()
        return (
            to: email,
            subject: "Thank you from GunnAire",
            body: """
Hello \(call.customer.name),

Thank you for choosing GunnAire for your \(visitDescription). If you have a moment, we would appreciate your feedback about your experience:

\(reviewURL.absoluteString)

Thank you,
GunnAire
"""
        )
    }

    private var hasSentReviewRequest: Bool {
        CustomerCommunication.hasConfirmedDelivery(
            workflow: .postJobReview,
            serviceCallID: call.id,
            in: customerCommunications
        )
    }

    private var validReviewRequestURL: URL? {
        let value = customerReviewURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    private var reviewRequestEmailURL: URL? {
        guard let draft = reviewRequestDraft else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.to
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.body)
        ]
        return components.url
    }

    private func openReviewRequest() {
        guard let draft = reviewRequestDraft else { return }
        if googleAuth.isAuthenticated {
            GunnAireAppIntentRouter.storeMailDraftRoute(
                to: draft.to,
                subject: draft.subject,
                body: draft.body,
                customerID: call.customer.id,
                serviceCallID: call.id,
                workflow: .postJobReview
            )
        } else if let reviewRequestEmailURL {
            openURL(reviewRequestEmailURL)
        }
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

    private var linkedProposalOptions: [Estimate] {
        guard let groupID = linkedEstimate?.proposalGroupID else { return [] }
        return estimates
            .filter { $0.serviceCallID == call.id && $0.proposalGroupID == groupID }
            .sorted { ($0.proposalOptionKind?.comparisonRank ?? Int.max) < ($1.proposalOptionKind?.comparisonRank ?? Int.max) }
    }

    private var totalPaid: Double {
        linkedPayments.reduce(0) { partial, payment in
            partial + (payment.isRefund ? -payment.amount : payment.amount)
        }
    }

    private var invoiceBalanceDue: Double {
        guard let invoice = linkedInvoice else { return 0 }
        return Invoice.outstandingBalance(for: invoice, payments: linkedPayments)
    }

    private var balanceLabel: String? {
        guard linkedInvoice != nil else { return nil }
        return invoiceBalanceDue.formatted(.currency(code: "USD"))
    }

    private var hasOpenInvoiceBalance: Bool {
        linkedInvoice != nil && invoiceBalanceDue > 0.009
    }

    private var collectionIsOverdue: Bool {
        guard let linkedInvoice, hasOpenInvoiceBalance else { return false }
        return Invoice.isOverdue(linkedInvoice, payments: linkedPayments)
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
Due date: \(invoice.effectiveDueDate().formatted(date: .long, time: .omitted))

Thank you,
GunnAire
"""
        )
    }

    private var appointmentUpdateDraft: (to: String, subject: String, body: String)? {
        makeAppointmentUpdateDraft()
    }

    private func makeAppointmentUpdateDraft(
        approximateArrivalMinutes: Int? = nil
    ) -> (to: String, subject: String, body: String)? {
        guard (call.status == .scheduled || call.status == .inProgress),
              call.customer.allowsTransactionalEmail,
              let email = call.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }

        let arrivalEstimate: EnRouteArrivalEstimate?
        if let approximateArrivalMinutes {
            guard let validEstimate = EnRouteArrivalEstimate(rawValue: approximateArrivalMinutes) else {
                return nil
            }
            arrivalEstimate = validEstimate
        } else {
            arrivalEstimate = nil
        }

        let appointment = call.customerAppointmentSummary
        let location = resolvedAddress.map { " at \($0)" } ?? ""
        let update: String
        switch call.technicianJobPresence {
        case .scheduled:
            guard arrivalEstimate == nil else { return nil }
            update = "This is a confirmation of your scheduled service appointment."
        case .enRoute:
            if let arrivalEstimate {
                update = "Your GunnAire technician is on the way and expects to arrive in approximately \(arrivalEstimate.rawValue) minutes."
            } else {
                update = "Your GunnAire technician is on the way for the scheduled service visit."
            }
        case .onSite:
            guard arrivalEstimate == nil else { return nil }
            update = "Your GunnAire technician has arrived for the scheduled service visit."
        case .working:
            guard arrivalEstimate == nil else { return nil }
            update = "Your GunnAire technician is working on the scheduled service visit."
        case .completed, .cancelled:
            return nil
        }
        return (
            to: email,
            subject: "GunnAire appointment update — \(appointment)",
            body: """
Hello \(call.customer.name),

\(update)

Appointment: \(appointment)\(location)
Service: \(call.type.displayName)

If you need to make a change, please contact GunnAire.

Thank you,
GunnAire
"""
        )
    }

    private var serviceTextDraft: CustomerServiceTextDraft? {
        CustomerServiceTextPolicy.draft(for: call)
    }

    private var appointmentUpdateActionTitle: String {
        switch call.technicianJobPresence {
        case .scheduled: "Draft Appointment Confirmation"
        case .enRoute: "Draft On-My-Way Update"
        case .onSite: "Draft Arrival Update"
        case .working: "Draft Work-in-Progress Update"
        case .completed, .cancelled: "Draft Appointment Update"
        }
    }

    private var appointmentUpdateWorkflow: GunnAireMailWorkflow {
        switch call.technicianJobPresence {
        case .scheduled: .appointmentConfirmation
        case .enRoute: .technicianEnRoute
        case .onSite: .technicianArrival
        case .working: .workInProgress
        case .completed, .cancelled: .general
        }
    }

    private var documentationActionLabel: String {
        let hasDocumentation = call.linkedEstimateID != nil || call.linkedInvoiceID != nil || call.documentationStartedAt != nil
        switch call.type {
        case .estimate:
            return hasDocumentation ? "Continue Estimate" : "Start Estimate"
        case .install, .replacement, .maintenance, .repair, .service, .meeting, .reminder, .siteVisit, .other:
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
            GunnAireAppIntentRouter.storeMailDraftRoute(
                to: draft.to,
                subject: draft.subject,
                body: draft.body,
                customerID: call.customer.id,
                serviceCallID: call.id,
                invoiceID: linkedInvoice.id,
                workflow: .paymentReminder
            )
        } else {
            openURL(fallbackURL)
        }
    }

    private func openAppointmentUpdate() {
        guard let draft = appointmentUpdateDraft else { return }
        openAppointmentUpdate(draft, workflow: appointmentUpdateWorkflow)
    }

    private func openAppointmentUpdate(
        _ draft: (to: String, subject: String, body: String),
        workflow: GunnAireMailWorkflow
    ) {
        if googleAuth.isAuthenticated {
            GunnAireAppIntentRouter.storeMailDraftRoute(
                to: draft.to,
                subject: draft.subject,
                body: draft.body,
                customerID: call.customer.id,
                serviceCallID: call.id,
                workflow: workflow
            )
        } else if let emailURL = mailtoURL(for: draft) {
            openURL(emailURL)
        }
    }

    private func mailtoURL(
        for draft: (to: String, subject: String, body: String)
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.to
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.body)
        ]
        return components.url
    }

    private func openServiceText() {
        guard let draft = serviceTextDraft,
              CustomerServiceTextPolicy.contextIsValid(draft, for: call) else {
            customerTextStatus = "The service-text draft is no longer valid. Check the phone number and text consent."
            return
        }
        guard CustomerServiceTextCapability.canSendText else {
            customerTextStatus = "Apple Messages is not available for texting on this device."
            return
        }
        customerTextStatus = nil
        activeServiceTextDraft = draft
    }

    private func commitEnRouteHandoff(_ submission: EnRouteHandoffSubmission) {
        showingEnRouteHandoff = false
        guard canUpdateCurrentJob,
              EnRouteHandoffPolicy.canMarkEnRoute(call),
              activeOperationalAlerts.contains(where: \CustomerOperationalAlert.blocksNewScheduling) == false else {
            jobActionStatus = "This job changed or your access no longer permits an En Route update. Refresh the job and try again."
            return
        }

        let markedAt = Date()
        call.markTechnicianEnRoute(at: markedAt)
        ServiceCallActivity.record(
            for: call,
            action: "Technician en route",
            detail: EnRouteHandoffPolicy.activityDetail(
                estimate: submission.arrivalEstimate,
                markedAt: markedAt
            ),
            actorEmail: currentActivityActor,
            occurredAt: markedAt,
            in: modelContext
        )

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            jobActionStatus = "The En Route update could not be saved. No customer draft was opened."
            return
        }

        jobActionStatus = "En Route recorded with an approximate \(submission.arrivalEstimate.rawValue)-minute arrival estimate."

        guard submission.customerUpdateChannel != .none else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            switch submission.customerUpdateChannel {
            case .none:
                break
            case .text:
                guard canDraftEnRouteText,
                      let draft = CustomerServiceTextPolicy.draft(
                        for: call,
                        approximateArrivalMinutes: submission.arrivalEstimate.rawValue
                      ),
                      CustomerServiceTextPolicy.contextIsValid(draft, for: call) else {
                    customerTextStatus = "En Route was saved, but the text draft is unavailable. Check Messages, the phone number, and text consent."
                    return
                }
                customerTextStatus = nil
                activeServiceTextDraft = draft
            case .email:
                guard canDraftEnRouteEmail,
                      let draft = makeAppointmentUpdateDraft(
                        approximateArrivalMinutes: submission.arrivalEstimate.rawValue
                      ) else {
                    jobActionStatus = "En Route was saved, but the email draft is unavailable. Check the customer email and transactional consent."
                    return
                }
                openAppointmentUpdate(draft, workflow: .technicianEnRoute)
            }
        }
    }

    private func handleServiceTextResult(_ outcome: CustomerServiceTextOutcome, draft: CustomerServiceTextDraft) {
        activeServiceTextDraft = nil
        switch outcome {
        case .cancelled:
            customerTextStatus = "Text draft cancelled. Nothing was recorded as sent."
        case .failed:
            recordServiceTextAttempt(
                draft,
                deliveryStatus: "failed",
                providerStatusDetail: "Apple Messages composer reported a send failure."
            )
            customerTextStatus = "Apple Messages could not send the text. The failed attempt was recorded."
        case .sent(let recipients):
            let contextIsValid = CustomerServiceTextPolicy.contextIsValid(draft, for: call)
            let actualRecipients = recipients.compactMap(CustomerServiceTextPolicy.normalizedRecipient)
            let recipientIsValid = actualRecipients == [draft.recipient]
            let workflowCanApply = contextIsValid && recipientIsValid
            let recipientsToAudit = actualRecipients.isEmpty ? [draft.recipient] : actualRecipients
            let detail = workflowCanApply
                ? "Apple Messages composer reported sent."
                : "Apple Messages composer reported sent after the recipient, job, or consent context changed; no workflow effect was applied."
            for (index, recipient) in recipientsToAudit.enumerated() {
                recordServiceTextAttempt(
                    draft,
                    recipient: recipient,
                    deliveryStatus: "sent",
                    providerStatusDetail: detail,
                    applyWorkflowEffect: workflowCanApply && index == 0
                )
            }
            customerTextStatus = workflowCanApply
                ? "Apple Messages reported the text sent. The service history was updated."
                : "Apple Messages reported the text sent. It was audited, but the changed recipient, job, or consent state was not updated."
        }
    }

    private func recordServiceTextAttempt(
        _ draft: CustomerServiceTextDraft,
        recipient: String? = nil,
        deliveryStatus: String,
        providerStatusDetail: String,
        applyWorkflowEffect: Bool = false
    ) {
        let now = Date()
        let communication = CustomerCommunication(
            customer: call.customer,
            serviceCallID: call.id,
            channel: "text",
            recipient: recipient ?? draft.recipient,
            subject: draft.auditSubject,
            deliveryStatus: deliveryStatus,
            workflow: draft.workflow,
            templateVersion: draft.templateVersion,
            actorEmail: currentActivityActor,
            consentSnapshot: draft.consentSnapshot,
            providerStatusDetail: providerStatusDetail,
            deliveredAt: deliveryStatus == "sent" ? now : nil,
            createdAt: now
        )
        modelContext.insert(communication)
        if applyWorkflowEffect {
            CustomerCommunicationWorkflow.applyConfirmedSend(
                workflow: draft.workflow,
                customerID: draft.customerID,
                serviceCallID: draft.serviceCallID,
                invoiceID: nil,
                estimateID: nil,
                estimates: estimates,
                invoices: invoices,
                serviceCalls: serviceCalls,
                now: now,
                actorEmail: currentActivityActor,
                deliveryEvidenceText: "Apple Messages composer reported sent",
                in: modelContext
            )
        }
        try? modelContext.save()
        guard GunnAireBackendService.isConfigured else { return }
        Task {
            do {
                let remote = try await GunnAireBackendService.uploadCustomerCommunication(communication)
                communication.markSharedCompanySynced(id: remote.id)
            } catch {
                communication.markSharedCompanySyncFailed(error.localizedDescription)
            }
            try? modelContext.save()
        }
    }

    private func openEstimateFollowUpEmail(fallbackURL: URL) {
        if let linkedEstimate, googleAuth.isAuthenticated, let draft = estimateFollowUpEmailDraft(for: linkedEstimate) {
            GunnAireAppIntentRouter.storeMailDraftRoute(
                to: draft.to,
                subject: draft.subject,
                body: draft.body,
                customerID: call.customer.id,
                serviceCallID: call.id,
                estimateID: linkedEstimate.id,
                workflow: .estimateFollowUp
            )
        } else {
            openURL(fallbackURL)
        }
    }

    private var jobWorkflowTitle: String {
        switch call.type {
        case .service:
            return "Service Workflow"
        case .repair:
            return "Repair Workflow"
        case .estimate:
            return "Estimate Workflow"
        case .replacement:
            return "Replacement Workflow"
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
        let email = AppIdentity.currentEmail
        return AppAccess.canViewBillingFinancialDetails(email: email, users: users)
    }

    private var canScheduleApprovedWork: Bool {
        AppAccess.canManageDispatch(email: currentActivityActor, users: users)
    }

    private var canUpdateCurrentJob: Bool {
        AppAccess.canUpdateJobProgress(email: currentActivityActor, users: users) &&
        AppAccess.canAccessServiceCall(
            call,
            email: currentActivityActor,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
    }

    private var canSubmitFieldExpenseForCurrentJob: Bool {
        AppAccess.canSubmitFieldExpenses(email: currentActivityActor, users: users) &&
        AppAccess.canAccessServiceCall(
            call,
            email: currentActivityActor,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
    }

    private var visibleCurrentJobExpenseClaims: [FieldExpenseClaim] {
        fieldExpenseClaims.filter { claim in
            claim.serviceCallID == call.id &&
                AppAccess.canAccessFieldExpenseClaim(claim, email: currentActivityActor, users: users)
        }
    }

    private var canDraftEnRouteText: Bool {
        call.customer.allowsServiceText &&
        CustomerServiceTextPolicy.normalizedRecipient(call.customer.phone) != nil &&
        CustomerServiceTextCapability.canSendText
    }

    private var canDraftEnRouteEmail: Bool {
        call.customer.allowsTransactionalEmail &&
        !(call.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var defaultEnRouteUpdateChannel: EnRouteCustomerUpdateChannel {
        if canDraftEnRouteText { return .text }
        if canDraftEnRouteEmail { return .email }
        return .none
    }

    private func canOpenRelatedCall(_ relatedCall: ServiceCall) -> Bool {
        let email = AppIdentity.currentEmail
        return AppAccess.canAccessServiceCall(
            relatedCall,
            email: email,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
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

    private var operationalCompletionBlockers: [String] {
        ServiceWorkLogPolicy.operationalCompletionBlockers(
            for: call,
            requireCompletionChecklist: requireJobCompletionChecklist,
            fieldFormTemplates: fieldFormTemplates,
            fieldFormResponses: fieldFormResponses,
            activities: serviceCallActivities,
            requireWorkPerformedLog: requireWorkPerformedLogForCloseout
        )
    }

    private var operationalCompletionStatus: String? {
        guard !operationalCompletionBlockers.isEmpty else { return nil }
        return "Before completion: \(operationalCompletionBlockers.joined(separator: ", "))."
    }

    private var hasJobStatusAction: Bool {
        canUpdateCurrentJob && (
            call.status == .scheduled ||
            call.status == .inProgress ||
            call.status == .completed ||
            (call.technicianEnRouteAt != nil && call.technicianArrivedAt == nil && !call.arrivalConfirmed)
        )
    }

    private var activeServiceRestriction: CustomerOperationalAlert? {
        activeOperationalAlerts.first(where: \CustomerOperationalAlert.blocksNewScheduling)
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

    private var linkedMaintenanceAgreement: RecurringMaintenanceContract? {
        guard let maintenanceAgreementID = call.maintenanceAgreementID else { return nil }
        return call.customer.recurringContracts.first { $0.id == maintenanceAgreementID }
    }

    private var activeServiceAgreement: RecurringMaintenanceContract? {
        linkedMaintenanceAgreement ?? call.customer.recurringContracts
            .filter(\.canScheduleVisit)
            .sorted(by: { $0.nextDate < $1.nextDate })
            .first
    }

    private var pendingServiceAgreement: RecurringMaintenanceContract? {
        call.customer.recurringContracts
            .filter { [.draft, .pendingApproval, .declined].contains($0.lifecycleStatus) }
            .sorted {
                ($0.lifecycle?.createdAt ?? .distantPast) > ($1.lifecycle?.createdAt ?? .distantPast)
            }
            .first
    }

    private var customerEquipmentProfiles: [CustomerEquipment] {
        equipmentProfiles.filter { $0.customer?.id == call.customer.id }
    }

    private var linkedEquipmentProfile: CustomerEquipment? {
        if let equipmentID = call.customerEquipmentID,
           let linked = customerEquipmentProfiles.first(where: { $0.id == equipmentID }) {
            return linked
        }
        return customerEquipmentProfiles.first { $0.matches(call) }
    }

    private var equipmentServicePlanningSnapshot: EquipmentServicePlanningSnapshot? {
        linkedEquipmentProfile?.servicePlanningSnapshot(in: serviceCalls)
    }

    private var canOfferMaintenanceAgreement: Bool {
        AppAccess.canOfferMaintenanceAgreements(email: currentActivityActor, users: users) &&
        AppAccess.canAccessServiceCall(
            call,
            email: currentActivityActor,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
    }

    private var canRequestWarrantyClaim: Bool {
        AppAccess.canPerformWarrantyClaimAction(.request, email: currentActivityActor, users: users) &&
        AppAccess.canAccessServiceCall(
            call,
            email: currentActivityActor,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
    }

    private var recentCustomerCalls: [ServiceCall] {
        guard let customerID = call.customer?.id else { return [] }
        return serviceCalls
            .filter { $0.customer?.id == customerID }
            .sorted(by: { $0.scheduledDate > $1.scheduledDate })
            .prefix(4)
            .map { $0 }
    }

    private var customerLifetimeInvoiceTotal: Double {
        guard let customerID = call.customer?.id else { return 0 }
        return invoices
            .filter { $0.customer?.id == customerID }
            .reduce(0) { $0 + $1.amount }
    }

    private func scheduleFollowUpVisit() {
        if let blocker = CustomerOperationalAlertPolicy.schedulingBlocker(
            customerID: call.customer.id,
            serviceLocationID: call.serviceLocationID,
            in: operationalAlerts
        ) {
            jobActionStatus = CustomerOperationalAlertPolicy.bookingRestrictionMessage(for: blocker)
            return
        }
        let followUpCall = call.makeFollowUpVisit()
        modelContext.insert(followUpCall)
        let sourceID = String(call.id.uuidString.prefix(8)).uppercased()
        ServiceCallActivity.record(
            for: call,
            action: call.isCorrectiveWorkClassification ? "Corrective visit scheduled" : "Follow-up visit scheduled",
            detail: "Linked follow-up for \(followUpCall.scheduledDate.formatted(date: .abbreviated, time: .shortened)).",
            actorEmail: currentActivityActor,
            in: modelContext
        )
        ServiceCallActivity.record(
            for: followUpCall,
            action: "Created from prior job",
            detail: "Linked to source job \(sourceID).",
            actorEmail: currentActivityActor,
            in: modelContext
        )
    }

    private func createMaintenanceAgreementFromJob(_ submission: MaintenanceAgreementOfferSubmission) {
        guard canOfferMaintenanceAgreement else {
            maintenanceAgreementMessage = "Agreement access changed. Reopen an assigned job and try again."
            return
        }

        let agreement = RecurringMaintenanceContract(
            customer: call.customer,
            planName: submission.planName,
            schedulePattern: submission.schedulePattern,
            nextDate: submission.nextDate,
            active: false,
            termEndsOn: submission.termEndsOn,
            pricePerVisit: submission.pricePerVisit,
            includedVisitsPerTerm: submission.includedVisitsPerTerm,
            coveredEquipmentIDs: submission.coveredEquipmentIDs
        )
        agreement.configureDraft(
            agreementPrice: submission.agreementPrice,
            billingInterval: submission.billingInterval,
            billingCatalogItemID: submission.billingCatalogItemID,
            billingAnchorDate: submission.billingAnchorDate,
            memberDiscountPercent: submission.memberDiscountPercent,
            autoRenews: submission.autoRenews,
            termsSummary: submission.termsSummary,
            createdByEmail: currentActivityActor,
            sourceServiceCallID: call.id
        )

        do {
            if let approval = submission.approval {
                agreement.markPendingApproval(
                    offeredByEmail: currentActivityActor,
                    sourceServiceCallID: call.id
                )
                try agreement.recordCustomerApproval(
                    customerName: approval.customerName,
                    method: approval.method,
                    reference: approval.reference,
                    signatureImageBase64: approval.signatureImageBase64,
                    recordedByEmail: currentActivityActor
                )
            }
            modelContext.insert(agreement)
            ServiceCallActivity.record(
                for: call,
                action: submission.approval == nil ? "Service agreement drafted" : "Service agreement activated",
                detail: "\(agreement.displayName) • agreement \(String(agreement.id.uuidString.prefix(8)).uppercased())",
                actorEmail: currentActivityActor,
                in: modelContext
            )
            try modelContext.save()
            generateMaintenanceAgreementDocumentFromJob(agreement)
            maintenanceAgreementMessage = submission.approval == nil
                ? "Saved \(agreement.displayName) as a draft for office/customer follow-up."
                : "Activated \(agreement.displayName) with customer approval evidence."
        } catch {
            maintenanceAgreementMessage = "Service agreement save failed: \(error.localizedDescription)"
        }
    }

    private func approveMaintenanceAgreementFromJob(
        _ agreement: RecurringMaintenanceContract,
        approval: MaintenanceAgreementApprovalSubmission
    ) {
        guard canOfferMaintenanceAgreement,
              agreement.customer.id == call.customer.id else {
            maintenanceAgreementMessage = "Agreement access changed. Reopen an assigned job and try again."
            return
        }
        let agreementLifecycleJSON = agreement.lifecycleJSON
        let agreementActive = agreement.active
        var source: RecurringMaintenanceContract?
        var sourceLifecycleJSON: String?
        var sourceActive: Bool?
        var activity: ServiceCallActivity?
        do {
            if let sourceID = agreement.lifecycle?.renewalOfContractID {
                guard let original = call.customer.recurringContracts.first(where: { $0.id == sourceID }) else {
                    throw MaintenanceAgreementLifecycleError.renewalSourceUnavailable
                }
                try original.validateRenewalCompletion(by: agreement.id)
                source = original
                sourceLifecycleJSON = original.lifecycleJSON
                sourceActive = original.active
            }
            if agreement.lifecycleStatus != .pendingApproval {
                agreement.markPendingApproval(
                    offeredByEmail: currentActivityActor,
                    sourceServiceCallID: call.id
                )
            }
            try agreement.recordCustomerApproval(
                customerName: approval.customerName,
                method: approval.method,
                reference: approval.reference,
                signatureImageBase64: approval.signatureImageBase64,
                recordedByEmail: currentActivityActor
            )
            try source?.markRenewed(by: agreement.id, byEmail: currentActivityActor)
            activity = ServiceCallActivity.record(
                for: call,
                action: source == nil ? "Service agreement activated" : "Service agreement renewed",
                detail: "Customer approval recorded for \(agreement.displayName) • agreement \(String(agreement.id.uuidString.prefix(8)).uppercased())",
                actorEmail: currentActivityActor,
                in: modelContext
            )
            try modelContext.save()
            generateMaintenanceAgreementDocumentFromJob(agreement)
            if let source {
                generateMaintenanceAgreementDocumentFromJob(source)
                maintenanceAgreementMessage = "Renewed \(source.displayName) with customer approval evidence."
            } else {
                maintenanceAgreementMessage = "Activated \(agreement.displayName) with customer approval evidence."
            }
        } catch {
            agreement.lifecycleJSON = agreementLifecycleJSON
            agreement.active = agreementActive
            if let source {
                source.lifecycleJSON = sourceLifecycleJSON
                source.active = sourceActive ?? source.active
            }
            if let activity {
                modelContext.delete(activity)
            }
            maintenanceAgreementMessage = "Service agreement approval failed: \(error.localizedDescription)"
        }
    }

    private func generateMaintenanceAgreementDocumentFromJob(_ agreement: RecurringMaintenanceContract) {
        do {
            let url = try CustomerDocumentExporter.exportMaintenanceAgreement(
                agreement,
                equipmentProfiles: customerEquipmentProfiles
            )
            let data = try Data(contentsOf: url)
            let attachment = ServiceDocumentAttachment(
                customer: call.customer,
                serviceCallID: call.id,
                maintenanceContractID: agreement.id,
                kind: .maintenanceAgreement,
                displayName: url.lastPathComponent,
                caption: "Generated \(agreement.lifecycleStatusDisplayName.lowercased()) maintenance agreement PDF",
                localFilePath: url.path,
                contentType: "application/pdf",
                fileSizeBytes: data.count,
                sharedCompanySyncStatus: GunnAireBackendService.isConfigured ? "needs_attention" : nil,
                sharedCompanySyncDetail: GunnAireBackendService.isConfigured
                    ? "Waiting for shared company storage upload."
                    : "Shared company storage is not configured for this build."
            )
            modelContext.insert(attachment)
            agreement.linkGeneratedDocument(attachment.id)
            try modelContext.save()
            syncMaintenanceAgreementDocumentFromJob(attachment, data: data)
        } catch {
            maintenanceAgreementMessage = "Agreement saved, but its PDF could not be generated: \(error.localizedDescription)"
        }
    }

    private func syncMaintenanceAgreementDocumentFromJob(
        _ attachment: ServiceDocumentAttachment,
        data: Data
    ) {
        guard GunnAireBackendService.isConfigured else { return }
        Task {
            do {
                let response = try await GunnAireBackendService.uploadDocument(
                    data: data,
                    filename: attachment.displayName,
                    contentType: attachment.contentType,
                    kind: attachment.kindRaw,
                    serviceCallID: call.id,
                    maintenanceContractID: attachment.maintenanceContractID,
                    customerEquipmentID: nil,
                    customerName: call.customer.name
                )
                attachment.markSharedCompanyStored(id: response.id)
                try? modelContext.save()
            } catch {
                attachment.markSharedCompanyUploadFailed(error.localizedDescription)
                try? modelContext.save()
                maintenanceAgreementMessage = "Agreement saved locally. Company storage upload failed: \(error.localizedDescription)"
            }
        }
    }

    private func scheduledApprovedWork(for estimate: Estimate) -> ServiceCall? {
        ApprovedEstimateScheduling.existingWorkOrder(for: estimate, in: serviceCalls)
    }

    private func presentApprovedWorkSchedule(for estimate: Estimate) {
        guard canScheduleApprovedWork else { return }
        guard EstimateProposalPolicy.selectionIssue(for: estimate, in: estimates) == nil else { return }
        if let existing = scheduledApprovedWork(for: estimate) {
            GunnAireAppIntentRouter.storeScheduleCallRoute(existing.id)
            return
        }
        guard estimate.hasRecordedCustomerApproval else {
            selectedEstimateForApproval = estimate
            return
        }
        if let blocker = CustomerOperationalAlertPolicy.schedulingBlocker(
            customerID: estimate.customer.id,
            serviceLocationID: estimate.serviceLocationID ?? call.serviceLocationID,
            in: operationalAlerts
        ) {
            jobActionStatus = CustomerOperationalAlertPolicy.bookingRestrictionMessage(for: blocker)
            return
        }
        selectedEstimateForScheduling = estimate
    }

    @discardableResult
    private func createApprovedWorkOrder(
        for estimate: Estimate,
        scheduledDate: Date,
        duration: TimeInterval,
        workType: ServiceCallType
    ) -> Bool {
        guard canScheduleApprovedWork else { return false }
        guard EstimateProposalPolicy.selectionIssue(for: estimate, in: estimates) == nil else { return false }
        if let blocker = CustomerOperationalAlertPolicy.schedulingBlocker(
            customerID: estimate.customer.id,
            serviceLocationID: estimate.serviceLocationID ?? call.serviceLocationID,
            in: operationalAlerts
        ) {
            jobActionStatus = CustomerOperationalAlertPolicy.bookingRestrictionMessage(for: blocker)
            return false
        }
        if let existing = scheduledApprovedWork(for: estimate) {
            GunnAireAppIntentRouter.storeScheduleCallRoute(existing.id)
            return true
        }
        do {
            let approvedWorkCall = try ApprovedEstimateScheduling.makeWorkOrder(
                for: estimate,
                sourceCall: call,
                scheduledDate: scheduledDate,
                duration: duration,
                workType: workType
            )
            modelContext.insert(approvedWorkCall)
            estimate.scheduledServiceCallID = approvedWorkCall.id
            call.followUpRequired = false
            call.followUpAction = nil
            call.followUpDueDate = nil
            ServiceCallActivity.record(
                for: approvedWorkCall,
                action: "Approved estimate scheduled",
                detail: "Created unassigned \(workType.displayName.lowercased()) work from approved estimate \(String(estimate.id.uuidString.prefix(8)).uppercased()) for \(estimate.amount.formatted(.currency(code: "USD"))).",
                actorEmail: currentActivityActor,
                in: modelContext
            )
            ServiceCallActivity.record(
                for: call,
                action: "Approved work scheduled",
                detail: "Created work order \(String(approvedWorkCall.id.uuidString.prefix(8)).uppercased()) for \(scheduledDate.formatted(date: .abbreviated, time: .shortened)).",
                actorEmail: currentActivityActor,
                in: modelContext
            )
            try modelContext.save()
            selectedEstimateForScheduling = nil
            GunnAireAppIntentRouter.storeScheduleCallRoute(approvedWorkCall.id)
            return true
        } catch {
            modelContext.rollback()
            return false
        }
    }

    @discardableResult
    private func saveWorkPerformedLog(_ content: String) -> Bool {
        guard canUpdateCurrentJob else {
            jobActionStatus = "This account can review the work log but cannot add an entry to this job."
            return false
        }
        var insertedActivity: ServiceCallActivity?
        do {
            insertedActivity = try ServiceWorkLogPolicy.recordWorkPerformed(
                content,
                for: call,
                actorEmail: currentActivityActor,
                in: modelContext
            )
            try modelContext.save()
            jobActionStatus = "Work performed was saved to the job timeline."
            return true
        } catch {
            if let insertedActivity { modelContext.delete(insertedActivity) }
            jobActionStatus = "The work log was not saved: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func saveCustomerWorkSummary(_ content: String) -> Bool {
        guard canUpdateCurrentJob else {
            jobActionStatus = "This account can review the customer summary but cannot revise it for this job."
            return false
        }
        let previousSummary = call.serviceReportSummary
        var insertedActivity: ServiceCallActivity?
        do {
            insertedActivity = try ServiceWorkLogPolicy.recordCustomerSummary(
                content,
                for: call,
                actorEmail: currentActivityActor,
                in: modelContext
            )
            try modelContext.save()
            jobActionStatus = "The customer-facing work summary and its revision history were saved."
            return true
        } catch {
            call.serviceReportSummary = previousSummary
            if let insertedActivity { modelContext.delete(insertedActivity) }
            jobActionStatus = "The work summary was not saved: \(error.localizedDescription)"
            return false
        }
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
                        } else {
                            Text("Technician: Unassigned")
                        }
                        if !crewTechnicianNames.isEmpty {
                            Text("Crew: \(crewTechnicianNames.joined(separator: ", "))")
                        }
                        Text("Scheduled work: \(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))")
                        if let promisedArrivalWindowSummary = call.promisedArrivalWindowSummary {
                            Text("Customer arrival window: \(promisedArrivalWindowSummary)")
                                .foregroundColor(.secondary)
                        }
                        Text("Duration: \(Int(call.duration / 60)) minutes")
                        Text("Status: \(call.status.rawValue.capitalized)")
                        Label(call.technicianJobPresence.displayName, systemImage: presenceSystemImage)
                            .foregroundColor(call.technicianJobPresence == .enRoute ? .orange : .secondary)
                    }
                    .foregroundColor(.primary)

                    GroupBox("Job Workspace") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Workspace", selection: $selectedWorkspace) {
                                ForEach(ServiceCallDetailWorkspace.available(canViewFinancials: canViewFinancials)) { workspace in
                                    Text(workspace.label).tag(workspace)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("ServiceCallWorkspacePicker")

                            Label(selectedWorkspace.guidance, systemImage: selectedWorkspace.systemImage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if hasJobStatusAction {
                        jobActionsSection
                    }

                    if selectedWorkspace == .overview {
                        CustomerOperationalAlertInlineSummary(
                            alerts: activeOperationalAlerts,
                            accessibilityIdentifier: "ServiceCallOperationalAlerts"
                        )
                        Group {
                        if call.status == .cancelled {
                            if let cancelledAt = call.cancelledAt {
                                Text("Cancelled: \(cancelledAt.formatted(date: .abbreviated, time: .shortened))")
                                    .foregroundColor(.secondary)
                            }
                            if let cancellationReason = call.cancellationReason, !cancellationReason.isEmpty {
                                Text("Cancellation reason: \(cancellationReason)")
                                    .foregroundColor(.secondary)
                            }
                        }
                        if call.visitDisposition != .standard {
                            Text("Visit result: \(call.visitDisposition.displayName)")
                                .foregroundColor(call.visitDisposition == .noAccess ? .orange : .secondary)
                            if let visitDispositionNotes = call.visitDispositionNotes, !visitDispositionNotes.isEmpty {
                                Text("Outcome: \(visitDispositionNotes)")
                            }
                        }
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
                        if let serviceLocation {
                            GroupBox("Service Location") {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(serviceLocation.displayName)
                                        .font(.headline)
                                    if let contact = serviceLocation.contactSummary {
                                        Label(contact, systemImage: "person.crop.circle")
                                    }
                                    if let accessNotes = serviceLocation.accessNotes,
                                       !accessNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Label(accessNotes, systemImage: "key")
                                            .foregroundStyle(.orange)
                                    }
                                    Text("The address above is the job snapshot; these contact and access details come from the active property record.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityIdentifier("ServiceCallServiceLocation")
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
                        if appointmentUpdateDraft != nil || serviceTextDraft != nil {
                            HStack(spacing: 10) {
                                if appointmentUpdateDraft != nil {
                                    Button(appointmentUpdateActionTitle) {
                                        openAppointmentUpdate()
                                    }
                                    .buttonStyle(.bordered)
                                }
                                if let serviceTextDraft {
                                    Button(serviceTextDraft.actionTitle) {
                                        openServiceText()
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(!CustomerServiceTextCapability.canSendText)
                                }
                            }
                            Text("Operational messages open as staff-reviewed drafts and are recorded only after the provider reports sent.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if serviceTextDraft != nil && !CustomerServiceTextCapability.canSendText {
                                Text("Apple Messages texting is unavailable on this device.")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                            if let customerTextStatus {
                                Text(customerTextStatus)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .accessibilityIdentifier("CustomerServiceTextStatus")
                            }
                        }
                        if reviewRequestDraft != nil {
                            Button("Draft Review Request") {
                                openReviewRequest()
                            }
                            .buttonStyle(.bordered)
                            Text("Optional marketing follow-up. It opens as a draft and is recorded only after staff sends it.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if hasSentReviewRequest {
                            Label("Review request sent", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .foregroundColor(.primary)
                    }

                    if selectedWorkspace == .overview,
                       let linkedMaintenanceAgreement {
                        GroupBox("Agreement Visit") {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(linkedMaintenanceAgreement.displayName)
                                    .font(.headline)
                                if let dueDate = call.maintenanceAgreementDueDate {
                                    Text("Agreement obligation: \(dueDate.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text("The agreement advances after this visit is completed, not when it is merely scheduled.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("LinkedMaintenanceAgreementVisit")
                    }

                    if selectedWorkspace == .overview,
                       call.isCorrectiveVisit || call.scheduledFollowUpServiceCallID != nil {
                        GroupBox(call.isCorrectiveWorkClassification ? "Corrective Work" : "Related Visit") {
                            VStack(alignment: .leading, spacing: 8) {
                                if call.isCorrectiveWorkClassification {
                                    Label(call.visitDisposition.displayName, systemImage: "arrow.trianglehead.clockwise")
                                        .font(.headline)
                                    if let reason = call.correctiveWorkReason {
                                        Text("Reason: \(reason.displayName)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                if let originatingCall, canOpenRelatedCall(originatingCall) {
                                    NavigationLink {
                                        ServiceCallDetailView(call: originatingCall)
                                    } label: {
                                        Label(
                                            "Open original job from \(originatingCall.scheduledDate.formatted(date: .abbreviated, time: .omitted))",
                                            systemImage: "arrow.up.left.square"
                                        )
                                    }
                                    .accessibilityIdentifier("OpenOriginatingServiceCall")
                                } else if call.originatingServiceCallID != nil {
                                    Text(originatingCall == nil
                                         ? "The original job is still syncing to this device."
                                         : "The original job is linked but outside this account's job access.")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }

                                if let scheduledFollowUpCall, canOpenRelatedCall(scheduledFollowUpCall) {
                                    NavigationLink {
                                        ServiceCallDetailView(call: scheduledFollowUpCall)
                                    } label: {
                                        Label(
                                            "Open scheduled follow-up on \(scheduledFollowUpCall.scheduledDate.formatted(date: .abbreviated, time: .omitted))",
                                            systemImage: "arrow.down.right.square"
                                        )
                                    }
                                    .accessibilityIdentifier("OpenScheduledFollowUpServiceCall")
                                } else if call.scheduledFollowUpServiceCallID != nil {
                                    Text(scheduledFollowUpCall == nil
                                         ? "The scheduled follow-up is still syncing to this device."
                                         : "The scheduled follow-up is linked but outside this account's job access.")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }

                    if selectedWorkspace == .history {
                    GroupBox("Job Activity") {
                        if callActivity.isEmpty {
                            Text("New operational changes will appear here for the office and field team.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(callActivity.prefix(12)) { activity in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(activity.action)
                                                .font(.subheadline.weight(.semibold))
                                            Spacer()
                                            Text(activity.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Text(activity.detail)
                                            .font(.caption)
                                        if let actorName = ServiceWorkLogPolicy.actorDisplayName(activity.actorEmail) {
                                            Text(actorName)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                    }

                    if selectedWorkspace == .work {
                    GroupBox("Field Forms") {
                        VStack(alignment: .leading, spacing: 10) {
                            if fieldFormCloseoutReadiness.totalCount > 0 {
                                Label(
                                    fieldFormCloseoutReadiness.statusLabel,
                                    systemImage: fieldFormCloseoutReadiness.isReady
                                        ? "checkmark.seal.fill"
                                        : "exclamationmark.triangle.fill"
                                )
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(fieldFormCloseoutReadiness.isReady ? Color.green : Color.orange)
                                .accessibilityIdentifier("ServiceCallFieldFormsReadiness")
                            }
                            Text("Forms marked Required must be completed before closeout. Every saved response creates a read-only PDF in this job’s Files.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if availableFieldFormTemplates.isEmpty {
                                Text("No active forms apply to this job type. An administrator can configure them in Settings.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(availableFieldFormTemplates) { template in
                                    let isCompleted = FieldFormCloseoutPolicy.responseCompletes(
                                        template,
                                        serviceCallID: call.id,
                                        responses: fieldFormResponses
                                    )
                                    NavigationLink {
                                        FieldFormResponseEditor(template: template, serviceCall: call, actorEmail: currentActivityActor)
                                    } label: {
                                        HStack {
                                            Label(
                                                template.title,
                                                systemImage: isCompleted ? "checkmark.circle.fill" : "checklist"
                                            )
                                            Spacer()
                                            if template.requiresCompletionForCloseout {
                                                Text(isCompleted ? "Complete" : "Required")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(isCompleted ? Color.green : Color.orange)
                                            }
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            if completedFieldFormResponses.isEmpty {
                                Text("No reusable field forms completed for this job yet.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Divider()
                                Text("Completed")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(completedFieldFormResponses.prefix(3)) { response in
                                    NavigationLink {
                                        FieldFormResponseDetailView(
                                            response: response,
                                            template: fieldFormTemplates.first { $0.id == response.templateID },
                                            serviceCall: call,
                                            attachment: fieldFormAttachment(for: response)
                                        )
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(response.templateTitle)
                                                .font(.caption.weight(.semibold))
                                            Text(response.completedAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                if completedFieldFormResponses.count > 3 {
                                    NavigationLink {
                                        CompletedFieldFormsView(
                                            responses: completedFieldFormResponses,
                                            templates: fieldFormTemplates,
                                            serviceCall: call,
                                            attachments: fieldFormAttachments
                                        )
                                    } label: {
                                        Label("View All \(completedFieldFormResponses.count) Forms", systemImage: "list.bullet.rectangle")
                                            .font(.caption.weight(.semibold))
                                    }
                                }
                            }
                        }
                    }

                    GroupBox("Work Performed") {
                        VStack(alignment: .leading, spacing: 10) {
                            if workPerformedEntries.isEmpty {
                                Label(
                                    requireWorkPerformedLogForCloseout && call.requiresTechnicalServiceReportCompletion
                                        ? "A work log is required before this job can be completed."
                                        : "No work-performed entries have been added yet.",
                                    systemImage: requireWorkPerformedLogForCloseout && call.requiresTechnicalServiceReportCompletion
                                        ? "exclamationmark.triangle.fill"
                                        : "text.badge.plus"
                                )
                                .font(.caption)
                                .foregroundStyle(
                                    requireWorkPerformedLogForCloseout && call.requiresTechnicalServiceReportCompletion
                                        ? Color.orange
                                        : Color.secondary
                                )
                                .accessibilityIdentifier("WorkPerformedEmptyState")
                            } else {
                                let visibleEntries = expandedWorkLogHistory
                                    ? workPerformedEntries
                                    : Array(workPerformedEntries.prefix(3))
                                ForEach(visibleEntries) { entry in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(ServiceWorkLogPolicy.actorDisplayName(entry.actorEmail) ?? "GunnAire staff")
                                                .font(.caption.weight(.semibold))
                                            Spacer()
                                            Text(entry.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(entry.detail)
                                            .font(.caption)
                                            .textSelection(.enabled)
                                    }
                                    .padding(9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .accessibilityElement(children: .combine)
                                }
                                if workPerformedEntries.count > 3 {
                                    Button(expandedWorkLogHistory ? "Show Recent Entries" : "Show All \(workPerformedEntries.count) Entries") {
                                        withAnimation { expandedWorkLogHistory.toggle() }
                                    }
                                    .font(.caption.weight(.semibold))
                                    .accessibilityIdentifier("ToggleFullWorkLog")
                                }
                            }

                            Divider()

                            if let currentCustomerWorkSummary {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("Customer work summary ready", systemImage: "doc.text.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                    Text(currentCustomerWorkSummary)
                                        .font(.caption)
                                        .lineLimit(4)
                                    if !customerWorkSummaryRevisions.isEmpty {
                                        Text("\(customerWorkSummaryRevisions.count) retained summary revision\(customerWorkSummaryRevisions.count == 1 ? "" : "s")")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityIdentifier("CurrentCustomerWorkSummary")
                            } else {
                                Text("The customer-facing service report summary has not been prepared yet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if canUpdateCurrentJob {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 8) {
                                        Button {
                                            showingWorkPerformedLog = true
                                        } label: {
                                            Label("Add Work Log", systemImage: "plus.circle")
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .accessibilityIdentifier("AddWorkPerformedLog")

                                        Button {
                                            showingCustomerWorkSummary = true
                                        } label: {
                                            Label(
                                                currentCustomerWorkSummary == nil ? "Create Work Summary" : "Review Work Summary",
                                                systemImage: "doc.text"
                                            )
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(workPerformedEntries.isEmpty && currentCustomerWorkSummary == nil)
                                        .accessibilityIdentifier("ReviewCustomerWorkSummary")
                                    }
                                    VStack(alignment: .leading, spacing: 8) {
                                        Button {
                                            showingWorkPerformedLog = true
                                        } label: {
                                            Label("Add Work Log", systemImage: "plus.circle")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .accessibilityIdentifier("AddWorkPerformedLog")

                                        Button {
                                            showingCustomerWorkSummary = true
                                        } label: {
                                            Label(
                                                currentCustomerWorkSummary == nil ? "Create Work Summary" : "Review Work Summary",
                                                systemImage: "doc.text"
                                            )
                                            .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(workPerformedEntries.isEmpty && currentCustomerWorkSummary == nil)
                                        .accessibilityIdentifier("ReviewCustomerWorkSummary")
                                    }
                                }
                            }

                            Text("Entries are append-only and remain available offline. The reviewed summary feeds the existing service report and customer-document workflow.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("ServiceCallWorkPerformed")

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
                            let lifecycle = call.equipmentLifecycleSnapshot
                            if let lifecycleSummary = lifecycle.summary {
                                Text(lifecycleSummary)
                                    .font(.caption)
                                    .foregroundColor(
                                        lifecycle.attention == .invalidDates
                                            ? .red
                                            : lifecycle.attention == .none ? .secondary : .orange
                                    )
                                    .accessibilityIdentifier("JobEquipmentLifecycle")
                            }
                            if let planning = equipmentServicePlanningSnapshot,
                               planning.needsAttention,
                               let planningTitle = planning.title,
                               let planningSummary = planning.summary {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(planningTitle)
                                            .font(.caption.weight(.semibold))
                                        Text(planningSummary)
                                            .font(.caption2)
                                        Text("Planning cue—confirm the current diagnosis before presenting options.")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: planning.attention == .replacementEvaluation ? "arrow.triangle.2.circlepath" : "wrench.adjustable")
                                }
                                .foregroundStyle(planning.overdueFollowUpCount > 0 ? Color.red : Color.orange)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(planningTitle). \(planningSummary). Planning cue only; confirm before presenting options.")
                                .accessibilityIdentifier("JobEquipmentServicePlanning")
                            }

                            if let linkedEquipmentProfile,
                               canRequestWarrantyClaim || linkedEquipmentProfile.warrantyClaims.contains(where: { $0.originatingServiceCallID == call.id }) {
                                Button {
                                    warrantyClaimsEquipment = linkedEquipmentProfile
                                } label: {
                                    Label(
                                        linkedEquipmentProfile.warrantyClaims.contains(where: { $0.originatingServiceCallID == call.id })
                                            ? "Open Job Warranty Claim"
                                            : "Request Warranty Claim",
                                        systemImage: "checkmark.shield"
                                    )
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("JobWarrantyClaimsButton")
                            } else if canRequestWarrantyClaim,
                                      (call.visitDisposition == .warranty || call.correctiveWorkReason == .manufacturerWarranty) {
                                Text("Link this job to an installed equipment profile before requesting manufacturer warranty support.")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .accessibilityIdentifier("JobWarrantyEquipmentRequired")
                            }
                        }
                    }
                    }

                    if selectedWorkspace == .overview,
                       phoneURL != nil || emailURL != nil || mapsURL != nil {
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

                    if selectedWorkspace == .history {
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

                            if let pendingAgreement = pendingServiceAgreement {
                                VStack(alignment: .leading, spacing: 3) {
                                    Label(
                                        "\(pendingAgreement.displayName) • \(pendingAgreement.lifecycleStatusDisplayName)",
                                        systemImage: "doc.badge.clock"
                                    )
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                                    Text("This offer does not schedule recurring work until customer approval is recorded.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    if canOfferMaintenanceAgreement {
                                        Button("Record Customer Approval") {
                                            selectedMaintenanceAgreementForApproval = pendingAgreement
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(Color.brandGold)
                                        .foregroundStyle(Color.primaryBlack)
                                        .accessibilityIdentifier("JobRecordMaintenanceAgreementApprovalButton")
                                    }
                                }
                            }

                            if canOfferMaintenanceAgreement {
                                Button {
                                    showingMaintenanceAgreementOffer = true
                                } label: {
                                    Label("Offer Service Agreement", systemImage: "person.crop.rectangle.badge.plus")
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("JobOfferMaintenanceAgreementButton")
                            }

                            if let maintenanceAgreementMessage {
                                Text(maintenanceAgreementMessage)
                                    .font(.caption2)
                                    .foregroundStyle(maintenanceAgreementMessage.localizedCaseInsensitiveContains("failed") ? .orange : .secondary)
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
                    }

                    if selectedWorkspace == .work {
                    GroupBox(jobWorkflowTitle) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Workflow progress: \(call.workflowChecklistCompletedCount)/\(call.workflowChecklistTotalCount)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            switch call.type {
                            case .service, .repair:
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
                            case .replacement, .install:
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
                                    set: { arrived in
                                        if arrived {
                                            call.markTechnicianArrived()
                                        } else {
                                            call.arrivalConfirmed = false
                                            call.technicianArrivedAt = nil
                                        }
                                    }
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
                    }

                    if selectedWorkspace == .history, !relatedEquipmentCalls.isEmpty {
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

                    if selectedWorkspace == .billing, canViewFinancials {
                        GroupBox("Documentation") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(call.linkedEstimateID == nil && call.linkedInvoiceID == nil ? "No estimate or invoice linked yet." : "This job already has linked billing documentation.")
                                .foregroundColor(.secondary)
                            if let linkedEstimate {
                                Text("Estimate: \(linkedEstimate.amount, format: .currency(code: "USD")) • \(linkedEstimate.status.capitalized)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if linkedEstimate.isProposalOption {
                                    Text("Selected proposal: \(linkedEstimate.proposalOptionDisplayDetail)")
                                        .font(.caption2)
                                        .foregroundColor(linkedEstimate.proposalIsRecommended ? .green : .secondary)
                                }
                                if linkedProposalOptions.count > 1 {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("Proposal Options")
                                            .font(.caption.weight(.semibold))
                                        ForEach(linkedProposalOptions) { option in
                                            let selectionIssue = EstimateProposalPolicy.selectionIssue(for: option, in: estimates)
                                            HStack {
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(option.proposalOptionDisplayDetail)
                                                        .font(.caption)
                                                    Text(option.amount, format: .currency(code: "USD"))
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                }
                                                Spacer()
                                                if option.id == linkedEstimate.id {
                                                    Text(option.proposalIsFinalized ? "Approved" : "Current choice")
                                                        .font(.caption2)
                                                        .foregroundColor(option.proposalIsFinalized ? .green : .secondary)
                                                } else {
                                                    Button("Select") {
                                                        selectProposalOption(option)
                                                    }
                                                    .font(.caption)
                                                    .buttonStyle(.bordered)
                                                    .disabled(selectionIssue != nil)
                                                }
                                            }
                                        }
                                        if let issue = EstimateProposalPolicy.selectionIssue(for: linkedEstimate, in: estimates) {
                                            Text(issue)
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        } else if linkedEstimate.proposalIsFinalized {
                                            Text("The approved option is locked. Use a change order for later scope or price changes.")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.top, 2)
                                }
                                if let approvedAt = linkedEstimate.customerApprovedAt {
                                    Text("Customer approval: \(linkedEstimate.customerApprovedByName ?? call.customer.name) • \(approvedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if let method = linkedEstimate.customerApprovalMethod {
                                        Text("Method: \(method.displayName)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                HStack {
                                    Button("Record Customer Approval") {
                                        selectedEstimateForApproval = linkedEstimate
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(linkedEstimate.hasRecordedCustomerApproval)

                                    Button("Rejected") {
                                        linkedEstimate.status = "rejected"
                                        call.followUpRequired = false
                                        call.followUpAction = nil
                                        call.followUpDueDate = nil
                                    }
                                    .buttonStyle(.bordered)

                                    if let estimateFollowUpEmailURL {
                                        Button("Draft Follow-Up") {
                                            openEstimateFollowUpEmail(fallbackURL: estimateFollowUpEmailURL)
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    if linkedEstimate.status == "accepted" {
                                        if let scheduledWork = scheduledApprovedWork(for: linkedEstimate) {
                                            Button("Open Scheduled Work") {
                                                GunnAireAppIntentRouter.storeScheduleCallRoute(scheduledWork.id)
                                            }
                                            .buttonStyle(.bordered)
                                        } else if canScheduleApprovedWork {
                                            Button("Schedule Approved Work") {
                                                presentApprovedWorkSchedule(for: linkedEstimate)
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(!linkedEstimate.hasRecordedCustomerApproval)
                                        }
                                    }
                                }
                                if linkedEstimate.status == "accepted" && !canScheduleApprovedWork {
                                    Text("Dispatch or an administrator must schedule approved work.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
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
                            } else if let linkedInvoice {
                                Text("Remaining balance: \(Invoice.outstandingBalance(for: linkedInvoice, payments: []), format: .currency(code: "USD"))")
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
                    } else if selectedWorkspace == .work, !canViewFinancials {
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

                    if selectedWorkspace == .work && (canSubmitFieldExpenseForCurrentJob || !visibleCurrentJobExpenseClaims.isEmpty) {
                        GroupBox("Field Expenses") {
                            VStack(alignment: .leading, spacing: 9) {
                                if visibleCurrentJobExpenseClaims.isEmpty {
                                    Text("No expense or mileage claims are linked to this job for this account.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(visibleCurrentJobExpenseClaims.prefix(3)) { claim in
                                        HStack {
                                            Label(claim.category.displayName, systemImage: claim.claimType.systemImage)
                                                .font(.caption.weight(.semibold))
                                            Spacer()
                                            Text(claim.amount, format: .currency(code: "USD"))
                                                .font(.caption.weight(.semibold))
                                            Text(claim.status.displayName)
                                                .font(.caption2)
                                                .foregroundStyle(claim.status == .reimbursed ? .green : .secondary)
                                        }
                                        .accessibilityElement(children: .combine)
                                    }
                                    if visibleCurrentJobExpenseClaims.count > 3 {
                                        Text("\(visibleCurrentJobExpenseClaims.count - 3) more in Time Clock → Expenses & Mileage")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if canSubmitFieldExpenseForCurrentJob {
                                    Button {
                                        showingFieldExpenseClaim = true
                                    } label: {
                                        Label("Add Expense or Mileage", systemImage: "plus.circle")
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("AddJobFieldExpense")
                                }
                                Text("Approved claims add internal job cost. Customer invoice lines, inventory use, payroll, reimbursement, and QuickBooks posting remain separate workflows.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("ServiceCallFieldExpenses")
                    }

                    if selectedWorkspace == .work {
                    GroupBox("Completion Checklist") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Customer notified", isOn: Binding(
                                get: { call.customerNotified },
                                set: { call.customerNotified = $0 }
                            ))
                            Toggle("Technician arrived on site", isOn: Binding(
                                get: { call.arrivalConfirmed },
                                set: { arrived in
                                    if arrived {
                                        call.markTechnicianArrived()
                                    } else {
                                        call.arrivalConfirmed = false
                                        call.technicianArrivedAt = nil
                                    }
                                }
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
                    }

                    if selectedWorkspace == .overview, let mapsURL {
                        Button {
                            openURL(mapsURL)
                        } label: {
                            Label("Driving Directions", systemImage: "map")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                    }

                    if selectedWorkspace == .billing, canViewFinancials {
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

                    if selectedWorkspace == .billing,
                       canViewFinancials,
                       GunnAireBackendService.isConfigured,
                       call.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        Button {
                            showingCustomerPortalComposer = true
                        } label: {
                            Label("Share Customer Portal", systemImage: "person.badge.key")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if selectedWorkspace == .billing && canViewFinancials && hasOpenInvoiceBalance {
                        VStack(spacing: 10) {
                            Button {
                                if let linkedInvoiceID = call.linkedInvoiceID {
                                    GunnAireAppIntentRouter.storePaymentCollectionRoute(linkedInvoiceID)
                                } else {
                                    GunnAireAppIntentRouter.storeDocumentationRoute(call.id)
                                }
                            } label: {
                                Label(tapToPayReady ? "Tap to Pay on iPhone" : "Take Payment", systemImage: "creditcard")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)

                            if let reminderEmailURL {
                                Button {
                                    openReminderEmail(fallbackURL: reminderEmailURL)
                                } label: {
                                    Label("Draft Payment Reminder", systemImage: "envelope.badge")
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
        .sheet(isPresented: $showingCustomerPortalComposer) {
            CustomerPortalLinkComposer(
                call: call,
                invoice: linkedInvoice,
                balanceDue: linkedInvoice == nil ? nil : invoiceBalanceDue
            )
            .tint(Color.brandGold)
        }
        .sheet(isPresented: $showingEnRouteHandoff) {
            EnRouteHandoffSheet(
                customerName: call.customer.name,
                appointmentSummary: call.customerAppointmentSummary,
                destinationAddress: resolvedAddress,
                canDraftText: canDraftEnRouteText,
                canDraftEmail: canDraftEnRouteEmail,
                canOpenDirections: mapsURL != nil,
                defaultCustomerUpdateChannel: defaultEnRouteUpdateChannel,
                onOpenDirections: {
                    guard let mapsURL else { return }
                    openURL(mapsURL)
                },
                onCommit: commitEnRouteHandoff
            )
            .tint(Color.brandGold)
        }
        .sheet(isPresented: $showingFieldExpenseClaim) {
            FieldExpenseClaimEditor(
                initialServiceCall: call,
                existingClaim: nil,
                serviceCalls: serviceCalls,
                technicians: technicians,
                users: users
            )
            .tint(Color.brandGold)
        }
        .sheet(isPresented: $showingWorkPerformedLog) {
            WorkPerformedLogComposer(
                jobTitle: call.eventTitle ?? call.type.displayName,
                onSave: saveWorkPerformedLog
            )
            .tint(Color.brandGold)
        }
        .sheet(isPresented: $showingCustomerWorkSummary) {
            CustomerWorkSummaryComposer(
                jobTitle: call.eventTitle ?? call.type.displayName,
                suggestedSummary: suggestedCustomerWorkSummary,
                existingSummary: currentCustomerWorkSummary,
                workLogCount: workPerformedEntries.count,
                onSave: saveCustomerWorkSummary
            )
            .tint(Color.brandGold)
        }
        .sheet(item: $activeServiceTextDraft) { draft in
            #if canImport(MessageUI) && !targetEnvironment(macCatalyst)
            CustomerMessageComposer(draft: draft) { outcome in
                handleServiceTextResult(outcome, draft: draft)
            }
            #else
            ContentUnavailableView(
                "Messages Unavailable",
                systemImage: "message.badge.filled.fill",
                description: Text("Use an iPhone or iPad configured for Apple Messages to send this staff-reviewed text draft.")
            )
            #endif
        }
        .sheet(item: $selectedEstimateForApproval) { estimate in
            EstimateApprovalSheet(estimate: estimate) { evidence in
                recordCustomerApproval(evidence, for: estimate)
            }
            .tint(Color.brandGold)
        }
        .sheet(item: $selectedEstimateForScheduling) { estimate in
            ApprovedEstimateSchedulingSheet(
                estimate: estimate,
                sourceCall: call
            ) { scheduledDate, duration, workType in
                createApprovedWorkOrder(
                    for: estimate,
                    scheduledDate: scheduledDate,
                    duration: duration,
                    workType: workType
                )
            }
            .tint(Color.brandGold)
        }
        .sheet(isPresented: $showingMaintenanceAgreementOffer) {
            MaintenanceAgreementOfferSheet(
                customer: call.customer,
                equipmentProfiles: customerEquipmentProfiles,
                billingItems: items
            ) { submission in
                createMaintenanceAgreementFromJob(submission)
            }
            .tint(Color.brandGold)
        }
        .sheet(item: $selectedMaintenanceAgreementForApproval) { agreement in
            MaintenanceAgreementApprovalSheet(agreement: agreement) { approval in
                approveMaintenanceAgreementFromJob(agreement, approval: approval)
            }
            .tint(Color.brandGold)
        }
        .sheet(item: $warrantyClaimsEquipment) { equipment in
            EquipmentWarrantyClaimsSheet(
                equipment: equipment,
                originatingServiceCall: call,
                restrictToOriginatingJob: true
            )
            .tint(Color.brandGold)
        }
        .onAppear {
            FieldFormTemplate.ensureStarterTemplates(in: modelContext)
            guard !hasSelectedInitialWorkspace else { return }
            selectedWorkspace = ServiceCallDetailWorkspace.recommended(
                for: call.status,
                hasOpenInvoiceBalance: hasOpenInvoiceBalance,
                canViewFinancials: canViewFinancials
            )
            hasSelectedInitialWorkspace = true
        }
        .onChange(of: canViewFinancials) { _, newCanViewFinancials in
            if !ServiceCallDetailWorkspace.available(canViewFinancials: newCanViewFinancials).contains(selectedWorkspace) {
                selectedWorkspace = .work
            }
        }
    }

    private var jobActionsSection: some View {
        GroupBox("Job Actions") {
            HStack {
                if call.status == .scheduled && call.technicianEnRouteAt == nil {
                    Button {
                        jobActionStatus = nil
                        showingEnRouteHandoff = true
                    } label: {
                        Label("En Route", systemImage: "car.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(activeServiceRestriction != nil)
                }
                if call.technicianEnRouteAt != nil && call.technicianArrivedAt == nil && !call.arrivalConfirmed {
                    Button {
                        call.markTechnicianArrived()
                        ServiceCallActivity.record(for: call, action: "Technician arrived", detail: "Arrival confirmed on site.", actorEmail: currentActivityActor, in: modelContext)
                    } label: {
                        Label("Arrived", systemImage: "mappin.and.ellipse")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(activeServiceRestriction != nil)
                }
                if call.status == .scheduled {
                    Button {
                        if let blocker = activeServiceRestriction {
                            jobActionStatus = CustomerOperationalAlertPolicy.bookingRestrictionMessage(for: blocker)
                            return
                        }
                        call.status = .inProgress
                        call.documentationStartedAt = call.documentationStartedAt ?? Date()
                        ServiceCallActivity.record(for: call, action: "Job started", detail: "Status changed from scheduled to in progress.", actorEmail: currentActivityActor, in: modelContext)
                    } label: {
                        Label("Start Job", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(activeServiceRestriction != nil)
                } else if call.status == .inProgress {
                    Button {
                        guard operationalCompletionBlockers.isEmpty else {
                            jobActionStatus = operationalCompletionStatus
                            return
                        }
                        if call.markDocumentationCompleteIfReady() {
                            call.status = .completed
                            call.completeLinkedMaintenanceAgreementIfNeeded()
                            ServiceCallActivity.record(for: call, action: "Job completed", detail: "Status changed from in progress to completed.", actorEmail: currentActivityActor, in: modelContext)
                        }
                    } label: {
                        Label("Mark Complete", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!operationalCompletionBlockers.isEmpty)
                } else if call.status == .completed {
                    Button {
                        if let blocker = activeServiceRestriction {
                            jobActionStatus = CustomerOperationalAlertPolicy.bookingRestrictionMessage(for: blocker)
                            return
                        }
                        call.status = .inProgress
                        ServiceCallActivity.record(for: call, action: "Job reopened", detail: "Status changed from completed to in progress.", actorEmail: currentActivityActor, in: modelContext)
                    } label: {
                        Label("Reopen Job", systemImage: "arrow.uturn.backward.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(activeServiceRestriction != nil)
                }
            }
            .tint(Color.brandGold)
            .foregroundStyle(Color.primaryBlack)

            if let activeServiceRestriction {
                Label(
                    CustomerOperationalAlertPolicy.bookingRestrictionMessage(for: activeServiceRestriction),
                    systemImage: "hand.raised.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("JobActionServiceRestriction")
            }

            if call.status == .inProgress, let operationalCompletionStatus {
                Label(operationalCompletionStatus, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("OperationalCompletionBlockers")
            }

            if let jobActionStatus {
                Text(jobActionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("JobActionStatus")
            }
        }
    }

    private func selectProposalOption(_ estimate: Estimate) {
        guard EstimateProposalPolicy.select(estimate, in: estimates) else { return }
        call.linkedEstimateID = estimate.id
    }

    private var presenceSystemImage: String {
        switch call.technicianJobPresence {
        case .scheduled: "calendar"
        case .enRoute: "car.fill"
        case .onSite: "mappin.and.ellipse"
        case .working: "wrench.and.screwdriver.fill"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    private var crewTechnicianNames: [String] {
        technicians
            .filter { call.additionalTechnicianIDs.contains($0.id) }
            .map(\.name)
    }

    private func recordCustomerApproval(_ evidence: EstimateApprovalEvidence, for estimate: Estimate) -> Bool {
        guard EstimateProposalPolicy.recordApproval(
            for: estimate,
            in: estimates,
            customerName: evidence.customerName,
            method: evidence.method,
            reference: evidence.reference,
            signatureImageBase64: evidence.signatureImageBase64,
            recordedByEmail: currentActivityActor
        ) else {
            return false
        }
        call.linkedEstimateID = estimate.id
        call.followUpRequired = false
        call.followUpAction = nil
        call.followUpDueDate = nil
        ServiceCallActivity.record(
            for: call,
            action: estimate.isChangeOrder ? "Change order approved" : "Estimate approved",
            detail: "Customer approval recorded by \(evidence.method.displayName.lowercased()) for \(estimate.amount.formatted(.currency(code: "USD"))).",
            actorEmail: currentActivityActor,
            in: modelContext
        )
        return true
    }
}

enum ServiceCallDetailWorkspace: String, CaseIterable, Identifiable {
    case overview
    case work
    case billing
    case history

    var id: String { rawValue }

    static func available(canViewFinancials: Bool) -> [ServiceCallDetailWorkspace] {
        canViewFinancials ? allCases : [.overview, .work, .history]
    }

    static func recommended(
        for status: JobStatus,
        hasOpenInvoiceBalance: Bool,
        canViewFinancials: Bool
    ) -> ServiceCallDetailWorkspace {
        switch status {
        case .scheduled, .inProgress:
            return .work
        case .completed, .invoiced:
            return canViewFinancials && hasOpenInvoiceBalance ? .billing : .history
        case .cancelled:
            return .history
        }
    }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .work: "Work"
        case .billing: "Billing"
        case .history: "History"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.grid.1x2"
        case .work: "wrench.and.screwdriver"
        case .billing: "doc.text"
        case .history: "clock.arrow.circlepath"
        }
    }

    var guidance: String {
        switch self {
        case .overview:
            "Review the appointment, contact the customer, navigate, and handle the next job-status action."
        case .work:
            "Capture field forms, equipment context, workflow checks, photos, and completion evidence."
        case .billing:
            "Review proposals, invoice status, payment balance, customer documents, and collection follow-up."
        case .history:
            "Review the job audit trail, service agreement, recent customer visits, and equipment history."
        }
    }
}

private struct CustomerPortalLinkComposer: View {
    @Environment(\.dismiss) private var dismiss
    let call: ServiceCall
    let invoice: Invoice?
    let balanceDue: Double?

    @State private var expiryDays = 14
    @State private var isCreating = false
    @State private var link: BackendCustomerPortalLink?
    @State private var errorMessage: String?

    private var expiryDescription: String {
        "Expires in \(expiryDays) day\(expiryDays == 1 ? "" : "s") and can be revoked by an administrator from the shared server."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer Access") {
                    Text(call.customer.name)
                    Text(call.customer.email ?? "No email")
                        .foregroundStyle(.secondary)
                    Text("This link only shows this appointment and its linked invoice summary. It cannot be used to browse customer records, edit a job, or take a payment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Link Expiry") {
                    Stepper("\(expiryDays) days", value: $expiryDays, in: 1...30)
                    Text(expiryDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let link, let url = URL(string: link.url) {
                    Section("Secure Link") {
                        ShareLink(item: url, subject: Text("Your GunnAire service update"), message: Text("Here is your secure GunnAire service link.")) {
                            Label("Share Secure Link", systemImage: "square.and.arrow.up")
                        }
                        Text(url.absoluteString)
                            .font(.caption2)
                            .textSelection(.enabled)
                        Text("Expires \(link.expiresAt)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Customer Portal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(link == nil ? "Cancel" : "Done") { dismiss() }
                }
                if link == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isCreating ? "Creating…" : "Create Link") {
                            createLink()
                        }
                        .disabled(isCreating)
                    }
                }
            }
        }
    }

    private func createLink() {
        isCreating = true
        errorMessage = nil
        Task {
            do {
                let created = try await GunnAireBackendService.createCustomerPortalLink(
                    customer: call.customer,
                    serviceCall: call,
                    invoice: invoice,
                    balanceDue: balanceDue,
                    expiresInDays: expiryDays
                )
                await MainActor.run {
                    link = created
                    isCreating = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isCreating = false
                }
            }
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
    @Query(sort: \CustomerServiceLocation.name, order: .forward) private var serviceLocations: [CustomerServiceLocation]
    @Query(sort: \CustomerOperationalAlert.createdAt, order: .reverse) private var operationalAlerts: [CustomerOperationalAlert]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @AppStorage("defaultJobDurationMinutes") private var defaultJobDurationMinutes = 90
    
    @State private var callType: ServiceCallType = .service
    @State private var dispatchUrgency: ServiceRequestUrgency = .normal
    @State private var eventTitle = ""
    @State private var customer: Customer?
    @State private var technician: Technician?
    @State private var crewMemberIDs: Set<UUID> = []
    @State private var scheduledTime: Date
    @State private var duration: TimeInterval = 3600
    @State private var usesArrivalWindow = false
    @State private var arrivalWindowStart: Date
    @State private var arrivalWindowEnd: Date
    @State private var customerSearchText = ""
    @State private var creatingNewCustomer = false
    @State private var newCustomerName = ""
    @State private var newCustomerPhone = ""
    @State private var newCustomerEmail = ""
    @State private var newCustomerAddress = ""
    @State private var siteAddress: String = ""
    @State private var selectedServiceLocationID: UUID?
    @State private var equipmentType: HVACEquipmentType = .splitSystemAC
    @State private var equipmentName = ""
    @State private var equipmentManufacturer = ""
    @State private var equipmentModel = ""
    @State private var equipmentSerialNumber = ""
    @State private var equipmentLocation = ""
    @State private var filterSize = ""
    @State private var equipmentNotes = ""
    @State private var showingEquipmentNameplateCapture = false
    @State private var equipmentInstallDate: Date = Date()
    @State private var includeInstallDate = false
    @State private var equipmentWarrantyExpiration: Date = Date()
    @State private var includeWarrantyExpiration = false
    @State private var selectedCustomerEquipmentID: UUID?
    @State private var notes: String = ""
    @State private var findingsSummary = ""
    @State private var recommendedWorkSummary = ""
    @State private var visitDisposition: ServiceVisitDisposition = .standard
    @State private var correctiveWorkReason: CorrectiveWorkReason = .unresolvedConcern
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
        let defaultWindowStart = calendar.date(byAdding: components, to: baseDate) ?? Date()
        _arrivalWindowStart = State(initialValue: defaultWindowStart)
        _arrivalWindowEnd = State(initialValue: defaultWindowStart.addingTimeInterval(2 * 3600))
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
        case .service, .repair, .estimate, .replacement, .install, .maintenance:
            return true
        case .meeting, .reminder, .siteVisit, .other:
            return false
        }
    }

    private var canSaveCall: Bool {
        canManageDispatch &&
            (customer != nil || (!requiresCustomer && eventTitle.nilIfBlank != nil)) &&
            (!usesArrivalWindow || arrivalWindowEnd > arrivalWindowStart) &&
            equipmentLifecycleSnapshot.validationMessage == nil &&
            schedulingBlocker == nil
    }

    private var equipmentLifecycleSnapshot: EquipmentLifecycleSnapshot {
        EquipmentLifecyclePolicy.snapshot(
            installDate: includeInstallDate ? equipmentInstallDate : nil,
            warrantyExpiration: includeWarrantyExpiration ? equipmentWarrantyExpiration : nil
        )
    }

    private var assignableTechnicians: [Technician] {
        AppAccess.schedulableTechnicians(technicians, users: users)
    }

    private var isAdminUser: Bool {
        let email = AppIdentity.currentEmail
        return AppAccess.isAdmin(email: email, users: users)
    }

    private var canManageDispatch: Bool {
        AppAccess.canPerformScheduleMutation(
            .createServiceCall,
            email: AppIdentity.currentEmail,
            users: users
        )
    }

    private var conflictingCalls: [ServiceCall] {
        var proposedTechnicianIDs = crewMemberIDs
        if let technician { proposedTechnicianIDs.insert(technician.id) }
        guard !proposedTechnicianIDs.isEmpty else { return [] }
        let proposedEnd = scheduledTime.addingTimeInterval(duration)
        return existingServiceCalls.filter { call in
            guard !call.assignedCrewTechnicianIDs.isDisjoint(with: proposedTechnicianIDs), call.status != .cancelled else { return false }
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

    private var selectedCustomerServiceLocations: [CustomerServiceLocation] {
        guard let customer else { return [] }
        return CustomerServiceLocationPolicy.locations(for: customer.id, in: serviceLocations)
    }

    private var selectedOperationalAlerts: [CustomerOperationalAlert] {
        guard let customer else { return [] }
        return CustomerOperationalAlertPolicy.activeAlerts(
            customerID: customer.id,
            serviceLocationID: selectedServiceLocationID,
            in: operationalAlerts
        )
    }

    private var schedulingBlocker: CustomerOperationalAlert? {
        guard let customer else { return nil }
        return CustomerOperationalAlertPolicy.schedulingBlocker(
            customerID: customer.id,
            serviceLocationID: selectedServiceLocationID,
            in: operationalAlerts
        )
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
                .accessibilityIdentifier("NewServiceCallType")
                Picker("Dispatch Priority", selection: $dispatchUrgency) {
                    ForEach(ServiceRequestUrgency.allCases) { urgency in
                        Text(urgency.displayName).tag(urgency)
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
                                    applyPreferredServiceLocation(for: matchedCustomer)
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
                        TextField("Billing / Default Address", text: $newCustomerAddress, axis: .vertical)
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
                            if let address = createdCustomer.address {
                                let primaryLocation = CustomerServiceLocation(
                                    customer: createdCustomer,
                                    name: "Primary Service Location",
                                    address: address,
                                    isPrimary: true
                                )
                                modelContext.insert(primaryLocation)
                                selectedServiceLocationID = primaryLocation.id
                            }
                            customer = createdCustomer
                            customerSearchText = createdCustomer.name
                            siteAddress = createdCustomer.address ?? ""
                            creatingNewCustomer = false
                            resetNewCustomerFields()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .disabled(!canSaveNewCustomer)
                    }
                }
                CustomerOperationalAlertInlineSummary(
                    alerts: selectedOperationalAlerts,
                    accessibilityIdentifier: "NewServiceCallOperationalAlerts"
                )
                if let schedulingBlocker {
                    Text(CustomerOperationalAlertPolicy.bookingRestrictionMessage(for: schedulingBlocker))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("NewServiceCallBookingRestriction")
                }
                if !selectedCustomerServiceLocations.isEmpty {
                    Picker("Service Location", selection: $selectedServiceLocationID) {
                        Text("Custom / billing address").tag(UUID?.none)
                        ForEach(selectedCustomerServiceLocations) { location in
                            Text(location.displayName).tag(UUID?.some(location.id))
                        }
                    }
                    .onChange(of: selectedServiceLocationID) { _, selectedID in
                        applyServiceLocation(id: selectedID)
                    }
                }
                TextField("Service Address Snapshot", text: $siteAddress, axis: .vertical)
                    .lineLimit(2...3)
                Text("The job keeps this address snapshot even if the reusable location is edited later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Picker("Equipment Type", selection: $equipmentType) {
                        ForEach(HVACEquipmentType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    TextField("Equipment", text: $equipmentName)
                    Button {
                        showingEquipmentNameplateCapture = true
                    } label: {
                        Label("Read Equipment Data Plate", systemImage: "text.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ReadNewJobEquipmentNameplate")
                    Text("Recognition stays on this device and fills only reviewed manufacturer, model, and serial values.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Manufacturer", text: $equipmentManufacturer)
                    TextField("Model", text: $equipmentModel)
                    TextField("Serial Number", text: $equipmentSerialNumber)
                    TextField("Equipment Location", text: $equipmentLocation)
                    TextField("Filter Size", text: $filterSize)
                    TextField("Equipment Notes", text: $equipmentNotes, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("Track Install Date", isOn: $includeInstallDate)
                    if includeInstallDate {
                        DatePicker("Install Date", selection: $equipmentInstallDate, displayedComponents: .date)
                    }
                    Toggle("Track Warranty Expiration", isOn: $includeWarrantyExpiration)
                    if includeWarrantyExpiration {
                        DatePicker("Warranty Expiration", selection: $equipmentWarrantyExpiration, displayedComponents: .date)
                    }
                    if let validationMessage = equipmentLifecycleSnapshot.validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("NewServiceCallEquipmentDateValidation")
                    }
                }
                Picker("Technician", selection: $technician) {
                    Text("Unassigned").tag(Technician?.none)
                    ForEach(assignableTechnicians) { t in
                        Text(AppAccess.scheduleLabel(for: t)).tag(Technician?.some(t))
                    }
                }
                if let technician {
                    let qualification = technician.qualification(for: equipmentType)
                    Text("Dispatch qualification: \(qualification.displayName)")
                        .font(.caption)
                        .foregroundStyle(qualification.needsDispatchAttention ? .orange : .secondary)
                        .accessibilityIdentifier("NewServiceCallTechnicianQualification")
                    let serviceAreaMatch = technician.serviceAreaMatch(for: siteAddress)
                    Text("Dispatch territory: \(serviceAreaMatch.dispatchDetail)")
                        .font(.caption)
                        .foregroundStyle(serviceAreaMatch == .outsideConfiguredAreas ? .orange : .secondary)
                }
                DisclosureGroup("Additional Crew (\(crewMemberIDs.count))") {
                    ForEach(assignableTechnicians.filter { $0.id != technician?.id }) { crewTechnician in
                        Toggle(crewTechnician.name, isOn: Binding(
                            get: { crewMemberIDs.contains(crewTechnician.id) },
                            set: { selected in
                                if selected { crewMemberIDs.insert(crewTechnician.id) }
                                else { crewMemberIDs.remove(crewTechnician.id) }
                            }
                        ))
                    }
                    Text("Crew members are included in conflict checks. The selected technician remains the lead and calendar owner.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Section("Customer Arrival Window") {
                    Toggle("Promise an arrival range", isOn: $usesArrivalWindow)
                    if usesArrivalWindow {
                        DatePicker("Arrival begins", selection: $arrivalWindowStart, displayedComponents: [.date, .hourAndMinute])
                        DatePicker("Arrival ends", selection: $arrivalWindowEnd, displayedComponents: [.date, .hourAndMinute])
                        if arrivalWindowEnd <= arrivalWindowStart {
                            Text("Arrival end must be later than arrival start.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Text("This customer promise does not change technician capacity or the calendar work block.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !conflictingCalls.isEmpty {
                    Section("Schedule Conflict") {
                        Text("A selected lead or crew member already has overlapping work scheduled.")
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
                Section("Visit Classification") {
                    Picker("Visit class", selection: $visitDisposition) {
                        ForEach(ServiceVisitDisposition.allCases.filter { $0 != .noAccess }) { disposition in
                            Text(disposition.displayName).tag(disposition)
                        }
                    }
                    Text(visitDisposition.guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if visitDisposition == .warranty || visitDisposition == .callback {
                        Picker("Corrective reason", selection: $correctiveWorkReason) {
                            ForEach(CorrectiveWorkReason.allCases) { reason in
                                Text(reason.displayName).tag(reason)
                            }
                        }
                        Text("The reason follows any scheduled corrective visit for history and callback reporting.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Open Documentation After Save", isOn: $openDocumentationAfterSave)
            }
            .disabled(!canManageDispatch)
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
        .sheet(isPresented: $showingEquipmentNameplateCapture) {
            EquipmentNameplateCaptureSheet { draft in
                applyEquipmentNameplateDraft(draft)
            }
        }
        .onAppear {
            guard canManageDispatch else {
                dismiss()
                return
            }
            AppAccess.ensureTechnicianRecords(for: users, technicians: technicians, modelContext: modelContext)
            duration = TimeInterval(defaultJobDurationMinutes * 60)
            loadAccessibleCalendarsIfNeeded()
        }
        .onChange(of: canManageDispatch) { _, isAllowed in
            if !isAllowed { dismiss() }
        }
        .onChange(of: technician) { _, newTechnician in
            if let newTechnician {
                crewMemberIDs.remove(newTechnician.id)
            }
            selectedCalendarID = ServiceCalendarRouting.preferredCalendarID(for: newTechnician, calendars: accessibleCalendars)
        }
        .onChange(of: customer) { _, newCustomer in
            selectedCustomerEquipmentID = nil
            selectedServiceLocationID = nil
            if let newCustomer {
                applyPreferredServiceLocation(for: newCustomer)
            } else {
                siteAddress = ""
            }
        }
        .onChange(of: scheduledTime) { oldValue, newValue in
            guard usesArrivalWindow else { return }
            let shift = newValue.timeIntervalSince(oldValue)
            arrivalWindowStart = arrivalWindowStart.addingTimeInterval(shift)
            arrivalWindowEnd = arrivalWindowEnd.addingTimeInterval(shift)
        }
    }
    
    private func addCall() {
        guard AppAccess.canPerformScheduleMutation(
            .createServiceCall,
            email: AppIdentity.currentEmail,
            users: users
        ) else {
            dismiss()
            return
        }
        guard equipmentLifecycleSnapshot.validationMessage == nil else { return }
        guard let resolvedCustomer = resolvedCustomerForSave() else { return }
        guard CustomerOperationalAlertPolicy.schedulingBlocker(
            customerID: resolvedCustomer.id,
            serviceLocationID: selectedServiceLocationID,
            in: operationalAlerts
        ) == nil else { return }
        let trimmedSiteAddress = siteAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSiteAddress = trimmedSiteAddress.isEmpty ? resolvedCustomer.address : trimmedSiteAddress
        let resolvedCalendarID = ServiceCalendarRouting.validSelection(
            selectedCalendarID,
            technician: technician,
            calendars: accessibleCalendars
        )
        let call = ServiceCall(
            googleCalendarID: resolvedCalendarID,
            googleEventManagedByApp: true,
            eventTitle: eventTitle.nilIfBlank,
            siteAddress: resolvedSiteAddress,
            serviceLocationID: selectedServiceLocationID,
            equipmentName: equipmentName.nilIfBlank,
            equipmentManufacturer: equipmentManufacturer.nilIfBlank,
            equipmentModel: equipmentModel.nilIfBlank,
            equipmentSerialNumber: equipmentSerialNumber.nilIfBlank,
            equipmentLocation: equipmentLocation.nilIfBlank,
            equipmentInstallDate: includeInstallDate ? equipmentInstallDate : nil,
            equipmentWarrantyExpiration: includeWarrantyExpiration ? equipmentWarrantyExpiration : nil,
            customerEquipmentID: selectedCustomerEquipmentID,
            equipmentTypeRaw: equipmentType.rawValue,
            equipmentNotes: equipmentNotes.nilIfBlank,
            filterSize: filterSize.nilIfBlank,
            type: callType,
            dispatchUrgency: dispatchUrgency,
            scheduledDate: scheduledTime,
            duration: duration,
            promisedArrivalWindowStart: usesArrivalWindow ? arrivalWindowStart : nil,
            promisedArrivalWindowEnd: usesArrivalWindow ? arrivalWindowEnd : nil,
            assignedTechnician: technician,
            additionalTechnicianIDs: crewMemberIDs,
            customer: resolvedCustomer,
            status: .scheduled,
            notes: notes.nilIfBlank,
            findingsSummary: findingsSummary.nilIfBlank,
            recommendedWorkSummary: recommendedWorkSummary.nilIfBlank,
            visitDisposition: visitDisposition,
            followUpRequired: followUpRequired,
            followUpAction: followUpRequired ? followUpAction.nilIfBlank : nil,
            followUpDueDate: followUpRequired ? followUpDueDate : nil,
            correctiveWorkReason: (visitDisposition == .warranty || visitDisposition == .callback) ? correctiveWorkReason : nil
        )
        if let selectedCustomerEquipmentID,
           let equipment = selectedCustomerEquipmentProfiles.first(where: { $0.id == selectedCustomerEquipmentID }) {
            equipment.applyTechnicalBaselines(to: call)
        }
        modelContext.insert(call)
        publishToGoogleCalendar(call)
        dismiss()
        if openDocumentationAfterSave {
            DispatchQueue.main.async {
                onCreated?(call)
            }
        }
    }

    private func applyEquipmentNameplateDraft(_ draft: EquipmentNameplateDraft) {
        let manufacturer = draft.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = draft.modelNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let serial = draft.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        func differs(_ scanned: String, from current: String) -> Bool {
            !scanned.isEmpty && scanned.localizedCaseInsensitiveCompare(current) != .orderedSame
        }
        if differs(manufacturer, from: equipmentManufacturer) ||
            differs(model, from: equipmentModel) ||
            differs(serial, from: equipmentSerialNumber) {
            selectedCustomerEquipmentID = nil
        }
        if !manufacturer.isEmpty { equipmentManufacturer = manufacturer }
        if !model.isEmpty { equipmentModel = model }
        if !serial.isEmpty { equipmentSerialNumber = serial }
    }

    private func applyEquipmentProfile(_ equipment: CustomerEquipment) {
        if let serviceLocationID = equipment.serviceLocationID {
            selectedServiceLocationID = serviceLocationID
            applyServiceLocation(id: serviceLocationID)
        }
        selectedCustomerEquipmentID = equipment.id
        equipmentType = equipment.equipmentType ?? .splitSystemAC
        equipmentName = equipment.name
        equipmentManufacturer = equipment.manufacturer ?? ""
        equipmentModel = equipment.modelNumber ?? ""
        equipmentSerialNumber = equipment.serialNumber ?? ""
        equipmentLocation = equipment.location ?? ""
        filterSize = equipment.filterSize ?? ""
        equipmentNotes = equipment.notes ?? ""
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

    private func applyPreferredServiceLocation(for customer: Customer) {
        let preferred = CustomerServiceLocationPolicy.preferredLocation(for: customer.id, in: serviceLocations)
        selectedServiceLocationID = preferred?.id
        siteAddress = preferred?.address ?? customer.address ?? ""
    }

    private func applyServiceLocation(id: UUID?) {
        guard let customer else { return }
        if let location = CustomerServiceLocationPolicy.location(id: id, customerID: customer.id, in: serviceLocations) {
            siteAddress = location.address
            if let selectedCustomerEquipmentID,
               let equipment = selectedCustomerEquipmentProfiles.first(where: { $0.id == selectedCustomerEquipmentID }),
               let equipmentLocationID = equipment.serviceLocationID,
               equipmentLocationID != location.id {
                self.selectedCustomerEquipmentID = nil
            }
        } else if id == nil {
            siteAddress = customer.address ?? siteAddress
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
        let signedInEmail = AppIdentity.currentEmail
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
    @Query(sort: \ServiceCallActivity.occurredAt, order: .reverse) private var serviceCallActivities: [ServiceCallActivity]
    @Query(sort: \CustomerEquipment.name, order: .forward) private var equipmentProfiles: [CustomerEquipment]
    @Query(sort: \CustomerServiceLocation.name, order: .forward) private var serviceLocations: [CustomerServiceLocation]
    @Query(sort: \CustomerOperationalAlert.createdAt, order: .reverse) private var operationalAlerts: [CustomerOperationalAlert]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @AppStorage("requireWorkPerformedLogForCloseout") private var requireWorkPerformedLogForCloseout = true

    let call: ServiceCall

    @State private var callType: ServiceCallType
    @State private var dispatchUrgency: ServiceRequestUrgency
    @State private var eventTitle: String
    @State private var customer: Customer?
    @State private var technician: Technician?
    @State private var crewMemberIDs: Set<UUID>
    @State private var scheduledTime: Date
    @State private var duration: TimeInterval
    @State private var usesArrivalWindow: Bool
    @State private var arrivalWindowStart: Date
    @State private var arrivalWindowEnd: Date
    @State private var status: JobStatus
    @State private var cancellationReason: String
    @State private var siteAddress: String
    @State private var selectedServiceLocationID: UUID?
    @State private var equipmentType: HVACEquipmentType
    @State private var equipmentName: String
    @State private var equipmentManufacturer: String
    @State private var equipmentModel: String
    @State private var equipmentSerialNumber: String
    @State private var equipmentLocation: String
    @State private var filterSize: String
    @State private var equipmentNotes: String
    @State private var showingEquipmentNameplateCapture = false
    @State private var equipmentInstallDate: Date
    @State private var includeInstallDate: Bool
    @State private var equipmentWarrantyExpiration: Date
    @State private var includeWarrantyExpiration: Bool
    @State private var selectedCustomerEquipmentID: UUID?
    @State private var notes: String
    @State private var findingsSummary: String
    @State private var recommendedWorkSummary: String
    @State private var visitDisposition: ServiceVisitDisposition
    @State private var visitDispositionNotes: String
    @State private var correctiveWorkReason: CorrectiveWorkReason
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
        _dispatchUrgency = State(initialValue: call.dispatchUrgency)
        _eventTitle = State(initialValue: initialEventTitle)
        _customer = State(initialValue: call.customer)
        _technician = State(initialValue: call.assignedTechnician)
        _crewMemberIDs = State(initialValue: call.additionalTechnicianIDs)
        _scheduledTime = State(initialValue: call.scheduledDate)
        _duration = State(initialValue: call.duration)
        _usesArrivalWindow = State(initialValue: call.hasPromisedArrivalWindow)
        _arrivalWindowStart = State(initialValue: call.promisedArrivalWindowStart ?? call.scheduledDate)
        _arrivalWindowEnd = State(initialValue: call.promisedArrivalWindowEnd ?? call.scheduledDate.addingTimeInterval(2 * 3600))
        _status = State(initialValue: call.status)
        _cancellationReason = State(initialValue: call.cancellationReason ?? "")
        _siteAddress = State(initialValue: call.siteAddress ?? call.customer.address ?? "")
        _selectedServiceLocationID = State(initialValue: call.serviceLocationID)
        _equipmentType = State(initialValue: call.equipmentType ?? .splitSystemAC)
        _equipmentName = State(initialValue: call.equipmentName ?? "")
        _equipmentManufacturer = State(initialValue: call.equipmentManufacturer ?? "")
        _equipmentModel = State(initialValue: call.equipmentModel ?? "")
        _equipmentSerialNumber = State(initialValue: call.equipmentSerialNumber ?? "")
        _equipmentLocation = State(initialValue: call.equipmentLocation ?? "")
        _filterSize = State(initialValue: call.filterSize ?? "")
        _equipmentNotes = State(initialValue: call.equipmentNotes ?? "")
        _equipmentInstallDate = State(initialValue: call.equipmentInstallDate ?? Date())
        _includeInstallDate = State(initialValue: call.equipmentInstallDate != nil)
        _equipmentWarrantyExpiration = State(initialValue: call.equipmentWarrantyExpiration ?? Date())
        _includeWarrantyExpiration = State(initialValue: call.equipmentWarrantyExpiration != nil)
        _selectedCustomerEquipmentID = State(initialValue: call.customerEquipmentID)
        _notes = State(initialValue: call.notes ?? "")
        _findingsSummary = State(initialValue: call.findingsSummary ?? "")
        _recommendedWorkSummary = State(initialValue: call.recommendedWorkSummary ?? "")
        _visitDisposition = State(initialValue: call.visitDisposition)
        _visitDispositionNotes = State(initialValue: call.visitDispositionNotes ?? "")
        _correctiveWorkReason = State(initialValue: call.correctiveWorkReason ?? .unresolvedConcern)
        _followUpRequired = State(initialValue: call.followUpRequired)
        _followUpAction = State(initialValue: call.followUpAction ?? "")
        _followUpDueDate = State(initialValue: call.followUpDueDate ?? Date())
        _selectedCalendarID = State(initialValue: call.googleCalendarID ?? "primary")
    }

    private var conflictingCalls: [ServiceCall] {
        var proposedTechnicianIDs = crewMemberIDs
        if let technician { proposedTechnicianIDs.insert(technician.id) }
        guard !proposedTechnicianIDs.isEmpty else { return [] }
        let proposedEnd = scheduledTime.addingTimeInterval(duration)
        return existingServiceCalls.filter { existingCall in
            guard existingCall.id != call.id,
                  !existingCall.assignedCrewTechnicianIDs.isDisjoint(with: proposedTechnicianIDs),
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
        let email = AppIdentity.currentEmail
        return AppAccess.isAdmin(email: email, users: users)
    }

    private var canManageDispatch: Bool {
        AppAccess.canPerformScheduleMutation(
            .editServiceCall,
            email: AppIdentity.currentEmail,
            users: users
        )
    }

    private var visibleCustomers: [Customer] {
        customers.filter { !CustomerDataMaintenance.isSystemCalendarCustomer($0) }
    }

    private var isExternalGoogleCalendarEvent: Bool {
        GoogleCalendarScheduleSync.isExternalGoogleCalendarEvent(call)
    }

    private var selectedCustomerEquipmentProfiles: [CustomerEquipment] {
        guard let customer else { return [] }
        return equipmentProfiles.filter { $0.customer?.id == customer.id && $0.isActive }
    }

    private var selectedCustomerServiceLocations: [CustomerServiceLocation] {
        guard let customer else { return [] }
        return CustomerServiceLocationPolicy.locations(for: customer.id, in: serviceLocations)
    }

    private var selectedOperationalAlerts: [CustomerOperationalAlert] {
        guard let customer else { return [] }
        return CustomerOperationalAlertPolicy.activeAlerts(
            customerID: customer.id,
            serviceLocationID: selectedServiceLocationID,
            in: operationalAlerts
        )
    }

    private var selectedSchedulingBlocker: CustomerOperationalAlert? {
        selectedOperationalAlerts.first(where: \CustomerOperationalAlert.blocksNewScheduling)
    }

    private var changesSchedulingCommitment: Bool {
        customer?.id != call.customer.id ||
            selectedServiceLocationID != call.serviceLocationID ||
            scheduledTime != call.scheduledDate ||
            duration != call.duration ||
            technician?.id != call.assignedTechnician?.id ||
            crewMemberIDs != call.additionalTechnicianIDs ||
            (status == .inProgress && call.status != .inProgress)
    }

    private var serviceRestrictionBlocksSave: Bool {
        status != .cancelled && selectedSchedulingBlocker != nil && changesSchedulingCommitment
    }

    private var equipmentLifecycleSnapshot: EquipmentLifecycleSnapshot {
        EquipmentLifecyclePolicy.snapshot(
            installDate: includeInstallDate ? equipmentInstallDate : nil,
            warrantyExpiration: includeWarrantyExpiration ? equipmentWarrantyExpiration : nil
        )
    }

    private var isRequestingAClosedStatus: Bool {
        (status == .completed || status == .invoiced) &&
            call.status != .completed &&
            call.status != .invoiced
    }

    private var workLogBlocksRequestedStatus: Bool {
        isRequestingAClosedStatus &&
            ServiceWorkLogPolicy.requiresWorkPerformedLog(
                for: callType,
                whenEnabled: requireWorkPerformedLogForCloseout
            ) &&
            ServiceWorkLogPolicy.workPerformedEntries(
                for: call.id,
                in: serviceCallActivities
            ).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $callType) {
                    ForEach(ServiceCallType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                Picker("Dispatch Priority", selection: $dispatchUrgency) {
                    ForEach(ServiceRequestUrgency.allCases) { urgency in
                        Text(urgency.displayName).tag(urgency)
                    }
                }
                Section("Calendar Event") {
                    TextField("Event Title", text: $eventTitle)
                        .textInputAutocapitalization(.words)
                        .disabled(isExternalGoogleCalendarEvent)
                    if isExternalGoogleCalendarEvent {
                        Text("This event came from Google Calendar. Edit the title, location, and body in Google Calendar; GunnAire will only keep a local mirror.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Picker("Customer", selection: $customer) {
                    if CustomerDataMaintenance.isSystemCalendarCustomer(call.customer) {
                        Text("Unassigned Calendar Event").tag(Customer?.some(call.customer))
                    }
                    ForEach(visibleCustomers) { customer in
                        Text(customer.name).tag(Customer?.some(customer))
                    }
                }
                CustomerOperationalAlertInlineSummary(
                    alerts: selectedOperationalAlerts,
                    accessibilityIdentifier: "EditServiceCallOperationalAlerts"
                )
                if serviceRestrictionBlocksSave, let selectedSchedulingBlocker {
                    Text(CustomerOperationalAlertPolicy.bookingRestrictionMessage(for: selectedSchedulingBlocker))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("EditServiceCallBookingRestriction")
                }
                Picker("Technician", selection: $technician) {
                    Text("Unassigned").tag(Technician?.none)
                    ForEach(assignableTechnicians) { technician in
                        Text(AppAccess.scheduleLabel(for: technician)).tag(Technician?.some(technician))
                    }
                }
                if let technician {
                    let qualification = technician.qualification(for: equipmentType)
                    Text("Dispatch qualification: \(qualification.displayName)")
                        .font(.caption)
                        .foregroundStyle(qualification.needsDispatchAttention ? .orange : .secondary)
                        .accessibilityIdentifier("EditServiceCallTechnicianQualification")
                }
                DisclosureGroup("Additional Crew (\(crewMemberIDs.count))") {
                    ForEach(assignableTechnicians.filter { $0.id != technician?.id }) { crewTechnician in
                        Toggle(crewTechnician.name, isOn: Binding(
                            get: { crewMemberIDs.contains(crewTechnician.id) },
                            set: { selected in
                                if selected { crewMemberIDs.insert(crewTechnician.id) }
                                else { crewMemberIDs.remove(crewTechnician.id) }
                            }
                        ))
                    }
                    Text("Crew members are included in conflict checks. The selected technician remains the lead and calendar owner.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Status", selection: $status) {
                    ForEach(JobStatus.allCases, id: \.self) { status in
                        Text(status.rawValue.capitalized).tag(status)
                    }
                }
                if workLogBlocksRequestedStatus {
                    Label(
                        "Add a work-performed entry from the job's Work workspace before selecting a closed status.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("EditServiceCallWorkLogBlocker")
                }
                if status == .cancelled {
                    Section("Cancellation") {
                        TextField("Reason for cancellation", text: $cancellationReason, axis: .vertical)
                            .lineLimit(2...4)
                        Text("Cancellation is retained in the job history and blocks invoice creation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                if !selectedCustomerServiceLocations.isEmpty {
                    Picker("Service Location", selection: $selectedServiceLocationID) {
                        Text("Custom / billing address").tag(UUID?.none)
                        ForEach(selectedCustomerServiceLocations) { location in
                            Text(location.displayName).tag(UUID?.some(location.id))
                        }
                    }
                    .disabled(isExternalGoogleCalendarEvent)
                    .onChange(of: selectedServiceLocationID) { _, selectedID in
                        applyServiceLocation(id: selectedID)
                    }
                }
                TextField("Service Address Snapshot", text: $siteAddress, axis: .vertical)
                    .lineLimit(2...3)
                    .disabled(isExternalGoogleCalendarEvent)
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
                    Picker("Equipment Type", selection: $equipmentType) {
                        ForEach(HVACEquipmentType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    TextField("Equipment", text: $equipmentName)
                    Button {
                        showingEquipmentNameplateCapture = true
                    } label: {
                        Label("Read Equipment Data Plate", systemImage: "text.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ReadEditJobEquipmentNameplate")
                    Text("Recognition stays on this device and fills only reviewed manufacturer, model, and serial values.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Manufacturer", text: $equipmentManufacturer)
                    TextField("Model", text: $equipmentModel)
                    TextField("Serial Number", text: $equipmentSerialNumber)
                    TextField("Equipment Location", text: $equipmentLocation)
                    TextField("Filter Size", text: $filterSize)
                    TextField("Equipment Notes", text: $equipmentNotes, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("Track Install Date", isOn: $includeInstallDate)
                    if includeInstallDate {
                        DatePicker("Install Date", selection: $equipmentInstallDate, displayedComponents: .date)
                    }
                    Toggle("Track Warranty Expiration", isOn: $includeWarrantyExpiration)
                    if includeWarrantyExpiration {
                        DatePicker("Warranty Expiration", selection: $equipmentWarrantyExpiration, displayedComponents: .date)
                    }
                    if let validationMessage = equipmentLifecycleSnapshot.validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("EditServiceCallEquipmentDateValidation")
                    }
                }
                DatePicker("Scheduled Time", selection: $scheduledTime, displayedComponents: [.date, .hourAndMinute])
                Stepper(value: $duration, in: 1800...8*3600, step: 900) {
                    Text("Duration: \(Int(duration / 60)) min")
                }
                Section("Customer Arrival Window") {
                    Toggle("Promise an arrival range", isOn: $usesArrivalWindow)
                        .disabled(isExternalGoogleCalendarEvent)
                    if usesArrivalWindow {
                        DatePicker("Arrival begins", selection: $arrivalWindowStart, displayedComponents: [.date, .hourAndMinute])
                            .disabled(isExternalGoogleCalendarEvent)
                        DatePicker("Arrival ends", selection: $arrivalWindowEnd, displayedComponents: [.date, .hourAndMinute])
                            .disabled(isExternalGoogleCalendarEvent)
                        if arrivalWindowEnd <= arrivalWindowStart {
                            Text("Arrival end must be later than arrival start.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Text("This is a customer promise, separate from the technician work block.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !conflictingCalls.isEmpty {
                    Section("Schedule Conflict") {
                        Text("A selected lead or crew member already has overlapping work scheduled.")
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
                    .disabled(isExternalGoogleCalendarEvent)
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
                Section("Visit Result") {
                    Picker("Result", selection: $visitDisposition) {
                        ForEach(ServiceVisitDisposition.allCases) { disposition in
                            Text(disposition.displayName).tag(disposition)
                        }
                    }
                    Text(visitDisposition.guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if visitDisposition != .standard {
                        TextField("Outcome notes", text: $visitDispositionNotes, axis: .vertical)
                            .lineLimit(2...4)
                    }
                    if visitDisposition == .warranty || visitDisposition == .callback {
                        Picker("Corrective reason", selection: $correctiveWorkReason) {
                            ForEach(CorrectiveWorkReason.allCases) { reason in
                                Text(reason.displayName).tag(reason)
                            }
                        }
                        Text("This reason remains linked to the original job when a corrective visit is scheduled.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if visitDisposition == .noAccess && !followUpRequired {
                        Text("Set a follow-up when the customer wants to reschedule.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .disabled(!canManageDispatch)
            .navigationTitle("Edit Service Call")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(
                        !canManageDispatch ||
                            customer == nil ||
                            (status == .cancelled && cancellationReason.nilIfBlank == nil) ||
                            (usesArrivalWindow && arrivalWindowEnd <= arrivalWindowStart) ||
                            equipmentLifecycleSnapshot.validationMessage != nil ||
                            workLogBlocksRequestedStatus ||
                            serviceRestrictionBlocksSave
                    )
                }
            }
        }
        .tint(Color.brandGold)
        .sheet(isPresented: $showingEquipmentNameplateCapture) {
            EquipmentNameplateCaptureSheet { draft in
                applyEquipmentNameplateDraft(draft)
            }
        }
        .onAppear {
            guard canManageDispatch else {
                dismiss()
                return
            }
            AppAccess.ensureTechnicianRecords(for: users, technicians: technicians, modelContext: modelContext)
            loadAccessibleCalendarsIfNeeded()
        }
        .onChange(of: canManageDispatch) { _, isAllowed in
            if !isAllowed { dismiss() }
        }
        .onChange(of: technician) { _, newTechnician in
            if let newTechnician {
                crewMemberIDs.remove(newTechnician.id)
            }
            selectedCalendarID = ServiceCalendarRouting.preferredCalendarID(for: newTechnician, calendars: accessibleCalendars)
        }
        .onChange(of: customer) { _, _ in
            if let customer {
                let selectedLocation = CustomerServiceLocationPolicy.location(
                    id: selectedServiceLocationID,
                    customerID: customer.id,
                    in: serviceLocations
                )
                if selectedLocation == nil {
                    let preferred = CustomerServiceLocationPolicy.preferredLocation(for: customer.id, in: serviceLocations)
                    selectedServiceLocationID = preferred?.id
                    siteAddress = preferred?.address ?? customer.address ?? ""
                }
            } else {
                selectedServiceLocationID = nil
            }
            if let selectedCustomerEquipmentID,
               !selectedCustomerEquipmentProfiles.contains(where: { $0.id == selectedCustomerEquipmentID }) {
                self.selectedCustomerEquipmentID = nil
            }
        }
        .onChange(of: scheduledTime) { oldValue, newValue in
            guard usesArrivalWindow else { return }
            let shift = newValue.timeIntervalSince(oldValue)
            arrivalWindowStart = arrivalWindowStart.addingTimeInterval(shift)
            arrivalWindowEnd = arrivalWindowEnd.addingTimeInterval(shift)
        }
    }

    private func applyEquipmentNameplateDraft(_ draft: EquipmentNameplateDraft) {
        let manufacturer = draft.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = draft.modelNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let serial = draft.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        func differs(_ scanned: String, from current: String) -> Bool {
            !scanned.isEmpty && scanned.localizedCaseInsensitiveCompare(current) != .orderedSame
        }
        if differs(manufacturer, from: equipmentManufacturer) ||
            differs(model, from: equipmentModel) ||
            differs(serial, from: equipmentSerialNumber) {
            selectedCustomerEquipmentID = nil
        }
        if !manufacturer.isEmpty { equipmentManufacturer = manufacturer }
        if !model.isEmpty { equipmentModel = model }
        if !serial.isEmpty { equipmentSerialNumber = serial }
    }

    private func applyEquipmentProfile(_ equipment: CustomerEquipment) {
        if let serviceLocationID = equipment.serviceLocationID {
            selectedServiceLocationID = serviceLocationID
            applyServiceLocation(id: serviceLocationID)
        }
        selectedCustomerEquipmentID = equipment.id
        equipmentType = equipment.equipmentType ?? .splitSystemAC
        equipmentName = equipment.name
        equipmentManufacturer = equipment.manufacturer ?? ""
        equipmentModel = equipment.modelNumber ?? ""
        equipmentSerialNumber = equipment.serialNumber ?? ""
        equipmentLocation = equipment.location ?? ""
        filterSize = equipment.filterSize ?? ""
        equipmentNotes = equipment.notes ?? ""
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

    private func applyServiceLocation(id: UUID?) {
        guard let customer else { return }
        if let location = CustomerServiceLocationPolicy.location(id: id, customerID: customer.id, in: serviceLocations) {
            siteAddress = location.address
            if let selectedCustomerEquipmentID,
               let equipment = selectedCustomerEquipmentProfiles.first(where: { $0.id == selectedCustomerEquipmentID }),
               let equipmentLocationID = equipment.serviceLocationID,
               equipmentLocationID != location.id {
                self.selectedCustomerEquipmentID = nil
            }
        } else if id == nil {
            siteAddress = customer.address ?? siteAddress
        }
    }

    private func saveChanges() {
        guard AppAccess.canPerformScheduleMutation(
            .editServiceCall,
            email: AppIdentity.currentEmail,
            users: users
        ) else {
            dismiss()
            return
        }
        guard equipmentLifecycleSnapshot.validationMessage == nil else { return }
        guard !workLogBlocksRequestedStatus else { return }
        guard let customer else { return }
        guard !serviceRestrictionBlocksSave else { return }
        let originalStart = call.scheduledDate
        let originalArrivalWindow = call.promisedArrivalWindowSummary
        let originalStatus = call.status
        let originalDispatchUrgency = call.dispatchUrgency
        let originalTechnician = call.assignedTechnician?.name
        let originalCrewIDs = call.additionalTechnicianIDs
        let preserveExternalCalendarDetails = GoogleCalendarScheduleSync.shouldPreserveExternalGoogleCalendarDetails(for: call)
        call.type = callType
        call.dispatchUrgency = dispatchUrgency
        if !preserveExternalCalendarDetails {
            call.eventTitle = eventTitle.nilIfBlank
        }
        call.customer = customer
        call.assignedTechnician = technician
        call.additionalTechnicianIDs = crewMemberIDs
        call.status = status
        if status == .cancelled {
            call.cancelledAt = call.cancelledAt ?? Date()
            call.cancellationReason = cancellationReason.nilIfBlank
        }
        if GoogleCalendarScheduleSync.shouldSelectGoogleCalendarBeforeCreate(for: call) {
            call.googleCalendarID = ServiceCalendarRouting.validSelection(
                selectedCalendarID,
                technician: technician,
                calendars: accessibleCalendars
            )
        }
        if !preserveExternalCalendarDetails {
            call.siteAddress = siteAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? customer.address : siteAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            call.serviceLocationID = selectedServiceLocationID
        }
        call.equipmentName = equipmentName.nilIfBlank
        call.equipmentManufacturer = equipmentManufacturer.nilIfBlank
        call.equipmentModel = equipmentModel.nilIfBlank
        call.equipmentSerialNumber = equipmentSerialNumber.nilIfBlank
        call.equipmentLocation = equipmentLocation.nilIfBlank
        call.equipmentType = equipmentType
        call.equipmentNotes = equipmentNotes.nilIfBlank
        call.filterSize = filterSize.nilIfBlank
        call.equipmentInstallDate = includeInstallDate ? equipmentInstallDate : nil
        call.equipmentWarrantyExpiration = includeWarrantyExpiration ? equipmentWarrantyExpiration : nil
        call.customerEquipmentID = selectedCustomerEquipmentID
        if let selectedCustomerEquipmentID,
           let equipment = selectedCustomerEquipmentProfiles.first(where: { $0.id == selectedCustomerEquipmentID }) {
            equipment.applyTechnicalBaselines(to: call)
        }
        call.scheduledDate = scheduledTime
        call.duration = duration
        call.promisedArrivalWindowStart = usesArrivalWindow ? arrivalWindowStart : nil
        call.promisedArrivalWindowEnd = usesArrivalWindow ? arrivalWindowEnd : nil
        if !preserveExternalCalendarDetails {
            call.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        call.findingsSummary = findingsSummary.nilIfBlank
        call.recommendedWorkSummary = recommendedWorkSummary.nilIfBlank
        call.visitDisposition = visitDisposition
        call.visitDispositionNotes = visitDisposition == .standard ? nil : visitDispositionNotes.nilIfBlank
        call.correctiveWorkReason = (visitDisposition == .warranty || visitDisposition == .callback) ? correctiveWorkReason : nil
        call.followUpRequired = followUpRequired
        call.followUpAction = followUpRequired ? followUpAction.nilIfBlank : nil
        call.followUpDueDate = followUpRequired ? followUpDueDate : nil

        if status == .inProgress && call.documentationStartedAt == nil {
            call.documentationStartedAt = Date()
        }
        if status == .completed || status == .invoiced {
            call.markDocumentationCompleteIfReady()
            call.completeLinkedMaintenanceAgreementIfNeeded()
        }
        let actorEmail = AppIdentity.currentEmail
        if originalStart != scheduledTime {
            ServiceCallActivity.record(for: call, action: "Appointment rescheduled", detail: "Moved from \(originalStart.formatted(date: .abbreviated, time: .shortened)) to \(scheduledTime.formatted(date: .abbreviated, time: .shortened)).", actorEmail: actorEmail, in: modelContext)
        }
        if originalArrivalWindow != call.promisedArrivalWindowSummary {
            let detail = call.promisedArrivalWindowSummary.map { "Customer arrival window set to \($0)." } ?? "Customer arrival window cleared."
            ServiceCallActivity.record(for: call, action: "Customer arrival window updated", detail: detail, actorEmail: actorEmail, in: modelContext)
        }
        if originalTechnician != technician?.name {
            let detail = technician.map { "Assigned to \($0.name)." } ?? "Technician assignment cleared."
            ServiceCallActivity.record(for: call, action: "Technician assignment updated", detail: detail, actorEmail: actorEmail, in: modelContext)
        }
        if originalCrewIDs != call.additionalTechnicianIDs {
            let crewNames = assignableTechnicians
                .filter { call.additionalTechnicianIDs.contains($0.id) }
                .map(\.name)
            let detail = crewNames.isEmpty ? "Additional crew cleared." : "Additional crew: \(crewNames.joined(separator: ", "))."
            ServiceCallActivity.record(for: call, action: "Job crew updated", detail: detail, actorEmail: actorEmail, in: modelContext)
        }
        if originalStatus != status {
            let detail = status == .cancelled && !cancellationReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Status changed from \(originalStatus.rawValue) to cancelled. Reason: \(cancellationReason.trimmingCharacters(in: .whitespacesAndNewlines))."
                : "Status changed from \(originalStatus.rawValue) to \(status.rawValue)."
            ServiceCallActivity.record(for: call, action: status == .cancelled ? "Job cancelled" : "Job status updated", detail: detail, actorEmail: actorEmail, in: modelContext)
        }
        if originalDispatchUrgency != dispatchUrgency {
            ServiceCallActivity.record(for: call, action: "Dispatch priority updated", detail: "Priority changed from \(originalDispatchUrgency.displayName) to \(dispatchUrgency.displayName).", actorEmail: actorEmail, in: modelContext)
        }
        let shouldPublishCalendarChanges = GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: call)
        if shouldPublishCalendarChanges {
            GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(call)
        }
        try? modelContext.save()
        if status == .cancelled {
            cancelManagedGoogleCalendarEvent(for: call)
        } else if shouldPublishCalendarChanges {
            publishToGoogleCalendar(call)
        }
        dismiss()
    }

    private func publishToGoogleCalendar(_ call: ServiceCall) {
        guard googleAuth.isAuthenticated else { return }
        let signedInEmail = AppIdentity.currentEmail
        GoogleCalendarScheduleSync.exportImmediately(
            call: call,
            auth: googleAuth,
            modelContext: modelContext,
            signedInEmail: signedInEmail,
            isAdminUser: isAdminUser
        )
    }

    private func cancelManagedGoogleCalendarEvent(for call: ServiceCall) {
        guard googleAuth.isAuthenticated else { return }
        GoogleCalendarScheduleSync.cancelManagedEventImmediately(
            for: call,
            auth: googleAuth,
            modelContext: modelContext
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
        guard GoogleAuthManager.shared.isAuthenticated else {
            return
        }
        if let googleEmail = GoogleAuthManager.shared.signedInEmail {
            guard GoogleAccountLinkPolicy.canUseIntegration(
                primaryBusinessEmail: AppIdentity.currentEmail,
                googleEmail: googleEmail
            ) else {
                GoogleAuthManager.shared.signOut()
                isGoogleAuthenticated = false
                presentAuthAlert(
                    title: "Google Account Needs Attention",
                    message: GoogleAuthError.businessAccountMismatch.localizedDescription
                )
                return
            }
            isGoogleAuthenticated = true
            renewGoogleApplicationSessionIfNeeded()
            return
        }
        GoogleAuthManager.shared.validateSignedInDomain { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let profile):
                    isGoogleAuthenticated = true
                    renewGoogleApplicationSessionIfNeeded(profile: profile)
                case .failure(let error):
                    isGoogleAuthenticated = false
                    presentAuthAlert(title: "Google Account Needs Attention", message: error.localizedDescription)
                }
            }
        }
    }

    private func renewGoogleApplicationSessionIfNeeded(profile: GoogleUserProfile? = nil) {
        guard Config.Backend.usesBusinessIdentity,
              GoogleAuthManager.shared.applicationSessionToken == nil else { return }
        if let profile {
            establishRenewedGoogleApplicationSession(profile)
            return
        }
        GoogleAuthManager.shared.validateSignedInDomain { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let profile):
                    establishRenewedGoogleApplicationSession(profile)
                case .failure(let error):
                    presentAuthAlert(title: "Google Account Needs Attention", message: error.localizedDescription)
                }
            }
        }
    }

    private func establishRenewedGoogleApplicationSession(_ profile: GoogleUserProfile) {
        Task { @MainActor in
            do {
                let remoteUser = try await GoogleAuthManager.shared.establishBusinessApplicationSession(for: profile)
                _ = GunnAireBackendService.applyVerifiedUser(
                    remoteUser,
                    into: modelContext,
                    currentUsers: users,
                    technicians: technicians
                )
            } catch {
                // Preserve offline access to already-synchronized local work,
                // but keep shared-server actions visibly unavailable until the
                // revocable business session can be renewed.
                presentAuthAlert(
                    title: "Shared Business Session Needs Attention",
                    message: "Local work remains available. Reconnect to the internet and sign in with Google again before using shared server or QuickBooks actions. \(error.localizedDescription)"
                )
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
        .environmentObject(GunnAireCloudKitEventMonitor(isEnabled: false))
}

#Preview("Canvas Sanity") {
    Text("Canvas is rendering.")
        .padding()
}
