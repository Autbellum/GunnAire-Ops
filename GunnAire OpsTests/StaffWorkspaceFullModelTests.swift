import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct StaffWorkspaceFullModelTests {
    typealias C = StaffWorkspaceModelCodecs
    let date = Date(timeIntervalSinceReferenceDate: 810_123_456.123456)

    /// One source model of every actual schema entity, with the real owning
    /// relationships. No service, provider, signed account or live store is used.
    func fixtures() -> [any PersistentModel] {
        let customer = Customer(name: "Original customer")
        let technician = Technician(name: "Original lead")
        let item = Item(name: "Original valve", unitPrice: 123.375)
        let job = ServiceCall(type: .repair, scheduledDate: date, assignedTechnician: technician, customer: customer)
        let invoice = Invoice(customer: customer, amount: 123.375)
        let estimate = Estimate(customer: customer, amount: 123.375)
        let template = FieldFormTemplate(title: "Original form", questions: [])
        let vehicle = FleetVehicle(unitNumber: "Truck 2", stockLocation: "Truck 2")
        let task = BusinessTask(title: "Order valve", assignedToEmail: "field@example.invalid", dueAt: date, createdByEmail: "office@example.invalid")
        return [
            customer, technician, item, job, invoice, estimate,
            CustomerServiceLocation(customer: customer, name: "Shop", address: "10 Main"),
            CustomerEquipment(customer: customer, name: "Original heat pump"),
            Payment(invoice: invoice, amount: 12.125),
            AppUser(email: "field@example.invalid", role: .fieldTechnician),
            TechnicianAvailabilityBlock(technicianID: technician.id, startsAt: date, endsAt: date.addingTimeInterval(3_600)),
            TechnicianWorkShift(technicianID: technician.id, technicianNameSnapshot: technician.name, weekday: .monday,
                startMinute: 480, durationMinutes: 540, kind: .regular, effectiveFrom: date,
                timeZoneIdentifier: "America/New_York", createdByEmail: "office@example.invalid"),
            TechnicianTimeOffRequest(technicianID: technician.id, technicianNameSnapshot: technician.name,
                requestedByEmail: "field@example.invalid", startsAt: date, endsAt: date.addingTimeInterval(3_600)),
            TechnicianAvailabilityEvent(requestID: nil, availabilityBlockID: nil, kind: .requested,
                technicianID: technician.id, technicianNameSnapshot: technician.name, startsAt: date,
                endsAt: date.addingTimeInterval(3_600), actorEmail: "field@example.invalid", privateDetail: "Original", requestStatus: .pending),
            TimeEntry(userEmail: "field@example.invalid", clockIn: date, serviceCall: job),
            RecurringMaintenanceContract(customer: customer, schedulePattern: "every 6 months", nextDate: date),
            ServiceRequest(customerName: "Original lead", summary: "No cooling"),
            ServiceCallActivity(serviceCallID: job.id, action: "Arrived", detail: "Original arrival"),
            ProjectMilestone(projectServiceCallID: job.id, estimateID: estimate.id, sequence: 2,
                title: "Equipment delivery", plannedDate: date, billingPercent: 33.333, plannedAmount: 123.375, billingTrigger: .milestoneCompletion),
            CustomerOperationalAlert(customerID: customer.id, customerName: customer.name,
                kind: .other, title: "Side entry", createdByEmail: "office@example.invalid"),
            task, BusinessTaskEvent(taskID: task.id, kind: .created, actorEmail: "office@example.invalid", detail: "Original",
                titleSnapshot: task.title, assignedToEmailSnapshot: task.assignedToEmail, dueAtSnapshot: date, priority: .normal),
            ServiceDocumentAttachment(customer: customer, serviceCallID: job.id, kind: .serviceReport,
                displayName: "Original.pdf", localFilePath: "/DO-NOT-TRANSFER/owner-file.pdf", contentType: "application/pdf", fileSizeBytes: 123),
            CustomerCommunication(customer: customer, serviceCallID: job.id, recipient: "customer@example.invalid",
                subject: "Original service report", deliveryStatus: "sent", deliveredAt: date, providerMessageID: "original-message"),
            template, FieldFormResponse(serviceCallID: job.id, template: template, answers: [:]),
            Vendor(name: "Original supplier"),
            PurchaseOrder(number: "ORIGINAL-PO-123", vendorName: "Original supplier", serviceCallID: job.id,
                itemName: item.name, quantity: 2.5, unitCost: 12.125),
            InventoryMovement(item: item, type: .adjust, quantity: -0.125, serviceCallID: job.id),
            vehicle, FleetVehicleEvent(vehicleID: vehicle.id, vehicleUnitNumber: vehicle.unitNumber,
                kind: .created, actorEmail: "office@example.invalid", detail: "Original inspection"),
            FieldExpenseClaim(serviceCallID: job.id, customerID: customer.id, claimantEmail: "field@example.invalid",
                claimantName: "Original lead", claimType: .expense, category: .other, expenseDate: date,
                merchant: "Original supplier", businessPurpose: "Valve", amount: 12.125, reimbursable: true),
        ]
    }

    func encodedFixtures() throws -> [StaffWorkspaceModelRecord] {
        let all = StaffWorkspaceModelCatalog.all
        let models = fixtures()
        #expect(models.count == 32)
        let records = try models.map { model in
            try #require(all.first { $0.modelName == String(describing: type(of: model)) }).encode(model)
        }
        #expect(Set(records.map(\.kind)) == Set(all.map(\.kind)))
        return records
    }

    /// Scalar sentinels test preservation, not business/tenant semantics. Raw
    /// statuses and nested JSON deliberately are not interpreted by these codecs.
    /// Populate every optional scalar; also exercise all explicit nulls separately.
    func variants(_ records: [StaffWorkspaceModelRecord], nullOptionals: Bool) throws -> [StaffWorkspaceModelRecord] {
        try records.map { original in
            let codec = try #require(StaffWorkspaceModelCatalog.all.first { $0.kind == original.kind })
            var fields = original.fields
            for name in codec.fields.sorted() where codec.references[name] == nil {
                let values: [StaffWorkspaceValue] = nullOptionals ? [.null] : [
                    .text("  Exact \(name) — café\nOriginal value  "), .number(123.375125), .integer(17),
                    .flag(false), .date(date), .identifier(UUID()),
                ]
                for value in values {
                    var proposed = fields; proposed[name] = value
                    let record = StaffWorkspaceModelRecord(version: original.version, kind: original.kind, id: original.id, fields: proposed)
                    if (try? codec.validate(record)) != nil { fields = proposed; break }
                }
                if !nullOptionals { #expect(fields[name] != .null) }
            }
            return .init(version: original.version, kind: original.kind, id: original.id, fields: fields)
        }
    }

    func encoded(_ models: [any PersistentModel]) throws -> [StaffWorkspaceModelRecord] {
        try models.map { model in
            try #require(StaffWorkspaceModelCatalog.all.first { $0.modelName == String(describing: type(of: model)) }).encode(model)
        }.sorted { $0.kind + $0.id.uuidString < $1.kind + $1.id.uuidString }
    }

    @Test func completeSchemaAndEveryScalarIncludingNullRoundTripInAnyInputOrder() throws {
        try StaffWorkspaceModelCatalog.validateSchema(GunnAireModelSchema.schema)
        for nullOptionals in [false, true] {
            let records = try variants(encodedFixtures(), nullOptionals: nullOptionals)
            let decoded = try StaffWorkspaceModelRecord.decode(JSONEncoder().encode(records.reversed()))
            let copies = try StaffWorkspaceModelCatalog.decodeDetached(decoded)
            #expect(copies.count == 32 && copies.allSatisfy { $0.modelContext == nil })
            #expect(try encoded(copies) == records.sorted { $0.kind + $0.id.uuidString < $1.kind + $1.id.uuidString })
            let customer = try #require(copies.compactMap { $0 as? Customer }.first)
            let job = try #require(copies.compactMap { $0 as? ServiceCall }.first)
            let time = try #require(copies.compactMap { $0 as? TimeEntry }.first)
            #expect(job.customer === customer && time.serviceCall === job)
            #expect(customer.recurringContracts.count == 1 && customer.communications.count == 1)
        }
    }

    @Test func all32ModelsSurviveTwoSeparateSQLiteStoresWithoutChangingSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GAFullStaffCodec-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func container(_ name: String) throws -> ModelContainer {
            let schema = GunnAireModelSchema.schema
            return try ModelContainer(for: schema, configurations: [.init(schema: schema, url: root.appendingPathComponent(name + ".store"), cloudKitDatabase: .none)])
        }
        func read(_ context: ModelContext) throws -> [StaffWorkspaceModelRecord] {
            try StaffWorkspaceModelCatalog.all.flatMap { try $0.readSavedRecords(context) }
                .sorted { $0.kind + $0.id.uuidString < $1.kind + $1.id.uuidString }
        }
        let source = try container("source"), target = try container("target")
        let writer = ModelContext(source); writer.autosaveEnabled = false
        let records = try variants(encodedFixtures(), nullOptionals: false)
        let models = try StaffWorkspaceModelCatalog.decodeDetached(records)
        for model in models { writer.insert(model) }
        #expect(throws: StaffWorkspaceModelError.invalid) { try StaffWorkspaceModelCatalog.all[0].readSavedRecords(writer) }
        try writer.save()
        let reader = ModelContext(source); reader.autosaveEnabled = false
        let saved = try read(reader)
        #expect(saved.count == 32 && saved == records.sorted { $0.kind + $0.id.uuidString < $1.kind + $1.id.uuidString })
        let bytes = try JSONEncoder().encode(saved)
        let imported = try StaffWorkspaceModelCatalog.decodeDetached(StaffWorkspaceModelRecord.decode(bytes))
        let targetWriter = ModelContext(target); targetWriter.autosaveEnabled = false
        try targetWriter.transaction { for model in imported { targetWriter.insert(model) } }
        let targetReader = ModelContext(target); targetReader.autosaveEnabled = false
        #expect(try read(targetReader) == saved)
        #expect(try read(reader) == saved && !reader.hasChanges && !writer.hasChanges)
        let job = try #require(targetReader.fetch(FetchDescriptor<ServiceCall>()).first)
        let time = try #require(targetReader.fetch(FetchDescriptor<TimeEntry>()).first)
        let invoice = try #require(targetReader.fetch(FetchDescriptor<Invoice>()).first)
        let payment = try #require(targetReader.fetch(FetchDescriptor<Payment>()).first)
        #expect(time.serviceCall === job && payment.invoice === invoice)
        #expect(job.customer?.id == invoice.customer?.id)
    }

    @Test func eachKindRejectsDroppedExtraAndWrongTypeFieldsWithoutDefaulting() throws {
        for original in try encodedFixtures() {
            let codec = try #require(StaffWorkspaceModelCatalog.all.first { $0.kind == original.kind })
            for name in codec.fields {
                var fields = original.fields; fields.removeValue(forKey: name)
                #expect(throws: StaffWorkspaceModelError.self) { try codec.validate(.init(version: 1, kind: original.kind, id: original.id, fields: fields)) }
                // Finite, encodable probes must be rejected by the actual scalar
                // validator, not merely JSONEncoder's nonfinite-number check.
                let probes: [StaffWorkspaceValue] = [.text("Type probe"), .number(0.5), .integer(7), .flag(true), .date(date), .identifier(UUID())]
                var acceptedTypes = 0
                for value in probes {
                    fields = original.fields; fields[name] = value
                    let probe = StaffWorkspaceModelRecord(version: 1, kind: original.kind, id: original.id, fields: fields)
                    if (try? codec.validate(probe)) != nil { acceptedTypes += 1 }
                }
                #expect(acceptedTypes <= 1)
                fields = original.fields; fields[name] = .number(.infinity)
                #expect(throws: (any Error).self) { try codec.validate(.init(version: 1, kind: original.kind, id: original.id, fields: fields)) }
            }
            var fields = original.fields; fields["unclassifiedFutureField"] = .flag(true)
            #expect(throws: StaffWorkspaceModelError.self) { try codec.validate(.init(version: 1, kind: original.kind, id: original.id, fields: fields)) }
            #expect(throws: StaffWorkspaceModelError.self) { try codec.validate(.init(version: 2, kind: original.kind, id: original.id, fields: original.fields)) }
        }
    }

    @Test func unknownDuplicateAndMissingOwningRecordsRejectTheWholeDetachedBatch() throws {
        let records = try encodedFixtures()
        #expect(throws: StaffWorkspaceModelError.invalid) { try StaffWorkspaceModelCatalog.decodeDetached(records + [records[0]]) }
        #expect(throws: StaffWorkspaceModelError.unsupported) { try StaffWorkspaceModelCatalog.decodeDetached([.init(version: 1, kind: "future", id: UUID(), fields: [:])]) }
        for kind in ["customer", "technician", "invoice", "job"] {
            #expect(throws: StaffWorkspaceModelError.relationships) { try StaffWorkspaceModelCatalog.decodeDetached(records.filter { $0.kind != kind }) }
        }
        let all = StaffWorkspaceModelCatalog.all
        #expect(throws: StaffWorkspaceModelError.invalid) { try all[0].encode(Vendor(name: "Wrong model")) }
    }

    @Test func filesRequireLocalContentResolutionAndUserRowsCannotGrantAccess() throws {
        let models = fixtures()
        let attachment = try #require(models.compactMap { $0 as? ServiceDocumentAttachment }.first)
        let record = try C.attachment.encode(attachment)
        #expect(record.fields["localFilePath"] == nil)
        #expect(!String(decoding: try JSONEncoder().encode(record), as: UTF8.self).contains("DO-NOT-TRANSFER"))
        let copies = try StaffWorkspaceModelCatalog.decodeDetached(encodedFixtures())
        #expect(try #require(copies.compactMap { $0 as? ServiceDocumentAttachment }.first).localFilePath.isEmpty)
        let user = AppUser(email: "owner@example.invalid", role: .admin)
        let imported = try C.user.decodeDetached(C.user.encode(user), resolver: .init())
        #expect(imported.roleRawValue == AppUserRole.admin.rawValue)
        #expect(AppAccess.activeRole(email: imported.email, users: [imported], verifiedUser: nil) == nil)
        #expect(attachment.localFilePath == "/DO-NOT-TRANSFER/owner-file.pdf")
    }
}
