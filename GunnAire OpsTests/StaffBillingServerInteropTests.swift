import Foundation
import XCTest
@testable import GunnAire_Ops

/// This vector is produced by the actual backend adapter and independently
/// compared with the native preparation, not merely decoded by both sides.
final class StaffBillingServerInteropTests: XCTestCase {
    struct Vector: Decodable {
        let records: [StaffWorkspaceModelRecord]
        let projections: [String: StaffWorkspaceBillingProjection]
    }

    private func vector() throws -> Vector {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "StaffBillingServerInterop", withExtension: "json"))
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    @MainActor func testAllFiveServerRoleProjectionsExactlyMatchNativePreparationFromOriginalRecords() throws {
        let vector = try vector(), fixture = StaffWorkspaceBillingProjectionTests()
        XCTAssertEqual(vector.records.count, 33)
        XCTAssertEqual(Set(vector.records.map(\.kind)).count, 32)
        XCTAssertEqual(Set(vector.projections.keys), Set(AppUserRole.allCases.map(\.rawValue)))
        for role in AppUserRole.allCases {
            let expected = try fixture.prepare(vector.records, role: role)
            let actual = try XCTUnwrap(vector.projections[role.rawValue])
            XCTAssertEqual(actual, expected, "Server/native disclosure differs for \(role.rawValue)")
            let wire = try StaffWorkspacePublicationContract.encode(actual)
            let verified = try StaffWorkspaceBillingProjection.verify(wire, source: fixture.source(vector.records),
                expectedScope: fixture.scope, plan: fixture.plan(role), workspace: fixture.fixture.workspace,
                sourceSequence: 1, now: fixture.fixture.now)
            XCTAssertEqual(verified, expected)
        }
    }

    @MainActor func testServerBundleRetainsIndependentSoldMembersWithoutDuplicatingRootQuantity() throws {
        let projection = try XCTUnwrap(vector().projections[AppUserRole.fieldTechnician.rawValue])
        let document = try XCTUnwrap(projection.documents.first)
        guard case .saved(let catalog) = document.catalog else { return XCTFail("Missing saved catalog") }
        let line = try XCTUnwrap(catalog.lines.first), bundle = try XCTUnwrap(line.bundle)
        XCTAssertEqual(line.quantity, 3)
        XCTAssertEqual(line.extendedAmount, 225)
        XCTAssertEqual(bundle.members.map(\.line.quantity), [6, 3])
        XCTAssertEqual(Set(bundle.members.map(\.id)).count, 2)
        XCTAssertEqual(Set(bundle.members.map(\.line.catalogItemID)).count, 1)
        XCTAssertEqual(bundle.scope, .restricted)
        XCTAssertTrue(bundle.members.allSatisfy { $0.line.purchaseCost == .restricted && $0.line.quickBooksItemID == .restricted })
        XCTAssertEqual(document.fields["amount"], .number(205.65))
        XCTAssertEqual(document.fields["salesTaxAmount"], .number(3.15))
        XCTAssertEqual(catalog.discount?.grossSubtotalAtAuthorization, 225)
    }

    @MainActor func testServerAssemblyCostsStayRestrictedToFinancialRoles() throws {
        let data = try vector()
        func assembly(_ role: AppUserRole) throws -> StaffWorkspaceBillingProjection.Assembly {
            let doc = try XCTUnwrap(data.projections[role.rawValue]?.documents.first { $0.kind == "estimate" })
            guard case .saved(let catalog) = doc.catalog else { throw StaffWorkspaceBillingProjection.Failure.invalid }
            return try XCTUnwrap(catalog.lines.first?.assembly)
        }
        let dispatch = try assembly(.dispatcher), owner = try assembly(.admin)
        XCTAssertEqual(dispatch.revision, 3)
        XCTAssertEqual(dispatch.components.first?.quantity, 2)
        XCTAssertEqual(dispatch.components.first?.purchaseCost, .restricted)
        XCTAssertEqual(owner.components.first?.purchaseCost, .recorded(3.125))
        XCTAssertTrue(try XCTUnwrap(data.projections[AppUserRole.standard.rawValue]).documents.isEmpty)
    }
}
