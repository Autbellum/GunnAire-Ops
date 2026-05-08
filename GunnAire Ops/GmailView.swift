import SwiftUI

struct GmailView: View {
    @ObservedObject private var googleAuth = GoogleAuthManager.shared

    @State private var messages: [GmailMessageDetail] = []
    @State private var isLoading = false
    @State private var statusMessage: String?
    @State private var searchQuery = ""
    @State private var selectedMessage: GmailMessageDetail?
    @State private var showingComposeSheet = false
    @State private var composeDraft: GmailDraft?
    @State private var didConsumePendingDraft = false

    var body: some View {
        NavigationStack {
            List {
                Section("Mailbox") {
                    if !googleAuth.isAuthenticated {
                        Text("Connect Google in Settings before using Mail.")
                            .foregroundColor(.secondary)
                    } else if isLoading {
                        ProgressView("Loading mail...")
                    } else if messages.isEmpty {
                        Text("No messages loaded.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(messages) { message in
                            Button {
                                selectedMessage = message
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(headerValue(named: "Subject", in: message) ?? "(No Subject)")
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(headerValue(named: "From", in: message) ?? "Unknown sender")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    if let snippet = message.snippet, !snippet.isEmpty {
                                        Text(snippet)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                    HStack {
                                        if let date = formattedDate(for: message) {
                                            Text(date)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        if (message.labelIds ?? []).contains("UNREAD") {
                                            Text("Unread")
                                                .font(.caption2)
                                                .foregroundColor(Color.brandGold)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let statusMessage, !statusMessage.isEmpty {
                    Section("Status") {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Mail")
            .searchable(text: $searchQuery, prompt: "Search Gmail")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        loadMessages()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading || !googleAuth.isAuthenticated)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingComposeSheet = true
                    } label: {
                        Label("Compose", systemImage: "square.and.pencil")
                    }
                    .disabled(!googleAuth.isAuthenticated)
                }
            }
            .onAppear {
                if googleAuth.isAuthenticated && messages.isEmpty {
                    loadMessages()
                }
                applyPendingDraftIfNeeded()
            }
            .onSubmit(of: .search) {
                loadMessages()
            }
            .sheet(item: $selectedMessage) { message in
                GmailMessageDetailView(message: message) { draft in
                    composeDraft = draft
                }
            }
            .sheet(item: $composeDraft) { draft in
                GmailComposeView(
                    initialTo: draft.to,
                    initialSubject: draft.subject,
                    initialMessageBody: draft.body
                ) { to, subject, body in
                    sendMessage(to: to, subject: subject, body: body, threadID: draft.threadID)
                }
            }
            .sheet(isPresented: $showingComposeSheet) {
                GmailComposeView { to, subject, body in
                    sendMessage(to: to, subject: subject, body: body, threadID: nil)
                }
            }
        }
    }

    private func loadMessages() {
        guard googleAuth.isAuthenticated else {
            statusMessage = "Connect Google in Settings first."
            return
        }

        isLoading = true
        statusMessage = "Loading Gmail..."
        googleAuth.fetchGmailMessages(query: searchQuery.nilIfBlank) { result in
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let loadedMessages):
                    messages = loadedMessages
                    statusMessage = "Loaded \(loadedMessages.count) messages."
                case .failure(let error):
                    messages = []
                    statusMessage = "Mail sync failed: \(error.localizedDescription). Disconnect and reconnect Google if Gmail permission was just added."
                }
            }
        }
    }

    private func sendMessage(to: String, subject: String, body: String, threadID: String?) {
        statusMessage = "Sending message..."
        googleAuth.sendGmailMessage(to: to, subject: subject, body: body, threadID: threadID) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    statusMessage = "Message sent."
                    loadMessages()
                case .failure(let error):
                    statusMessage = "Send failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func applyPendingDraftIfNeeded() {
        guard !didConsumePendingDraft else { return }
        didConsumePendingDraft = true
        guard let draft = GunnAireAppIntentRouter.consumePendingMailDraft() else { return }
        composeDraft = GmailDraft(
            to: draft.to,
            subject: draft.subject,
            body: draft.body,
            threadID: nil
        )
    }

    private func headerValue(named name: String, in message: GmailMessageDetail) -> String? {
        message.payload?.headers?.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    private func formattedDate(for message: GmailMessageDetail) -> String? {
        guard let internalDate = message.internalDate,
              let timestamp = Double(internalDate) else {
            return nil
        }
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct GmailMessageDetailView: View {
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    let message: GmailMessageDetail
    let onReply: (GmailDraft) -> Void

    @State private var loadedMessage: GmailMessageDetail?
    @State private var threadMessages: [GmailMessageDetail] = []
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Headers") {
                    ForEach(activeMessage.payload?.headers ?? [], id: \.name) { header in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(header.name)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(header.value)
                        }
                    }
                }

                Section("Snippet") {
                    Text(activeMessage.snippet ?? "No preview available.")
                }

                if isLoading {
                    Section("Message Body") {
                        ProgressView("Loading message...")
                    }
                } else if let bodyText = extractedBody, !bodyText.isEmpty {
                    Section("Message Body") {
                        Text(bodyText)
                            .textSelection(.enabled)
                    }
                }

                if let loadError, !loadError.isEmpty {
                    Section("Load Error") {
                        Text(loadError)
                            .foregroundColor(.secondary)
                    }
                }

                if !threadMessages.isEmpty {
                    Section("Thread") {
                        ForEach(threadMessages) { threadMessage in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(headerValue(named: "From", in: threadMessage) ?? "Unknown sender")
                                    .font(.headline)
                                if let bodyText = decodeBody(from: threadMessage.payload), !bodyText.isEmpty {
                                    Text(bodyText)
                                        .font(.caption)
                                        .lineLimit(8)
                                } else {
                                    Text(threadMessage.snippet ?? "No preview available.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Message")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu("Reply") {
                        Button("Reply") {
                            onReply(makeReplyDraft())
                        }
                        Button("Reply All") {
                            onReply(makeReplyAllDraft())
                        }
                        Button("Forward") {
                            onReply(makeForwardDraft())
                        }
                    }
                }
            }
            .onAppear(perform: loadMessageIfNeeded)
        }
    }

    private var activeMessage: GmailMessageDetail {
        loadedMessage ?? message
    }

    private var extractedBody: String? {
        decodeBody(from: activeMessage.payload)
    }

    private func loadMessageIfNeeded() {
        guard loadedMessage == nil, !isLoading else { return }
        isLoading = true
        googleAuth.fetchGmailMessage(id: message.id) { result in
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let fullMessage):
                    loadedMessage = fullMessage
                    loadThreadIfNeeded(from: fullMessage)
                case .failure(let error):
                    loadError = error.localizedDescription
                }
            }
        }
    }

    private func decodeBody(from payload: GmailMessagePayload?) -> String? {
        guard let payload else { return nil }
        if let data = payload.body?.data,
           let decoded = decodeBase64URL(data),
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return decoded
        }
        for part in payload.parts ?? [] {
            if let nested = decodeBody(from: part),
               !nested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nested
            }
        }
        return nil
    }

    private func headerValue(named name: String, in message: GmailMessageDetail) -> String? {
        message.payload?.headers?.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    private func loadThreadIfNeeded(from message: GmailMessageDetail) {
        guard threadMessages.isEmpty, let threadID = message.threadId, !threadID.isEmpty else { return }
        googleAuth.fetchGmailThread(id: threadID) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let messages):
                    threadMessages = messages
                case .failure:
                    break
                }
            }
        }
    }

    private func makeReplyDraft() -> GmailDraft {
        let sender = headerValue(named: "From", in: activeMessage) ?? ""
        let extractedEmail = extractEmailAddress(from: sender) ?? sender
        let subject = headerValue(named: "Subject", in: activeMessage) ?? ""
        let replySubject = subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
        let bodyText = extractedBody ?? activeMessage.snippet ?? ""
        let quoted = bodyText.isEmpty ? "" : "\n\n--- Original Message ---\n\(bodyText)"
        return GmailDraft(
            to: extractedEmail,
            subject: replySubject,
            body: quoted,
            threadID: activeMessage.threadId
        )
    }

    private func makeReplyAllDraft() -> GmailDraft {
        let selfEmail = googleAuth.signedInEmail?.lowercased()
        let senderValues = parseAddresses(from: headerValue(named: "From", in: activeMessage))
        let toValues = parseAddresses(from: headerValue(named: "To", in: activeMessage))
        let ccValues = parseAddresses(from: headerValue(named: "Cc", in: activeMessage))
        let uniqueRecipients = Array(Set((senderValues + toValues + ccValues).filter { $0.lowercased() != selfEmail }))
            .sorted()
        let subject = headerValue(named: "Subject", in: activeMessage) ?? ""
        let replySubject = subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
        let bodyText = extractedBody ?? activeMessage.snippet ?? ""
        let quoted = bodyText.isEmpty ? "" : "\n\n--- Original Message ---\n\(bodyText)"
        return GmailDraft(
            to: uniqueRecipients.joined(separator: ", "),
            subject: replySubject,
            body: quoted,
            threadID: activeMessage.threadId
        )
    }

    private func makeForwardDraft() -> GmailDraft {
        let subject = headerValue(named: "Subject", in: activeMessage) ?? ""
        let forwardSubject = subject.lowercased().hasPrefix("fwd:") ? subject : "Fwd: \(subject)"
        let bodyText = extractedBody ?? activeMessage.snippet ?? ""
        let sender = headerValue(named: "From", in: activeMessage) ?? ""
        let originalDate = headerValue(named: "Date", in: activeMessage) ?? ""
        let quoted = [
            "",
            "",
            "---------- Forwarded message ---------",
            "From: \(sender)",
            "Date: \(originalDate)",
            "Subject: \(subject)",
            "To: \(headerValue(named: "To", in: activeMessage) ?? "")",
            "",
            bodyText
        ].joined(separator: "\n")
        return GmailDraft(
            to: "",
            subject: forwardSubject,
            body: quoted,
            threadID: nil
        )
    }

    private func extractEmailAddress(from value: String) -> String? {
        guard let start = value.firstIndex(of: "<"),
              let end = value.firstIndex(of: ">"),
              start < end else {
            return nil
        }
        return String(value[value.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseAddresses(from value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value
            .split(separator: ",")
            .map { part in
                let string = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                return extractEmailAddress(from: string) ?? string
            }
            .filter { !$0.isEmpty }
    }

    private func decodeBase64URL(_ value: String) -> String? {
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
}

private struct GmailComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let onSend: (String, String, String) -> Void

    @State private var to: String
    @State private var subject: String
    @State private var messageBody: String

    init(
        initialTo: String = "",
        initialSubject: String = "",
        initialMessageBody: String = "",
        onSend: @escaping (String, String, String) -> Void
    ) {
        self.onSend = onSend
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
                TextField("Subject", text: $subject)
                TextField("Message", text: $messageBody, axis: .vertical)
                    .lineLimit(8...16)
            }
            .navigationTitle("Compose")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        onSend(to.trimmingCharacters(in: .whitespacesAndNewlines), subject, messageBody)
                        dismiss()
                    }
                    .disabled(to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
