import Foundation

nonisolated struct QuickBooksOAuthCallback: Equatable, Sendable {
    let state: String
    let code: String
    let realmID: String

    static func parse(_ url: URL, expectedScheme: String) throws -> Self {
        guard !expectedScheme.isEmpty,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.caseInsensitiveCompare(expectedScheme) == .orderedSame,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems else { throw QBOError.invalidCallback }
        func single(_ key: String, allowedNames: Set<String>) throws -> String {
            let matches = items.filter { $0.name.lowercased() == key }
            guard matches.count == 1, let item = matches.first, allowedNames.contains(item.name),
                  let value = item.value, !value.isEmpty, value.utf8.count <= 8192,
                  value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                throw QBOError.invalidCallback
            }
            return value
        }
        let state = try single("state", allowedNames: ["state"])
        guard UUID(uuidString: state)?.uuidString == state else { throw QBOError.invalidState }
        guard !items.contains(where: { $0.name.lowercased() == "error" }) else {
            throw QBOError.authorizationDeclined
        }
        return Self(state: state, code: try single("code", allowedNames: ["code"]),
                    realmID: try single("realmid", allowedNames: ["realmId", "realmid"]))
    }

    static func isCandidate(_ url: URL, expectedScheme: String) -> Bool {
        guard url.scheme?.caseInsensitiveCompare(expectedScheme) == .orderedSame,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let names = Set((parts.queryItems ?? []).map { $0.name.lowercased() })
        return names.contains("realmid") || (names.contains("state") && !names.isDisjoint(with: ["code", "error"]))
    }
}

nonisolated struct QuickBooksOAuthStateRecord: Codable, Equatable, Sendable {
    static let lifetime: TimeInterval = 10 * 60

    let id: UUID
    let createdAt: Date
    let expiresAt: Date
    let binding: String

    var state: String { id.uuidString }

    init(id: UUID = UUID(), binding: String, createdAt: Date = Date()) {
        self.id = id
        self.binding = binding
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(Self.lifetime)
    }

    fileprivate func validate() throws {
        let duration = expiresAt.timeIntervalSince(createdAt)
        guard !binding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              duration > 0, duration <= Self.lifetime else {
            throw QuickBooksOAuthStateError.invalidRecord
        }
    }
}

nonisolated enum QuickBooksOAuthStateError: Error, Equatable {
    case missing
    case invalidRecord
    case mismatchedState
    case changedBinding
    case expired
    case clockRollback
    case removalNotConfirmed
}

/// Synchronous operations keep each read/validate/remove transaction within one actor turn.
nonisolated struct QuickBooksOAuthStateStorage: Sendable {
    let read: @Sendable () throws -> Data?
    let write: @Sendable (Data) throws -> Void
    let remove: @Sendable () throws -> Void

    static var keychain: Self {
        let account = "QuickBooksPendingOAuthState-v1"
        return Self(
            read: { try KeychainStore.loadData(account: account) },
            write: { try KeychainStore.saveData($0, account: account) },
            remove: { try KeychainStore.remove(account: account) }
        )
    }
}

/// The production singleton serializes all pending-flow changes off the main actor.
actor QuickBooksOAuthStateStore {
    static let shared = QuickBooksOAuthStateStore()
    private let storage: QuickBooksOAuthStateStorage

    init(storage: QuickBooksOAuthStateStorage = .keychain) {
        self.storage = storage
    }

    func save(_ record: QuickBooksOAuthStateRecord) throws {
        try Task.checkCancellation()
        try record.validate()
        try storage.write(JSONEncoder().encode(record))
    }

    /// The caller rejects duplicate callback parameters before passing the sole state value.
    /// A successful result is issued only after durable removal and read-back confirmation.
    func consume(state: String, binding: String, now: Date = Date()) throws -> QuickBooksOAuthStateRecord {
        try Task.checkCancellation()
        guard let record = try readRecord() else { throw QuickBooksOAuthStateError.missing }
        guard state == record.state else { throw QuickBooksOAuthStateError.mismatchedState }
        guard binding == record.binding else { throw QuickBooksOAuthStateError.changedBinding }
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw QuickBooksOAuthStateError.invalidRecord }
        guard now >= record.createdAt else { throw QuickBooksOAuthStateError.clockRollback }
        guard now < record.expiresAt else { throw QuickBooksOAuthStateError.expired }
        try Task.checkCancellation()
        try removeAndConfirm()
        return record
    }

    /// An older browser session must never cancel a subsequently started flow.
    @discardableResult
    func cancel(state: String) throws -> Bool {
        guard let record = try readRecord(), record.state == state else { return false }
        try removeAndConfirm()
        return true
    }

    /// A restarted app has no in-memory state ID, but may invalidate its own saved session's flow.
    @discardableResult
    func cancel(binding: String) throws -> Bool {
        guard let record = try readRecord(), record.binding == binding else { return false }
        try removeAndConfirm()
        return true
    }

    private func readRecord() throws -> QuickBooksOAuthStateRecord? {
        guard let bytes = try storage.read() else { return nil }
        let record: QuickBooksOAuthStateRecord
        do {
            record = try JSONDecoder().decode(QuickBooksOAuthStateRecord.self, from: bytes)
        } catch {
            throw QuickBooksOAuthStateError.invalidRecord
        }
        try record.validate()
        return record
    }

    private func removeAndConfirm() throws {
        try storage.remove()
        guard try storage.read() == nil else { throw QuickBooksOAuthStateError.removalNotConfirmed }
    }
}
