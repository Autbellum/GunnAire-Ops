import SwiftUI
import SwiftData

enum CustomerPortalEstimateApprovalImportIssue: LocalizedError, Equatable {
    case incompleteResponse
    case responseTimeInvalid
    case estimateUnavailable
    case estimateAmbiguous
    case jobUnavailable
    case snapshotChanged
    case customerMismatch
    case approvalConflict

    var errorDescription: String? {
        switch self {
        case .incompleteResponse:
            "The portal approval is incomplete. Keep it for administrator review."
        case .responseTimeInvalid:
            "The portal approval time is invalid. Keep it for administrator review."
        case .estimateUnavailable:
            "The exact estimate is not on this device yet. Refresh after CloudKit finishes syncing."
        case .estimateAmbiguous:
            "More than one local estimate has this identity. Resolve the duplicate before applying approval."
        case .jobUnavailable:
            "The linked job is not on this device yet. Refresh after CloudKit finishes syncing."
        case .snapshotChanged:
            "The local estimate no longer matches the exact amount and revision shown to the customer."
        case .customerMismatch:
            "The portal customer does not match the estimate and linked job."
        case .approvalConflict:
            "Different approval evidence already exists for this estimate. Review it before continuing."
        }
    }

    var requiresAdministratorAttention: Bool {
        switch self {
        case .estimateUnavailable, .jobUnavailable:
            false
        case .incompleteResponse, .responseTimeInvalid, .estimateAmbiguous,
             .snapshotChanged, .customerMismatch, .approvalConflict:
            true
        }
    }
}

struct CustomerPortalEstimateApprovalImportResult {
    let estimate: Estimate
    let serviceCall: ServiceCall
    let wasAlreadyApplied: Bool
}

enum CustomerPortalEstimateApprovalPolicy {
    static func apply(
        _ link: BackendCustomerPortalLinkRecord,
        estimates: [Estimate],
        serviceCalls: [ServiceCall],
        recordedByEmail: String?,
        now: Date = Date()
    ) throws -> CustomerPortalEstimateApprovalImportResult {
        guard let estimateIDRaw = link.estimateID,
              let estimateID = UUID(uuidString: estimateIDRaw),
              let expectedAmount = link.estimateAmount,
              let expectedRevision = link.estimateRevision,
              let expectedLabel = link.estimateLabel,
              let responseIDRaw = link.estimateResponseID,
              let responseID = UUID(uuidString: responseIDRaw),
              let responseName = link.estimateResponseName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !responseName.isEmpty,
              let respondedAtRaw = link.estimateRespondedAt,
              let respondedAt = portalDate(respondedAtRaw),
              let linkCreatedAt = portalDate(link.createdAt) else {
            throw CustomerPortalEstimateApprovalImportIssue.incompleteResponse
        }
        guard respondedAt >= linkCreatedAt.addingTimeInterval(-1),
              respondedAt <= now.addingTimeInterval(5 * 60) else {
            throw CustomerPortalEstimateApprovalImportIssue.responseTimeInvalid
        }

        let matchingEstimates = estimates.filter { $0.id == estimateID }
        guard !matchingEstimates.isEmpty else {
            throw CustomerPortalEstimateApprovalImportIssue.estimateUnavailable
        }
        guard matchingEstimates.count == 1, let estimate = matchingEstimates.first else {
            throw CustomerPortalEstimateApprovalImportIssue.estimateAmbiguous
        }
        guard respondedAt >= estimate.createdAt.addingTimeInterval(-5 * 60),
              estimate.customerPortalRevision == expectedRevision.lowercased(),
              estimate.proposalLabel == expectedLabel,
              Int64((estimate.amount * 100).rounded()) == Int64((expectedAmount * 100).rounded()) else {
            throw CustomerPortalEstimateApprovalImportIssue.snapshotChanged
        }
        guard let estimateCustomer = estimate.customer,
              AppAccess.normalizedEmail(estimateCustomer.email) == AppAccess.normalizedEmail(link.customerEmail),
              !AppAccess.normalizedEmail(link.customerEmail).isEmpty else {
            throw CustomerPortalEstimateApprovalImportIssue.customerMismatch
        }

        guard let serviceCallIDRaw = link.serviceCallID,
              let serviceCallID = UUID(uuidString: serviceCallIDRaw) else {
            throw CustomerPortalEstimateApprovalImportIssue.incompleteResponse
        }
        let matchingCalls = serviceCalls.filter { $0.id == serviceCallID }
        guard matchingCalls.count == 1, let serviceCall = matchingCalls.first else {
            throw matchingCalls.isEmpty
                ? CustomerPortalEstimateApprovalImportIssue.jobUnavailable
                : CustomerPortalEstimateApprovalImportIssue.customerMismatch
        }
        guard serviceCall.customer.id == estimateCustomer.id,
              estimate.serviceCallID == serviceCall.id else {
            throw CustomerPortalEstimateApprovalImportIssue.customerMismatch
        }

        let reference = "Customer portal response \(responseID.uuidString.lowercased())"
        if estimate.hasRecordedCustomerApproval {
            guard estimate.customerApprovalMethod == .email,
                  estimate.customerApprovalReference == reference,
                  estimate.customerApprovedByName == responseName,
                  let previouslyApprovedAt = estimate.customerApprovedAt,
                  abs(previouslyApprovedAt.timeIntervalSince(respondedAt)) <= 1 else {
                throw CustomerPortalEstimateApprovalImportIssue.approvalConflict
            }
            return CustomerPortalEstimateApprovalImportResult(
                estimate: estimate,
                serviceCall: serviceCall,
                wasAlreadyApplied: true
            )
        }

        guard estimate.customerApprovalBlockedMessage == nil,
              EstimateProposalPolicy.selectionIssue(for: estimate, in: estimates) == nil,
              EstimateProposalPolicy.recordApproval(
            for: estimate,
            in: estimates,
            customerName: responseName,
            method: .email,
            reference: reference,
            signatureImageBase64: nil,
            recordedByEmail: recordedByEmail,
            at: respondedAt
              ) else {
            throw CustomerPortalEstimateApprovalImportIssue.approvalConflict
        }
        serviceCall.linkedEstimateID = estimate.id
        serviceCall.followUpRequired = false
        serviceCall.followUpAction = nil
        serviceCall.followUpDueDate = nil
        return CustomerPortalEstimateApprovalImportResult(
            estimate: estimate,
            serviceCall: serviceCall,
            wasAlreadyApplied: false
        )
    }

    private static func portalDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

/// Administrator-only view of non-secret customer portal link metadata. The
/// capability URL is intentionally never returned after creation, so this queue
/// cannot be used to resend or expose a customer link accidentally.
struct CustomerPortalLinkManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @State private var links: [BackendCustomerPortalLinkRecord] = []
    @State private var isLoading = false
    @State private var message: String?
    @State private var pendingRevocation: BackendCustomerPortalLinkRecord?
    @State private var pendingApproval: BackendCustomerPortalLinkRecord?
    @State private var applyingLinkID: String?

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
                        Section {
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
                                    if let estimateLabel = link.estimateLabel,
                                       let estimateAmount = link.estimateAmount {
                                        Text("\(estimateLabel): \(estimateAmount, format: .currency(code: "USD"))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    approvalStatus(for: link)
                                    Label(openStatusText(for: link), systemImage: openStatusSymbol(for: link))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("Created by \(link.createdBy) • expires \(dateText(link.expiresAt))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if isActive(link) {
                                        Button("Revoke Link", role: .destructive) {
                                            pendingRevocation = link
                                        }
                                        .font(.caption.weight(.semibold))
                                    }
                                    if canApplyApproval(link) {
                                        Button(applyButtonTitle(for: link)) {
                                            pendingApproval = link
                                        }
                                        .font(.caption.weight(.semibold))
                                        .disabled(applyingLinkID != nil)
                                        .accessibilityIdentifier("ApplyPortalEstimateApproval")
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        } footer: {
                            Text("Open counts may include mail or security previews and are not proof that the customer read the update.")
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
            .alert("Apply customer approval?", isPresented: Binding(
                get: { pendingApproval != nil },
                set: { if !$0 { pendingApproval = nil } }
            )) {
                Button("Cancel", role: .cancel) { pendingApproval = nil }
                Button("Apply Approval") {
                    guard let link = pendingApproval else { return }
                    pendingApproval = nil
                    Task { await applyApproval(link) }
                }
            } message: {
                if let link = pendingApproval {
                    Text("Apply \(link.estimateResponseName ?? "the customer")'s approval to the exact \(link.estimateLabel ?? "estimate") shown in this link?")
                }
            }
        }
    }

    @ViewBuilder
    private func approvalStatus(for link: BackendCustomerPortalLinkRecord) -> some View {
        if link.estimateResolutionStatus == "applied" {
            Label("Customer approval applied", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else if let respondedAt = link.estimateRespondedAt,
                  let responseName = link.estimateResponseName {
            Label(
                "Approved by \(responseName) • \(dateText(respondedAt))",
                systemImage: link.estimateResolutionStatus == "needs_attention"
                    ? "exclamationmark.triangle.fill"
                    : "signature"
            )
            .font(.caption)
            .foregroundStyle(link.estimateResolutionStatus == "needs_attention" ? .orange : .blue)
            if let detail = link.estimateResolutionDetail,
               link.estimateResolutionStatus == "needs_attention" {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if link.estimateID != nil {
            Label("Awaiting customer approval", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func canApplyApproval(_ link: BackendCustomerPortalLinkRecord) -> Bool {
        link.estimateResponseID != nil && link.estimateResolutionStatus != "applied"
    }

    private func applyButtonTitle(for link: BackendCustomerPortalLinkRecord) -> String {
        link.estimateResolutionStatus == "needs_attention" ? "Retry Apply" : "Apply Approval"
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

    private func openStatusText(for link: BackendCustomerPortalLinkRecord) -> String {
        let count = max(link.openedCount ?? 0, 0)
        guard count > 0 else { return "Not opened" }
        let countText = count == 1 ? "Opened once" : "Opened \(count) times"
        guard let lastOpenedAt = link.lastOpenedAt, !lastOpenedAt.isEmpty else { return countText }
        return "\(countText) • last \(dateText(lastOpenedAt))"
    }

    private func openStatusSymbol(for link: BackendCustomerPortalLinkRecord) -> String {
        max(link.openedCount ?? 0, 0) > 0 ? "eye" : "eye.slash"
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

    @MainActor
    private func applyApproval(_ link: BackendCustomerPortalLinkRecord) async {
        guard let responseID = link.estimateResponseID else { return }
        applyingLinkID = link.id
        defer { applyingLinkID = nil }
        do {
            let result = try CustomerPortalEstimateApprovalPolicy.apply(
                link,
                estimates: estimates,
                serviceCalls: serviceCalls,
                recordedByEmail: AppIdentity.currentEmail
            )
            if !result.wasAlreadyApplied {
                ServiceCallActivity.record(
                    for: result.serviceCall,
                    action: result.estimate.isChangeOrder ? "Portal change order approved" : "Portal estimate approved",
                    detail: "Customer portal approval applied for \(result.estimate.amount.formatted(.currency(code: "USD"))).",
                    actorEmail: AppIdentity.currentEmail,
                    in: modelContext
                )
            }
            try modelContext.save()
            let updated = try await GunnAireBackendService.resolveCustomerPortalEstimateResponse(
                linkID: link.id,
                responseID: responseID,
                status: "applied"
            )
            replaceLink(updated)
            message = result.wasAlreadyApplied
                ? "Approval was already applied; the server record is reconciled."
                : "Customer approval applied to the exact estimate."
        } catch let issue as CustomerPortalEstimateApprovalImportIssue {
            if issue.requiresAdministratorAttention {
                if let updated = try? await GunnAireBackendService.resolveCustomerPortalEstimateResponse(
                    linkID: link.id,
                    responseID: responseID,
                    status: "needs_attention",
                    detail: issue.errorDescription
                ) {
                    replaceLink(updated)
                }
            }
            message = issue.errorDescription
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func replaceLink(_ updated: BackendCustomerPortalLinkRecord) {
        guard let index = links.firstIndex(where: { $0.id == updated.id }) else {
            links.insert(updated, at: 0)
            return
        }
        links[index] = updated
    }
}
