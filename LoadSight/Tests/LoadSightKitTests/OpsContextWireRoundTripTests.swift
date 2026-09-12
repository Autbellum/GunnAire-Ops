import XCTest
import LoadSightKit

/// Exercise the real encoder; hand-written null fields can hide wire mismatches.
final class OpsContextWireRoundTripTests: XCTestCase {
    private let customer = OpsCustomerSnapshot(id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
                                               name: "Synthetic customer", address: "Synthetic address")

    private func assertWireRoundTrip(_ context: OpsProjectContext, file: StaticString = #filePath, line: UInt = #line) throws {
        let raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(context))
        XCTAssertEqual(Set(raw.object!.keys), Set(["version", "customer", "job"]), file: file, line: line)
        if context.job != nil {
            XCTAssertEqual(Set(raw["job"].object!.keys), Set(["id", "customerID", "title", "siteAddress", "serviceLocationID"]), file: file, line: line)
        }
        let project = try LoadSightTests().readyProject()
        let request = JSONValue.object(["operation": .string("ops.context.update"),
                                       "author": .string("Synthetic recorder"),
                                       "reason": .string("Typed snapshot round trip"),
                                       "expectedFingerprint": .string(try project.opsContextEditFingerprint()),
                                       "context": raw])
        let updated = try ProjectEditing.apply(request, to: project).project
        XCTAssertEqual(try updated.opsContext(), context, file: file, line: line)
        XCTAssertEqual(updated.root["opsContext"], raw, file: file, line: line)
        XCTAssertEqual(try updated.opsContextHistory().count, 1, file: file, line: line)
    }

    func testCustomerOnlyTypedSnapshotEmitsExplicitNullAndIsAccepted() throws {
        try assertWireRoundTrip(OpsProjectContext(customer: customer))
    }

    func testJobWithoutServiceLocationEmitsExplicitNullAndIsAccepted() throws {
        let job = OpsJobSnapshot(id: UUID(), customerID: customer.id, title: "Synthetic service", siteAddress: "Synthetic site", serviceLocationID: nil)
        try assertWireRoundTrip(OpsProjectContext(customer: customer, job: job))
    }

    func testJobWithServiceLocationRetainsItsIDAndIsAccepted() throws {
        let job = OpsJobSnapshot(id: UUID(), customerID: customer.id, title: "Synthetic service", siteAddress: "Synthetic site", serviceLocationID: UUID())
        try assertWireRoundTrip(OpsProjectContext(customer: customer, job: job))
    }

    func testLegacyOmittedOptionalFieldsRemainReadableAndKeepTheirHistoryOnEdit() throws {
        for hasJob in [false, true] {
            let job = hasJob ? OpsJobSnapshot(id: UUID(), customerID: customer.id, title: "Synthetic service", siteAddress: "Synthetic site", serviceLocationID: nil) : nil
            let context = OpsProjectContext(customer: customer, job: job)
            var project = try LoadSightTests().readyProject()
            try project.updateOpsContext(context, expectedFingerprint: project.opsContextEditFingerprint(), author: "Legacy recorder", reason: "Original snapshot")
            var root = project.root.object!, legacy = root["opsContext"]!.object!
            if hasJob {
                var rawJob = legacy["job"]!.object!
                rawJob.removeValue(forKey: "serviceLocationID"); legacy["job"] = .object(rawJob)
            } else { legacy.removeValue(forKey: "job") }
            let originalSnapshot = JSONValue.object(legacy)
            root["opsContext"] = originalSnapshot
            var history = root["opsContextHistory"]!.array!, first = history[0].object!
            first["after"] = originalSnapshot; history[0] = .object(first); root["opsContextHistory"] = .array(history)
            var restored = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(root)))
            XCTAssertEqual(try restored.opsContext(), context)
            try restored.updateOpsContext(context, expectedFingerprint: restored.opsContextEditFingerprint(), author: "Current recorder", reason: "Reconfirmed legacy context")
            let revisions = try restored.opsContextHistory()
            XCTAssertEqual(revisions.count, 2)
            XCTAssertEqual(revisions[0].after, originalSnapshot)
            XCTAssertEqual(revisions[1].before, originalSnapshot)
            XCTAssertEqual(try revisions[1].context(before: false), context)
        }
    }
}
