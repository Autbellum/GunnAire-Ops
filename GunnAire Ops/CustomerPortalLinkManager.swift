import SwiftUI

/// Administrator-only view of non-secret customer portal link metadata. The
/// capability URL is intentionally never returned after creation, so this queue
/// cannot be used to resend or expose a customer link accidentally.
struct CustomerPortalLinkManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var links: [BackendCustomerPortalLinkRecord] = []
    @State private var isLoading = false
    @State private var message: String?
    @State private var pendingRevocation: BackendCustomerPortalLinkRecord?

    private var formatter: ISO8601DateFormatter { ISO8601DateFormatter() }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && links.isEmpty {
                    ProgressView("Loading customer portal links…")
                } else if links.isEmpty {
                    ContentUnavailableView(
                        "No customer portal links",
                        systemImage: "person.badge.key",
                        description: Text("New links appear here after an administrator creates them from a job."))
                } else {
                    List {
                        ForEach(links) { link in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(link.customerName)
                                        .font(.headline)
                                    Spacer()
                                    Text(statusText(for: link))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(statusColor(for: link))
                                }
                                Text(link.title)
                                    .font(.subheadline)
                                if let appointmentSummary = link.appointmentSummary, !appointmentSummary.isEmpty {
                                    Text(appointmentSummary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let invoiceReference = link.invoiceReference, !invoiceReference.isEmpty {
                                    Text("Invoice \(invoiceReference)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text("Created by \(link.createdBy) • expires \(dateText(link.expiresAt))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if isActive(link) {
                                    Button("Revoke Link", role: .destructive) {
                                        pendingRevocation = link
                                    }
                                    .font(.caption.weight(.semibold))
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .navigationTitle("Customer Portal Links")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await loadLinks() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.caption)
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .padding()
                }
            }
            .task { await loadLinks() }
            .alert("Revoke customer portal link?", isPresented: Binding(
                get: { pendingRevocation != nil },
                set: { if !$0 { pendingRevocation = nil } }
            )) {
                Button("Keep Link", role: .cancel) { pendingRevocation = nil }
                Button("Revoke", role: .destructive) {
                    guard let link = pendingRevocation else { return }
                    pendingRevocation = nil
                    Task { await revoke(link) }
                }
            } message: {
                Text("The customer will no longer be able to open this link. This cannot be undone; create a new link if needed.")
            }
        }
    }

    private func isActive(_ link: BackendCustomerPortalLinkRecord) -> Bool {
        guard link.revokedAt == nil,
              let expiresAt = formatter.date(from: link.expiresAt) else { return false }
        return expiresAt > Date()
    }

    private func statusText(for link: BackendCustomerPortalLinkRecord) -> String {
        if link.revokedAt != nil { return "Revoked" }
        return isActive(link) ? "Active" : "Expired"
    }

    private func statusColor(for link: BackendCustomerPortalLinkRecord) -> Color {
        if link.revokedAt != nil { return .red }
        return isActive(link) ? .green : .orange
    }

    private func dateText(_ value: String) -> String {
        formatter.date(from: value)?.formatted(date: .abbreviated, time: .shortened) ?? value
    }

    @MainActor
    private func loadLinks() async {
        guard GunnAireBackendService.isConfigured else {
            message = "Configure the shared business server before loading customer portal links."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            links = try await GunnAireBackendService.fetchCustomerPortalLinks()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func revoke(_ link: BackendCustomerPortalLinkRecord) async {
        do {
            try await GunnAireBackendService.revokeCustomerPortalLink(id: link.id)
            message = "Customer portal link revoked."
            await loadLinks()
        } catch {
            message = error.localizedDescription
        }
    }
}
