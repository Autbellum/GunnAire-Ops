import Foundation

enum GmailComposeError: LocalizedError, Equatable {
    case recipients, attachment, header, access, changed, save, busy, consent

    var errorDescription: String? {
        switch self {
        case .recipients: "Enter valid email addresses separated by commas. Your draft has been kept."
        case .attachment: "An attachment is unavailable or invalid. Nothing was sent. Return to the original file and attach it again."
        case .header: "The message contains an invalid subject or reply reference. Nothing was sent."
        case .access: "Your current business access does not allow sending this message."
        case .changed: "The customer, consent, linked work, or business connection changed. Nothing further was sent. Review the original record."
        case .save: "The email history could not be saved. Your draft has been kept."
        case .busy: "This message is already being processed."
        case .consent: "Email was not sent because a recipient's customer contact preference is off. Review Contact Preferences before sending."
        }
    }
}

enum GmailAddressList {
    /// Supports ordinary mailbox lists including quoted display names. Rejects
    /// malformed/header-injected/group syntax instead of guessing a recipient.
    static func parse(_ input: String) throws -> [String] {
        guard !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GmailComposeError.recipients
        }
        var chunks: [String] = [], current = "", quoted = false, escaped = false, angle = false
        for character in input {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quoted { current.append(character); escaped = true; continue }
            if character == "\"" { quoted.toggle() }
            if !quoted {
                if character == "<" { guard !angle else { throw GmailComposeError.recipients }; angle = true }
                if character == ">" { guard angle else { throw GmailComposeError.recipients }; angle = false }
                if character == ",", !angle { chunks.append(current); current = ""; continue }
                if character == ";" || character == ":" { throw GmailComposeError.recipients }
            }
            current.append(character)
        }
        guard !quoted, !escaped, !angle else { throw GmailComposeError.recipients }
        chunks.append(current)
        guard chunks.count <= 100 else { throw GmailComposeError.recipients }
        var addresses: [String] = []
        for chunk in chunks {
            let part = chunk.trimmingCharacters(in: .whitespaces)
            let address: String
            if let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end {
                guard part[part.index(after: end)...].trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw GmailComposeError.recipients
                }
                address = String(part[part.index(after: start)..<end]).trimmingCharacters(in: .whitespaces)
            } else { address = part }
            guard address.utf8.count <= 254,
                  address.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$"#, options: .regularExpression) != nil,
                  let local = address.split(separator: "@").first,
                  !local.hasPrefix("."), !local.hasSuffix("."), !local.contains("..") else {
                throw GmailComposeError.recipients
            }
            if !addresses.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) {
                addresses.append(address)
            }
        }
        guard !addresses.isEmpty else { throw GmailComposeError.recipients }
        return addresses
    }
}

struct GmailReplyContext: Codable, Equatable {
    let threadID: String
    let messageID: String
    let references: [String]
    let subject: String
    var parentID: String? = nil

    static func from(_ message: GmailMessageDetail) -> GmailReplyContext? {
        guard let thread = message.threadId, !thread.isEmpty,
              let id = GmailMessagePresentation.headerValue(named: "Message-ID", in: message),
              isValidMessageID(id) else { return nil }
        let references = (GmailMessagePresentation.headerValue(named: "References", in: message) ?? "")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard references.count <= 50, references.allSatisfy(isValidMessageID) else { return nil }
        return .init(threadID: thread, messageID: id, references: references,
                     subject: GmailMessagePresentation.headerValue(named: "Subject", in: message) ?? "", parentID: message.id)
    }

    nonisolated static func isValidMessageID(_ value: String) -> Bool {
        value.utf8.count <= 250 &&
        value.range(of: #"^<[A-Za-z0-9.!#$%&'*+/=?^_{|}~-]+@[A-Za-z0-9.-]+>$"#, options: .regularExpression) != nil
    }

    var referenceHeader: String {
        (references.filter { $0 != messageID } + [messageID]).joined(separator: " ")
    }
}

struct GmailBusinessContext: Codable, Equatable {
    let customerID: UUID
    var serviceCallID: UUID?
    var invoiceID: UUID?
    var estimateID: UUID?
    var maintenanceContractID: UUID?
    var workflow: GunnAireMailWorkflow = .general
}

struct GmailOutgoingMessage {
    let to: String
    let subject: String
    let body: String
    let attachments: [GmailAttachment]
    let reply: GmailReplyContext?

    init(to: String, subject: String, body: String, attachments: [GmailAttachment] = [],
         reply: GmailReplyContext? = nil) throws {
        self.to = try GmailAddressList.parse(to).joined(separator: ", ")
        guard !subject.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), subject.utf8.count <= 900 else {
            throw GmailComposeError.header
        }
        try Self.validateAttachments(attachments)
        self.subject = subject
        self.body = body
        self.attachments = attachments
        // Google requires matching Subject plus both RFC threading headers.
        // Editing the subject deliberately creates a new conversation.
        self.reply = reply.flatMap { $0.subject == subject ? $0 : nil }
    }

    static func attachments(paths: [String], read: (URL) throws -> Data = { try Data(contentsOf: $0) }) throws -> [GmailAttachment] {
        guard paths.count <= GmailAttachmentLoader.maximumFiles else { throw GmailComposeError.attachment }
        var total = 0
        let attachments = try paths.map { path in
            let url = URL(fileURLWithPath: path)
            guard url.isFileURL else { throw GmailComposeError.attachment }
            let data: Data
            do { data = try read(url) } catch { throw GmailComposeError.attachment }
            guard data.count <= GmailAttachmentLoader.maximumBytes - total else { throw GmailComposeError.attachment }
            total += data.count
            return GmailAttachment(fileName: url.lastPathComponent, mimeType: QuickBooksDataAPI.mimeType(for: url), data: data)
        }
        try validateAttachments(attachments)
        return attachments
    }

    static func validateAttachments(_ attachments: [GmailAttachment]) throws {
        guard attachments.count <= GmailAttachmentLoader.maximumFiles else { throw GmailComposeError.attachment }
        var total = 0
        for attachment in attachments {
            guard !attachment.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  attachment.fileName.unicodeScalars.count <= 255,
                  !attachment.fileName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  attachment.mimeType.range(of: #"^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$"#, options: .regularExpression) != nil,
                  attachment.data.count <= GmailAttachmentLoader.maximumBytes - total else { throw GmailComposeError.attachment }
            total += attachment.data.count
        }
    }

    static func addingFiles(_ urls: [URL], to existing: [GmailAttachment],
                            read: (URL) throws -> Data = { try Data(contentsOf: $0) }) throws -> [GmailAttachment] {
        guard urls.count <= GmailAttachmentLoader.maximumFiles - existing.count else { throw GmailComposeError.attachment }
        var additions: [GmailAttachment] = []
        for url in urls {
            guard url.isFileURL else { throw GmailComposeError.attachment }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let files = try attachments(paths: [url.path], read: read)
            try validateAttachments(existing + additions + files)
            additions += files
        }
        return existing + additions
    }

    static func importingFiles(_ urls: [URL], to existing: [GmailAttachment]) async throws -> [GmailAttachment] {
        try validateAttachments(existing)
        guard urls.count <= GmailAttachmentLoader.maximumFiles - existing.count else { throw GmailComposeError.attachment }
        var files = existing
        var remaining = GmailAttachmentLoader.maximumBytes - existing.reduce(0) { $0 + $1.data.count }
        for url in urls {
            try Task.checkCancellation()
            guard url.isFileURL else { throw GmailComposeError.attachment }
            let limit = remaining
            // File-provider reads can wait on iCloud. Keep that wait off the UI actor.
            let data = try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard resource.isRegularFile == true, (resource.fileSize ?? 0) <= limit else {
                    throw CocoaError(.fileReadTooLarge)
                }
                let data = try Data(contentsOf: url)
                guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
                return data
            }.value
            try Task.checkCancellation()
            remaining -= data.count
            files.append(GmailAttachment(fileName: url.lastPathComponent,
                mimeType: QuickBooksDataAPI.mimeType(for: url), data: data))
        }
        try validateAttachments(files)
        return files
    }
}

struct GmailSendOutcome {
    enum State { case sent, notSent, reviewRequired }
    let state: State
    let message: String
    var canRetry: Bool { state == .notSent }

    static func notSent(_ error: Error) -> Self {
        .init(state: .notSent, message: (error as? GmailDraftError)?.localizedDescription ?? (error as? GmailComposeError)?.localizedDescription ??
              "The message was not sent. Check your Google connection and try again. Your draft has been kept.")
    }
    static let uncertain = Self(state: .reviewRequired,
        message: "Gmail may have received this message. Check Sent in Gmail before composing another copy. Your draft has been kept; it will not be sent again automatically.")
}
