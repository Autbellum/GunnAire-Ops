import Foundation
import SwiftData

/// Retains the original customer and workspace through provider delivery and
/// local confirmation. Recovery never writes customer contact fields.
@MainActor
final class CustomerPublicationWorkflow {
    let workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow
    let draft: QuickBooksCustomerCreateDraft
    private let customer: Customer
    private let context: ModelContext
    private let api: QuickBooksDataAPI
    private let access: () throws -> Void
    private let save: (ModelContext) throws -> Void
    private var expectedID: String?
    private var cancelled = false
    private var busy = false

    init(customer: Customer, context: ModelContext, api: QuickBooksDataAPI,
         validateAccess: (() throws -> Void)? = nil,
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        let access = validateAccess ?? { try QuickBooksSyncAccessPolicy.validate(context: context) }
        try access()
        guard try context.fetch(FetchDescriptor<Customer>()).contains(where: { $0 === customer }) else {
            throw QuickBooksBillingWorkflowError.changed
        }
        self.customer = customer; self.context = context; self.api = api; self.access = access; self.save = save
        draft = QuickBooksCustomerCreateOperation.draft(for: customer)
        expectedID = customer.quickBooksID
        workflow = try api.captureWorkspaceWorkflow()
        try check()
    }

    func cancel() { cancelled = true }

    func check() throws {
        guard !cancelled else { throw CancellationError() }
        try workflow.check()
        try access()
        let records = try context.fetch(FetchDescriptor<Customer>()).filter { $0.id == draft.localCustomerID }
        guard records.count == 1, records.first === customer,
              QuickBooksCustomerCreateOperation.draft(for: customer) == draft, customer.quickBooksID == expectedID else {
            throw QuickBooksBillingWorkflowError.changed
        }
    }

    func publish() async throws {
        guard !busy else { throw QuickBooksBillingWorkflowError.busy }
        busy = true
        defer { busy = false }
        try check()
        let remote: QuickBooksCustomer = try await workflow.perform { _ in
            try await withCheckedThrowingContinuation { continuation in
                api.recoverOrCreateCustomer(draft) { continuation.resume(with: $0) }
            }
        }
        try apply(remote)
    }

    func recover(_ id: UUID, transport: (UUID) async throws -> CustomerPublicationResponse) async throws {
        guard !busy else { throw QuickBooksBillingWorkflowError.busy }
        busy = true
        defer { busy = false }
        try check()
        let request = try CustomerPublicationBoundary.request(workflow: workflow, draft: draft)
        let response = try await workflow.perform { _ in try await transport(id) }
        try check()
        try response.validate(companyID: request.companyID, realmID: request.realmID,
                              environment: request.environment, customerID: request.localCustomerID)
        guard response.publication.id == id else { throw CustomerPublicationError.invalidResponse }
        try apply(response.customer)
    }

    private func apply(_ remote: QuickBooksCustomer) throws {
        try check()
        guard expectedID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false || expectedID == remote.Id,
              try QuickBooksCustomerCreateOperation.matchingRemoteCustomer(for: draft, in: [remote]) != nil,
              try !context.fetch(FetchDescriptor<Customer>()).contains(where: { $0 !== customer && $0.quickBooksID == remote.Id }) else {
            throw QuickBooksBillingWorkflowError.customerConflict
        }
        customer.quickBooksID = remote.Id
        do { try save(context) }
        catch {
            customer.quickBooksID = expectedID
            throw QuickBooksBillingWorkflowError.saveFailed
        }
        expectedID = remote.Id
    }
}
