import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum GmailMessagePresentation {
    static func inboxQuery(searchText: String) -> String {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "in:inbox" : "in:inbox \(trimmed)"
    }

    static func headerValue(named name: String, in message: GmailMessageDetail) -> String? {
        message.payload?.headers?
            .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?
            .value
    }

    static func bodyText(from payload: GmailMessagePayload?) -> String? {
        guard let payload else { return nil }
        if let plainText = decodedText(in: payload, matching: "text/plain") {
            return cleaned(plainText)
        }
        if let html = decodedText(in: payload, matching: "text/html") {
            return cleaned(plainText(fromHTML: html))
        }
        if payload.filename?.isEmpty != false, payload.mimeType?.lowercased() == "text/plain",
           let encoded = payload.body?.data, let decoded = decodeBase64URL(encoded) {
            return cleaned(decoded)
        }
        return nil
    }

    static func removingUnreadLabel(from message: GmailMessageDetail) -> GmailMessageDetail {
        GmailMessageDetail(
            id: message.id,
            threadId: message.threadId,
            labelIds: message.labelIds?.filter { $0 != "UNREAD" },
            snippet: message.snippet,
            internalDate: message.internalDate,
            payload: message.payload
        )
    }

    private static func decodedText(in payload: GmailMessagePayload, matching mimeType: String) -> String? {
        guard payload.filename?.isEmpty != false else { return nil }
        if payload.mimeType?.lowercased() == mimeType,
           let encoded = payload.body?.data,
           let decoded = decodeBase64URL(encoded),
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return decoded
        }
        for part in payload.parts ?? [] {
            if let decoded = decodedText(in: part, matching: mimeType) {
                return decoded
            }
        }
        return nil
    }

    private static func decodeBase64URL(_ value: String) -> String? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = normalized.count % 4
        if padding > 0 {
            normalized += String(repeating: "=", count: 4 - padding)
        }
        guard let data = Data(base64Encoded: normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func plainText(fromHTML html: String) -> String {
        html
            .replacingOccurrences(
                of: "(?is)<(?:head|style|script)[^>]*>.*?</(?:head|style|script)>",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
            .replacingOccurrences(
                of: "(?i)<\\s*(br\\s*/?|/p|/div|/li|/tr)\\s*>",
                with: "\n",
                options: .regularExpression
            )
            .replacingOccurrences(of: "(?s)<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func cleaned(_ value: String) -> String? {
        var normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        normalized = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        while normalized.contains("\n\n\n") {
            normalized = normalized.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

struct GmailView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @ObservedObject private var workspace = CompanyWorkspaceAccessController.shared

    @StateObject private var mailbox = Self.makeMailbox()
    @State private var searchQuery = ""
    @State private var activeMailSend: GmailSendWorkflow?
    @State private var composeDraft: GmailDraft?
    @State private var didConsumePendingDraft = false
    @State private var showingDrafts = false
    @State private var savedDrafts: [GmailDraftSummary] = []
    @State private var connectingMail = false
    @State private var needsMailApproval = false
    @State private var mailConnectionRun = UUID()
    @State private var mailConnectionTask: Task<Void, Never>?

    private var messages: [GmailMessageDetail] { mailbox.messages }
    private var isLoading: Bool { mailbox.isLoading }
    private var statusMessage: String? {
        get { mailbox.status }
        nonmutating set { mailbox.status = newValue }
    }

    private var usesMailUITestFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uiTestSeedMailInbox")
        #else
        false
        #endif
    }
    private var usesServerMailFixture: Bool {
        #if DEBUG
        GmailServerMailFixture.enabled
        #else
        false
        #endif
    }
    private func captureMailProvider() async throws -> WorkspaceProviderOperation {
        #if DEBUG
        if usesServerMailFixture { return try GmailServerMailFixture.provider() }
        #endif
        return try await GmailServerMail.capture(context: modelContext)
    }

    private var isMailConnected: Bool {
        usesMailUITestFixture || !needsMailApproval
    }

    private var canUseGoogleIntegration: Bool {
        usesMailUITestFixture || (workspace.authorizedContainer === modelContext.container &&
                                  (workspace.verifiedRole == .admin || workspace.verifiedRole == .dispatcher))
    }

    var body: some View {
        NavigationStack {
            List {
                if showingDrafts && canUseGoogleIntegration {
                    if savedDrafts.isEmpty {
                        ContentUnavailableView("No Saved Drafts", systemImage: "doc",
                            description: Text("Messages you save on this device appear here."))
                            .listRowBackground(Color.clear)
                    }
                    ForEach(savedDrafts.filter { searchQuery.isEmpty || ($0.subject + " " + $0.recipient).localizedCaseInsensitiveContains(searchQuery) }) { draft in
                        Button { openSavedDraft(draft.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(draft.subject.isEmpty ? "(No subject)" : draft.subject).font(.headline).lineLimit(1)
                                Text(draft.recipient.isEmpty ? "No recipient yet" : draft.recipient).font(.subheadline).lineLimit(1)
                                if draft.state != .editing { Text("Check Sent before sending another copy").font(.caption).foregroundStyle(.secondary) }
                            }.foregroundStyle(.primary).padding(.vertical, 4)
                        }.accessibilityIdentifier("MailSavedDraft-\(draft.id.uuidString)")
                    }
                } else if !isMailConnected {
                    ContentUnavailableView(
                        "Connect Mail",
                        systemImage: "envelope",
                        description: Text("Approve shared Mail access for this business login, then return to your inbox.")
                    )
                    .listRowBackground(Color.clear)
                    NavigationLink("Google Access") { GoogleServerAccessView(context: modelContext) }
                        .accessibilityIdentifier("MailGoogleAccessLink")
                } else if !canUseGoogleIntegration {
                    ContentUnavailableView(
                        "Mail Access Required",
                        systemImage: "person.crop.circle.badge.xmark",
                        description: Text("The office mailbox is available to approved office staff. Job-related messages remain available from the work you can access.")
                    )
                    .listRowBackground(Color.clear)
                } else if (isLoading || connectingMail) && messages.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Loading mail...")
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if !mailbox.hasLoaded && messages.isEmpty {
                    ContentUnavailableView("Mail Unavailable", systemImage: "envelope.badge",
                        description: Text("Refresh to load this mailbox."))
                        .listRowBackground(Color.clear)
                } else if messages.isEmpty {
                    ContentUnavailableView(
                        mailbox.nextPageToken != nil ? "No Messages on This Page" : mailbox.query.isEmpty ? "\(mailbox.folder.rawValue) Empty" : "No Results",
                        systemImage: searchQuery.nilIfBlank == nil ? "tray" : "magnifyingglass",
                        description: Text(mailbox.nextPageToken != nil ? "Load older messages to continue."
                            : mailbox.query.isEmpty ? "Messages in this mailbox will appear here." : "Try a different search.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(messages) { message in
                        NavigationLink {
                            GmailMessageDetailView(
                                message: message,
                                loadsRemoteMessage: !usesMailUITestFixture || usesServerMailFixture,
                                provider: mailbox.provider,
                                mailbox: mailbox,
                                onReply: { draft in
                                    composeDraft = draft
                                }
                            )
                        } label: {
                            GmailMessageRow(
                                message: message,
                                folder: mailbox.folder,
                                isDeleting: mailbox.busyIDs.contains(message.id)
                            )
                        }
                        .disabled(mailbox.busyIDs.contains(message.id))
                        .accessibilityIdentifier("MailMessage-\(message.id)")
                        .swipeActions(edge: .trailing) {
                            if mailbox.folder == .trash {
                                Button { mailbox.perform(.restore, on: message) } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }.tint(.blue)
                            } else {
                                Button(role: .destructive) { trashMessage(message) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                mailbox.perform((message.labelIds ?? []).contains("UNREAD") ? .read : .unread, on: message)
                            } label: {
                                Label((message.labelIds ?? []).contains("UNREAD") ? "Mark as Read" : "Mark as Unread", systemImage: "envelope")
                            }.tint(.blue)
                            if mailbox.folder == .inbox {
                                Button { mailbox.perform(.archive, on: message) } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }.tint(.gray)
                            }
                        }
                    }
                }
                if !showingDrafts && mailbox.nextPageToken != nil && isMailConnected && canUseGoogleIntegration {
                    Button { mailbox.loadMore() } label: {
                        HStack {
                            Spacer()
                            if isLoading { ProgressView("Loading older messages…") }
                            else { Text("Load Older Messages") }
                            Spacer()
                        }.padding(.vertical, 8)
                    }
                    .disabled(isLoading || !mailbox.busyIDs.isEmpty)
                    .accessibilityIdentifier("MailLoadOlderButton")
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("MailInboxList")
            .navigationTitle(showingDrafts ? "Drafts" : mailbox.folder.rawValue)
            .searchable(text: $searchQuery, prompt: "Search mail")
            .safeAreaInset(edge: .bottom) {
                if let statusMessage, !statusMessage.isEmpty {
                    HStack(spacing: 12) {
                        Text(statusMessage)
                            .font(.footnote)
                        Spacer()
                        Button {
                            self.statusMessage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss mail status")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Menu {
                        Picker("Mailbox", selection: Binding(get: { mailbox.folder }, set: { loadMessages(folder: $0) })) {
                            ForEach(GmailMailboxFolder.allCases) { folder in
                                Label(folder.rawValue, systemImage: folder.symbol).tag(folder)
                            }
                        }
                        .disabled(!canUseGoogleIntegration || !mailbox.busyIDs.isEmpty)
                        Button("Drafts on This Device", systemImage: "doc") { loadDrafts() }
                            .disabled(!canUseGoogleIntegration || !mailbox.busyIDs.isEmpty)
                            .accessibilityIdentifier("MailDraftsButton")
                        if let provider = mailbox.provider, provider.serverMail != nil {
                            NavigationLink("Outbox", destination: GmailServerOutboxView(provider: provider))
                                .accessibilityIdentifier("MailOutboxButton")
                            Button("Check Mail Changes", systemImage: "arrow.clockwise") {
                                Task { @MainActor in
                                    do {
                                        let remaining = try await provider.serverMail!.recoverActions(operation: provider)
                                        statusMessage = remaining == 0 ? "Mail changes checked." : "Some changes still need confirmation. The original requests have been kept."
                                        loadMessages(preservingStatus: true)
                                    } catch { statusMessage = GmailServerMailError.safe(error).localizedDescription }
                                }
                            }
                        }
                    } label: {
                        Label("Mailboxes", systemImage: "tray.2")
                    }
                    .accessibilityIdentifier("MailFoldersButton")
                    Button {
                        if showingDrafts { loadDrafts() } else { loadMessages() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading || connectingMail || !canUseGoogleIntegration || !mailbox.busyIDs.isEmpty)
                    .accessibilityIdentifier("MailRefreshButton")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        composeDraft = GmailDraft(to: "", subject: "", body: "", threadID: nil, attachments: [])
                    } label: {
                        Label("Compose", systemImage: "square.and.pencil")
                    }
                    .disabled(!canUseGoogleIntegration)
                    .accessibilityIdentifier("MailComposeButton")
                }
            }
            .onAppear {
                if canUseGoogleIntegration && messages.isEmpty {
                    loadMessages()
                }
                applyPendingDraftIfNeeded()
            }
            .onSubmit(of: .search) {
                if showingDrafts { loadDrafts() } else { loadMessages() }
            }
            .onChange(of: searchQuery) { oldValue, newValue in
                if !showingDrafts, !oldValue.isEmpty && newValue.isEmpty { loadMessages() }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GunnAireRouteDidChange"))) { _ in
                applyPendingDraftIfNeeded(force: true)
            }
            .sheet(item: $composeDraft) { draft in
                GmailComposeView(
                    initialTo: draft.to,
                    initialSubject: draft.subject,
                    initialMessageBody: draft.body,
                    attachments: draft.attachments,
                    attachmentError: draft.attachmentError,
                    template: draft.content,
                    makeSession: { try makeDraftSession(draft, content: $0) },
                    onReviewSent: { loadMessages(folder: .sent) },
                    onRecover: { journal, cancel in
                        do {
                            let provider = try await captureMailProvider()
                            let result = try await journal.recoverServer(provider: provider, cancelUnsent: cancel)
                            if result.canRetry { activeMailSend = nil }
                            return result
                        } catch {
                            return .init(state: .reviewRequired, message: GmailServerMailError.safe(error).localizedDescription)
                        }
                    }
                ) { to, subject, body, attachments, journal in
                    await sendMessage(to: to, subject: subject, body: body, attachments: attachments, draft: draft, journal: journal)
                }
            }
            .onChange(of: composeDraft?.id) { _, value in
                activeMailSend = nil
                if value == nil {
                    if showingDrafts { loadDrafts() }
                    applyPendingDraftIfNeeded(force: true)
                }
            }
            .onChange(of: googleAuth.signedInEmail) { _, _ in if mailbox.provider?.serverMail == nil { clearMailbox() } }
            .onChange(of: googleAuth.isAuthenticated) { _, _ in if mailbox.provider?.serverMail == nil { clearMailbox() } }
            .onChange(of: workspace.operationStamp) { _, _ in
                if !usesMailUITestFixture { clearMailbox() }
            }
        }
    }

    private func loadMessages(folder: GmailMailboxFolder? = nil, preservingStatus: Bool = false) {
        guard mailbox.busyIDs.isEmpty else {
            statusMessage = "Wait for the message change to finish, then try again."
            return
        }
        guard canUseGoogleIntegration else {
            statusMessage = "Verify your business login and Mail access before opening this mailbox."
            return
        }
        if !usesMailUITestFixture || usesServerMailFixture {
            mailConnectionTask?.cancel()
            let run = UUID(); mailConnectionRun = run; connectingMail = true
            mailConnectionTask = Task { @MainActor in
                defer { if mailConnectionRun == run { connectingMail = false; mailConnectionTask = nil } }
                do {
                    let provider = try await captureMailProvider()
                    guard mailConnectionRun == run else { return }
                    try provider.check()
                    needsMailApproval = false; showingDrafts = false
                    mailbox.refresh(folder: folder ?? mailbox.folder, query: searchQuery, provider: provider, preservingStatus: preservingStatus)
                } catch {
                    guard mailConnectionRun == run, !(error is CancellationError) else { return }
                    mailbox.clear()
                    needsMailApproval = (error as? GmailServerMailError) == .connect
                    statusMessage = GmailServerMailError.safe(error).localizedDescription
                }
            }
            return
        }
        do {
            showingDrafts = false
            let provider = try usesMailUITestFixture ? WorkspaceProviderOperation { true }
                : GmailMailbox.captureAccess(auth: googleAuth, context: modelContext)
            mailbox.refresh(folder: folder ?? mailbox.folder, query: searchQuery,
                            provider: provider, preservingStatus: preservingStatus)
        } catch {
            mailbox.clear()
            statusMessage = "Verify your Mail access and Google connection in Settings, then refresh."
        }
    }

    private func sendMessage(to: String, subject: String, body: String, attachments: [GmailAttachment], draft: GmailDraft, journal: GmailDraftSession) async -> GmailSendOutcome {
        if usesMailUITestFixture && !usesServerMailFixture {
            do { try journal.begin() } catch { return .notSent(error) }
            let result: GmailSendOutcome
            if ProcessInfo.processInfo.arguments.contains("-uiTestMailRejectSend") {
                result = .notSent(GmailComposeError.recipients)
            } else if ProcessInfo.processInfo.arguments.contains("-uiTestMailUnconfirmedSend") { result = .uncertain }
            else { result = .init(state: .sent, message: "Message sent.") }
            do { try journal.finish(result) } catch { return .uncertain }
            return result
        }
        do {
            guard draft.attachmentError == nil else { throw GmailComposeError.attachment }
            guard !draft.requiresBusinessContext || draft.businessContext != nil else { throw GmailComposeError.changed }
            if activeMailSend == nil {
                let message = try GmailOutgoingMessage(to: to, subject: subject, body: body,
                                                       attachments: attachments, reply: draft.reply)
                var content = journal.record.content
                content.to = message.to; content.reply = message.reply
                try journal.save(content)
                let provider: WorkspaceProviderOperation?
                if draft.businessContext == nil {
                    if let original = draft.provider { try original.check(); provider = original }
                    else { provider = try await captureMailProvider() }
                } else {
                    // Domain messages keep the job/billing/consent-authorized
                    // device workflow until its server domain gate is available.
                    guard googleAuth.canUseCurrentBusinessIdentity else { throw GmailComposeError.access }
                    provider = draft.provider
                }
                #if DEBUG
                let fixtureAccess: (() throws -> Void)? = usesServerMailFixture ? {} : nil
                #else
                let fixtureAccess: (() throws -> Void)? = nil
                #endif
                activeMailSend = try GmailSendWorkflow(auth: googleAuth, context: modelContext,
                    message: message, business: draft.businessContext, provider: provider, validateAccess: fixtureAccess, journal: journal)
            }
            guard let workflow = activeMailSend else { throw GmailComposeError.changed }
            let result = await workflow.send()
            if result.canRetry { activeMailSend = nil }
            if result.state == .sent {
                statusMessage = result.message
                loadMessages(preservingStatus: true)
            }
            return result
        } catch { return .notSent(error) }
    }

    private func clearMailbox() {
        mailConnectionRun = UUID(); mailConnectionTask?.cancel(); mailConnectionTask = nil; connectingMail = false
        mailbox.clear()
        savedDrafts = []; showingDrafts = false
        composeDraft = nil
    }

    private func draftScope() throws -> GmailDraftScope {
        #if DEBUG
        if usesMailUITestFixture {
            return .init(companyID: UUID(uuidString: "3BF63F8D-C536-4BC2-826B-EF5CA1B1C9DA")!, backendOrigin: "https://fixture.example.invalid",
                actorEmail: "mail-fixture@gunnaire.com", googleEmail: "mail-fixture@gunnaire.com")
        }
        #endif
        return try GmailDraftScope.captureCompany(context: modelContext)
    }

    private var draftStore: GmailDraftStore {
        #if DEBUG
        if usesMailUITestFixture {
            let id = ProcessInfo.processInfo.environment["GUNNAIRE_MAIL_DRAFT_FIXTURE"].flatMap(UUID.init(uuidString:)) ?? Self.fixtureDraftID
            return .encrypted(directory: FileManager.default.temporaryDirectory.appendingPathComponent("MailDraftFixture-" + id.uuidString)) { _ in Data(repeating: 71, count: 32) }
        }
        #endif
        return .device
    }
    #if DEBUG
    private static let fixtureDraftID = UUID()
    #endif

    private func validateDraftAccess(_ scope: GmailDraftScope, business: GmailBusinessContext?) throws {
        guard try draftScope() == scope else { throw GmailDraftError.access }
        if !usesMailUITestFixture {
            try GmailSendWorkflow.requireAccess(context: modelContext, business: business, sender: scope.actorEmail)
        }
    }

    private func makeDraftSession(_ draft: GmailDraft, content: GmailDraftContent) throws -> GmailDraftSession {
        let scope = try draftScope()
        var content = content
        if draft.savedRecord == nil {
            content.businessSnapshot = try GmailDraftBusinessSnapshot.capture(content.business, context: modelContext)
        }
        let record = draft.savedRecord ?? GmailDraftRecord(id: draft.id, scope: scope, content: content)
        guard record.scope == scope else { throw GmailDraftError.access }
        return try GmailDraftSession(record: record, store: draftStore) {
            try validateDraftAccess(scope, business: record.content.business)
        }
    }

    private func loadDrafts() {
        do {
            let scope = try draftScope()
            try validateDraftAccess(scope, business: nil)
            savedDrafts = try draftStore.list(scope).filter { (try? validateDraftAccess(scope, business: $0.business)) != nil }
            showingDrafts = true
            statusMessage = nil
        } catch {
            savedDrafts = []
            statusMessage = (error as? LocalizedError)?.errorDescription ?? GmailDraftError.storage.localizedDescription
        }
    }

    private func openSavedDraft(_ id: UUID) {
        do {
            let scope = try draftScope()
            guard let record = try draftStore.read(scope, id), record.state != .sent, record.state != .discarded else { throw GmailDraftError.changed }
            try validateDraftAccess(scope, business: record.content.business)
            composeDraft = GmailDraft(record: record)
        } catch { statusMessage = (error as? LocalizedError)?.errorDescription ?? GmailDraftError.storage.localizedDescription }
    }

    private func trashMessage(_ message: GmailMessageDetail) {
        mailbox.perform(.trash, on: message)
    }

    private func applyPendingDraftIfNeeded(force: Bool = false) {
        guard composeDraft == nil, force || !didConsumePendingDraft else { return }
        didConsumePendingDraft = true
        guard let draft = GunnAireAppIntentRouter.consumePendingMailDraft() else { return }
        let attachmentResult = Result { try GmailOutgoingMessage.attachments(paths: draft.attachmentPaths) }
        composeDraft = GmailDraft(
            to: draft.to,
            subject: draft.subject,
            body: draft.body,
            threadID: nil,
            attachments: (try? attachmentResult.get()) ?? [],
            attachmentError: attachmentResult.failureDescription,
            customerID: draft.customerID,
            serviceCallID: draft.serviceCallID,
            invoiceID: draft.invoiceID,
            estimateID: draft.estimateID,
            maintenanceContractID: draft.maintenanceContractID,
            workflow: draft.workflow
        )
    }

    private static func makeMailbox() -> GmailMailbox {
        #if DEBUG
        if GmailServerMailFixture.enabled { return GmailMailbox() }
        if ProcessInfo.processInfo.arguments.contains("-uiTestSeedMailInbox") {
            var fixtures = uiTestMessages
            if ProcessInfo.processInfo.arguments.contains("-uiTestMailMailbox") {
                let base = fixtures[0]
                fixtures.append(.init(id: "ui-mail-older", threadId: "ui-thread-older", labelIds: ["INBOX"],
                    snippet: "Previous equipment visit.", internalDate: "1788000000000",
                    payload: .init(headers: [.init(name: "From", value: "Previous Customer"),
                        .init(name: "Subject", value: "Earlier service visit")], mimeType: "text/plain",
                        body: .init(data: Data("Older service history.".utf8).base64EncodedString(), size: 22), parts: nil, filename: nil)))
                fixtures.append(.init(id: "ui-mail-sent", threadId: "ui-thread-sent", labelIds: ["SENT"],
                    snippet: "Your repair estimate is attached.", internalDate: base.internalDate,
                    payload: .init(headers: [.init(name: "From", value: "GunnAire Service"),
                        .init(name: "To", value: "Taylor Customer"), .init(name: "Subject", value: "Repair estimate sent")],
                        mimeType: "text/plain", body: .init(data: Data("Estimate follow-up.".utf8).base64EncodedString(), size: 19), parts: nil, filename: nil)))
            }
            return GmailMailbox(loader: { folder, query, token, operation in
                try operation.check()
                let filtered = fixtures.filter(folder.contains).filter { message in
                    query.isEmpty || ["From", "To", "Subject"].compactMap {
                        GmailMessagePresentation.headerValue(named: $0, in: message)
                    }.joined(separator: " ").localizedCaseInsensitiveContains(query)
                }
                let offset = token.flatMap(Int.init) ?? 0
                let next = offset + 1
                return .init(messages: Array(filtered.dropFirst(offset).prefix(1)),
                             nextPageToken: next < filtered.count ? String(next) : nil)
            }, mutator: { message, action, operation in
                try operation.check()
                guard let index = fixtures.firstIndex(where: { $0.id == message.id }) else { throw GoogleAuthError.noData }
                var labels = Set(fixtures[index].labelIds ?? [])
                switch action {
                case .read: labels.remove("UNREAD")
                case .unread: labels.insert("UNREAD")
                case .archive: labels.remove("INBOX")
                case .trash: labels.insert("TRASH")
                case .restore: labels.remove("TRASH")
                }
                fixtures[index] = fixtures[index].replacingLabels(Array(labels).sorted())
                return fixtures[index]
            })
        }
        #endif
        return GmailMailbox()
    }

    #if DEBUG
    private static var uiTestMessages: [GmailMessageDetail] {
        let html = "<div>Your service appointment is confirmed.</div><p>We will see you Tuesday morning.</p>"
        let encodedHTML = Data(html.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let headers = [
            GmailMessageHeader(name: "From", value: "Jordan Customer <jordan@example.com>"),
            GmailMessageHeader(name: "To", value: "service@gunnaire.com"),
            GmailMessageHeader(name: "Subject", value: "Service appointment confirmed"),
            GmailMessageHeader(name: "Date", value: "Tue, 3 Sep 2026 9:30:00 -0400"),
            GmailMessageHeader(name: "MIME-Version", value: "1.0"),
            GmailMessageHeader(name: "Content-Type", value: "text/html; charset=UTF-8")
        ]
        let textPayload = GmailMessagePayload(headers: nil, mimeType: "text/html",
            body: GmailMessageBody(data: encodedHTML, size: html.utf8.count), parts: nil, filename: nil)
        let fixtureAttachment = MailAttachmentPreviewFixture.attachment
        let includesAttachment = ProcessInfo.processInfo.arguments.contains("-uiTestMailAttachments")
        let filePayload = GmailMessagePayload(headers: nil, mimeType: fixtureAttachment.mimeType,
            body: GmailMessageBody(data: fixtureAttachment.data.base64EncodedString(), size: fixtureAttachment.data.count),
            parts: nil, filename: fixtureAttachment.fileName)
        return [
            GmailMessageDetail(
                id: "ui-mail-1",
                threadId: "ui-thread-1",
                labelIds: ["INBOX", "UNREAD"],
                snippet: "Your service appointment is confirmed. We will see you Tuesday morning.",
                internalDate: "1788442200000",
                payload: GmailMessagePayload(
                    headers: headers,
                    mimeType: includesAttachment ? "multipart/mixed" : "text/html",
                    body: includesAttachment ? nil : textPayload.body,
                    parts: includesAttachment ? [filePayload, textPayload] : nil,
                    filename: nil
                )
            )
        ]
    }
    #endif
}

private struct GmailMessageRow: View {
    let message: GmailMessageDetail
    let folder: GmailMailboxFolder
    let isDeleting: Bool

    private var isUnread: Bool {
        (message.labelIds ?? []).contains("UNREAD")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isUnread ? Color.brandGold : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 7)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(folder.correspondent(message))
                        .font(.headline)
                        .fontWeight(isUnread ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    if let formattedDate {
                        Text(formattedDate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(GmailMessagePresentation.headerValue(named: "Subject", in: message) ?? "(No subject)")
                    .fontWeight(isUnread ? .semibold : .regular)
                    .lineLimit(1)

                if let snippet = message.snippet?.trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty {
                    Text(snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if isDeleting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating message")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isUnread ? "Unread" : "Read")
    }

    private var formattedDate: String? {
        guard let internalDate = message.internalDate, let timestamp = Double(internalDate) else { return nil }
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct GmailPreviewFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct GmailMessageDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    let message: GmailMessageDetail
    let loadsRemoteMessage: Bool
    @State private var provider: WorkspaceProviderOperation?
    @ObservedObject var mailbox: GmailMailbox
    let onReply: (GmailDraft) -> Void

    init(message: GmailMessageDetail, loadsRemoteMessage: Bool, provider: WorkspaceProviderOperation?,
         mailbox: GmailMailbox, onReply: @escaping (GmailDraft) -> Void) {
        self.message = message
        self.loadsRemoteMessage = loadsRemoteMessage
        _provider = State(initialValue: provider)
        _mailbox = ObservedObject(wrappedValue: mailbox)
        self.onReply = onReply
    }

    @State private var loadedMessage: GmailMessageDetail?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var showingDeleteConfirmation = false
    @State private var attachmentTask: Task<Void, Never>?
    @State private var attachmentRun = UUID()
    @State private var isPreparingAttachment = false
    @State private var attachmentStatus: String?
    @State private var previewFile: GmailPreviewFile?
    @State private var previewCleanupURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(GmailMessagePresentation.headerValue(named: "Subject", in: activeMessage) ?? "(No subject)")
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)

                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.brandGold.opacity(0.2))
                        Text(senderInitial)
                            .font(.headline)
                            .foregroundStyle(Color.brandGold)
                    }
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(GmailMessagePresentation.headerValue(named: "From", in: activeMessage) ?? "Unknown sender")
                            .font(.headline)
                            .textSelection(.enabled)
                        if let recipient = GmailMessagePresentation.headerValue(named: "To", in: activeMessage), !recipient.isEmpty {
                            Text("To: \(recipient)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: 12)
                    if let formattedDate {
                        Text(formattedDate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Divider()

                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView("Loading message...")
                        Spacer()
                    }
                    .padding(.vertical, 32)
                } else if loadFailed {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The full message couldn't be loaded.")
                            .foregroundColor(.secondary)
                        Button("Try Again") {
                            loadMessageIfNeeded(force: true)
                        }
                    }
                } else if let bodyText = extractedBody {
                    Text(bodyText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else {
                    Text("This message has no text content.")
                        .foregroundStyle(.secondary)
                }
                if canReadFullMessage { attachmentSection }
                if isPreparingAttachment { ProgressView("Preparing attachments…") }
                if let attachmentStatus {
                    Text(attachmentStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("MailAttachmentStatus")
                }
            }
            .padding()
        }
        .navigationTitle("Mail")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    onReply(makeReplyDraft())
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                .accessibilityIdentifier("MailReplyButton")
                .disabled(!canReadFullMessage || isPreparingAttachment)

                Menu {
                    Button {
                        onReply(makeReplyAllDraft())
                    } label: {
                        Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                    }
                    .disabled(!canReadFullMessage || isPreparingAttachment)
                    Button {
                        prepareAttachments(forward: true)
                    } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
                    .disabled(!canReadFullMessage || isPreparingAttachment)
                    Divider()
                    Button {
                        mailbox.perform(.unread, on: activeMessage, provider: provider)
                        dismiss()
                    } label: { Label("Mark as Unread", systemImage: "envelope.badge") }
                    if mailbox.folder == .inbox {
                        Button {
                            mailbox.perform(.archive, on: activeMessage, provider: provider)
                            dismiss()
                        } label: { Label("Archive", systemImage: "archivebox") }
                    }
                    if mailbox.folder == .trash {
                        Button {
                            mailbox.perform(.restore, on: activeMessage, provider: provider)
                            dismiss()
                        } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    } else {
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: { Label("Move to Trash", systemImage: "trash") }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("MailMoreActionsButton")
                .disabled(mailbox.busyIDs.contains(message.id))
            }
        }
        .sheet(item: $previewFile, onDismiss: clearPreview) { file in
            AttachmentPreviewScreen(url: file.url)
        }
        .alert("Move this message to Trash?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                mailbox.perform(.trash, on: activeMessage, provider: provider)
                dismiss()
            }
        } message: {
            Text("You can recover it later from Mailboxes → Trash.")
        }
        .onAppear {
            mailbox.perform(.read, on: message, provider: provider)
            if loadsRemoteMessage {
                loadMessageIfNeeded()
            }
        }
        .onDisappear {
            attachmentTask?.cancel()
            attachmentRun = UUID()
            isPreparingAttachment = false
            if previewFile == nil { clearPreview() }
        }
        .onChange(of: googleAuth.signedInEmail) { _, _ in
            attachmentTask?.cancel()
            attachmentRun = UUID()
            previewFile = nil
            clearPreview()
            if loadsRemoteMessage { dismiss() }
        }
        .onChange(of: googleAuth.isAuthenticated) { _, connected in
            if loadsRemoteMessage && !connected { dismiss() }
        }
    }

    private var canReadFullMessage: Bool {
        !isLoading && !loadFailed && (!loadsRemoteMessage || loadedMessage != nil)
    }

    @ViewBuilder private var attachmentSection: some View {
        switch Result(catching: { try GmailAttachmentLoader.parts(in: activeMessage.payload) }) {
        case .success(let parts):
            if !parts.isEmpty {
                Divider()
                Text("Attachments").font(.headline)
                ForEach(parts) { part in
                    Button {
                        prepareAttachments(forward: false, selected: part)
                    } label: {
                        HStack {
                            Image(systemName: "doc")
                            Text(part.fileName).lineLimit(2)
                            Spacer()
                            if let size = part.body.size, size >= 0 {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("MailAttachment-\(part.id)")
                    .disabled(isPreparingAttachment)
                }
            }
        case .failure:
            Text("Attachments could not be read. Try loading this message again before forwarding.")
                .foregroundStyle(.secondary)
        }
    }

    private func prepareAttachments(forward: Bool, selected: GmailAttachmentPart? = nil) {
        guard canReadFullMessage, !isPreparingAttachment else { return }
        let retainedMessage = activeMessage
        let run = UUID()
        attachmentRun = run
        isPreparingAttachment = true
        attachmentStatus = nil
        attachmentTask = Task { @MainActor in
            defer { if attachmentRun == run { isPreparingAttachment = false } }
            do {
                let parts = try selected.map { [$0] } ?? GmailAttachmentLoader.parts(in: retainedMessage.payload)
                let attachments: [GmailAttachment]
                if loadsRemoteMessage {
                    guard let provider else { throw GmailComposeError.changed }
                    attachments = try await GmailAttachmentLoader.load(parts, messageID: retainedMessage.id,
                        auth: googleAuth, operation: provider)
                    try provider.check()
                } else {
                    attachments = try GmailAttachmentLoader.inlineAttachments(parts)
                }
                try Task.checkCancellation()
                guard attachmentRun == run, activeMessage.id == retainedMessage.id else { return }
                if forward {
                    onReply(makeForwardDraft(attachments: attachments))
                } else if let attachment = attachments.first {
                    clearPreview()
                    let url = try GmailAttachmentLoader.previewFile(for: attachment)
                    previewCleanupURL = url
                    previewFile = GmailPreviewFile(url: url)
                }
            } catch {
                guard !Task.isCancelled, attachmentRun == run else { return }
                attachmentStatus = "The attachments couldn't be loaded. No files were forwarded. Try again after checking your Google connection."
            }
        }
    }

    private func clearPreview() {
        if let url = previewCleanupURL { GmailAttachmentLoader.removePreviewFile(url) }
        previewCleanupURL = nil
    }

    private var activeMessage: GmailMessageDetail {
        loadedMessage ?? message
    }

    private var extractedBody: String? {
        GmailMessagePresentation.bodyText(from: activeMessage.payload)
    }

    private var senderInitial: String {
        let sender = GmailMessagePresentation.headerValue(named: "From", in: activeMessage) ?? "?"
        return String(sender.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
    }

    private var formattedDate: String? {
        guard let internalDate = activeMessage.internalDate, let timestamp = Double(internalDate) else { return nil }
        return Date(timeIntervalSince1970: timestamp / 1000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private func loadMessageIfNeeded(force: Bool = false) {
        guard (force || loadedMessage == nil), !isLoading else { return }
        if force {
            loadedMessage = nil
        }
        loadFailed = false
        isLoading = true
        guard let provider, (try? provider.check()) != nil else { isLoading = false; loadFailed = true; return }
        googleAuth.fetchGmailMessage(id: message.id, operation: provider) { result in
            Task { @MainActor in
                defer { isLoading = false }
                do {
                    try provider.check()
                    let fullMessage = try result.get()
                    guard fullMessage.id == message.id, fullMessage.threadId == message.threadId else {
                        throw GoogleAuthError.decoding
                    }
                    let resolved = try await GmailAttachmentLoader.loadingTextBodies(in: fullMessage,
                        auth: googleAuth, operation: provider)
                    try provider.check()
                    loadedMessage = resolved
                } catch {
                    loadFailed = true
                }
            }
        }
    }

    private func makeReplyDraft() -> GmailDraft {
        let sender = GmailMessagePresentation.headerValue(named: "Reply-To", in: activeMessage) ??
            GmailMessagePresentation.headerValue(named: "From", in: activeMessage) ?? ""
        let extractedEmail = (try? GmailAddressList.parse(sender).joined(separator: ", ")) ?? sender
        let subject = GmailMessagePresentation.headerValue(named: "Subject", in: activeMessage) ?? ""
        let replySubject = subject
        let bodyText = extractedBody ?? activeMessage.snippet ?? ""
        let quoted = bodyText.isEmpty ? "" : "\n\n--- Original Message ---\n\(bodyText)"
        return GmailDraft(
            to: extractedEmail,
            subject: replySubject,
            body: quoted,
            threadID: activeMessage.threadId,
            attachments: [],
            reply: GmailReplyContext.from(activeMessage),
            provider: provider
        )
    }

    private func makeReplyAllDraft() -> GmailDraft {
        let selfEmail = (provider?.serverMail?.scope.company.actorEmail ?? googleAuth.signedInEmail)?.lowercased()
        let senderValues = parseAddresses(from: GmailMessagePresentation.headerValue(named: "Reply-To", in: activeMessage) ??
            GmailMessagePresentation.headerValue(named: "From", in: activeMessage))
        let toValues = parseAddresses(from: GmailMessagePresentation.headerValue(named: "To", in: activeMessage))
        let ccValues = parseAddresses(from: GmailMessagePresentation.headerValue(named: "Cc", in: activeMessage))
        let uniqueRecipients = Array(Set((senderValues + toValues + ccValues).filter { $0.lowercased() != selfEmail }))
            .sorted()
        let subject = GmailMessagePresentation.headerValue(named: "Subject", in: activeMessage) ?? ""
        let replySubject = subject
        let bodyText = extractedBody ?? activeMessage.snippet ?? ""
        let quoted = bodyText.isEmpty ? "" : "\n\n--- Original Message ---\n\(bodyText)"
        return GmailDraft(
            to: uniqueRecipients.joined(separator: ", "),
            subject: replySubject,
            body: quoted,
            threadID: activeMessage.threadId,
            attachments: [],
            reply: GmailReplyContext.from(activeMessage),
            provider: provider
        )
    }

    private func makeForwardDraft(attachments: [GmailAttachment]) -> GmailDraft {
        let subject = GmailMessagePresentation.headerValue(named: "Subject", in: activeMessage) ?? ""
        let forwardSubject = subject.lowercased().hasPrefix("fwd:") ? subject : "Fwd: \(subject)"
        let bodyText = extractedBody ?? activeMessage.snippet ?? ""
        let sender = GmailMessagePresentation.headerValue(named: "From", in: activeMessage) ?? ""
        let originalDate = GmailMessagePresentation.headerValue(named: "Date", in: activeMessage) ?? ""
        let quoted = [
            "",
            "",
            "---------- Forwarded message ---------",
            "From: \(sender)",
            "Date: \(originalDate)",
            "Subject: \(subject)",
            "To: \(GmailMessagePresentation.headerValue(named: "To", in: activeMessage) ?? "")",
            "",
            bodyText
        ].joined(separator: "\n")
        return GmailDraft(
            to: "",
            subject: forwardSubject,
            body: quoted,
            threadID: nil,
            attachments: attachments,
            provider: provider
        )
    }

    private func parseAddresses(from value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return (try? GmailAddressList.parse(value)) ?? [value]
    }

}

private struct GmailComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let onSend: (String, String, String, [GmailAttachment], GmailDraftSession) async -> GmailSendOutcome
    let template: GmailDraftContent
    let makeSession: (GmailDraftContent) throws -> GmailDraftSession
    let onReviewSent: () -> Void
    let onRecover: (GmailDraftSession, Bool) async -> GmailSendOutcome
    @State private var journal: GmailDraftSession?
    @State private var draftError: String?
    @State private var confirmsClose = false
    @State private var saveRevision = 0
    @State private var savedContent: GmailDraftContent?
    @State private var attachments: [GmailAttachment]
    let attachmentError: String?
    @State private var isSending = false
    @State private var sendOutcome: GmailSendOutcome?
    @State private var showingFileImporter = false
    @State private var fileImportError: String?
    @State private var isImportingFiles = false

    @State private var to: String
    @State private var subject: String
    @State private var messageBody: String

    init(
        initialTo: String = "",
        initialSubject: String = "",
        initialMessageBody: String = "",
        attachments: [GmailAttachment] = [],
        attachmentError: String? = nil,
        template: GmailDraftContent,
        makeSession: @escaping (GmailDraftContent) throws -> GmailDraftSession,
        onReviewSent: @escaping () -> Void,
        onRecover: @escaping (GmailDraftSession, Bool) async -> GmailSendOutcome,
        onSend: @escaping (String, String, String, [GmailAttachment], GmailDraftSession) async -> GmailSendOutcome
    ) {
        self.onSend = onSend
        self.template = template
        self.makeSession = makeSession
        self.onReviewSent = onReviewSent
        self.onRecover = onRecover
        _attachments = State(initialValue: attachments)
        self.attachmentError = attachmentError
        _to = State(initialValue: initialTo)
        _subject = State(initialValue: initialSubject)
        _messageBody = State(initialValue: initialMessageBody)
    }

    private var content: GmailDraftContent {
        var value = template
        value.to = to; value.subject = subject; value.body = messageBody
        value.files = attachments.map { GmailDraftFile($0) }
        value.businessSnapshot = journal?.record.content.businessSnapshot ?? template.businessSnapshot
        return value
    }

    @discardableResult private func persist() -> Bool {
        do {
            if journal == nil { journal = try makeSession(content) }
            guard let journal else { throw GmailDraftError.storage }
            try journal.verify()
            if !journal.record.editable {
                sendOutcome = .init(state: .reviewRequired, message: journal.record.status ?? GmailDraftError.locked.localizedDescription)
                return true
            }
            if journal.record.content != content { try journal.save(content) }
            savedContent = content
            draftError = nil
            return true
        } catch {
            draftError = (error as? LocalizedError)?.errorDescription ?? GmailDraftError.storage.localizedDescription
            return false
        }
    }

    private func closeSaving() {
        guard persist() else { return }
        dismiss()
    }

    private func discard() {
        do {
            // Discard is explicit; do not require invalid/oversize unsaved
            // input to be saved before the user can leave it.
            try journal?.discard()
            dismiss()
        } catch { draftError = (error as? LocalizedError)?.errorDescription ?? GmailDraftError.storage.localizedDescription }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("To", text: $to)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("MailComposeTo")
                TextField("Subject", text: $subject)
                    .accessibilityIdentifier("MailComposeSubject")
                TextField("Message", text: $messageBody, axis: .vertical)
                    .lineLimit(8...16)
                    .accessibilityIdentifier("MailComposeBody")
                Section {
                    Button("Attach Files", systemImage: "paperclip") { showingFileImporter = true }
                        .accessibilityIdentifier("MailAttachFilesButton")
                    if isImportingFiles { ProgressView("Attaching files…") }
                    if !attachments.isEmpty {
                        ForEach(attachments) { attachment in
                            HStack {
                                Image(systemName: "paperclip")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attachment.fileName)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Remove attachment", systemImage: "xmark.circle") {
                                    attachments.removeAll { $0.id == attachment.id }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(attachment.fileName)")
                            }
                        }
                    }
                }
            }
            .disabled(isSending || isImportingFiles || sendOutcome?.state == .reviewRequired)
            .safeAreaInset(edge: .bottom) {
                if let message = attachmentError ?? fileImportError ?? draftError ?? sendOutcome?.message {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(message).font(.footnote).accessibilityIdentifier("MailComposeStatus")
                        if sendOutcome?.state == .reviewRequired {
                            if let journal, journal.record.serverAttempt != nil {
                                Button("Check Sending Status") { recover(cancel: false) }
                                    .disabled(isSending).accessibilityIdentifier("MailCheckSendingStatus")
                                if journal.serverCanCancel {
                                    Button("Cancel Unsent Request") { recover(cancel: true) }
                                        .disabled(isSending).accessibilityIdentifier("MailCancelUnsentRequest")
                                }
                            }
                            Button("Open Sent", systemImage: "paperplane") {
                                do {
                                    try journal?.verify()
                                    dismiss(); onReviewSent()
                                } catch { draftError = GmailDraftError.access.localizedDescription }
                            }.accessibilityIdentifier("MailReviewSentButton")
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.thinMaterial)
                } else if content.hasContent {
                    Text(savedContent == content ? "Draft saved on this device." : "Saving draft…")
                        .font(.footnote).foregroundStyle(.secondary).padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("MailDraftSaveStatus")
                }
            }
            .navigationTitle("Compose")
            .interactiveDismissDisabled(true)
            .onAppear { persist() }
            .onChange(of: content) { _, _ in saveRevision += 1 }
            .task(id: saveRevision) {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard !isSending, !isImportingFiles, sendOutcome?.state != .reviewRequired else { return }
                persist()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active, !isSending, !isImportingFiles { persist() }
            }
            .confirmationDialog("Save this draft?", isPresented: $confirmsClose, titleVisibility: .visible) {
                Button("Save Draft") { closeSaving() }
                Button("Delete Draft", role: .destructive) { discard() }
                Button("Keep Editing", role: .cancel) { }
            } message: {
                Text("Saved drafts stay on this device. Sending is always a separate action.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sendOutcome?.state == .reviewRequired ? "Close" : "Cancel") {
                        if sendOutcome?.state == .reviewRequired { dismiss() }
                        else if content.hasContent { confirmsClose = true }
                        else { discard() }
                    }
                        .disabled(isSending || isImportingFiles)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSending ? "Sending..." : "Send") {
                        guard !isSending, persist(), let journal, journal.record.editable else { return }
                        isSending = true
                        Task { @MainActor in
                            fileImportError = nil
                            let result = await onSend(to.trimmingCharacters(in: .whitespacesAndNewlines), subject, messageBody, attachments, journal)
                            sendOutcome = result
                            isSending = false
                            if result.state == .sent { dismiss() }
                        }
                    }
                    .disabled(isSending || isImportingFiles || attachmentError != nil || sendOutcome?.state == .reviewRequired ||
                              to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              (messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                               subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))
                    .accessibilityIdentifier("MailSendButton")
                }
            }
            .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard !isSending, !isImportingFiles, sendOutcome?.state != .reviewRequired else { return }
                isImportingFiles = true
                Task { @MainActor in
                    defer { isImportingFiles = false }
                    do {
                        attachments = try await GmailOutgoingMessage.importingFiles(result.get(), to: attachments)
                        fileImportError = nil
                    } catch {
                        fileImportError = "No new files were attached. Your existing attachments are unchanged. Choose readable files, up to 50 files and 25 MB total."
                    }
                }
            }
        }
    }

    private func recover(cancel: Bool) {
        guard let journal, !isSending else { return }
        isSending = true
        Task { @MainActor in
            let outcome = await onRecover(journal, cancel)
            sendOutcome = outcome; isSending = false
            if outcome.state == .sent { dismiss(); onReviewSent() }
        }
    }
}

private struct GmailDraft: Identifiable {
    let id: UUID
    var savedRecord: GmailDraftRecord?
    let to: String
    let subject: String
    let body: String
    let threadID: String?
    let attachments: [GmailAttachment]
    let attachmentError: String?
    let reply: GmailReplyContext?
    let provider: WorkspaceProviderOperation?
    let customerID: UUID?
    let serviceCallID: UUID?
    let invoiceID: UUID?
    let estimateID: UUID?
    let maintenanceContractID: UUID?
    let workflow: GunnAireMailWorkflow

    var requiresBusinessContext: Bool {
        customerID != nil || workflow != .general || serviceCallID != nil || invoiceID != nil ||
        estimateID != nil || maintenanceContractID != nil
    }
    var businessContext: GmailBusinessContext? {
        customerID.map { GmailBusinessContext(customerID: $0, serviceCallID: serviceCallID,
            invoiceID: invoiceID, estimateID: estimateID, maintenanceContractID: maintenanceContractID, workflow: workflow) }
    }
    var content: GmailDraftContent {
        .init(to: to, subject: subject, body: body, files: attachments.map { GmailDraftFile($0) },
            reply: reply, business: businessContext, requiresBusinessContext: savedRecord?.content.requiresBusinessContext ?? requiresBusinessContext,
            attachmentError: attachmentError, businessSnapshot: savedRecord?.content.businessSnapshot)
    }

    init(record: GmailDraftRecord) {
        let value = record.content
        self.init(id: record.id, to: value.to, subject: value.subject, body: value.body, threadID: value.reply?.threadID,
            attachments: value.files.map(\.attachment), attachmentError: value.attachmentError,
            reply: value.reply, customerID: value.business?.customerID, serviceCallID: value.business?.serviceCallID,
            invoiceID: value.business?.invoiceID, estimateID: value.business?.estimateID,
            maintenanceContractID: value.business?.maintenanceContractID, workflow: value.business?.workflow ?? .general)
        savedRecord = record
    }

    init(
        id: UUID = UUID(),
        to: String,
        subject: String,
        body: String,
        threadID: String?,
        attachments: [GmailAttachment],
        attachmentError: String? = nil,
        reply: GmailReplyContext? = nil,
        provider: WorkspaceProviderOperation? = nil,
        customerID: UUID? = nil,
        serviceCallID: UUID? = nil,
        invoiceID: UUID? = nil,
        estimateID: UUID? = nil,
        maintenanceContractID: UUID? = nil,
        workflow: GunnAireMailWorkflow = .general
    ) {
        self.id = id
        self.to = to
        self.subject = subject
        self.body = body
        self.threadID = threadID
        self.attachments = attachments
        self.attachmentError = attachmentError
        self.reply = reply
        self.provider = provider ?? (try? GoogleAuthManager.shared.captureProviderOperation())
        self.customerID = customerID
        self.serviceCallID = serviceCallID
        self.invoiceID = invoiceID
        self.estimateID = estimateID
        self.maintenanceContractID = maintenanceContractID
        self.workflow = workflow
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Result {
    var failureDescription: String? {
        if case .failure = self { return GmailComposeError.attachment.localizedDescription }
        return nil
    }
}
