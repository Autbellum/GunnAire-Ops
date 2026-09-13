import Foundation
import SwiftData

/// Preserves original sold lines, taxes, approvals, balances and receipt identity.
/// Reconstruction does not send, publish, charge, reconcile, or declare payment
/// success. These owner-side records are not yet role-filtered staff payloads.
extension StaffWorkspaceModelCodecs {
    static var invoice: StaffWorkspaceModelCodec<Invoice> {
        .init(kind: "invoice", id: \.id, fields: [
            .value("quickBooksSyncStatus", \.quickBooksSyncStatus),
            .value("workTypeRaw", \.workTypeRaw),
            .value("lineItemSummary", \.lineItemSummary),
            .value("amount", \.amount),
            .value("salesTaxAmount", \.salesTaxAmount),
            .value("status", \.status),
            .value("createdAt", \.createdAt),
            .optional("serviceCallID", \.serviceCallID),
            .optional("serviceLocationID", \.serviceLocationID),
            .optional("siteAddress", \.siteAddress),
            .optional("quickBooksID", \.quickBooksID),
            .optional("quickBooksBalanceDue", \.quickBooksBalanceDue),
            .optional("quickBooksSyncDetail", \.quickBooksSyncDetail),
            .optional("quickBooksLastSyncedAt", \.quickBooksLastSyncedAt),
            .optional("quickBooksPaymentReviewJSON", \.quickBooksPaymentReviewJSON),
            .optional("catalogSnapshotJSON", \.catalogSnapshotJSON),
            .optional("taxCalculationStatusRawValue", \.taxCalculationStatusRawValue),
            .optional("taxCalculatedAt", \.taxCalculatedAt),
            .optional("projectMilestoneID", \.projectMilestoneID),
            .optional("milestoneDraftReceiptJSON", \.milestoneDraftReceiptJSON),
            .optional("projectMilestoneSequence", \.projectMilestoneSequence),
            .optional("projectMilestoneTitle", \.projectMilestoneTitle),
            .optional("projectContractAmount", \.projectContractAmount),
            .optional("projectBillingPercent", \.projectBillingPercent),
            .optional("dueDate", \.dueDate),
            .optional("notes", \.notes),
            .optional("customerSignatureName", \.customerSignatureName),
            .optional("customerSignatureImageBase64", \.customerSignatureImageBase64),
            .optional("customerSignedAt", \.customerSignedAt),
            .optional("completionNotes", \.completionNotes),
            .optional("finalizedAt", \.finalizedAt),
            .reference("customer", \.customer, id: \Customer.id, kind: "customer", required: true),
        ], excludedAttributes: [:], inverseRelationships: ["storedPayments"], make: { record, resolver in
            return Invoice(id: record.id, customer: try resolver.parent(Customer.self, kind: "customer", field: "customer", record: record))
        })
    }
    static var estimate: StaffWorkspaceModelCodec<Estimate> {
        .init(kind: "estimate", id: \.id, fields: [
            .value("proposalIsRecommended", \.proposalIsRecommended),
            .value("lineItemSummary", \.lineItemSummary),
            .value("amount", \.amount),
            .value("salesTaxAmount", \.salesTaxAmount),
            .value("status", \.status),
            .value("createdAt", \.createdAt),
            .optional("serviceCallID", \.serviceCallID),
            .optional("serviceLocationID", \.serviceLocationID),
            .optional("siteAddress", \.siteAddress),
            .optional("scheduledServiceCallID", \.scheduledServiceCallID),
            .optional("parentEstimateID", \.parentEstimateID),
            .optional("changeOrderReason", \.changeOrderReason),
            .optional("proposalGroupID", \.proposalGroupID),
            .optional("proposalOption", \.proposalOption),
            .optional("quickBooksID", \.quickBooksID),
            .optional("catalogSnapshotJSON", \.catalogSnapshotJSON),
            .optional("taxCalculationStatusRawValue", \.taxCalculationStatusRawValue),
            .optional("taxCalculatedAt", \.taxCalculatedAt),
            .optional("customerApprovedByName", \.customerApprovedByName),
            .optional("customerApprovedAt", \.customerApprovedAt),
            .optional("customerApprovalMethodRaw", \.customerApprovalMethodRaw),
            .optional("customerApprovalReference", \.customerApprovalReference),
            .optional("customerApprovalRecordedByEmail", \.customerApprovalRecordedByEmail),
            .optional("customerApprovalSignatureImageBase64", \.customerApprovalSignatureImageBase64),
            .optional("notes", \.notes),
            .reference("customer", \.customer, id: \Customer.id, kind: "customer", required: true),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            return Estimate(id: record.id, customer: try resolver.parent(Customer.self, kind: "customer", field: "customer", record: record))
        })
    }
    static var payment: StaffWorkspaceModelCodec<Payment> {
        .init(kind: "payment", id: \.id, fields: [
            .value("amount", \.amount),
            .value("date", \.date),
            .value("method", \.method),
            .value("isRefund", \.isRefund),
            .optional("quickBooksID", \.quickBooksID),
            .optional("quickBooksChargeID", \.quickBooksChargeID),
            .optional("quickBooksClientTransID", \.quickBooksClientTransID),
            .optional("collectionAttemptID", \.collectionAttemptID),
            .optional("providerPaymentStatus", \.providerPaymentStatus),
            .optional("quickBooksRefundReceiptID", \.quickBooksRefundReceiptID),
            .optional("quickBooksDepositID", \.quickBooksDepositID),
            .optional("quickBooksSalesReceiptID", \.quickBooksSalesReceiptID),
            .optional("quickBooksAccountingSyncStatus", \.quickBooksAccountingSyncStatus),
            .optional("quickBooksAccountingSyncDetail", \.quickBooksAccountingSyncDetail),
            .optional("processorSyncStatus", \.processorSyncStatus),
            .optional("processorSyncDetail", \.processorSyncDetail),
            .optional("settlementBatchID", \.settlementBatchID),
            .optional("cardLast4", \.cardLast4),
            .optional("authorizationReference", \.authorizationReference),
            .optional("notes", \.notes),
            .optional("processor", \.processor),
            .optional("refundedPaymentID", \.refundedPaymentID),
            .reference("invoice", \.invoice, id: \Invoice.id, kind: "invoice", required: true),
        ], excludedAttributes: ["storedCardID": "Charge-capable card handle remains in the authenticated payment service, never a staff model snapshot."], inverseRelationships: [], make: { record, resolver in
            return Payment(id: record.id, invoice: try resolver.parent(Invoice.self, kind: "invoice", field: "invoice", record: record), amount: 0)
        })
    }
}
