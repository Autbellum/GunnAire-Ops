import BackgroundTasks
import Foundation
import SwiftData

/// Callback-based Calendar requests create their own Swift task. This shared
/// lifetime closes their provider fence when iOS expires the parent refresh.
nonisolated final class BackgroundRefreshLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var completed = false

    var isExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }

    func expire(_ task: BGTask) {
        lock.lock()
        expired = true
        let shouldComplete = !completed
        completed = true
        lock.unlock()
        if shouldComplete { task.setTaskCompleted(success: false) }
    }

    func complete(_ task: BGTask, success: Bool) {
        lock.lock()
        let shouldComplete = !completed
        completed = true
        lock.unlock()
        if shouldComplete { task.setTaskCompleted(success: success) }
    }
}

/// iOS chooses when to launch a refresh and may give no launch at all. Every
/// provider mutation remains in its original durable, identity-checked outbox.
@MainActor
final class BackgroundProviderRecovery {
    static let shared = BackgroundProviderRecovery()
    nonisolated static let identifier = "com.gunnaire.ops.provider-recovery"

    private var registered = false

    private init() {}

    func registerAtLaunch() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await BackgroundProviderRecovery.shared.handle(refresh)
            }
        }
        if !registered { NSLog("Background provider refresh registration is unavailable for this app build.") }
    }

    func scheduleAfterBackgrounding() {
        guard registered, BusinessLoginSelection.selected != nil,
              CompanyWorkspaceAccessController.shared.authorizedContainer != nil else { return }
        scheduleNext()
    }

    private func scheduleNext() {
        guard registered else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do {
            // Apple replaces an earlier request with the same identifier.
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("Background provider refresh could not be scheduled: %@", String(describing: error))
        }
    }

    private func handle(_ refresh: BGAppRefreshTask) async {
        if BusinessLoginSelection.selected != nil { scheduleNext() }
        let lifetime = BackgroundRefreshLifetime()
        let worker = Task { @MainActor in await runOnce(lifetime: lifetime) }
        refresh.expirationHandler = {
            lifetime.expire(refresh)
            worker.cancel()
        }
        let completed = await worker.value
        refresh.expirationHandler = nil
        lifetime.complete(refresh, success: completed && !worker.isCancelled && !lifetime.isExpired)
    }

    private func runOnce(lifetime: BackgroundRefreshLifetime) async -> Bool {
        guard let selected = BusinessLoginSelection.selected,
              !Task.isCancelled, !lifetime.isExpired else { return false }
        async let appleRestore: Void = AppleAuthManager.shared.restoreStoredSession()
        async let googleRestore: Void = GoogleAuthManager.shared.restoreStoredSession()
        _ = await (appleRestore, googleRestore)
        guard !Task.isCancelled, !lifetime.isExpired,
              BusinessLoginSelection.selected == selected,
              BusinessLoginSelection.resolvedProvider(
                selected: selected,
                appleBusinessSessionAvailable: AppleAuthManager.shared.isAuthenticated &&
                    AppleAuthManager.shared.workspaceSessionProof != nil,
                googleBusinessSessionAvailable: GoogleAuthManager.shared.isAuthenticated &&
                    GoogleAuthManager.shared.workspaceSessionProof != nil
              ) == selected else { return false }
        if selected == .apple {
            guard await AppleAuthManager.shared.validateCredentialState(),
                  !Task.isCancelled, !lifetime.isExpired else { return false }
        }

        let access = CompanyWorkspaceAccessController.shared
        await access.refreshIfStale(maxAge: CompanyWorkspaceAccessController.verificationInterval)
        guard !Task.isCancelled, !lifetime.isExpired,
              let container = access.authorizedContainer,
              let stamp = access.operationStamp,
              access.verifiedUser?.isActive == true else { return false }
        let businessEmail = AppAccess.normalizedEmail(AppIdentity.currentEmail)
        guard !businessEmail.isEmpty,
              businessEmail == AppAccess.normalizedEmail(access.verifiedUser?.email) else { return false }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let stillAuthorized: @MainActor () -> Bool = {
            !Task.isCancelled && !lifetime.isExpired && BusinessLoginSelection.selected == selected &&
                access.authorizedContainer === container && access.operationStamp == stamp &&
                AppAccess.normalizedEmail(AppIdentity.currentEmail) == businessEmail &&
                AppAccess.normalizedEmail(access.verifiedUser?.email) == businessEmail
        }
        return await Self.runVerifiedProviders(
            stillAuthorized: stillAuthorized,
            calendar: {
                guard GoogleAuthManager.shared.googleCalendarAuthorizationState == .ready else { return true }
                let result = await GoogleCalendarScheduleSync.backgroundPublishPending(
                    auth: GoogleAuthManager.shared, context: context, signedInEmail: businessEmail,
                    isExpired: { lifetime.isExpired })
                if case .success = result { return true }
                return false
            },
            drive: {
                guard GoogleAuthManager.shared.googleDriveAuthorizationState == .ready,
                      access.verifiedRole == .admin else { return true }
                return await AutomaticGoogleDriveArchive.shared.recoverOneBackground(context: context)
            }
        )
    }

    /// Recheck the exact lease and business identity between providers. The
    /// outbox workers additionally fence each individual remote operation.
    static func runVerifiedProviders(
        stillAuthorized: @MainActor () -> Bool,
        calendar: @MainActor () async -> Bool,
        drive: @MainActor () async -> Bool
    ) async -> Bool {
        guard stillAuthorized() else { return false }
        let calendarCompleted = await calendar()
        guard stillAuthorized() else { return false }
        let driveCompleted = await drive()
        return stillAuthorized() && calendarCompleted && driveCompleted
    }
}
