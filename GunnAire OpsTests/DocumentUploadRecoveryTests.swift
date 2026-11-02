import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct DocumentUploadRecoveryTests {
    func request() -> GunnAireBackendService.SharedCompanyDocumentUploadRequest {
        .init(operationID: UUID(), data: Data("original".utf8), filename: "report.pdf",
            contentType: "application/pdf", kind: "service_report", serviceCallID: UUID(),
            invoiceID: nil, estimateID: nil, maintenanceContractID: nil,
            customerEquipmentID: UUID(), customerName: "Synthetic customer")
    }
    func envelope(_ request: GunnAireBackendService.SharedCompanyDocumentUploadRequest) -> [String: Any] {
        ["schema": "document-upload-recovery-v1", "operationID": request.operationID.uuidString.lowercased(),
         "document": ["id": UUID().uuidString.lowercased(), "filename": request.filename,
            "contentType": request.contentType, "kind": request.kind,
            "fileSizeBytes": request.data.count, "fileSHA256": QBODocumentFileInfo.hash(request.data),
            "serviceCallID": request.serviceCallID!.uuidString, "customerEquipmentID": request.customerEquipmentID!.uuidString,
            "customerName": request.customerName!, "equipmentName": "Original equipment", "createdAt": "2026-11-02T00:00:00Z"]]
    }
    @Test func legacyUncertainAttachmentCannotMintANewRecoveryIdentity() throws {
        let attachment = ServiceDocumentAttachment(customer: nil, serviceCallID: nil, kind: .other,
            displayName: "fixture.pdf", localFilePath: "/synthetic/fixture.pdf", contentType: "application/pdf", fileSizeBytes: 8)
        #expect(try attachment.retainedCompanyUploadOperationID() == attachment.id)
        attachment.sharedCompanyUploadOperationID = nil // Missing field in a migrated legacy record.
        #expect(throws: CompanyDocumentContentError.unverified) {
            try attachment.retainedCompanyUploadOperationID()
        }
        #expect(attachment.sharedCompanyUploadOperationID == nil)
        attachment.sharedCompanyUploadOperationID = UUID()
        #expect(throws: CompanyDocumentContentError.unverified) {
            try attachment.retainedCompanyUploadOperationID()
        }
    }

    @Test func committedSameOperationRecoversOriginalIDAndContent() throws {
        let request = request(), value = envelope(request)
        let raw = try JSONSerialization.data(withJSONObject: value)
        let recovered = try #require(try GunnAireBackendService.verifiedDocumentUploadRecovery(raw, request: request))
        #expect(recovered.id == (value["document"] as! [String: Any])["id"] as? String)
        #expect(recovered.filename == request.filename)
        #expect(try GunnAireBackendService.verifiedDocumentUploadRecovery(raw, request: request, equipmentName: "Original equipment")?.id == recovered.id)
        #expect(throws: CompanyDocumentContentError.changed) {
            try GunnAireBackendService.verifiedDocumentUploadRecovery(raw, request: request, equipmentName: "Different equipment")
        }
    }
    @Test func onlyVersionedExplicitAbsencePermitsNewOperation() throws {
        let request = request()
        var value: [String: Any] = ["schema": "document-upload-recovery-v1", "operationID": request.operationID.uuidString.lowercased(), "document": NSNull()]
        #expect(try GunnAireBackendService.verifiedDocumentUploadRecovery(JSONSerialization.data(withJSONObject: value), request: request) == nil)
        value.removeValue(forKey: "document")
        #expect(throws: (any Error).self) {
            try GunnAireBackendService.verifiedDocumentUploadRecovery(JSONSerialization.data(withJSONObject: value), request: request)
        }
        value["document"] = NSNull(); value["schema"] = "unknown"
        #expect(throws: CompanyDocumentContentError.invalid) {
            try GunnAireBackendService.verifiedDocumentUploadRecovery(JSONSerialization.data(withJSONObject: value), request: request)
        }
    }
    @Test func mismatchedIdentityMetadataOrBytesCannotConfirmUpload() throws {
        let request = request()
        for (key, replacement) in [("id", "invalid"), ("fileSHA256", String(repeating: "0", count: 64)),
            ("filename", "other.pdf"), ("contentType", "text/plain"), ("kind", "invoice"),
            ("serviceCallID", UUID().uuidString), ("customerEquipmentID", UUID().uuidString),
            ("customerName", "Other customer")] {
            var value = envelope(request)
            var document = value["document"] as! [String: Any]
            document[key] = replacement; value["document"] = document
            #expect(throws: CompanyDocumentContentError.changed) {
                try GunnAireBackendService.verifiedDocumentUploadRecovery(JSONSerialization.data(withJSONObject: value), request: request)
            }
        }
        var value = envelope(request); value["operationID"] = UUID().uuidString.lowercased()
        #expect(throws: CompanyDocumentContentError.invalid) {
            try GunnAireBackendService.verifiedDocumentUploadRecovery(JSONSerialization.data(withJSONObject: value), request: request)
        }
    }
    @Test func canonicalServerNamesAndEmptyEquipmentRecoverWithoutRelaxingProof() throws {
        for (raw, stored) in [(" José.pdf ", "Jos_.pdf"), ("receipt(1).pdf", "receipt_1_.pdf"), ("\u{001c}report.pdf\u{0085}", "report.pdf")] {
            let base = request()
            let request = GunnAireBackendService.SharedCompanyDocumentUploadRequest(operationID: base.operationID,
                data: base.data, filename: raw, contentType: base.contentType, kind: base.kind,
                serviceCallID: base.serviceCallID, invoiceID: nil, estimateID: nil, maintenanceContractID: nil,
                customerEquipmentID: base.customerEquipmentID, customerName: base.customerName)
            var value = envelope(request)
            var document = value["document"] as! [String: Any]
            document["filename"] = stored
            document["equipmentName"] = NSNull()
            value["document"] = document
            #expect(try GunnAireBackendService.verifiedDocumentUploadRecovery(JSONSerialization.data(withJSONObject: value), request: request, equipmentName: "  \n")?.filename == stored)
        }
    }

}
