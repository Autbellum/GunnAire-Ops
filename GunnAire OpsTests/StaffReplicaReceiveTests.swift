import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor struct StaffReplicaReceiveTests {
    @MainActor final class Fixture {
        let cloud: StaffReplicaDeliveryTests.Fixture
        let ids = (1...8).map { String(format: "a4000000-0000-4000-8000-%012d", $0) }
        var afterDownload: (() -> Void)?
        init() throws { cloud = try .init() }
        func cleanup() { cloud.cleanup() }
        func records() -> [[String: Any]] {
            [
                ["kind": "customer", "id": ids[0], "revision": 1, "fields": ["name": "Morgan", "allowsServiceText": false]],
                ["kind": "equipment", "id": ids[2], "revision": 1, "fields": ["name": "Air handler", "customerID": ids[0], "serviceLocationID": ids[1], "isActive": true]],
                ["kind": "item", "id": ids[5], "revision": 1, "fields": ["name": "Capacitor", "itemType": "Inventory", "unitPrice": 125.375, "isTaxable": true, "reviewStatus": "approved"]],
                ["kind": "job", "id": ids[4], "revision": 1, "fields": ["customerID": ids[0], "serviceLocationID": ids[1], "customerEquipmentID": ids[2], "type": "Service", "scheduledDate": cloud.base.instant, "duration": 90, "status": "Scheduled", "assignedTechnicianIDs": [ids[3]]]],
                ["kind": "location", "id": ids[1], "revision": 1, "fields": ["name": "Home", "customerID": ids[0], "address": "10 Main", "isActive": true]],
                ["kind": "technician", "id": ids[3], "revision": 1, "fields": ["name": "Technician", "email": cloud.base.member.email, "isActive": true]]
            ]
        }
        func plan(role: String = "Field Technician") throws -> CloudKitStaffSharePlan {
            var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cloud.base.plan())) as! [String: Any]
            root["memberRole"] = role; root["projectionPolicy"] = CloudKitStaffSharePlan.policy(for: role)
            return try JSONDecoder().decode(CloudKitStaffSharePlan.self, from: JSONSerialization.data(withJSONObject: root))
        }
        func payload(_ records: [[String: Any]]? = nil, plan: CloudKitStaffSharePlan? = nil, operation: UUID? = nil, sequence: Int = 1) throws -> StaffReplicaVerifiedPayload {
            let original = try cloud.payload(operation: operation, sequence: sequence), plan = try plan ?? self.plan()
            var root = try JSONSerialization.jsonObject(with: original.bytes) as! [String: Any]
            root["records"] = (records ?? self.records()).sorted { ($0["kind"] as! String, $0["id"] as! String) < ($1["kind"] as! String, $1["id"] as! String) }
            root["projectionPolicy"] = plan.projectionPolicy
            let bytes = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            var manifest = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original.manifest)) as! [String: Any]
            manifest["projectionPolicy"] = plan.projectionPolicy; manifest["payloadBytes"] = bytes.count
            manifest["payloadSHA256"] = StaffReplicaManifest.hash(bytes); manifest["recordCount"] = (root["records"] as! [[String: Any]]).count
            return try .init(manifest: JSONDecoder().decode(StaffReplicaManifest.self, from: JSONSerialization.data(withJSONObject: manifest)), bytes: bytes)
        }
        func graph(_ records: [[String: Any]], role: String = "Field Technician") throws -> StaffReplicaCoreGraph {
            let plan = try plan(role: role)
            return try .init(payload: payload(records, plan: plan), plan: plan, workspace: cloud.base.workspace, now: cloud.base.now)
        }
        func changing(_ kind: String, _ fields: [String: Any]) -> [[String: Any]] {
            records().map { value in
                guard value["kind"] as? String == kind else { return value }
                var result = value, existing = value["fields"] as! [String: Any]
                existing.merge(fields) { _, new in new }; result["fields"] = existing; return result
            }
        }
        func controller() -> StaffReplicaReceiveController {
            .init(dependencies: .init(check: { context in
                guard self.cloud.authorized, self.cloud.stamp == context.stamp else { throw StaffReplicaDeliveryError.access }
            }, download: { plan, context, url in
                let result = try await self.cloud.coordinator().download(plan: plan, context: context, invitation: url, requireCurrent: true,
                    validate: { _ = try StaffReplicaCoreGraph(payload: $0, plan: plan, workspace: context.workspace, now: self.cloud.base.now) })
                self.afterDownload?(); return result
            }, now: { self.cloud.base.now }))
        }
        func receive(_ controller: StaffReplicaReceiveController) async throws {
            try await controller.refresh(context: cloud.context(), plan: plan(), invitation: URL(string: "https://www.icloud.com/share/fixture")!)
        }
    }

    @Test func completeTypedFieldGraphPreservesPricesBooleansRelationshipsAndOriginalIDs() throws {
        let f = try Fixture(); defer { f.cleanup() }; let graph = try f.graph(f.records())
        #expect(graph.records.count == 6)
        #expect(graph.records.first { $0.kind == "item" }?.fields["unitPrice"] == .number(125.375))
        #expect(graph.records.first { $0.kind == "customer" }?.flag("allowsServiceText") == false)
        #expect(graph.records.first { $0.kind == "job" }?.ids("assignedTechnicianIDs") == [f.ids[3]])
    }
    @Test func taskIdentityIsStableAcrossRenderingButChangesWithOriginalAuthorityOrInvitation() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let stamp = try #require(f.cloud.stamp), plan = try f.plan(), url = URL(string: "https://www.icloud.com/share/original")!
        let identity = StaffReplicaReceiveIdentity(stamp: stamp, plan: plan, invitation: url, isActive: true)
        for _ in 0..<100 {
            let decoded = try JSONDecoder().decode(CloudKitStaffSharePlan.self, from: JSONEncoder().encode(plan))
            #expect(identity == StaffReplicaReceiveIdentity(stamp: stamp, plan: decoded, invitation: url, isActive: true))
        }
        #expect(identity != StaffReplicaReceiveIdentity(stamp: stamp, plan: plan, invitation: url, isActive: false))
        #expect(identity != StaffReplicaReceiveIdentity(stamp: stamp, plan: plan, invitation: nil, isActive: true))
        #expect(identity != StaffReplicaReceiveIdentity(stamp: stamp, plan: plan, invitation: URL(string: "https://www.icloud.com/share/other"), isActive: true))
        #expect(identity != StaffReplicaReceiveIdentity(stamp: stamp, plan: try f.plan(role: "Dispatcher"), invitation: url, isActive: true))
        let changed = CloudKitStaffSetupStamp(session: stamp.session, accountGeneration: UUID())
        #expect(identity != StaffReplicaReceiveIdentity(stamp: changed, plan: plan, invitation: url, isActive: true))
        let session = CompanyWorkspaceSession(backendOrigin: stamp.session.backendOrigin, email: stamp.session.email,
            tokenFingerprint: String(repeating: "d", count: 64), expiresAt: stamp.session.expiresAt)
        #expect(identity != StaffReplicaReceiveIdentity(stamp: .init(session: session, accountGeneration: stamp.accountGeneration),
            plan: plan, invitation: url, isActive: true))
    }
    @Test func unknownMissingWrongTypesBoundsAndControlCharactersCannotEnterStage() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let changes: [(String, [String: Any])] = [
            ("customer", ["name": " "]), ("customer", ["rawProviderPayload": "no"]),
            ("customer", ["allowsServiceText": 1]), ("customer", ["name": String(repeating: "x", count: 2049)]),
            ("customer", ["name": "bad\u{7F}"]), ("item", ["unitPrice": true]), ("item", ["unitPrice": -1]),
            ("item", ["unitPrice": 1_000_000_001]), ("item", ["reviewStatus": "anything"]),
            ("job", ["scheduledDate": "2026-09-09"]), ("job", ["customerID": f.ids[0].uppercased()]),
            ("job", ["assignedTechnicianIDs": [f.ids[3], f.ids[3]]]), ("technician", ["email": "BAD@EXAMPLE.INVALID"])]
        for (kind, fields) in changes { #expect(throws: (any Error).self) { try f.graph(f.changing(kind, fields)) } }
        var missing = f.records(); missing[0]["fields"] = ["email": "customer@example.invalid"]
        #expect(throws: (any Error).self) { try f.graph(missing) }
    }
    @Test func optionalNullsRemainAbsentWithoutInventingFieldValues() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let graph = try f.graph(f.changing("customer", ["email": NSNull(), "address": NSNull()]))
        #expect(graph.records.first { $0.kind == "customer" }?.fields["email"] == nil)
    }
    @Test func missingParentsWrongCustomerPropertiesAndCrewCannotBecomeAnEmptySuccess() throws {
        let f = try Fixture(); defer { f.cleanup() }
        for kind in ["customer", "location", "equipment", "technician"] {
            #expect(throws: (any Error).self) { try f.graph(f.records().filter { $0["kind"] as? String != kind }) }
        }
        for kind in ["location", "equipment", "job"] {
            #expect(throws: (any Error).self) { try f.graph(f.changing(kind, ["customerID": f.ids[7]])) }
        }
        #expect(throws: (any Error).self) { try f.graph(f.changing("job", ["scheduledFollowUpServiceCallID": f.ids[7]])) }
    }
    @Test func unrelatedStaffCustomerAndUnassignedJobCannotWidenFieldScope() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var records = f.records(); records.append(["kind": "customer", "id": f.ids[7], "revision": 1, "fields": ["name": "Other customer"]])
        #expect(throws: StaffReplicaDeliveryError.access) { try f.graph(records) }
        #expect(throws: StaffReplicaDeliveryError.access) { try f.graph(f.changing("job", ["assignedTechnicianIDs": []])) }
        #expect(throws: StaffReplicaDeliveryError.access) { try f.graph(f.changing("technician", ["email": "other@example.invalid"])) }
    }
    @Test func rolePricebookAndMarginRulesMatchServer() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let cost = f.changing("item", ["purchaseCost": 30])
        #expect(throws: StaffReplicaDeliveryError.access) { try f.graph(cost) }
        #expect(throws: StaffReplicaDeliveryError.access) { try f.graph(cost, role: "Dispatcher") }
        #expect(try f.graph(cost, role: "Admin").records.count == 6)
        #expect(throws: StaffReplicaDeliveryError.access) { try f.graph(f.changing("item", ["reviewStatus": "needs_review", "createdByEmail": "other@example.invalid"])) }
        #expect(try f.graph(f.changing("item", ["reviewStatus": "needs_review", "createdByEmail": f.cloud.base.member.email])).records.count == 6)
        for role in ["Standard", "Accounting"] {
            #expect(throws: StaffReplicaDeliveryError.access) { try f.graph(f.records(), role: role) }
            #expect(try f.graph([], role: role).records.isEmpty)
        }
    }
    @Test func realSharedAssetReceivesIntoEncryptedStageWithoutClaimingOperationalImport() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let original = try f.payload()
        _ = try await f.cloud.publish(original); f.cloud.signIn(owner: false)
        let controller = f.controller(); try await f.receive(controller)
        #expect(controller.received == original.manifest && !controller.isRunning)
        #expect(controller.message.contains("Full workspace data is still required"))
        let key = try f.cloud.coordinator().key(context: f.cloud.context(), plan: f.plan())
        let bytes = try #require(f.cloud.saved[key])
        let journal = try JSONDecoder().decode(StaffReplicaDeliveryJournal.self, from: bytes)
        #expect(journal.state == "staged" && journal.payload == original.bytes)
        #expect(f.cloud.saves == 1) // Receiving never writes CloudKit.
    }
    @Test func invalidGraphDoesNotReplaceAnExistingRetainedStage() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        _ = try await f.cloud.publish(f.payload()); f.cloud.signIn(owner: false)
        let controller = f.controller(); try await f.receive(controller)
        let key = try f.cloud.coordinator().key(context: f.cloud.context(), plan: f.plan())
        let before = try #require(f.cloud.saved[key])
        f.cloud.signIn(owner: true); f.cloud.sequence = 2
        let invalid = try f.payload(f.changing("customer", ["unknown": "never import"]), operation: UUID(), sequence: 2)
        _ = try await f.cloud.publish(invalid); f.cloud.signIn(owner: false)
        try await f.receive(controller)
        #expect(controller.received == nil && f.cloud.saved[key] == before)
    }
    @Test func staleDataFreshnessAndRevocationCannotShowReceived() async throws {
        for revoked in [false, true] {
            let f = try Fixture(); defer { f.cleanup() }; _ = try await f.cloud.publish(f.payload())
            f.cloud.signIn(owner: false)
            if revoked { f.cloud.authorized = false } else { f.cloud.sequence = 2 }
            let controller = f.controller(); try await f.receive(controller)
            #expect(controller.received == nil && f.cloud.saves == 1)
        }
    }
    @Test func accountOrViewReplacementDuringReceiptCannotRestoreOldDisplay() async throws {
        for account in [false, true] {
            let f = try Fixture(); defer { f.cleanup() }; _ = try await f.cloud.publish(f.payload())
            f.cloud.signIn(owner: false); let controller = f.controller()
            f.afterDownload = { if account { f.cloud.signIn(owner: true) } else { controller.clearDisplay() } }
            try await f.receive(controller); #expect(controller.received == nil)
        }
    }
}
