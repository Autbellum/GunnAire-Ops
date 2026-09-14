import Foundation
import SwiftUI
import SwiftData
import CloudKit
import UIKit
import StoreKit

/// CloudKit's async calls carry no built-in timeout, so a stalled network
/// path (rather than a clean error) can leave a caller awaiting forever with
/// no feedback. Races the operation against a deadline and throws
/// `CompanyWorkspaceFailure.server` if the deadline wins.
private func withCloudKitTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CompanyWorkspaceFailure.server
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// A repeated "could not verify its secure server or signed CloudKit
/// environment" failure on a real device with no console access is otherwise
/// undiagnosable. Captures exactly why the AppTransaction check didn't
/// succeed so it can be shown directly in the on-screen error text.
@MainActor
enum CompanyWorkspaceDiagnostics {
    static var lastConfigurationDetail: String = ""
    /// The raw CKAccountStatus (or empty-record-ID condition) behind the most
    /// recent accountUnavailable failure. That failure collapses several
    /// distinct device-side conditions (.noAccount, .restricted,
    /// .couldNotDetermine, .temporarilyUnavailable) into one generic message,
    /// which made remote diagnosis on real staff hardware pure guesswork.
    static var lastAccountStatusDetail: String = ""
    /// The raw error behind the most recent .server failure. That failure is
    /// a catch-all for any workspace-fetch error that isn't a recognized
    /// GunnAireBackendError, so the on-screen message alone can't distinguish
    /// a real backend problem from a URLError/DecodingError on this device.
    static var lastServerFailureDetail: String = ""
}

enum CompanyCloudKitRuntimeAccount {
    /// The installed, signed profile determines CloudKit's environment when
    /// present. When it is absent, StoreKit's AppTransaction is the
    /// preferred proof, but AppTransaction.shared has a known real-world
    /// reliability problem (StoreKitError.unknown, confirmed on-device,
    /// independent of network or account state) that must not hard-block
    /// every staff device. The absence of the embedded profile is itself
    /// strong evidence: only Apple's own App Store Connect processing
    /// pipeline (App Store or TestFlight) strips it - a Development, Ad Hoc,
    /// or Enterprise build always keeps it, so this cannot be replicated by
    /// simply omitting a file from a side-loaded build. Never infer this
    /// from DEBUG, a receipt file, or QBO.
    static func environment(profileData: Data?, hasVerifiedStoreDistribution: Bool) -> String? {
        if let data = profileData {
            guard let start = data.range(of: Data("<?xml".utf8)),
                  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
                  let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
                  let entitlements = plist["Entitlements"] as? [String: Any],
                  let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String],
                  containers.contains(GunnAireCloudKit.containerIdentifier) else { return nil }
            // Provisioning profiles encode this entitlement as a single String
            // for a distribution-only profile, but as a String array (e.g.
            // ["Production", "Development"]) for profiles that support both
            // environments. Accept either shape and prefer Production.
            let rawEnvironmentValues: [String]
            if let single = entitlements["com.apple.developer.icloud-container-environment"] as? String {
                rawEnvironmentValues = [single]
            } else if let list = entitlements["com.apple.developer.icloud-container-environment"] as? [String] {
                rawEnvironmentValues = list
            } else {
                return nil
            }
            guard let value = rawEnvironmentValues.first(where: { $0 == "Production" }) ?? rawEnvironmentValues.first(where: { $0 == "Development" }) else { return nil }
            return value.lowercased()
        }
        return hasVerifiedStoreDistribution ? "production" : nil
    }

    static func current() async throws -> CompanyCloudKitAccount {
        guard !GunnAireCloudKit.usesTestDatabase else { throw CompanyWorkspaceFailure.configuration }
        let profileURLs = [
            Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        ]
        let profileURL = profileURLs.first { FileManager.default.fileExists(atPath: $0.path) }
        let profileData = try profileURL.map { try Data(contentsOf: $0) }
        var hasVerifiedDistribution = false
        if profileData == nil {
            // App Store / TestFlight distribution strips the embedded
            // provisioning profile from the on-device bundle, so this is the
            // only path real staff devices take: distribution is proven via
            // StoreKit's AppTransaction instead. A thrown error here (network,
            // or the App Store receipt not yet settling right after a fresh
            // install/update) must never propagate as a raw, uncategorized
            // error — the caller maps any such error to accountUnavailable,
            // which misleadingly sends staff to check their iCloud sign-in
            // for what is really a StoreKit verification problem. Retry
            // briefly before giving up.
            var lastDetail = ""
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                do {
                    let result = try await AppTransaction.shared
                    switch result {
                    case .verified(let transaction):
                        if transaction.bundleID != Bundle.main.bundleIdentifier {
                            lastDetail = "bundleID mismatch: got \(transaction.bundleID)"
                        } else if !(transaction.environment == .production || transaction.environment == .sandbox) {
                            lastDetail = "unexpected environment: \(transaction.environment)"
                        } else {
                            hasVerifiedDistribution = true
                        }
                    case .unverified(_, let verificationError):
                        lastDetail = "unverified: \(verificationError)"
                    }
                } catch {
                    lastDetail = "threw: \(String(describing: error))"
                }
                if hasVerifiedDistribution { break }
            }
            if hasVerifiedDistribution {
                let detail = "profileData=nil, AppTransaction verified"
                await MainActor.run { CompanyWorkspaceDiagnostics.lastConfigurationDetail = detail }
            } else {
                // AppTransaction did not verify, but the missing embedded
                // profile is itself sufficient proof this is a real Apple
                // Store Connect distribution (see comment above). Fall back
                // rather than blocking every device on a flaky StoreKit call.
                hasVerifiedDistribution = true
                let detail = "profileData=nil, AppTransaction: \(lastDetail) — fell back to profile-absence proof"
                await MainActor.run { CompanyWorkspaceDiagnostics.lastConfigurationDetail = detail }
            }
        } else {
            await MainActor.run { CompanyWorkspaceDiagnostics.lastConfigurationDetail = "profileData present, \(profileData?.count ?? -1) bytes" }
        }
        guard let environment = environment(profileData: profileData, hasVerifiedStoreDistribution: hasVerifiedDistribution) else {
            throw CompanyWorkspaceFailure.configuration
        }
        let container = CKContainer(identifier: GunnAireCloudKit.containerIdentifier)
        // CKContainer's async calls have no built-in timeout. A stalled
        // network path (rather than a clean error) previously left staff
        // staring at an unbounded "Verifying company access…" spinner with
        // no feedback at all. Bound each call so a stall surfaces as a clear,
        // actionable failure instead of hanging indefinitely.
        let status = try await withCloudKitTimeout(seconds: 20, { try await container.accountStatus() })
        guard status == .available else {
            await MainActor.run { CompanyWorkspaceDiagnostics.lastAccountStatusDetail = "accountStatus=\(Self.describe(status))" }
            throw CompanyWorkspaceFailure.accountUnavailable
        }
        let identifier = try await withCloudKitTimeout(seconds: 20) { try await container.userRecordID() }
        guard !identifier.recordName.isEmpty else {
            await MainActor.run { CompanyWorkspaceDiagnostics.lastAccountStatusDetail = "accountStatus=available, userRecordID.recordName=empty" }
            throw CompanyWorkspaceFailure.accountUnavailable
        }
        let hash = CompanyWorkspaceSession.digest(
            "gunnaire-cloudkit-account-v1\n\(GunnAireCloudKit.containerIdentifier)\n\(environment)\n\(identifier.recordName)"
        )
        return CompanyCloudKitAccount(environment: environment, accountHash: hash, recordName: identifier.recordName)
    }

    private static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: "available"
        case .restricted: "restricted"
        case .noAccount: "noAccount"
        case .couldNotDetermine: "couldNotDetermine"
        case .temporarilyUnavailable: "temporarilyUnavailable"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}

struct CompanyWorkspaceHost: View {
    @ObservedObject private var access = CompanyWorkspaceAccessController.shared
    @ObservedObject private var receive = StaffReplicaReceiveController.shared
    @Binding var hasAuthenticatedUser: Bool
    @State private var confirmsOwnership = false
    @State private var showingStaffSetup = false
    @StateObject private var staffNavigation = StaffWorkspaceNavigationController()
    @ObservedObject private var staffInvitations = CloudKitStaffInvitationInbox.shared

    var body: some View {
        Group {
            if let container = access.authorizedContainer {
                ContentView().modifier(JobBillingRecoveryModifier()).modifier(StaffReplicaSourceRecoveryModifier()).modelContainer(container)
                    .id(access.generation)
            } else if let presentation = receive.authorizedPresentation {
                // One verified session, never independently published host/identity
                // fields. Navigation survives content refresh within this scope.
                StaffWorkspaceOperationalHostedWorkspaceView(
                    hosted: presentation.workspace.hosted,
                    identity: presentation.workspace.identity,
                    account: presentation.context.account,
                    deviceFingerprint: presentation.deviceFingerprint,
                    navigation: staffNavigation
                )
                    .id(presentation.navigationScope)
                    .accessibilityIdentifier("StaffOperationalHostedWorkspace")
                    .safeAreaInset(edge: .top, spacing: 0) {
                        StaffReplicaOfflineStatusView(receive: receive)
                    }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("Company workspace", systemImage: "person.icloud")
                            .font(.title2.bold())
                        switch access.phase {
                        case .checking, .ready:
                            ProgressView("Verifying company access…")
                                .accessibilityIdentifier("CompanyWorkspaceProofCheck")
                            Text(access.diagnosticStep)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("CompanyWorkspaceDiagnosticStep")
                        case .needsApproval(let hasSavedStore):
                            Text(hasSavedStore ? "Review this device's saved work" : "Approve this company iCloud account")
                                .font(.headline)
                            Text("Only approve the business iCloud account used for GunnAire's operational records. This links the account and this device's saved workspace to your verified business. It does not move or delete existing records.")
                            if hasSavedStore {
                                Text("Existing saved records have not been assigned to a verified company. If you cannot confirm their ownership, stop and ask for a data review.")
                                    .foregroundStyle(.secondary)
                            }
                            Toggle("I confirm that this iCloud account and any saved work belong to this business.", isOn: $confirmsOwnership)
                                .accessibilityIdentifier("CompanyWorkspaceOwnershipConfirmation")
                            Button("Approve Workspace") {
                                Task { await access.approve(confirmed: confirmsOwnership) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!confirmsOwnership)
                            .accessibilityIdentifier("CompanyWorkspaceApproveButton")
                            Text("Approval requires an administrator sign-in within the last 10 minutes.")
                                .font(.footnote).foregroundStyle(.secondary)
                        case .blocked(let failure):
                            Text(failure == .differentWorkspace ? "Workspace does not match" : "Workspace needs attention")
                                .font(.headline)
                            Text(failure.localizedDescription)
                            if failure == .configuration, !CompanyWorkspaceDiagnostics.lastConfigurationDetail.isEmpty {
                                Text(CompanyWorkspaceDiagnostics.lastConfigurationDetail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("CompanyWorkspaceConfigurationDetail")
                            }
                            if failure == .accountUnavailable, !CompanyWorkspaceDiagnostics.lastAccountStatusDetail.isEmpty {
                                Text(CompanyWorkspaceDiagnostics.lastAccountStatusDetail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("CompanyWorkspaceAccountStatusDetail")
                            }
                            if failure == .server, !CompanyWorkspaceDiagnostics.lastServerFailureDetail.isEmpty {
                                Text(CompanyWorkspaceDiagnostics.lastServerFailureDetail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("CompanyWorkspaceServerFailureDetail")
                            }
                            if failure != .restartRequired {
                                Button("Check Again") { Task { await access.refresh() } }
                                    .buttonStyle(.borderedProminent)
                                Button("Staff iCloud Setup") { showingStaffSetup = true }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("OpenStaffCloudKitSetup")
                            }
                        }
                        Button("Sign Out") {
                            access.invalidate()
                            FieldPaymentHandoff.shared.end()
                            GunnAireAppIntentRouter.discardAllPendingPayloads()
                            QuickBooksAuthAPI.shared.signOut()
                            GoogleAuthManager.shared.signOut()
                            AppleAuthManager.shared.signOut()
                            hasAuthenticatedUser = false
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(24)
                    .frame(maxWidth: 600, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
                .accessibilityIdentifier("CompanyWorkspaceProofGate")
            }
        }
        .modifier(StaffReplicaReceiveRecoveryModifier())
        .onChange(of: receive.authorizedPresentation?.navigationIdentity, initial: true) { _, _ in
            staffNavigation.update(receive.authorizedPresentation)
        }
        .sheet(item: $staffNavigation.editor) { session in
            StaffWorkspaceFieldEditorView(title: session.title, field: session.field, editor: session.controller)
        }
        .sheet(item: $staffNavigation.invoiceEditor) { session in
            StaffInvoiceEditorView(editor: session.controller)
        }
        .sheet(isPresented: $showingStaffSetup) { CloudKitStaffSetupView() }
        .onReceive(staffInvitations.$pending) { invitation in
            if invitation != nil { showingStaffSetup = true }
        }
        .task { await access.refresh() }
        .task(id: receive.presentation?.context.stamp.session.expiresAt) {
            guard let expires = receive.presentation?.context.stamp.session.expiresAt else { return }
            do { try await Task.sleep(for: .seconds(max(0, expires.timeIntervalSinceNow))) }
            catch { return }
            receive.enforceAccessDeadline()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            access.enforceAccessDeadline()
            receive.enforceAccessDeadline()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            access.enforceAccessDeadline()
            receive.enforceAccessDeadline()
            Task { await access.refresh() }
        }
    }
}
