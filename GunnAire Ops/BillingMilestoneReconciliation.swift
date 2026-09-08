import Foundation
import CryptoKit
import SwiftData

/// A retained draft is not deleted, merged, paid or voided. This receipt records
/// an office-reviewed exclusion after the shared publisher confirms its original.
struct BillingMilestoneDraftReceipt: Codable, Equatable {
    let version: Int
    let scope: BillingDocumentScope
    let customerID: UUID
    let serviceCallID: UUID
    let milestoneID: UUID
    let originalInvoiceID: UUID
    let originalPublicationID: UUID
    let originalProviderID: String
    let draftDigest: String
    let reviewedBy: UUID
    let reviewedAt: Date
}

enum BillingMilestoneReconciliationError: LocalizedError {
    case reviewRequired, originalRequired, accessRequired

    var errorDescription: String? {
        switch self {
        case .reviewRequired:
            "This milestone draft has changed or has billing activity. Keep both records and ask accounting to review them."
        case .originalRequired:
            "First sync and review the original milestone invoice confirmed in QuickBooks. No draft or supporting file was removed."
        case .accessRequired:
            "An administrator or accounting user must review this duplicate milestone draft."
        }
    }
}

enum BillingMilestoneReconciliation {
    static let retainedMessage = "Retained duplicate draft. Use Billing Review to open the original invoice. This draft cannot be published, sent or paid; its saved details and files remain available."
    static let reviewMessage = "Milestone invoices need reconciliation. Open Billing Review from the duplicate draft and review the original before using financial totals or creating a customer statement."

    struct Projection {
        let activeInvoices: [Invoice]
        let retainedDrafts: [Invoice]
        let needsReview: Bool
    }

    static func digest(_ invoice: Invoice) throws -> String {
        func date(_ value: Date?) -> String? { value.map { String($0.timeIntervalSince1970) } }
        let values: [String?] = [invoice.id.uuidString, invoice.customer?.id.uuidString,
            invoice.customer?.quickBooksID, invoice.serviceCallID?.uuidString,
            invoice.serviceLocationID?.uuidString, invoice.siteAddress, invoice.projectMilestoneID?.uuidString,
            invoice.projectMilestoneSequence.map(String.init), invoice.projectMilestoneTitle,
            invoice.projectContractAmount.map(String.init(describing:)), invoice.projectBillingPercent.map(String.init(describing:)),
            invoice.catalogSnapshotJSON, invoice.lineItemSummary, String(invoice.amount), String(invoice.salesTaxAmount),
            invoice.workTypeRaw, invoice.status, invoice.notes, invoice.completionNotes,
            date(invoice.createdAt), date(invoice.dueDate), invoice.customerSignatureName,
            invoice.customerSignatureImageBase64, date(invoice.customerSignedAt), date(invoice.finalizedAt)]
        return SHA256.hash(data: try JSONEncoder().encode(values)).map { String(format: "%02x", $0) }.joined()
    }

    static func isUnissued(_ invoice: Invoice, payments: [Payment]) -> Bool {
        QuickBooksBillingIdentity.identifier(invoice.quickBooksID) == nil &&
        invoice.quickBooksBalanceDue == nil && invoice.quickBooksLastSyncedAt == nil &&
        invoice.quickBooksSyncState == "pending" && invoice.normalizedStatus == "unpaid" &&
        invoice.customerSignedAt == nil && invoice.customerSignatureName == nil &&
        invoice.customerSignatureImageBase64 == nil && invoice.finalizedAt == nil &&
        invoice.payments.isEmpty && !payments.contains { $0.invoice?.id == invoice.id }
    }

    static func receipt(_ invoice: Invoice) -> BillingMilestoneDraftReceipt? {
        guard let raw = invoice.milestoneDraftReceiptJSON, raw.utf8.count < 16_384,
              let value = try? JSONDecoder().decode(BillingMilestoneDraftReceipt.self, from: Data(raw.utf8)),
              value.version == 1, value.scope.documentType == .invoice,
              value.scope.localDocumentID == invoice.id, value.customerID == invoice.customer?.id,
              value.serviceCallID == invoice.serviceCallID, value.milestoneID == invoice.projectMilestoneID,
              value.originalInvoiceID != invoice.id, !value.scope.realmID.isEmpty,
              ["sandbox", "production"].contains(value.scope.environment),
              QuickBooksBillingIdentity.identifier(value.originalProviderID) == value.originalProviderID,
              value.draftDigest == (try? digest(invoice)), value.reviewedAt.timeIntervalSince1970.isFinite else { return nil }
        return value
    }

    static func original(for draft: Invoice, in invoices: [Invoice], payments: [Payment]) -> Invoice? {
        // Ordinary invoices have no receipt. Do not scan their payment history
        // on every dashboard/report row just to establish that fact.
        guard let receipt = receipt(draft), isUnissued(draft, payments: payments) else { return nil }
        let matches = invoices.filter { $0.id == receipt.originalInvoiceID }
        guard matches.count == 1, let original = matches.first,
              original.customer === draft.customer, original.customer?.id == receipt.customerID,
              original.serviceCallID == receipt.serviceCallID, original.projectMilestoneID == receipt.milestoneID,
              original.milestoneDraftReceiptJSON == nil,
              QuickBooksBillingIdentity.identifier(original.quickBooksID) == receipt.originalProviderID,
              original.quickBooksIdentityReviewMessage == nil else { return nil }
        return original
    }

    static func project(_ invoices: [Invoice], payments: [Payment]) -> Projection {
        let retained = invoices.filter { original(for: $0, in: invoices, payments: payments) != nil }
        let retainedObjects = Set(retained.map(ObjectIdentifier.init))
        let active = invoices.filter { !retainedObjects.contains(ObjectIdentifier($0)) }
        let groups = Dictionary(grouping: active.filter { $0.projectMilestoneID != nil }, by: { $0.projectMilestoneID! })
        let conflict = groups.values.contains { group in
            Set(group.map(\.id)).count > 1 || Set(group.map { $0.customer?.id }).count > 1 ||
            Set(group.map(\.serviceCallID)).count > 1
        }
        return .init(activeInvoices: active, retainedDrafts: retained,
            needsReview: conflict || active.contains { $0.milestoneDraftReceiptJSON != nil })
    }

    /// Follow the reviewed original for a job's billing and collection actions,
    /// while preserving the historical job link and the unused draft's files.
    /// An incomplete receipt remains visible as a blocked draft, never as an
    /// absent invoice that would invite the user to create another one.
    static func linkedInvoice(for call: ServiceCall, in invoices: [Invoice], payments: [Payment]) -> Invoice? {
        guard let id = call.linkedInvoiceID, let customer = call.customer else { return nil }
        let matches = invoices.filter { $0.id == id }
        guard matches.count == 1, let stored = matches.first,
              stored.customer === customer,
              stored.serviceCallID == nil || stored.serviceCallID == call.id else { return nil }
        return original(for: stored, in: invoices, payments: payments) ?? stored
    }

    /// Legacy documentation may predate the stored job link. Resolve only an
    /// exact, unique invoice for that customer and job; never guess by amount
    /// or bypass a present but unresolved historical link.
    static func documentationInvoice(for call: ServiceCall, in invoices: [Invoice], payments: [Payment]) -> Invoice? {
        if call.linkedInvoiceID != nil { return linkedInvoice(for: call, in: invoices, payments: payments) }
        guard let customer = call.customer else { return nil }
        let matches = project(invoices, payments: payments).activeInvoices.filter {
            $0.customer === customer && $0.serviceCallID == call.id
        }
        return matches.count == 1 ? matches.first : nil
    }

    @MainActor static func save(draft: Invoice, original: Invoice, evidence: BillingMilestoneOriginal,
                     publication: BillingOriginalProposal, scope: BillingDocumentScope,
                     reviewer: AppUser, context: ModelContext, check: () throws -> Void,
                     persist: () throws -> Void) throws {
        try check()
        guard reviewer.isActive, [.admin, .accounting].contains(reviewer.role) else {
            throw BillingMilestoneReconciliationError.accessRequired
        }
        let invoices = try context.fetch(FetchDescriptor<Invoice>())
        let payments = try context.fetch(FetchDescriptor<Payment>())
        guard draft.milestoneDraftReceiptJSON == nil, isUnissued(draft, payments: payments),
              invoices.filter({ $0.id == draft.id }).count == 1,
              invoices.filter({ $0.id == original.id }).count == 1,
              invoices.contains(where: { $0 === draft }), invoices.contains(where: { $0 === original }),
              draft.id != original.id, draft.customer === original.customer,
              let customerID = draft.customer?.id, let jobID = draft.serviceCallID,
              let milestoneID = draft.projectMilestoneID, original.serviceCallID == jobID,
              original.projectMilestoneID == milestoneID, original.milestoneDraftReceiptJSON == nil,
              scope.documentType == .invoice, scope.localDocumentID == draft.id,
              evidence.localCustomerID == customerID, evidence.localDocumentID == original.id,
              evidence.projectMilestoneID == milestoneID, evidence.state == .confirmed,
              evidence.publicationID == publication.publication.id,
              publication.publication.state == .confirmed,
              let providerID = publication.publication.providerID,
              QuickBooksBillingIdentity.identifier(original.quickBooksID) == providerID,
              original.quickBooksReconciliationReviewMessage == nil,
              publication.proposal.localCustomerID == customerID, publication.proposal.serviceCallID == jobID,
              (try publication.proposal.projectMilestoneID ?? BillingMilestoneIdentity.reference(in: publication.proposal.document.PrivateNote)) == milestoneID else {
            throw BillingMilestoneReconciliationError.reviewRequired
        }
        let originalScope = BillingDocumentScope(companyID: scope.companyID, realmID: scope.realmID,
            environment: scope.environment, documentType: .invoice, localDocumentID: original.id)
        try publication.publication.validate(originalScope, customerID: customerID)
        guard publication.proposal.scope == originalScope else { throw BillingMilestoneReconciliationError.originalRequired }
        let value = BillingMilestoneDraftReceipt(version: 1, scope: scope, customerID: customerID,
            serviceCallID: jobID, milestoneID: milestoneID, originalInvoiceID: original.id,
            originalPublicationID: evidence.publicationID, originalProviderID: providerID,
            draftDigest: try digest(draft), reviewedBy: reviewer.id, reviewedAt: Date())
        let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try check()
        draft.milestoneDraftReceiptJSON = encoded
        do { try persist() }
        catch {
            // Restore only our field, not unrelated edits in the shared context.
            draft.milestoneDraftReceiptJSON = nil
            throw error
        }
    }
}
