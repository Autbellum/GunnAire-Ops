import Foundation
import SwiftData

/// Explicit owner-side values. These mappings are not staff role projections,
/// authorization, content delivery, or permission to activate a staff store.
/// `make` closures may invent empty SwiftData defaults for owner import only —
/// staff operational acceptance must never call them for restricted fields.
extension StaffWorkspaceModelCodecs {
    static var attachment: StaffWorkspaceModelCodec<ServiceDocumentAttachment> {
        .init(kind: "attachment", id: \.id, fields: [
            .value("kindRaw", \.kindRaw),
            .value("displayName", \.displayName),
            .value("contentType", \.contentType),
            .value("fileSizeBytes", \.fileSizeBytes),
            .value("createdAt", \.createdAt),
            .optional("serviceCallID", \.serviceCallID),
            .optional("customerEquipmentID", \.customerEquipmentID),
            .optional("invoiceID", \.invoiceID),
            .optional("estimateID", \.estimateID),
            .optional("maintenanceContractID", \.maintenanceContractID),
            .optional("fleetVehicleID", \.fleetVehicleID),
            .optional("fleetVehicleEventID", \.fleetVehicleEventID),
            .optional("expenseClaimID", \.expenseClaimID),
            .optional("caption", \.caption),
            .optional("backendDocumentID", \.backendDocumentID),
            .optional("sharedCompanySyncStatus", \.sharedCompanySyncStatus),
            .optional("sharedCompanySyncDetail", \.sharedCompanySyncDetail),
            .optional("quickBooksAttachableID", \.quickBooksAttachableID),
            .optional("quickBooksSyncError", \.quickBooksSyncError),
            .optional("quickBooksAttachedEntityKeysRaw", \.quickBooksAttachedEntityKeysRaw),
            .optional("googleDriveFileID", \.googleDriveFileID),
            .optional("googleDriveWebViewLink", \.googleDriveWebViewLink),
            .optional("googleDriveSyncStatus", \.googleDriveSyncStatus),
            .optional("googleDriveSyncDetail", \.googleDriveSyncDetail),
            .optional("googleDriveLastSyncedAt", \.googleDriveLastSyncedAt),
            .optional("googleDriveArchivedByEmail", \.googleDriveArchivedByEmail),
            .reference("customer", \.customer, id: \Customer.id, kind: "customer", required: false),
        ], excludedAttributes: ["localFilePath": "Device-local paths are not transferable authority. The verified content-delivery service must supply a new sandbox URL before this attachment can be opened."], inverseRelationships: [], make: { record, resolver in
            ServiceDocumentAttachment(id: record.id, customer: nil, serviceCallID: nil, kind: .other, displayName: "", localFilePath: "", contentType: "application/octet-stream", fileSizeBytes: 0)
        })
    }
    static var communication: StaffWorkspaceModelCodec<CustomerCommunication> {
        .init(kind: "communication", id: \.id, fields: [
            .value("channel", \.channel),
            .value("direction", \.direction),
            .value("recipient", \.recipient),
            .value("subject", \.subject),
            .value("deliveryStatus", \.deliveryStatus),
            .value("workflowRawValue", \.workflowRawValue),
            .value("templateVersion", \.templateVersion),
            .value("createdAt", \.createdAt),
            .optional("serviceCallID", \.serviceCallID),
            .optional("invoiceID", \.invoiceID),
            .optional("estimateID", \.estimateID),
            .optional("maintenanceContractID", \.maintenanceContractID),
            .optional("actorEmail", \.actorEmail),
            .optional("consentSnapshotJSON", \.consentSnapshotJSON),
            .optional("providerStatusDetail", \.providerStatusDetail),
            .optional("deliveredAt", \.deliveredAt),
            .optional("attachmentFileNamesJSON", \.attachmentFileNamesJSON),
            .optional("providerMessageID", \.providerMessageID),
            .optional("backendCommunicationID", \.backendCommunicationID),
            .optional("backendSyncError", \.backendSyncError),
            .reference("customer", \.customer, id: \Customer.id, kind: "customer", required: true),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            CustomerCommunication(id: record.id, customer: try resolver.parent(Customer.self, kind: "customer", field: "customer", record: record), recipient: "", subject: "", deliveryStatus: "pending")
        })
    }
    static var formTemplate: StaffWorkspaceModelCodec<FieldFormTemplate> {
        .init(kind: "formTemplate", id: \.id, fields: [
            .value("title", \.title),
            .value("questionsJSON", \.questionsJSON),
            .value("isActive", \.isActive),
            .value("createdAt", \.createdAt),
            .optional("applicableServiceTypesJSON", \.applicableServiceTypesJSON),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            FieldFormTemplate(id: record.id, title: "", questions: [])
        })
    }
    static var formResponse: StaffWorkspaceModelCodec<FieldFormResponse> {
        .init(kind: "formResponse", id: \.id, fields: [
            .value("serviceCallID", \.serviceCallID),
            .value("templateID", \.templateID),
            .value("templateTitle", \.templateTitle),
            .value("answersJSON", \.answersJSON),
            .value("completedAt", \.completedAt),
            .optional("completedByEmail", \.completedByEmail),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            // Preserve the saved question/answer snapshot even if the original template was retired.
            FieldFormResponse(id: record.id, serviceCallID: record.id, template: FieldFormTemplate(id: record.id, title: "", questions: []), answers: [:])
        })
    }
}
