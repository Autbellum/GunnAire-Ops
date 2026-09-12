import Foundation
import CloudKit
import SwiftData
import XCTest
@testable import GunnAire_Ops

final class StaffWorkspaceOperationalDetailTests: XCTestCase {
    /// Retain MainActor handles across XCTest off-actor teardown.
    private enum DetailTestRetain {
        static var handles: [StaffWorkspaceOperationalActivatedStore] = []
        static var hosted: [StaffWorkspaceOperationalHostedStore] = []
    }

    struct Vector: Decodable {
        let receipt: StaffWorkspaceContentReceipt
        let payloadUtf8: String
    }

    private func vector() throws -> Vector {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "StaffWorkspaceContentTransportInterop", withExtension: "json"))
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    @MainActor
    private func scopeContextAndPlan() throws
    -> (CloudKitStaffSetupController.Context, CloudKitStaffSharePlan, CloudKitStaffSharingTests) {
        let base = CloudKitStaffSharingTests()
        let plan = try base.plan()
        let stamp = CloudKitStaffSetupStamp(
            session: .init(backendOrigin: "https://fixture.gunnaire.invalid", email: base.member.email,
                           tokenFingerprint: String(repeating: "1", count: 64),
                           expiresAt: base.now.addingTimeInterval(3600)),
            accountGeneration: UUID())
        let context = CloudKitStaffSetupController.Context(
            stamp: stamp, workspace: base.workspace,
            member: .init(email: base.member.email, role: plan.memberRole, isActive: true,
                          createdAt: base.instant),
            account: .init(environment: plan.environment, accountHash: base.participantHash,
                           recordName: base.participantName))
        return (context, plan, base)
    }

    private final class MemoryStore {
        var saved: [String: Data] = [:]
        var store: SharedTimeLocalStore {
            .init(read: { [self] in self.saved[$0] }, write: { [self] key, value in self.saved[key] = value })
        }
    }

    @MainActor
    private func installThroughHost(
        raw: Data, receipt: StaffWorkspaceContentReceipt,
        sealedSHA256: String, scope: CloudKitStaffSetupScope, plan: CloudKitStaffSharePlan,
        participantAccountHash: String, memory: MemoryStore
    ) throws -> StaffWorkspaceOperationalHostedStore {
        let manifest = try StaffWorkspaceCloudSealManifest(
            content: receipt, sealedSHA256: sealedSHA256, sealedBytes: raw.count + 28)
        _ = try StaffWorkspaceOperationalMountStore.install(
            opened: raw, manifest: manifest, store: memory.store, scope: scope, plan: plan.id, check: {})
        let view = try StaffWorkspaceOperationalAcceptanceStore.accept(
            store: memory.store, scope: scope, plan: plan.id, selectionID: receipt.selectionID)
        let imported = try StaffWorkspaceOperationalImportStore.importAccepted(
            store: memory.store, scope: scope, plan: plan.id, selectionID: view.selectionID)
        let activated = try StaffWorkspaceOperationalStoreActivator.activate(
            plan: imported, store: memory.store, scope: scope, planID: plan.id)
        DetailTestRetain.handles = [activated]
        _ = try StaffWorkspaceOperationalConvergenceStore.prove(
            head: manifest, plan: plan, participantAccountHash: participantAccountHash,
            zoneName: plan.zoneName, store: memory.store, scope: scope, planID: plan.id)
        _ = try StaffWorkspaceOperationalReadyStore.markReady(
            plan: plan, store: memory.store, scope: scope, planID: plan.id)
        let hosted = try StaffWorkspaceOperationalHostStore.open(
            plan: plan, store: memory.store, scope: scope, planID: plan.id)
        DetailTestRetain.hosted = [hosted]
        return hosted
    }

    private func encodeFields(_ fields: [String: StaffWorkspaceValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(fields)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func encodeUnavailable(
        _ fields: [String: StaffWorkspaceBillingProjection.Unavailable]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(fields)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    func testCustomerTitleFromAvailableName() throws {
        let available = try encodeFields([
            "name": .text("Original customer"),
            "email": .null,
            "preferredContactMethodRaw": .text("email")
        ])
        let unavailable = try encodeUnavailable([
            "quickBooksID": .roleRestricted
        ])
        let summary = StaffWorkspaceOperationalDetail.summary(
            kind: "customer",
            recordID: "9d98492b-8093-46d4-b89e-e9c745f5beab",
            availableFieldsJSON: available,
            unavailableFieldsJSON: unavailable
        )
        XCTAssertEqual(summary.title, "Original customer")
        XCTAssertEqual(summary.kindBadge, "Customer")
        XCTAssertTrue(summary.hasRestrictedFields)
        XCTAssertTrue(summary.badges.contains("Restricted"))
    }

    func testInvoiceTitleStatusAndCurrencyAmount() throws {
        let available = try encodeFields([
            "status": .text("unpaid"),
            "amount": .number(205.65),
            "lineItemSummary": .text("")
        ])
        let unavailable = try encodeUnavailable([
            "quickBooksID": .roleRestricted
        ])
        let summary = StaffWorkspaceOperationalDetail.summary(
            kind: "invoice",
            recordID: "52be8b00-7a09-49c5-9096-424a00043ef0",
            availableFieldsJSON: available,
            unavailableFieldsJSON: unavailable
        )
        // Preference: number, status, total, amount, balanceDue → status then amount
        XCTAssertEqual(summary.title, "unpaid")
        XCTAssertTrue(summary.subtitle.contains("$"), "Expected currency subtitle, got \(summary.subtitle)")
        XCTAssertTrue(summary.subtitle.contains("205.65") || summary.subtitle.contains("205"),
                      "Expected amount in subtitle: \(summary.subtitle)")

        let detail = StaffWorkspaceOperationalDetail.detail(
            kind: "invoice",
            recordID: "52be8b00-7a09-49c5-9096-424a00043ef0",
            revision: 1,
            bodyKind: "billing",
            availableFieldsJSON: available,
            unavailableFieldsJSON: unavailable
        )
        let amount = try XCTUnwrap(detail.fields.first { $0.key == "amount" })
        XCTAssertFalse(amount.isRestricted)
        XCTAssertTrue(amount.displayValue.contains("$"))
        let restricted = try XCTUnwrap(detail.fields.first { $0.key == "quickBooksID" })
        XCTAssertTrue(restricted.isRestricted)
        XCTAssertEqual(restricted.displayValue, "Restricted")
    }

    func testJobTitleFromStatusAndScheduledDate() throws {
        let date = Date(timeIntervalSinceReferenceDate: 810123456.123456)
        let available = try encodeFields([
            "status": .text("scheduled"),
            "scheduledDate": .date(date),
            "type": .text("repair")
        ])
        let summary = StaffWorkspaceOperationalDetail.summary(
            kind: "job",
            recordID: "ecc96bf1-0a93-42cc-b497-a580799067b9",
            availableFieldsJSON: available,
            unavailableFieldsJSON: "{}"
        )
        XCTAssertEqual(summary.title, "scheduled")
        XCTAssertFalse(summary.subtitle.isEmpty)
        XCTAssertFalse(summary.hasRestrictedFields)
    }

    func testRestrictedUnavailableNotInventedFromStructured() throws {
        let available = try encodeFields([
            "amount": .number(12.125),
            "method": .text("cash")
        ])
        let unavailable = try encodeUnavailable([
            "cardLast4": .roleRestricted,
            "notes": .roleRestricted,
            "authorizationReference": .roleRestricted
        ])
        let detail = StaffWorkspaceOperationalDetail.detail(
            kind: "payment",
            recordID: "640f75a3-f70c-4d32-b9e2-41e88382acf7",
            revision: 1,
            bodyKind: "operational",
            availableFieldsJSON: available,
            unavailableFieldsJSON: unavailable
        )
        XCTAssertEqual(detail.summary.title.contains("$") || detail.summary.title == "12.125"
                       || detail.summary.title.contains("12"), true)
        for key in ["cardLast4", "notes", "authorizationReference"] {
            let row = try XCTUnwrap(detail.fields.first { $0.key == key })
            XCTAssertTrue(row.isRestricted)
            XCTAssertEqual(row.displayValue, "Restricted")
        }
        // Available method must not be overwritten by restricted placeholders.
        let method = try XCTUnwrap(detail.fields.first { $0.key == "method" })
        XCTAssertEqual(method.displayValue, "cash")
        XCTAssertFalse(method.isRestricted)
    }

    func testCorruptJSONFailsSoft() {
        let summary = StaffWorkspaceOperationalDetail.summary(
            kind: "customer",
            recordID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            availableFieldsJSON: "{not-json",
            unavailableFieldsJSON: "%%%"
        )
        XCTAssertTrue(summary.title.contains("Customer"))
        XCTAssertTrue(summary.title.contains("…") || summary.title.contains("aaaaaaaa"))
        XCTAssertFalse(summary.hasRestrictedFields)

        let detail = StaffWorkspaceOperationalDetail.detail(
            kind: "invoice",
            recordID: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff",
            revision: 0,
            bodyKind: "billing",
            availableFieldsJSON: "",
            unavailableFieldsJSON: "null"
        )
        XCTAssertTrue(detail.fields.isEmpty)
        XCTAssertTrue(detail.summary.title.contains("Invoice"))
    }

    func testValueFormattingCases() {
        XCTAssertEqual(StaffWorkspaceOperationalDetail.format(.text("Hello")), "Hello")
        XCTAssertEqual(StaffWorkspaceOperationalDetail.format(.flag(true)), "Yes")
        XCTAssertEqual(StaffWorkspaceOperationalDetail.format(.flag(false)), "No")
        XCTAssertEqual(StaffWorkspaceOperationalDetail.format(.integer(42)), "42")
        XCTAssertEqual(StaffWorkspaceOperationalDetail.format(.null), "—")
        let money = StaffWorkspaceOperationalDetail.format(.number(10.5), currency: true)
        XCTAssertTrue(money.contains("$"))
        let id = UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!
        XCTAssertEqual(StaffWorkspaceOperationalDetail.format(.identifier(id)), id.uuidString)
    }

    @MainActor
    func testInteropHostedRowsProjectListAndDetail() throws {
        let vector = try vector()
        let raw = Data(vector.payloadUtf8.utf8)
        let (context, plan, _) = try scopeContextAndPlan()
        let memory = MemoryStore()
        let sealed = String(repeating: "b", count: 64)
        let hosted = try installThroughHost(
            raw: raw, receipt: vector.receipt, sealedSHA256: sealed,
            scope: context.scope, plan: plan, participantAccountHash: context.account.accountHash,
            memory: memory)

        try StaffWorkspaceOperationalPresentation.requireHosted(hosted)
        let modelContext = ModelContext(hosted.container)
        modelContext.autosaveEnabled = false
        let rows = try modelContext.fetch(FetchDescriptor<StaffWorkspaceOperationalProjectionRecord>())
        XCTAssertFalse(rows.isEmpty)

        let customer = try XCTUnwrap(rows.first { $0.kind == "customer" })
        let customerSummary = StaffWorkspaceOperationalDetail.summary(for: customer)
        XCTAssertEqual(customerSummary.title, "Original customer")
        XCTAssertTrue(customerSummary.hasRestrictedFields)

        let customerDetail = StaffWorkspaceOperationalDetail.detail(for: customer)
        XCTAssertEqual(customerDetail.summary.title, customerSummary.title)
        XCTAssertTrue(customerDetail.fields.contains { $0.key == "name" && !$0.isRestricted })
        XCTAssertTrue(customerDetail.fields.contains {
            $0.key == "quickBooksID" && $0.isRestricted && $0.displayValue == "Restricted"
        })

        let invoice = try XCTUnwrap(rows.first { $0.kind == "invoice" })
        let invoiceSummary = StaffWorkspaceOperationalDetail.summary(for: invoice)
        XCTAssertFalse(invoiceSummary.title.isEmpty)
        XCTAssertNotEqual(invoiceSummary.title, invoice.kind)
        let invoiceDetail = StaffWorkspaceOperationalDetail.detail(for: invoice)
        XCTAssertEqual(invoiceDetail.bodyKind, "billing")
        XCTAssertTrue(invoiceDetail.fields.contains { $0.key == "status" || $0.key == "amount" })

        let job = try XCTUnwrap(rows.first { $0.kind == "job" })
        let jobSummary = StaffWorkspaceOperationalDetail.summary(for: job)
        XCTAssertFalse(jobSummary.title.isEmpty)
        // Must not invent title from structured extras / restricted keys.
        XCTAssertFalse(jobSummary.title.lowercased().contains("google"))
    }
}
