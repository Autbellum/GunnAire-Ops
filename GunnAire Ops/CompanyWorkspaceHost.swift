import Foundation
import SwiftUI
import SwiftData
import CloudKit
import UIKit
import StoreKit

enum CompanyCloudKitRuntimeAccount {
    /// The installed, signed profile determines CloudKit's environment. Store
    /// distribution removes that profile; a verified App Store transaction is
    /// then required. Never infer this from DEBUG, a receipt file, or QBO.
    static func environment(profileData: Data?, hasVerifiedStoreDistribution: Bool) -> String? {
        if let data = profileData {
            guard let start = data.range(of: Data("<?xml".utf8)),
                  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
                  let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
                  let entitlements = plist["Entitlements"] as? [String: Any],
                  let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String],
                  containers.contains(GunnAireCloudKit.containerIdentifier),
                  let value = entitlements["com.apple.developer.icloud-container-environment"] as? String,
                  ["Development", "Production"].contains(value) else { return nil }
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
        if profileData == nil,
           case .verified(let transaction) = try await AppTransaction.shared,
           transaction.bundleID == Bundle.main.bundleIdentifier,
           transaction.environment == .production || transaction.environment == .sandbox {
            hasVerifiedDistribution = true
        }
        guard let environment = environment(profileData: profileData, hasVerifiedStoreDistribution: hasVerifiedDistribution) else {
            throw CompanyWorkspaceFailure.configuration
        }
        let container = CKContainer(identifier: GunnAireCloudKit.containerIdentifier)
        guard try await container.accountStatus() == .available else { throw CompanyWorkspaceFailure.accountUnavailable }
        let identifier = try await container.userRecordID()
        guard !identifier.recordName.isEmpty else { throw CompanyWorkspaceFailure.accountUnavailable }
        let hash = CompanyWorkspaceSession.digest(
            "gunnaire-cloudkit-account-v1\n\(GunnAireCloudKit.containerIdentifier)\n\(environment)\n\(identifier.recordName)"
        )
        return CompanyCloudKitAccount(environment: environment, accountHash: hash, recordName: identifier.recordName)
    }
}

struct CompanyWorkspaceHost: View {
    @ObservedObject private var access = CompanyWorkspaceAccessController.shared
    @Binding var hasAuthenticatedUser: Bool
    @State private var confirmsOwnership = false
    @State private var showingStaffSetup = false
    @ObservedObject private var staffInvitations = CloudKitStaffInvitationInbox.shared

    var body: some View {
        Group {
            if let container = access.authorizedContainer {
                ContentView().modifier(JobBillingRecoveryModifier()).modelContainer(container)
                    .id(access.generation)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("Company workspace", systemImage: "person.icloud")
                            .font(.title2.bold())
                        switch access.phase {
                        case .checking, .ready:
                            ProgressView("Verifying company access…")
                                .accessibilityIdentifier("CompanyWorkspaceProofCheck")
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
        .sheet(isPresented: $showingStaffSetup) { CloudKitStaffSetupView() }
        .onReceive(staffInvitations.$pending) { invitation in
            if invitation != nil { showingStaffSetup = true }
        }
        .task { await access.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            access.enforceAccessDeadline()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            access.enforceAccessDeadline()
            Task { await access.refresh() }
        }
    }
}
