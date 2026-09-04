import Foundation
import SwiftUI
import SwiftData

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
        if let encoded = payload.body?.data, let decoded = decodeBase64URL(encoded) {
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
    @Query(sort: \Customer.name, order: .forward) private var customers: [Customer]
    @Query private var estimates: [Estimate]
    @Query private var invoices: [Invoice]
    @Query private var serviceCalls: [ServiceCall]
    @Query private var recurringContracts: [RecurringMaintenanceContract]

    @State private var messages: [GmailMessageDetail] = []
    @State private var isLoading = false
    @State private var statusMessage: String?
    @State private var searchQuery = ""
    @State private var deletingMessageIDs: Set<String> = []
    @State private var showingComposeSheet = false
    @State private var composeDraft: GmailDraft?
    @State private var didConsumePendingDraft = false

    private var usesMailUITestFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestSeedMailInbox")
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
                        showingComposeSheet = true
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
                    attachments: draft.attachments
                ) { to, subject, body in
                    sendMessage(to: to, subject: subject, body: body, threadID: draft.threadID, attachments: draft.attachments, auditDraft: draft)
                }
            }
            .sheet(isPresented: $showingComposeSheet) {
                GmailComposeView { to, subject, body in
                    sendMessage(to: to, subject: subject, body: body, threadID: nil, attachments: [], auditDraft: nil)
                }
            }
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

        isLoading = true
        if !preservingStatus {
            statusMessage = nil
        }
        googleAuth.fetchGmailMessages(query: GmailMessagePresentation.inboxQuery(searchText: searchQuery)) { result in
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let loadedMessages):
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

    private func sendMessage(to: String, subject: String, body: String, threadID: String?, attachments: [GmailAttachment], auditDraft: GmailDraft?) {
        if usesMailUITestFixture {
            statusMessage = "Message sent."
            return
        }
        guard canUseGoogleIntegration else {
            statusMessage = GoogleAuthError.businessAccountMismatch.localizedDescription
            return
        }
        let recipient = AppAccess.normalizedEmail(to)
        let linkedCustomer = auditDraft?.customerID.flatMap { customerID in
            customers.first { $0.id == customerID }
        } ?? customers.first { AppAccess.normalizedEmail($0.email) == recipient }
        if let auditDraft {
            guard let linkedCustomer else {
                statusMessage = "Email was not sent because its customer record is no longer available. Open the record and draft it again."
                return
            }
            let expectedRecipient = AppAccess.normalizedEmail(linkedCustomer.email)
            guard !expectedRecipient.isEmpty, recipient == expectedRecipient else {
                statusMessage = "Email was not sent because the recipient no longer matches the linked customer. Return to the customer or job and draft it again."
                return
            }
            guard CustomerCommunicationWorkflow.contextIsValid(
                workflow: auditDraft.workflow,
                customerID: auditDraft.customerID,
                serviceCallID: auditDraft.serviceCallID,
                invoiceID: auditDraft.invoiceID,
                estimateID: auditDraft.estimateID,
                maintenanceContractID: auditDraft.maintenanceContractID,
                estimates: estimates,
                invoices: invoices,
                serviceCalls: serviceCalls,
                recurringContracts: recurringContracts
            ) else {
                statusMessage = "Email was not sent because the linked job, agreement, estimate, or invoice changed. Return to that record and draft it again."
                return
            }
            let consentAllowed = auditDraft.workflow.requiresMarketingConsent
                ? linkedCustomer.allowsMarketing
                : linkedCustomer.allowsTransactionalEmail
            if !consentAllowed {
                recordCustomerCommunicationAttempt(
                    from: auditDraft,
                    customer: linkedCustomer,
                    to: to,
                    subject: subject,
                    attachments: attachments,
                    deliveryStatus: "suppressed",
                    providerMessageID: nil,
                    providerStatusDetail: auditDraft.workflow.requiresMarketingConsent
                        ? "Marketing preference is off."
                        : "Transactional email preference is off."
                )
                statusMessage = auditDraft.workflow.requiresMarketingConsent
                    ? "Email was not sent because \(linkedCustomer.name)'s marketing preference is off."
                    : "Email was not sent because \(linkedCustomer.name)'s service and billing email preference is off. Update Contact Preferences before sending."
                return
            }
        } else if let linkedCustomer, !linkedCustomer.allowsTransactionalEmail {
            statusMessage = "Email was not sent because \(linkedCustomer.name)'s service and billing email preference is off. Update Contact Preferences in the customer record before sending."
            return
        }
        statusMessage = "Sending message..."
        googleAuth.sendGmailMessage(to: to, subject: subject, body: body, threadID: threadID, attachments: attachments) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let sentMessage):
                    if let auditDraft,
                       let customerID = auditDraft.customerID,
                       let linkedCustomer = customers.first(where: { $0.id == customerID }) {
                        recordCustomerCommunicationAttempt(
                            from: auditDraft,
                            customer: linkedCustomer,
                            to: to,
                            subject: subject,
                            attachments: attachments,
                            deliveryStatus: "sent",
                            providerMessageID: sentMessage.id,
                            providerStatusDetail: nil
                        )
                    }
                    statusMessage = "Message sent."
                    loadMessages(preservingStatus: true)
                case .failure(let error):
                    if let auditDraft,
                       let customerID = auditDraft.customerID,
                       let linkedCustomer = customers.first(where: { $0.id == customerID }) {
                        recordCustomerCommunicationAttempt(
                            from: auditDraft,
                            customer: linkedCustomer,
                            to: to,
                            subject: subject,
                            attachments: attachments,
                            deliveryStatus: "failed",
                            providerMessageID: nil,
                            providerStatusDetail: error.localizedDescription
                        )
                    }
                    statusMessage = "The message couldn't be sent. Check your connection and try again."
                }
            }
        }
    }

    private func markMessageRead(_ message: GmailMessageDetail) {
        guard (message.labelIds ?? []).contains("UNREAD") else { return }
        if usesMailUITestFixture {
            guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
            messages[index] = GmailMessagePresentation.removingUnreadLabel(from: messages[index])
            return
        }
        googleAuth.markGmailMessageRead(id: message.id) { result in
            guard case .success = result else { return }
            DispatchQueue.main.async {
                guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
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
        deletingMessageIDs.insert(message.id)
        googleAuth.moveGmailMessageToTrash(id: message.id) { result in
            DispatchQueue.main.async {
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
        guard force || !didConsumePendingDraft else { return }
        didConsumePendingDraft = true
        guard let draft = GunnAireAppIntentRouter.consumePendingMailDraft() else { return }
        composeDraft = GmailDraft(
            to: draft.to,
            subject: draft.subject,
            body: draft.body,
            threadID: nil,
            attachments: attachments(from: draft.attachmentPaths),
            customerID: draft.customerID,
            serviceCallID: draft.serviceCallID,
            invoiceID: draft.invoiceID,
            estimateID: draft.estimateID,
            maintenanceContractID: draft.maintenanceContractID,
            workflow: draft.workflow
        )
    }

    private func recordCustomerCommunicationAttempt(
        from draft: GmailDraft,
        customer: Customer,
        to: String,
        subject: String,
        attachments: [GmailAttachment],
        deliveryStatus: String,
        providerMessageID: String?,
        providerStatusDetail: String?
    ) {
        let now = Date()
        let communication = CustomerCommunication(
            customer: customer,
            serviceCallID: draft.serviceCallID,
            invoiceID: draft.invoiceID,
            estimateID: draft.estimateID,
            maintenanceContractID: draft.maintenanceContractID,
            recipient: to,
            subject: subject,
            deliveryStatus: deliveryStatus,
            workflow: draft.workflow,
            actorEmail: googleAuth.signedInEmail,
            consentSnapshot: CustomerCommunicationConsentSnapshot(customer: customer),
            providerStatusDetail: providerStatusDetail,
            deliveredAt: deliveryStatus == "sent" ? now : nil,
            attachmentFileNames: attachments.map(\.fileName),
            providerMessageID: providerMessageID,
            createdAt: now
        )
        modelContext.insert(communication)
        if deliveryStatus == "sent" {
            CustomerCommunicationWorkflow.applyConfirmedSend(
                workflow: draft.workflow,
                customerID: draft.customerID,
                serviceCallID: draft.serviceCallID,
                invoiceID: draft.invoiceID,
                estimateID: draft.estimateID,
                maintenanceContractID: draft.maintenanceContractID,
                estimates: estimates,
                invoices: invoices,
                serviceCalls: serviceCalls,
                recurringContracts: recurringContracts,
                now: now,
                actorEmail: googleAuth.signedInEmail,
                in: modelContext
            )
        }
        try? modelContext.save()
        guard GunnAireBackendService.isConfigured else { return }
        Task {
            do {
                let remote = try await GunnAireBackendService.uploadCustomerCommunication(communication)
                communication.markSharedCompanySynced(id: remote.id)
            } catch {
                communication.markSharedCompanySyncFailed(error.localizedDescription)
            }
            try? modelContext.save()
        }
    }

    private func attachments(from paths: [String]) -> [GmailAttachment] {
        paths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return GmailAttachment(
                fileName: url.lastPathComponent,
                mimeType: QuickBooksDataAPI.mimeType(for: url),
                data: data
            )
        }
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
        return [
            GmailMessageDetail(
                id: "ui-mail-1",
                threadId: "ui-thread-1",
                labelIds: ["INBOX", "UNREAD"],
                snippet: "Your service appointment is confirmed. We will see you Tuesday morning.",
                internalDate: "1788442200000",
                payload: GmailMessagePayload(
                    headers: headers,
                    mimeType: "text/html",
                    body: GmailMessageBody(data: encodedHTML, size: html.utf8.count),
                    parts: nil,
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

private struct GmailMessageDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    let message: GmailMessageDetail
    let loadsRemoteMessage: Bool
    let onReply: (GmailDraft) -> Void
    let onDelete: (GmailMessageDetail) -> Void
    let onRead: (GmailMessageDetail) -> Void

    @State private var loadedMessage: GmailMessageDetail?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var showingDeleteConfirmation = false

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
                } else if let bodyText = extractedBody {
                    Text(bodyText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else if loadFailed {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The full message couldn't be loaded.")
                            .foregroundColor(.secondary)
                        Button("Try Again") {
                            loadMessageIfNeeded(force: true)
                        }
                    }
                } else {
                    Text("This message has no text content.")
                        .foregroundStyle(.secondary)
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

                Menu {
                    Button {
                        onReply(makeReplyAllDraft())
                    } label: {
                        Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                    }
                    Button {
                        onReply(makeForwardDraft())
                    } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
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
        googleAuth.fetchGmailMessage(id: message.id) { result in
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let fullMessage):
                    loadedMessage = fullMessage
                case .failure:
                    loadFailed = true
                }
            }
        }
    }

    private func makeReplyDraft() -> GmailDraft {
        let sender = GmailMessagePresentation.headerValue(named: "From", in: activeMessage) ?? ""
        let extractedEmail = extractEmailAddress(from: sender) ?? sender
        let subject = GmailMessagePresentation.headerValue(named: "Subject", in: activeMessage) ?? ""
        let replySubject = subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
        let bodyText = extractedBody ?? activeMessage.snippet ?? ""
        let quoted = bodyText.isEmpty ? "" : "\n\n--- Original Message ---\n\(bodyText)"
        return GmailDraft(
            to: extractedEmail,
            subject: replySubject,
            body: quoted,
            threadID: activeMessage.threadId,
            attachments: []
        )
    }

    private func makeReplyAllDraft() -> GmailDraft {
        let selfEmail = googleAuth.signedInEmail?.lowercased()
        let senderValues = parseAddresses(from: GmailMessagePresentation.headerValue(named: "From", in: activeMessage))
        let toValues = parseAddresses(from: GmailMessagePresentation.headerValue(named: "To", in: activeMessage))
        let ccValues = parseAddresses(from: GmailMessagePresentation.headerValue(named: "Cc", in: activeMessage))
        let uniqueRecipients = Array(Set((senderValues + toValues + ccValues).filter { $0.lowercased() != selfEmail }))
            .sorted()
        let subject = GmailMessagePresentation.headerValue(named: "Subject", in: activeMessage) ?? ""
        let replySubject = subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
        let bodyText = extractedBody ?? activeMessage.snippet ?? ""
        let quoted = bodyText.isEmpty ? "" : "\n\n--- Original Message ---\n\(bodyText)"
        return GmailDraft(
            to: uniqueRecipients.joined(separator: ", "),
            subject: replySubject,
            body: quoted,
            threadID: activeMessage.threadId,
            attachments: []
        )
    }

    private func makeForwardDraft() -> GmailDraft {
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
            attachments: []
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

}

private struct GmailComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let onSend: (String, String, String) -> Void
    let attachments: [GmailAttachment]

    @State private var to: String
    @State private var subject: String
    @State private var messageBody: String

    init(
        initialTo: String = "",
        initialSubject: String = "",
        initialMessageBody: String = "",
        attachments: [GmailAttachment] = [],
        onSend: @escaping (String, String, String) -> Void
    ) {
        self.onSend = onSend
        self.attachments = attachments
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
                if !attachments.isEmpty {
                    Section("Attachments") {
                        ForEach(attachments) { attachment in
                            HStack {
                                Image(systemName: "paperclip")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attachment.fileName)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
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
                    .accessibilityIdentifier("MailSendButton")
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
    let customerID: UUID?
    let serviceCallID: UUID?
    let invoiceID: UUID?
    let estimateID: UUID?
    let maintenanceContractID: UUID?
    let workflow: GunnAireMailWorkflow

    init(
        to: String,
        subject: String,
        body: String,
        threadID: String?,
        attachments: [GmailAttachment],
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
