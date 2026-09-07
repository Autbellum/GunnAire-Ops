import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct GmailSendWorkflowTests {
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
        var beforeReply: ((URLRequest) async throws -> Void)?
        lazy var auth = GoogleAuthManager(testTokens: .init(accessToken: "fixture-token",
            refreshToken: nil, idToken: nil, expiration: .distantFuture), email: email,
            businessEmail: { self.email }) { [unowned self] request in
                requests.append(request)
                try await beforeReply?(request)
                return try response(request)
            }

        init() throws {
            let schema = GunnAireModelSchema.schema
            context = ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ]))
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

        func flow(to: String = "vendor@example.invalid", business: GmailBusinessContext? = nil,
                  save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws -> GmailSendWorkflow {
            try GmailSendWorkflow(auth: auth, context: context,
                message: GmailOutgoingMessage(to: to, subject: "Repair appointment", body: "Fixture only."),
                business: business, validateAccess: { if !self.allowed { throw GmailComposeError.access } }, save: save)
        }

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
