import Foundation
import SwiftData
import SwiftUI

enum FieldFormQuestionKind: String, Codable, CaseIterable, Identifiable {
    case toggle
    case text
    case choice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toggle: "Confirmation"
        case .text: "Text / reading"
        case .choice: "Choice"
        }
    }

    var systemImage: String {
        switch self {
        case .toggle: "checkmark.square"
        case .text: "text.cursor"
        case .choice: "list.bullet"
        }
    }
}

struct FieldFormQuestion: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var label: String
    var kind: FieldFormQuestionKind
    var required: Bool = false
    var choices: [String] = []
}

struct FieldFormAnswerRow: Identifiable, Equatable {
    let questionID: UUID
    let label: String
    let kind: FieldFormQuestionKind
    let required: Bool
    let answer: String

    var id: UUID { questionID }

    var displayAnswer: String {
        switch kind {
        case .toggle:
            return answer == "true" ? "Yes" : "No"
        case .text, .choice:
            let value = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "Not answered" : value
        }
    }
}

private struct FieldFormAnswerSnapshot {
    let version: Int
    let rows: [FieldFormAnswerRow]
}

enum FieldFormCompletionPolicy {
    static func validationIssue(
        questions: [FieldFormQuestion],
        answers: [UUID: String]
    ) -> String? {
        let missing = questions.compactMap { question -> String? in
            guard question.required else { return nil }
            let answer = answers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch question.kind {
            case .toggle:
                return answer == "true" ? nil : question.label
            case .text, .choice:
                return answer.isEmpty ? question.label : nil
            }
        }
        guard !missing.isEmpty else { return nil }
        if missing.count == 1 {
            return "Complete the required field “\(missing[0])” before saving."
        }
        return "Complete all \(missing.count) required fields before saving."
    }

    static func answerRows(
        questions: [FieldFormQuestion],
        answers: [UUID: String]
    ) -> [FieldFormAnswerRow] {
        questions.map { question in
            FieldFormAnswerRow(
                questionID: question.id,
                label: question.label,
                kind: question.kind,
                required: question.required,
                answer: answers[question.id] ?? ""
            )
        }
    }
}

enum FieldFormTemplatePolicy {
    static func validationIssue(title: String, questions: [FieldFormQuestion]) -> String? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter a form title."
        }
        guard !questions.isEmpty else {
            return "Add at least one field."
        }
        guard questions.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return "Every field needs a label."
        }
        for question in questions where question.kind == .choice {
            let choices = normalizedChoices(question.choices)
            guard choices.count >= 2 else {
                return "“\(question.label)” needs at least two distinct choices."
            }
        }
        return nil
    }

    static func normalizedChoices(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}

nonisolated private struct FieldFormAssignmentEnvelope: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let serviceTypes: [String]
    let requiredForCloseout: Bool
}

@Model
final class FieldFormTemplate {
    var id: UUID = UUID()
    var title: String = ""
    var questionsJSON: String = "[]"
    var applicableServiceTypesJSON: String?
    var isActive: Bool = true
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        title: String,
        questions: [FieldFormQuestion],
        applicableServiceTypes: Set<ServiceCallType> = [],
        requiresCompletionForCloseout: Bool = false,
        isActive: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.questionsJSON = Self.encode(questions) ?? "[]"
        self.applicableServiceTypesJSON = Self.assignmentJSON(
            serviceTypes: applicableServiceTypes,
            requiredForCloseout: requiresCompletionForCloseout
        )
        self.isActive = isActive
        self.createdAt = createdAt
    }

    var questions: [FieldFormQuestion] {
        Self.decode(questionsJSON) ?? []
    }

    var applicableServiceTypes: Set<ServiceCallType> {
        if let envelope = Self.assignmentEnvelope(from: applicableServiceTypesJSON) {
            return Set(envelope.serviceTypes.compactMap(ServiceCallType.init(rawValue:)))
        }
        return Set((Self.decode(applicableServiceTypesJSON) ?? []).compactMap(ServiceCallType.init(rawValue:)))
    }

    var requiresCompletionForCloseout: Bool {
        Self.assignmentEnvelope(from: applicableServiceTypesJSON)?.requiredForCloseout ?? false
    }

    var hasVersionedAssignment: Bool {
        Self.assignmentEnvelope(from: applicableServiceTypesJSON) != nil
    }

    func applies(to type: ServiceCallType) -> Bool {
        let types = applicableServiceTypes
        return types.isEmpty || types.contains(type)
    }

    var scopeSummary: String {
        let types = applicableServiceTypes
        guard !types.isEmpty else { return "All job types" }
        return ServiceCallType.allCases
            .filter(types.contains)
            .map(\.displayName)
            .joined(separator: ", ")
    }

    func makeRevision(
        title: String,
        questions: [FieldFormQuestion],
        applicableServiceTypes: Set<ServiceCallType>
    ) -> FieldFormTemplate {
        makeRevision(
            title: title,
            questions: questions,
            applicableServiceTypes: applicableServiceTypes,
            requiresCompletionForCloseout: requiresCompletionForCloseout
        )
    }

    func makeRevision(
        title: String,
        questions: [FieldFormQuestion],
        applicableServiceTypes: Set<ServiceCallType>,
        requiresCompletionForCloseout: Bool
    ) -> FieldFormTemplate {
        isActive = false
        return FieldFormTemplate(
            title: title,
            questions: questions,
            applicableServiceTypes: applicableServiceTypes,
            requiresCompletionForCloseout: requiresCompletionForCloseout
        )
    }

    func updateAssignment(
        serviceTypes: Set<ServiceCallType>,
        requiredForCloseout: Bool
    ) {
        applicableServiceTypesJSON = Self.assignmentJSON(
            serviceTypes: serviceTypes,
            requiredForCloseout: requiredForCloseout
        )
    }

    static func ensureStarterTemplates(in modelContext: ModelContext) {
        let existing = (try? modelContext.fetch(FetchDescriptor<FieldFormTemplate>())) ?? []
        let operationalHVACTypes: Set<ServiceCallType> = [.service, .repair, .replacement, .maintenance, .install]
        let starters = [FieldFormTemplate(
            title: "HVAC Safety Check",
            questions: [
                FieldFormQuestion(label: "Electrical disconnect inspected", kind: .toggle, required: true),
                FieldFormQuestion(label: "Combustion or refrigerant concern observed", kind: .choice, required: true, choices: ["No", "Yes — documented in findings"]),
                FieldFormQuestion(label: "Safety notes", kind: .text)
            ],
            applicableServiceTypes: operationalHVACTypes,
            requiresCompletionForCloseout: true
        ), FieldFormTemplate(
            title: "Service Diagnostic",
            questions: [
                FieldFormQuestion(label: "Customer concern verified", kind: .toggle, required: true),
                FieldFormQuestion(label: "Diagnostic findings documented", kind: .toggle, required: true),
                FieldFormQuestion(label: "Recommended repair or next step reviewed", kind: .toggle, required: true),
                FieldFormQuestion(label: "Diagnostic notes", kind: .text)
            ],
            applicableServiceTypes: [.service],
            requiresCompletionForCloseout: true
        ), FieldFormTemplate(
            title: "Repair Completion",
            questions: [
                FieldFormQuestion(label: "Repaired component or assembly", kind: .text, required: true),
                FieldFormQuestion(label: "Repair and installed parts documented", kind: .toggle, required: true),
                FieldFormQuestion(label: "Final system operation verified", kind: .toggle, required: true),
                FieldFormQuestion(label: "Repair classification", kind: .choice, required: true, choices: ["Standard repair", "Warranty — linked in job", "Callback — linked in job"]),
                FieldFormQuestion(label: "Repair notes", kind: .text)
            ],
            applicableServiceTypes: [.repair],
            requiresCompletionForCloseout: true
        ), FieldFormTemplate(
            title: "Replacement Commissioning",
            questions: [
                FieldFormQuestion(label: "Replacement model and serial verified", kind: .toggle, required: true),
                FieldFormQuestion(label: "Removed equipment disposition", kind: .choice, required: true, choices: ["Removed / recycled", "Left with customer", "Not applicable"]),
                FieldFormQuestion(label: "Startup readings and commissioning completed", kind: .toggle, required: true),
                FieldFormQuestion(label: "Safety and permit / inspection status reviewed", kind: .toggle, required: true),
                FieldFormQuestion(label: "Customer orientation and warranty registration reviewed", kind: .toggle, required: true),
                FieldFormQuestion(label: "Replacement notes", kind: .text)
            ],
            applicableServiceTypes: [.replacement],
            requiresCompletionForCloseout: true
        ), FieldFormTemplate(
            title: "Install Start-Up",
            questions: [
                FieldFormQuestion(label: "Model and serial verified", kind: .toggle, required: true),
                FieldFormQuestion(label: "System operation confirmed", kind: .toggle, required: true),
                FieldFormQuestion(label: "Customer orientation completed", kind: .toggle, required: true),
                FieldFormQuestion(label: "Start-up notes", kind: .text)
            ],
            applicableServiceTypes: [.install],
            requiresCompletionForCloseout: true
        )]
        let existingByTitle = Dictionary(grouping: existing, by: { normalizedStarterTitle($0.title) })
        for starter in starters {
            let key = normalizedStarterTitle(starter.title)
            if let installed = existingByTitle[key]?.sorted(by: { $0.createdAt > $1.createdAt }).first {
                // Upgrade only the legacy array payload. Once an administrator
                // saves a versioned assignment, startup never overwrites it.
                if !installed.hasVersionedAssignment {
                    installed.updateAssignment(
                        serviceTypes: starter.applicableServiceTypes,
                        requiredForCloseout: true
                    )
                }
            } else {
                modelContext.insert(starter)
            }
        }
    }

    private static func normalizedStarterTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func assignmentEnvelope(from value: String?) -> FieldFormAssignmentEnvelope? {
        guard let envelope: FieldFormAssignmentEnvelope = decode(value),
              envelope.version == FieldFormAssignmentEnvelope.currentVersion else {
            return nil
        }
        return envelope
    }

    private static func assignmentJSON(
        serviceTypes: Set<ServiceCallType>,
        requiredForCloseout: Bool
    ) -> String? {
        let orderedTypes = ServiceCallType.allCases
            .filter(serviceTypes.contains)
            .map(\.rawValue)
        return encode(FieldFormAssignmentEnvelope(
            version: FieldFormAssignmentEnvelope.currentVersion,
            serviceTypes: orderedTypes,
            requiredForCloseout: requiredForCloseout
        ))
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode<T: Decodable>(_ value: String?) -> T? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

@Model
final class FieldFormResponse {
    var id: UUID = UUID()
    var serviceCallID: UUID = UUID()
    var templateID: UUID = UUID()
    var templateTitle: String = ""
    var answersJSON: String = "{}"
    var completedByEmail: String?
    var completedAt: Date = Date()

    init(id: UUID = UUID(), serviceCallID: UUID, template: FieldFormTemplate, answers: [UUID: String], completedByEmail: String? = nil, completedAt: Date = Date()) {
        self.id = id
        self.serviceCallID = serviceCallID
        self.templateID = template.id
        self.templateTitle = template.title
        let snapshot = FieldFormAnswerSnapshot(
            version: 1,
            rows: FieldFormCompletionPolicy.answerRows(questions: template.questions, answers: answers)
        )
        self.answersJSON = Self.encodeSnapshot(snapshot) ?? Self.encode(answers) ?? "{}"
        self.completedByEmail = completedByEmail
        self.completedAt = completedAt
    }

    var answers: [UUID: String] {
        if let snapshot = Self.decodeSnapshot(answersJSON) {
            return Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.questionID, $0.answer) })
        }
        return Self.decode(answersJSON) ?? [:]
    }

    var snapshotAnswerRows: [FieldFormAnswerRow] {
        let snapshot = Self.decodeSnapshot(answersJSON)
        return snapshot?.rows ?? []
    }

    func answerRows(resolving template: FieldFormTemplate?) -> [FieldFormAnswerRow] {
        if !snapshotAnswerRows.isEmpty {
            return snapshotAnswerRows
        }
        let legacyAnswers = answers
        if let template {
            return FieldFormCompletionPolicy.answerRows(
                questions: template.questions,
                answers: legacyAnswers
            )
        }
        return legacyAnswers
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .enumerated()
            .map { index, entry in
                FieldFormAnswerRow(
                    questionID: entry.key,
                    label: "Recorded field \(index + 1)",
                    kind: .text,
                    required: false,
                    answer: entry.value
                )
            }
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode<T: Decodable>(_ value: String) -> T? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func encodeSnapshot(_ snapshot: FieldFormAnswerSnapshot) -> String? {
        let object: [String: Any] = [
            "version": snapshot.version,
            "rows": snapshot.rows.map { row in
                [
                    "questionID": row.questionID.uuidString,
                    "label": row.label,
                    "kind": row.kind.rawValue,
                    "required": row.required,
                    "answer": row.answer
                ]
            }
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeSnapshot(_ value: String) -> FieldFormAnswerSnapshot? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int,
              let rawRows = object["rows"] as? [[String: Any]] else {
            return nil
        }
        let rows = rawRows.compactMap { raw -> FieldFormAnswerRow? in
            guard let idValue = raw["questionID"] as? String,
                  let questionID = UUID(uuidString: idValue),
                  let label = raw["label"] as? String,
                  let kindValue = raw["kind"] as? String,
                  let kind = FieldFormQuestionKind(rawValue: kindValue),
                  let required = raw["required"] as? Bool,
                  let answer = raw["answer"] as? String else {
                return nil
            }
            return FieldFormAnswerRow(
                questionID: questionID,
                label: label,
                kind: kind,
                required: required,
                answer: answer
            )
        }
        guard rows.count == rawRows.count else { return nil }
        return FieldFormAnswerSnapshot(version: version, rows: rows)
    }
}

struct FieldFormCloseoutRequirement: Identifiable, Equatable {
    let templateID: UUID
    let title: String

    var id: UUID { templateID }
    var closeoutItem: String { "Field form: \(title)" }
}

struct FieldFormCloseoutReadiness: Equatable {
    let requirements: [FieldFormCloseoutRequirement]
    let missingRequirements: [FieldFormCloseoutRequirement]

    var completedCount: Int { requirements.count - missingRequirements.count }
    var totalCount: Int { requirements.count }
    var isReady: Bool { missingRequirements.isEmpty }

    var statusLabel: String {
        guard totalCount > 0 else { return "No required forms" }
        return isReady
            ? "\(totalCount) required form\(totalCount == 1 ? "" : "s") complete"
            : "\(completedCount)/\(totalCount) required forms complete"
    }
}

enum FieldFormCloseoutPolicy {
    static func readiness(
        serviceCallID: UUID,
        serviceType: ServiceCallType,
        templates: [FieldFormTemplate],
        responses: [FieldFormResponse]
    ) -> FieldFormCloseoutReadiness {
        let scopedResponses = responses.filter { $0.serviceCallID == serviceCallID }
        let completedTemplateIDs = Set(scopedResponses.map(\.templateID))
        let completedTitles = Set(scopedResponses.map { normalizedTitle($0.templateTitle) })

        var seenTitles = Set<String>()
        let requirements = templates
            .filter {
                $0.isActive &&
                    $0.requiresCompletionForCloseout &&
                    $0.applies(to: serviceType)
            }
            .sorted {
                let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
                return titleOrder == .orderedSame ? $0.createdAt > $1.createdAt : titleOrder == .orderedAscending
            }
            .compactMap { template -> FieldFormCloseoutRequirement? in
                let titleKey = normalizedTitle(template.title)
                guard !titleKey.isEmpty, seenTitles.insert(titleKey).inserted else { return nil }
                return FieldFormCloseoutRequirement(templateID: template.id, title: template.title)
            }

        let missing = requirements.filter { requirement in
            !completedTemplateIDs.contains(requirement.templateID) &&
                !completedTitles.contains(normalizedTitle(requirement.title))
        }
        return FieldFormCloseoutReadiness(
            requirements: requirements,
            missingRequirements: missing
        )
    }

    static func responseCompletes(
        _ template: FieldFormTemplate,
        serviceCallID: UUID,
        responses: [FieldFormResponse]
    ) -> Bool {
        latestResponse(
            completing: template,
            serviceCallID: serviceCallID,
            responses: responses
        ) != nil
    }

    static func latestResponse(
        completing template: FieldFormTemplate,
        serviceCallID: UUID,
        responses: [FieldFormResponse]
    ) -> FieldFormResponse? {
        let titleKey = normalizedTitle(template.title)
        return responses
            .filter { response in
                response.serviceCallID == serviceCallID &&
                    (response.templateID == template.id || normalizedTitle(response.templateTitle) == titleKey)
            }
            .max(by: { $0.completedAt < $1.completedAt })
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct FieldFormResponseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let template: FieldFormTemplate
    let serviceCall: ServiceCall
    let actorEmail: String?
    @State private var answers: [UUID: String] = [:]
    @State private var validationMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Job") {
                    LabeledContent("Customer", value: serviceCall.customer.name)
                    LabeledContent("Work", value: serviceCall.type.displayName)
                    if template.requiresCompletionForCloseout {
                        Label("Required for closeout", systemImage: "checkmark.seal")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    Text("Saving creates a read-only PDF in this job’s Files. If the job is linked to an estimate or invoice, the file keeps that transaction link for QuickBooks attachment recovery.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(template.title) {
                    ForEach(template.questions) { question in
                        questionView(question)
                    }
                }
                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Complete Form")
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("SaveCompletedFieldForm")
                }
            }
        }
    }

    @ViewBuilder private func questionView(_ question: FieldFormQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(question.label)
                    .font(.subheadline.weight(.semibold))
                if question.required {
                    Text("Required")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            switch question.kind {
            case .toggle:
                Toggle(
                    question.required ? "Confirmed" : "Yes",
                    isOn: Binding(
                        get: { answers[question.id] == "true" },
                        set: { answers[question.id] = $0 ? "true" : "false" }
                    )
                )
            case .text:
                TextField(
                    "Enter response",
                    text: Binding(
                        get: { answers[question.id] ?? "" },
                        set: { answers[question.id] = $0 }
                    ),
                    axis: .vertical
                )
                .lineLimit(2...6)
            case .choice:
                Picker(
                    "Response",
                    selection: Binding(
                        get: { answers[question.id] ?? "" },
                        set: { answers[question.id] = $0 }
                    )
                ) {
                    Text("Select").tag("")
                    ForEach(question.choices, id: \.self) { Text($0).tag($0) }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func save() {
        if let issue = FieldFormCompletionPolicy.validationIssue(
            questions: template.questions,
            answers: answers
        ) {
            validationMessage = issue
            return
        }
        isSaving = true
        validationMessage = nil
        let response = FieldFormResponse(
            serviceCallID: serviceCall.id,
            template: template,
            answers: answers,
            completedByEmail: actorEmail
        )
        var insertedAttachment: ServiceDocumentAttachment?
        do {
            let url = try CustomerDocumentExporter.exportFieldFormResponse(
                response,
                serviceCall: serviceCall,
                template: template
            )
            let data = try Data(contentsOf: url)
            let attachment = ServiceDocumentAttachment(
                customer: serviceCall.customer,
                serviceCallID: serviceCall.id,
                invoiceID: serviceCall.linkedInvoiceID,
                estimateID: serviceCall.linkedEstimateID,
                kind: .customerDocument,
                displayName: url.lastPathComponent,
                caption: "Completed field form: \(template.title) [FieldFormResponse:\(response.id.uuidString)]",
                localFilePath: url.path,
                contentType: "application/pdf",
                fileSizeBytes: data.count
            )
            insertedAttachment = attachment
            modelContext.insert(response)
            modelContext.insert(attachment)
            try modelContext.save()
            ServiceCallActivity.record(
                for: serviceCall,
                action: "Field form completed",
                detail: "Completed \(template.title); saved a PDF in job Files.",
                actorEmail: actorEmail,
                in: modelContext
            )
            try? modelContext.save()
            syncAttachmentIfPossible(attachment, data: data)
            dismiss()
        } catch {
            modelContext.delete(response)
            if let insertedAttachment {
                modelContext.delete(insertedAttachment)
            }
            isSaving = false
            validationMessage = "Could not save the completed form and PDF: \(error.localizedDescription)"
        }
    }

    private func syncAttachmentIfPossible(_ attachment: ServiceDocumentAttachment, data: Data) {
        guard GunnAireBackendService.isConfigured else { return }
        Task { @MainActor in
            do {
                let stored = try await GunnAireBackendService.uploadDocument(
                    data: data,
                    filename: attachment.displayName,
                    contentType: attachment.contentType,
                    kind: attachment.kindRaw,
                    serviceCallID: attachment.serviceCallID,
                    invoiceID: attachment.invoiceID,
                    estimateID: attachment.estimateID,
                    customerName: attachment.customer?.name
                )
                attachment.markSharedCompanyStored(id: stored.id)
            } catch {
                attachment.markSharedCompanyUploadFailed(error.localizedDescription)
            }
            try? modelContext.save()
        }
    }
}

struct FieldFormResponseDetailView: View {
    let response: FieldFormResponse
    let template: FieldFormTemplate?
    let serviceCall: ServiceCall
    let attachment: ServiceDocumentAttachment?
    @State private var exportURL: URL?
    @State private var exportMessage: String?

    private var rows: [FieldFormAnswerRow] {
        response.answerRows(resolving: template)
    }

    var body: some View {
        Form {
            Section("Completion") {
                LabeledContent("Form", value: response.templateTitle)
                LabeledContent("Customer", value: serviceCall.customer.name)
                LabeledContent("Job", value: serviceCall.type.displayName)
                LabeledContent("Completed", value: response.completedAt.formatted(date: .abbreviated, time: .shortened))
                if let completedByEmail = response.completedByEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !completedByEmail.isEmpty {
                    LabeledContent("Completed by", value: completedByEmail)
                }
            }
            Section("Responses") {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.label)
                            .font(.subheadline.weight(.semibold))
                        Text(row.displayAnswer)
                            .foregroundStyle(row.displayAnswer == "Not answered" ? .secondary : .primary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let exportMessage {
                Section {
                    Label(exportMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(response.templateTitle)
        .toolbar {
            if let exportURL {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: exportURL) {
                        Label("Share PDF", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("ShareCompletedFieldFormPDF")
                }
            }
        }
        .task(id: response.id) {
            prepareExportURL()
        }
    }

    private func prepareExportURL() {
        if let attachment,
           FileManager.default.fileExists(atPath: attachment.localFilePath) {
            exportURL = attachment.localFileURL
            exportMessage = nil
            return
        }
        do {
            exportURL = try CustomerDocumentExporter.exportFieldFormResponse(
                response,
                serviceCall: serviceCall,
                template: template
            )
            exportMessage = nil
        } catch {
            exportMessage = "The PDF could not be prepared: \(error.localizedDescription)"
        }
    }
}

struct CompletedFieldFormsView: View {
    let responses: [FieldFormResponse]
    let templates: [FieldFormTemplate]
    let serviceCall: ServiceCall
    let attachments: [ServiceDocumentAttachment]

    var body: some View {
        List(responses) { response in
            NavigationLink {
                FieldFormResponseDetailView(
                    response: response,
                    template: templates.first { $0.id == response.templateID },
                    serviceCall: serviceCall,
                    attachment: attachment(for: response)
                )
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(response.templateTitle)
                        .font(.headline)
                    Text(response.completedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Completed Forms")
    }

    private func attachment(for response: FieldFormResponse) -> ServiceDocumentAttachment? {
        let marker = "[FieldFormResponse:\(response.id.uuidString)]"
        return attachments.first {
            $0.serviceCallID == serviceCall.id && ($0.caption?.contains(marker) ?? false)
        }
    }
}

private enum FieldFormTemplateEditorMode: Identifiable {
    case create
    case revise(FieldFormTemplate)
    case duplicate(FieldFormTemplate)

    var id: String {
        switch self {
        case .create: "create"
        case .revise(let template): "revise-\(template.id.uuidString)"
        case .duplicate(let template): "duplicate-\(template.id.uuidString)"
        }
    }

    var sourceTemplate: FieldFormTemplate? {
        switch self {
        case .create: nil
        case .revise(let template), .duplicate(let template): template
        }
    }
}

struct FieldFormTemplateManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FieldFormTemplate.createdAt, order: .forward) private var templates: [FieldFormTemplate]
    @State private var editorMode: FieldFormTemplateEditorMode?

    private var orderedTemplates: [FieldFormTemplate] {
        templates.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.title != rhs.title {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reusable Forms") {
                    if orderedTemplates.isEmpty {
                        ContentUnavailableView(
                            "No field forms",
                            systemImage: "checklist",
                            description: Text("Create a form for service, repair, installation, maintenance, or another job type.")
                        )
                    }
                    ForEach(orderedTemplates) { template in
                        templateRow(template)
                    }
                }
                Section("Version Safety") {
                    Text("Revising creates a new active template and retires the prior version. Completed jobs keep their original question labels, answers, technician, timestamp, and PDF.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Field Form Templates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editorMode = .create
                    } label: {
                        Label("New Form", systemImage: "plus")
                    }
                    .accessibilityIdentifier("CreateFieldFormTemplate")
                }
            }
            .sheet(item: $editorMode) { mode in
                FieldFormTemplateEditor(mode: mode)
            }
            .onAppear {
                FieldFormTemplate.ensureStarterTemplates(in: modelContext)
                try? modelContext.save()
            }
        }
    }

    private func templateRow(_ template: FieldFormTemplate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(template.title)
                    .font(.headline)
                Text("\(template.questions.count) \(template.questions.count == 1 ? "field" : "fields") • \(template.scopeSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if template.requiresCompletionForCloseout {
                    Text("Required for closeout")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                if !template.isActive {
                    Text("Retired")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Toggle(
                "Active",
                isOn: Binding(
                    get: { template.isActive },
                    set: { newValue in
                        template.isActive = newValue
                        try? modelContext.save()
                    }
                )
            )
            .labelsHidden()
            .accessibilityLabel("\(template.title) active")
            Menu {
                Button {
                    editorMode = .revise(template)
                } label: {
                    Label("Revise", systemImage: "square.and.pencil")
                }
                Button {
                    editorMode = .duplicate(template)
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Actions for \(template.title)")
        }
    }
}

private struct FieldFormTemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let mode: FieldFormTemplateEditorMode
    @State private var title: String
    @State private var questions: [FieldFormQuestion]
    @State private var selectedTypes: Set<ServiceCallType>
    @State private var requiresCompletionForCloseout: Bool
    @State private var validationMessage: String?

    init(mode: FieldFormTemplateEditorMode) {
        self.mode = mode
        let source = mode.sourceTemplate
        let initialTitle: String
        switch mode {
        case .duplicate:
            initialTitle = source.map { "\($0.title) Copy" } ?? ""
        case .create, .revise:
            initialTitle = source?.title ?? ""
        }
        _title = State(initialValue: initialTitle)
        _questions = State(initialValue: source?.questions ?? [
            FieldFormQuestion(label: "", kind: .toggle, required: true)
        ])
        _selectedTypes = State(initialValue: source?.applicableServiceTypes ?? [])
        switch mode {
        case .revise:
            _requiresCompletionForCloseout = State(initialValue: source?.requiresCompletionForCloseout ?? false)
        case .create, .duplicate:
            _requiresCompletionForCloseout = State(initialValue: false)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Form") {
                    TextField("Form title", text: $title)
                        .accessibilityIdentifier("FieldFormTemplateTitle")
                    DisclosureGroup("Job types") {
                        Text("Leave every type off to make this form available for all jobs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(ServiceCallType.allCases, id: \.rawValue) { type in
                            Toggle(type.displayName, isOn: serviceTypeBinding(type))
                        }
                    }
                    Text(selectedTypes.isEmpty ? "Applies to all job types" : selectedTypes.map(\.displayName).sorted().joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Required for job closeout", isOn: $requiresCompletionForCloseout)
                        .accessibilityIdentifier("FieldFormRequiredForCloseout")
                    Text(requiresCompletionForCloseout
                         ? "Every matching job must complete this form before closeout."
                         : "The form stays available when useful but does not block closeout.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Fields") {
                    ForEach($questions) { $question in
                        questionEditor(question: $question)
                    }
                    .onDelete { questions.remove(atOffsets: $0) }
                    .onMove { questions.move(fromOffsets: $0, toOffset: $1) }

                    Menu {
                        ForEach(FieldFormQuestionKind.allCases) { kind in
                            Button {
                                addQuestion(kind)
                            } label: {
                                Label(kind.displayName, systemImage: kind.systemImage)
                            }
                        }
                    } label: {
                        Label("Add Field", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("AddFieldFormQuestion")
                }
                if case .revise = mode {
                    Section("Revision") {
                        Text("Saving retires the current template and creates a new active version. Existing completed forms and PDFs are not changed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    EditButton()
                        .disabled(questions.count < 2)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier("SaveFieldFormTemplate")
                }
            }
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .create: "New Field Form"
        case .revise: "Revise Field Form"
        case .duplicate: "Duplicate Field Form"
        }
    }

    private func serviceTypeBinding(_ type: ServiceCallType) -> Binding<Bool> {
        Binding(
            get: { selectedTypes.contains(type) },
            set: { isSelected in
                if isSelected { selectedTypes.insert(type) }
                else { selectedTypes.remove(type) }
            }
        )
    }

    private func questionEditor(question: Binding<FieldFormQuestion>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Field label", text: question.label)
            Picker("Type", selection: question.kind) {
                ForEach(FieldFormQuestionKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Required before completion", isOn: question.required)
            if question.wrappedValue.kind == .choice {
                TextField("Choices — one per line", text: choicesBinding(question), axis: .vertical)
                    .lineLimit(2...6)
                Text("Enter at least two distinct choices.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func choicesBinding(_ question: Binding<FieldFormQuestion>) -> Binding<String> {
        Binding(
            get: { question.wrappedValue.choices.joined(separator: "\n") },
            set: { value in
                question.wrappedValue.choices = value
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
            }
        )
    }

    private func addQuestion(_ kind: FieldFormQuestionKind) {
        questions.append(FieldFormQuestion(
            label: "",
            kind: kind,
            required: false,
            choices: kind == .choice ? ["Pass", "Flag", "Fail"] : []
        ))
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanQuestions = questions.map { question in
            FieldFormQuestion(
                id: question.id,
                label: question.label.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: question.kind,
                required: question.required,
                choices: question.kind == .choice
                    ? FieldFormTemplatePolicy.normalizedChoices(question.choices)
                    : []
            )
        }
        if let issue = FieldFormTemplatePolicy.validationIssue(title: cleanTitle, questions: cleanQuestions) {
            validationMessage = issue
            return
        }

        switch mode {
        case .create, .duplicate:
            modelContext.insert(FieldFormTemplate(
                title: cleanTitle,
                questions: cleanQuestions,
                applicableServiceTypes: selectedTypes,
                requiresCompletionForCloseout: requiresCompletionForCloseout
            ))
        case .revise(let source):
            modelContext.insert(source.makeRevision(
                title: cleanTitle,
                questions: cleanQuestions,
                applicableServiceTypes: selectedTypes,
                requiresCompletionForCloseout: requiresCompletionForCloseout
            ))
        }
        do {
            try modelContext.save()
            dismiss()
        } catch {
            validationMessage = "Could not save this form: \(error.localizedDescription)"
        }
    }
}
