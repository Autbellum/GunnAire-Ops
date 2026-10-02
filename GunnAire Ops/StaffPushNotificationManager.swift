import Combine
import Foundation
import SwiftUI
import UIKit
import UserNotifications

enum StaffPushNotificationState: Equatable {
    case off
    case permissionRequired
    case authorizing
    case registering
    case ready
    case denied
    case attention(String)

    var title: String {
        switch self {
        case .off: "Off"
        case .permissionRequired: "Available"
        case .authorizing: "Requesting permission"
        case .registering: "Connecting"
        case .ready: "Ready"
        case .denied: "Disabled in Apple Settings"
        case .attention: "Needs attention"
        }
    }

    var detail: String {
        switch self {
        case .off:
            "Staff alerts are off on this device."
        case .permissionRequired:
            "Enable private staff alerts when you want assignment updates on this device."
        case .authorizing:
            "Waiting for the Apple notification permission choice."
        case .registering:
            "Registering this signed-in account and the current APNs device token."
        case .ready:
            "Assignment alerts are enabled for this signed-in account. Notification previews omit customer, address, balance, and payment details."
        case .denied:
            "Allow notifications in Apple Settings, then return here and retry."
        case .attention(let detail):
            detail
        }
    }

    var systemImage: String {
        switch self {
        case .ready: "bell.badge.fill"
        case .authorizing, .registering: "arrow.triangle.2.circlepath"
        case .denied, .attention: "bell.badge.slash"
        case .off, .permissionRequired: "bell"
        }
    }

    var isProcessing: Bool {
        self == .authorizing || self == .registering
    }
}

nonisolated struct StaffPushNotificationPreference: Codable, Equatable, Sendable {
    var installationID: UUID
    var ownerEmail: String?
    var isOptedIn: Bool
    var pendingServerDeactivation: Bool
    /// When the server last confirmed this installation's registration.
    /// Absent in preferences saved before it existed.
    var lastRegisteredAt: Date? = nil

    func disablingDeliveryForSignOut() -> Self {
        var saved = self
        saved.isOptedIn = false
        saved.pendingServerDeactivation = saved.ownerEmail != nil
        return saved
    }

    static func newInstallation() -> Self {
        Self(
            installationID: UUID(),
            ownerEmail: nil,
            isOptedIn: false,
            pendingServerDeactivation: false
        )
    }
}

nonisolated enum StaffPushNotificationRouteParser {
    static func paymentCollectionInvoiceID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard let payload = userInfo["gunnaire"] as? [String: Any],
              let version = payload["version"] as? NSNumber,
              version.intValue == 1,
              let eventID = payload["eventID"] as? String,
              (1...160).contains(eventID.count),
              eventID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ":" || $0 == "_" || $0 == "-" }),
              payload["route"] as? String == "paymentCollection",
              let recordID = payload["recordID"] as? String,
              let invoiceID = UUID(uuidString: recordID) else {
            return nil
        }
        return invoiceID
    }
}

@MainActor
final class StaffPushNotificationManager: NSObject, ObservableObject {
    static let shared = StaffPushNotificationManager()

    @Published private(set) var state: StaffPushNotificationState = .off

    private let notificationCenter = UNUserNotificationCenter.current()
    private let keychainAccount = "GunnAireStaffPushPreferenceV1"
    private var preference: StaffPushNotificationPreference
    private var preferenceRestoreTask: Task<StaffPushNotificationPreference?, Never>?
    private var hasRestoredPreference = false
    private var signOutRequestedBeforeRestore = false
    private var registrationAttemptID = UUID()

    private override init() {
        preference = .newInstallation()
        super.init()
    }

    /// Resolve the saved installation identity before any staff workspace or
    /// push registration uses it. Secure storage can stall, so read it away
    /// from the UI actor and share one in-flight restore with launch callers.
    func restoreStoredPreference() async {
        guard !hasRestoredPreference else { return }
        let task: Task<StaffPushNotificationPreference?, Never>
        if let preferenceRestoreTask {
            task = preferenceRestoreTask
        } else {
            let account = keychainAccount
            task = Task.detached(priority: .userInitiated) {
                try? KeychainStore.loadCodable(StaffPushNotificationPreference.self, account: account)
            }
            preferenceRestoreTask = task
        }
        let saved = await task.value
        guard !hasRestoredPreference else { return }
        if let saved { preference = saved }
        hasRestoredPreference = true
        preferenceRestoreTask = nil
        if signOutRequestedBeforeRestore {
            signOutRequestedBeforeRestore = false
            preference = preference.disablingDeliveryForSignOut()
            savePreference()
            state = .off
        }
    }

    var statusTitle: String { state.title }
    var statusDetail: String { state.detail }
    var statusSystemImage: String { state.systemImage }
    var isProcessing: Bool { state.isProcessing }
    var isReady: Bool { state == .ready }
    var isDenied: Bool { state == .denied }
    var hasPendingServerDeactivation: Bool { preference.pendingServerDeactivation }
    var isEnabledForDisplay: Bool { state == .ready || preference.isOptedIn }
    /// Stable installation UUID for device fingerprints — read-only, no side effects.
    var installationID: UUID { preference.installationID }
    /// A temporary installation must never become durable staff-workspace identity.
    var restoredInstallationID: UUID? { hasRestoredPreference ? preference.installationID : nil }

    func configureAtLaunch() {
        notificationCenter.delegate = self
        if applyUITestStateIfRequested() { return }
        Task {
            await restoreStoredPreference()
            await refreshAndRegisterIfNeeded()
        }
    }

    /// Registration is repeated at launch and, on activation, at most this
    /// often; the privacy cover alone must not re-register the device.
    static let activationRegistrationInterval: TimeInterval = 12 * 60 * 60

    func applicationDidBecomeActive() {
        Task {
            await restoreStoredPreference()
            guard !applyUITestStateIfRequested() else { return }
            if state == .ready, let last = preference.lastRegisteredAt,
               Date().timeIntervalSince(last) < Self.activationRegistrationInterval {
                return
            }
            await refreshAndRegisterIfNeeded()
        }
    }

    func activateForCurrentSessionIfNeeded() async {
        await restoreStoredPreference()
        guard !applyUITestStateIfRequested() else { return }
        await refreshAndRegisterIfNeeded()
    }

    func enableForCurrentAccount() async {
        await restoreStoredPreference()
        guard !applyUITestStateIfRequested() else { return }
        guard let email = currentEmail, AppIdentity.hasAuthenticatedProvider else {
            state = .attention("Sign in with an approved Apple or Google business account before enabling staff alerts.")
            return
        }
        state = .authorizing
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                preference.isOptedIn = false
                preference.ownerEmail = nil
                savePreference()
                state = .denied
                return
            }
            preference.ownerEmail = email
            preference.isOptedIn = true
            preference.pendingServerDeactivation = false
            savePreference()
            requestCurrentDeviceToken()
        } catch {
            state = .attention("Apple notification permission could not be requested. Check this device’s Settings and try again.")
        }
    }

    func retry() async {
        await restoreStoredPreference()
        guard !applyUITestStateIfRequested() else { return }
        if preference.pendingServerDeactivation {
            await disableForCurrentAccount()
        } else if preference.isOptedIn {
            await refreshAndRegisterIfNeeded()
        } else {
            await enableForCurrentAccount()
        }
    }

    func disableForCurrentAccount() async {
        await restoreStoredPreference()
        guard !applyUITestStateIfRequested() else { return }
        let owner = preference.ownerEmail
        UIApplication.shared.unregisterForRemoteNotifications()
        preference.isOptedIn = false
        registrationAttemptID = UUID()
        guard owner == currentEmail, AppIdentity.hasAuthenticatedProvider else {
            preference.pendingServerDeactivation = owner != nil
            savePreference()
            state = owner == nil
                ? .off
                : .attention("Alerts are off on this device. Sign in with the same business account to finish removing its server registration.")
            return
        }
        do {
            _ = try await GunnAireBackendService.deactivateStaffPushDevice(
                installationID: preference.installationID
            )
            preference.ownerEmail = nil
            preference.pendingServerDeactivation = false
            preference.lastRegisteredAt = nil
            savePreference()
            state = .off
        } catch {
            preference.pendingServerDeactivation = true
            savePreference()
            state = .attention("Alerts are off on this device. Server removal will retry when the business connection is available.")
        }
    }

    /// Stops local delivery immediately and uses the captured application session
    /// to remove the server registration while the ordinary sign-out revokes that
    /// same session. No device token is retained on the device.
    func prepareForSignOut() {
        guard !applyUITestStateIfRequested() else { return }
        UIApplication.shared.unregisterForRemoteNotifications()
        registrationAttemptID = UUID()
        guard hasRestoredPreference else {
            // Do not overwrite the saved installation with the temporary launch
            // UUID. Apply the sign-out intent when secure storage returns.
            signOutRequestedBeforeRestore = true
            state = .off
            Task { await restoreStoredPreference() }
            return
        }
        let installationID = preference.installationID
        let owner = preference.ownerEmail
        let sessionToken = currentApplicationSessionToken
        preference = preference.disablingDeliveryForSignOut()
        savePreference()
        state = .off
        guard let owner, let sessionToken, !sessionToken.isEmpty else { return }
        Task {
            let removed = (try? await GunnAireBackendService.deactivateStaffPushDevice(
                installationID: installationID,
                applicationSessionToken: sessionToken
            )) != nil
            guard removed,
                  self.preference.ownerEmail == owner,
                  self.preference.installationID == installationID else { return }
            self.preference.ownerEmail = nil
            self.preference.pendingServerDeactivation = false
            self.savePreference()
        }
    }

    func openAppleNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        guard !applyUITestStateIfRequested(),
              preference.isOptedIn,
              preference.ownerEmail == currentEmail,
              AppIdentity.hasAuthenticatedProvider else { return }
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty else {
            state = .attention("Apple returned an empty notification registration. Retry when this device is online.")
            return
        }
        let attemptID = UUID()
        registrationAttemptID = attemptID
        state = .registering
        let installationID = preference.installationID
        let owner = preference.ownerEmail
        Task {
            do {
                let response = try await GunnAireBackendService.registerStaffPushDevice(
                    installationID: installationID,
                    deviceToken: token,
                    platform: Self.platform,
                    environment: Self.apnsEnvironment,
                    bundleID: Bundle.main.bundleIdentifier ?? "",
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
                )
                guard registrationAttemptID == attemptID,
                      preference.isOptedIn,
                      preference.ownerEmail == owner,
                      response.registered,
                      response.device?.isActive == true else { return }
                preference.pendingServerDeactivation = false
                preference.lastRegisteredAt = Date()
                savePreference()
                state = .ready
            } catch {
                guard registrationAttemptID == attemptID else { return }
                state = .attention(registrationFailureDetail(for: error))
            }
        }
    }

    func didFailToRegisterForRemoteNotifications(error: Error) {
        guard !applyUITestStateIfRequested(), preference.isOptedIn else { return }
        state = .attention("This device could not register with Apple Push Notification service. Check the network and retry.")
    }

    private func refreshAndRegisterIfNeeded() async {
        let settings = await notificationCenter.notificationSettings()
        guard let email = currentEmail, AppIdentity.hasAuthenticatedProvider else {
            state = preference.pendingServerDeactivation
                ? .attention("Sign in with the original business account to finish removing its staff-alert registration.")
                : .off
            return
        }
        if preference.pendingServerDeactivation, preference.ownerEmail == email {
            await disableForCurrentAccount()
            return
        }
        guard preference.isOptedIn else {
            state = settings.authorizationStatus == .denied ? .denied : .permissionRequired
            return
        }
        guard preference.ownerEmail == email else {
            UIApplication.shared.unregisterForRemoteNotifications()
            preference.isOptedIn = false
            savePreference()
            state = .permissionRequired
            return
        }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            requestCurrentDeviceToken()
        case .denied:
            state = .denied
        case .notDetermined:
            preference.isOptedIn = false
            savePreference()
            state = .permissionRequired
        @unknown default:
            state = .attention("Apple notification authorization could not be determined. Check Settings and retry.")
        }
    }

    private func requestCurrentDeviceToken() {
        state = .registering
        UIApplication.shared.registerForRemoteNotifications()
    }

    private var currentEmail: String? {
        let normalized = AppAccess.normalizedEmail(AppIdentity.currentEmail)
        return normalized.isEmpty ? nil : normalized
    }

    private var currentApplicationSessionToken: String? {
        if let token = AppleAuthManager.shared.sessionToken, !token.isEmpty { return token }
        if let token = GoogleAuthManager.shared.applicationSessionToken, !token.isEmpty { return token }
        return nil
    }

    private func savePreference() {
        try? KeychainStore.saveCodable(preference, account: keychainAccount)
    }

    private func registrationFailureDetail(for error: Error) -> String {
        if let backendError = error as? GunnAireBackendError {
            switch backendError {
            case .missingBusinessIdentity:
                return "Sign in again with Apple or Google before retrying staff alerts."
            case .notConfigured:
                return "The GunnAire business server is not configured in this build."
            case .server(let statusCode, let message):
                // The server states the exact reason (for example, staff
                // notifications not configured, or no application session).
                // Hiding it behind a generic sentence sent the owner looking
                // for a device or account problem that did not exist.
                let reason = message.trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = reason.isEmpty ? "" : " \(reason.hasSuffix(".") ? reason : reason + ".")"
                return "Apple registration succeeded, but the GunnAire server declined this device (HTTP \(statusCode)).\(suffix)"
            default:
                break
            }
        }
        return "Apple registration succeeded, but the GunnAire server could not bind this device to the signed-in account. Retry when the business connection is available."
    }

    @discardableResult
    private func applyUITestStateIfRequested() -> Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiTestSeedStaffNotificationsReady") {
            state = .ready
            return true
        }
        if arguments.contains("-uiTestSeedStaffNotificationsDenied") {
            state = .denied
            return true
        }
        if arguments.contains("-uiTestSeedStaffNotificationsOff") {
            state = .permissionRequired
            return true
        }
        #endif
        return false
    }

    private static var platform: String {
        #if targetEnvironment(macCatalyst)
        "macCatalyst"
        #else
        "iOS"
        #endif
    }

    private static var apnsEnvironment: String {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }
}

extension StaffPushNotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if StaffPushNotificationRouteParser.paymentCollectionInvoiceID(
            from: notification.request.content.userInfo
        ) != nil {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let invoiceID = StaffPushNotificationRouteParser.paymentCollectionInvoiceID(
            from: response.notification.request.content.userInfo
        ) {
            GunnAireAppIntentRouter.storeFieldPaymentCollectionRoute(invoiceID)
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        openSettingsFor notification: UNNotification?
    ) {
        Task { @MainActor in
            openAppleNotificationSettings()
        }
    }
}

@MainActor
final class GunnAireApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Started first so the launch stopwatch sees as much of startup as the
        // app can observe, and so a crash during startup is still recorded.
        AppPerformanceDiagnostics.shared.start()
        StaffPushNotificationManager.shared.configureAtLaunch()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        StaffPushNotificationManager.shared.applicationDidBecomeActive()
        Task { await CompanyWorkspaceAccessController.shared.revalidateSessionStorageOnForeground() }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        StaffPushNotificationManager.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        StaffPushNotificationManager.shared.didFailToRegisterForRemoteNotifications(error: error)
    }
}
