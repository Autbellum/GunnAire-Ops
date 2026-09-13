import SwiftUI
import Combine

@MainActor final class GmailServerOutbox: ObservableObject {
    @Published private(set) var items: [GmailServerMail.OutboxItem] = []
    @Published private(set) var nextPageToken: String?
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    let provider: WorkspaceProviderOperation
    private var tokens: Set<String> = []
    private var open = true

    init(provider: WorkspaceProviderOperation) { self.provider = provider }
    func close() { open = false; items = []; nextPageToken = nil }
    func load(more: Bool = false) async {
        guard open, !busy, let server = provider.serverMail else { return }
        let token = more ? nextPageToken : nil
        if more && token == nil { return }
        busy = true; status = nil
        defer { busy = false }
        do {
            try provider.check()
            let page = try await server.outbox(pageToken: token, operation: provider)
            try provider.check(); guard open else { return }
            guard !more || page.nextPageToken.map({ !tokens.contains($0) }) != false else { throw GmailServerMailError.invalid }
            var values = more ? items : []
            let known = Set(values.map(\.id))
            values += page.operations.filter { !known.contains($0.id) }
            if !more { tokens = [] }
            if let token { tokens.insert(token) }
            items = values; nextPageToken = page.nextPageToken
        } catch {
            guard open else { return }
            if provider.failure != nil { items = []; nextPageToken = nil }
            status = GmailServerMailError.safe(error).localizedDescription
        }
    }
}

struct GmailServerOutboxView: View {
    @StateObject private var outbox: GmailServerOutbox
    init(provider: WorkspaceProviderOperation) { _outbox = StateObject(wrappedValue: GmailServerOutbox(provider: provider)) }
    var body: some View {
        List {
            if outbox.items.isEmpty && !outbox.busy && outbox.status == nil {
                ContentUnavailableView("Outbox Empty", systemImage: "tray",
                    description: Text("Messages submitted from this business login appear here across your devices."))
            }
            ForEach(outbox.items) { item in
                NavigationLink {
                    GmailServerOutboxDetail(item: item, provider: outbox.provider)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.summary.subject.isEmpty ? "(No subject)" : item.summary.subject).font(.headline).lineLimit(1)
                        Text(item.summary.to.joined(separator: ", ")).font(.subheadline).lineLimit(1)
                        Text(item.state.title).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
            if outbox.nextPageToken != nil {
                Button("Load Older Requests") { Task { await outbox.load(more: true) } }.disabled(outbox.busy)
            }
            if outbox.busy { ProgressView("Checking outbox…") }
            if let status = outbox.status { Text(status).font(.callout) }
        }
        .listStyle(.plain).navigationTitle("Outbox")
        .accessibilityIdentifier("MailSharedOutbox")
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await outbox.load() } }.disabled(outbox.busy) }
        .task { await outbox.load() }
        .onDisappear {
            // A pushed message uses this same original capability. Do not
            // invalidate it just because the list is temporarily covered.
        }
    }
}

private struct GmailServerOutboxDetail: View {
    let item: GmailServerMail.OutboxItem
    let provider: WorkspaceProviderOperation
    @State private var content: GmailServerMessage?
    @State private var state: GmailServerOperationState?
    @State private var status: String?
    @State private var busy = false
    @State private var confirmingCancel = false
    var body: some View {
        Form {
            if let content {
                Section {
                    Text(content.subject.isEmpty ? "(No subject)" : content.subject).font(.headline)
                    LabeledContent("To", value: content.to.joined(separator: ", "))
                    Text(content.body).textSelection(.enabled)
                }
                if !content.attachments.isEmpty {
                    Section("Attachments") {
                        ForEach(Array(content.attachments.enumerated()), id: \.offset) { _, file in
                            Label(file.name, systemImage: "paperclip")
                        }
                    }
                }
            }
            Section {
                Text((state ?? item.state).title)
                if state == .confirmed {
                    Text("Gmail accepted this message. Delivery to the recipient has not been verified.").font(.footnote).foregroundStyle(.secondary)
                }
                if let status { Text(status).font(.callout) }
                if busy { ProgressView("Checking original message…") }
                Button("Check Status") { Task { await check() } }.disabled(busy)
                if state == .prepared {
                    Button("Cancel Unsent Request", role: .destructive) { confirmingCancel = true }.disabled(busy)
                }
            } footer: {
                Text("This is the original submitted message. Checking its status never sends another copy. Editable drafts remain in Drafts on the device where you wrote them.")
            }
        }
        .navigationTitle("Outbox Message").navigationBarTitleDisplayMode(.inline)
        .task { await check() }
        .confirmationDialog("Cancel this unsent request?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Cancel Unsent Request", role: .destructive) { Task { await check(cancel: true) } }
        } message: { Text("Only a request that has not started sending can be cancelled. Its saved content is retained.") }
    }
    private func check(cancel: Bool = false) async {
        guard !busy, let server = provider.serverMail else { return }
        busy = true; status = nil
        defer { busy = false }
        do {
            try provider.check()
            let message = try await server.savedMessage(id: item.id, operation: provider)
            guard message.to == item.summary.to, message.subject == item.summary.subject,
                  message.attachments.map(\.name) == item.summary.attachmentNames else { throw GmailServerMailError.invalid }
            let original = try await (cancel ? server.cancel(id: item.id, operation: provider)
                : server.operation(id: item.id, recovery: true, operation: provider))
            try provider.check()
            content = message; state = original.state
        } catch {
            if provider.failure != nil { content = nil; state = nil }
            status = GmailServerMailError.safe(error).localizedDescription
        }
    }
}
