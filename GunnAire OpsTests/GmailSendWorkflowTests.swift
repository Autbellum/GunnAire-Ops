import Foundation
import SwiftData
import CoreData
import Testing
@testable import GunnAire_Ops

@Suite(.serialized)
@MainActor
struct GmailSendWorkflowTests {
    private nonisolated final class StoreNotificationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Notification?
        func retain(_ notification: Notification) { lock.withLock { value = notification } }
        var latest: Notification? { lock.withLock { value } }
    }

    @MainActor private final class Fixture {
        let email = "mail-fixture@gunnaire.com"
        let context: ModelContext
        let customer: Customer
        let call: ServiceCall
        var requests: [URLRequest] = []
        var raw = ""
        var status = 200
        var allowed = true
        var sentLabels = ["SENT"]
        var wrongMessageID = false
        var wrongRecipient = false
        let draftDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MailSendJournalTest-" + UUID().uuidString)
        var draftKeyAvailable = true
        lazy var draftStore = GmailDraftStore.encrypted(directory: draftDirectory) { [unowned self] _ in
            guard draftKeyAvailable else { throw GmailDraftError.storage }
            return Data(repeating: 83, count: 32)
        }
        var beforeReply: ((URLRequest) async throws -> Void)?
        lazy var auth = GoogleAuthManager(testTokens: .init(accessToken: "fixture-token",
            refreshToken: nil, idToken: nil, expiration: .distantFuture), email: email,
            businessEmail: { self.email }) { [unowned self] request in
                requests.append(request)
                try await beforeReply?(request)
                return try response(request)
            }

        init(storeURL: URL? = nil) throws {
            let schema = GunnAireModelSchema.schema
            let configuration = storeURL.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
                ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
            customer = Customer(name: "Mail fixture", email: "customer@example.invalid")
            call = ServiceCall(type: .repair, scheduledDate: Date(), duration: 3600, customer: customer)
            context.insert(customer); context.insert(call); try context.save()
        }

        func header(_ name: String) -> String {
            raw.components(separatedBy: "\r\n").first { $0.hasPrefix(name + ": ") }
                .map { String($0.dropFirst(name.count + 2)) } ?? ""
        }

        func response(_ request: URLRequest) throws -> (Data, URLResponse) {
            var payload: [String: Any]
            if request.httpMethod == "POST" {
                let body = try JSONDecoder().decode(GmailSendRequest.self, from: request.httpBody!)
                var encoded = body.raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
                raw = String(data: Data(base64Encoded: encoded)!, encoding: .utf8)!
                payload = ["id": "sent-message", "threadId": "sent-thread"]
            } else {
                payload = ["id": "sent-message", "threadId": "sent-thread", "labelIds": sentLabels,
                    "payload": ["headers": [
                        ["name": "From", "value": header("From")],
                        ["name": "Message-ID", "value": wrongMessageID ? "<foreign@example.invalid>" : header("Message-ID")],
                        ["name": "To", "value": wrongRecipient ? "someone-else@example.invalid" : header("To")]
                    ]]]
            }
            if status != 200 { payload = ["error": ["code": status, "message": "Fixture provider rejection"]] }
            return (try JSONSerialization.data(withJSONObject: payload),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        deinit { try? FileManager.default.removeItem(at: draftDirectory) }

        func draft() throws -> GmailDraftSession {
            let scope = GmailDraftScope(companyID: UUID(), backendOrigin: "https://fixture.example.invalid", actorEmail: email, googleEmail: email)
            return try GmailDraftSession(record: .init(id: UUID(), scope: scope,
                content: .init(to: "vendor@example.invalid", subject: "Repair appointment", body: "Fixture only.")), store: draftStore) {
                    if !self.allowed { throw GmailDraftError.access }
                }
        }

        func flow(to: String = "vendor@example.invalid", business: GmailBusinessContext? = nil, journal: GmailDraftSession? = nil,
                  save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws -> GmailSendWorkflow {
            try GmailSendWorkflow(auth: auth, context: context,
                message: GmailOutgoingMessage(to: to, subject: "Repair appointment", body: "Fixture only.",
                    attachments: journal?.record.content.files.map(\.attachment) ?? []),
                business: business, validateAccess: { if !self.allowed { throw GmailComposeError.access } }, journal: journal, save: save)
        }

        var recipient: String { get throws { try #require(customer.email) } }

        var business: GmailBusinessContext {
            .init(customerID: customer.id, serviceCallID: call.id, workflow: .appointmentConfirmation)
        }
        var writes: [URLRequest] { requests.filter { $0.httpMethod == "POST" } }
        func history() throws -> [CustomerCommunication] { try context.fetch(FetchDescriptor<CustomerCommunication>()) }
    }

    @Test func replyToSomeoneOutsideCustomersSendsWithoutAFalseTemplateGate() async throws {
        let f = try Fixture()
        let result = await (try f.flow()).send()
        #expect(result.state == .sent)
        #expect(f.writes.count == 1 && f.requests.count == 2)
        #expect(try f.history().isEmpty)
    }

    @Test func persistentDraftIsLockedBeforeGmailAndUsesItsOriginalMessageID() async throws {
        let f = try Fixture(); let journal = try f.draft()
        f.beforeReply = { _ in
            let original = try f.draftStore.read(journal.record.scope, journal.record.id)
            #expect(original?.state == .sending)
        }
        let flow = try f.flow(journal: journal)
        #expect(await flow.send().state == .sent)
        #expect(f.header("Message-ID") == journal.record.messageID)
        #expect(try f.draftStore.read(journal.record.scope, journal.record.id)?.state == .sent)
    }

    @Test func failedPersistentPreSendWriteMakesNoProviderRequest() async throws {
        let f = try Fixture(); let journal = try f.draft(); let flow = try f.flow(journal: journal)
        f.draftKeyAvailable = false
        #expect(await flow.send().state == .notSent)
        #expect(f.requests.isEmpty)
        f.draftKeyAvailable = true
        #expect(try f.draftStore.read(journal.record.scope, journal.record.id)?.state == .editing)
    }

    @Test func lostReplySurvivesNewWorkflowAndCannotProduceASecondPOST() async throws {
        let f = try Fixture(); let journal = try f.draft()
        f.beforeReply = { _ in throw URLError(.networkConnectionLost) }
        let flow = try f.flow(journal: journal)
        #expect(await flow.send().state == .reviewRequired)
        let original = try #require(try f.draftStore.read(journal.record.scope, journal.record.id))
        let reopened = try GmailDraftSession(record: original, store: f.draftStore, access: {})
        #expect(throws: GmailDraftError.changed) { try f.flow(journal: reopened) }
        #expect(f.writes.count == 1)
    }

    @Test func acceptedPOSTAndRejectedConfirmationPersistReviewNotRetry() async throws {
        let f = try Fixture(); let journal = try f.draft()
        f.beforeReply = { request in if request.httpMethod == "GET" { f.status = 403 } }
        let flow = try f.flow(journal: journal)
        #expect(await flow.send().state == .reviewRequired)
        #expect(try f.draftStore.read(journal.record.scope, journal.record.id)?.state == .review)
        #expect(f.writes.count == 1)
    }

    @Test func definiteRejectionCanBeExplicitlyRetriedFromSameSavedDraft() async throws {
        let f = try Fixture(); let journal = try f.draft(); f.status = 400
        let flow = try f.flow(journal: journal)
        #expect(await flow.send().state == .notSent)
        let original = try #require(try f.draftStore.read(journal.record.scope, journal.record.id))
        let reopened = try GmailDraftSession(record: original, store: f.draftStore, access: {})
        f.status = 200
        let retry = try f.flow(journal: reopened)
        #expect(await retry.send().state == .sent)
        #expect(f.writes.count == 2)
        #expect(f.header("Message-ID") == original.messageID)
    }

    @Test func mismatchedSavedDraftCannotAuthorizeDifferentMessageContents() throws {
        let f = try Fixture(); let journal = try f.draft()
        #expect(throws: GmailDraftError.changed) { try f.flow(to: "different@example.invalid", journal: journal) }
        #expect(f.requests.isEmpty)
    }

    @Test func reopenedBusinessDraftCannotAdoptChangedConsentContactOrJob() throws {
        for change in 0..<3 {
            let f = try Fixture()
            let scope = GmailDraftScope(companyID: UUID(), backendOrigin: "https://fixture.example.invalid", actorEmail: f.email, googleEmail: f.email)
            let content = GmailDraftContent(to: f.customer.email!, subject: "Repair appointment", body: "Fixture only.",
                business: f.business, requiresBusinessContext: true,
                businessSnapshot: try GmailDraftBusinessSnapshot.capture(f.business, context: f.context))
            let journal = try GmailDraftSession(record: .init(id: UUID(), scope: scope, content: content), store: f.draftStore, access: {})
            if change == 0 { f.customer.name = "Changed customer" }
            if change == 1 { f.customer.allowsTransactionalEmail = false }
            if change == 2 { f.call.notes = "Changed scope of work" }
            #expect(throws: GmailDraftError.businessChanged) { try f.flow(to: f.customer.email!, business: f.business, journal: journal) }
            #expect(f.requests.isEmpty)
        }
    }

    @Test func savedInvoiceDraftRejectsChangedPrintedDetailsAndPayments() throws {
        for change in 0..<8 {
            let f = try Fixture()
            let invoice = Invoice(customer: f.customer, lineItemSummary: "Saved work", amount: 100,
                dueDate: Date(timeIntervalSince1970: 2_000_000_000), completionNotes: "Original work")
            f.context.insert(invoice)
            let payment = Payment(invoice: invoice, amount: 10)
            f.context.insert(payment); try f.context.save()
            let business = GmailBusinessContext(customerID: f.customer.id, invoiceID: invoice.id, workflow: .customerDocument)
            let journal = try businessJournal(f, business: business)
            let encoded = try JSONEncoder().encode(journal.record)
            switch change {
            case 0: invoice.dueDate = invoice.dueDate?.addingTimeInterval(86_400)
            case 1: invoice.createdAt = invoice.createdAt.addingTimeInterval(-86_400 * 30)
            case 2: invoice.completionNotes = "Changed completed work"
            case 3: invoice.lineItemSummary = "Different work for the same total"
            case 4: invoice.siteAddress = "Different service property"
            case 5: payment.amount = 15
            case 6: payment.method = "check"
            default: f.context.insert(Payment(invoice: invoice, amount: 3))
            }
            let reopened = try GmailDraftSession(record: JSONDecoder().decode(GmailDraftRecord.self, from: encoded),
                store: f.draftStore, access: {})
            #expect(throws: GmailDraftError.businessChanged) {
                try f.flow(to: try f.recipient, business: business, journal: reopened)
            }
            #expect(f.requests.isEmpty)
            #expect(reopened.record.content.files.first?.data == Data("Original PDF".utf8))
        }
    }

    @Test func savedEstimateDraftRejectsNotesApprovalAndSiteChanges() throws {
        for change in 0..<5 {
            let f = try Fixture()
            let estimate = Estimate(customer: f.customer, lineItemSummary: "Original work", amount: 100, notes: "Original notes")
            f.context.insert(estimate); try f.context.save()
            let business = GmailBusinessContext(customerID: f.customer.id, estimateID: estimate.id, workflow: .customerDocument)
            let journal = try businessJournal(f, business: business)
            switch change {
            case 0: estimate.notes = "Different scope of work"
            case 1: estimate.siteAddress = "Different property"
            case 2: estimate.lineItemSummary = "Changed work, unchanged total"
            case 3: estimate.customerApprovalReference = "Changed approval"
            default: estimate.customerApprovalSignatureImageBase64 = "changed-signature"
            }
            #expect(throws: GmailDraftError.businessChanged) {
                try f.flow(to: try f.recipient, business: business, journal: journal)
            }
            #expect(f.requests.isEmpty)
        }
    }

    @Test func inFlightPrintedDocumentChangeKeepsOriginalAttemptUnconfirmed() async throws {
        for change in 0..<4 {
            let f = try Fixture()
            let invoice = Invoice(customer: f.customer, amount: 100, dueDate: .distantFuture)
            let estimate = Estimate(customer: f.customer, amount: 100, notes: "Original estimate")
            f.context.insert(invoice); f.context.insert(estimate)
            let payment = Payment(invoice: invoice, amount: 10)
            f.context.insert(payment); try f.context.save()
            let business = GmailBusinessContext(customerID: f.customer.id,
                invoiceID: change == 3 ? nil : invoice.id, estimateID: change == 3 ? estimate.id : nil,
                workflow: .customerDocument)
            f.beforeReply = { request in
                guard request.httpMethod == "POST" else { return }
                switch change {
                case 0: invoice.dueDate = Date()
                case 1: invoice.createdAt = invoice.createdAt.addingTimeInterval(-86_400)
                case 2: payment.amount = 20
                default: estimate.notes = "New estimate notes"
                }
            }
            let flow = try f.flow(to: try f.recipient, business: business)
            #expect(await flow.send().state == .reviewRequired)
            #expect(await flow.send().state == .reviewRequired)
            #expect(f.writes.count == 1)
            #expect(f.requests.count == 1, "Do not verify or audit changed work as the original message.")
            #expect(try f.history().first?.deliveryStatus != "sent")
        }
    }

    @Test func generatedPDFOriginCannotAdoptNewSourceBeforeFirstDraftOrSend() throws {
        let f = try Fixture()
        let invoice = Invoice(customer: f.customer, amount: 100, dueDate: .distantFuture)
        f.context.insert(invoice); try f.context.save()
        let business = GmailBusinessContext(customerID: f.customer.id, invoiceID: invoice.id, workflow: .customerDocument)
        let original = try GmailDraftBusinessSnapshot.capture(business, context: f.context)
        invoice.dueDate = Date()
        #expect(throws: GmailDraftError.businessChanged) {
            try GmailDraftBusinessSnapshot.validate(original, business: business, context: f.context)
        }
        #expect(throws: GmailDraftError.businessChanged) {
            try GmailSendWorkflow(auth: f.auth, context: f.context,
                message: GmailOutgoingMessage(to: try f.recipient, subject: "Original invoice", body: "Review attached.",
                    attachments: [.init(fileName: "invoice.pdf", mimeType: "application/pdf", data: Data("Original PDF".utf8))]),
                business: business, validateAccess: {}, sourceSnapshot: original)
        }
        #expect(f.requests.isEmpty)
    }

    @Test func unchangedDocumentAndReorderedPaymentResultsKeepOriginalSnapshot() throws {
        let f = try Fixture()
        let invoice = Invoice(customer: f.customer, amount: 100, dueDate: .distantFuture)
        f.context.insert(invoice)
        f.context.insert(Payment(invoice: invoice, amount: 10, date: Date(timeIntervalSince1970: 100)))
        f.context.insert(Payment(invoice: invoice, amount: 5, date: Date(timeIntervalSince1970: 100)))
        try f.context.save()
        let business = GmailBusinessContext(customerID: f.customer.id, invoiceID: invoice.id, workflow: .customerDocument)
        let original = try GmailDraftBusinessSnapshot.capture(business, context: f.context)
        try GmailDraftBusinessSnapshot.validate(original, business: business, context: f.context)
        let payments = try f.context.fetch(FetchDescriptor<Payment>())
        let forward = CustomerDocumentExporter.mailSourceValues(estimate: nil, invoice: invoice, serviceCall: nil,
            payments: payments, attachments: [], equipmentProfiles: [], serviceCalls: [])
        let reverse = CustomerDocumentExporter.mailSourceValues(estimate: nil, invoice: invoice, serviceCall: nil,
            payments: Array(payments.reversed()), attachments: [], equipmentProfiles: [], serviceCalls: [])
        #expect(forward == reverse)
        let unrelated = Invoice(customer: f.customer, amount: 500)
        f.context.insert(unrelated); f.context.insert(Payment(invoice: unrelated, amount: 500))
        try GmailDraftBusinessSnapshot.validate(original, business: business, context: f.context)
    }

    @Test func generatedOutputsDoNotInvalidateTheirOwnSourceButJobReadingsDo() throws {
        let f = try Fixture()
        let business = GmailBusinessContext(customerID: f.customer.id, serviceCallID: f.call.id, workflow: .customerDocument)
        let original = try GmailDraftBusinessSnapshot.capture(business, context: f.context)
        let output = ServiceDocumentAttachment(customer: f.customer, serviceCallID: f.call.id,
            kind: .serviceReport, displayName: "generated.pdf", localFilePath: "/synthetic/generated.pdf",
            contentType: "application/pdf", fileSizeBytes: 100)
        f.context.insert(output)
        try GmailDraftBusinessSnapshot.validate(original, business: business, context: f.context)
        output.fileSizeBytes = 200
        output.caption = "Replaced generated report"
        try GmailDraftBusinessSnapshot.validate(original, business: business, context: f.context)
        f.call.documentationChecklist.toggle()
        #expect(throws: GmailDraftError.businessChanged) {
            try GmailDraftBusinessSnapshot.validate(original, business: business, context: f.context)
        }
    }

    @Test func scopedMaterialInputsDetectLegacyCaseInsensitiveRequirements() throws {
        let f = try Fixture()
        let invoice = Invoice(serviceCallID: f.call.id, customer: f.customer, lineItemSummary: "FILTER REPLACEMENT", amount: 100)
        let item = Item(name: "Filter", unitPrice: 100, tracksInventory: false)
        f.context.insert(invoice); f.context.insert(item); try f.context.save()
        let business = GmailBusinessContext(customerID: f.customer.id, serviceCallID: f.call.id,
            invoiceID: invoice.id, workflow: .customerDocument)
        let original = try GmailDraftBusinessSnapshot.capture(business, context: f.context)
        try GmailDraftBusinessSnapshot.validate(original, business: business, context: f.context)
        item.tracksInventory = true
        #expect(throws: GmailDraftError.businessChanged) {
            try GmailDraftBusinessSnapshot.validate(original, business: business, context: f.context)
        }
    }

    @Test func legacyBusinessDraftDecodesButRequiresRegenerationBeforeSend() throws {
        let f = try Fixture()
        let journal = try businessJournal(f, business: f.business)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(journal.record)) as? [String: Any])
        var content = try #require(object["content"] as? [String: Any])
        content.removeValue(forKey: "businessSnapshot"); object["content"] = content
        let legacy = try JSONDecoder().decode(GmailDraftRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.content.businessSnapshot == nil)
        let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyBusinessMail-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: legacyDirectory) }
        let store = GmailDraftStore.encrypted(directory: legacyDirectory) { _ in Data(repeating: 17, count: 32) }
        let reopened = try GmailDraftSession(record: legacy, store: store, access: {})
        #expect(throws: GmailDraftError.businessChanged) {
            try f.flow(to: try f.recipient, business: f.business, journal: reopened)
        }
        #expect(f.requests.isEmpty)
    }

    @Test func savedStatementRejectsAggregateInvoicePaymentAndRefundChanges() throws {
        for change in 0..<12 {
            let f = try Fixture()
            let invoice = Invoice(customer: f.customer, amount: 100, dueDate: .distantFuture,
                createdAt: Date(timeIntervalSince1970: 100))
            let otherInvoice = Invoice(customer: f.customer, amount: 40, createdAt: Date(timeIntervalSince1970: 100))
            let payment = Payment(invoice: invoice, amount: 10, date: Date(timeIntervalSince1970: 200))
            f.context.insert(invoice); f.context.insert(otherInvoice); f.context.insert(payment); try f.context.save()
            let business = GmailBusinessContext(customerID: f.customer.id, workflow: .accountStatement)
            let origin = try GmailDraftBusinessSnapshot.prepareAccountStatement(customer: f.customer, context: f.context)
            let journal = try businessJournal(f, business: business)
            #expect(journal.record.content.businessSnapshot == origin.sourceSnapshot)
            let saved = try JSONEncoder().encode(journal.record)
            switch change {
            case 0: invoice.amount = 101
            case 1: invoice.dueDate = Date(timeIntervalSince1970: 500)
            case 2: invoice.siteAddress = "Changed property"
            case 3: invoice.quickBooksBalanceDue = 15
            case 4: invoice.quickBooksLastSyncedAt = Date(timeIntervalSince1970: 600)
            case 5: f.context.insert(Invoice(customer: f.customer, amount: 20))
            case 6: f.context.delete(otherInvoice)
            case 7: f.context.insert(Payment(invoice: invoice, amount: 2))
            case 8: f.context.delete(payment)
            case 9: payment.isRefund = true
            case 10: payment.quickBooksRefundReceiptID = "synthetic-refund"
            default: payment.method = "ach"; payment.providerPaymentStatus = "PENDING"
            }
            let reopened = try GmailDraftSession(record: JSONDecoder().decode(GmailDraftRecord.self, from: saved),
                store: f.draftStore, access: {})
            #expect(throws: GmailDraftError.businessChanged) {
                try f.flow(to: try f.recipient, business: business, journal: reopened)
            }
            #expect(reopened.record.content.files.first?.data == Data("Original PDF".utf8))
            #expect(f.requests.isEmpty)
        }
    }

    @Test func statementKeepsOriginalCutoffAndIgnoresGeneratedFilesAndOtherCustomers() throws {
        let f = try Fixture()
        let invoice = Invoice(customer: f.customer, amount: 100, createdAt: Date(timeIntervalSince1970: 100))
        f.context.insert(invoice); try f.context.save()
        let business = GmailBusinessContext(customerID: f.customer.id, workflow: .accountStatement)
        let origin = try GmailDraftBusinessSnapshot.prepareAccountStatement(customer: f.customer, context: f.context)
        let originalCutoff = origin.statement.asOf
        let generated = ServiceDocumentAttachment(customer: f.customer, serviceCallID: nil, kind: .customerDocument,
            displayName: "statement.pdf", localFilePath: "/synthetic/statement.pdf", contentType: "application/pdf", fileSizeBytes: 100)
        f.context.insert(generated)
        let other = Customer(name: "Other statement customer")
        let unrelated = Invoice(customer: other, amount: 9)
        f.context.insert(other); f.context.insert(unrelated); f.context.insert(Payment(invoice: unrelated, amount: 3))
        try GmailDraftBusinessSnapshot.validate(origin.sourceSnapshot, business: business, context: f.context)
        generated.fileSizeBytes = 200
        try GmailDraftBusinessSnapshot.validate(origin.sourceSnapshot, business: business, context: f.context)
        #expect(origin.statement.asOf == originalCutoff)
        #expect(origin.statement.preparedAt == originalCutoff)
        #expect(origin.statement.totalBalance == 100)
    }

    @Test func statementPaymentMutationAfterPostKeepsSingleAttemptUnconfirmed() async throws {
        let f = try Fixture()
        let invoice = Invoice(customer: f.customer, amount: 100, createdAt: Date(timeIntervalSince1970: 100))
        let payment = Payment(invoice: invoice, amount: 10, date: Date(timeIntervalSince1970: 200))
        f.context.insert(invoice); f.context.insert(payment); try f.context.save()
        let business = GmailBusinessContext(customerID: f.customer.id, workflow: .accountStatement)
        let journal = try businessJournal(f, business: business)
        let flow = try f.flow(to: try f.recipient, business: business, journal: journal)
        f.beforeReply = { request in
            if request.httpMethod == "POST" { payment.amount = 20 }
        }
        let first = await flow.send()
        let repeated = await flow.send()
        #expect(first.state == .reviewRequired)
        #expect(repeated.state == .reviewRequired)
        #expect(f.writes.count == 1)
        #expect(try f.history().first?.deliveryStatus != "sent")
    }

    @Test func receiptOriginRejectsPaymentChangeBeforeMailSessionConstruction() throws {
        let f = try Fixture()
        let invoice = Invoice(customer: f.customer, amount: 100)
        let payment = Payment(invoice: invoice, amount: 10)
        f.context.insert(invoice); f.context.insert(payment); try f.context.save()
        let business = GmailBusinessContext(customerID: f.customer.id, invoiceID: invoice.id, workflow: .receipt)
        let origin = try GmailDraftBusinessSnapshot.capture(business, context: f.context)
        payment.amount = 20
        #expect(throws: GmailDraftError.businessChanged) {
            try GmailSendWorkflow(auth: f.auth, context: f.context,
                message: GmailOutgoingMessage(to: try f.recipient, subject: "Receipt", body: "Received $10"),
                business: business, validateAccess: {}, sourceSnapshot: origin)
        }
        #expect(f.requests.isEmpty)
    }

    @Test func historyInsertionAndSaveRearmsAnExactFreshSourceLease() async throws {
        let f = try Fixture()
        let original = try GmailDraftSourceLease(business: f.business, context: f.context)
        let replacement = try await original.replacingAfterHistoryWrite(business: f.business, context: f.context,
            validatePreparation: {}, write: {
                let history = CustomerCommunication(customer: f.customer, serviceCallID: f.call.id,
                    recipient: try f.recipient, subject: "Fixture history", deliveryStatus: "pending")
                f.context.insert(history)
                try f.context.save()
                return [history.persistentModelID, f.customer.persistentModelID]
            })
        #expect(replacement.snapshot == original.snapshot)
        #expect(try f.history().count == 1)
        try replacement.check(context: f.context)
        #expect(throws: GmailDraftError.businessChanged) { try original.check(context: f.context) }
        f.call.notes = "Edit after history rearm"
        #expect(throws: GmailDraftError.businessChanged) { try replacement.check(context: f.context) }
    }

    @Test func diskHistoryInsertionAndSaveRearmsAnExactFreshSourceLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskMailLease-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let f = try Fixture(storeURL: directory.appendingPathComponent("fixture.store"))
            let recipient = try #require(f.customer.email)
            let started = ContinuousClock.now
            let original = try await GmailDraftSourceLease.prepare(business: f.business, context: f.context)
            let replacement = try await original.replacingAfterHistoryWrite(business: f.business, context: f.context,
                validatePreparation: {}, write: {
                    let history = CustomerCommunication(customer: f.customer, serviceCallID: f.call.id,
                        recipient: recipient, subject: "Fixture history", deliveryStatus: "pending")
                    f.context.insert(history)
                    try f.context.save()
                    return [history.persistentModelID, f.customer.persistentModelID]
                })
            #expect(replacement.snapshot == original.snapshot)
            try replacement.check(context: f.context)
            #expect(throws: GmailDraftError.businessChanged) { try original.check(context: f.context) }
            print("MAIL_DISK_LEASE_TIMING total=\(started.duration(to: .now))")
        }
    }

    @Test func diskDelayedOwnRemoteNotificationRequiresReclassificationAndStillPasses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskMailDelayed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let f = try Fixture(storeURL: directory.appendingPathComponent("fixture.store"))
        let box = StoreNotificationBox()
        let observer = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange,
            object: nil, queue: nil) { notification in
                if let url = notification.userInfo?[NSPersistentStoreURLKey] as? URL,
                   url.standardizedFileURL == directory.appendingPathComponent("fixture.store").standardizedFileURL {
                    box.retain(notification)
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        let center = NotificationCenter()
        let original = try await GmailDraftSourceLease.prepare(business: f.business, context: f.context,
            notificationCenter: center)
        let replacement = try await original.replacingAfterHistoryWrite(business: f.business, context: f.context,
            validatePreparation: {}, write: {
                let row = CustomerCommunication(customer: f.customer, recipient: try f.recipient,
                    subject: "Fixture", deliveryStatus: "pending")
                f.context.insert(row); try f.context.save()
                return [row.persistentModelID, f.customer.persistentModelID]
            })
        for _ in 0..<100 where box.latest == nil { try await Task.sleep(for: .milliseconds(10)) }
        let notification = try #require(box.latest)
        let url = try #require(notification.userInfo?[NSPersistentStoreURLKey] as? URL)
        #expect(url.standardizedFileURL == directory.appendingPathComponent("fixture.store").standardizedFileURL)
        center.post(notification)
        #expect(throws: GmailDraftError.businessChanged) { try replacement.checkTransportPermit(context: f.context) }
        try await replacement.validateHistory(context: f.context)
        try replacement.checkTransportPermit(context: f.context)
        #expect(throws: GmailDraftError.businessChanged) { try original.check(context: f.context) }
    }

    @Test func diskBusinessSendPersistsHistoryAndDoesNotRetryAcceptedMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskMailSend-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let f = try Fixture(storeURL: directory.appendingPathComponent("fixture.store"))
        let flow = try await GmailSendWorkflow.prepare(auth: f.auth, context: f.context,
            message: GmailOutgoingMessage(to: try f.recipient, subject: "Fixture", body: "Fixture only"),
            business: f.business, validateAccess: { if !f.allowed { throw GmailComposeError.access } })
        #expect(await flow.send().state == .sent)
        #expect(await flow.send().state == .sent)
        #expect(f.writes.count == 1 && f.requests.count == 2)
        #expect(try f.history().map(\.deliveryStatus) == ["sent"])
    }

    @Test func diskHistoryRejectsExternalThenOwnTransactionInOneInterval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskMailCoalesced-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let f = try Fixture(storeURL: directory.appendingPathComponent("fixture.store"))
        let anchor = try #require(await GmailSourceHistoryReader.capture(f.context.container))
        let other = ModelContext(f.context.container)
        other.author = "external-fixture"
        other.insert(Customer(name: "Unrelated fixture"))
        try other.save()
        f.context.author = "own-fixture"
        let history = CustomerCommunication(customer: f.customer, recipient: try f.recipient,
            subject: "Fixture", deliveryStatus: "pending")
        f.context.insert(history); try f.context.save()
        do {
            _ = try await GmailSourceHistoryReader.verify(anchor, container: f.context.container,
                ownAuthor: "own-fixture", allowedIDs: [history.persistentModelID, f.customer.persistentModelID])
            Issue.record("A newer own-author transaction cannot hide a preceding external write.")
        } catch { #expect(error as? GmailDraftError == .businessChanged) }
    }

    @Test func unrelatedDiskStoreSaveDoesNotRevokeSourceLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskMailOtherStore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let f = try Fixture(storeURL: directory.appendingPathComponent("source.store"))
        let other = try Fixture(storeURL: directory.appendingPathComponent("other.store"))
        let lease = try await GmailDraftSourceLease.prepare(business: f.business, context: f.context)
        other.customer.name = "Changed in a separate store"
        try other.context.save()
        try await lease.validateHistory(context: f.context)
        try lease.checkTransportPermit(context: f.context)
    }

    @Test func diskHistoryRejectsPrunedAnchor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskMailPruned-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let f = try Fixture(storeURL: directory.appendingPathComponent("fixture.store"))
        let anchor = try #require(await GmailSourceHistoryReader.capture(f.context.container))
        try f.context.deleteHistory(HistoryDescriptor<DefaultHistoryTransaction>())
        do {
            _ = try await GmailSourceHistoryReader.verify(anchor, container: f.context.container)
            Issue.record("A pruned anchor cannot authorize a transport.")
        } catch { #expect(error as? GmailDraftError == .businessChanged) }
    }

    @Test func confirmedHistorySaveCannotRebaseChangedConsent() async throws {
        let f = try Fixture()
        var saves = 0
        let flow = try f.flow(to: try f.recipient, business: f.business, save: { context in
            saves += 1
            if saves == 2 { f.customer.allowsTransactionalEmail = false }
            try context.save()
        })
        #expect(await flow.send().state == .reviewRequired)
        #expect(f.writes.count == 1 && !f.customer.allowsTransactionalEmail)
        #expect(await flow.send().state == .reviewRequired)
        #expect(f.writes.count == 1)
    }

    @Test func historyWriteChecksCurrentAccessBeforeMutation() async throws {
        let f = try Fixture()
        let lease = try GmailDraftSourceLease(business: f.business, context: f.context)
        var mutations = 0
        do {
            _ = try await lease.replacingAfterHistoryWrite(business: f.business, context: f.context,
                beforeWrite: { throw GmailComposeError.access }, validatePreparation: {}, write: {
                    mutations += 1
                    return []
                })
            Issue.record("Changed access must reject before retained models are mutated.")
        } catch { #expect(error as? GmailComposeError == .access) }
        #expect(mutations == 0 && !f.context.hasChanges)
    }

    @Test func childPreflightCannotOutliveParentTransportPermit() async throws {
        let root = WorkspaceProviderOperation { true }
        var parentPermit = true
        let parent = WorkspaceProviderOperation(parent: root, beforeTransport: {}, transportFence: {
            if !parentPermit { throw GmailDraftError.businessChanged }
        }, isCurrent: { true })
        let child = WorkspaceProviderOperation(parent: parent, beforeTransport: {
            await Task.yield()
            parentPermit = false
        }, transportFence: {}, isCurrent: { true })
        let url = try #require(URL(string: "https://fixture.example.invalid/send"))
        var request = URLRequest(url: url); request.httpMethod = "POST"
        var sends = 0
        do {
            _ = try await child.data(for: request) { _ in
                sends += 1
                return (Data(), URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
            }
            Issue.record("A parent permit invalidated during a child await must block transport.")
        } catch { #expect(error as? GmailDraftError == .businessChanged) }
        #expect(sends == 0 && !child.mayHaveReachedProvider)
    }

    @Test func latePermitReclassificationNeverRetriesProviderMutation() async throws {
        let parent = WorkspaceProviderOperation { true }
        var classifications = 0
        let operation = WorkspaceProviderOperation(parent: parent, beforeTransport: { classifications += 1 }, transportFence: {
            if classifications == 1 { throw GmailDraftError.businessChanged }
        }, isCurrent: { true })
        let url = try #require(URL(string: "https://fixture.example.invalid/send"))
        var request = URLRequest(url: url); request.httpMethod = "POST"
        var sends = 0
        _ = try await operation.data(for: request) { _ in
            sends += 1
            return (Data(), URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }
        #expect(classifications == 3 && sends == 1)
    }

    @Test func failedHistoryWritePermanentlyRetiresItsOneShotLease() async throws {
        let f = try Fixture()
        let original = try GmailDraftSourceLease(business: f.business, context: f.context)
        do {
            _ = try await original.replacingAfterHistoryWrite(business: f.business, context: f.context,
                validatePreparation: {}, write: { throw GmailComposeError.save })
            Issue.record("A failed history write must throw.")
        } catch { #expect(error as? GmailComposeError == .save) }
        #expect(!f.context.hasChanges)
        #expect(throws: GmailDraftError.businessChanged) { try original.check(context: f.context) }
    }

    @Test func sourceLeaseRejectsAlreadyDirtyExcludedRowsBeforeArming() throws {
        let f = try Fixture()
        let unrelated = Customer(name: "Other fixture", email: "other@example.invalid")
        let invoice = Invoice(customer: unrelated, amount: 100)
        f.context.insert(unrelated); f.context.insert(invoice); try f.context.save()
        invoice.notes = "Already dirty outside the captured source"
        #expect(throws: GmailDraftError.businessChanged) {
            try GmailDraftSourceLease(business: f.business, context: f.context)
        }
        #expect(f.requests.isEmpty)
    }

    @Test func sourceLeaseCannotBecomeValidAgainAfterUnsavedEditAndRollback() throws {
        let f = try Fixture()
        let lease = try GmailDraftSourceLease(business: f.business, context: f.context)
        try lease.check(context: f.context)
        f.call.notes = "Changed before transport"
        #expect(throws: GmailDraftError.businessChanged) { try lease.check(context: f.context) }
        f.context.rollback()
        #expect(!f.context.hasChanges)
        #expect(throws: GmailDraftError.businessChanged) { try lease.check(context: f.context) }
    }

    @Test func businessMutationInsidePendingHistorySavePreventsPOST() async throws {
        let f = try Fixture()
        let flow = try f.flow(to: try f.recipient, business: f.business, save: { context in
            f.call.notes = "Changed inside the saving boundary"
            try context.save()
        })
        #expect(await flow.send().state == .notSent)
        #expect(f.requests.isEmpty)
        #expect(f.call.notes == "Changed inside the saving boundary")
    }

    @Test func newStatementInvoiceInsideOwnHistorySaveCannotRebaseDraft() async throws {
        let f = try Fixture()
        f.context.insert(Invoice(customer: f.customer, amount: 100)); try f.context.save()
        let business = GmailBusinessContext(customerID: f.customer.id, workflow: .accountStatement)
        let journal = try businessJournal(f, business: business)
        let flow = try f.flow(to: try f.recipient, business: business, journal: journal, save: { context in
            context.insert(Invoice(customer: f.customer, amount: 250))
            try context.save()
        })
        #expect(await flow.send().state == .notSent)
        #expect(f.requests.isEmpty)
        #expect(journal.record.state == .editing)
    }

    @Test func anotherContextsSavedChangeAfterPOSTRequiresReviewWithoutRetry() async throws {
        let f = try Fixture()
        let flow = try f.flow(to: try f.recipient, business: f.business)
        f.beforeReply = { request in
            guard request.httpMethod == "POST" else { return }
            let other = ModelContext(f.context.container)
            let id = f.call.id
            let call = try #require(try other.fetch(FetchDescriptor<ServiceCall>(predicate: #Predicate { $0.id == id })).first)
            call.notes = "Other context update"
            try other.save()
        }
        #expect(await flow.send().state == .reviewRequired)
        #expect(await flow.send().state == .reviewRequired)
        #expect(f.writes.count == 1 && f.requests.count == 1)
    }

    @Test func newlyInsertedStatementPaymentAfterPOSTRequiresReviewWithoutRetry() async throws {
        let f = try Fixture()
        let invoice = Invoice(customer: f.customer, amount: 100)
        f.context.insert(invoice); try f.context.save()
        let business = GmailBusinessContext(customerID: f.customer.id, workflow: .accountStatement)
        let flow = try f.flow(to: try f.recipient, business: business)
        f.beforeReply = { request in
            if request.httpMethod == "POST" {
                f.context.insert(Payment(invoice: invoice, amount: 25, method: "Cash"))
            }
        }
        #expect(await flow.send().state == .reviewRequired)
        #expect(await flow.send().state == .reviewRequired)
        #expect(f.writes.count == 1 && f.requests.count == 1)
    }

    @Test func anotherContextsSaveInsideOwnHistoryWriteCannotBeExempted() async throws {
        let f = try Fixture()
        let flow = try f.flow(to: try f.recipient, business: f.business, save: { context in
            let other = ModelContext(context.container)
            let id = f.call.id
            let call = try #require(try other.fetch(FetchDescriptor<ServiceCall>(predicate: #Predicate { $0.id == id })).first)
            call.notes = "Saved by a different context during the history write"
            try other.save()
            try context.save()
        })
        #expect(await flow.send().state == .notSent)
        #expect(f.requests.isEmpty)
    }

    @Test func saveDuringPreparationRevokesLeaseBeforeItsCaptureCanRebase() throws {
        let f = try Fixture()
        #expect(throws: GmailDraftError.businessChanged) {
            try GmailDraftSourceLease(business: f.business, context: f.context, validatePreparation: {
                let other = ModelContext(f.context.container)
                other.insert(Customer(name: "Duplicate recipient", email: f.customer.email))
                try other.save()
            })
        }
        #expect(f.requests.isEmpty)
    }

    @Test func remoteStoreEventRevokesLeaseSynchronouslyBeforeAnotherActorTurn() throws {
        let f = try Fixture()
        let center = NotificationCenter()
        let lease = try GmailDraftSourceLease(business: f.business, context: f.context, notificationCenter: center)
        center.post(name: .NSPersistentStoreRemoteChange, object: nil)
        #expect(throws: GmailDraftError.businessChanged) { try lease.check(context: f.context) }
    }

    private func businessJournal(_ f: Fixture, business: GmailBusinessContext) throws -> GmailDraftSession {
        let scope = GmailDraftScope(companyID: UUID(), backendOrigin: "https://fixture.example.invalid", actorEmail: f.email, googleEmail: f.email)
        let content = GmailDraftContent(to: try f.recipient, subject: "Repair appointment", body: "Fixture only.",
            files: [.init(.init(fileName: "original.pdf", mimeType: "application/pdf", data: Data("Original PDF".utf8)))],
            business: business, requiresBusinessContext: true,
            businessSnapshot: try GmailDraftBusinessSnapshot.capture(business, context: f.context))
        return try GmailDraftSession(record: .init(id: UUID(), scope: scope, content: content), store: f.draftStore, access: {})
    }

    @Test func knownCustomerGeneralMailIsAuditedWithoutRequiringAJobTemplate() async throws {
        let f = try Fixture()
        let result = await (try f.flow(to: f.customer.email!)).send()
        #expect(result.state == .sent)
        let history = try f.history()
        #expect(history.count == 1 && history[0].deliveryStatus == "sent")
        #expect(history[0].actorEmail == f.email)
        #expect(history[0].providerMessageID == "sent-message")
        #expect(history[0].providerStatusDetail?.contains("recipient delivery is not verified") == true)
    }

    @Test func businessAttemptIsSavedBeforePOSTAndConfirmedOnlyAfterExactSentRead() async throws {
        let f = try Fixture()
        f.beforeReply = { request in
            let history = try f.history()
            #expect(history.count == 1 && history[0].deliveryStatus == "pending")
            #expect(history[0].providerMessageID == nil)
            #expect(request.url?.host == "gmail.googleapis.com")
        }
        let result = await (try f.flow(to: f.customer.email!, business: f.business)).send()
        #expect(result.state == .sent)
        #expect(try f.history().first?.serviceCallID == f.call.id)
    }

    @Test func optingOutSuppressesEveryRecipientBeforeNetworkAndRetainsConsentAudit() async throws {
        let f = try Fixture()
        f.customer.allowsTransactionalEmail = false
        let result = await (try f.flow(to: "vendor@example.invalid, customer@example.invalid")).send()
        #expect(result.state == .notSent && f.requests.isEmpty)
        #expect(try f.history().first?.deliveryStatus == "suppressed")
        #expect(try f.history().first?.consentSnapshot?.allowsTransactionalEmail == false)
    }

    @Test func marketingAndTransactionalConsentAreNotInterchangeable() async throws {
        let f = try Fixture()
        f.customer.allowsMarketing = true; f.customer.allowsTransactionalEmail = false
        let result = await (try f.flow(to: f.customer.email!)).send()
        #expect(result.canRetry && f.writes.isEmpty)
    }

    @Test func ambiguousCustomerEmailCannotChooseTheFirstCustomer() throws {
        let f = try Fixture()
        f.context.insert(Customer(name: "Different customer", email: f.customer.email))
        #expect(throws: GmailComposeError.changed) { try f.flow(to: f.customer.email!) }
        #expect(f.requests.isEmpty)
    }

    @Test func businessTemplateCannotAddAnotherRecipient() throws {
        let f = try Fixture()
        #expect(throws: GmailComposeError.changed) {
            try f.flow(to: "customer@example.invalid, vendor@example.invalid", business: f.business)
        }
    }

    @Test func incompleteBusinessLinkCannotBecomeGeneralMail() throws {
        let f = try Fixture()
        let invalid = GmailBusinessContext(customerID: f.customer.id, serviceCallID: UUID(), workflow: .appointmentConfirmation)
        #expect(throws: GmailComposeError.changed) { try f.flow(to: f.customer.email!, business: invalid) }
    }

    @Test func missingCustomerRelationshipDoesNotCrashTemplateValidation() throws {
        let f = try Fixture()
        f.call.customer = nil
        #expect(throws: GmailComposeError.changed) { try f.flow(to: f.customer.email!, business: f.business) }
    }

    @Test func failureSavingTheAttemptPreventsPOSTAndPreservesUnrelatedEdits() async throws {
        let f = try Fixture()
        f.call.notes = "Unrelated unsaved technician note"
        let flow = try f.flow(to: f.customer.email!, save: { _ in throw GmailComposeError.save })
        let result = await flow.send()
        #expect(result.state == .notSent && f.requests.isEmpty)
        #expect(try f.history().isEmpty)
        #expect(f.call.notes == "Unrelated unsaved technician note")
    }

    @Test func failedConfirmationSaveRetainsProviderEvidenceAndCannotSendAgain() async throws {
        let f = try Fixture()
        var saves = 0
        let flow = try f.flow(to: f.customer.email!, save: { context in
            saves += 1
            if saves == 2 { throw GmailComposeError.save }
            try context.save()
        })
        let result = await flow.send()
        #expect(result.state == .reviewRequired)
        #expect(result.message.contains("Gmail accepted"))
        #expect(try f.history().first?.providerMessageID == "sent-message")
        _ = await flow.send()
        #expect(f.writes.count == 1)
    }

    @Test func lostSendResponseIsNotAFailureOrPermissionToResend() async throws {
        let f = try Fixture()
        f.beforeReply = { _ in throw URLError(.networkConnectionLost) }
        let flow = try f.flow(to: f.customer.email!)
        let result = await flow.send()
        #expect(result.state == .reviewRequired && !result.canRetry)
        #expect(try f.history().first?.deliveryStatus == "unconfirmed")
        _ = await flow.send()
        #expect(f.writes.count == 1)
    }

    @Test func serverFailureAndThrottlingDoNotAutomaticallyResend() async throws {
        for status in [429, 500, 502, 503, 504] {
            let f = try Fixture(); f.status = status
            let flow = try f.flow()
            #expect(await flow.send().state == .reviewRequired)
            _ = await flow.send()
            #expect(f.writes.count == 1)
        }
    }

    @Test func providerRejectionLeavesAReusableDraftWithoutAutomaticRetry() async throws {
        let f = try Fixture(); f.status = 400
        let flow = try f.flow()
        #expect(await flow.send().state == .notSent)
        _ = await flow.send()
        #expect(f.writes.count == 1)
    }

    @Test func successWithoutMatchingSentEvidenceDoesNotAdvanceBusinessWork() async throws {
        for variant in 0..<3 {
            let f = try Fixture()
            if variant == 0 { f.sentLabels = ["DRAFT"] }
            if variant == 1 { f.wrongMessageID = true }
            if variant == 2 { f.wrongRecipient = true }
            let result = await (try f.flow(to: f.customer.email!, business: f.business)).send()
            #expect(result.state == .reviewRequired)
            #expect(try f.history().first?.deliveryStatus == "unconfirmed")
            #expect(try f.context.fetch(FetchDescriptor<ServiceCallActivity>()).isEmpty)
        }
    }

    @Test func rejectedSentVerificationCannotAuthorizeAnotherMessageAfterAcceptedPOST() async throws {
        for code in [400, 401, 403, 404] {
            let f = try Fixture()
            f.beforeReply = { request in if request.httpMethod == "GET" { f.status = code } }
            let flow = try f.flow(to: f.customer.email!, business: f.business)
            #expect(await flow.send().state == .reviewRequired)
            #expect(await flow.send().state == .reviewRequired)
            #expect(f.writes.count == 1)
            #expect(try f.history().first?.deliveryStatus == "unconfirmed")
        }
    }

    @Test func pendingAndUnconfirmedHistoryCannotBeUploadedAsAConfirmedOutcome() throws {
        let f = try Fixture()
        let record = CustomerCommunication(customer: f.customer, recipient: f.customer.email!, subject: "Fixture", deliveryStatus: "pending")
        #expect(!record.needsSharedCompanySync)
        record.deliveryStatus = "unconfirmed"
        #expect(!record.needsSharedCompanySync)
        for status in ["sent", "failed", "suppressed"] {
            record.deliveryStatus = status
            #expect(record.needsSharedCompanySync)
        }
    }

    @Test func businessWorkflowAccessSeparatesFieldAndAccountingFromTheOfficeMailbox() {
        let customerID = UUID()
        let invoice = GmailBusinessContext(customerID: customerID, invoiceID: UUID(), workflow: .receipt)
        let call = GmailBusinessContext(customerID: customerID, serviceCallID: UUID(), workflow: .customerDocument)
        let statement = GmailBusinessContext(customerID: customerID, workflow: .accountStatement)
        #expect(GmailSendWorkflow.allowsBusinessWorkflow(role: .fieldTechnician, business: call))
        #expect(!GmailSendWorkflow.allowsBusinessWorkflow(role: .fieldTechnician, business: statement))
        #expect(!GmailSendWorkflow.allowsBusinessWorkflow(role: .fieldTechnician, business: nil))
        #expect(GmailSendWorkflow.allowsBusinessWorkflow(role: .accounting, business: invoice))
        #expect(GmailSendWorkflow.allowsBusinessWorkflow(role: .accounting, business: statement))
        #expect(!GmailSendWorkflow.allowsBusinessWorkflow(role: .accounting, business: call))
        #expect(!GmailSendWorkflow.allowsBusinessWorkflow(role: .dispatcher, business: invoice))
        #expect(GmailSendWorkflow.allowsBusinessWorkflow(role: .dispatcher, business: nil))
        #expect(!GmailSendWorkflow.allowsBusinessWorkflow(role: nil, business: invoice))
    }

    @Test func accessLossBeforeSchedulingDoesNotSend() async throws {
        let f = try Fixture()
        let flow = try f.flow()
        f.allowed = false
        #expect(await flow.send().state == .notSent)
        #expect(f.requests.isEmpty)
    }

    @Test func changedCustomerOrConsentBeforeSchedulingDoesNotSend() async throws {
        for change in 0..<2 {
            let f = try Fixture()
            let flow = try f.flow(to: f.customer.email!)
            if change == 0 { f.customer.email = "replacement@example.invalid" }
            else { f.customer.allowsTransactionalEmail = false }
            #expect(await flow.send().state == .notSent)
            #expect(f.requests.isEmpty)
        }
    }

    @Test func originalProviderIsRetainedWhenBusinessLoginChangesBeforeSend() async throws {
        let f = try Fixture()
        let flow = try f.flow()
        f.auth.signOut()
        #expect(await flow.send().state == .notSent)
        #expect(f.requests.isEmpty)
    }

    @Test func roleLossDuringPOSTRetainsUnconfirmedHistoryAndStopsFollowup() async throws {
        let f = try Fixture()
        f.beforeReply = { _ in f.allowed = false }
        let result = await (try f.flow(to: f.customer.email!, business: f.business)).send()
        #expect(result.state == .reviewRequired && f.requests.count == 1)
        #expect(try f.history().first?.deliveryStatus == "pending")
        #expect(try f.context.fetch(FetchDescriptor<ServiceCallActivity>()).isEmpty)
    }

    @Test func customerReassignmentDuringSentReadCannotAuditTheReplacement() async throws {
        let f = try Fixture()
        f.beforeReply = { request in
            if request.httpMethod == "GET" { f.call.customer = Customer(name: "Replacement", email: "other@example.invalid") }
        }
        let result = await (try f.flow(to: f.customer.email!, business: f.business)).send()
        #expect(result.state == .reviewRequired)
        #expect(try f.history().first?.customer === f.customer)
        #expect(try f.history().first?.deliveryStatus == "pending")
    }

    @Test func concurrentSendOfTheSameInstanceCanOnlyDispatchOnce() async throws {
        let f = try Fixture()
        f.beforeReply = { _ in await Task.yield() }
        let flow = try f.flow()
        async let one = flow.send()
        async let two = flow.send()
        let outcomes = await [one, two]
        #expect(outcomes.contains { $0.state == .sent })
        #expect(f.writes.count == 1)
    }

    @Test func recipientListsHandleQuotedNamesAndDeduplicateWithoutDroppingPeople() throws {
        #expect(try GmailAddressList.parse(#""Customer, Jordan" <Jordan@example.com>, vendor@example.com, jordan@EXAMPLE.com"#)
                == ["Jordan@example.com", "vendor@example.com"])
    }

    @Test func malformedAndHeaderInjectedRecipientsAreRejected() {
        for address in ["", "a@example.com,", "a@example.com\r\nBcc: hidden@example.com",
                        "Group:a@example.com;", "bad@@example.com", "name <a@example.com> extra",
                        "\"unclosed <a@example.com>", "a..b@example.com", ".a@example.com", "a@localhost"] {
            #expect(throws: GmailComposeError.recipients) { try GmailAddressList.parse(address) }
        }
    }

    @Test func missingAttachmentsFailTheWholeLoadInsteadOfSilentlySendingASubset() {
        var reads = 0
        #expect(throws: GmailComposeError.attachment) {
            try GmailOutgoingMessage.attachments(paths: ["/fixture/first.pdf", "/fixture/missing.pdf"]) { _ in
                reads += 1
                if reads == 2 { throw URLError(.fileDoesNotExist) }
                return Data("fixture".utf8)
            }
        }
        #expect(reads == 2)
    }

    @Test func malformedMIMEAndSubjectHeadersCannotReachProvider() {
        #expect(throws: GmailComposeError.header) {
            try GmailOutgoingMessage(to: "valid@example.com", subject: "Subject\r\nBcc: hidden@example.com", body: "body")
        }
        #expect(throws: GmailComposeError.attachment) {
            try GmailOutgoingMessage(to: "valid@example.com", subject: "Subject", body: "body",
                attachments: [.init(fileName: "invoice.pdf", mimeType: "application/pdf\r\nX-Header: injected", data: Data([1]))])
        }
    }

    @Test func repliesIncludeOriginalRFCIdentityAndSubjectWhileChangedSubjectStartsANewThread() throws {
        let reply = GmailReplyContext(threadID: "thread", messageID: "<original@example.invalid>",
                                      references: ["<earlier@example.invalid>"], subject: "Original subject")
        let outgoing = try GmailOutgoingMessage(to: "vendor@example.invalid", subject: reply.subject, body: "Reply", reply: reply)
        let raw = GoogleAuthManager.makeGmailRawMessage(to: outgoing.to, subject: outgoing.subject, body: outgoing.body,
            reply: outgoing.reply, messageID: "<new@gunnaire.com>")
        #expect(raw.contains("Message-ID: <new@gunnaire.com>"))
        #expect(raw.contains("In-Reply-To: <original@example.invalid>"))
        #expect(raw.contains("References: <earlier@example.invalid> <original@example.invalid>"))
        #expect(try GmailOutgoingMessage(to: outgoing.to, subject: "Different subject", body: "Reply", reply: reply).reply == nil)
    }

    @Test func unicodeBodyUsesAnHonestMIMETransferEncoding() {
        let text = "Heat pump — 72°F, café"
        let raw = GoogleAuthManager.makeGmailRawMessage(to: "customer@example.invalid", subject: "Service", body: text)
        #expect(raw.contains("Content-Transfer-Encoding: base64"))
        #expect(raw.contains(Data(text.utf8).base64EncodedString()))
        #expect(!raw.contains("7bit"))
    }

    @Test func attachedPlainTextCodeIsNotPresentedAsTheEmailBody() {
        let attachment = GmailMessagePayload(headers: nil, mimeType: "text/plain",
            body: .init(data: Data("const secret = 123".utf8).base64EncodedString(), size: nil),
            parts: nil, filename: "source.txt")
        let actual = GmailMessagePayload(headers: nil, mimeType: "text/html",
            body: .init(data: Data("<p>Your appointment is set.</p>".utf8).base64EncodedString(), size: nil),
            parts: nil, filename: nil)
        let payload = GmailMessagePayload(headers: nil, mimeType: "multipart/mixed", body: nil,
                                          parts: [attachment, actual], filename: nil)
        #expect(GmailMessagePresentation.bodyText(from: payload) == "Your appointment is set.")
    }

    @Test func mailboxAccessCannotUseThePrimaryEmailAsAnAdministratorBypass() {
        #expect(!GmailSendWorkflow.allowsMailbox(sender: AppAccess.primaryAdminEmail,
            currentEmail: AppAccess.primaryAdminEmail, users: [], verifiedRole: .admin))
        let user = AppUser(email: "staff@example.invalid", role: .dispatcher)
        #expect(GmailSendWorkflow.allowsMailbox(sender: user.email, currentEmail: user.email, users: [user], verifiedRole: .dispatcher))
        user.isActive = false
        #expect(!GmailSendWorkflow.allowsMailbox(sender: user.email, currentEmail: user.email, users: [user], verifiedRole: .dispatcher))
    }
}
