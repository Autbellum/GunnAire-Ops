import Foundation

/// Recorded means the server retained the original field finding. It does not
/// mean that an office record, invoice, or CloudKit payload was changed.
struct StaffWorkspaceCommandRecoverySummary: Equatable {
    let recorded: Int
    let pending: Int
}

/// A scheduling cursor only; original command IDs, bodies and receipts remain
/// in their write-ahead journals. A blocked first page must not starve page two.
struct StaffWorkspaceCommandRecoveryCursor: Codable {
    let version: Int
    let scope: CloudKitStaffSetupScope
    let planID: UUID
    let lastAttemptedID: String
}
