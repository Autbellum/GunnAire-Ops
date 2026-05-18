import SwiftUI

struct SearchableDropdownOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?

    init(id: String, title: String, subtitle: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

struct SearchableDropdownPicker: View {
    let title: String
    let options: [SearchableDropdownOption]
    @Binding var selectedID: String?
    var placeholder = "Select"
    var showsClearButton = false

    @State private var isPresented = false

    private var selectedOption: SearchableDropdownOption? {
        guard let selectedID else { return nil }
        return options.first { $0.id == selectedID }
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(selectedOption?.title ?? placeholder)
                        .foregroundColor(selectedOption == nil ? .secondary : .primary)
                        .lineLimit(1)
                    if let subtitle = selectedOption?.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresented) {
            SearchableDropdownSheet(
                title: title,
                options: options,
                selectedID: $selectedID,
                showsClearButton: showsClearButton
            )
        }
    }
}

private struct SearchableDropdownSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let options: [SearchableDropdownOption]
    @Binding var selectedID: String?
    let showsClearButton: Bool

    @State private var searchText = ""

    private var filteredOptions: [SearchableDropdownOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return options }
        return options.filter { option in
            option.title.localizedCaseInsensitiveContains(query) ||
            (option.subtitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if showsClearButton {
                    Button {
                        selectedID = nil
                        dismiss()
                    } label: {
                        HStack {
                            Text("None")
                            Spacer()
                            if selectedID == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }

                ForEach(filteredOptions) { option in
                    Button {
                        selectedID = option.id
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title)
                                    .foregroundColor(.primary)
                                if let subtitle = option.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if selectedID == option.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }

                if filteredOptions.isEmpty {
                    Text("No matches")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(title)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
