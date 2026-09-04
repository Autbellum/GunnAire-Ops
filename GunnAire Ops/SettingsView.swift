import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AVKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var cloudKitEventMonitor: GunnAireCloudKitEventMonitor
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @ObservedObject private var staffNotifications = StaffPushNotificationManager.shared

    @Binding var isQuickBooksAuthenticated: Bool
    @Binding var isGoogleAuthenticated: Bool
    let authenticateQuickBooks: () -> Void
    let authenticateGoogle: () -> Void
    let disconnectQuickBooks: () -> Void
    let disconnectGoogle: () -> Void
    let signOutOfApp: () -> Void
    let dismiss: () -> Void

    @State private var newUserEmail = ""
    @State private var newUserRole: AppUserRole = .fieldTechnician
    @State private var userAdminMessage: String?
    @State private var selectedSettingsPage: SettingsPage = .company
    @State private var showingSplashVideoImporter = false
    @State private var showingSplashVideoPreview = false
    @State private var showingSplashLaunchSimulation = false
    @State private var splashVideoMessage: String?
    @State private var splashVideoStatus = SplashVideoLocator.currentSource()
    @State private var splashVideoDetails: SplashVideoLocator.VideoDetails?
    @State private var quickBooksConnectionMessage: String?
    @State private var resettingQuickBooksConnection = false
    @State private var isSyncingSharedUsers = false
    @State private var backendAuditEvents: [BackendAuditEventRecord] = []
    @State private var isLoadingBackendAudit = false
    @State private var backendAuditMessage: String?
    @State private var backendReadiness: BackendReadinessSnapshot?
    @State private var isLoadingBackendReadiness = false
    @State private var backendReadinessMessage: String?
    @State private var showingBackendReadinessDetails = false
    @State private var showingFieldFormTemplates = false
    @State private var showingCustomerPortalLinks = false
    @State private var cloudKitReadiness: GunnAireCloudKit.AccountReadiness = .couldNotDetermine

    @AppStorage("companyName") private var companyName = "GunnAire"
    @AppStorage("dispatchStartHour") private var dispatchStartHour = 8
    @AppStorage("dispatchEndHour") private var dispatchEndHour = 17
    @AppStorage("defaultJobDurationMinutes") private var defaultJobDurationMinutes = 90
    @AppStorage("enableSplashVideo") private var enableSplashVideo = true
    @AppStorage("maximumSplashDurationSeconds") private var maximumSplashDurationSeconds = 6.0
    @AppStorage("allowSplashTapToSkip") private var allowSplashTapToSkip = true
    @AppStorage("requireTechnicianClockIn") private var requireTechnicianClockIn = true
    @AppStorage("requireJobCompletionChecklist") private var requireJobCompletionChecklist = true
    @AppStorage("requireWorkPerformedLogForCloseout") private var requireWorkPerformedLogForCloseout = true
    @AppStorage("requireCustomerSignature") private var requireCustomerSignature = true
    @AppStorage("enableCustomerNotifications") private var enableCustomerNotifications = true
    @AppStorage("enableDispatchBoard") private var enableDispatchBoard = true
    @AppStorage("enableRoutePlanning") private var enableRoutePlanning = true
    @AppStorage("enableRecurringMaintenance") private var enableRecurringMaintenance = true
    @AppStorage("enableEquipmentTracking") private var enableEquipmentTracking = true
    @AppStorage("enableInventoryTracking") private var enableInventoryTracking = true
    @AppStorage("enablePricebook") private var enablePricebook = true
    @AppStorage("enableGoodBetterBestEstimates") private var enableGoodBetterBestEstimates = true
    @AppStorage("enableOnsitePayments") private var enableOnsitePayments = false
    @AppStorage("defaultInvoicePaymentTerms") private var defaultInvoicePaymentTermsRawValue = InvoicePaymentTerms.dueOnReceipt.rawValue
    @AppStorage("onsitePaymentProcessor") private var onsitePaymentProcessor = OnsitePaymentProcessor.none.rawValue
    @AppStorage("onsitePaymentProcessorReady") private var onsitePaymentProcessorReady = false
    @AppStorage("enablePhotoDocumentation") private var enablePhotoDocumentation = true
    @AppStorage("enableOfflineMode") private var enableOfflineMode = false
    @AppStorage("enableReportingDashboard") private var enableReportingDashboard = true
    @AppStorage("enableMarketingCampaigns") private var enableMarketingCampaigns = false
    @AppStorage("customerReviewURL") private var customerReviewURL = ""
    @AppStorage("enableCustomerPortal") private var enableCustomerPortal = false

    private var currentUserEmail: String? {
        AppIdentity.currentEmail
    }

    private var isAdminUser: Bool {
        AppAccess.isAdmin(email: currentUserEmail, users: users)
    }

    private var currentUserRole: AppUserRole? {
        AppAccess.activeRole(email: currentUserEmail, users: users)
    }

    private var currentRoleAccessSummary: String {
        switch currentUserRole {
        case .standard:
            return "Standard access includes the command center, time clock, schedule, customer review, and onsite documentation."
        case .fieldTechnician:
            return "Field Technician access is limited to assigned jobs, field documentation, job materials, invoices, collections, and receipt capture."
        case .dispatcher:
            return "Dispatcher access includes scheduling, customer records, estimates, mail, and service coordination without accounting administration."
        case .accounting:
            return "Accounting access includes customer review, invoices, payments, reports, receipts, and team-time approval without dispatch or integration administration."
        case .admin:
            return "Administrator access includes company configuration, shared-user management, integrations, and QuickBooks controls."
        case nil:
            return "This account does not currently have one active, unambiguous business role. Ask an administrator to refresh access."
        }
    }

    private var quickBooksTimeMappedTechnicianCount: Int {
        technicians.filter { $0.quickBooksTimeMapping != nil }.count
    }

    private var quickBooksTimeMappingsReady: Bool {
        !technicians.isEmpty && quickBooksTimeMappedTechnicianCount == technicians.count
    }

    private var onsitePaymentConfigurationReady: Bool {
        !enableOnsitePayments || OnsitePaymentManager.shared.processorReady()
    }

    private var splashLaunchBehaviorDescription: String {
        guard enableSplashVideo else { return "Disabled. The app will open straight to the main UI." }
        guard SplashVideoLocator.resolveURL() != nil else { return "No MP4 found. The app will show the logo briefly." }
        return "Plays \(splashVideoStatus.description) and opens the app after playback or \(maximumSplashDurationSeconds.formatted(.number.precision(.fractionLength(0...1)))) seconds."
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: isAdminUser ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                            .font(.title2)
                            .foregroundColor(Color.brandGold)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(currentUserEmail ?? "Signed in")
                                .font(.headline)
                            Text(currentUserRole?.rawValue ?? "Access Pending")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if isAdminUser {
                    Section {
                        Picker("Settings Area", selection: $selectedSettingsPage) {
                            ForEach(SettingsPage.allCases) { page in
                                Label(page.title, systemImage: page.systemImage).tag(page)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    switch selectedSettingsPage {
                    case .company:
                        Section("Company") {
                            LabelTextField(title: "Company Name", text: $companyName, systemImage: "building.2")
                            Stepper("Dispatch day starts at \(dispatchStartHour):00", value: $dispatchStartHour, in: 0...23)
                            Stepper("Dispatch day ends at \(dispatchEndHour):00", value: $dispatchEndHour, in: 1...24)
                            Stepper("Default job duration: \(defaultJobDurationMinutes) minutes", value: $defaultJobDurationMinutes, in: 15...480, step: 15)
                        }

                        Section("Operational Readiness") {
                            readinessRow(title: "Users and roles", isComplete: !users.isEmpty)
                            readinessRow(title: "QuickBooks connected", isComplete: isQuickBooksAuthenticated)
                            readinessRow(
                                title: "Google Calendar, Gmail & Drive authorized",
                                isComplete: isGoogleAuthenticated && googleAuth.googleDriveAuthorizationState == .ready
                            )
                            readinessRow(
                                title: "CloudKit on this device",
                                isComplete: cloudKitReadiness.isReady && !cloudKitEventMonitor.state.needsAttention
                            )
                            readinessRow(title: "Pricebook enabled", isComplete: enablePricebook)
                            readinessRow(
                                title: "Technician workflow configured",
                                isComplete: requireTechnicianClockIn && requireJobCompletionChecklist && requireWorkPerformedLogForCloseout
                            )
                            readinessRow(title: "Payments configured", isComplete: onsitePaymentConfigurationReady)
                        }

                        Section("App Loading Video") {
                            Toggle("Play Splash Video On Launch", isOn: $enableSplashVideo)

                            Stepper(
                                "Maximum Splash Playback: \(maximumSplashDurationSeconds.formatted(.number.precision(.fractionLength(0...1)))) seconds",
                                value: $maximumSplashDurationSeconds,
                                in: 1.5...8.0,
                                step: 0.5
                            )

                            Toggle("Allow Tap To Skip", isOn: $allowSplashTapToSkip)

                            HStack {
                                Text("Current Splash")
                                Spacer()
                                Text(splashVideoStatus.description)
                                    .foregroundColor(.secondary)
                            }

                            HStack(alignment: .top) {
                                Text("Launch Behavior")
                                Spacer()
                                Text(splashLaunchBehaviorDescription)
                                    .multilineTextAlignment(.trailing)
                                    .foregroundColor(.secondary)
                            }

                            if let splashVideoDetails {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(splashVideoDetails.filename)
                                        .font(.subheadline)
                                    Text("Size: \(splashVideoDetails.fileSizeDescription)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("Updated: \(splashVideoDetails.modifiedDescription)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    if let durationDescription = splashVideoDetails.durationDescription {
                                        Text("Duration: \(durationDescription)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if let resolutionDescription = splashVideoDetails.resolutionDescription {
                                        Text("Resolution: \(resolutionDescription)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if let advisoryMessage = splashVideoDetails.advisoryMessage {
                                        Text(advisoryMessage)
                                            .font(.caption)
                                            .foregroundColor(Color.brandGold)
                                    }
                                }
                            }

                            Button("Load Splash MP4") {
                                showingSplashVideoImporter = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)

                            Button("Preview Splash Video") {
                                showingSplashVideoPreview = true
                            }
                            .buttonStyle(.bordered)
                            .disabled(SplashVideoLocator.resolveURL() == nil)

                            Button("Simulate App Launch") {
                                showingSplashLaunchSimulation = true
                            }
                            .buttonStyle(.bordered)

                            if let splashVideoURL = SplashVideoLocator.resolveURL() {
                                ShareLink(item: splashVideoURL) {
                                    Label("Share Splash MP4", systemImage: "square.and.arrow.up")
                                }
                            }

                            Button("Remove Custom Splash Video", role: .destructive) {
                                removeSplashVideo()
                            }
                            .disabled(splashVideoStatus != .custom)

                            Button("Reset Splash Settings") {
                                resetSplashVideoSettings()
                            }
                            .buttonStyle(.bordered)

                            Text("The app will play `Loading.mp4` from app storage first, then a bundled video if one exists, and finally fall back to the logo.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text("Short videos are allowed to finish; longer videos are capped by the maximum playback setting above.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if let splashVideoMessage {
                                Text(splashVideoMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                    case .workflow:
                        Section("Field Service Modules") {
                            featureStatus("Dispatch Board", systemImage: "rectangle.3.group", detail: "Included in Schedule")
                            featureStatus("Route Planning", systemImage: "map", detail: "Calendar routing is included")
                            featureStatus("Recurring Maintenance", systemImage: "repeat", detail: "Included in Schedule")
                            featureStatus("Customer Equipment Tracking", systemImage: "wrench.and.screwdriver", detail: "Included in Customer records")
                            featureStatus("Inventory & Parts Tracking", systemImage: "shippingbox", detail: "Included in Receipts & Bills")
                            featureStatus("Fleet & Truck Readiness", systemImage: "car.2", detail: "Included in the Command Center")
                            featureStatus("Pricebook", systemImage: "list.bullet.rectangle", detail: "Included in estimates and invoices")
                            featureStatus("Good-Better-Best Estimates", systemImage: "square.stack.3d.up", detail: "Included in estimates")
                            Button {
                                showingFieldFormTemplates = true
                            } label: {
                                Label("Manage Field Form Templates", systemImage: "list.clipboard")
                            }
                            .accessibilityIdentifier("ManageFieldFormTemplates")
                            .accessibilityHint("Opens reusable service, repair, replacement, and maintenance forms")
                            settingsToggle("Photo & Document Capture", systemImage: "camera", isOn: $enablePhotoDocumentation)
                            featureStatus("Reporting Dashboard", systemImage: "chart.bar", detail: "Included in Command Center")
                        }

                        Section("Technician Workflow") {
                            settingsToggle("Require Technician Clock In", systemImage: "clock", isOn: $requireTechnicianClockIn)
                            if Config.QuickBooksTime.enabled {
                                Label(
                                    quickBooksTimeMappingsReady
                                        ? "QBO TimeActivity sync is mapped for all \(technicians.count) technicians."
                                        : "QBO TimeActivity mapping is complete for \(quickBooksTimeMappedTechnicianCount) of \(technicians.count) technicians.",
                                    systemImage: quickBooksTimeMappingsReady ? "checkmark.circle" : "exclamationmark.triangle"
                                )
                                .font(.caption)
                                .foregroundColor(quickBooksTimeMappingsReady ? .secondary : .orange)

                                Text("Edit each technician in Sync & Integrations and enter the exact QuickBooks Employee or Vendor ID. Completed entries reconcile their stable GunnAire marker before create and can be retried without silently switching workers.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            settingsToggle("Require Completion Checklist", systemImage: "checklist", isOn: $requireJobCompletionChecklist)
                            settingsToggle("Require Work-Performed Log", systemImage: "text.badge.checkmark", isOn: $requireWorkPerformedLogForCloseout)
                            settingsToggle("Require Customer Signature", systemImage: "signature", isOn: $requireCustomerSignature)
                            featureStatus("Customer Appointment Notifications", systemImage: "bell", detail: "Requires a connected messaging provider")
                            featureStatus("Offline Field Mode", systemImage: "wifi.slash", detail: OperationalDataContinuity.offlineRecoveryDetail)
                            featureStatus(
                                "Cross-Device Operations",
                                systemImage: cloudKitReadiness.isReady && !cloudKitEventMonitor.state.needsAttention
                                    ? "externaldrive.badge.checkmark"
                                    : "externaldrive.badge.exclamationmark",
                                detail: "CloudKit account: \(cloudKitReadiness.statusTitle). \(cloudKitReadiness.userFacingDetail) \(cloudKitEventMonitor.state.operatorStatusDetail) \(OperationalDataContinuity.currentStatusDetail)"
                            )
                        }

                        Section("Sales & Payments") {
                            Picker("Default Invoice Terms", selection: $defaultInvoicePaymentTermsRawValue) {
                                ForEach(InvoicePaymentTerms.allCases.filter { $0 != .custom }) { terms in
                                    Text(terms.displayName).tag(terms.rawValue)
                                }
                            }
                            .accessibilityIdentifier("DefaultInvoicePaymentTerms")
                            Text("Each invoice can override this setting. The selected due date is shared with QuickBooks and every overdue workflow.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            settingsToggle("On-Site Payment Processing", systemImage: "creditcard", isOn: $enableOnsitePayments)
                            featureStatus(
                                "Customer Financing",
                                systemImage: "dollarsign.circle",
                                detail: "Configured on the authenticated backend. When an approved provider is ready, eligible estimates offer a provider-hosted application without storing applicant or credit data in GunnAire Ops."
                            )
                            settingsToggle("Marketing Campaigns", systemImage: "megaphone", isOn: $enableMarketingCampaigns)
                            if enableMarketingCampaigns {
                                TextField("Review request URL", text: $customerReviewURL)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                Text("Use an HTTPS link to the business's approved review destination. Review drafts appear only for completed jobs when this URL and the customer's marketing consent are both present.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            featureStatus("Customer Portal", systemImage: "person.text.rectangle", detail: "Requires a deployed customer portal")

                            if enableOnsitePayments {
                                if OnsitePaymentManager.shared.tapToPayAvailableInCurrentBuild {
                                    Picker("Tap to Pay on iPhone Processor", selection: $onsitePaymentProcessor) {
                                        ForEach(OnsitePaymentManager.shared.availableProcessors()) { processor in
                                            Text(processor.displayName).tag(processor.rawValue)
                                        }
                                    }
                                    Toggle("Processor Ready on This Device", isOn: $onsitePaymentProcessorReady)
                                    let selectedProcessor = OnsitePaymentProcessor(rawValue: onsitePaymentProcessor) ?? .none
                                    Text(selectedProcessor == .none
                                         ? "Choose the live processor for Tap to Pay on iPhone."
                                         : OnsitePaymentManager.shared.processorStatusDetail())
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("Card and check payments can be recorded in GunnAire Ops. For contactless payment, hand off to a field iPhone and use QuickBooks Mobile or GoPayment; Intuit provides Tap to Pay on iPhone in those apps rather than an embedded custom-app flow.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                    case .integrations:
                        integrationsSections

                    case .users:
                        Section("Application Users") {
                            LabeledContent("Shared Backend") {
                                Text(GunnAireBackendService.isConfigured ? Config.Backend.displayHost : "Not configured")
                                    .foregroundColor(GunnAireBackendService.isConfigured ? .secondary : .orange)
                            }

                            HStack {
                                TextField("user@gunnaire.com", text: $newUserEmail)
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.emailAddress)
                                Picker("Role", selection: $newUserRole) {
                                    ForEach(AppUserRole.allCases) { role in
                                        Text(role.rawValue).tag(role)
                                    }
                                }
                                .labelsHidden()
                            }

                            Button {
                                addUser()
                            } label: {
                                Label("Add User", systemImage: "person.badge.plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)

                            Button {
                                Task {
                                    await refreshSharedUsers(showSuccess: true)
                                }
                            } label: {
                                Label(isSyncingSharedUsers ? "Syncing Users..." : "Sync Users From Mac Studio", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSyncingSharedUsers || !GunnAireBackendService.isConfigured)

                            if !GunnAireBackendService.isConfigured {
                                Text("Set GUNNAIRE_BACKEND_BASE_URL and GUNNAIRE_BACKEND_API_TOKEN to let every iPad use the same approved user list.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if let userAdminMessage {
                                Text(userAdminMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Section("Active Users") {
                            ForEach(users) { user in
                                HStack {
                                    Image(systemName: roleIcon(for: user.role))
                                        .foregroundColor(user.role == .admin ? Color.brandGold : .secondary)
                                    VStack(alignment: .leading) {
                                        Text(user.email)
                                        Text(user.role.rawValue)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Toggle("Active", isOn: Binding(
                                        get: { user.isActive },
                                        set: { isActive in
                                            user.isActive = isActive
                                            if isActive && AppAccess.shouldProvisionTechnicianRecord(for: user.role) {
                                                AppAccess.ensureTechnicianRecord(for: user.email, technicians: technicians, modelContext: modelContext)
                                            }
                                            syncSharedUser(email: user.email, role: user.role, isActive: isActive)
                                        }
                                    ))
                                    .labelsHidden()
                                    .disabled(user.email == AppAccess.primaryAdminEmail)
                                }
                            }
                            .onDelete(perform: deleteUsers)
                        }
                    }
                } else {
                    Section("Account") {
                        Text(currentUserEmail ?? "Signed in")
                        Text(currentRoleAccessSummary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Staff Notifications") {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Label("Assignment Alerts", systemImage: staffNotifications.statusSystemImage)
                        Spacer()
                        if staffNotifications.isProcessing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(staffNotifications.statusTitle)
                            .foregroundColor(staffNotifications.isReady ? .green : .secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("StaffNotificationsStatus")

                    Text(staffNotifications.statusDetail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if staffNotifications.isDenied {
                        HStack {
                            Button("Open Apple Notification Settings") {
                                staffNotifications.openAppleNotificationSettings()
                            }
                            .accessibilityIdentifier("OpenStaffNotificationSettings")

                            if staffNotifications.isEnabledForDisplay {
                                Button("Turn Off", role: .destructive) {
                                    Task { await staffNotifications.disableForCurrentAccount() }
                                }
                                .disabled(staffNotifications.isProcessing)
                                .accessibilityIdentifier("DisableStaffNotifications")
                            }
                        }
                    } else if staffNotifications.hasPendingServerDeactivation {
                        Button("Retry Server Removal") {
                            Task { await staffNotifications.retry() }
                        }
                        .disabled(staffNotifications.isProcessing)
                        .accessibilityIdentifier("RetryStaffNotificationRemoval")
                    } else if staffNotifications.isReady {
                        Button("Turn Off Staff Alerts", role: .destructive) {
                            Task { await staffNotifications.disableForCurrentAccount() }
                        }
                        .disabled(staffNotifications.isProcessing)
                        .accessibilityIdentifier("DisableStaffNotifications")
                    } else if staffNotifications.isEnabledForDisplay {
                        HStack {
                            Button("Retry") {
                                Task { await staffNotifications.retry() }
                            }
                            .disabled(staffNotifications.isProcessing)
                            .accessibilityIdentifier("RetryStaffNotifications")

                            Button("Turn Off", role: .destructive) {
                                Task { await staffNotifications.disableForCurrentAccount() }
                            }
                            .disabled(staffNotifications.isProcessing)
                            .accessibilityIdentifier("DisableStaffNotifications")
                        }
                    } else {
                        Button("Enable Staff Alerts") {
                            Task { await staffNotifications.enableForCurrentAccount() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(staffNotifications.isProcessing)
                        .accessibilityIdentifier("EnableStaffNotifications")
                    }
                }

                Section("Application") {
                    Button("Sign Out of App", role: .destructive) {
                        signOutOfApp()
                    }
                }
            }
            .accessibilityIdentifier("SettingsForm")
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showingSplashVideoImporter,
                allowedContentTypes: [.mpeg4Movie, .movie],
                allowsMultipleSelection: false
            ) { result in
                handleSplashVideoImport(result)
            }
            .sheet(isPresented: $showingSplashVideoPreview) {
                SplashVideoPreviewSheet()
            }
            .sheet(isPresented: $showingFieldFormTemplates) {
                FieldFormTemplateManagerView()
                    .tint(Color.brandGold)
            }
            .sheet(isPresented: $showingCustomerPortalLinks) {
                CustomerPortalLinkManagerView()
                    .tint(Color.brandGold)
            }
            .fullScreenCover(isPresented: $showingSplashLaunchSimulation) {
                SplashLaunchSimulationSheet()
            }
            .task {
                refreshSplashVideoState(loadDetails: true)
                syncUserTechnicians()
                await refreshSharedUsers(showSuccess: false)
                await refreshCloudKitReadiness()
            }
        }
    }

    private func roleIcon(for role: AppUserRole) -> String {
        switch role {
        case .admin: "person.crop.circle.badge.checkmark"
        case .fieldTechnician: "wrench.and.screwdriver"
        case .dispatcher: "calendar.badge.clock"
        case .accounting: "chart.line.uptrend.xyaxis"
        case .standard: "person.crop.circle"
        }
    }

    @ViewBuilder
    private func settingsToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
        }
    }

    private func featureStatus(_ title: String, systemImage: String, detail: String) -> some View {
        LabeledContent {
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func refreshCloudKitReadiness() async {
        cloudKitReadiness = await GunnAireCloudKit.accountReadiness()
    }

    @ViewBuilder
    private var integrationsSections: some View {
        Section(isAdminUser ? "Administrator Sync Accounts" : "Sync Accounts") {
            Text(isAdminUser
                 ? "QuickBooks and Google sync are configured from this screen."
                 : "Shared integrations are managed by an administrator. Your login uses the company sync connection.")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Section("QuickBooks") {
            connectionStatusRow(title: "Status", isConnected: isQuickBooksAuthenticated)
            Text(QuickBooksDataAPI.shared.connectionDiagnosticSummary)
                .font(.caption)
                .foregroundColor(.secondary)

            if isAdminUser {
                if isQuickBooksAuthenticated {
                    Button("Disconnect QuickBooks", role: .destructive) {
                        disconnectQuickBooks()
                        isQuickBooksAuthenticated = false
                    }
                } else {
                    Button {
                        authenticateQuickBooks()
                    } label: {
                        Label("Connect QuickBooks", systemImage: "link")
                    }
                }

                Button {
                    resetAndReconnectQuickBooks()
                } label: {
                    Label(resettingQuickBooksConnection ? "Resetting..." : "Reset and Reconnect QuickBooks", systemImage: "arrow.clockwise.circle")
                }
                .disabled(resettingQuickBooksConnection)

                Button("Validate QuickBooks Access") {
                    validateQuickBooksAccess()
                }
                .disabled(!QuickBooksDataAPI.shared.isAuthenticated)
            }

            if let refreshDetail = QuickBooksDataAPI.shared.lastRefreshFailureDetail {
                Text(refreshDetail)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            if let authorizationDetail = QuickBooksDataAPI.shared.lastAuthorizationFailureDetail {
                Text(authorizationDetail)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            if let scopeReauthorization = QuickBooksDataAPI.shared.scopeReauthorizationDiagnostic {
                Text(scopeReauthorization)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            if let paymentsAuthorization = QuickBooksDataAPI.shared.paymentsAuthorizationDiagnostic {
                Text(paymentsAuthorization)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            if let quickBooksConnectionMessage {
                Text(quickBooksConnectionMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        Section("Google") {
            connectionStatusRow(title: "Status", isConnected: isGoogleAuthenticated)

            if googleAuth.googleDriveAuthorizationState == .ready {
                Label("Calendar, Gmail, and per-file Drive archive access confirmed.", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(googleAuth.googleDriveAuthorizationState.detail)
                    .font(.caption)
                    .foregroundColor(
                        googleAuth.googleDriveAuthorizationState == .disconnected ? .secondary : .orange
                    )
            }

            if isAdminUser {
                if isGoogleAuthenticated {
                    Button("Disconnect Google", role: .destructive) {
                        disconnectGoogle()
                        isGoogleAuthenticated = false
                    }

                    if googleAuth.googleDriveAuthorizationState == .reauthorizationRequired ||
                        googleAuth.googleDriveAuthorizationState == .businessAccountMismatch {
                        Button {
                            disconnectGoogle()
                            isGoogleAuthenticated = false
                            authenticateGoogle()
                        } label: {
                            Label("Reconnect Google for Drive", systemImage: "arrow.clockwise.circle")
                        }
                        .accessibilityIdentifier("ReconnectGoogleForDrive")
                    }
                } else {
                    Button {
                        authenticateGoogle()
                    } label: {
                        Label("Connect Google", systemImage: "link")
                    }
                }
            }
        }

        if isAdminUser {
            Section("Shared Server Readiness") {
                Button {
                    refreshBackendReadiness()
                } label: {
                    Label(
                        isLoadingBackendReadiness ? "Checking Shared Server..." : "Refresh Readiness",
                        systemImage: "server.rack"
                    )
                }
                .disabled(isLoadingBackendReadiness || !GunnAireBackendService.isConfigured)
                .accessibilityIdentifier("BackendReadinessRefreshButton")

                if !GunnAireBackendService.isConfigured {
                    Label("Shared server is not configured for this build.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let backendReadiness {
                    LabeledContent("Overall") {
                        Label(
                            backendReadiness.isReady ? "Ready" : "(backendReadiness.attentionCount) need attention",
                            systemImage: backendReadiness.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(backendReadiness.isReady ? .green : .orange)
                    }
                    LabeledContent("Service Version", value: backendReadiness.serviceVersion)

                    DisclosureGroup("Readiness Details", isExpanded: $showingBackendReadinessDetails) {
                        ForEach(backendReadiness.components) { component in
                            backendReadinessRow(component)
                        }
                    }

                    Text("Checked (readinessCheckTime(backendReadiness.checkedAt)). A verified backup record proves the artifact passed integrity checks; operations must still retain a copy off-host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Readiness verifies persistent data placement, database and document writes, business authentication, the HTTPS customer portal, encrypted QuickBooks authorization, and recent backup evidence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let backendReadinessMessage {
                    Text(backendReadinessMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .task {
                if backendReadiness == nil { refreshBackendReadiness() }
            }

            Section("Customer Portal") {
                Button {
                    showingCustomerPortalLinks = true
                } label: {
                    Label("Manage Customer Portal Links", systemImage: "person.badge.key")
                }
                .disabled(!GunnAireBackendService.isConfigured)

                Text(GunnAireBackendService.isConfigured
                     ? "Review active, expired, and revoked link metadata. Capability URLs are never shown again after creation."
                     : "Configure the shared backend before managing customer portal links.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Shared Server Activity") {
                Button {
                    refreshBackendAuditEvents()
                } label: {
                    Label(isLoadingBackendAudit ? "Loading Activity..." : "Refresh Activity", systemImage: "clock.arrow.circlepath")
                }
                .disabled(isLoadingBackendAudit || !GunnAireBackendService.isConfigured)

                if !GunnAireBackendService.isConfigured {
                    Text("Configure the shared backend to review role, document, payment, communication, and QuickBooks authorization activity.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if backendAuditEvents.isEmpty {
                    Text("Refresh to review recent server activity. Sensitive values such as OAuth tokens and card details are never included.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(backendAuditEvents.prefix(8)) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.summary)
                                .font(.subheadline.weight(.medium))
                            Text("\(event.actorEmail) • \(event.occurredAt)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let backendAuditMessage {
                    Text(backendAuditMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func connectionStatusRow(title: String, isConnected: Bool) -> some View {
        HStack {
            Label(title, systemImage: isConnected ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundColor(isConnected ? .green : .secondary)
            Spacer()
            Text(isConnected ? "Connected" : "Not Connected")
                .foregroundColor(isConnected ? .green : .secondary)
        }
    }

    @ViewBuilder
    private func readinessRow(title: String, isComplete: Bool) -> some View {
        HStack {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isComplete ? .green : .secondary)
            Text(title)
            Spacer()
            Text(isComplete ? "Ready" : "Needed")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func addUser() {
        let email = AppAccess.normalizedEmail(newUserEmail)
        guard !email.isEmpty else {
            userAdminMessage = "Enter an email address first."
            return
        }
        guard email.hasSuffix("@gunnaire.com") else {
            userAdminMessage = "Users must have a gunnaire.com email address."
            return
        }
        guard !users.contains(where: { $0.email == email }) else {
            userAdminMessage = "\(email) is already added."
            return
        }
        let user = AppUser(email: email, role: newUserRole)
        modelContext.insert(user)
        if AppAccess.shouldProvisionTechnicianRecord(for: newUserRole) {
            AppAccess.ensureTechnicianRecord(for: email, technicians: technicians, modelContext: modelContext)
        }
        syncSharedUser(email: email, role: newUserRole, isActive: true)
        userAdminMessage = AppAccess.shouldProvisionTechnicianRecord(for: newUserRole)
            ? "Added \(email) as \(newUserRole.rawValue) and provisioned the technician calendar record."
            : "Added \(email) as \(newUserRole.rawValue)."
        newUserEmail = ""
        newUserRole = .fieldTechnician
    }

    private func syncUserTechnicians() {
        AppAccess.ensureTechnicianRecords(for: users, technicians: technicians, modelContext: modelContext)
    }

    private func refreshBackendAuditEvents() {
        guard GunnAireBackendService.isConfigured else { return }
        isLoadingBackendAudit = true
        backendAuditMessage = nil
        Task {
            do {
                let events = try await GunnAireBackendService.fetchAuditEvents()
                await MainActor.run {
                    backendAuditEvents = events
                    backendAuditMessage = events.isEmpty ? "No recorded shared-server activity yet." : "Showing the latest \(min(events.count, 8)) of \(events.count) events."
                    isLoadingBackendAudit = false
                }
            } catch {
                await MainActor.run {
                    backendAuditMessage = "Unable to load shared-server activity: \(error.localizedDescription)"
                    isLoadingBackendAudit = false
                }
            }
        }
    }

    private func refreshBackendReadiness() {
        guard GunnAireBackendService.isConfigured, !isLoadingBackendReadiness else { return }
        isLoadingBackendReadiness = true
        backendReadinessMessage = nil
        Task {
            do {
                let snapshot = try await GunnAireBackendService.fetchReadiness()
                await MainActor.run {
                    backendReadiness = snapshot
                    showingBackendReadinessDetails = !snapshot.isReady
                    isLoadingBackendReadiness = false
                }
            } catch {
                await MainActor.run {
                    backendReadinessMessage = "Unable to verify shared-server readiness: \(error.localizedDescription)"
                    isLoadingBackendReadiness = false
                }
            }
        }
    }

    private func backendReadinessRow(_ component: BackendReadinessComponent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: component.isReady ? "checkmark.circle.fill" : component.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(component.isReady ? .green : component.isError ? .red : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(component.title)
                    .font(.subheadline.weight(.semibold))
                Text(component.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func readinessCheckTime(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    @MainActor
    private func refreshSharedUsers(showSuccess: Bool) async {
        guard GunnAireBackendService.isConfigured else { return }
        isSyncingSharedUsers = true
        defer { isSyncingSharedUsers = false }
        do {
            let refreshedUsers = try await GunnAireBackendService.refreshUsers(
                into: modelContext,
                currentUsers: users,
                technicians: technicians
            )
            if showSuccess {
                userAdminMessage = "Synced \(refreshedUsers.count) shared user(s) from the Mac Studio backend."
            }
        } catch {
            userAdminMessage = "Shared user sync failed: \(error.localizedDescription)"
        }
    }

    private func syncSharedUser(email: String, role: AppUserRole, isActive: Bool) {
        guard GunnAireBackendService.isConfigured else { return }
        Task {
            do {
                try await GunnAireBackendService.upsertUser(email: email, role: role, isActive: isActive)
                await MainActor.run {
                    userAdminMessage = "Shared user access updated for \(email)."
                }
            } catch {
                await MainActor.run {
                    userAdminMessage = "Saved locally, but shared backend update failed for \(email): \(error.localizedDescription)"
                }
            }
        }
    }

    private func handleSplashVideoImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                splashVideoMessage = "No splash video was selected."
                return
            }
            do {
                let details = try SplashVideoLocator.installVideo(from: url)
                refreshSplashVideoState(loadDetails: false)
                splashVideoDetails = details
                splashVideoMessage = "Splash MP4 loaded successfully: \(details.durationDescription ?? "ready for launch")."
            } catch {
                splashVideoMessage = "Failed to load splash MP4: \(error.localizedDescription)"
            }
        case .failure(let error):
            splashVideoMessage = "Splash video import failed: \(error.localizedDescription)"
        }
    }

    private func removeSplashVideo() {
        do {
            try SplashVideoLocator.removeStoredVideo()
            refreshSplashVideoState(loadDetails: false)
            splashVideoMessage = "Custom splash MP4 removed."
        } catch {
            splashVideoMessage = "Failed to remove splash MP4: \(error.localizedDescription)"
        }
    }

    private func resetSplashVideoSettings() {
        enableSplashVideo = true
        maximumSplashDurationSeconds = 6.0
        allowSplashTapToSkip = true
        refreshSplashVideoState(loadDetails: true)
        splashVideoMessage = "Splash playback settings were reset to defaults."
    }

    private func resetAndReconnectQuickBooks() {
        resettingQuickBooksConnection = true
        quickBooksConnectionMessage = "Resetting the saved QuickBooks session..."
        QuickBooksDataAPI.shared.resetConnectionForReconnect { _ in
            DispatchQueue.main.async {
                resettingQuickBooksConnection = false
                isQuickBooksAuthenticated = false
                quickBooksConnectionMessage = "Saved QuickBooks session cleared. Starting a fresh production connection..."
                authenticateQuickBooks()
            }
        }
    }

    private func validateQuickBooksAccess() {
        quickBooksConnectionMessage = "Checking QuickBooks Accounting access..."
        QuickBooksDataAPI.shared.validateAccountingConnection { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let company):
                    let name = company.CompanyName ?? company.LegalName ?? company.Id ?? "the selected company"
                    quickBooksConnectionMessage = "QuickBooks Accounting access confirmed for \(name)."
                    isQuickBooksAuthenticated = true
                case .failure(let error):
                    quickBooksConnectionMessage = "QuickBooks Accounting access failed: \(error.localizedDescription)"
                    isQuickBooksAuthenticated = QuickBooksDataAPI.shared.isAuthenticated
                }
            }
        }
    }

    private func refreshSplashVideoState(loadDetails: Bool) {
        splashVideoStatus = SplashVideoLocator.currentSource()
        guard loadDetails else {
            if splashVideoStatus == .fallback {
                splashVideoDetails = nil
            }
            return
        }
        Task {
            let details = await SplashVideoLocator.currentResolvedVideoDetailsAsync()
            await MainActor.run {
                splashVideoDetails = details
            }
        }
    }

    private func deleteUsers(offsets: IndexSet) {
        for index in offsets {
            let user = users[index]
            if user.email != AppAccess.primaryAdminEmail {
                let email = user.email
                modelContext.delete(user)
                deactivateSharedUser(email: email)
            }
        }
    }

    private func deactivateSharedUser(email: String) {
        guard GunnAireBackendService.isConfigured else { return }
        Task {
            do {
                try await GunnAireBackendService.deactivateUser(email: email)
                await MainActor.run {
                    userAdminMessage = "Shared user access deactivated for \(email)."
                }
            } catch {
                await MainActor.run {
                    userAdminMessage = "Deleted locally, but shared backend deactivation failed for \(email): \(error.localizedDescription)"
                }
            }
        }
    }
}

private struct SplashVideoPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let url = SplashVideoLocator.resolveURL() {
                    VideoPlayer(player: player)
                        .background(Color.black)
                        .onAppear {
                            let player = AVPlayer(url: url)
                            player.isMuted = true
                            self.player = player
                            player.play()
                        }
                        .onDisappear {
                            player?.pause()
                            player = nil
                        }
                } else {
                    ContentUnavailableView(
                        "No Splash Video",
                        systemImage: "film",
                        description: Text("Load a `Loading.mp4` file or bundle one with the app to preview the splash video.")
                    )
                }
            }
            .navigationTitle("Splash Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SplashLaunchSimulationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var closeWorkItem: DispatchWorkItem?
    @AppStorage("enableSplashVideo") private var enableSplashVideo = true
    @AppStorage("maximumSplashDurationSeconds") private var maximumSplashDurationSeconds = 6.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if enableSplashVideo, let url = SplashVideoLocator.resolveURL() {
                VideoPlayer(player: player)
                    .background(Color.black)
                    .onAppear {
                        let player = AVPlayer(url: url)
                        player.isMuted = true
                        self.player = player
                        player.play()
                        scheduleDismiss(after: min(max(maximumSplashDurationSeconds, 1.2), 6.0))
                    }
                    .onDisappear {
                        cleanup()
                    }
            } else {
                VStack(spacing: 18) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220)
                    Text(enableSplashVideo ? "Logo fallback launch simulation" : "Splash video disabled")
                        .foregroundColor(.white.opacity(0.8))
                        .font(.headline)
                }
                .onAppear {
                    scheduleDismiss(after: 0.8)
                }
                .onDisappear {
                    cleanup()
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button("Close") {
                        dismiss()
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .padding()
                Spacer()
            }
        }
        .statusBarHidden()
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        closeWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            dismiss()
        }
        closeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cleanup() {
        closeWorkItem?.cancel()
        closeWorkItem = nil
        player?.pause()
        player = nil
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case company
    case workflow
    case integrations
    case users

    var id: String { rawValue }

    var title: String {
        switch self {
        case .company: return "Company"
        case .workflow: return "Workflow"
        case .integrations: return "Sync"
        case .users: return "Users"
        }
    }

    var systemImage: String {
        switch self {
        case .company: return "building.2"
        case .workflow: return "slider.horizontal.3"
        case .integrations: return "arrow.triangle.2.circlepath"
        case .users: return "person.2"
        }
    }
}

private struct LabelTextField: View {
    let title: String
    @Binding var text: String
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            TextField(title, text: $text)
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview {
    SettingsView(
        isQuickBooksAuthenticated: .constant(false),
        isGoogleAuthenticated: .constant(false),
        authenticateQuickBooks: {},
        authenticateGoogle: {},
        disconnectQuickBooks: {},
        disconnectGoogle: {},
        signOutOfApp: {},
        dismiss: {}
    )
    .environmentObject(GunnAireCloudKitEventMonitor(isEnabled: false))
}
