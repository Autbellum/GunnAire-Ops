import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct StaffWorkspaceDiscriminatorTests {
    typealias D = StaffWorkspaceDiscriminators
    typealias R = StaffWorkspaceModelRecord
    typealias C = StaffWorkspaceModelCodecs
    typealias G = StaffWorkspaceRelationshipGraph

    func records() throws -> [R] { try StaffWorkspaceFullModelTests().encodedFixtures() }
    func replace(_ row: R, field: String, value: StaffWorkspaceValue) -> R {
        .init(version: row.version, kind: row.kind, id: row.id, fields: row.fields.merging([field: value]) { _, next in next })
    }

    @Test func everyRawFieldInAll32ActualModelsIsClassifiedWithoutInventingDefaults() throws {
        try D.validateCoverage()
        let input = try records()
        #expect(D.rules.count == 32)
        #expect(try G.validate(input.reversed()).recordCount == 32)
        for row in input {
            let codec = try #require(StaffWorkspaceModelCatalog.all.first { $0.kind == row.kind })
            try D.validate(row)
            for (field, rule) in D.rules[row.kind]! {
                let invalid: [StaffWorkspaceValue]
                switch rule {
                case .integer: invalid = [.integer(-1), .integer(0), .integer(8), .integer(2_147_483_647)]
                case .text, .lines: invalid = [.text("future-unrecognized-value"), .text(" valid "), .text("null"), .text("{}")]
                }
                for value in invalid {
                    let bad = replace(row, field: field, value: value)
                    if (try? codec.validate(bad)) != nil {
                        #expect(throws: StaffWorkspaceDiscriminatorError.unrecognized(source: .init(kind: row.kind, id: row.id), field: field)) { try D.validate(bad) }
                    } else {
                        // The two enum-typed job fields already reject unknown
                        // cases in their scalar codec; retain that earlier gate.
                        #expect(throws: StaffWorkspaceModelError.self) { try D.validate(bad) }
                    }
                    // The real graph entry point uses the same check before it
                    // can reconstruct models or expose computed fallback values.
                    #expect(throws: (any Error).self) { try G.validate(input.map { $0.id == row.id ? bad : $0 }) }
                }
            }
        }
    }

    @Test func unknownValuesRemainLosslesslyAvailableButCannotBecomeNormalDispatchOrPaidTax() throws {
        var input = try records()
        let shift = try #require(input.first { $0.kind == "shift" })
        let unknown = replace(shift, field: "weekdayRawValue", value: .integer(0))
        input = input.map { $0.id == shift.id ? unknown : $0 }
        // Reproduce the existing getter hazard independently of the new gate.
        let rawCopies = try StaffWorkspaceModelCatalog.decodeDetached(input)
        let rawShift = try #require(rawCopies.compactMap { $0 as? TechnicianWorkShift }.first)
        #expect(rawShift.weekdayRawValue == 0 && rawShift.weekday == .monday)
        #expect(try C.shift.encode(rawShift) == unknown)
        #expect(throws: StaffWorkspaceDiscriminatorError.self) { try G.validate(input) }
        #expect(try StaffWorkspaceModelRecord.decode(JSONEncoder().encode(input)) == input)

        let job = ServiceCall(type: .service, scheduledDate: Date(), customer: Customer(name: "Original"))
        job.dispatchUrgencyRaw = "future-urgency"
        #expect(job.dispatchUrgency == .normal)
        #expect(throws: StaffWorkspaceDiscriminatorError.self) { try D.validate(C.job.encode(job)) }
        #expect(job.dispatchUrgencyRaw == "future-urgency")
        let invoice = Invoice(customer: job.customer)
        invoice.taxCalculationStatusRawValue = "future-tax-status"
        #expect(throws: StaffWorkspaceDiscriminatorError.self) { try D.validate(C.invoice.encode(invoice)) }
        #expect(invoice.taxCalculationStatusRawValue == "future-tax-status" && invoice.quickBooksID == nil)
    }

    @Test func everySupportedSchedulingRoleCatalogAndTaxChoiceRetainsExactRawValues() throws {
        let input = try records()
        func accepts(_ kind: String, _ field: String, _ values: [StaffWorkspaceValue]) throws {
            let original = try #require(input.first { $0.kind == kind })
            for value in values {
                let changed = replace(original, field: field, value: value)
                try D.validate(changed)
                #expect(changed.fields[field] == value)
            }
        }
        try accepts("shift", "weekdayRawValue", TechnicianWeekday.allCases.map { .integer($0.rawValue) })
        try accepts("user", "roleRawValue", AppUserRole.allCases.map { .text($0.rawValue) })
        try accepts("job", "dispatchUrgencyRaw", ServiceRequestUrgency.allCases.map { .text($0.rawValue) })
        try accepts("job", "visitDispositionRaw", ServiceVisitDisposition.allCases.map { .text($0.rawValue) })
        try accepts("item", "itemTypeRawValue", CatalogItemType.allCases.map { .text($0.rawValue) })
        try accepts("item", "pricebookReviewStatusRawValue", PricebookReviewStatus.allCases.map { .text($0.rawValue) })
        try accepts("invoice", "workTypeRaw", InvoiceWorkType.allCases.map { .text($0.rawValue) })
        try accepts("estimate", "proposalOption", EstimateProposalOption.allCases.map { .text($0.rawValue) })
        try accepts("estimate", "customerApprovalMethodRaw", EstimateApprovalMethod.allCases.map { .text($0.rawValue) })
        try accepts("invoice", "taxCalculationStatusRawValue", ["not_applicable", "pending_quickbooks", "calculated_by_quickbooks", "needs_attention"].map { .text($0) })
    }

    @Test func optionalNullAndExplicitUnknownCatalogTypeAreNotGuessedOrRemoved() throws {
        for row in try records() {
            let codec = try #require(StaffWorkspaceModelCatalog.all.first { $0.kind == row.kind })
            for field in D.rules[row.kind]!.keys {
                let changed = replace(row, field: field, value: .null)
                if (try? codec.validate(changed)) != nil { try D.validate(changed); #expect(changed.fields[field] == .null) }
                else { #expect(throws: StaffWorkspaceModelError.self) { try D.validate(changed) } }
            }
        }
        let item = Item(name: "Original unmapped product", unitPrice: 123.375)
        item.itemTypeRawValue = CatalogItemType.unknown.rawValue
        try D.validate(C.item.encode(item))
        #expect(item.itemType == .unknown && !item.itemType.isDirectSalesItem)
        item.itemTypeRawValue = "FutureInventory"
        #expect(throws: StaffWorkspaceDiscriminatorError.self) { try D.validate(C.item.encode(item)) }
        #expect(item.itemTypeRawValue == "FutureInventory")
    }

    @Test func fleetFailureListsCannotDropUnknownDuplicateOrEmptyMembers() throws {
        let original = try #require(records().first { $0.kind == "vehicleEvent" })
        let all = FleetInspectionItem.allCases.map(\.rawValue)
        for value in ["", all.joined(separator: "\n"), all.reversed().joined(separator: "\n")] {
            let changed = replace(original, field: "failedInspectionItemsRaw", value: .text(value))
            try D.validate(changed); #expect(changed.fields["failedInspectionItemsRaw"] == .text(value))
        }
        for value in [all[0] + "\nfuture_safety_item", all[0] + "\n" + all[0], all[0] + "\n", "\n" + all[0], all[0] + "\r\n" + all[1]] {
            #expect(throws: StaffWorkspaceDiscriminatorError.self) {
                try D.validate(replace(original, field: "failedInspectionItemsRaw", value: .text(value)))
            }
        }
    }

    @Test func allSixOriginalAttachmentReceiptTypesPreserveIDsWithoutReuploading() throws {
        let models = StaffWorkspaceFullModelTests().fixtures()
        let attachment = try #require(models.compactMap { $0 as? ServiceDocumentAttachment }.first)
        let keys = QuickBooksAttachableEntityType.allCases.map {
            ServiceDocumentAttachment.quickBooksAttachedEntityKey(type: $0.rawValue, value: "original:123-ABC")
        }
        attachment.quickBooksAttachableID = "original-attachable"
        attachment.quickBooksAttachedEntityKeysRaw = keys.reversed().joined(separator: "\n")
        let source = try C.attachment.encode(attachment)
        try D.validate(source)
        #expect(source.fields["quickBooksAttachedEntityKeysRaw"] == .text(keys.reversed().joined(separator: "\n")))
        #expect(attachment.quickBooksAttachableID == "original-attachable" && attachment.localFilePath == "/DO-NOT-TRANSFER/owner-file.pdf")
        for text in ["Invoice:123", "future:123", "invoice:", "invoice:..", "invoice:original id", "invoice:123\ninvoice:123", "invoice:123\n", "invoice:123\nbill:bad/value"] {
            #expect(throws: StaffWorkspaceDiscriminatorError.self) {
                try D.validate(replace(source, field: "quickBooksAttachedEntityKeysRaw", value: .text(text)))
            }
        }
        try D.validate(replace(source, field: "quickBooksAttachedEntityKeysRaw", value: .null))
        try D.validate(replace(source, field: "quickBooksAttachedEntityKeysRaw", value: .text("")))
    }

    @Test func recognizedReplicaRoleNeverBecomesMembershipAuthority() throws {
        let user = AppUser(email: "owner@example.invalid", role: .admin)
        let row = try C.user.encode(user)
        try D.validate(row)
        let copy = try C.user.decodeDetached(row, resolver: .init())
        #expect(AppAccess.activeRole(email: copy.email, users: [copy], verifiedUser: nil) == nil)
        #expect(copy.roleRawValue == AppUserRole.admin.rawValue)
    }

    @Test func rejectedSavedSourceRemainsIntactAndDoesNotSaveOrReplaceThePreviousGraph() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GAStaffDiscriminator-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, url: root.appendingPathComponent("source.store"), cloudKitDatabase: .none)])
        let writer = ModelContext(container); writer.autosaveEnabled = false
        for model in try G.validate(records()).decodeDetached() { writer.insert(model) }
        try writer.save()
        let prior = try G.captureSaved(in: writer)
        let job = try #require(writer.fetch(FetchDescriptor<ServiceCall>()).first)
        let originalUrgency = job.dispatchUrgencyRaw
        job.dispatchUrgencyRaw = "future-urgent-code"; try writer.save()
        let reader = ModelContext(container); reader.autosaveEnabled = false
        #expect(throws: StaffWorkspaceDiscriminatorError.self) { try G.captureSaved(in: reader) }
        #expect(!reader.hasChanges && !writer.hasChanges)
        #expect(try reader.fetch(FetchDescriptor<ServiceCall>()).first?.dispatchUrgencyRaw == "future-urgent-code")
        #expect(try reader.fetchCount(FetchDescriptor<ServiceCall>()) == 1)
        let priorJob = try #require(prior.decodeDetached().compactMap { $0 as? ServiceCall }.first)
        #expect(priorJob.dispatchUrgencyRaw == originalUrgency)
    }
}
