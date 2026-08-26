import Foundation
import SwiftData
import SwiftUI

enum FieldFormQuestionKind: String, Codable, CaseIterable, Identifiable {
    case toggle
    case text
    case choice

    var id: String { rawValue }
}

struct FieldFormQuestion: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var label: String
    var kind: FieldFormQuestionKind
    var required: Bool = false
    var choices: [String] = []
}

@Model
final class FieldFormTemplate {
    var id: UUID = UUID()
    var title: String = ""
    var questionsJSON: String = "[]"
    var applicableServiceTypesJSON: String?
    var isActive: Bool = true
    var createdAt: Date = Date()

    init(id: UUID = UUID(), title: String, questions: [FieldFormQuestion], applicableServiceTypes: Set<ServiceCallType> = [], isActive: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.questionsJSON = Self.encode(questions) ?? "[]"
        self.applicableServiceTypesJSON = Self.encode(Array(applicableServiceTypes.map(\.rawValue)))
        self.isActive = isActive
        self.createdAt = createdAt
    }

    var questions: [FieldFormQuestion] {
        Self.decode(questionsJSON) ?? []
    }

    var applicableServiceTypes: Set<ServiceCallType> {
        Set((Self.decode(applicableServiceTypesJSON) ?? []).compactMap(ServiceCallType.init(rawValue:)))
    }

    func applies(to type: ServiceCallType) -> Bool {
        let types = applicableServiceTypes
        return types.isEmpty || types.contains(type)
    }

    static func ensureStarterTemplates(in modelContext: ModelContext) {
        let existing = (try? modelContext.fetch(FetchDescriptor<FieldFormTemplate>())) ?? []
        guard existing.isEmpty else { return }
        modelContext.insert(FieldFormTemplate(
            title: "HVAC Safety Check",
            questions: [
                FieldFormQuestion(label: "Electrical disconnect inspected", kind: .toggle, required: true),
                FieldFormQuestion(label: "Combustion or refrigerant concern observed", kind: .choice, required: true, choices: ["No", "Yes — documented in findings"]),
                FieldFormQuestion(label: "Safety notes", kind: .text)
            ]
        ))
        modelContext.insert(FieldFormTemplate(
            title: "Install Start-Up",
            questions: [
                FieldFormQuestion(label: "Model and serial verified", kind: .toggle, required: true),
                FieldFormQuestion(label: "System operation confirmed", kind: .toggle, required: true),
                FieldFormQuestion(label: "Customer orientation completed", kind: .toggle, required: true),
                FieldFormQuestion(label: "Start-up notes", kind: .text)
            ],
            applicableServiceTypes: [.install]
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
        self.answersJSON = Self.encode(answers) ?? "{}"
        self.completedByEmail = completedByEmail
        self.completedAt = completedAt
    }

    var answers: [UUID: String] { Self.decode(answersJSON) ?? [:] }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode<T: Decodable>(_ value: String) -> T? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
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

    var body: some View {
        NavigationStack {
            Form {
                Section(template.title) {
                    ForEach(template.questions) { question in
                        questionView(question)
                    }
                }
                if let validationMessage {
                    Text(validationMessage).foregroundStyle(.orange)
                }
            }
            .navigationTitle("Complete Form")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
    }

    @ViewBuilder private func questionView(_ question: FieldFormQuestion) -> some View {
        switch question.kind {
        case .toggle:
            Toggle(question.label, isOn: Binding(get: { answers[question.id] == "true" }, set: { answers[question.id] = $0 ? "true" : "false" }))
        case .text:
            TextField(question.label, text: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 }), axis: .vertical)
                .lineLimit(2...5)
        case .choice:
            Picker(question.label, selection: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 })) {
                Text("Select").tag("")
                ForEach(question.choices, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    private func save() {
        let missing = template.questions.contains { question in
            question.required && (answers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        guard !missing else { validationMessage = "Complete the required form fields before saving."; return }
        modelContext.insert(FieldFormResponse(serviceCallID: serviceCall.id, template: template, answers: answers, completedByEmail: actorEmail))
        ServiceCallActivity.record(for: serviceCall, action: "Field form completed", detail: "Completed \(template.title).", actorEmail: actorEmail, in: modelContext)
        try? modelContext.save()
        dismiss()
    }
}

struct FieldFormTemplateManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FieldFormTemplate.createdAt, order: .forward) private var templates: [FieldFormTemplate]
    @State private var title = ""
    @State private var questionLines = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Active Forms") {
                    if templates.isEmpty {
                        Text("Starter forms will appear when a job detail is opened.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(templates) { template in
                        Toggle(template.title, isOn: Binding(get: { template.isActive }, set: { template.isActive = $0 }))
                    }
                }
                Section("Create a Short Checklist") {
                    TextField("Form Title", text: $title)
                    TextField("One checklist item per line", text: $questionLines, axis: .vertical)
                        .lineLimit(3...8)
                    Button("Add Checklist") {
                        let questions = questionLines
                            .split(whereSeparator: \.isNewline)
                            .map { FieldFormQuestion(label: String($0).trimmingCharacters(in: .whitespacesAndNewlines), kind: .toggle) }
                            .filter { !$0.label.isEmpty }
                        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !questions.isEmpty else { return }
                        modelContext.insert(FieldFormTemplate(title: title.trimmingCharacters(in: .whitespacesAndNewlines), questions: questions))
                        title = ""
                        questionLines = ""
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || questionLines.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Field Form Templates")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { FieldFormTemplate.ensureStarterTemplates(in: modelContext) }
        }
    }
}
