import Foundation
import SwiftData

/// One reviewed message, original business/provider identity and send attempt.
/// A response timeout never becomes permission to send this instance again.
@MainActor
final class GmailSendWorkflow {
    let message: GmailOutgoingMessage
    let business: GmailBusinessContext?
    let messageID: String
    private let journal: GmailDraftSession?
    private let auth: GoogleAuthManager
    private let context: ModelContext
    private let sender: String
    private let provider: WorkspaceProviderOperation
    private let access: () throws -> Void
    private let save: (ModelContext) throws -> Void
    private var baseline: [String] = []
    private var sourceLease: GmailDraftSourceLease?
    private var communications: [CustomerCommunication] = []
    private var running = false
    private var outcome: GmailSendOutcome?

    private lazy var operation = WorkspaceProviderOperation(parent: provider,
        beforeTransport: { [weak self] in
            guard let self else { throw GmailDraftError.businessChanged }
            try await self.checkAsync()
        }, transportFence: { [weak self] in
            guard let self else { throw GmailDraftError.businessChanged }
            try self.check()
            try self.sourceLease?.checkTransportPermit(context: self.context)
        }, isCurrent: { [weak self] in
            guard let self else { return false }
            return (try? self.checkRecordsAndAccess()) != nil
        })

    static func prepare(auth: GoogleAuthManager, context: ModelContext, message: GmailOutgoingMessage,
                        business: GmailBusinessContext? = nil, provider: WorkspaceProviderOperation? = nil,
                        validateAccess: (() throws -> Void)? = nil, journal: GmailDraftSession? = nil,
                        sourceSnapshot: [String]? = nil,
                        save: @escaping (ModelContext) throws -> Void = { try $0.save() }) async throws -> GmailSendWorkflow {
        let retainedProvider = try provider ?? auth.captureProviderOperation()
        try retainedProvider.check()
        guard retainedProvider.serverMail == nil || business == nil else { throw GmailComposeError.access }
        let sender = AppAccess.normalizedEmail(retainedProvider.serverMail?.scope.company.actorEmail ?? auth.signedInEmail)
        let access = validateAccess ?? { try requireAccess(context: context, business: business, sender: sender) }
        try access()
        let lease: GmailDraftSourceLease?
        if let business {
            lease = try await GmailDraftSourceLease.prepare(business: business, context: context)
        } else { lease = nil }
        try retainedProvider.check(); try access()
        return try GmailSendWorkflow(auth: auth, context: context, message: message, business: business,
            provider: retainedProvider, validateAccess: access, journal: journal, sourceSnapshot: sourceSnapshot,
            preparedSourceLease: lease, save: save)
    }

    init(auth: GoogleAuthManager, context: ModelContext, message: GmailOutgoingMessage,
         business: GmailBusinessContext? = nil, provider: WorkspaceProviderOperation? = nil,
         validateAccess: (() throws -> Void)? = nil,
         journal: GmailDraftSession? = nil,
         sourceSnapshot: [String]? = nil,
         preparedSourceLease: GmailDraftSourceLease? = nil,
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        self.auth = auth; self.context = context; self.message = message; self.business = business
        sender = AppAccess.normalizedEmail(provider?.serverMail?.scope.company.actorEmail ?? auth.signedInEmail)
        let capturedProvider = try provider ?? auth.captureProviderOperation()
        self.provider = capturedProvider
        self.save = save
        let retainedSender = sender
        let accessCheck = validateAccess ?? { try Self.requireAccess(context: context, business: business, sender: retainedSender) }
        access = accessCheck
        try capturedProvider.check()
        try accessCheck()
        guard capturedProvider.serverMail == nil || business == nil else { throw GmailComposeError.access }
        var preparedState: [String] = []
        let preparedLease: GmailDraftSourceLease?
        if let business {
            let validate: () throws -> Void = {
                do {
                    preparedState = try Self.recordState(message: message, business: business, context: context)
                } catch GmailComposeError.changed {
                    if sourceSnapshot != nil || journal != nil { throw GmailDraftError.businessChanged }
                    throw GmailComposeError.changed
                }
            }
            if let preparedSourceLease {
                try validate(); try preparedSourceLease.check(context: context)
                preparedLease = preparedSourceLease
            } else {
                preparedLease = try GmailDraftSourceLease(business: business, context: context, validatePreparation: validate)
            }
        } else {
            preparedLease = nil
            preparedState = try Self.recordState(message: message, business: business, context: context)
        }
        if let sourceSnapshot {
            guard sourceSnapshot == preparedLease?.snapshot else { throw GmailDraftError.businessChanged }
        }
        if let journal {
            self.journal = journal
        } else if !GunnAireCloudKit.usesTestDatabase {
            let scope = try GmailDraftScope.capture(auth: auth, context: context)
            let content = GmailDraftContent(to: message.to, subject: message.subject, body: message.body,
                files: message.attachments.map { GmailDraftFile($0) }, reply: message.reply,
                business: business, requiresBusinessContext: business != nil,
                businessSnapshot: preparedLease?.snapshot)
            self.journal = try GmailDraftSession(record: .init(id: UUID(), scope: scope, content: content), store: .device) {
                guard try GmailDraftScope.capture(auth: auth, context: context) == scope else { throw GmailDraftError.access }
                try Self.requireAccess(context: context, business: business, sender: auth.signedInEmail)
            }
        } else { self.journal = nil }
        if let server = self.provider.serverMail {
            guard business == nil, let journal = self.journal else { throw GmailComposeError.access }
            try journal.prepareServerAttempt(scope: server.scope)
        }
        messageID = self.journal?.record.messageID ?? "<gunnaire-\(UUID().uuidString.lowercased())@gunnaire.com>"
        try self.provider.check()
        try access()
        try preparedLease?.check(context: context)
        if let journal = self.journal {
            try journal.verify()
            guard journal.record.scope.googleEmail == sender else { throw GmailDraftError.access }
            if !GunnAireCloudKit.usesTestDatabase {
                let scope = try self.provider.serverMail == nil ? GmailDraftScope.capture(auth: auth, context: context)
                    : GmailDraftScope.captureCompany(context: context)
                guard journal.record.scope == scope else { throw GmailDraftError.access }
            }
            let saved = journal.record.content
            guard journal.record.editable, saved.to == message.to, saved.subject == message.subject,
                  saved.body == message.body, saved.files == message.attachments.map({ GmailDraftFile($0) }),
                  saved.reply == message.reply, saved.business == business,
                  saved.attachmentError == nil, !saved.requiresBusinessContext || business != nil else { throw GmailDraftError.changed }
            guard saved.businessSnapshot == preparedLease?.snapshot else { throw GmailDraftError.businessChanged }
        }
        sourceLease = preparedLease
        baseline = preparedState
    }

    func send() async -> GmailSendOutcome {
        if let outcome { return outcome }
        guard !running else { return .notSent(GmailComposeError.busy) }
        running = true
        defer { running = false }
        var receivedSendResponse = false
        do {
            try await checkAsync()
            try checkClassified()
            let customers = try matchingCustomers()
            let consentAllowed = customers.allSatisfy {
                business?.workflow.requiresMarketingConsent == true ? $0.allowsMarketing : $0.allowsTransactionalEmail
            }
            do {
                try await saveHistoryPreservingSource {
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
                }
            }
            catch {
                // Only undo unsaved insertions while their original access is
                // still valid. A persisted pending row remains audit evidence.
                if (try? provider.check()) != nil, (try? access()) != nil {
                    let inserted = context.insertedModelsArray
                    for record in communications where inserted.contains(where: { $0 === record }) {
                        context.delete(record)
                    }
                }
                communications = []
                throw GmailComposeError.save
            }
            try await checkAsync()
            try checkClassified()
            if !consentAllowed {
                let result = GmailSendOutcome.notSent(GmailComposeError.consent)
                outcome = result
                synchronizeHistory()
                return result
            }
            try journal?.begin()
            let sent: GmailMessageReference
            if let server = operation.serverMail {
                guard business == nil, let attempt = journal?.record.serverAttempt, attempt.scope == server.scope else { throw GmailComposeError.access }
                let response = try await server.send(id: attempt.id, message: GmailServerMessage(message), operation: operation)
                if response.state == .rejected || response.state == .cancelled { throw GmailServerMailError.rejected }
                guard response.state == .confirmed, let id = response.messageID, let thread = response.threadID else { throw GmailServerMailError.pending }
                sent = .init(id: id, threadId: thread)
            } else {
                sent = try await withCheckedThrowingContinuation { continuation in
                    auth.sendGmailMessage(to: message.to, subject: message.subject, body: message.body,
                        threadID: message.reply?.threadID, attachments: message.attachments,
                        reply: message.reply, messageID: messageID, operation: operation) {
                            continuation.resume(with: $0)
                        }
                    }
            }
            receivedSendResponse = true
            try await checkAsync()
            try checkClassified()
            guard GoogleAuthManager.calendarPathComponent(sent.id) != nil,
                  GoogleAuthManager.calendarPathComponent(sent.threadId) != nil else {
                throw GoogleAuthError.decoding
            }
            let confirmed: GmailMessageDetail = try await withCheckedThrowingContinuation { continuation in
                auth.fetchGmailMessage(id: sent.id, operation: operation) { continuation.resume(with: $0) }
            }
            try await checkAsync()
            try checkClassified()
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
            do {
                try await saveHistoryPreservingSource(sourceTransition: true) {
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
                }
                try checkClassified()
                baseline = try recordState()
            } catch {
                let result = GmailSendOutcome(state: .reviewRequired,
                    message: "Gmail accepted the message, but its local history could not be saved. Do not send another copy. Review customer history and Gmail Sent.")
                outcome = result
                try? journal?.finish(result)
                return result
            }
            let result = GmailSendOutcome(state: .sent, message: "Message saved in Gmail Sent.")
            do { try journal?.finish(result) }
            catch {
                let retained = GmailSendOutcome(state: .reviewRequired,
                    message: "Gmail accepted the message, but its saved draft needs review. Do not send another copy. Open Sent to check the original message.")
                outcome = retained
                return retained
            }
            outcome = result
            synchronizeHistory()
            return result
        } catch {
            let rejected: Bool
            if case GoogleAuthError.http(let code) = error {
                // A failed verification GET cannot undo an accepted POST or
                // authorize another copy of a possibly sent customer message.
                rejected = !receivedSendResponse && [400, 401, 403, 404, 413, 422].contains(code)
            } else { rejected = !receivedSendResponse && (error as? GmailServerMailError) == .rejected }
            let result: GmailSendOutcome = operation.mayHaveReachedProvider && !rejected
                ? .uncertain : .notSent(error)
            // Never attach a late result to another workspace or changed job.
            if (try? await checkAsync()) != nil, (try? checkClassified()) != nil {
                for record in communications {
                    record.deliveryStatus = result.canRetry ? "failed" : "unconfirmed"
                    record.providerStatusDetail = result.message
                }
                if !communications.isEmpty { try? save(context) }
            }
            if journal?.record.state == .sending {
                do { try journal?.finish(result) }
                catch {
                    outcome = .uncertain
                    return .uncertain
                }
            }
            outcome = result
            return result
        }
    }

    private func checkAsync() async throws {
        for attempt in 0..<2 {
            try check()
            try await sourceLease?.validateHistory(context: context)
            try check()
            do { try sourceLease?.checkTransportPermit(context: context); return }
            catch { if attempt == 1 { throw error } }
        }
    }

    private func checkClassified() throws {
        try check()
        try sourceLease?.checkTransportPermit(context: context)
    }

    private func check() throws {
        try provider.check()
        try checkRecordsAndAccess()
        try Task.checkCancellation()
    }

    private func checkRecordsAndAccess() throws {
        try access()
        if business != nil {
            guard let sourceLease else { throw GmailDraftError.businessChanged }
            try sourceLease.check(context: context)
            // External saves/imports expire the lease; unsaved deletion/changes
            // fail its clean-context check before retained models are touched.
            guard communications.allSatisfy({ record in
                guard record.modelContext === context, !record.isDeleted else { return false }
                let registered: CustomerCommunication? = context.registeredModel(for: record.persistentModelID)
                return registered === record
            }) else { throw GmailComposeError.changed }
        } else {
            guard try recordState() == baseline else { throw GmailComposeError.changed }
            let current = try context.fetch(FetchDescriptor<CustomerCommunication>())
            guard communications.allSatisfy({ retained in current.contains { $0 === retained } }) else {
                throw GmailComposeError.changed
            }
        }
    }

    private func saveHistoryPreservingSource(sourceTransition: Bool = false,
                                            _ mutation: () throws -> Void = {}) async throws {
        guard let business, let original = sourceLease else {
            try mutation()
            if !communications.isEmpty { try save(context) }
            return
        }
        var expectedState = baseline
        var expectedSnapshot = original.snapshot
        let replacement = try await original.replacingAfterHistoryWrite(business: business, context: context,
            expectedSnapshot: { expectedSnapshot }, beforeWrite: { try check() }, validatePreparation: {
                try provider.check()
                try access()
                guard try recordState() == expectedState else { throw GmailComposeError.changed }
            }, write: {
                try mutation()
                if sourceTransition {
                    // Capture the intended operational transition before the
                    // save hook can mutate consent, recipient or source data.
                    expectedState = try recordState()
                    expectedSnapshot = try GmailDraftBusinessSnapshot.capture(business, context: context)
                }
                let touched = context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray
                if !communications.isEmpty { try save(context) }
                return Set(touched.map(\.persistentModelID))
            })
        try provider.check()
        try access()
        try replacement.checkTransportPermit(context: context)
        guard try recordState() == expectedState else { throw GmailComposeError.changed }
        sourceLease = replacement
    }

    private func matchingCustomers() throws -> [Customer] {
        try Self.matchingCustomers(message: message, business: business, context: context)
    }

    private static func matchingCustomers(message: GmailOutgoingMessage, business: GmailBusinessContext?, context: ModelContext) throws -> [Customer] {
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
        try Self.recordState(message: message, business: business, context: context)
    }

    private static func recordState(message: GmailOutgoingMessage, business: GmailBusinessContext?, context: ModelContext) throws -> [String] {
        let customers = try matchingCustomers(message: message, business: business, context: context)
        var state = customers.flatMap {
            [String(describing: ObjectIdentifier($0)), $0.id.uuidString, $0.name, $0.email ?? "",
             $0.address ?? "", String($0.allowsTransactionalEmail), String($0.allowsMarketing),
             $0.communicationConsentUpdatedAt?.description ?? ""]
        }
        guard let business else { return state }
        let calls = try business.serviceCallID.map { id in
            try context.fetch(FetchDescriptor<ServiceCall>(predicate: #Predicate { $0.id == id }))
        } ?? []
        let invoices: [Invoice]
        if let id = business.invoiceID {
            invoices = try context.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == id }))
        } else if business.workflow == .accountStatement {
            let customerID = business.customerID
            var descriptor = FetchDescriptor<Invoice>(predicate: #Predicate { $0.customer?.id == customerID })
            descriptor.fetchLimit = 1
            invoices = try context.fetch(descriptor)
        } else { invoices = [] }
        let estimates = try business.estimateID.map { id in
            try context.fetch(FetchDescriptor<Estimate>(predicate: #Predicate { $0.id == id }))
        } ?? []
        let contracts = try business.maintenanceContractID.map { id in
            try context.fetch(FetchDescriptor<RecurringMaintenanceContract>(predicate: #Predicate { $0.id == id }))
        } ?? []
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

    static func requireAccess(context: ModelContext, business: GmailBusinessContext?, sender: String?) throws {
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
                    try await checkAsync()
                    try checkClassified()
                    let payload = GunnAireBackendService.communicationPayload(for: record)
                    let remote = try await GunnAireBackendService.uploadCustomerCommunication(payload: payload,
                        originatingOperation: operation)
                    try await checkAsync()
                    try checkClassified()
                    try await saveHistoryPreservingSource { record.markSharedCompanySynced(id: remote.id) }
                } catch {
                    guard (try? await checkAsync()) != nil, (try? checkClassified()) != nil else { return }
                    try? await saveHistoryPreservingSource {
                        record.markSharedCompanySyncFailed("Company email history needs another sync attempt.")
                    }
                }
            }
        }
    }
}
