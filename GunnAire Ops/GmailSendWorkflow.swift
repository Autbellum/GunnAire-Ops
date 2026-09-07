import Foundation
import SwiftData

/// One reviewed message, original business/provider identity and send attempt.
/// A response timeout never becomes permission to send this instance again.
@MainActor
final class GmailSendWorkflow {
    let message: GmailOutgoingMessage
    let business: GmailBusinessContext?
    let messageID = "<gunnaire-\(UUID().uuidString.lowercased())@gunnaire.com>"
    private let auth: GoogleAuthManager
    private let context: ModelContext
    private let sender: String
    private let provider: WorkspaceProviderOperation
    private let access: () throws -> Void
    private let save: (ModelContext) throws -> Void
    private var baseline: [String] = []
    private var communications: [CustomerCommunication] = []
    private var running = false
    private var outcome: GmailSendOutcome?

    private lazy var operation = WorkspaceProviderOperation(parent: provider) { [weak self] in
        guard let self else { return false }
        return (try? self.checkRecordsAndAccess()) != nil
    }

    init(auth: GoogleAuthManager, context: ModelContext, message: GmailOutgoingMessage,
         business: GmailBusinessContext? = nil, provider: WorkspaceProviderOperation? = nil,
         validateAccess: (() throws -> Void)? = nil,
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        self.auth = auth; self.context = context; self.message = message; self.business = business
        sender = AppAccess.normalizedEmail(auth.signedInEmail)
        self.provider = try provider ?? auth.captureProviderOperation()
        self.save = save
        access = validateAccess ?? { try Self.requireAccess(context: context, business: business, sender: auth.signedInEmail) }
        try self.provider.check()
        try access()
        baseline = try recordState()
    }

    func send() async -> GmailSendOutcome {
        if let outcome { return outcome }
        guard !running else { return .notSent(GmailComposeError.busy) }
        running = true
        defer { running = false }
        var receivedSendResponse = false
        do {
            try check()
            let customers = try matchingCustomers()
            let consentAllowed = customers.allSatisfy {
                business?.workflow.requiresMarketingConsent == true ? $0.allowsMarketing : $0.allowsTransactionalEmail
            }
            communications = customers.map { customer in
                CustomerCommunication(customer: customer, serviceCallID: business?.serviceCallID,
                    invoiceID: business?.invoiceID, estimateID: business?.estimateID,
                    maintenanceContractID: business?.maintenanceContractID, recipient: AppAccess.normalizedEmail(customer.email),
                    subject: message.subject.trimmingCharacters(in: .whitespaces).isEmpty ? "(No subject)" :
                        String(String.UnicodeScalarView(message.subject.unicodeScalars.prefix(500))),
                    deliveryStatus: consentAllowed ? "pending" : "suppressed",
                    workflow: business?.workflow ?? .general, actorEmail: sender,
                    consentSnapshot: CustomerCommunicationConsentSnapshot(customer: customer),
                    providerStatusDetail: consentAllowed ? "Prepared for Gmail; sending outcome is not yet confirmed." :
                        GmailComposeError.consent.localizedDescription,
                    attachmentFileNames: message.attachments.map(\.fileName))
            }
            for record in communications { context.insert(record) }
            do { if !communications.isEmpty { try save(context) } }
            catch {
                for record in communications { context.delete(record) }
                communications = []
                throw GmailComposeError.save
            }
            try check()
            if !consentAllowed {
                let result = GmailSendOutcome.notSent(GmailComposeError.consent)
                outcome = result
                synchronizeHistory()
                return result
            }
            let sent: GmailMessageReference = try await withCheckedThrowingContinuation { continuation in
                auth.sendGmailMessage(to: message.to, subject: message.subject, body: message.body,
                    threadID: message.reply?.threadID, attachments: message.attachments,
                    reply: message.reply, messageID: messageID, operation: operation) {
                        continuation.resume(with: $0)
                    }
            }
            receivedSendResponse = true
            try check()
            guard GoogleAuthManager.calendarPathComponent(sent.id) != nil,
                  GoogleAuthManager.calendarPathComponent(sent.threadId) != nil else {
                throw GoogleAuthError.decoding
            }
            let confirmed: GmailMessageDetail = try await withCheckedThrowingContinuation { continuation in
                auth.fetchGmailMessage(id: sent.id, operation: operation) { continuation.resume(with: $0) }
            }
            try check()
            guard confirmed.id == sent.id, confirmed.threadId == sent.threadId,
                  confirmed.labelIds?.contains("SENT") == true,
                  GmailMessagePresentation.headerValue(named: "Message-ID", in: confirmed) == messageID,
                  let from = GmailMessagePresentation.headerValue(named: "From", in: confirmed),
                  try GmailAddressList.parse(from).map({ $0.lowercased() }) == [sender],
                  let to = GmailMessagePresentation.headerValue(named: "To", in: confirmed),
                  Set(try GmailAddressList.parse(to).map { $0.lowercased() }) ==
                  Set(try GmailAddressList.parse(message.to).map { $0.lowercased() }) else {
                throw GoogleAuthError.decoding
            }
            let now = Date()
            for record in communications {
                record.deliveryStatus = "sent"
                record.providerMessageID = sent.id
                record.providerStatusDetail = "Gmail accepted the message for sending; recipient delivery is not verified."
                record.deliveredAt = now
            }
            if let business {
                CustomerCommunicationWorkflow.applyConfirmedSend(workflow: business.workflow,
                    customerID: business.customerID, serviceCallID: business.serviceCallID,
                    invoiceID: business.invoiceID, estimateID: business.estimateID,
                    maintenanceContractID: business.maintenanceContractID,
                    estimates: try context.fetch(FetchDescriptor<Estimate>()),
                    invoices: try context.fetch(FetchDescriptor<Invoice>()),
                    serviceCalls: try context.fetch(FetchDescriptor<ServiceCall>()),
                    recurringContracts: try context.fetch(FetchDescriptor<RecurringMaintenanceContract>()),
                    now: now, actorEmail: sender, deliveryEvidenceText: "Gmail accepted the message for sending",
                    in: context)
            }
            // Intentional operational follow-up becomes this workflow's new baseline.
            baseline = try recordState()
            do { if !communications.isEmpty { try save(context) } }
            catch {
                let result = GmailSendOutcome(state: .reviewRequired,
                    message: "Gmail accepted the message, but its local history could not be saved. Do not send another copy. Review customer history and Gmail Sent.")
                outcome = result
                return result
            }
            let result = GmailSendOutcome(state: .sent, message: "Message saved in Gmail Sent.")
            outcome = result
            synchronizeHistory()
            return result
        } catch {
            let rejected: Bool
            if case GoogleAuthError.http(let code) = error {
                // A failed verification GET cannot undo an accepted POST or
                // authorize another copy of a possibly sent customer message.
                rejected = !receivedSendResponse && [400, 401, 403, 404, 413, 422].contains(code)
            } else { rejected = false }
            let result: GmailSendOutcome = operation.mayHaveReachedProvider && !rejected
                ? .uncertain : .notSent(error)
            // Never attach a late result to another workspace or changed job.
            if (try? check()) != nil {
                for record in communications {
                    record.deliveryStatus = result.canRetry ? "failed" : "unconfirmed"
                    record.providerStatusDetail = result.message
                }
                if !communications.isEmpty { try? save(context) }
            }
            outcome = result
            return result
        }
    }

    private func check() throws {
        try provider.check()
        try checkRecordsAndAccess()
        try Task.checkCancellation()
    }

    private func checkRecordsAndAccess() throws {
        try access()
        guard try recordState() == baseline else { throw GmailComposeError.changed }
        let current = try context.fetch(FetchDescriptor<CustomerCommunication>())
        guard communications.allSatisfy({ retained in current.contains { $0 === retained } }) else {
            throw GmailComposeError.changed
        }
    }

    private func matchingCustomers() throws -> [Customer] {
        let all = try context.fetch(FetchDescriptor<Customer>())
        let recipients = try GmailAddressList.parse(message.to).map { AppAccess.normalizedEmail($0) }
        let matches: [Customer]
        if let business {
            matches = all.filter { $0.id == business.customerID }
            guard matches.count == 1, recipients == [AppAccess.normalizedEmail(matches[0].email)] else {
                throw GmailComposeError.changed
            }
        } else {
            matches = all.filter { recipients.contains(AppAccess.normalizedEmail($0.email)) }
        }
        for recipient in recipients {
            guard all.filter({ AppAccess.normalizedEmail($0.email) == recipient }).count <= 1 else {
                throw GmailComposeError.changed
            }
        }
        return matches.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func recordState() throws -> [String] {
        let customers = try matchingCustomers()
        var state = customers.flatMap {
            [String(describing: ObjectIdentifier($0)), $0.id.uuidString, $0.name, $0.email ?? "",
             $0.address ?? "", String($0.allowsTransactionalEmail), String($0.allowsMarketing),
             $0.communicationConsentUpdatedAt?.description ?? ""]
        }
        guard let business else { return state }
        let calls = try context.fetch(FetchDescriptor<ServiceCall>())
        let invoices = try context.fetch(FetchDescriptor<Invoice>())
        let estimates = try context.fetch(FetchDescriptor<Estimate>())
        let contracts = try context.fetch(FetchDescriptor<RecurringMaintenanceContract>())
        func requireUnique<T: AnyObject>(_ values: [T], customer: (T) -> Customer?) throws -> T {
            guard values.count == 1, customer(values[0]) === customers[0] else { throw GmailComposeError.changed }
            return values[0]
        }
        if let id = business.serviceCallID {
            let call = try requireUnique(calls.filter { $0.id == id }, customer: { $0.customer })
            state += [String(describing: ObjectIdentifier(call)), call.status.rawValue, call.eventTitle ?? "",
                      call.scheduledDate.description, String(call.duration), call.notes ?? "",
                      call.assignedTechnician?.id.uuidString ?? "", call.additionalTechnicianIDsJSON ?? ""]
        }
        if let id = business.invoiceID {
            let invoice = try requireUnique(invoices.filter { $0.id == id }, customer: { $0.customer })
            state += [String(describing: ObjectIdentifier(invoice)), invoice.status, String(invoice.amount),
                      String(describing: invoice.quickBooksBalanceDue), invoice.catalogSnapshotJSON ?? "",
                      invoice.quickBooksID ?? "", invoice.serviceCallID?.uuidString ?? ""]
        }
        if let id = business.estimateID {
            let estimate = try requireUnique(estimates.filter { $0.id == id }, customer: { $0.customer })
            state += [String(describing: ObjectIdentifier(estimate)), estimate.status, String(estimate.amount),
                      estimate.catalogSnapshotJSON ?? "", estimate.quickBooksID ?? "",
                      estimate.serviceCallID?.uuidString ?? ""]
        }
        if let id = business.maintenanceContractID {
            let contract = try requireUnique(contracts.filter { $0.id == id }, customer: { $0.customer })
            state += [String(describing: ObjectIdentifier(contract)), String(contract.active)]
        }
        guard CustomerCommunicationWorkflow.contextIsValid(workflow: business.workflow,
            customerID: business.customerID, serviceCallID: business.serviceCallID,
            invoiceID: business.invoiceID, estimateID: business.estimateID,
            maintenanceContractID: business.maintenanceContractID, estimates: estimates,
            invoices: invoices, serviceCalls: calls, recurringContracts: contracts) else {
            throw GmailComposeError.changed
        }
        return state
    }

    static func allowsMailbox(sender: String?, currentEmail: String?, users: [AppUser], verifiedRole: AppUserRole?) -> Bool {
        let email = AppAccess.normalizedEmail(sender)
        let matches = users.filter { AppAccess.normalizedEmail($0.email) == email }
        return !email.isEmpty && email == AppAccess.normalizedEmail(currentEmail) &&
            !matches.isEmpty && (verifiedRole == .admin || verifiedRole == .dispatcher) &&
            matches.allSatisfy { $0.isActive && $0.role == verifiedRole }
    }

    static func allowsBusinessWorkflow(role: AppUserRole?, business: GmailBusinessContext?) -> Bool {
        switch role {
        case .admin: return true
        case .dispatcher:
            return business?.invoiceID == nil &&
                ![.paymentReminder, .receipt, .accountStatement].contains(business?.workflow ?? .general)
        case .accounting:
            guard let business else { return false }
            return business.workflow == .accountStatement ||
                (business.invoiceID != nil && [.paymentReminder, .receipt, .customerDocument].contains(business.workflow))
        case .fieldTechnician:
            guard let business, business.workflow != .accountStatement,
                  business.maintenanceContractID == nil else { return false }
            return business.serviceCallID != nil || business.invoiceID != nil || business.estimateID != nil
        default: return false
        }
    }

    private static func requireAccess(context: ModelContext, business: GmailBusinessContext?, sender: String?) throws {
        let controller = CompanyWorkspaceAccessController.shared
        let users = try context.fetch(FetchDescriptor<AppUser>())
        let fixture = GunnAireCloudKit.usesTestDatabase
        let role = fixture ? users.first(where: { AppAccess.normalizedEmail($0.email) == AppAccess.normalizedEmail(sender) })?.role : controller.verifiedRole
        let email = AppAccess.normalizedEmail(sender)
        let matches = users.filter { AppAccess.normalizedEmail($0.email) == email }
        guard !email.isEmpty, email == AppAccess.normalizedEmail(AppIdentity.currentEmail),
              !matches.isEmpty, matches.allSatisfy({ $0.isActive && $0.role == role }),
              fixture || controller.authorizedContainer === context.container,
              allowsBusinessWorkflow(role: role, business: business) else { throw GmailComposeError.access }
        if let business, let id = business.invoiceID {
            let values = try context.fetch(FetchDescriptor<Invoice>()).filter { $0.id == id }
            guard values.count == 1, values[0].customer?.id == business.customerID else { throw GmailComposeError.access }
            try QuickBooksBillingAccessPolicy.validate(context: context, document: .invoice(values[0]))
        } else if let business, let id = business.estimateID {
            let values = try context.fetch(FetchDescriptor<Estimate>()).filter { $0.id == id }
            guard values.count == 1, values[0].customer?.id == business.customerID else { throw GmailComposeError.access }
            try QuickBooksBillingAccessPolicy.validate(context: context, document: .estimate(values[0]))
        } else if role == .fieldTechnician, let id = business?.serviceCallID {
            let calls = try context.fetch(FetchDescriptor<ServiceCall>()).filter { $0.id == id }
            let technicians = try context.fetch(FetchDescriptor<Technician>())
            let assigned = technicians.filter { AppAccess.normalizedEmail($0.contactInfo) == email }
            guard calls.count == 1, assigned.count == 1,
                  calls[0].customer?.id == business?.customerID,
                  technicians.filter({ $0.id == assigned[0].id }).count == 1,
                  (calls[0].assignedTechnician === assigned[0] || calls[0].assignedCrewTechnicianIDs.contains(assigned[0].id)) else {
                throw GmailComposeError.access
            }
        } else if role == .accounting, business?.workflow == .accountStatement {
            return
        } else {
            guard allowsMailbox(sender: sender, currentEmail: AppIdentity.currentEmail, users: users, verifiedRole: role) else {
                throw GmailComposeError.access
            }
        }
    }

    private func synchronizeHistory() {
        guard !GunnAireCloudKit.usesTestDatabase, GunnAireBackendService.isConfigured else { return }
        Task { @MainActor in
            for record in communications {
                do {
                    try check()
                    let remote = try await GunnAireBackendService.uploadCustomerCommunication(record)
                    try check()
                    record.markSharedCompanySynced(id: remote.id)
                    try save(context)
                } catch {
                    guard (try? check()) != nil else { return }
                    record.markSharedCompanySyncFailed("Company email history needs another sync attempt.")
                    try? save(context)
                }
            }
        }
    }
}
