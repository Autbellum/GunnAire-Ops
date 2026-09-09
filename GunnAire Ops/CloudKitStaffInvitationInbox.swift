import Foundation
import CloudKit
import UIKit
import Combine

struct CloudKitStaffInvitation: Codable, Equatable, Identifiable {
    let id: UUID
    let url: URL
    let containerID: String
    let zoneName: String
    let shareName: String
    let rootName: String
    var isValid: Bool {
        containerID == GunnAireCloudKit.containerIdentifier && CloudKitStaffSetupPolicy.invitationURL(url) && rootName == "workspace" &&
        zoneName.hasPrefix("ga-staff-") && CloudKitStaffSetupPolicy.canonicalID(String(zoneName.dropFirst(9))) &&
        shareName.hasPrefix("share-") && CloudKitStaffSetupPolicy.canonicalID(String(shareName.dropFirst(6)))
    }
    func matches(_ plan: CloudKitStaffSharePlan) -> Bool {
        isValid && containerID == plan.containerID && zoneName == plan.zoneName && shareName == plan.shareRecordName && rootName == plan.rootRecordName
    }
}

/// Holds only the unopened original invitation in device-only Keychain. It is
/// untrusted routing input, not authorization; the native flow re-fetches Apple
/// metadata and the current server plan before any acceptance or data access.
@MainActor final class CloudKitStaffInvitationInbox: ObservableObject {
    static let shared = CloudKitStaffInvitationInbox()
    @Published private(set) var pending: CloudKitStaffInvitation?
    @Published private(set) var error: CloudKitStaffSharingError?
    private let read: () throws -> CloudKitStaffInvitation?
    private let write: (CloudKitStaffInvitation?) throws -> Void
    init(read: (() throws -> CloudKitStaffInvitation?)? = nil,
         write: ((CloudKitStaffInvitation?) throws -> Void)? = nil) {
        self.read = read ?? {
            if GunnAireCloudKit.usesTestDatabase { return nil }
            return try KeychainStore.loadCodable(CloudKitStaffInvitation.self, account: "GunnAirePendingStaffInvitation-v1")
        }
        self.write = write ?? { value in
            guard !GunnAireCloudKit.usesTestDatabase else { return }
            if let value { try KeychainStore.saveCodable(value, account: "GunnAirePendingStaffInvitation-v1") }
            else { try KeychainStore.remove(account: "GunnAirePendingStaffInvitation-v1") }
        }
        do {
            if let value = try self.read() {
                guard value.isValid else { throw CloudKitStaffSharingError.storage }
                pending = value
            }
        } catch { self.error = .storage }
    }
    func receive(_ metadata: CKShare.Metadata) {
        guard let url = metadata.share.url, let root = metadata.hierarchicalRootRecordID,
              root.zoneID == metadata.share.recordID.zoneID else { error = .invalid; return }
        receive(.init(id: UUID(), url: url, containerID: metadata.containerIdentifier,
                      zoneName: root.zoneID.zoneName, shareName: metadata.share.recordID.recordName, rootName: root.recordName))
    }
    func receive(_ value: CloudKitStaffInvitation) {
        guard value.isValid else { error = .invalid; return }
        guard error != .storage else { return } // Never overwrite unreadable recovery.
        if let pending {
            guard pending.url == value.url && pending.zoneName == value.zoneName && pending.shareName == value.shareName else { error = .review; return }
            error = nil; return
        }
        do { try write(value); pending = value; error = nil }
        catch { self.error = .storage }
    }
    func dismissOriginal(_ id: UUID) {
        guard pending?.id == id else { return }
        do { try write(nil); pending = nil; error = nil }
        catch { self.error = .storage }
    }
}

@MainActor final class GunnAireStaffSharingSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata { CloudKitStaffInvitationInbox.shared.receive(metadata) }
    }
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        CloudKitStaffInvitationInbox.shared.receive(cloudKitShareMetadata)
    }
}

extension GunnAireApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication { configuration.delegateClass = GunnAireStaffSharingSceneDelegate.self }
        return configuration // SwiftUI retains ownership of the scene/window.
    }
}
