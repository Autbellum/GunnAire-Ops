import Foundation
import SwiftData

@MainActor struct FieldFormDraftWorkflow {
    let context: ModelContext
    let scope: FieldFormDraftScope
    let store: FieldFormDraftStore
    let authorize: () throws -> Void

    static func live(context: ModelContext, actorEmail: String?) throws -> Self {
        let scope = try captureScope(context: context, actorEmail: actorEmail)
        var store = FieldFormDraftStore.device
        #if DEBUG
        if let name = fixtureStoreName {
            store = .encrypted(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("FieldFormDraftFixture-" + name)) { _ in Data(repeating: 83, count: 32) }
            if ProcessInfo.processInfo.arguments.contains("-uiTestFieldFormAcknowledgementFailure") {
                let durable = store
                store = .init(read: durable.read, write: { record, expected in
                    if record.state == .completed { throw FieldFormDraftError.storage }
                    try durable.write(record, expected)
                }, list: durable.list)
            }
        }
        #endif
        return Self(context: context, scope: scope, store: store) {
            guard try captureScope(context: context, actorEmail: actorEmail) == scope else { throw FieldFormDraftError.access }
        }
    }

    static func captureScope(context: ModelContext, actorEmail: String?) throws -> FieldFormDraftScope {
        let controller = CompanyWorkspaceAccessController.shared
        guard controller.authorizedContainer === context.container,
              AppAccess.normalizedEmail(actorEmail) == AppAccess.normalizedEmail(AppIdentity.currentEmail) else {
            throw FieldFormDraftError.access
        }
        #if DEBUG
        if let name = fixtureStoreName {
            let scope = FieldFormDraftScope(companyID: UUID(uuidString: "F0F00000-0000-4000-8000-000000000100")!,
                backendOrigin: "https://fixture.example.invalid", actorEmail: AppAccess.normalizedEmail(actorEmail), storeID: name)
            try scope.validate(); return scope
        }
        #endif
        guard let company = controller.verifiedCompanyID, let session = CompanyWorkspaceSession.current,
              context.container.configurations.count == 1,
              let url = context.container.configurations.first?.url,
              let identity = try CompanyWorkspaceStore.identity(at: url) else { throw FieldFormDraftError.access }
        let scope = FieldFormDraftScope(companyID: company, backendOrigin: session.backendOrigin,
                                       actorEmail: session.email, storeID: identity)
        try scope.validate(); return scope
    }

    #if DEBUG
    static var fixtureStoreName: String? {
        let args = ProcessInfo.processInfo.arguments
        guard GunnAireCloudKit.usesTestDatabase, args.contains("-uiTestFieldFormDrafts"),
              args.contains("-uiTestSeedCollectibleJob"),
              args.contains("-uiTestAuthenticatedAdmin") || args.contains("-uiTestAuthenticatedTechnician") else { return nil }
        return GunnAireCloudKit.isolatedUITestStoreName(arguments: args)
    }
    #endif

    func requireJob(_ id: UUID, in source: ModelContext? = nil) throws -> ServiceCall {
        try authorize(); try scope.validate()
        let source = source ?? context
        let jobs = try source.fetch(FetchDescriptor<ServiceCall>()).filter { !$0.isDeleted }
        let matching = jobs.filter { $0.id == id }
        guard matching.count == 1, let customer = matching[0].customer, !customer.isDeleted,
              try source.fetch(FetchDescriptor<Customer>()).filter({ $0.id == customer.id && !$0.isDeleted }).count == 1 else {
            throw FieldFormDraftError.access
        }
        let users = try source.fetch(FetchDescriptor<AppUser>())
        let technicians = try source.fetch(FetchDescriptor<Technician>())
        guard AppAccess.canUpdateJobProgress(email: scope.actorEmail, users: users),
              AppAccess.canAccessServiceCall(matching[0], email: scope.actorEmail, users: users,
                                            serviceCalls: jobs, technicians: technicians) else { throw FieldFormDraftError.access }
        return matching[0]
    }

    private func currentTemplate(_ id: UUID, job: ServiceCall, in source: ModelContext) throws -> FieldFormTemplate {
        let rows = try source.fetch(FetchDescriptor<FieldFormTemplate>()).filter { $0.id == id && !$0.isDeleted }
        guard rows.count == 1, rows[0].isActive, rows[0].isListed(for: job.type),
              rows[0].dataReviewIssue == nil, job.status != .cancelled else { throw FieldFormDraftError.contextChanged }
        return rows[0]
    }

    static func content(template: FieldFormTemplate, job: ServiceCall) throws -> FieldFormDraftContent {
        guard let customer = job.customer else { throw FieldFormDraftError.contextChanged }
        let content = FieldFormDraftContent(title: template.title, questions: template.questions,
            job: .init(customerID: customer.id, customerName: customer.name, siteAddress: job.siteAddress ?? customer.address ?? "",
                workType: job.type.rawValue, serviceLocationID: job.serviceLocationID, equipmentID: job.customerEquipmentID,
                equipment: [job.equipmentName, job.equipmentManufacturer, job.equipmentModel,
                            job.equipmentSerialNumber, job.equipmentLocation],
                invoiceID: job.linkedInvoiceID, estimateID: job.linkedEstimateID))
        try content.validate(); return content
    }

    func open(jobID: UUID, templateID: UUID, startAnother: Bool = false) throws -> FieldFormDraftSession {
        let job = try requireJob(jobID)
        let slot = FieldFormDraftSlot(scope: scope, jobID: jobID, templateID: templateID)
        let previous = try store.read(slot)
        let record: FieldFormDraftRecord
        if let previous, previous.state != .discarded, !startAnother {
            record = previous
        } else {
            guard previous == nil || [.completed, .discarded].contains(previous!.state) else { throw FieldFormDraftError.locked }
            let template = try currentTemplate(templateID, job: job, in: context)
            record = FieldFormDraftRecord(slot: slot, content: try Self.content(template: template, job: job),
                                          revision: previous.map { $0.revision + 1 } ?? 0)
            try store.write(record, previous?.revision)
        }
        return try FieldFormDraftSession(record: record, store: store) { _ = try requireJob(jobID) }
    }

    func drafts(jobID: UUID) throws -> [FieldFormDraftRecord] {
        _ = try requireJob(jobID)
        return try store.list(scope, jobID)
    }

    func verifyContext(_ record: FieldFormDraftRecord, in source: ModelContext? = nil) throws {
        guard record.slot.scope == scope, let original = record.content else { throw FieldFormDraftError.access }
        let source = source ?? context
        let job = try requireJob(record.slot.jobID, in: source)
        let template = try currentTemplate(record.slot.templateID, job: job, in: source)
        var current = try Self.content(template: template, job: job)
        current.answers = original.answers
        guard current == original else { throw FieldFormDraftError.contextChanged }
    }

    /// Only exact original identifiers and immutable answers can acknowledge an
    /// interrupted save. Partial/deleted/conflicting records never mean "retry
    /// with a new ID". The complete response and linked file share one database
    /// transaction; the private draft is not counted for job closeout.
    func savedResult(_ record: FieldFormDraftRecord, in source: ModelContext) throws -> ServiceDocumentAttachment? {
        let job = try requireJob(record.slot.jobID, in: source)
        guard record.slot.scope == scope, let content = record.content, let completedAt = record.completedAt else {
            throw FieldFormDraftError.completionReview
        }
        guard job.customer?.id == content.job.customerID else { throw FieldFormDraftError.completionReview }
        let responses = try source.fetch(FetchDescriptor<FieldFormResponse>()).filter { $0.id == record.id }
        let files = try source.fetch(FetchDescriptor<ServiceDocumentAttachment>()).filter { $0.id == record.attachmentID }
        let activities = try source.fetch(FetchDescriptor<ServiceCallActivity>()).filter { $0.id == record.activityID }
        if responses.isEmpty && files.isEmpty && activities.isEmpty && record.state == .completing { return nil }
        guard responses.count == 1, files.count == 1, activities.count == 1 else { throw FieldFormDraftError.completionReview }
        let response = responses[0], attachment = files[0]
        guard response.serviceCallID == record.slot.jobID, response.templateID == record.slot.templateID,
              response.templateTitle == content.title, response.completedAt == completedAt,
              response.completedByEmail == scope.actorEmail,
              response.snapshotAnswerRows == FieldFormCompletionPolicy.answerRows(questions: content.questions, answers: content.answers),
              response.completionReviewIssue(resolving: nil) == nil,
              attachment.serviceCallID == record.slot.jobID, attachment.customer?.id == content.job.customerID,
              attachment.invoiceID == content.job.invoiceID, attachment.estimateID == content.job.estimateID,
              attachment.kind == .customerDocument, attachment.contentType == "application/pdf",
              attachment.caption == "Completed field form: \(content.title) [FieldFormResponse:\(record.id.uuidString)]",
              activities[0].serviceCallID == record.slot.jobID, activities[0].actorEmail == scope.actorEmail,
              activities[0].occurredAt == completedAt, activities[0].action == "Field form completed",
              activities[0].detail == "Completed \(content.title); saved a PDF in job Files." else {
            throw FieldFormDraftError.completionReview
        }
        return attachment
    }

    func verifyFileLineage(job: ServiceCall, in source: ModelContext) throws {
        guard let customer = job.customer else { throw FieldFormDraftError.fileLinkReview }
        if let id = job.serviceLocationID {
            let rows = try source.fetch(FetchDescriptor<CustomerServiceLocation>()).filter { $0.id == id }
            guard rows.count == 1, rows[0].customer === customer else { throw FieldFormDraftError.fileLinkReview }
        }
        if let id = job.customerEquipmentID {
            let rows = try source.fetch(FetchDescriptor<CustomerEquipment>()).filter { $0.id == id }
            guard rows.count == 1, rows[0].customer === customer,
                  rows[0].serviceLocationID == nil || job.serviceLocationID == nil || rows[0].serviceLocationID == job.serviceLocationID else {
                throw FieldFormDraftError.fileLinkReview
            }
        }
        if let id = job.linkedInvoiceID {
            let rows = try source.fetch(FetchDescriptor<Invoice>())
            guard let invoice = JobBillingDocumentLinks.invoice(id: id, in: rows), invoice.customer === customer,
                  invoice.serviceCallID == nil || invoice.serviceCallID == job.id else { throw FieldFormDraftError.fileLinkReview }
        }
        if let id = job.linkedEstimateID {
            let rows = try source.fetch(FetchDescriptor<Estimate>())
            guard let estimate = JobBillingDocumentLinks.estimate(id: id, in: rows), estimate.customer === customer,
                  EstimateJobLineage.matches(jobID: job.id, diagnosticJobID: estimate.serviceCallID,
                                            scheduledJobID: estimate.scheduledServiceCallID) else { throw FieldFormDraftError.fileLinkReview }
        }
    }

    struct Completion {
        let context: ModelContext
        let attachment: ServiceDocumentAttachment
        let newFileData: Data?
        let record: FieldFormDraftRecord
    }

    func complete(_ session: FieldFormDraftSession,
                  export: (@MainActor (FieldFormResponse, ServiceCall, FieldFormTemplate) throws -> URL)? = nil,
                  save: (@MainActor (ModelContext) throws -> Void)? = nil) throws -> Completion {
        try session.verify()
        guard session.record.slot.scope == scope else { throw FieldFormDraftError.access }
        // An isolated transaction never saves or rolls back another window's
        // unfinished model edits when this form encounters an error.
        let transaction = ModelContext(context.container)
        transaction.autosaveEnabled = false
        if session.record.state == .editing {
            try verifyContext(session.record); try verifyContext(session.record, in: transaction)
            try verifyFileLineage(job: requireJob(session.record.slot.jobID, in: transaction), in: transaction)
            try session.begin()
        }
        guard [.completing, .completed].contains(session.record.state) else { throw FieldFormDraftError.locked }
        if let existing = try savedResult(session.record, in: transaction) {
            if session.record.state == .completing { try session.finish() }
            return Completion(context: transaction, attachment: existing, newFileData: nil, record: session.record)
        }
        let record = session.record
        try verifyContext(record); try verifyContext(record, in: transaction)
        let job = try requireJob(record.slot.jobID, in: transaction)
        try verifyFileLineage(job: job, in: transaction)
        let template = try currentTemplate(record.slot.templateID, job: job, in: transaction)
        guard let content = record.content, let date = record.completedAt else { throw FieldFormDraftError.completionReview }
        let response = FieldFormResponse(id: record.id, serviceCallID: record.slot.jobID, template: template,
            answers: content.answers, completedByEmail: scope.actorEmail, completedAt: date)
        let url: URL
        if let export { url = try export(response, job, template) }
        else { url = try CustomerDocumentExporter.exportFieldFormResponse(response, serviceCall: job, template: template) }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw FieldFormDraftError.storage }
        let attachment = ServiceDocumentAttachment(id: record.attachmentID, customer: job.customer,
            serviceCallID: job.id, invoiceID: content.job.invoiceID, estimateID: content.job.estimateID,
            kind: .customerDocument, displayName: url.lastPathComponent,
            caption: "Completed field form: \(content.title) [FieldFormResponse:\(record.id.uuidString)]",
            localFilePath: url.path, contentType: "application/pdf", fileSizeBytes: data.count, createdAt: date)
        try session.verify(); try verifyContext(record)
        transaction.insert(response); transaction.insert(attachment)
        transaction.insert(ServiceCallActivity(id: record.activityID, serviceCallID: job.id, action: "Field form completed",
            detail: "Completed \(content.title); saved a PDF in job Files.", actorEmail: scope.actorEmail,
            occurredAt: date))
        if let save { try save(transaction) }
        else { try transaction.save() }
        // If this acknowledgement fails, the committed response/file remain.
        // A subsequent explicit retry recovers those exact IDs, not new ones.
        try session.finish()
        return Completion(context: transaction, attachment: attachment, newFileData: data, record: session.record)
    }

    /// Recovered completions do not start another upload. For a newly saved
    /// file, both success and failure callbacks require the captured workspace,
    /// current job access, original immutable records and unchanged local bytes.
    /// A late callback after logout/reassignment leaves the retained file alone.
    func syncNewFile(_ result: Completion,
                     upload: @MainActor (Data, ServiceDocumentAttachment) async throws -> String) async {
        guard let data = result.newFileData, result.attachment.backendDocumentID == nil else { return }
        func verify() throws {
            _ = try requireJob(result.record.slot.jobID)
            guard result.context.container === context.container,
                  try savedResult(result.record, in: result.context) === result.attachment,
                  result.attachment.fileSizeBytes == data.count,
                  try Data(contentsOf: result.attachment.localFileURL) == data else { throw FieldFormDraftError.completionReview }
        }
        do {
            try verify()
            let identifier = try await upload(data, result.attachment)
            try verify()
            // The existing company document endpoint returns UUID identities.
            guard UUID(uuidString: identifier) != nil else { throw FieldFormDraftError.storage }
            result.attachment.markSharedCompanyStored(id: identifier)
            try result.context.save()
        } catch {
            guard (try? verify()) != nil else { return }
            result.attachment.markSharedCompanyUploadFailed(
                "Shared upload was not confirmed. The original file is kept on this device; review Files before retrying.")
            try? result.context.save()
        }
    }
}
