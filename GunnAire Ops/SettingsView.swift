import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AVKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared

    @Binding var isQuickBooksAuthenticated: Bool
    @Binding var isGoogleAuthenticated: Bool
    let authenticateQuickBooks: () -> Void
    let authenticateGoogle: () -> Void
    let disconnectQuickBooks: () -> Void
    let disconnectGoogle: () -> Void
    let signOutOfApp: () -> Void
    let dismiss: () -> Void

    @State private var newUserEmail = ""
    @State private var newUserRole: AppUserRole = .standard
    @State private var userAdminMessage: String?
    @State private var selectedSettingsPage: SettingsPage = .company
    @State private var showingSplashVideoImporter = false
    @State private var showingSplashVideoPreview = false
    @State private var showingSplashLaunchSimulation = false
    @State private var splashVideoMessage: String?
    @State private var splashVideoStatus = SplashVideoLocator.currentSourceDescription()
    @State private var splashVideoDetails = SplashVideoLocator.currentStoredVideoDetails()

    @AppStorage("companyName") private var companyName = "GunnAire"
    @AppStorage("dispatchStartHour") private var dispatchStartHour = 8
    @AppStorage("dispatchEndHour") private var dispatchEndHour = 17
    @AppStorage("defaultJobDurationMinutes") private var defaultJobDurationMinutes = 90
    @AppStorage("enableSplashVideo") private var enableSplashVideo = true
    @AppStorage("maximumSplashDurationSeconds") private var maximumSplashDurationSeconds = 6.0
    @AppStorage("requireTechnicianClockIn") private var requireTechnicianClockIn = true
    @AppStorage("requireJobCompletionChecklist") private var requireJobCompletionChecklist = true
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
    @AppStorage("onsitePaymentProcessor") private var onsitePaymentProcessor = OnsitePaymentProcessor.none.rawValue
    @AppStorage("onsitePaymentProcessorReady") private var onsitePaymentProcessorReady = false
    @AppStorage("enableFinancing") private var enableFinancing = false
    @AppStorage("enablePhotoDocumentation") private var enablePhotoDocumentation = true
    @AppStorage("enableOfflineMode") private var enableOfflineMode = false
    @AppStorage("enableReportingDashboard") private var enableReportingDashboard = true
    @AppStorage("enableMarketingCampaigns") private var enableMarketingCampaigns = false
    @AppStorage("enableCustomerPortal") private var enableCustomerPortal = false

    private var currentUserEmail: String? {
        googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail")
    }

    private var isAdminUser: Bool {
        AppAccess.isAdmin(email: currentUserEmail, users: users)
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
                            Text(isAdminUser ? "Administrator" : "Standard User")
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
                            readinessRow(title: "Google admin account connected", isComplete: isGoogleAuthenticated)
                            readinessRow(title: "Pricebook enabled", isComplete: enablePricebook)
                            readinessRow(title: "Technician workflow configured", isComplete: requireTechnicianClockIn && requireJobCompletionChecklist)
                            readinessRow(title: "Payments configured", isComplete: !enableOnsitePayments || isQuickBooksAuthenticated)
                        }

                        Section("App Loading Video") {
                            Toggle("Play Splash Video On Launch", isOn: $enableSplashVideo)

                            Stepper(
                                "Maximum Splash Playback: \(maximumSplashDurationSeconds.formatted(.number.precision(.fractionLength(0...1)))) seconds",
                                value: $maximumSplashDurationSeconds,
                                in: 1.5...8.0,
                                step: 0.5
                            )

                            HStack {
                                Text("Current Splash")
                                Spacer()
                                Text(splashVideoStatus)
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

                            Button("Remove Custom Splash Video", role: .destructive) {
                                removeSplashVideo()
                            }
                            .disabled(splashVideoStatus != "Custom Loading.mp4")

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
                            settingsToggle("Dispatch Board", systemImage: "rectangle.3.group", isOn: $enableDispatchBoard)
                            settingsToggle("Route Planning", systemImage: "map", isOn: $enableRoutePlanning)
                            settingsToggle("Recurring Maintenance", systemImage: "repeat", isOn: $enableRecurringMaintenance)
                            settingsToggle("Customer Equipment Tracking", systemImage: "wrench.and.screwdriver", isOn: $enableEquipmentTracking)
                            settingsToggle("Inventory & Parts Tracking", systemImage: "shippingbox", isOn: $enableInventoryTracking)
                            settingsToggle("Pricebook", systemImage: "list.bullet.rectangle", isOn: $enablePricebook)
                            settingsToggle("Good-Better-Best Estimates", systemImage: "square.stack.3d.up", isOn: $enableGoodBetterBestEstimates)
                            settingsToggle("Photo & Document Capture", systemImage: "camera", isOn: $enablePhotoDocumentation)
                            settingsToggle("Reporting Dashboard", systemImage: "chart.bar", isOn: $enableReportingDashboard)
                        }

                        Section("Technician Workflow") {
                            settingsToggle("Require Technician Clock In", systemImage: "clock", isOn: $requireTechnicianClockIn)
                            settingsToggle("Require Completion Checklist", systemImage: "checklist", isOn: $requireJobCompletionChecklist)
                            settingsToggle("Require Customer Signature", systemImage: "signature", isOn: $requireCustomerSignature)
                            settingsToggle("Customer Appointment Notifications", systemImage: "bell", isOn: $enableCustomerNotifications)
                            settingsToggle("Offline Field Mode", systemImage: "wifi.slash", isOn: $enableOfflineMode)
                        }

                        Section("Sales & Payments") {
                            settingsToggle("On-Site Payment Processing", systemImage: "creditcard", isOn: $enableOnsitePayments)
                            settingsToggle("Customer Financing", systemImage: "dollarsign.circle", isOn: $enableFinancing)
                            settingsToggle("Marketing Campaigns", systemImage: "megaphone", isOn: $enableMarketingCampaigns)
                            settingsToggle("Customer Portal", systemImage: "person.text.rectangle", isOn: $enableCustomerPortal)

                            if enableOnsitePayments {
                                Picker("Tap to Pay Processor", selection: $onsitePaymentProcessor) {
                                    ForEach(OnsitePaymentProcessor.allCases) { processor in
                                        Text(processor.displayName).tag(processor.rawValue)
                                    }
                                }

                                Toggle("Processor Ready on This Device", isOn: $onsitePaymentProcessorReady)

                                let selectedProcessor = OnsitePaymentProcessor(rawValue: onsitePaymentProcessor) ?? .none
                                Text(selectedProcessor == .simulated
                                     ? "Simulator mode is enabled for Tap to Pay workflow testing."
                                     : "Select the live processor SDK you intend to use and mark the device ready once it is configured.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                    case .integrations:
                        integrationsSections

                    case .users:
                        Section("Application Users") {
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

                            if let userAdminMessage {
                                Text(userAdminMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Section("Active Users") {
                            ForEach(users) { user in
                                HStack {
                                    Image(systemName: user.role == .admin ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
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
                                        set: { user.isActive = $0 }
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
                        Text("Google and QuickBooks connections can be managed here. Company workflow and user management remain admin-only.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    integrationsSections
                }

                Section("Application") {
                    Button("Sign Out of App", role: .destructive) {
                        signOutOfApp()
                    }
                }
            }
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
            .fullScreenCover(isPresented: $showingSplashLaunchSimulation) {
                SplashLaunchSimulationSheet()
            }
        }
    }

    @ViewBuilder
    private func settingsToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
        }
    }

    @ViewBuilder
    private var integrationsSections: some View {
        if isAdminUser {
            Section("Administrator Sync Accounts") {
                Text("QuickBooks and Google sync are configured from this screen.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else {
            Section("Sync Accounts") {
                Text("These connection settings are editable regardless of app role because the underlying Google and QuickBooks access is granted by the connected account.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        Section("QuickBooks") {
            connectionStatusRow(title: "Status", isConnected: isQuickBooksAuthenticated)

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
        }

        Section("Google") {
            connectionStatusRow(title: "Status", isConnected: isGoogleAuthenticated)

            if isGoogleAuthenticated {
                Button("Disconnect Google", role: .destructive) {
                    disconnectGoogle()
                    isGoogleAuthenticated = false
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
        modelContext.insert(AppUser(email: email, role: newUserRole))
        userAdminMessage = "Added \(email) as \(newUserRole.rawValue)."
        newUserEmail = ""
        newUserRole = .standard
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
                refreshSplashVideoState()
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
            refreshSplashVideoState()
            splashVideoMessage = "Custom splash MP4 removed."
        } catch {
            splashVideoMessage = "Failed to remove splash MP4: \(error.localizedDescription)"
        }
    }

    private func refreshSplashVideoState() {
        splashVideoStatus = SplashVideoLocator.currentSourceDescription()
        splashVideoDetails = SplashVideoLocator.currentStoredVideoDetails()
    }

    private func deleteUsers(offsets: IndexSet) {
        for index in offsets {
            let user = users[index]
            if user.email != AppAccess.primaryAdminEmail {
                modelContext.delete(user)
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
                        scheduleDismiss(
                            after: SplashVideoLocator.preferredFinishDelay(
                                for: url,
                                maximumDuration: maximumSplashDurationSeconds
                            )
                        )
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
}
