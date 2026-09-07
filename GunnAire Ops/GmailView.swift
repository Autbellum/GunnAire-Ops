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

    @State private var messages: [GmailMessageDetail] = []
    @State private var isLoading = false
    @State private var statusMessage: String?
    @State private var searchQuery = ""
    @State private var deletingMessageIDs: Set<String> = []
    @State private var activeMailSend: GmailSendWorkflow?
    @State private var mailboxOperation: WorkspaceProviderOperation?
    @State private var mailLoadRun = UUID()
    @State private var composeDraft: GmailDraft?
    @State private var didConsumePendingDraft = false

    private var usesMailUITestFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uiTestSeedMailInbox")
        #else
        false
        #endif
    }

    private var isMailConnected: Bool {
        usesMailUITestFixture || googleAuth.isAuthenticated
    }

    private var canUseGoogleIntegration: Bool {
        usesMailUITestFixture || googleAuth.canUseCurrentBusinessIdentity
    }

    var body: some View {
        NavigationStack {
            List {
                if !isMailConnected {
                    ContentUnavailableView(
                        "Connect Google",
                        systemImage: "envelope",
                        description: Text("Connect your GunnAire Google account in Settings to use Mail.")
                    )
                    .listRowBackground(Color.clear)
                } else if !canUseGoogleIntegration {
                    ContentUnavailableView(
                        "Use Your GunnAire Account",
                        systemImage: "person.crop.circle.badge.xmark",
                        description: Text("Reconnect Google in Settings using the account that matches this business login.")
                    )
                    .listRowBackground(Color.clear)
                } else if isLoading && messages.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Loading mail...")
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if messages.isEmpty {
                    ContentUnavailableView(
                        searchQuery.nilIfBlank == nil ? "Inbox Empty" : "No Results",
                        systemImage: searchQuery.nilIfBlank == nil ? "tray" : "magnifyingglass",
                        description: Text(searchQuery.nilIfBlank == nil ? "New messages will appear here." : "Try a different search.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(messages) { message in
                        NavigationLink {
                            GmailMessageDetailView(
                                message: message,
                                loadsRemoteMessage: !usesMailUITestFixture,
                                provider: mailboxOperation,
                                onReply: { draft in
                                    composeDraft = draft
                                },
                                onDelete: trashMessage,
                                onRead: markMessageRead
                            )
                        } label: {
                            GmailMessageRow(
                                message: message,
                                isDeleting: deletingMessageIDs.contains(message.id)
                            )
                        }
                        .disabled(deletingMessageIDs.contains(message.id))
                        .accessibilityIdentifier("MailMessage-\(message.id)")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                trashMessage(message)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("MailInboxList")
            .navigationTitle("Inbox")
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        loadMessages()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading || !canUseGoogleIntegration)
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
                loadMessages()
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
                    attachmentError: draft.attachmentError
                ) { to, subject, body, attachments in
                    await sendMessage(to: to, subject: subject, body: body, attachments: attachments, draft: draft)
                }
            }
            .onChange(of: composeDraft?.id) { _, value in
                activeMailSend = nil
                if value == nil { applyPendingDraftIfNeeded(force: true) }
            }
            .onChange(of: googleAuth.signedInEmail) { _, _ in clearMailbox() }
            .onChange(of: googleAuth.isAuthenticated) { _, _ in clearMailbox() }
        }
    }

    private func loadMessages(preservingStatus: Bool = false) {
        if usesMailUITestFixture {
            let search = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            messages = search.isEmpty ? Self.uiTestMessages : Self.uiTestMessages.filter { message in
                [
                    GmailMessagePresentation.headerValue(named: "From", in: message),
                    GmailMessagePresentation.headerValue(named: "Subject", in: message),
                    message.snippet
                ]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(search) }
            }
            isLoading = false
            if !preservingStatus {
                statusMessage = nil
            }
            return
        }
        guard canUseGoogleIntegration else {
            statusMessage = googleAuth.isAuthenticated
                ? GoogleAuthError.businessAccountMismatch.localizedDescription
                : "Connect Google in Settings first."
            return
        }

        let run = UUID()
        mailLoadRun = run
        guard let retainedOperation = try? googleAuth.captureProviderOperation() else { return }
        isLoading = true
        if !preservingStatus {
            statusMessage = nil
        }
        googleAuth.fetchGmailMessages(query: GmailMessagePresentation.inboxQuery(searchText: searchQuery)) { result in
            DispatchQueue.main.async {
                guard mailLoadRun == run, (try? retainedOperation.check()) != nil else { return }
                isLoading = false
                switch result {
                case .success(let loadedMessages):
                    mailboxOperation = retainedOperation
                    messages = loadedMessages
                    if !preservingStatus {
                        statusMessage = nil
                    }
                case .failure:
                    messages = []
                    statusMessage = "Mail couldn't be refreshed. Check your Google connection in Settings and try again."
                }
            }
        }
    }

    private func sendMessage(to: String, subject: String, body: String, attachments: [GmailAttachment], draft: GmailDraft) async -> GmailSendOutcome {
        if usesMailUITestFixture {
            if ProcessInfo.processInfo.arguments.contains("-uiTestMailRejectSend") {
                return .notSent(GmailComposeError.recipients)
            }
            if ProcessInfo.processInfo.arguments.contains("-uiTestMailUnconfirmedSend") {
                return .uncertain
            }
            statusMessage = "Message sent."
            return .init(state: .sent, message: "Message sent.")
        }
        do {
            guard draft.attachmentError == nil else { throw GmailComposeError.attachment }
            guard !draft.requiresBusinessContext || draft.businessContext != nil else { throw GmailComposeError.changed }
            if activeMailSend == nil {
                let message = try GmailOutgoingMessage(to: to, subject: subject, body: body,
                                                       attachments: attachments, reply: draft.reply)
                activeMailSend = try GmailSendWorkflow(auth: googleAuth, context: modelContext,
                    message: message, business: draft.businessContext, provider: draft.provider)
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
        mailLoadRun = UUID()
        mailboxOperation = nil
        messages = []
        deletingMessageIDs = []
        isLoading = false
        composeDraft = nil
        statusMessage = nil
    }

    private func markMessageRead(_ message: GmailMessageDetail) {
        guard (message.labelIds ?? []).contains("UNREAD") else { return }
        if usesMailUITestFixture {
            guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
            messages[index] = GmailMessagePresentation.removingUnreadLabel(from: messages[index])
            return
        }
        guard let provider = mailboxOperation, (try? provider.check()) != nil else { return }
        googleAuth.markGmailMessageRead(id: message.id, operation: provider) { result in
            guard case .success = result else { return }
            DispatchQueue.main.async {
                guard (try? provider.check()) != nil,
                      let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
                messages[index] = GmailMessagePresentation.removingUnreadLabel(from: messages[index])
            }
        }
    }

    private func trashMessage(_ message: GmailMessageDetail) {
        guard canUseGoogleIntegration, !deletingMessageIDs.contains(message.id) else { return }
        if usesMailUITestFixture {
            messages.removeAll { $0.id == message.id }
            statusMessage = "Message moved to Trash."
            return
        }
        guard let provider = mailboxOperation, (try? provider.check()) != nil else { return }
        deletingMessageIDs.insert(message.id)
        googleAuth.moveGmailMessageToTrash(id: message.id, operation: provider) { result in
            DispatchQueue.main.async {
                guard (try? provider.check()) != nil else { return }
                deletingMessageIDs.remove(message.id)
                switch result {
                case .success:
                    messages.removeAll { $0.id == message.id }
                    statusMessage = "Message moved to Trash."
                case .failure:
                    statusMessage = "The message couldn't be moved to Trash. Refresh and try again."
                }
            }
        }
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
        let fixtureAttachment = Data("Fixture equipment list.\n".utf8)
        let includesAttachment = ProcessInfo.processInfo.arguments.contains("-uiTestMailAttachments")
        let filePayload = GmailMessagePayload(headers: nil, mimeType: "text/plain",
            body: GmailMessageBody(data: fixtureAttachment.base64EncodedString(), size: fixtureAttachment.count),
            parts: nil, filename: "Equipment.txt")
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
}

private struct GmailMessageRow: View {
    let message: GmailMessageDetail
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
                    Text(GmailMessagePresentation.headerValue(named: "From", in: message) ?? "Unknown sender")
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
                    .accessibilityLabel("Moving message to Trash")
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
    let provider: WorkspaceProviderOperation?
    let onReply: (GmailDraft) -> Void
    let onDelete: (GmailMessageDetail) -> Void
    let onRead: (GmailMessageDetail) -> Void

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
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("MailMoreActionsButton")
            }
        }
        .sheet(item: $previewFile, onDismiss: clearPreview) { file in
            AttachmentPreviewScreen(url: file.url)
        }
        .alert("Move this message to Trash?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                onDelete(activeMessage)
                dismiss()
            }
        } message: {
            Text("You can recover it later from Gmail Trash.")
        }
        .onAppear {
            onRead(message)
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
        let selfEmail = googleAuth.signedInEmail?.lowercased()
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

    let onSend: (String, String, String, [GmailAttachment]) async -> GmailSendOutcome
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
        onSend: @escaping (String, String, String, [GmailAttachment]) async -> GmailSendOutcome
    ) {
        self.onSend = onSend
        _attachments = State(initialValue: attachments)
        self.attachmentError = attachmentError
        _to = State(initialValue: initialTo)
        _subject = State(initialValue: initialSubject)
        _messageBody = State(initialValue: initialMessageBody)
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
                if let message = attachmentError ?? fileImportError ?? sendOutcome?.message {
                    Text(message).font(.footnote).padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial).accessibilityIdentifier("MailComposeStatus")
                }
            }
            .navigationTitle("Compose")
            .interactiveDismissDisabled(isSending || isImportingFiles)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sendOutcome?.state == .reviewRequired ? "Close" : "Cancel") { dismiss() }
                        .disabled(isSending || isImportingFiles)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSending ? "Sending..." : "Send") {
                        guard !isSending else { return }
                        isSending = true
                        Task { @MainActor in
                            fileImportError = nil
                            let result = await onSend(to.trimmingCharacters(in: .whitespacesAndNewlines), subject, messageBody, attachments)
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
}

private struct GmailDraft: Identifiable {
    let id = UUID()
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

    init(
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
