import Foundation

struct CloudKitContinuityNotice: Equatable, Sendable {
    let title: String
    let systemImage: String
    let statusDetail: String
    let recoveryDetail: String
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
