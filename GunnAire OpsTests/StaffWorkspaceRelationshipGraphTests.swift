import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct StaffWorkspaceRelationshipGraphTests {
    typealias C = StaffWorkspaceModelCodecs
    typealias R = StaffWorkspaceModelRecord
    typealias G = StaffWorkspaceRelationshipGraph
    let date = Date(timeIntervalSinceReferenceDate: 810_123_456.123456)

    func base() throws -> [R] { try StaffWorkspaceFullModelTests().encodedFixtures() }
    func row(_ kind: String, _ records: [R]) throws -> R { try #require(records.first { $0.kind == kind }) }
    func replacing(_ source: R, _ values: [String: StaffWorkspaceValue]) -> R {
        .init(version: source.version, kind: source.kind, id: source.id, fields: source.fields.merging(values) { _, next in next })
    }
    func replacing(_ records: [R], _ kind: String, _ values: [String: StaffWorkspaceValue]) -> [R] {
        records.map { $0.kind == kind ? replacing($0, values) : $0 }
    }
    func list(_ ids: [UUID]) throws -> StaffWorkspaceValue { .text(String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)) }

    @Test func everyModelUUIDAndOwningReferenceIsClassifiedAndTheCompleteGraphReconstructs() throws {
        try StaffWorkspaceRecordLinks.validateCoverage()
        let records = try base()
        let graph = try G.validate(records.reversed())
        #expect(graph.recordCount == 32)
        let copies = try graph.decodeDetached()
        #expect(copies.count == 32 && copies.allSatisfy { $0.modelContext == nil })
        #expect(try StaffWorkspaceFullModelTests().encoded(copies) == records.sorted { $0.kind + $0.id.uuidString < $1.kind + $1.id.uuidString })
        #expect(StaffWorkspaceRecordLinks.scalar.values.reduce(0) { $0 + $1.count } > 50)
    }

    @Test func everyDeclaredForeignKeyRequiresItsExactKindAndIdentity() throws {
        let records = try base()
        for record in records {
            let dispositions = StaffWorkspaceRecordLinks.scalar[record.kind]!.merging(StaffWorkspaceRecordLinks.owning[record.kind, default: [:]]) { a, _ in a }
            for (field, disposition) in dispositions {
                guard case .link(let target, _) = disposition else { continue }
                let missing = UUID()
                let changed = replacing(records, record.kind, [field: .identifier(missing)])
                #expect(throws: StaffWorkspaceLinkError.missing(source: .init(kind: record.kind, id: record.id),
                    field: field, target: .init(kind: target, id: missing))) { try G.validate(changed) }
            }
        }
        let duplicate = records + [records[0]]
        #expect(throws: StaffWorkspaceModelError.invalid) { try G.validate(duplicate) }
        #expect(throws: StaffWorkspaceModelError.invalid) { try G.validate([.init(version: 1, kind: "unclassified", id: UUID(), fields: [:])]) }
    }

    @Test func customerJobEquipmentBillingFilesAndProjectLinksCannotCrossCustomers() throws {
        let original = try base()
        let otherCustomer = Customer(name: "Another customer")
        let otherLocation = CustomerServiceLocation(customer: otherCustomer, name: "Other property", address: "Other address")
        let otherJob = ServiceCall(type: .service, scheduledDate: date, customer: otherCustomer)
        let otherInvoice = Invoice(customer: otherCustomer)
        let otherEstimate = Estimate(customer: otherCustomer)
        let others = try [C.customer.encode(otherCustomer), C.location.encode(otherLocation), C.job.encode(otherJob), C.invoice.encode(otherInvoice), C.estimate.encode(otherEstimate)]
        let customer = try row("customer", original)
        let scenarios: [(String, [String: StaffWorkspaceValue])] = [
            ("equipment", ["serviceLocationID": .identifier(otherLocation.id)]),
            ("job", ["serviceLocationID": .identifier(otherLocation.id)]),
            ("invoice", ["serviceCallID": .identifier(otherJob.id)]),
            ("estimate", ["scheduledServiceCallID": .identifier(otherJob.id)]),
            ("attachment", ["invoiceID": .identifier(otherInvoice.id)]),
            ("communication", ["estimateID": .identifier(otherEstimate.id)]),
            ("expense", ["serviceCallID": .identifier(otherJob.id)]),
            ("task", ["customerID": .identifier(customer.id), "estimateID": .identifier(otherEstimate.id)]),
            ("request", ["convertedCustomerID": .identifier(customer.id), "convertedServiceCallID": .identifier(otherJob.id)]),
            ("milestone", ["estimateID": .identifier(otherEstimate.id)]),
        ]
        for (kind, values) in scenarios {
            do { _ = try G.validate(replacing(original, kind, values) + others); Issue.record("Accepted cross-customer \(kind) link") }
            catch StaffWorkspaceLinkError.conflictingScope(_, _, let scope) { #expect(scope == .customer) }
        }
        // Shared pricebooks/templates/crew are not customer-owned edges.
        #expect(try G.validate(original + others).recordCount == 37)
    }

    @Test func historicalPropertyAndFleetAssignmentAreNotRewrittenToCurrentValues() throws {
        let original = try base(), customer = try row("customer", original)
        let owner = Customer(id: customer.id, name: "Original")
        let a = try C.location.encode(CustomerServiceLocation(customer: owner, name: "Original property", address: "10 Main"))
        let b = try C.location.encode(CustomerServiceLocation(customer: owner, name: "Current property", address: "20 Main"))
        var records = replacing(original, "job", ["serviceLocationID": .identifier(a.id), "customerEquipmentID": .identifier(try row("equipment", original).id), "equipmentSerialNumber": .text("ORIGINAL-SERIAL")])
        records = replacing(records, "equipment", ["serviceLocationID": .identifier(b.id), "serialNumber": .text("CURRENT-SERIAL")])
        let otherTech = Technician(name: "Historical technician")
        records = replacing(records, "vehicle", ["assignedTechnicianID": .identifier(try row("technician", original).id)])
        records = replacing(records, "vehicleEvent", ["assignmentTechnicianID": .identifier(otherTech.id)])
        let copies = try G.validate(records + [a, b, C.technician.encode(otherTech)]).decodeDetached()
        let job = try #require(copies.compactMap { $0 as? ServiceCall }.first)
        let equipment = try #require(copies.compactMap { $0 as? CustomerEquipment }.first)
        #expect(job.serviceLocationID == a.id && equipment.serviceLocationID == b.id)
        #expect(job.equipmentSerialNumber == "ORIGINAL-SERIAL" && equipment.serialNumber == "CURRENT-SERIAL")
    }

    @Test func proposalGroupsStayWithOneCustomerAndOperationIDsDoNotBecomeForeignKeys() throws {
        let original = try base(), group = UUID()
        let other = Customer(name: "Other customer"), estimate = Estimate(customer: Customer(name: "Unused"))
        estimate.customer = other; estimate.proposalGroupID = group
        let changed = replacing(original, "estimate", ["proposalGroupID": .identifier(group)])
        #expect(throws: StaffWorkspaceLinkError.self) { try G.validate(changed + [C.customer.encode(other), C.estimate.encode(estimate)]) }
        let sameCustomer = Customer(id: try row("customer", original).id, name: "Original")
        estimate.customer = sameCustomer
        #expect(try G.validate(changed + [C.estimate.encode(estimate)]).recordCount == 33)
        for record in original {
            for (field, disposition) in StaffWorkspaceRecordLinks.scalar[record.kind]! {
                if case .evidence = disposition {
                    #expect(try G.validate(replacing(original, record.kind, [field: .identifier(UUID())])).recordCount == 32)
                }
            }
        }
    }

    @Test func timeOffAndVehicleFilesCannotClaimAnotherProfileOrAsset() throws {
        let original = try base(), request = try row("timeOff", original), block = try row("availability", original)
        var linked = replacing(original, "timeOff", ["approvedAvailabilityBlockID": .identifier(block.id)])
        linked = replacing(linked, "availability", ["sourceTimeOffRequestID": .identifier(request.id)])
        linked = replacing(linked, "availabilityEvent", ["requestID": .identifier(request.id), "availabilityBlockID": .identifier(block.id)])
        #expect(try G.validate(linked).recordCount == 32)
        let otherTech = Technician(name: "Other profile")
        #expect(throws: StaffWorkspaceLinkError.self) { try G.validate(replacing(linked, "availability", ["technicianID": .identifier(otherTech.id)]) + [C.technician.encode(otherTech)]) }
        let otherVehicle = FleetVehicle(unitNumber: "Other truck", stockLocation: "Other truck")
        let changed = replacing(original, "attachment", ["fleetVehicleID": .identifier(otherVehicle.id), "fleetVehicleEventID": .identifier(try row("vehicleEvent", original).id)])
        #expect(throws: StaffWorkspaceLinkError.self) { try G.validate(changed + [C.vehicle.encode(otherVehicle)]) }
    }

    @Test func refundsUseTheOriginalInvoiceWithoutDeclaringOrRepeatingPayment() throws {
        let original = try base(), customer = Customer(id: try row("customer", original).id, name: "Original")
        let invoice = Invoice(id: try row("invoice", original).id, customer: customer)
        let refund = Payment(invoice: invoice, amount: 1.125, date: date, isRefund: true, refundedPaymentID: try row("payment", original).id)
        #expect(try G.validate(original + [C.payment.encode(refund)]).recordCount == 33)
        let secondInvoice = Invoice(customer: customer); refund.invoice = secondInvoice
        #expect(throws: StaffWorkspaceLinkError.self) { try G.validate(original + [C.invoice.encode(secondInvoice), C.payment.encode(refund)]) }
        refund.invoice = invoice; refund.isRefund = false
        #expect(throws: StaffWorkspaceLinkError.self) { try G.validate(original + [C.payment.encode(refund)]) }
        #expect(refund.amount == 1.125 && refund.providerPaymentStatus == nil)
    }

    @Test func originalFollowUpAndChangeOrderChainsRejectCyclesButKeepOlderSiblings() throws {
        let original = try base(), job = try row("job", original)
        let customer = Customer(id: try row("customer", original).id, name: "Original")
        let earlier = ServiceCall(type: .repair, scheduledDate: date, customer: customer, originatingServiceCallID: job.id)
        let later = ServiceCall(type: .repair, scheduledDate: date, customer: customer, originatingServiceCallID: job.id)
        let changed = replacing(original, "job", ["scheduledFollowUpServiceCallID": .identifier(later.id)])
        #expect(try G.validate(changed + [C.job.encode(earlier), C.job.encode(later)]).recordCount == 34)
        later.originatingServiceCallID = earlier.id
        #expect(throws: StaffWorkspaceLinkError.self) { try G.validate(changed + [C.job.encode(earlier), C.job.encode(later)]) }
        let estimate = try row("estimate", original)
        let child = Estimate(parentEstimateID: estimate.id, customer: customer)
        #expect(throws: StaffWorkspaceLinkError.cycle(kind: "estimate", field: "parentEstimateID")) {
            try G.validate(replacing(original, "estimate", ["parentEstimateID": .identifier(child.id)]) + [C.estimate.encode(child)])
        }
        #expect(throws: StaffWorkspaceLinkError.cycle(kind: "job", field: "originatingServiceCallID")) {
            try G.validate(replacing(original, "job", ["originatingServiceCallID": .identifier(job.id)]))
        }
    }

    @Test func crewAndCoveredEquipmentListsRejectMissingDuplicateAndForeignMembers() throws {
        let original = try base(), technician = try row("technician", original), equipment = try row("equipment", original)
        let extra = Technician(name: "Additional crew")
        let positive = try replacing(replacing(original, "job", ["additionalTechnicianIDsJSON": list([extra.id])]), "agreement", ["coveredEquipmentIDsJSON": list([equipment.id])])
        #expect(try G.validate(positive + [C.technician.encode(extra)]).recordCount == 33)
        for text in ["{}", "null", "[null]", "[\"invalid-uuid\"]", "[true]"] {
            #expect(throws: StaffWorkspaceLinkError.self) { try G.validate(replacing(original, "job", ["additionalTechnicianIDsJSON": .text(text)])) }
        }
        for ids in [[UUID()], [technician.id], [extra.id, extra.id]] {
            #expect(throws: StaffWorkspaceLinkError.self) { try G.validate(replacing(original, "job", ["additionalTechnicianIDsJSON": list(ids)]) + [C.technician.encode(extra)]) }
        }
        let other = Customer(name: "Other"), otherEquipment = CustomerEquipment(name: "Other system")
        otherEquipment.customer = other
        #expect(throws: StaffWorkspaceLinkError.self) {
            try G.validate(replacing(original, "agreement", ["coveredEquipmentIDsJSON": list([otherEquipment.id])]) + [C.customer.encode(other), C.equipment.encode(otherEquipment)])
        }
    }

    @Test func linkedBillingDocumentsCannotSelectAnotherJobForTheSameCustomer() throws {
        let original = try base(), job = try row("job", original), estimate = try row("estimate", original), invoice = try row("invoice", original)
        let customer = Customer(id: try row("customer", original).id, name: "Original")
        let scheduled = ServiceCall(type: .install, scheduledDate: date, customer: customer)
        let linked = replacing(original, "job", ["linkedEstimateID": .identifier(estimate.id), "linkedInvoiceID": .identifier(invoice.id)]) + [try C.job.encode(scheduled)]
        // Standalone documents keep their original explicit links.
        #expect(try G.validate(linked).recordCount == 33)
        let wrongEstimate = replacing(linked, "estimate", ["scheduledServiceCallID": .identifier(scheduled.id)])
        #expect(throws: StaffWorkspaceLinkError.inconsistent(source: .init(kind: "job", id: job.id), field: "linkedEstimateID")) {
            try G.validate(wrongEstimate)
        }
        #expect(try G.validate(replacing(wrongEstimate, "estimate", ["serviceCallID": .identifier(job.id)])).recordCount == 33)
        #expect(try G.validate(replacing(linked, "estimate", ["scheduledServiceCallID": .identifier(job.id)])).recordCount == 33)
        #expect(throws: StaffWorkspaceLinkError.inconsistent(source: .init(kind: "job", id: job.id), field: "linkedInvoiceID")) {
            try G.validate(replacing(linked, "invoice", ["serviceCallID": .identifier(scheduled.id)]))
        }
        #expect(try G.validate(replacing(linked, "invoice", ["serviceCallID": .identifier(job.id)])).recordCount == 33)
    }

    @Test func backlinksCannotSubstituteAnotherOriginalInTheSameScope() throws {
        let original = try base()
        let scenarios = [
            ("timeOff", "approvedAvailabilityBlockID", "availability", "sourceTimeOffRequestID"),
            ("availability", "sourceTimeOffRequestID", "timeOff", "approvedAvailabilityBlockID"),
            ("expense", "receiptAttachmentID", "attachment", "expenseClaimID"),
            ("milestone", "invoiceID", "invoice", "projectMilestoneID"),
        ]
        for (sourceKind, field, targetKind, backlink) in scenarios {
            let source = try row(sourceKind, original), target = try row(targetKind, original)
            let alternate = R(version: source.version, kind: source.kind, id: UUID(), fields: source.fields)
            let linked = replacing(original, sourceKind, [field: .identifier(target.id)])
            #expect(try G.validate(replacing(linked, targetKind, [backlink: .identifier(source.id)])).recordCount == 32)
            #expect(throws: StaffWorkspaceLinkError.inconsistent(source: .init(kind: sourceKind, id: source.id), field: field)) {
                try G.validate(replacing(linked, targetKind, [backlink: .identifier(alternate.id)]) + [alternate])
            }
        }
    }

    @Test func longChangeOrderHistoryValidatesWithoutRecursiveTraversal() throws {
        var records = try base()
        let customer = Customer(id: try row("customer", records).id, name: "Original")
        let originalEstimate = try row("estimate", records)
        var parent = originalEstimate.id
        for _ in 0..<512 {
            let child = Estimate(parentEstimateID: parent, customer: customer)
            records.append(try C.estimate.encode(child)); parent = child.id
        }
        #expect(try G.validate(records.reversed()).recordCount == 544)
        let cycle = records.map { $0.id == originalEstimate.id ? replacing($0, ["parentEstimateID": .identifier(parent)]) : $0 }
        #expect(throws: StaffWorkspaceLinkError.cycle(kind: "estimate", field: "parentEstimateID")) { try G.validate(cycle) }
    }

    @Test func savedSourcePreflightNeverSavesOrReplacesDataWhenRelationshipsAreIncomplete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GAStaffGraph-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, url: root.appendingPathComponent("source.store"), cloudKitDatabase: .none)])
        let context = ModelContext(container); context.autosaveEnabled = false
        for model in try G.validate(base()).decodeDetached() { context.insert(model) }
        #expect(throws: StaffWorkspaceModelError.invalid) { try G.captureSaved(in: context) }
        try context.save()
        let reader = ModelContext(container); reader.autosaveEnabled = false
        #expect(try G.captureSaved(in: reader).recordCount == 32 && !reader.hasChanges)
        let job = try #require(context.fetch(FetchDescriptor<ServiceCall>()).first)
        job.linkedInvoiceID = UUID(); try context.save()
        let fresh = ModelContext(container); fresh.autosaveEnabled = false
        #expect(throws: StaffWorkspaceLinkError.self) { try G.captureSaved(in: fresh) }
        #expect(try fresh.fetchCount(FetchDescriptor<ServiceCall>()) == 1 && !fresh.hasChanges)
        #expect(try fresh.fetch(FetchDescriptor<ServiceCall>()).first?.linkedInvoiceID == job.linkedInvoiceID)
    }
}
