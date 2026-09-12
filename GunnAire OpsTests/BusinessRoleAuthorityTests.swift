import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct BusinessRoleAuthorityTests {
    private func approved(_ email: String, _ role: AppUserRole, active: Bool = true) -> BackendAppUserRecord {
        BackendAppUserRecord(email: email, role: role.rawValue, isActive: active, createdAt: nil)
    }

    @Test func everyRoleRequiresTheSameApprovedBusinessIdentity() {
        for role in AppUserRole.allCases {
            let user = AppUser(email: "person@example.test", role: role)
            #expect(AppAccess.activeRole(email: user.email, users: [user], verifiedUser: approved(user.email, role)) == role)
            #expect(AppAccess.activeRole(email: user.email, users: [user], verifiedUser: nil) == nil)
            #expect(AppAccess.activeRole(email: user.email, users: [user], verifiedUser: approved("other@example.test", role)) == nil)
            #expect(AppAccess.activeRole(email: user.email, users: [user], verifiedUser: approved(user.email, role, active: false)) == nil)
        }
    }

    @Test func primaryEmailCannotRestoreRevokedOrMissingAdministratorAccess() {
        let email = AppAccess.primaryAdminEmail
        let admin = AppUser(email: email, role: .admin)
        #expect(AppAccess.activeRole(email: email, users: [], verifiedUser: approved(email, .admin)) == nil)
        #expect(AppAccess.activeRole(email: email, users: [admin], verifiedUser: nil) == nil)
        #expect(AppAccess.activeRole(email: email, users: [admin], verifiedUser: approved(email, .fieldTechnician)) == nil)
        admin.isActive = false
        #expect(AppAccess.activeRole(email: email, users: [admin], verifiedUser: approved(email, .admin)) == nil)
        #expect(AppAccess.activeRole(email: email, users: []) == nil)
        #expect(!AppAccess.isAdmin(email: email, users: [admin]))
    }

    @Test func cloudKitRoleEditsCannotPromoteAnyApprovedRole() {
        for granted in AppUserRole.allCases {
            for mirrored in AppUserRole.allCases where granted != mirrored {
                let user = AppUser(email: "staff@example.test", role: mirrored)
                #expect(AppAccess.activeRole(email: user.email, users: [user], verifiedUser: approved(user.email, granted)) == nil)
            }
        }
    }

    @Test func duplicatedNormalizedIdentityMustBeUnambiguousAndActive() {
        let email = "staff@example.test"
        let first = AppUser(email: email, role: .accounting)
        let second = AppUser(email: " STAFF@example.test ", role: .accounting)
        #expect(AppAccess.activeRole(email: " STAFF@EXAMPLE.TEST ", users: [first, second], verifiedUser: approved(email, .accounting)) == .accounting)
        second.role = .admin
        #expect(AppAccess.activeRole(email: email, users: [first, second], verifiedUser: approved(email, .accounting)) == nil)
        second.role = .accounting; second.isActive = false
        #expect(AppAccess.activeRole(email: email, users: [first, second], verifiedUser: approved(email, .accounting)) == nil)
    }

    @Test func unknownRolesAndEmptyIdentitiesCannotBecomeStandardAccess() {
        let user = AppUser(email: "staff@example.test", role: .standard)
        user.roleRawValue = "Unrecognized"
        #expect(AppAccess.activeRole(email: user.email, users: [user], verifiedUser: approved(user.email, .standard)) == nil)
        user.role = .standard
        let unknown = BackendAppUserRecord(email: user.email, role: "Unrecognized", isActive: true, createdAt: nil)
        #expect(AppAccess.activeRole(email: user.email, users: [user], verifiedUser: unknown) == nil)
        let blank = AppUser(email: " ", role: .standard)
        #expect(AppAccess.activeRole(email: nil, users: [blank], verifiedUser: approved("", .standard)) == nil)
    }

    @Test func taskAssigneesRequireActualUnambiguousActiveRecords() {
        let inactiveAdmin = AppUser(email: AppAccess.primaryAdminEmail, role: .admin, isActive: false)
        let staff = AppUser(email: "staff@example.test", role: .fieldTechnician)
        let conflict = AppUser(email: staff.email, role: .admin)
        #expect(AppAccess.businessTaskAssigneeEmails(users: []) == [])
        #expect(AppAccess.businessTaskAssigneeEmails(users: [inactiveAdmin, staff]) == [staff.email])
        #expect(AppAccess.businessTaskAssigneeEmails(users: [inactiveAdmin, staff, conflict]) == [])
    }

    @Test func missingRevokedAndAccountingRolesCannotStartPersonalTime() {
        let user = AppUser(email: "clock@example.test", role: .fieldTechnician)
        #expect(AppAccess.canRecordOwnTime(email: user.email, users: [user]))
        #expect(!AppAccess.canRecordOwnTime(email: user.email, users: []))
        user.isActive = false
        #expect(!AppAccess.canRecordOwnTime(email: user.email, users: [user]))
        user.isActive = true; user.role = .accounting
        #expect(!AppAccess.canRecordOwnTime(email: user.email, users: [user]))
    }

    @Test func timeEditingRequiresTheCurrentActiveOwnerAndAnOpenEntry() {
        let user = AppUser(email: "clock@example.test", role: .fieldTechnician)
        let entry = TimeEntry(userEmail: user.email)
        #expect(AppAccess.canEditOwnOpenTime(entry, email: user.email, users: [user]))
        #expect(!AppAccess.canEditOwnOpenTime(entry, email: "other@example.test", users: [user]))
        user.isActive = false
        #expect(!AppAccess.canEditOwnOpenTime(entry, email: user.email, users: [user]))
        user.isActive = true; entry.clockOut = Date()
        #expect(!AppAccess.canEditOwnOpenTime(entry, email: user.email, users: [user]))
    }
}
