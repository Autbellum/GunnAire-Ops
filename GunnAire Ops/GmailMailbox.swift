import Foundation
import Combine
import SwiftData

enum GmailMailboxFolder: String, CaseIterable, Identifiable {
    case inbox = "Inbox", sent = "Sent", allMail = "All Mail", trash = "Trash"
    var id: String { rawValue }
    var labelID: String? {
        switch self {
        case .inbox: "INBOX"
        case .sent: "SENT"
        case .trash: "TRASH"
        case .allMail: nil
        }
    }
    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .allMail: "tray.full"
        case .trash: "trash"
        }
    }
    func contains(_ message: GmailMessageDetail) -> Bool {
        let labels = Set(message.labelIds ?? [])
        if self == .trash { return labels.contains("TRASH") }
        guard labels.isDisjoint(with: ["TRASH", "SPAM", "DRAFT"]) else { return false }
        return labelID.map { labels.contains($0) } ?? true
    }
    func correspondent(_ message: GmailMessageDetail) -> String {
        GmailMessagePresentation.headerValue(named: self == .sent ? "To" : "From", in: message)
            ?? (self == .sent ? "Unknown recipient" : "Unknown sender")
    }
}

struct GmailMailboxPage {
    let messages: [GmailMessageDetail]
    let nextPageToken: String?

    static func validToken(_ token: String?) -> Bool {
        guard let token else { return true }
        return !token.isEmpty && token.utf8.count <= 8_192 &&
            !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

enum GmailMailboxAction: CaseIterable {
    case read, unread, archive, trash, restore
    var title: String {
        switch self {
        case .read: "Mark as Read"
        case .unread: "Mark as Unread"
        case .archive: "Archive"
        case .trash: "Move to Trash"
        case .restore: "Restore"
        }
    }
    var confirmation: String {
        switch self {
        case .read: "Message marked as read."
        case .unread: "Message marked as unread."
        case .archive: "Message archived. Find it in All Mail."
        case .trash: "Message moved to Trash."
        case .restore: "Message restored. Find it in All Mail."
        }
    }
    var endpoint: String {
        switch self {
        case .trash: "trash"
        case .restore: "untrash"
        default: "modify"
        }
    }
    var labels: GmailLabelModificationRequest {
        .init(addLabelIds: self == .unread ? ["UNREAD"] : [],
              removeLabelIds: self == .read ? ["UNREAD"] : self == .archive ? ["INBOX"] : [])
    }
    func confirmed(by message: GmailMessageDetail) -> Bool {
        let labels = Set(message.labelIds ?? [])
        switch self {
        case .read: return !labels.contains("UNREAD")
        case .unread: return labels.contains("UNREAD")
        case .archive: return !labels.contains("INBOX") && !labels.contains("TRASH")
        case .trash: return labels.contains("TRASH")
        case .restore: return !labels.contains("TRASH")
        }
    }
}

extension GmailMessageDetail {
    func replacingLabels(_ labels: [String]?) -> Self {
        .init(id: id, threadId: threadId, labelIds: labels, snippet: snippet,
              internalDate: internalDate, payload: payload)
    }
}

/// One mailbox collection, with an independent lifetime for its original
/// business/provider. Refreshing the list does not invalidate an open reply.
@MainActor
final class GmailMailbox: ObservableObject {
    typealias Loader = (GmailMailboxFolder, String, String?, WorkspaceProviderOperation) async throws -> GmailMailboxPage
    typealias Mutator = (GmailMessageDetail, GmailMailboxAction, WorkspaceProviderOperation) async throws -> GmailMessageDetail

    @Published private(set) var messages: [GmailMessageDetail] = []
    @Published private(set) var folder: GmailMailboxFolder = .inbox
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var nextPageToken: String?
    @Published private(set) var busyIDs: Set<String> = []
    @Published var status: String?
    private(set) var provider: WorkspaceProviderOperation?
    private(set) var query = ""
    private var consumedTokens: Set<String> = []
    private var run = UUID()
    private var session = UUID()
    private var loadTask: Task<Void, Never>?
    private var actions: [String: Task<Void, Never>] = [:]
    private let loader: Loader
    private let mutator: Mutator

    init(auth: GoogleAuthManager? = nil, loader: Loader? = nil, mutator: Mutator? = nil) {
        let auth = auth ?? .shared
        self.loader = loader ?? { folder, query, token, operation in
            try await withCheckedThrowingContinuation { continuation in
                auth.fetchGmailMessagePage(folder: folder, query: query, pageToken: token, operation: operation) {
                    continuation.resume(with: $0)
                }
            }
        }
        self.mutator = mutator ?? { message, action, operation in
            try await withCheckedThrowingContinuation { continuation in
                auth.changeGmailMessage(id: message.id, threadID: message.threadId, action: action, operation: operation) {
                    continuation.resume(with: $0)
                }
            }
        }
    }

    static func captureAccess(auth: GoogleAuthManager, context: ModelContext) throws -> WorkspaceProviderOperation {
        let parent = try auth.captureProviderOperation()
        let sender = auth.signedInEmail
        let operation = WorkspaceProviderOperation(parent: parent) {
            let controller = CompanyWorkspaceAccessController.shared
            guard let users = try? context.fetch(FetchDescriptor<AppUser>()),
                  GunnAireCloudKit.usesTestDatabase || controller.authorizedContainer === context.container else { return false }
            let role = GunnAireCloudKit.usesTestDatabase
                ? users.first(where: { AppAccess.normalizedEmail($0.email) == AppAccess.normalizedEmail(sender) })?.role
                : controller.verifiedRole
            return GmailSendWorkflow.allowsMailbox(sender: sender, currentEmail: AppIdentity.currentEmail,
                                                  users: users, verifiedRole: role)
        }
        try operation.check()
        return operation
    }

    @discardableResult
    func refresh(folder: GmailMailboxFolder, query: String, provider: WorkspaceProviderOperation,
                 preservingStatus: Bool = false) -> Task<Void, Never>? {
        guard busyIDs.isEmpty else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.folder != folder || self.query != trimmed || self.provider?.failure != nil {
            messages = []
            hasLoaded = false
            nextPageToken = nil
            consumedTokens = []
        }
        self.folder = folder
        self.query = trimmed
        self.provider = provider
        if !preservingStatus { status = nil }
        return startPage(token: nil)
    }

    @discardableResult
    func loadMore() -> Task<Void, Never>? {
        guard !isLoading, busyIDs.isEmpty, let token = nextPageToken else { return nil }
        status = nil
        return startPage(token: token)
    }

    private func cancelPage() {
        run = UUID()
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    private func startPage(token: String?) -> Task<Void, Never>? {
        cancelPage()
        guard let provider else { return nil }
        let retainedRun = run
        let retainedFolder = folder
        let retainedQuery = query
        let operation = WorkspaceProviderOperation(parent: provider) { [weak self] in self?.run == retainedRun }
        isLoading = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.run == retainedRun { self.isLoading = false; self.loadTask = nil } }
            do {
                try operation.check()
                let page = try await self.loader(retainedFolder, retainedQuery, token, operation)
                try operation.check()
                guard GmailMailboxPage.validToken(page.nextPageToken),
                      page.nextPageToken != token || token == nil,
                      token == nil || page.nextPageToken.map({ !self.consumedTokens.contains($0) }) != false else {
                    throw GoogleAuthError.decoding
                }
                var values = token == nil ? [] : self.messages
                var indices = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.element.id, $0.offset) })
                for message in page.messages {
                    guard GoogleAuthManager.calendarPathComponent(message.id) != nil,
                          let thread = message.threadId, GoogleAuthManager.calendarPathComponent(thread) != nil else {
                        throw GoogleAuthError.decoding
                    }
                    if let index = indices[message.id] {
                        guard values[index].threadId == message.threadId else { throw GoogleAuthError.decoding }
                        // Overlapping pages must not overwrite a newer local read state.
                    } else {
                        indices[message.id] = values.count
                        values.append(message)
                    }
                }
                if token == nil { self.consumedTokens = [] }
                if let token { self.consumedTokens.insert(token) }
                self.messages = values.filter(retainedFolder.contains)
                self.nextPageToken = page.nextPageToken
                self.hasLoaded = true
            } catch {
                guard self.run == retainedRun else { return }
                if provider.failure != nil {
                    self.clear()
                    self.status = "Your Mail access changed. Reopen Mail after verifying your business connection."
                } else if !(error is CancellationError) {
                    self.status = token == nil
                        ? (self.messages.isEmpty ? "Mail couldn't be loaded. Check your connection and refresh to try again."
                           : "Mail couldn't be refreshed. Your loaded messages are still here. Check your connection and try again.")
                        : "Older messages couldn't be loaded. Your place is saved; try again."
                }
            }
        }
        loadTask = task
        return task
    }

    /// Serialize each message action. Folder changes and page reads pause only
    /// while a user-requested change is being confirmed; no optimistic deletion.
    @discardableResult
    func perform(_ action: GmailMailboxAction, on message: GmailMessageDetail,
                 provider originalProvider: WorkspaceProviderOperation? = nil) -> Task<Void, Never>? {
        guard !busyIDs.contains(message.id), let provider = originalProvider ?? provider,
              let existing = messages.first(where: { $0.id == message.id }),
              existing.threadId == message.threadId else { return nil }
        do { try provider.check() }
        catch {
            // An obsolete reader must not clear a replacement connection.
            // A revoked current connection must stop presenting its mailbox.
            if self.provider?.failure != nil {
                clear()
                status = "Your Mail access changed. Reopen Mail after verifying your business connection."
            }
            return nil
        }
        if action == .read && !(existing.labelIds ?? []).contains("UNREAD") { return nil }
        cancelPage()
        let retainedSession = session
        busyIDs.insert(message.id)
        if action != .read { status = nil }
        let operation = WorkspaceProviderOperation(parent: provider) { [weak self] in self?.session == retainedSession }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.session == retainedSession {
                    self.busyIDs.remove(message.id)
                    self.actions[message.id] = nil
                }
            }
            do {
                try operation.check()
                let updated = try await self.mutator(existing, action, operation)
                try operation.check()
                guard updated.id == existing.id, updated.threadId == existing.threadId,
                      action.confirmed(by: updated) else { throw GoogleAuthError.decoding }
                if let index = self.messages.firstIndex(where: { $0.id == existing.id }) {
                    self.messages[index] = self.messages[index].replacingLabels(updated.labelIds)
                    self.messages.removeAll { !self.folder.contains($0) }
                }
                if action != .read { self.status = action.confirmation }
                // A Gmail search may depend on read/label state. Re-query it,
                // rather than attempting to interpret Google's search grammar.
                self.busyIDs.remove(message.id)
                if !self.query.isEmpty && self.busyIDs.isEmpty {
                    self.refresh(folder: self.folder, query: self.query, provider: provider, preservingStatus: true)
                }
            } catch {
                guard self.session == retainedSession else { return }
                if provider.failure != nil {
                    self.clear()
                    self.status = "Your Mail access changed. Check the message in the original account before trying again."
                } else {
                    self.status = "Gmail hasn't confirmed this change. Refresh to check the message before trying again."
                }
            }
        }
        actions[message.id] = task
        return task
    }

    func clear() {
        session = UUID()
        cancelPage()
        for task in actions.values { task.cancel() }
        actions = [:]
        messages = []
        busyIDs = []
        nextPageToken = nil
        consumedTokens = []
        provider = nil
        hasLoaded = false
        status = nil
    }
}
