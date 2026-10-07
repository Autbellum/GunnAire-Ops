import Foundation
import SwiftData
import CryptoKit

nonisolated enum BillingPDFPrivateProjectionError: Error, Equatable, Sendable {
    case changed
    case oversized
}

/// Reads one saved billing document and its customer-owned source graph in a
/// private context. Only the immutable render plan crosses the task boundary.
/// This reader does not dispatch a PDF or create a Drive reservation.
nonisolated enum BillingPDFPrivateProjection {
    static let rendererVersion = "customer-pdf-v1"

    enum Kind: String, Sendable {
        case estimate
        case invoice
    }

    struct Rendered: Sendable {
        let prepared: PreparedCustomerDocument
        let data: Data
    }

    /// This digest identifies the customer-visible snapshot on this device.
    /// Local photo paths and file timestamps are excluded; the frozen bytes
    /// are authoritative. Cross-device locale differences are still refused
    /// by the server's per-document conflict fence pending a canonical source.
    static func sourceDigest(_ prepared: PreparedCustomerDocument) throws -> String {
        let plan = prepared.plan
        var values = [Self.rendererVersion, plan.title, plan.customerBlock,
                      plan.approvalSignatureImageBase64 ?? "",
                      String(plan.sections.count)]
        for section in plan.sections {
            values += [section.title, section.keepsTogether ? "1" : "0",
                       String(section.rows.count)]
            for row in section.rows { values += [row.label, row.value] }
        }
        values.append(String(plan.photos.count))
        for photo in plan.photos {
            guard let data = photo.frozenData else {
                throw BillingPDFPrivateProjectionError.changed
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            values += [photo.caption, String(data.count), digest]
        }
        return BillingPDFSourceDigest.make(values)
    }

    static func prepare(
        container: ModelContainer,
        kind: Kind,
        documentID: UUID,
        renderedAt: Date
    ) async throws -> PreparedCustomerDocument {
        try await Task.detached(priority: .utility) {
            try read(container: container, kind: kind, documentID: documentID, renderedAt: renderedAt)
        }.value
    }

    static func isCurrent(
        _ original: PreparedCustomerDocument,
        container: ModelContainer,
        kind: Kind,
        renderedAt: Date
    ) async throws -> Bool {
        let current = try await prepare(container: container, kind: kind,
            documentID: original.documentID, renderedAt: renderedAt)
        return current == original
    }

    /// Produces the existing customer layout without moving a SwiftData model
    /// or photo path onto the main actor. Publication must still recheck the
    /// source and the approved account after its next suspension.
    static func renderCurrent(
        container: ModelContainer,
        kind: Kind,
        documentID: UUID,
        renderedAt: Date
    ) async throws -> Rendered {
        let prepared = try await prepare(container: container, kind: kind,
            documentID: documentID, renderedAt: renderedAt)
        let data = try await Task.detached(priority: .utility) {
            try CustomerDocumentExporter.renderDocumentData(prepared.plan)
        }.value
        guard (5...25 * 1024 * 1024).contains(data.count),
              data.starts(with: Data("%PDF-".utf8)),
              try await isCurrent(prepared, container: container, kind: kind,
                                  renderedAt: renderedAt) else {
            throw BillingPDFPrivateProjectionError.changed
        }
        return Rendered(prepared: prepared, data: data)
    }

    private static func read(
        container: ModelContainer,
        kind: Kind,
        documentID: UUID,
        renderedAt: Date
    ) throws -> PreparedCustomerDocument {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let estimate: Estimate?
        let invoice: Invoice?
        let customer: Customer
        let serviceCallID: UUID?
        switch kind {
        case .estimate:
            var descriptor = FetchDescriptor<Estimate>(predicate: #Predicate { $0.id == documentID })
            descriptor.fetchLimit = 2
            let rows = try context.fetch(descriptor)
            guard rows.count == 1, let row = rows.first, !row.isDeleted,
                  let owner = row.customer else { throw BillingPDFPrivateProjectionError.changed }
            estimate = row
            invoice = nil
            customer = owner
            serviceCallID = row.serviceCallID
        case .invoice:
            var descriptor = FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == documentID })
            descriptor.fetchLimit = 2
            let rows = try context.fetch(descriptor)
            guard rows.count == 1, let row = rows.first, !row.isDeleted,
                  let owner = row.customer else { throw BillingPDFPrivateProjectionError.changed }
            estimate = nil
            invoice = row
            customer = owner
            serviceCallID = row.serviceCallID
        }
        let customerID = customer.id
        var customerDescriptor = FetchDescriptor<Customer>(predicate: #Predicate { $0.id == customerID })
        customerDescriptor.fetchLimit = 2
        let customers = try context.fetch(customerDescriptor)
        guard customers.count == 1, customers[0].persistentModelID == customer.persistentModelID,
              !customer.isDeleted else { throw BillingPDFPrivateProjectionError.changed }

        let calls = try bounded(FetchDescriptor<ServiceCall>(
            predicate: #Predicate { $0.customer?.id == customerID }), context: context)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard Set(calls.map(\.id)).count == calls.count else {
            throw BillingPDFPrivateProjectionError.changed
        }
        let serviceCall: ServiceCall?
        if let serviceCallID {
            let matches = calls.filter { $0.id == serviceCallID }
            guard matches.count == 1 else { throw BillingPDFPrivateProjectionError.changed }
            serviceCall = matches[0]
        } else {
            serviceCall = nil
        }
        var attachmentCandidates = try bounded(FetchDescriptor<ServiceDocumentAttachment>(
            predicate: #Predicate { $0.customer?.id == customerID }), context: context)
        if let serviceCallID {
            attachmentCandidates += try bounded(FetchDescriptor<ServiceDocumentAttachment>(
                predicate: #Predicate { $0.serviceCallID == serviceCallID }), context: context)
        }
        if let equipmentID = serviceCall?.customerEquipmentID {
            attachmentCandidates += try bounded(FetchDescriptor<ServiceDocumentAttachment>(
                predicate: #Predicate { $0.customerEquipmentID == equipmentID }), context: context)
        }
        switch kind {
        case .estimate:
            attachmentCandidates += try bounded(FetchDescriptor<ServiceDocumentAttachment>(
                predicate: #Predicate { $0.estimateID == documentID }), context: context)
        case .invoice:
            attachmentCandidates += try bounded(FetchDescriptor<ServiceDocumentAttachment>(
                predicate: #Predicate { $0.invoiceID == documentID }), context: context)
        }
        guard attachmentCandidates.count <= 8_000 else {
            throw BillingPDFPrivateProjectionError.oversized
        }
        var attachmentsByID: [UUID: ServiceDocumentAttachment] = [:]
        for attachment in attachmentCandidates {
            if let owner = attachment.customer, owner.id != customerID {
                throw BillingPDFPrivateProjectionError.changed
            }
            if let original = attachmentsByID[attachment.id],
               original.persistentModelID != attachment.persistentModelID {
                throw BillingPDFPrivateProjectionError.changed
            }
            attachmentsByID[attachment.id] = attachment
        }
        let attachments = attachmentsByID.values.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        var equipmentCandidates = try bounded(FetchDescriptor<CustomerEquipment>(
            predicate: #Predicate { $0.customer?.id == customerID }), context: context)
        if let equipmentID = serviceCall?.customerEquipmentID {
            equipmentCandidates += try bounded(FetchDescriptor<CustomerEquipment>(
                predicate: #Predicate { $0.id == equipmentID }), context: context)
        }
        var equipmentByID: [UUID: CustomerEquipment] = [:]
        for item in equipmentCandidates {
            if let owner = item.customer, owner.id != customerID {
                throw BillingPDFPrivateProjectionError.changed
            }
            if let original = equipmentByID[item.id],
               original.persistentModelID != item.persistentModelID {
                throw BillingPDFPrivateProjectionError.changed
            }
            equipmentByID[item.id] = item
        }
        let equipment = equipmentByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let name = "GunnAire-\(kind.rawValue.capitalized)-\(documentID.uuidString).pdf"
        let prepared: PreparedCustomerDocument
        switch kind {
        case .estimate:
            guard let estimate else { throw BillingPDFPrivateProjectionError.changed }
            prepared = try CustomerDocumentExporter.preparedEstimateForArchive(estimate,
                serviceCall: serviceCall, attachments: attachments,
                equipmentProfiles: equipment, serviceCalls: calls,
                renderedAt: renderedAt, fileName: name)
        case .invoice:
            guard let invoice else { throw BillingPDFPrivateProjectionError.changed }
            let payments = try bounded(FetchDescriptor<Payment>(
                predicate: #Predicate { $0.invoice?.id == documentID }), context: context)
                .sorted { $0.id.uuidString < $1.id.uuidString }
            guard Set(payments.map(\.id)).count == payments.count else {
                throw BillingPDFPrivateProjectionError.changed
            }
            prepared = try CustomerDocumentExporter.preparedInvoiceForArchive(invoice,
                serviceCall: serviceCall, payments: payments, attachments: attachments,
                equipmentProfiles: equipment, serviceCalls: calls,
                renderedAt: renderedAt, fileName: name)
        }
        guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else {
            throw BillingPDFPrivateProjectionError.changed
        }
        return try freezePhotos(prepared,
            allowedPhotoRoot: documents.appendingPathComponent("GunnAire Attachments", isDirectory: true))
    }

    /// Freezes actual photo bytes, not merely size and modification date.
    /// Calling code runs this from the private projection task, and a later
    /// isCurrent read proves that the same photo bytes are still authoritative.
    static func freezePhotos(
        _ prepared: PreparedCustomerDocument,
        allowedPhotoRoot: URL
    ) throws -> PreparedCustomerDocument {
        let rawRoot = allowedPhotoRoot.standardizedFileURL
        let root = rawRoot.resolvingSymlinksInPath()
        var totalBytes = 0
        let photos = try prepared.plan.photos.map { photo -> BusinessDocumentRenderPlan.Photo in
            try Task.checkCancellation()
            let path = URL(fileURLWithPath: photo.filePath).standardizedFileURL
            let canonical = path.resolvingSymlinksInPath()
            guard path.path.hasPrefix(rawRoot.path + "/"),
                  canonical.path.hasPrefix(root.path + "/") else {
                throw BillingPDFPrivateProjectionError.changed
            }
            let properties = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                  (1...25 * 1024 * 1024).contains(photo.fileSize),
                  totalBytes <= 25 * 1024 * 1024 - photo.fileSize,
                  photo.matchesFileOnDisk else {
                throw BillingPDFPrivateProjectionError.changed
            }
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() }
            var data = Data()
            while data.count <= photo.fileSize {
                let next = try handle.read(upToCount: min(64 * 1024,
                    photo.fileSize + 1 - data.count)) ?? Data()
                if next.isEmpty { break }
                data.append(next)
            }
            guard data.count == photo.fileSize, photo.matchesFileOnDisk else {
                throw BillingPDFPrivateProjectionError.changed
            }
            totalBytes += data.count
            return .init(filePath: photo.filePath, caption: photo.caption,
                fileSize: photo.fileSize, modifiedAt: photo.modifiedAt,
                frozenData: data)
        }
        let original = prepared.plan
        let plan = BusinessDocumentRenderPlan(title: original.title,
            customerBlock: original.customerBlock, sections: original.sections,
            approvalSignatureImageBase64: original.approvalSignatureImageBase64,
            photos: photos, generatedAt: original.generatedAt)
        return PreparedCustomerDocument(plan: plan, fileName: prepared.fileName,
            sourceValues: prepared.sourceValues, customerHeader: prepared.customerHeader,
            customerID: prepared.customerID, documentID: prepared.documentID)
    }

    private static func bounded<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>,
        context: ModelContext
    ) throws -> [Model] {
        var descriptor = descriptor
        descriptor.fetchLimit = 2_001
        let rows = try context.fetch(descriptor)
        guard rows.count <= 2_000 else { throw BillingPDFPrivateProjectionError.oversized }
        return rows
    }
}
