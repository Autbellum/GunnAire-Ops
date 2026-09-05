import Foundation

struct CloudKitContinuityNotice: Equatable, Sendable {
    let title: String
    let systemImage: String
    let statusDetail: String
    let recoveryDetail: String
}

enum OperationalWorkspaceAccess: Equatable, Sendable {
    case checking
    case ready
    case emptyReplica

    var allowsOperationalWork: Bool {
        self == .ready
    }
}

/// Describes the current storage boundary so staff do not mistake integration
/// status for full cross-device operational replication.
enum OperationalDataContinuity {
    static let sharedCompanyRecordTypes = [
        "approved users and roles",
        "uploaded customer files",
        "field payment collection records",
        "customer communication history",
        "public service requests"
    ]

    static let deviceLocalRecordTypes = [
        "customers and equipment profiles",
        "jobs, dispatch assignments, and field forms",
        "estimates, invoices, and inventory",
        "time entries and service agreements"
    ]

    static var currentStatusDetail: String {
        "CloudKit replicates core operational records across company iPad and Mac devices signed into the same approved business iCloud account. Shared storage also covers files, payments, messages, requests, and access records. Each staff member must still sign in to the app; CloudKit sign-in alone never grants business access."
    }

    static var offlineRecoveryDetail: String {
        "Field work is retained locally while offline. Reopen this device to finish or retry work; CloudKit merges the saved changes when it returns online. Confirm shared-file upload status before relying on another device."
    }

    /// A verified app login grants a role, but it does not prove that the
    /// device is using the company's existing private CloudKit replica. Keep
    /// administrators able to establish the first company record while
    /// preventing other roles from creating a second, isolated company data
    /// set on an empty iCloud account. Devices that already hold operational
    /// records remain usable offline.
    static func workspaceAccess(
        role: AppUserRole?,
        didInspectLocalRecords: Bool,
        hasLocalCompanyRecords: Bool
    ) -> OperationalWorkspaceAccess {
        guard let role else { return .ready }
        guard role != .admin else { return .ready }
        guard didInspectLocalRecords else { return .checking }
        return hasLocalCompanyRecords ? .ready : .emptyReplica
    }

    static func workspaceNotice(
        for access: OperationalWorkspaceAccess,
        cloudKitReadiness: GunnAireCloudKit.AccountReadiness?
    ) -> CloudKitContinuityNotice? {
        guard access == .emptyReplica else { return nil }

        let statusDetail: String
        switch cloudKitReadiness {
        case .available:
            statusDetail = "This staff account is authorized, but no GunnAire customers, jobs, invoices, inventory, or other company records were found in this device's iCloud replica."
        case .unavailable:
            statusDetail = "This device has no saved GunnAire company records and is not signed in to iCloud."
        case .restricted:
            statusDetail = "This device has no saved GunnAire company records, and iCloud access is restricted."
        case .couldNotDetermine, nil:
            statusDetail = "This device has no saved GunnAire company records, and the app could not verify the company CloudKit replica."
        }

        return CloudKitContinuityNotice(
            title: "Company workspace not loaded",
            systemImage: "person.icloud",
            statusDetail: statusDetail,
            recoveryDetail: "Before entering work, sign this company device in to the same approved business iCloud account used by GunnAire Ops, keep the app open on a stable network, and check again. Ask an administrator to create the first company record if this is a new deployment."
        )
    }

    /// Ready devices stay visually quiet. A compact notice appears only when
    /// staff need to understand that saved field work has not yet been proven
    /// available on another company device.
    static func cloudKitNotice(
        for readiness: GunnAireCloudKit.AccountReadiness
    ) -> CloudKitContinuityNotice? {
        cloudKitNotice(for: readiness, mirroringState: CloudKitMirroringState())
    }

    static func cloudKitNotice(
        for readiness: GunnAireCloudKit.AccountReadiness,
        mirroringState: CloudKitMirroringState
    ) -> CloudKitContinuityNotice? {
        let title: String
        switch readiness {
        case .available:
            if let failure = mirroringState.attentionFailure {
                return CloudKitContinuityNotice(
                    title: failure.title,
                    systemImage: "externaldrive.badge.exclamationmark",
                    statusDetail: failure.statusDetail,
                    recoveryDetail: failure.recoveryDetail
                )
            }
            return nil
        case .unavailable:
            title = "Cloud sync unavailable"
        case .restricted:
            title = "Cloud sync restricted"
        case .couldNotDetermine:
            title = "Cloud sync not verified"
        }

        return CloudKitContinuityNotice(
            title: title,
            systemImage: "externaldrive.badge.exclamationmark",
            statusDetail: readiness.userFacingDetail,
            recoveryDetail: offlineRecoveryDetail
        )
    }
}
