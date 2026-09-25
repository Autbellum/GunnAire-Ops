import Foundation
import SwiftData

/// Customer consent and local history for one explicit QuickBooks email action.
/// The API's durable journal owns provider reconciliation and duplicate safety.
@MainActor
final class QuickBooksCustomerEmailWorkflow {
    private let context: ModelContext
    private let document: QuickBooksBillingDocument
    private let customer: Customer
    private let customerID: UUID
    private let documentID: UUID
    private let actor: String
    let recipient: String
    let quickBooksCustomerID: String
    private let consent: CustomerCommunicationConsentSnapshot
    private let validateDocument: () throws -> Void
    private let access: () throws -> Void
    private let save: (ModelContext) throws -> Void
    private let customerQuickBooksID: String?
    private var communication: CustomerCommunication?
    private var communicationID: UUID?
    private var completed = false

    init(context: ModelContext, document: QuickBooksBillingDocument, recipient: String?,
         validateAccess: (() throws -> Void)? = nil,
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        self.context = context; self.document = document; self.save = save
        let access = validateAccess ?? { try Self.requireAccess(context: context, document: document) }
        try access()
        let validateDocument = document.validation(context: context)
        try validateDocument()
        guard let customer = document.customer else { throw GmailComposeError.changed }
        let addresses = try GmailAddressList.parse(recipient ?? customer.email ?? "")
        guard addresses.count == 1, let address = addresses.first,
              AppAccess.normalizedEmail(address) == AppAccess.normalizedEmail(customer.email) else {
            throw QuickBooksDocumentEmailError.recipientRequired
        }
        guard let linkedCustomerID = customer.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !linkedCustomerID.isEmpty else { throw QuickBooksBillingWorkflowError.customerConflict }
        quickBooksCustomerID = linkedCustomerID
        self.customer = customer; customerID = customer.id; documentID = document.id
        self.recipient = AppAccess.normalizedEmail(address)
        consent = CustomerCommunicationConsentSnapshot(customer: customer)
        customerQuickBooksID = customer.quickBooksID
        actor = AppAccess.normalizedEmail(AppIdentity.currentEmail)
        self.access = access; self.validateDocument = validateDocument
        try validate(requireConsent: false)
    }

    static func requireAccess(context: ModelContext, document: QuickBooksBillingDocument) throws {
        let users = try context.fetch(FetchDescriptor<AppUser>())
        guard AppAccess.canAccessSidebarItem(.mail, email: AppIdentity.currentEmail, users: users) else {
            throw GmailComposeError.access
        }
        try QuickBooksBillingAccessPolicy.validate(context: context, document: document)
    }

    /// Stop before document preparation, retaining a suppression audit when
    /// the original customer's consent explicitly disallows this message.
    func checkEligibilityAndRecordSuppression() throws {
        do { try validate() }
        catch GmailComposeError.consent {
            try prepare()
            throw GmailComposeError.consent
        }
    }

    func prepare() throws {
        guard communication == nil, !completed else { throw QuickBooksDocumentEmailError.busy }
        try validate(requireConsent: false)
        let allowed = customer.allowsTransactionalEmail
        let record = CustomerCommunication(customer: customer, serviceCallID: document.serviceCallID,
            invoiceID: invoiceID, estimateID: estimateID, recipient: recipient,
            subject: "QuickBooks \(document.label.lowercased())", deliveryStatus: allowed ? "pending" : "suppressed",
            workflow: .customerDocument, actorEmail: actor,
            consentSnapshot: consent,
            providerStatusDetail: allowed ? "Prepared for QuickBooks; provider acceptance is not yet confirmed." : GmailComposeError.consent.localizedDescription)
        context.insert(record)
        do { try save(context) }
        catch { context.delete(record); throw GmailComposeError.save }
        communicationID = record.id
        communication = record
        try validate()
    }

    /// Called again by the transport fence immediately before its POST and after
    /// awaits. A replacement model with the same UUID cannot inherit this action.
    func validateSend() throws {
        guard let communication, let id = communicationID, !completed else { throw QuickBooksDocumentEmailError.busy }
        try validate()
        let rows = try context.fetch(FetchDescriptor<CustomerCommunication>(predicate: #Predicate { $0.id == id }))
        guard rows.count == 1, rows.first === communication,
              communication.customer === customer, communication.recipient == recipient,
              communication.invoiceID == invoiceID, communication.estimateID == estimateID,
              communication.deliveryStatus == "pending" else { throw GmailComposeError.changed }
    }

    func finish(_ result: Result<Void, Error>) -> String {
        guard !completed else { return "Review the recorded QuickBooks email status before sending again." }
        defer { completed = true }
        let accepted: Bool
        let detail: String
        let status: String
        switch result {
        case .success:
            accepted = true; status = "sent"
            detail = "QuickBooks accepted the email to \(recipient). Recipient delivery is not verified."
        case .failure(let error):
            accepted = (error as? QuickBooksDocumentEmailError) == .reconciled
            switch error as? QuickBooksDocumentEmailError {
            case .reconciled:
                status = "sent"; detail = error.localizedDescription
            case .reviewRequired, .acceptedInOriginalWorkspace, .storage:
                status = "unconfirmed"; detail = error.localizedDescription
            default:
                status = "failed"; detail = "QuickBooks did not confirm a new email. \(error.localizedDescription)"
            }
        }
        do {
            try validateSend()
            guard let communication else { throw GmailComposeError.changed }
            let oldStatus = communication.deliveryStatus, oldDetail = communication.providerStatusDetail
            let oldDate = communication.deliveredAt
            let restoreDocument = sentStatusRestoration()
            communication.deliveryStatus = status
            communication.providerStatusDetail = CustomerCommunication.safeProviderStatusDetail(detail)
            // This is provider acceptance time, not recipient delivery proof.
            communication.deliveredAt = accepted ? Date() : nil
            if accepted { markDocumentSent() }
            do { try save(context) }
            catch {
                restoreDocument()
                communication.deliveryStatus = oldStatus
                communication.providerStatusDetail = oldDetail
                communication.deliveredAt = oldDate
                return "QuickBooks may have accepted the email, but its result could not be saved locally. Review QuickBooks before trying again."
            }
            return detail
        } catch {
            return detail + " Local history was not updated because access, consent, or the original record changed. Review the original document before retrying."
        }
    }

    private var invoiceID: UUID? { if case .invoice = document { documentID } else { nil } }
    private var estimateID: UUID? { if case .estimate = document { documentID } else { nil } }

    private func validate(requireConsent: Bool = true) throws {
        try access()
        guard actor == AppAccess.normalizedEmail(AppIdentity.currentEmail) else { throw GmailComposeError.access }
        try validateDocument()
        let id = customerID
        let rows = try context.fetch(FetchDescriptor<Customer>(predicate: #Predicate { $0.id == id }))
        guard rows.count == 1, rows.first === customer,
              document.customer === customer, customer.quickBooksID == customerQuickBooksID,
              AppAccess.normalizedEmail(customer.email) == recipient,
              CustomerCommunicationConsentSnapshot(customer: customer) == consent else { throw GmailComposeError.changed }
        let linkedID = quickBooksCustomerID
        let linkedCustomers = try context.fetch(FetchDescriptor<Customer>(predicate: #Predicate { $0.quickBooksID == linkedID }))
        guard linkedCustomers.count == 1, linkedCustomers.first === customer else {
            throw QuickBooksBillingWorkflowError.customerConflict
        }
        if requireConsent, !customer.allowsTransactionalEmail { throw GmailComposeError.consent }
    }

    private func sentStatusRestoration() -> () -> Void {
        switch document {
        case .invoice(let value): let status = value.status; return { value.status = status }
        case .estimate(let value): let status = value.status; return { value.status = status }
        }
    }

    private func markDocumentSent() {
        switch document {
        case .estimate(let value):
            if !["accepted", "rejected"].contains(value.status.lowercased()) { value.status = "sent" }
        case .invoice(let value):
            if !["paid", "partial"].contains(value.status.lowercased()) { value.status = "sent" }
        }
    }
}
