import SwiftUI
import SwiftData

struct FieldFormResponseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var access = CompanyWorkspaceAccessController.shared
    let serviceCallID: UUID
    let templateID: UUID
    let actorEmail: String?
    @State private var workflow: FieldFormDraftWorkflow?
    @State private var session: FieldFormDraftSession?
    @State private var record: FieldFormDraftRecord?
    @State private var answers: [UUID: String] = [:]
    @State private var message: String?
    @State private var contextChanged = false
    @State private var accessDenied = false
    @State private var unsaved = false
    @State private var isSaving = false
    @State private var showingDiscard = false
    @State private var showingReload = false
    @State private var completion: FieldFormDraftWorkflow.Completion?

    init(template: FieldFormTemplate, serviceCall: ServiceCall, actorEmail: String?) {
        self.init(serviceCallID: serviceCall.id, templateID: template.id, actorEmail: actorEmail)
    }

    init(serviceCallID: UUID, templateID: UUID, actorEmail: String?) {
        self.serviceCallID = serviceCallID; self.templateID = templateID; self.actorEmail = actorEmail
    }

    private var editable: Bool { record?.state == .editing && !contextChanged && !accessDenied && !isSaving }

    var body: some View {
        NavigationStack {
            Form {
                if !accessDenied, let record, let content = record.content {
                    Section("Job") {
                        LabeledContent("Customer", value: content.job.customerName)
                        LabeledContent("Work", value: ServiceCallType(rawValue: content.job.workType)?.displayName ?? "Needs review")
                        if !content.job.siteAddress.isEmpty { Text(content.job.siteAddress).font(.caption).foregroundStyle(.secondary) }
                        if record.state == .editing && !unsaved && !contextChanged {
                            Label("Draft saved on this device", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("FieldFormDraftSaved")
                        } else if record.state == .completed {
                            Label("Completed form saved in this job’s Files", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green).accessibilityIdentifier("FieldFormCompletionSaved")
                        } else if record.state == .completing {
                            Text("Finish saving to recover the original form and file.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let message {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                .accessibilityIdentifier("FieldFormDraftIssue")
                            if unsaved && !contextChanged {
                                Button("Retry saving draft") { persistAnswers() }
                                Button("Reload saved draft…") { showingReload = true }
                            }
                        }
                    }
                    Section(content.title) {
                        ForEach(content.questions) { question in questionView(question) }
                    }
                    if record.state == .editing {
                        Section {
                            Button("Discard draft…", role: .destructive) { showingDiscard = true }
                                .disabled(isSaving).accessibilityIdentifier("DiscardFieldFormDraft")
                        } footer: {
                            Text("Drafts stay private on this device. Complete the form to add its PDF to this job’s Files.")
                        }
                    } else if record.state == .completed {
                        Section {
                            savedFormLink(record)
                            Button("Start another form") { load(startAnother: true) }
                                .accessibilityIdentifier("StartAnotherFieldForm")
                        }
                    }
                } else {
                    ContentUnavailableView("Form unavailable", systemImage: "checklist",
                        description: Text(message ?? "Checking your saved draft…"))
                    Button("Try again") { load() }
                }
            }
            .navigationTitle(record?.state == .completed ? "Saved Form" : "Complete Form")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(isSaving || unsaved)
                        .accessibilityIdentifier("CloseFieldFormDraft")
                }
                if record?.state == .editing || record?.state == .completing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? "Saving…" : record?.state == .completing ? "Finish saving" : "Complete") { save() }
                            .disabled(isSaving || unsaved || accessDenied || contextChanged)
                            .accessibilityIdentifier("SaveCompletedFieldForm")
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving || unsaved)
        .navigationBarBackButtonHidden(isSaving || unsaved)
        .task { if workflow == nil { load() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { checkAccessAndContext() } }
        .onChange(of: access.phase) { _, _ in checkAccessAndContext() }
        .confirmationDialog("Discard this unfinished form?", isPresented: $showingDiscard, titleVisibility: .visible) {
            Button("Discard draft", role: .destructive) {
                do {
                    guard let session else { return }
                    try session.discard(); unsaved = false; dismiss()
                } catch { message = error.localizedDescription }
            }
        } message: { Text("Only this draft’s answers will be removed. Completed forms and files are kept.") }
        .confirmationDialog("Reload the saved draft?", isPresented: $showingReload, titleVisibility: .visible) {
            Button("Replace unsaved entries", role: .destructive) { load() }
        } message: { Text("The entries that could not be saved in this window will be replaced by the last saved draft.") }
    }

    @ViewBuilder private func questionView(_ question: FieldFormQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(question.label).font(.subheadline.weight(.semibold))
                if question.required { Text("Required").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
            }
            if !editable {
                Text(FieldFormCompletionPolicy.answerRows(questions: [question], answers: answers)[0].displayAnswer)
                    .textSelection(.enabled)
            } else {
                switch question.kind {
                case .toggle:
                    Toggle(question.required ? "Confirmed" : "Yes", isOn: Binding(
                        get: { answers[question.id] == "true" },
                        set: { answers[question.id] = $0 ? "true" : "false"; persistAnswers() }))
                        .accessibilityLabel(question.label)
                        .accessibilityIdentifier("FieldFormAnswer-\(question.id.uuidString)")
                case .text:
                    TextField("Enter response", text: answerBinding(question.id), axis: .vertical)
                        .lineLimit(2...6).accessibilityLabel(question.label)
                        .accessibilityIdentifier("FieldFormAnswer-\(question.id.uuidString)")
                case .choice:
                    Picker("Response", selection: answerBinding(question.id)) {
                        Text("Select").tag("")
                        ForEach(question.choices, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityLabel(question.label)
                    .accessibilityIdentifier("FieldFormAnswer-\(question.id.uuidString)")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func answerBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0; persistAnswers() })
    }

    @ViewBuilder private func savedFormLink(_ record: FieldFormDraftRecord) -> some View {
        if let completion,
           let response = try? completion.context.fetch(FetchDescriptor<FieldFormResponse>()).first(where: { $0.id == record.id }),
           let job = try? workflow?.requireJob(serviceCallID, in: completion.context) {
            NavigationLink("View saved form") {
                FieldFormResponseDetailView(response: response, template: nil, serviceCall: job, attachment: completion.attachment)
            }
            .accessibilityIdentifier("ViewCompletedDraftForm")
        }
    }

    private func load(startAnother: Bool = false) {
        do {
            let current = try FieldFormDraftWorkflow.live(context: modelContext, actorEmail: actorEmail)
            let opened = try current.open(jobID: serviceCallID, templateID: templateID, startAnother: startAnother)
            workflow = current; session = opened; record = opened.record
            answers = opened.record.content?.answers ?? [:]
            unsaved = false; accessDenied = false; message = nil; completion = nil
            if opened.record.state == .completed {
                completion = try current.complete(opened)
            } else if opened.record.state == .completing {
                // Recover the original outcome on opening, but never create a
                // completion without the user's explicit Finish saving action.
                let source = ModelContext(modelContext.container)
                source.autosaveEnabled = false
                if try current.savedResult(opened.record, in: source) != nil {
                    completion = try current.complete(opened); record = opened.record
                }
            }
            checkAccessAndContext()
        } catch {
            message = error.localizedDescription
            if error as? FieldFormDraftError == .access { accessDenied = true }
        }
    }

    private func checkAccessAndContext() {
        guard let workflow, let session else { return }
        do {
            try session.verify(); accessDenied = false
            if session.record.state != .completed { try workflow.verifyContext(session.record) }
            contextChanged = false
        } catch {
            message = error.localizedDescription
            accessDenied = error as? FieldFormDraftError == .access
            contextChanged = error as? FieldFormDraftError == .contextChanged
        }
    }

    private func persistAnswers() {
        unsaved = true
        do {
            guard let workflow, let session else { throw FieldFormDraftError.storage }
            try workflow.verifyContext(session.record)
            try session.save(answers); record = session.record
            unsaved = false; message = nil
        } catch {
            message = error.localizedDescription
            accessDenied = error as? FieldFormDraftError == .access
            contextChanged = error as? FieldFormDraftError == .contextChanged
        }
    }

    private func save() {
        guard let workflow, let session, let content = session.record.content else { return }
        if let issue = FieldFormCompletionPolicy.validationIssue(questions: content.questions, answers: answers) {
            message = issue; return
        }
        isSaving = true; message = nil
        defer { isSaving = false; record = session.record }
        do {
            let result = try workflow.complete(session)
            completion = result
            if result.newFileData != nil { syncAttachmentIfPossible(result) }
        } catch { message = error.localizedDescription }
    }

    private func syncAttachmentIfPossible(_ result: FieldFormDraftWorkflow.Completion) {
        #if DEBUG
        if GunnAireCloudKit.usesTestDatabase { return }
        #endif
        guard GunnAireBackendService.isConfigured, let workflow else { return }
        Task { @MainActor in
            await workflow.syncNewFile(result) { bytes, attachment in
                let stored = try await GunnAireBackendService.uploadDocument(data: bytes,
                    filename: attachment.displayName, contentType: attachment.contentType, kind: attachment.kindRaw,
                    serviceCallID: attachment.serviceCallID, invoiceID: attachment.invoiceID,
                    estimateID: attachment.estimateID, customerName: attachment.customer?.name)
                return stored.id
            }
        }
    }
}

/// Job-scoped recovery stays reachable even when the office retires or removes
/// the template. It does not add a company-wide drafts dashboard to field work.
struct FieldFormDraftLinks: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var access = CompanyWorkspaceAccessController.shared
    let serviceCallID: UUID
    let actorEmail: String?
    @State private var drafts: [FieldFormDraftRecord] = []
    @State private var unavailable = false

    var body: some View {
        // Group applies lifecycle modifiers to its children. With no initial
        // rows it never appeared, so retired-template recovery never loaded.
        // A stable container gives the disk read a real lifecycle even empty.
        VStack(alignment: .leading, spacing: 8) {
            ForEach(drafts) { draft in
                NavigationLink {
                    FieldFormResponseEditor(serviceCallID: serviceCallID, templateID: draft.slot.templateID, actorEmail: actorEmail)
                } label: {
                    Label("Resume \(draft.content?.title ?? "saved form")", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("ResumeFieldFormDraft-\(draft.slot.templateID.uuidString)")
            }
            if unavailable { Button("Saved drafts unavailable — try again") { refresh() } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: drafts.isEmpty && !unavailable ? 0 : nil)
        .environment(\.defaultMinListRowHeight, 0)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: drafts.isEmpty && !unavailable ? 0 : 8,
                                 leading: 20, bottom: drafts.isEmpty && !unavailable ? 0 : 8, trailing: 20))
        .onAppear { refresh() }
        .onChange(of: access.phase) { _, _ in refresh() }
    }

    private func refresh() {
        do {
            let workflow = try FieldFormDraftWorkflow.live(context: modelContext, actorEmail: actorEmail)
            let job = try workflow.requireJob(serviceCallID)
            let activeIDs = Set(try modelContext.fetch(FetchDescriptor<FieldFormTemplate>())
                .filter { $0.isActive && $0.isListed(for: job.type) }.map(\.id))
            let completedIDs = Set(try modelContext.fetch(FetchDescriptor<FieldFormResponse>())
                .filter { $0.serviceCallID == serviceCallID }.map(\.id))
            drafts = try workflow.drafts(jobID: serviceCallID).filter {
                !activeIDs.contains($0.slot.templateID) || ($0.state == .completing && completedIDs.contains($0.id))
            }
            unavailable = false
        } catch {
            drafts = []; unavailable = error as? FieldFormDraftError != .access
        }
    }
}

/// Existing template entries become Resume in place. Only drafts whose
/// templates are no longer listed need the separate retained-draft links.
struct FieldFormDraftNavigationLink<Content: View>: View {
    @Environment(\.modelContext) private var modelContext
    let template: FieldFormTemplate
    let serviceCall: ServiceCall
    let actorEmail: String?
    let identifier: String?
    let content: Content
    @State private var hasDraft = false

    init(template: FieldFormTemplate, serviceCall: ServiceCall, actorEmail: String?, identifier: String? = nil,
         @ViewBuilder label: () -> Content) {
        self.template = template; self.serviceCall = serviceCall; self.actorEmail = actorEmail
        self.identifier = identifier; content = label()
    }

    var body: some View {
        NavigationLink {
            FieldFormResponseEditor(template: template, serviceCall: serviceCall, actorEmail: actorEmail)
        } label: {
            if hasDraft { Label("Resume \(template.title)", systemImage: "square.and.pencil") }
            else { content }
        }
        .accessibilityIdentifier(hasDraft ? "ResumeFieldFormDraft-\(template.id.uuidString)" :
            identifier ?? "OpenFieldForm-\(template.id.uuidString)")
        .onAppear {
            do {
                let workflow = try FieldFormDraftWorkflow.live(context: modelContext, actorEmail: actorEmail)
                _ = try workflow.requireJob(serviceCall.id)
                let record = try workflow.store.read(.init(scope: workflow.scope, jobID: serviceCall.id, templateID: template.id))
                hasDraft = record.map { [.editing, .completing].contains($0.state) } ?? false
            } catch { hasDraft = false }
        }
    }
}
