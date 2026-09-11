import SwiftUI

nonisolated enum GunnAireLocalAITask: String, CaseIterable, Identifiable, Sendable {
    case operationsNarrative = "operations_narrative"
    case customerEmailDraft = "customer_email_draft"
    case customerTextDraft = "customer_text_draft"
    case serviceNoteSummary = "service_note_summary"
    case documentClassification = "document_classification"
    case estimateScopeDraft = "estimate_scope_draft"
    case failureTriage = "failure_triage"
    case securityReview = "security_review"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .operationsNarrative: "Operations Brief"
        case .customerEmailDraft: "Customer Email Draft"
        case .customerTextDraft: "Customer Text Draft"
        case .serviceNoteSummary: "Service Note Summary"
        case .documentClassification: "Document Classification"
        case .estimateScopeDraft: "Estimate Scope Draft"
        case .failureTriage: "Failure Triage"
        case .securityReview: "Security Review"
        }
    }

    var systemImage: String {
        switch self {
        case .operationsNarrative: "chart.bar.doc.horizontal"
        case .customerEmailDraft: "envelope.badge"
        case .customerTextDraft: "message.badge"
        case .serviceNoteSummary: "wrench.and.screwdriver.fill"
        case .documentClassification: "doc.text.magnifyingglass"
        case .estimateScopeDraft: "doc.badge.gearshape"
        case .failureTriage: "stethoscope"
        case .securityReview: "lock.shield"
        }
    }

    var inputTitle: String {
        switch self {
        case .operationsNarrative: "Optional Direction"
        case .customerEmailDraft, .customerTextDraft: "Verified Customer Facts"
        case .serviceNoteSummary: "Technician Notes"
        case .documentClassification: "Document Excerpt"
        case .estimateScopeDraft: "Source-Backed Scope Facts"
        case .failureTriage: "Deterministic Failure Output"
        case .securityReview: "Redacted Security Evidence"
        }
    }

    var inputPrompt: String {
        switch self {
        case .operationsNarrative:
            "Create a concise management brief from the deterministic dashboard snapshot. Do not change any counts, scores, or amounts."
        case .customerEmailDraft:
            "Enter only verified appointment, service, or follow-up facts. Do not include card, bank, password, token, or private-key data."
        case .customerTextDraft:
            "Enter only verified facts needed for a brief transactional text."
        case .serviceNoteSummary:
            "Paste technician notes. The model must preserve uncertainty and may not add a diagnosis or measurement."
        case .documentClassification:
            "Paste a short non-sensitive document excerpt."
        case .estimateScopeDraft:
            "Enter source-backed HVAC scope facts. Do not ask the model to invent quantities, pricing, code conclusions, or field conditions."
        case .failureTriage:
            "Paste redacted deterministic failure output. A failing exit code remains a failure."
        case .securityReview:
            "Paste redacted evidence only. Never include credentials, customer payment data, or signing material."
        }
    }

    func isAllowed(for role: AppUserRole?) -> Bool {
        switch self {
        case .customerEmailDraft, .customerTextDraft, .serviceNoteSummary:
            return role != nil
        case .operationsNarrative, .documentClassification:
            return role == .admin || role == .accounting || role == .dispatcher || role == .standard
        case .estimateScopeDraft:
            return role == .admin || role == .dispatcher || role == .standard
        case .failureTriage, .securityReview:
            return role == .admin
        }
    }

    static func available(for role: AppUserRole?) -> [GunnAireLocalAITask] {
        allCases.filter { $0.isAllowed(for: role) }
    }
}

struct GunnAireLocalAIWorkspace: View {
    @Environment(\.dismiss) private var dismiss

    let snapshot: BusinessSuiteSnapshot
    let role: AppUserRole?
    let canViewFinancials: Bool

    @State private var selectedTask: GunnAireLocalAITask
    @State private var verifiedInput = ""
    @State private var status: GunnAireLocalAIStatus?
    @State private var response: GunnAireLocalAIAssistResponse?
    @State private var statusMessage: String?
    @State private var isRefreshingStatus = false
    @State private var isGenerating = false

    init(snapshot: BusinessSuiteSnapshot, role: AppUserRole?, canViewFinancials: Bool) {
        self.snapshot = snapshot
        self.role = role
        self.canViewFinancials = canViewFinancials
        _selectedTask = State(initialValue: GunnAireLocalAITask.available(for: role).first ?? .customerTextDraft)
    }

    private var availableTasks: [GunnAireLocalAITask] {
        GunnAireLocalAITask.available(for: role)
    }

    private var requestInput: String {
        let input = verifiedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return input.isEmpty && selectedTask == .operationsNarrative
            ? selectedTask.inputPrompt
            : input
    }

    private var canGenerate: Bool {
        !isGenerating && status?.available == true && !requestInput.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                routingSection
                taskSection
                inputSection
                resultSection
                safetySection
            }
            .navigationTitle("Local AI Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await generate() }
                    } label: {
                        if isGenerating {
                            ProgressView()
                        } else {
                            Label("Generate", systemImage: "sparkles")
                        }
                    }
                    .disabled(!canGenerate)
                    .accessibilityIdentifier("GenerateLocalAIDraft")
                }
            }
            .task {
                await refreshStatus()
            }
            .onChange(of: selectedTask) { _, _ in
                response = nil
                statusMessage = nil
                verifiedInput = ""
            }
        }
        .tint(Color.brandGold)
    }

    private var routingSection: some View {
        Section("Local-Only Routing") {
            if let status {
                Label(status.displayTitle, systemImage: status.available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status.available ? .green : .orange)
                Text(status.displayDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Provider", value: status.isLocalOnly ? "Ollama on the business backend" : status.provider)
                LabeledContent("Hosted credits", value: "\(status.hostedCreditsUsed)")
                LabeledContent("Image model", value: status.stableDiffusionScope == "image-only" ? "Image work only" : status.stableDiffusionScope)
                if let models = status.installedModels, !models.isEmpty {
                    LabeledContent("Installed models", value: "\(models.count)")
                }
            } else if isRefreshingStatus {
                HStack {
                    ProgressView()
                    Text("Checking the Mac Studio local model…")
                }
            } else {
                Label("Local AI status not checked", systemImage: "questionmark.circle")
            }

            Button("Refresh Local AI Status") {
                Task { await refreshStatus() }
            }
            .disabled(isRefreshingStatus)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var taskSection: some View {
        Section("Task") {
            if availableTasks.isEmpty {
                Label("No local-AI task is available for the current unresolved role.", systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Local AI task", selection: $selectedTask) {
                    ForEach(availableTasks) { task in
                        Label(task.title, systemImage: task.systemImage).tag(task)
                    }
                }
                Text(selectedTask.inputPrompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var inputSection: some View {
        Section(selectedTask.inputTitle) {
            if selectedTask == .operationsNarrative {
                Text("The model receives a role-filtered copy of the deterministic Command Center snapshot. The app's calculations remain authoritative.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $verifiedInput)
                .frame(minHeight: selectedTask == .operationsNarrative ? 90 : 180)
                .accessibilityIdentifier("LocalAIVerifiedInput")
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        Section("Staff-Reviewed Result") {
            if let response {
                let output = response.result.displayText(for: selectedTask)
                Text(output.isEmpty ? "The local model returned no usable draft text." : output)
                    .textSelection(.enabled)
                Divider()
                LabeledContent("Model", value: response.model)
                LabeledContent("Source", value: response.local ? "Local" : "Unexpected")
                LabeledContent("Cache", value: response.cached ? "Reused identical local result" : "New local inference")
                LabeledContent("Hosted credits", value: "\(response.hostedCreditsUsed)")
                if response.redactions > 0 {
                    LabeledContent("Automatic redactions", value: "\(response.redactions)")
                }
            } else {
                Text("Generate a local result. Nothing is sent, applied, posted, charged, or marked complete automatically.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var safetySection: some View {
        Section("Review Gate") {
            Label("Every result is advisory and requires staff review.", systemImage: "person.badge.shield.checkmark")
            Text("Deterministic calculations, role permissions, consent, payment status, accounting records, diagnoses, measurements, and release gates remain authoritative. If the local model is unavailable, the app does not switch to a hosted model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func refreshStatus() async {
        guard GunnAireBackendService.isConfigured else {
            status = nil
            statusMessage = "Configure the authenticated GunnAire backend before using local AI."
            return
        }
        isRefreshingStatus = true
        defer { isRefreshingStatus = false }
        do {
            status = try await GunnAireLocalAIService.fetchStatus()
            statusMessage = status?.available == true
                ? nil
                : "The local model is unavailable. Deterministic app features remain available without hosted-model charges."
        } catch {
            status = nil
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func generate() async {
        guard canGenerate else { return }
        isGenerating = true
        response = nil
        statusMessage = nil
        defer { isGenerating = false }
        do {
            let request = GunnAireLocalAIAssistRequest(
                task: selectedTask.rawValue,
                input: requestInput,
                context: selectedTask == .operationsNarrative
                    ? snapshot.localAIContext(includeFinancials: canViewFinancials)
                    : [:],
                baseline: selectedTask == .operationsNarrative
                    ? snapshot.localAIBaseline(includeFinancials: canViewFinancials)
                    : [:]
            )
            response = try await GunnAireLocalAIService.assist(request)
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

struct GunnAireLocalAIReadinessSection: View {
    @State private var status: GunnAireLocalAIStatus?
    @State private var message: String?
    @State private var isRefreshing = false

    var body: some View {
        Section("Local AI") {
            if let status {
                Label(status.displayTitle, systemImage: status.available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status.available ? .green : .orange)
                Text(status.displayDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Text and reasoning", value: status.isLocalOnly ? "Local Ollama first" : status.provider)
                LabeledContent("Hosted credits", value: "\(status.hostedCreditsUsed)")
                LabeledContent("Image generation", value: "Separate image-only provider")
            } else {
                Label("Local AI status unavailable", systemImage: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
            }

            Button("Refresh Local AI Status") {
                Task { await refresh() }
            }
            .disabled(isRefreshing || !GunnAireBackendService.isConfigured)

            if isRefreshing {
                ProgressView("Checking local model")
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .task {
            if status == nil { await refresh() }
        }
    }

    @MainActor
    private func refresh() async {
        guard GunnAireBackendService.isConfigured else {
            message = "Configure the shared backend first."
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            status = try await GunnAireLocalAIService.fetchStatus()
            message = status?.available == true
                ? "Eligible business AI work uses the local model. Hosted fallback remains disabled."
                : "Local AI is offline; deterministic app behavior remains active with no hosted fallback."
        } catch {
            status = nil
            message = error.localizedDescription
        }
    }
}

private extension BusinessSuiteSnapshot {
    func localAIContext(includeFinancials: Bool) -> [String: GunnAireLocalAIValue] {
        var context: [String: GunnAireLocalAIValue] = [
            "generatedAt": .string(generatedAt.ISO8601Format()),
            "healthScore": .number(Double(healthScore)),
            "healthLabel": .string(healthLabel),
            "healthDetail": .string(healthDetail),
            "readyToBillCount": .number(Double(readyToBillCount)),
            "openWorkCount": .number(Double(openWorkCount)),
            "customerRiskCount": .number(Double(customerRiskCount)),
            "syncAttentionCount": .number(Double(syncAttentionCount)),
            "pricebookAttentionCount": .number(Double(pricebookAttentionCount)),
            "catalogItemCount": .number(Double(catalogItemCount)),
            "fieldCoverage": .number(fieldCoverage),
            "workstreams": .array(visibleWorkstreams(includeFinancials: includeFinancials).map { workstream in
                .object([
                    "title": .string(workstream.title),
                    "value": .string(workstream.value),
                    "status": .string(workstream.status),
                    "detail": .string(workstream.detail),
                    "score": .number(Double(workstream.score)),
                    "severity": .string(String(describing: workstream.severity)),
                ])
            }),
            "actions": .array(visibleActions(includeFinancials: includeFinancials).prefix(8).map { action in
                .object([
                    "title": .string(action.title),
                    "detail": .string(action.detail),
                    "value": .string(action.value),
                    "severity": .string(String(describing: action.severity)),
                ])
            }),
        ]
        if includeFinancials {
            context["monthInvoiceTotal"] = .number(monthInvoiceTotal)
            context["monthPaymentTotal"] = .number(monthPaymentTotal)
            context["openReceivablesTotal"] = .number(openReceivablesTotal)
            context["estimatePipelineTotal"] = .number(estimatePipelineTotal)
            context["averageGrossMargin"] = .number(averageGrossMargin)
        }
        return context
    }

    func localAIBaseline(includeFinancials: Bool) -> [String: GunnAireLocalAIValue] {
        var baseline: [String: GunnAireLocalAIValue] = [
            "headline": .string("\(healthLabel) — \(healthScore)/100"),
            "summary": .string(healthDetail),
            "priorityCount": .number(Double(actions.count)),
        ]
        if includeFinancials {
            baseline["openReceivablesTotal"] = .number(openReceivablesTotal)
            baseline["estimatePipelineTotal"] = .number(estimatePipelineTotal)
        }
        return baseline
    }

    func visibleWorkstreams(includeFinancials: Bool) -> [BusinessSuiteWorkstream] {
        guard !includeFinancials else { return workstreams }
        return workstreams.filter { $0.id != .revenue && $0.id != .accounts }
    }

    func visibleActions(includeFinancials: Bool) -> [BusinessSuiteAction] {
        guard !includeFinancials else { return actions }
        return actions.filter { action in
            switch action.destination {
            case .collectPayment, .payments, .quickBooks, .quickBooksSales, .estimates, .invoices:
                return false
            default:
                return true
            }
        }
    }
}
