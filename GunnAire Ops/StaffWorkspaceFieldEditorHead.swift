import Foundation

/// A freshness identity for an already verified displayed field. This cannot
/// authorize commands, media, imports, or adoption of unvalidated record values.
struct StaffWorkspaceFieldEditorHead: Equatable {
    let scope: CloudKitStaffSetupScope
    let planID: UUID
    let selectionID: String
    let sourceSequence: Int
    let contentSHA256: String

    init(snapshot: StaffWorkspaceFieldEditorSnapshot) {
        scope = snapshot.scope; planID = snapshot.planID; selectionID = snapshot.selectionID
        sourceSequence = snapshot.sourceSequence; contentSHA256 = snapshot.contentSHA256
    }
    init(mount: StaffWorkspaceOperationalMount) {
        scope = mount.scope; planID = mount.planID; selectionID = mount.selectionID
        sourceSequence = mount.sourceSequence; contentSHA256 = mount.contentSHA256
    }
}
