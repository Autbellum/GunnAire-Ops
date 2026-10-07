import Foundation
import CryptoKit

nonisolated enum QuickBooksDocumentEmailError: LocalizedError, Equatable {
    case busy, storage, invalidDocument, recipientRequired, reviewRequired, reconciled, acceptedInOriginalWorkspace
    var errorDescription: String? {
        switch self {
        case .busy: "This document already has an email operation in progress."
        case .storage: "The email attempt could not be saved or verified. No new copy will be sent."
        case .invalidDocument: "QuickBooks returned a different or incomplete document. Refresh the document before sending."
        case .recipientRequired: "Choose one valid customer email address before sending through QuickBooks."
        case .reviewRequired: "QuickBooks may have accepted the earlier email. Another copy was not sent. Use this action again to check its status, or review the document's email history in QuickBooks."
        case .acceptedInOriginalWorkspace: "QuickBooks accepted the email in the original workspace, but your workspace changed before its local history could be updated. Review the original document in QuickBooks; do not send another copy as a retry."
        case .reconciled: "QuickBooks now reports the earlier email as sent. Another copy was not sent. Recipient delivery is not verified."
        }
    }
}

nonisolated struct QuickBooksDocumentDeliveryInfo: Codable, Equatable, Sendable {
    let DeliveryType: String?
    let DeliveryTime: String?
}

nonisolated struct QuickBooksDocumentEmailObservation: Sendable {
    let id: String
    let recipient: String?
    let emailStatus: String?
    let delivery: QuickBooksDocumentDeliveryInfo?
    var customerID: String? = nil

    func confirms(_ attempt: QuickBooksDocumentEmailAttempt) -> Bool {
        guard emailStatus == "EmailSent", delivery?.DeliveryType == "Email",
              let recipient, QuickBooksDocumentEmailAttempt.digest(recipient.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) == attempt.recipientDigest,
              let stamp = delivery?.DeliveryTime,
              let sentAt = Self.date(stamp), sentAt >= attempt.startedAt else { return false }
        if let previous = attempt.previousDeliveryTime {
            guard let previousDate = Self.date(previous), sentAt > previousDate else { return false }
        }
        return true
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

/// Contains only opaque document/recipient digests, timing and a request ID.
/// Never persist bearer tokens, customer addresses or document contents here.
nonisolated struct QuickBooksDocumentEmailAttempt: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case pending, accepted, rejected }
    let key: String
    let requestID: UUID
    let recipientDigest: String
    let previousDeliveryTime: String?
    let startedAt: Date
    var state: State

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// All journal I/O is isolated from SwiftUI. A persisted pending attempt survives
/// process termination and blocks a fresh POST until provider readback confirms it.
actor QuickBooksDocumentEmailJournal {
    static let device = QuickBooksDocumentEmailJournal(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("QuickBooksEmailAttempts-v1", isDirectory: true))
    private let directory: URL?
    private let memoryOnly: Bool
    private var records: [String: QuickBooksDocumentEmailAttempt] = [:]
    private var active: Set<String> = []

    init(directory: URL?, memoryOnly: Bool = false) {
        self.directory = directory
        self.memoryOnly = memoryOnly
    }

    func acquire(_ key: String) throws -> QuickBooksDocumentEmailAttempt? {
        guard !active.contains(key) else { throw QuickBooksDocumentEmailError.busy }
        let value = try read(key)
        active.insert(key)
        return value
    }

    func release(_ key: String) { active.remove(key) }

    func begin(key: String, recipient: String, previousDeliveryTime: String?, now: Date = Date()) throws -> QuickBooksDocumentEmailAttempt {
        guard active.contains(key), try read(key)?.state != .pending else { throw QuickBooksDocumentEmailError.reviewRequired }
        let attempt = QuickBooksDocumentEmailAttempt(key: key, requestID: UUID(),
            recipientDigest: QuickBooksDocumentEmailAttempt.digest(recipient),
            previousDeliveryTime: previousDeliveryTime, startedAt: now, state: .pending)
        try write(attempt)
        return attempt
    }

    func finish(_ attempt: QuickBooksDocumentEmailAttempt, state: QuickBooksDocumentEmailAttempt.State) throws {
        guard let current = try read(attempt.key), current.requestID == attempt.requestID,
              current.state == .pending else { throw QuickBooksDocumentEmailError.storage }
        var updated = current
        updated.state = state
        try write(updated)
    }

    private func read(_ key: String) throws -> QuickBooksDocumentEmailAttempt? {
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit }) else { throw QuickBooksDocumentEmailError.storage }
        if memoryOnly { return records[key] }
        guard let directory else { throw QuickBooksDocumentEmailError.storage }
        let file = directory.appendingPathComponent(key + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  (info.fileSize ?? Int.max) < 8192 else { throw QuickBooksDocumentEmailError.storage }
            let value = try JSONDecoder().decode(QuickBooksDocumentEmailAttempt.self, from: Data(contentsOf: file))
            guard value.key == key, value.recipientDigest.count == 64 else { throw QuickBooksDocumentEmailError.storage }
            return value
        } catch { throw QuickBooksDocumentEmailError.storage }
    }

    private func write(_ value: QuickBooksDocumentEmailAttempt) throws {
        if memoryOnly { records[value.key] = value; return }
        guard let directory else { throw QuickBooksDocumentEmailError.storage }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw QuickBooksDocumentEmailError.storage }
            let data = try JSONEncoder().encode(value)
            try data.write(to: directory.appendingPathComponent(value.key + ".json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { throw QuickBooksDocumentEmailError.storage }
    }
}
