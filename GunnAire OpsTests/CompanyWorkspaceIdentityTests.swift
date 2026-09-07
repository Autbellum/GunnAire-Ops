import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct CompanyWorkspaceIdentityTests {
    private let companyID = UUID(uuidString: "a1000000-0000-4000-8000-000000000001")!

    private func binding(
        companyID: UUID? = nil,
        environment: String = "development",
        accountHash: String = String(repeating: "a", count: 64),
        approvedAt: String = "2026-09-06T12:00:00.123456+00:00"
    ) -> CompanyCloudKitBinding {
        CompanyCloudKitBinding(
            companyID: companyID ?? self.companyID,
            containerID: GunnAireCloudKit.containerIdentifier,
            environment: environment,
            replicaID: UUID(),
            cloudAccountHash: accountHash,
            approvedAt: approvedAt
        )
    }

    @Test func serverWorkspaceContractDecodesAndSeparatesCloudKitEnvironments() throws {
        let development = binding()
        let production = binding(environment: "production")
        let identity = CompanyWorkspaceIdentity(companyID: companyID, containerID: GunnAireCloudKit.containerIdentifier, bindings: [development, production])
        let encoded = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(CompanyWorkspaceIdentity.self, from: encoded)
        #expect(decoded == identity)
        #expect(decoded.binding(for: "development") == development)
        #expect(decoded.binding(for: "production") == production)
        #expect(decoded.binding(for: "Production") == nil)
        let envelope = try JSONSerialization.data(withJSONObject: [
            "user": ["email": "approved@example.test", "role": "Admin", "isActive": true],
            "workspace": JSONSerialization.jsonObject(with: encoded)
        ])
        let response = try JSONDecoder().decode(BackendCompanyWorkspaceResponse.self, from: envelope)
        #expect(response.user.role == "Admin")
        #expect(response.workspace == identity)
    }

    @Test func missingDuplicateForeignOrMalformedBindingsNeverSelectAWorkspace() {
        let valid = binding()
        for candidates in [[], [valid, valid], [binding(companyID: UUID())], [binding(accountHash: "x")], [binding(environment: "test")], [binding(approvedAt: "not-a-date")]] {
            let identity = CompanyWorkspaceIdentity(companyID: companyID, containerID: GunnAireCloudKit.containerIdentifier, bindings: candidates)
            #expect(identity.binding(for: "development") == nil)
        }
        let wrongContainer = CompanyWorkspaceIdentity(companyID: companyID, containerID: "iCloud.other.company", bindings: [valid])
        #expect(wrongContainer.binding(for: "development") == nil)
        #expect(!binding(accountHash: String(repeating: "A", count: 64)).isValid)
        #expect(!binding(accountHash: String(repeating: "a", count: 65)).isValid)
    }

    @Test func workspaceApprovalRequiresAnExplicitOwnershipValueAndCanonicalCompanyID() throws {
        for confirmed in [false, true] {
            let payload = CompanyCloudKitApprovalRequest(
                companyID: companyID,
                containerID: GunnAireCloudKit.containerIdentifier,
                environment: "development",
                cloudAccountHash: String(repeating: "a", count: 64),
                confirmCompanyDataOwnership: confirmed
            )
            let encoded = try JSONEncoder().encode(payload)
            let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(json["expectedCompanyID"] as? String == companyID.uuidString.lowercased())
            #expect(json["confirmCompanyDataOwnership"] as? Bool == confirmed)
        }
    }
}
