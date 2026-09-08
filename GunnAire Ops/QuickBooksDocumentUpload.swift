import Foundation
import CryptoKit

enum QBODocumentError: LocalizedError, Equatable {
    case access, invalid, unavailable, review, storage, changed, file, limit, jobDestination, photoRequired
    var errorDescription: String? {
        switch self {
        case .access: "Verify administrator access to the original business before continuing. Your file is retained."
        case .invalid: "The original file or destination could not be verified. Keep it for review."
        case .unavailable: "File recovery is unavailable. Your original file is retained; no direct QuickBooks retry was sent."
        case .review: "Check the original upload before taking another action. An interrupted upload will not be sent again."
        case .storage: "The original file could not be saved or verified. Keep this screen open; existing files have not been cleared."
        case .changed: "This saved upload changed in another window. Reopen the original file."
        case .file: "Choose a supported file with a safe filename, up to 25 MB."
        case .limit: "This device's file queue is full. Keep the original file and review saved uploads."
        case .jobDestination: "Choose this job's original invoice or estimate before uploading to QuickBooks. For an unbilled job, save the document in the job's Files first."
        case .photoRequired: "Before and after photos require an image. Choose Supporting Docs for this document."
        }
    }
}

struct QBODocumentScope: Codable, Equatable {
    let companyID: UUID
    let realmID: String
    let environment: String
    func validate() throws {
        guard Self.reference(realmID), ["sandbox", "production"].contains(environment) else { throw QBODocumentError.access }
    }
    static func reference(_ value: String) -> Bool {
        ![".", ".."].contains(value) && value.range(of: #"^[A-Za-z0-9._:-]{1,128}$"#, options: .regularExpression) != nil
    }
    var query: [URLQueryItem] {
        [.init(name: "companyID", value: companyID.uuidString.lowercased()), .init(name: "realmID", value: realmID),
         .init(name: "environment", value: environment)]
    }
}

struct QBODocumentTarget: Codable, Equatable, Hashable {
    let type: String
    let id: String
    static let types = ["Invoice", "Estimate", "Bill", "Payment", "SalesReceipt", "Purchase"]
    static func normalized(_ values: [Self]) throws -> [Self] {
        guard values.count <= 4, Set(values).count == values.count,
              values.allSatisfy({ types.contains($0.type) && QBODocumentScope.reference($0.id) }) else { throw QBODocumentError.invalid }
        return values.sorted { ($0.type, $0.id) < ($1.type, $1.id) }
    }
}

struct QBODocumentJob: Codable, Equatable {
    struct Document: Codable, Equatable {
        let type: String
        let localID: UUID
        let id: String
    }
    let attachmentID: UUID
    let serviceCallID: UUID
    let localCustomerID: UUID
    let customerQuickBooksID: String
    let kind: String
    let stage: String
    let documents: [Document]

    func validate(targets: [QBODocumentTarget]) throws {
        let kinds = ["service_report", "before_photo", "after_photo", "diagnostic_photo", "equipment_data_plate_photo",
                     "warranty_evidence", "customer_document", "invoice_support", "estimate_support", "receipt", "other"]
        guard kinds.contains(kind), ["before", "after", "supporting"].contains(stage),
              QBODocumentScope.reference(customerQuickBooksID), !documents.isEmpty, documents.count <= 4,
              documents.allSatisfy({ ["Invoice", "Estimate"].contains($0.type) &&
                  (kind != "invoice_support" || $0.type == "Invoice") && (kind != "estimate_support" || $0.type == "Estimate") }),
              Set(documents.map { $0.type + "/" + $0.localID.uuidString }).count == documents.count,
              documents.map({ QBODocumentTarget(type: $0.type, id: $0.id) }) == targets,
              try QBODocumentTarget.normalized(documents.map { .init(type: $0.type, id: $0.id) }) == targets else { throw QBODocumentError.invalid }
    }
}

struct QBODocumentFileInfo: Codable, Equatable {
    let filename: String
    let contentType: String
    let size: Int
    let sha256: String
    static let maximum = 25 * 1024 * 1024
    static let mime: [String: Set<String>] = [
        "pdf": ["application/pdf"], "txt": ["text/plain"], "rtf": ["text/rtf", "application/rtf"],
        "jpg": ["image/jpeg", "image/jpg"], "jpeg": ["image/jpeg", "image/jpg"], "png": ["image/png"],
        "gif": ["image/gif"], "tif": ["image/tiff"], "csv": ["text/csv"], "doc": ["application/msword"],
        "docx": ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"], "xls": ["application/vnd.ms-excel"],
        "xlsx": ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"], "ods": ["application/vnd.oasis.opendocument.spreadsheet"],
        "xml": ["application/xml", "text/xml"], "ai": ["application/postscript"], "eps": ["application/postscript"]]

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func validate() throws {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard (1...255).contains(filename.utf8.count), filename == filename.trimmingCharacters(in: .whitespacesAndNewlines),
              !filename.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || "/\\\"".unicodeScalars.contains($0) }),
              Self.mime[ext]?.contains(contentType) == true, (1...Self.maximum).contains(size),
              JobBillingAssignmentSnapshot.validConnectionRevision(sha256) else { throw QBODocumentError.file }
    }
    func verify(_ data: Data) throws {
        try validate()
        guard data.count == size, Self.hash(data) == sha256 else { throw QBODocumentError.invalid }
    }
    init(filename: String, contentType: String, data: Data) throws {
        self.filename = filename; self.contentType = contentType; size = data.count; sha256 = Self.hash(data)
        try validate()
    }
}

enum QBODocumentState: String, Codable { case reserved, sending, uncertain, confirmed, cancelled }

struct QBODocumentUploadRecord: Codable, Equatable, Identifiable {
    let protocolVersion: Int
    let id: UUID
    let companyID: UUID
    let realmID: String
    let environment: String
    let operationID: UUID
    let revision: String
    let state: QBODocumentState
    let providerID: String?
    let file: QBODocumentFileInfo
    let targets: [QBODocumentTarget]
    let jobDocument: QBODocumentJob?
    let createdAt: String
    let updatedAt: String
    let connectionChanged: Bool
    var scope: QBODocumentScope { .init(companyID: companyID, realmID: realmID, environment: environment) }
    var status: String {
        switch state {
        case .reserved: connectionChanged ? "Connection needs review" : "Ready to upload"
        case .sending, .uncertain: "Check original upload"
        case .confirmed: "Saved in QuickBooks"
        case .cancelled: "Cancelled — original retained"
        }
    }
    func validate(_ expected: QBODocumentScope) throws {
        try expected.validate(); try file.validate()
        guard protocolVersion == 1, scope == expected, JobBillingAssignmentSnapshot.validConnectionRevision(revision),
              try QBODocumentTarget.normalized(targets) == targets,
              (state == .confirmed) == (providerID != nil), providerID.map(QBODocumentScope.reference) ?? true,
              let created = CompanyWorkspaceClock.parse(createdAt), let updated = CompanyWorkspaceClock.parse(updatedAt), updated >= created
        else { throw QBODocumentError.invalid }
        try jobDocument?.validate(targets: targets)
    }
    func matchesOriginal(_ other: Self) -> Bool {
        id == other.id && scope == other.scope && operationID == other.operationID && revision == other.revision &&
        file == other.file && targets == other.targets && jobDocument == other.jobDocument && createdAt == other.createdAt
    }
}

struct QBODocumentUploadPage: Decodable {
    let protocolVersion: Int
    let maxFileBytes: Int
    let companyID: UUID
    let realmID: String
    let environment: String
    let connectionRevision: String?
    let uploads: [QBODocumentUploadRecord]
    let nextCursor: UUID?
}

struct QBODocumentUploadRequest: Encodable {
    struct File: Encodable { let filename: String; let contentType: String; let data: Data }
    let companyID: UUID
    let realmID: String
    let environment: String
    let operationID: UUID
    let connectionRevision: String
    let file: File
    let targets: [QBODocumentTarget]
    let jobDocument: QBODocumentJob?
    var scope: QBODocumentScope { .init(companyID: companyID, realmID: realmID, environment: environment) }
    func validate() throws -> QBODocumentFileInfo {
        try scope.validate()
        guard JobBillingAssignmentSnapshot.validConnectionRevision(connectionRevision), try QBODocumentTarget.normalized(targets) == targets else {
            throw QBODocumentError.invalid
        }
        try jobDocument?.validate(targets: targets)
        return try .init(filename: file.filename, contentType: file.contentType, data: file.data)
    }
}

@MainActor struct QBODocumentUploadClient {
    typealias Transport = (String, String, Data?) async throws -> Data
    let transport: Transport
    let check: () throws -> Void
    static let maximumResponseBytes = ((QBODocumentFileInfo.maximum + 2) / 3) * 4 + 65_536
    private let base = "/api/qbo-document-uploads"

    private func perform<T: Decodable>(_ type: T.Type, path: String, body: Data? = nil) async throws -> T {
        try check(); try Task.checkCancellation()
        do {
            let data = try await transport(path, body == nil ? "GET" : "POST", body)
            try check(); try Task.checkCancellation()
            guard data.count <= Self.maximumResponseBytes else { throw QBODocumentError.invalid }
            return try JSONDecoder().decode(type, from: data)
        } catch {
            try check()
            if let error = error as? QBODocumentError { throw error }
            if error is DecodingError { throw QBODocumentError.invalid }
            if case GunnAireBackendError.server(let status, _) = error {
                if [401, 403].contains(status) { throw QBODocumentError.access }
                if status == 400 { throw QBODocumentError.invalid }
                if status == 409 { throw QBODocumentError.review }
            }
            throw QBODocumentError.unavailable
        }
    }

    func page(_ scope: QBODocumentScope, operationID: UUID? = nil, after: UUID? = nil) async throws -> QBODocumentUploadPage {
        try scope.validate()
        guard operationID == nil || after == nil else { throw QBODocumentError.invalid }
        var parts = URLComponents(); parts.path = base; parts.queryItems = scope.query
        if let operationID { parts.queryItems?.append(.init(name: "operationID", value: operationID.uuidString.lowercased())) }
        if let after { parts.queryItems?.append(.init(name: "after", value: after.uuidString.lowercased())) }
        guard let path = parts.string else { throw QBODocumentError.invalid }
        let result = try await perform(QBODocumentUploadPage.self, path: path)
        guard result.protocolVersion == 1, result.maxFileBytes == QBODocumentFileInfo.maximum,
              result.companyID == scope.companyID, result.realmID == scope.realmID, result.environment == scope.environment,
              result.connectionRevision.map(JobBillingAssignmentSnapshot.validConnectionRevision) ?? true,
              result.uploads.count <= (operationID == nil ? 50 : 1), Set(result.uploads.map(\.id)).count == result.uploads.count,
              result.nextCursor == nil || (result.uploads.count == 50 && result.nextCursor == result.uploads.last?.id && result.nextCursor != after),
              result.uploads.map({ $0.id.uuidString }).sorted() == result.uploads.map({ $0.id.uuidString }),
              after.map({ cursor in result.uploads.allSatisfy { $0.id.uuidString > cursor.uuidString } }) ?? true else { throw QBODocumentError.invalid }
        for row in result.uploads { try row.validate(scope) }
        return result
    }

    func reserve(_ request: QBODocumentUploadRequest) async throws -> QBODocumentUploadRecord {
        let file = try request.validate()
        let result = try await perform(QBODocumentUploadRecord.self, path: base, body: JSONEncoder().encode(request))
        try result.validate(request.scope)
        // Deduplication may return an earlier original operation. Its original
        // file/destination/job must still match; never invent a new operation.
        guard result.file == file, result.targets == request.targets, result.jobDocument == request.jobDocument else { throw QBODocumentError.invalid }
        return result
    }

    func read(_ id: UUID, scope: QBODocumentScope) async throws -> QBODocumentUploadRecord {
        let result = try await perform(QBODocumentUploadRecord.self, path: base + "/" + id.uuidString.lowercased())
        try result.validate(scope)
        guard result.id == id else { throw QBODocumentError.invalid }
        return result
    }

    enum Action: String { case send, recover, cancel }
    func action(_ action: Action, original: QBODocumentUploadRecord) async throws -> QBODocumentUploadRecord {
        try original.validate(original.scope)
        if action == .send, original.state != .reserved || original.connectionChanged { throw QBODocumentError.review }
        if action == .cancel, ![.reserved, .cancelled].contains(original.state) { throw QBODocumentError.review }
        let body = action == .recover ? Data("{}".utf8) : try JSONEncoder().encode(["revision": original.revision])
        let result = try await perform(QBODocumentUploadRecord.self, path: base + "/" + original.id.uuidString.lowercased() + "/" + action.rawValue, body: body)
        try result.validate(original.scope)
        guard result.matchesOriginal(original), action != .cancel || result.state == .cancelled,
              action != .send || result.state == .confirmed,
              original.state != .confirmed || (result.state == .confirmed && result.providerID == original.providerID),
              ![.sending, .uncertain].contains(original.state) || [.sending, .uncertain, .confirmed].contains(result.state)
        else { throw QBODocumentError.invalid }
        return result
    }

    func file(_ original: QBODocumentUploadRecord) async throws -> Data {
        struct Response: Decodable {
            let record: QBODocumentUploadRecord
            let data: Data
            init(from decoder: Decoder) throws {
                record = try QBODocumentUploadRecord(from: decoder)
                data = try decoder.container(keyedBy: CodingKeys.self).decode(Data.self, forKey: .data)
            }
            enum CodingKeys: String, CodingKey { case data }
        }
        try original.validate(original.scope)
        let value = try await perform(Response.self, path: base + "/" + original.id.uuidString.lowercased() + "/file")
        try value.record.validate(original.scope)
        guard value.record.matchesOriginal(original) else { throw QBODocumentError.invalid }
        try original.file.verify(value.data)
        return value.data
    }
}
