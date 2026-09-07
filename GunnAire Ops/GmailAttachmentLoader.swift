import Foundation

struct GmailAttachmentPart: Identifiable {
    let id: String
    let fileName: String
    let mimeType: String
    let body: GmailMessageBody
}

enum GmailAttachmentLoader {
    // Application memory/compose bounds, not a claim about Google's maximum.
    static let maximumBytes = 25_000_000
    static let maximumFiles = 50

    static func parts(in payload: GmailMessagePayload?) throws -> [GmailAttachmentPart] {
        var result: [GmailAttachmentPart] = []
        func visit(_ payload: GmailMessagePayload, path: String, depth: Int) throws {
            guard depth <= 30 else { throw GmailComposeError.attachment }
            let isText = ["text/plain", "text/html"].contains(payload.mimeType?.lowercased() ?? "")
            if payload.filename?.isEmpty == false || (!isText && (payload.body?.attachmentId != nil || payload.body?.data?.isEmpty == false)) {
                guard result.count < maximumFiles, let body = payload.body else { throw GmailComposeError.attachment }
                result.append(.init(id: path, fileName: payload.filename?.isEmpty == false ? payload.filename! : "Attachment",
                                    mimeType: payload.mimeType ?? "application/octet-stream", body: body))
            } else {
                for (index, part) in (payload.parts ?? []).enumerated() {
                    try visit(part, path: path + ".\(index)", depth: depth + 1)
                }
            }
        }
        if let payload { try visit(payload, path: "0", depth: 0) }
        return result
    }

    static func decode(_ body: GmailMessageBody, expectedSize: Int?) throws -> Data {
        guard let encoded = body.data, let size = body.size ?? expectedSize,
              size >= 0, size <= maximumBytes, encoded.utf8.count <= maximumBytes * 2 else {
            throw GmailComposeError.attachment
        }
        var normalized = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized), data.count == size,
              expectedSize == nil || expectedSize == data.count else { throw GmailComposeError.attachment }
        return data
    }

    static func load(_ parts: [GmailAttachmentPart], messageID: String, auth: GoogleAuthManager,
                     operation: WorkspaceProviderOperation) async throws -> [GmailAttachment] {
        try operation.check()
        guard GoogleAuthManager.calendarPathComponent(messageID) != nil, parts.count <= maximumFiles else {
            throw GmailComposeError.attachment
        }
        var attachments: [GmailAttachment] = [], total = 0
        for part in parts {
            try operation.check()
            let body: GmailMessageBody
            if let id = part.body.attachmentId {
                body = try await withCheckedThrowingContinuation { continuation in
                    auth.fetchGmailAttachment(messageID: messageID, attachmentID: id, operation: operation) {
                        continuation.resume(with: $0)
                    }
                }
            } else { body = part.body }
            try operation.check()
            let data = try decode(body, expectedSize: part.body.size)
            guard total <= maximumBytes - data.count else { throw GmailComposeError.attachment }
            total += data.count
            attachments.append(.init(fileName: part.fileName, mimeType: part.mimeType, data: data))
        }
        try operation.check()
        try GmailOutgoingMessage.validateAttachments(attachments)
        return attachments
    }

    /// Used for embedded MIME content, including the isolated UI fixtures.
    /// A remote attachment reference is never silently replaced with empty data.
    static func inlineAttachments(_ parts: [GmailAttachmentPart]) throws -> [GmailAttachment] {
        guard parts.count <= maximumFiles else { throw GmailComposeError.attachment }
        let attachments = try parts.map { part in
            guard part.body.attachmentId == nil else { throw GmailComposeError.attachment }
            return GmailAttachment(fileName: part.fileName, mimeType: part.mimeType,
                                   data: try decode(part.body, expectedSize: part.body.size))
        }
        try GmailOutgoingMessage.validateAttachments(attachments)
        return attachments
    }

    /// Gmail may store a long text body behind the same attachment endpoint.
    /// Resolve only body text here; actual files remain lazy until opened or forwarded.
    static func loadingTextBodies(in message: GmailMessageDetail, auth: GoogleAuthManager,
                                 operation: WorkspaceProviderOperation) async throws -> GmailMessageDetail {
        try operation.check()
        var total = 0, visited = 0
        func resolve(_ payload: GmailMessagePayload, depth: Int) async throws -> GmailMessagePayload {
            try operation.check()
            visited += 1
            guard depth <= 30, visited <= 500 else { throw GmailComposeError.attachment }
            guard payload.filename?.isEmpty != false else { return payload }
            var body = payload.body
            if ["text/plain", "text/html"].contains(payload.mimeType?.lowercased() ?? ""), let original = body {
                if let id = original.attachmentId {
                    body = try await withCheckedThrowingContinuation { continuation in
                        auth.fetchGmailAttachment(messageID: message.id, attachmentID: id, operation: operation) {
                            continuation.resume(with: $0)
                        }
                    }
                }
                try operation.check()
                guard let content = body else { throw GmailComposeError.attachment }
                let data = try decode(content, expectedSize: original.size)
                guard data.count <= maximumBytes - total else { throw GmailComposeError.attachment }
                total += data.count
                body = GmailMessageBody(data: data.base64EncodedString(), size: data.count)
            }
            var parts: [GmailMessagePayload] = []
            for part in payload.parts ?? [] { parts.append(try await resolve(part, depth: depth + 1)) }
            return GmailMessagePayload(headers: payload.headers, mimeType: payload.mimeType, body: body,
                                       parts: payload.parts == nil ? nil : parts, filename: payload.filename)
        }
        let payload: GmailMessagePayload?
        if let original = message.payload { payload = try await resolve(original, depth: 0) }
        else { payload = nil }
        try operation.check()
        return GmailMessageDetail(id: message.id, threadId: message.threadId, labelIds: message.labelIds,
                                  snippet: message.snippet, internalDate: message.internalDate, payload: payload)
    }

    static func previewFile(for attachment: GmailAttachment) throws -> URL {
        let name = URL(fileURLWithPath: attachment.fileName.replacingOccurrences(of: "\\", with: "/")).lastPathComponent
        guard !["", ".", "..", "/"].contains(name), name.utf8.count <= 255 else { throw GmailComposeError.attachment }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gunnaire-mail-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent(name)
        do { try attachment.data.write(to: url, options: [.atomic, .completeFileProtection]) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return url
    }

    static func removePreviewFile(_ url: URL) {
        let directory = url.deletingLastPathComponent().standardizedFileURL
        let prefix = "gunnaire-mail-"
        guard directory.deletingLastPathComponent() == FileManager.default.temporaryDirectory.standardizedFileURL,
              directory.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil else { return }
        // Only the unique, app-created read-only preview directory is removed.
        try? FileManager.default.removeItem(at: directory)
    }
}
