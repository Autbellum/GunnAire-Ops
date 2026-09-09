import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct StaffWorkspaceModelCodecTests {
    typealias C = StaffWorkspaceModelCodecs
    let date = Date(timeIntervalSinceReferenceDate: 810_123_456.123456)

    func coverage<M: PersistentModel>(_ codec: StaffWorkspaceModelCodec<M>) throws {
        let entity = try #require(GunnAireModelSchema.schema.entities.first { $0.name == String(describing: M.self) })
        let references = Set(codec.fields.filter { $0.referenceKind != nil }.map(\.name))
        #expect(Set(entity.attributes.map(\.name)) == codec.fieldNames.subtracting(references).union(["id"]).union(codec.excludedAttributes.keys))
        #expect(Set(entity.relationships.map(\.name)) == references.union(codec.inverseRelationships))
        #expect(codec.fields.count == codec.fieldNames.count)
        #expect(codec.excludedAttributes.values.allSatisfy { !$0.isEmpty })
    }

    @Test func everyPersistedAttributeAndRelationshipHasAnExplicitDisposition() throws {
        try coverage(C.customer); try coverage(C.location); try coverage(C.equipment)
        try coverage(C.technician); try coverage(C.item); try coverage(C.job)
        try coverage(C.invoice); try coverage(C.estimate); try coverage(C.payment)
        try StaffWorkspaceModelCatalog.validateSchema(GunnAireModelSchema.schema)
        #expect(StaffWorkspaceModelCatalog.all.count == 32)
        #expect(GunnAireModelSchema.schema.entities.count == 32)
    }

    func roundTrip<M: PersistentModel>(_ codec: StaffWorkspaceModelCodec<M>, _ model: M,
                                      resolver: StaffWorkspaceModelResolver) throws -> M {
        let record = try codec.encode(model)
        let encoded = try JSONEncoder().encode([record])
        let decoded = try #require(StaffWorkspaceModelRecord.decode(encoded).first)
        #expect(decoded == record)
        let copy = try codec.decodeDetached(decoded, resolver: resolver)
        #expect(copy !== model && copy.modelContext == nil)
        #expect(try codec.encode(copy) == record)
        return copy
    }

    @Test func fullJobAndEquipmentValuesSurviveWithoutFlatteningLeadOrInventingChecklists() throws {
        let customer = Customer(name: "Morgan", allowsTransactionalEmail: false, allowsServiceText: true,
            allowsMarketing: false, preferredContactMethod: .phone, communicationConsentUpdatedAt: date)
        let property = CustomerServiceLocation(customer: customer, name: "Shop", address: "10 Main", accessNotes: "Side entry", createdAt: date, updatedAt: date)
        let equipment = CustomerEquipment(customer: customer, serviceLocationID: property.id, name: "Heat pump",
            manufacturer: "Lennox", modelNumber: "MODEL", serialNumber: "SERIAL", technicalBaselineReadingsJSON: "{\"supplyTemp\":\"51.25\"}", createdAt: date)
        let lead = Technician(name: "Lead", contactInfo: "lead@example.invalid", laborCostPerHour: 51.375)
        let crew = Technician(name: "Crew", contactInfo: "crew@example.invalid")
        let job = ServiceCall(googleCalendarID: "original-calendar", googleEventID: "original-event", googleEventManagedByApp: true,
            siteAddress: "10 Main — original visit address", serviceLocationID: property.id, equipmentSerialNumber: "OLD-SERIAL",
            customerEquipmentID: equipment.id, serviceReportReadingsJSON: "{\"supplyTemp\":\"52.875\"}",
            serviceActionChecklistJSON: "{\"drain\":\"completed\"}", filterCondition: "Replaced", serviceReportSummary: "Original report",
            type: .repair, scheduledDate: date, duration: 4500.125, assignedTechnician: lead, additionalTechnicianIDs: [crew.id],
            customer: customer, status: .completed, diagnosticsCaptured: true, quoteReviewedWithCustomer: false,
            startupChecklistComplete: true, workCompletedChecklist: true, paymentCollectedChecklist: false,
            beforePhotoCount: 3, afterPhotoCount: 2, documentationStartedAt: date, documentationCompletedAt: date)
        let resolver = StaffWorkspaceModelResolver()
        let c = try roundTrip(C.customer, customer, resolver: resolver)
        let p = try roundTrip(C.location, property, resolver: resolver)
        let e = try roundTrip(C.equipment, equipment, resolver: resolver)
        let l = try roundTrip(C.technician, lead, resolver: resolver)
        _ = try roundTrip(C.technician, crew, resolver: resolver)
        let j = try roundTrip(C.job, job, resolver: resolver)
        #expect(p.customer === c && e.customer === c && j.customer === c && j.assignedTechnician === l)
        #expect(j.additionalTechnicianIDs == [crew.id] && !j.additionalTechnicianIDs.contains(lead.id))
        #expect(j.serviceReportReadingsJSON == job.serviceReportReadingsJSON && e.technicalBaselineReadingsJSON == equipment.technicalBaselineReadingsJSON)
        #expect(j.equipmentSerialNumber == "OLD-SERIAL" && e.serialNumber == "SERIAL")
        #expect(!j.paymentCollectedChecklist && j.workCompletedChecklist && j.duration == 4500.125)
        #expect(j.documentationCompletedAt == date && !c.allowsTransactionalEmail && c.allowsServiceText)
    }

    @Test func invoiceEstimateAndPaymentRetainSoldLinesTaxAmountsApprovalAndReceiptIdentity() throws {
        let customer = Customer(name: "Morgan")
        customer.storedPaymentMethodsJSON = "DO-NOT-TRANSFER-PAYMENT-METHOD"
        let item = Item(quickBooksID: "71", pricebookReviewStatus: .needsReview, pricebookCreatedByEmail: "field@example.invalid",
            name: "Service valve", unitPrice: 123.375, purchaseCost: 41.125, isTaxable: true, createdAt: date)
        let lines = try String(decoding: JSONEncoder().encode([CatalogLineItemSnapshot(item: item, quantity: 2.5)]), as: UTF8.self)
        let invoice = Invoice(customer: customer, quickBooksID: "85", quickBooksBalanceDue: 150.125,
            lineItemSummary: "Sold valve", catalogSnapshotJSON: lines, amount: 320.4375, salesTaxAmount: 12,
            dueDate: date, customerSignatureName: "Morgan", customerSignedAt: date, createdAt: date)
        invoice.projectMilestoneID = UUID(); invoice.projectMilestoneSequence = 2; invoice.projectBillingPercent = 33.333
        invoice.customerSignatureImageBase64 = "c3ludGhldGljLXNpZ25hdHVyZQ=="
        invoice.quickBooksPaymentReviewJSON = "{\"originalObservation\":\"fixture\"}"
        let estimate = Estimate(customer: customer, quickBooksID: "84", lineItemSummary: "Original option", catalogSnapshotJSON: lines,
            amount: invoice.amount, salesTaxAmount: 12, status: "accepted", customerApprovedByName: "Morgan", customerApprovedAt: date, createdAt: date)
        estimate.parentEstimateID = UUID(); estimate.changeOrderReason = "Approved equipment change"
        let payment = Payment(invoice: invoice, quickBooksID: "91", quickBooksChargeID: "original-charge",
            collectionAttemptID: UUID(), providerPaymentStatus: "CAPTURED", storedCardID: "DO-NOT-TRANSFER-CARD",
            amount: 170.3125, date: date, method: "card", cardLast4: "4242", isRefund: false)
        let resolver = StaffWorkspaceModelResolver()
        let c = try roundTrip(C.customer, customer, resolver: resolver)
        let i = try roundTrip(C.item, item, resolver: resolver)
        let inv = try roundTrip(C.invoice, invoice, resolver: resolver)
        let est = try roundTrip(C.estimate, estimate, resolver: resolver)
        let pay = try roundTrip(C.payment, payment, resolver: resolver)
        #expect(inv.customer === c && est.customer === c && pay.invoice === inv)
        #expect(inv.catalogSnapshotJSON == lines && est.catalogSnapshotJSON == lines && i.unitPrice == item.unitPrice)
        #expect(inv.amount == 320.4375 && inv.quickBooksBalanceDue == 150.125 && inv.salesTaxAmount == 12)
        #expect(pay.amount == 170.3125 && pay.collectionAttemptID == payment.collectionAttemptID && pay.date == date)
        #expect(inv.status == invoice.status && pay.providerPaymentStatus == payment.providerPaymentStatus)
        #expect(c.storedPaymentMethodsJSON == nil && pay.storedCardID == nil)
        let bytes = try JSONEncoder().encode([C.customer.encode(customer), C.payment.encode(payment)])
        #expect(!String(decoding: bytes, as: UTF8.self).contains("DO-NOT-TRANSFER"))
        // Source identities and totals remain untouched; there is no provider I/O.
        #expect(payment.storedCardID == "DO-NOT-TRANSFER-CARD" && invoice.amount == inv.amount)
    }

    @Test func missingUnknownWrongTypeAndWrongVersionFieldsNeverUseModelDefaults() throws {
        let customer = Customer(name: "Original")
        let source = try C.customer.encode(customer)
        var missing = source.fields; missing.removeValue(forKey: "allowsServiceText")
        var unknown = source.fields; unknown["newUnclassifiedField"] = .flag(true)
        var wrong = source.fields; wrong["allowsServiceText"] = .integer(1)
        for fields in [missing, unknown, wrong] {
            #expect(throws: StaffWorkspaceModelError.self) {
                try C.customer.decodeDetached(.init(version: 1, kind: source.kind, id: source.id, fields: fields), resolver: .init())
            }
        }
        #expect(throws: StaffWorkspaceModelError.self) { try C.customer.validate(.init(version: 2, kind: source.kind, id: source.id, fields: source.fields)) }
    }

    @Test func unknownEnvelopeAndNestedTaggedValueKeysCannotBeSilentlyDropped() throws {
        let original = try C.customer.encode(Customer(name: "Original"))
        let data = try JSONEncoder().encode([original])
        let root = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        var changed = root; changed[0]["hidden"] = true
        #expect(throws: (any Error).self) { try StaffWorkspaceModelRecord.decode(JSONSerialization.data(withJSONObject: changed)) }
        changed = root
        var fields = changed[0]["fields"] as! [String: Any]
        fields["name"] = ["text": ["_0": "Original", "hidden": true]]; changed[0]["fields"] = fields
        #expect(throws: (any Error).self) { try StaffWorkspaceModelRecord.decode(JSONSerialization.data(withJSONObject: changed)) }
        #expect(throws: StaffWorkspaceModelError.self) { try StaffWorkspaceModelRecord.decode(JSONEncoder().encode([original, original])) }
    }

    @Test func missingParentAndDuplicateIdentityDoNotMutateTheDetachedGraph() throws {
        let customer = Customer(name: "Original"), lead = Technician(name: "Lead")
        let job = ServiceCall(type: .service, scheduledDate: date, assignedTechnician: lead, customer: customer)
        let resolver = StaffWorkspaceModelResolver()
        #expect(throws: StaffWorkspaceModelError.relationships) { try C.job.decodeDetached(C.job.encode(job), resolver: resolver) }
        let copy = try C.customer.decodeDetached(C.customer.encode(customer), resolver: resolver)
        let before = copy.serviceCalls.count
        #expect(throws: StaffWorkspaceModelError.relationships) { try C.job.decodeDetached(C.job.encode(job), resolver: resolver) }
        #expect(copy.serviceCalls.count == before)
        #expect(throws: StaffWorkspaceModelError.invalid) { try C.customer.decodeDetached(C.customer.encode(customer), resolver: resolver) }
        #expect(copy.name == "Original")
    }

    @Test func persistedSourceAndFreshSQLiteTargetKeepExactRecordsAndOriginalRelationships() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GAStaffModelCodecTest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func container(_ name: String) throws -> ModelContainer {
            let schema = GunnAireModelSchema.schema
            return try ModelContainer(for: schema, configurations: [.init(schema: schema, url: root.appendingPathComponent(name + ".store"), cloudKitDatabase: .none)])
        }
        let source = try container("source"), target = try container("target")
        let sourceContext = ModelContext(source), targetContext = ModelContext(target)
        sourceContext.autosaveEnabled = false; targetContext.autosaveEnabled = false
        let customer = Customer(name: "SQL customer", communicationConsentUpdatedAt: date)
        let tech = Technician(name: "SQL lead", contactInfo: "lead@example.invalid")
        let job = ServiceCall(serviceReportSummary: "Retained diagnosis", type: .repair, scheduledDate: date, assignedTechnician: tech, customer: customer)
        let invoice = Invoice(serviceCallID: job.id, customer: customer, amount: 178.375, createdAt: date)
        let payment = Payment(invoice: invoice, amount: 78.125, date: date)
        sourceContext.insert(job); sourceContext.insert(payment); try sourceContext.save()
        let reader = ModelContext(source); reader.autosaveEnabled = false
        let resolver = StaffWorkspaceModelResolver()
        let c = try roundTrip(C.customer, #require(reader.fetch(FetchDescriptor<Customer>()).first), resolver: resolver)
        let t = try roundTrip(C.technician, #require(reader.fetch(FetchDescriptor<Technician>()).first), resolver: resolver)
        let j = try roundTrip(C.job, #require(reader.fetch(FetchDescriptor<ServiceCall>()).first), resolver: resolver)
        let i = try roundTrip(C.invoice, #require(reader.fetch(FetchDescriptor<Invoice>()).first), resolver: resolver)
        let p = try roundTrip(C.payment, #require(reader.fetch(FetchDescriptor<Payment>()).first), resolver: resolver)
        #expect(j.customer === c && j.assignedTechnician === t && p.invoice === i)
        try targetContext.transaction { targetContext.insert(j); targetContext.insert(p) }
        let reread = ModelContext(target); reread.autosaveEnabled = false
        #expect(try C.job.encode(#require(reread.fetch(FetchDescriptor<ServiceCall>()).first)) == C.job.encode(job))
        #expect(try C.invoice.encode(#require(reread.fetch(FetchDescriptor<Invoice>()).first)) == C.invoice.encode(invoice))
        #expect(try C.payment.encode(#require(reread.fetch(FetchDescriptor<Payment>()).first)) == C.payment.encode(payment))
        #expect(try reread.fetchCount(FetchDescriptor<Customer>()) == 1)
        #expect(try reader.fetchCount(FetchDescriptor<ServiceCall>()) == 1 && !reader.hasChanges)
        #expect(throws: StaffWorkspaceModelError.invalid) { try StaffWorkspaceModelResolver().add(customer, kind: "customer", id: customer.id) }
        #expect(throws: StaffWorkspaceModelError.relationships) { try resolver.require(Customer.self, kind: "customer", id: c.id) }
    }
}
