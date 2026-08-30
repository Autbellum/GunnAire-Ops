import SwiftUI

struct WorkPerformedLogComposer: View {
    @Environment(\.dismiss) private var dismiss
    let jobTitle: String
    let onSave: (String) -> Bool

    @State private var content = ""
    @State private var validationMessage: String?

    private var normalizedContent: String {
        ServiceWorkLogPolicy.normalizedContent(content)
    }

    private var canSave: Bool {
        (try? ServiceWorkLogPolicy.validatedContent(content)) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Work Performed") {
                    Text(jobTitle)
                        .font(.headline)
                    TextEditor(text: $content)
                        .frame(minHeight: 190)
                        .accessibilityIdentifier("WorkPerformedLogContent")
                    HStack {
                        Text("Record the work completed, readings acted on, parts changed, and remaining conditions.")
                        Spacer()
                        Text("\(normalizedContent.count)/\(ServiceWorkLogPolicy.maximumContentLength)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Label(
                        "Saving appends an author- and time-stamped entry. Existing entries are never overwritten, including while the device is offline.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("WorkPerformedLogValidation")
                    }
                }
            }
            .navigationTitle("Add Work Log")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            _ = try ServiceWorkLogPolicy.validatedContent(content)
                            validationMessage = nil
                            if onSave(content) { dismiss() }
                        } catch {
                            validationMessage = error.localizedDescription
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("SaveWorkPerformedLog")
                }
            }
        }
        .frame(minWidth: 420, minHeight: 380)
    }
}

struct CustomerWorkSummaryComposer: View {
    @Environment(\.dismiss) private var dismiss
    let jobTitle: String
    let suggestedSummary: String
    let existingSummary: String?
    let workLogCount: Int
    let onSave: (String) -> Bool

    @State private var content: String
    @State private var validationMessage: String?

    init(
        jobTitle: String,
        suggestedSummary: String,
        existingSummary: String?,
        workLogCount: Int,
        onSave: @escaping (String) -> Bool
    ) {
        self.jobTitle = jobTitle
        self.suggestedSummary = suggestedSummary
        self.existingSummary = existingSummary
        self.workLogCount = workLogCount
        self.onSave = onSave
        _content = State(initialValue: existingSummary ?? suggestedSummary)
    }

    private var canSave: Bool {
        (try? ServiceWorkLogPolicy.validatedContent(content)) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer-Facing Work Summary") {
                    Text(jobTitle)
                        .font(.headline)
                    TextEditor(text: $content)
                        .frame(minHeight: 220)
                        .accessibilityIdentifier("CustomerWorkSummaryContent")
                    HStack {
                        Text("Review for accuracy and customer-safe language before saving.")
                        Spacer()
                        Text("\(ServiceWorkLogPolicy.normalizedContent(content).count)/\(ServiceWorkLogPolicy.maximumContentLength)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if !suggestedSummary.isEmpty {
                        Button {
                            content = suggestedSummary
                            validationMessage = nil
                        } label: {
                            Label(
                                existingSummary == nil ? "Use \(workLogCount) Work Log\(workLogCount == 1 ? "" : "s")" : "Rebuild from Work Logs",
                                systemImage: "text.append"
                            )
                        }
                        .accessibilityIdentifier("UseWorkLogsForSummary")
                    }
                }

                Section {
                    Label(
                        "Each save keeps a separate summary revision in job history and updates the service report used for customer documents.",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(existingSummary == nil ? "Create Work Summary" : "Review Work Summary")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Revision") {
                        do {
                            _ = try ServiceWorkLogPolicy.validatedContent(content)
                            validationMessage = nil
                            if onSave(content) { dismiss() }
                        } catch {
                            validationMessage = error.localizedDescription
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("SaveCustomerWorkSummary")
                }
            }
        }
        .frame(minWidth: 460, minHeight: 430)
    }
}
