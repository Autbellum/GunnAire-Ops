import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct DeviceGoogleConnectionEligibilityTests {
    private let now = Date(timeIntervalSince1970: 1_790_121_600)
    private let email = "dispatcher@fixture.invalid"
    private let origin = "https://backend.fixture.invalid"

    private func user(_ role: AppUserRole, email: String? = nil, active: Bool = true) -> BackendAppUserRecord {
        .init(email: email ?? self.email, role: role.rawValue, isActive: active, createdAt: nil)
    }

    private func session(email: String? = nil, origin: String? = nil, expiry: Date? = nil) -> CompanyWorkspaceSession {
        .init(backendOrigin: origin ?? self.origin, email: email ?? self.email,
              tokenFingerprint: "synthetic-proof", expiresAt: expiry ?? now.addingTimeInterval(60))
    }

    private func allows(role: AppUserRole?, verified: BackendAppUserRecord?, session: CompanyWorkspaceSession?,
                        email: String? = nil) -> Bool {
        DeviceGoogleConnectionEligibility.allows(role: role, email: email ?? self.email,
            verifiedUser: verified, session: session, backendOrigin: origin, now: now)
    }

    @Test func approvedDispatcherAndAdministratorCanConnectTheirOwnDeviceGoogle() {
        for role in [AppUserRole.dispatcher, .admin] {
            #expect(allows(role: role, verified: user(role), session: session()))
        }
        #expect(allows(role: .dispatcher,
            verified: user(.dispatcher, email: " DISPATCHER@FIXTURE.INVALID "),
            session: session(email: "Dispatcher@Fixture.Invalid")))
    }

    @Test func rolesWithoutMailPermissionCannotGainDeviceConnectionControls() {
        for role in [AppUserRole.standard, .fieldTechnician, .accounting] {
            #expect(!allows(role: role, verified: user(role), session: session()))
        }
        #expect(!allows(role: nil, verified: user(.dispatcher), session: session()))
    }

    @Test func localRoleCannotSubstituteForAnActiveMatchingVerifiedRole() {
        #expect(!allows(role: .dispatcher, verified: nil, session: session()))
        #expect(!allows(role: .dispatcher, verified: user(.dispatcher, active: false), session: session()))
        #expect(!allows(role: .admin, verified: user(.fieldTechnician), session: session()))
        #expect(!allows(role: .admin, verified: user(.dispatcher), session: session()))
        #expect(!allows(role: .dispatcher, verified: user(.dispatcher, email: "other@fixture.invalid"), session: session()))
        let unknown = BackendAppUserRecord(email: email, role: "Unknown", isActive: true, createdAt: nil)
        #expect(!allows(role: .dispatcher, verified: unknown, session: session()))
    }

    @Test func missingExpiredAndForeignBusinessSessionsFailClosed() {
        let verified = user(.dispatcher)
        #expect(!allows(role: .dispatcher, verified: verified, session: nil))
        #expect(!allows(role: .dispatcher, verified: verified, session: session(expiry: now)))
        #expect(!allows(role: .dispatcher, verified: verified, session: session(expiry: now.addingTimeInterval(-1))))
        #expect(!allows(role: .dispatcher, verified: verified, session: session(email: "other@fixture.invalid")))
        #expect(!allows(role: .dispatcher, verified: verified, session: session(origin: "https://other.fixture.invalid")))
        #expect(!allows(role: .dispatcher, verified: verified, session: session(), email: " "))
        #expect(!DeviceGoogleConnectionEligibility.allows(role: .dispatcher, email: nil,
            verifiedUser: verified, session: session(), backendOrigin: origin, now: now))
    }

    @Test func actionRecheckRejectsAuthorityLostAfterTheControlWasDisplayed() {
        var verified: BackendAppUserRecord? = user(.dispatcher)
        var proof: CompanyWorkspaceSession? = session()
        #expect(allows(role: .dispatcher, verified: verified, session: proof))
        verified = user(.dispatcher, active: false)
        #expect(!allows(role: .dispatcher, verified: verified, session: proof))
        verified = user(.dispatcher)
        proof = nil
        #expect(!allows(role: .dispatcher, verified: verified, session: proof))
        proof = session()
        #expect(!allows(role: .dispatcher, verified: verified, session: proof, email: "replacement@fixture.invalid"))
    }
}
