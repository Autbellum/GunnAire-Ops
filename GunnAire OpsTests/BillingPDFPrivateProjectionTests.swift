import Foundation
import SwiftData
import Testing
import UIKit
@testable import GunnAire_Ops

@MainActor
struct BillingPDFPrivateProjectionTests {
    private func fixture() throws -> (ModelContainer, ModelContext, Customer) {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let customer = Customer(name: "Projection Customer")
        context.insert(customer)
        try context.save()
        return (container, context, customer)
    }

    @Test func savedEstimateProjectionIsStableAndRejectsLaterEdit() async throws {
        let (container, context, customer) = try fixture()
        let estimate = Estimate(customer: customer, lineItemSummary: "One service visit",
            amount: 125, notes: "Original scope")
        context.insert(estimate)
        try context.save()
        let renderedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let first = try await BillingPDFPrivateProjection.prepare(container: container,
            kind: .estimate, documentID: estimate.id, renderedAt: renderedAt)
        let repeated = try await BillingPDFPrivateProjection.prepare(container: container,
            kind: .estimate, documentID: estimate.id, renderedAt: renderedAt)
        #expect(first == repeated)
        #expect(first.plan.generatedAt == renderedAt)
        #expect(first.fileName.contains(estimate.id.uuidString))
        let rendered = try await BillingPDFPrivateProjection.renderCurrent(container: container,
            kind: .estimate, documentID: estimate.id, renderedAt: renderedAt)
        #expect(rendered.prepared == first)
        #expect(rendered.data.starts(with: Data("%PDF-".utf8)))
        estimate.notes = "Revised scope"
        try context.save()
        let stillCurrent = try await BillingPDFPrivateProjection.isCurrent(first,
            container: container, kind: .estimate, renderedAt: renderedAt)
        #expect(!stillCurrent)
    }

    @Test func savedInvoiceProjectionRejectsLaterBalanceChange() async throws {
        let (container, context, customer) = try fixture()
        let invoice = Invoice(customer: customer, lineItemSummary: "Repair labor",
            amount: 225, completionNotes: "Original completion")
        context.insert(invoice)
        try context.save()
        let renderedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let original = try await BillingPDFPrivateProjection.prepare(container: container,
            kind: .invoice, documentID: invoice.id, renderedAt: renderedAt)
        #expect(original.plan.generatedAt == renderedAt)
        let rendered = try await BillingPDFPrivateProjection.renderCurrent(container: container,
            kind: .invoice, documentID: invoice.id, renderedAt: renderedAt)
        #expect(rendered.prepared == original)
        #expect(rendered.data.starts(with: Data("%PDF-".utf8)))
        invoice.amount = 250
        try context.save()
        let stillCurrent = try await BillingPDFPrivateProjection.isCurrent(original,
            container: container, kind: .invoice, renderedAt: renderedAt)
        #expect(!stillCurrent)
    }

    @Test func duplicateSavedDocumentIdentityFailsClosed() async throws {
        let (container, context, customer) = try fixture()
        let id = UUID()
        context.insert(Estimate(id: id, customer: customer, amount: 100))
        context.insert(Estimate(id: id, customer: customer, amount: 200))
        try context.save()
        await #expect(throws: BillingPDFPrivateProjectionError.changed) {
            try await BillingPDFPrivateProjection.prepare(container: container,
                kind: .estimate, documentID: id, renderedAt: Date(timeIntervalSince1970: 1_780_000_000))
        }
    }

    @Test func photoByteChangeWithSameSizeAndTimeChangesFrozenSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("billing-pdf-photo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("source.png")
        let original = Data("synthetic-photo-A".utf8)
        let changed = Data("synthetic-photo-B".utf8)
        try original.write(to: path)
        let stableTime = Date(timeIntervalSince1970: 1_780_000_000)
        try FileManager.default.setAttributes([.modificationDate: stableTime],
            ofItemAtPath: path.path)
        let fingerprint = BusinessDocumentRenderPlan.Photo.fingerprint(path.path)
        guard let modifiedAt = fingerprint.modifiedAt else {
            throw BillingPDFPrivateProjectionError.changed
        }
        let photo = BusinessDocumentRenderPlan.Photo(filePath: path.path,
            caption: "Original photo", fileSize: fingerprint.size,
            modifiedAt: modifiedAt, frozenData: nil)
        let plan = BusinessDocumentRenderPlan(title: "Estimate",
            customerBlock: "Synthetic Customer", sections: [],
            approvalSignatureImageBase64: nil, photos: [photo],
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000))
        let prepared = PreparedCustomerDocument(plan: plan, fileName: "estimate.pdf",
            sourceValues: ["original"], customerHeader: ["synthetic"],
            customerID: UUID(), documentID: UUID())
        let first = try BillingPDFPrivateProjection.freezePhotos(prepared,
            allowedPhotoRoot: root)
        #expect(first.plan.photos[0].frozenData == original)
        try changed.write(to: path)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt],
            ofItemAtPath: path.path)
        let second = try BillingPDFPrivateProjection.freezePhotos(prepared,
            allowedPhotoRoot: root)
        #expect(second.plan.photos[0].frozenData == changed)
        #expect(first != second)
    }

    @Test func photoOutsideApprovedRootFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("billing-pdf-photo-root-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("billing-pdf-photo-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let link = root.appendingPathComponent("source.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let fingerprint = BusinessDocumentRenderPlan.Photo.fingerprint(link.path)
        let photo = BusinessDocumentRenderPlan.Photo(filePath: link.path,
            caption: "Outside photo", fileSize: fingerprint.size,
            modifiedAt: fingerprint.modifiedAt, frozenData: nil)
        let plan = BusinessDocumentRenderPlan(title: "Invoice",
            customerBlock: "Synthetic Customer", sections: [],
            approvalSignatureImageBase64: nil, photos: [photo],
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000))
        let prepared = PreparedCustomerDocument(plan: plan, fileName: "invoice.pdf",
            sourceValues: [], customerHeader: [], customerID: UUID(), documentID: UUID())
        #expect(throws: BillingPDFPrivateProjectionError.changed) {
            try BillingPDFPrivateProjection.freezePhotos(prepared, allowedPhotoRoot: root)
        }
    }

    @Test func frozenPhotoRendersAfterOriginalPathDisappears() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("billing-pdf-frozen-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("source.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        guard let png = image.pngData() else { throw BillingPDFPrivateProjectionError.changed }
        try png.write(to: path)
        let fingerprint = BusinessDocumentRenderPlan.Photo.fingerprint(path.path)
        let photo = BusinessDocumentRenderPlan.Photo(filePath: path.path,
            caption: "Frozen photo", fileSize: fingerprint.size,
            modifiedAt: fingerprint.modifiedAt, frozenData: nil)
        let plan = BusinessDocumentRenderPlan(title: "Estimate",
            customerBlock: "Synthetic Customer", sections: [],
            approvalSignatureImageBase64: nil, photos: [photo],
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000))
        let prepared = PreparedCustomerDocument(plan: plan, fileName: "estimate.pdf",
            sourceValues: [], customerHeader: [], customerID: UUID(), documentID: UUID())
        let frozen = try BillingPDFPrivateProjection.freezePhotos(prepared, allowedPhotoRoot: root)
        try FileManager.default.removeItem(at: path)
        let bytes = try await Task.detached {
            try CustomerDocumentExporter.renderDocumentData(frozen.plan)
        }.value
        #expect(bytes.starts(with: Data("%PDF-".utf8)))
    }

    @Test func unrelatedOrphanPhotoDoesNotEnterCustomerJobPDF() {
        let customer = Customer(name: "Target Customer")
        let call = ServiceCall(type: .repair, scheduledDate: Date(), customer: customer)
        let equipmentID = UUID()
        let orphan = ServiceDocumentAttachment(customer: nil, serviceCallID: nil,
            kind: .beforePhoto, displayName: "Unrelated.png",
            localFilePath: "/synthetic/unrelated.png", contentType: "image/png",
            fileSizeBytes: 10)
        let withoutEquipment = CustomerDocumentExporter.reportEvidenceAttachments(
            for: [orphan], serviceCall: call)
        #expect(withoutEquipment.isEmpty)
        call.customerEquipmentID = equipmentID
        let shared = ServiceDocumentAttachment(customer: nil, serviceCallID: nil,
            customerEquipmentID: equipmentID, kind: .beforePhoto,
            displayName: "Matching.png", localFilePath: "/synthetic/matching.png",
            contentType: "image/png", fileSizeBytes: 10)
        let matching = CustomerDocumentExporter.reportEvidenceAttachments(
            for: [orphan, shared], serviceCall: call)
        #expect(matching.map(\.id) == [shared.id])
    }
}
