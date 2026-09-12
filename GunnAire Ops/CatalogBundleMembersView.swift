import SwiftUI

struct CatalogBundleEditRequest: Identifiable {
    let id = UUID()
    let snapshot: CatalogLineItemSnapshot
    let memberID: UUID?
}

struct CatalogBundleMembersView: View {
    let snapshot: CatalogLineItemSnapshot
    let onChange: (CatalogLineItemSnapshot) -> Void
    let onEdit: (UUID?) -> Void
    @State private var message: String?

    var body: some View {
        DisclosureGroup("Included Items (\(snapshot.bundle?.members.count ?? 0))") {
            Button { onEdit(nil) } label: {
                Text("Bundle quantity: \(snapshot.quantity.formatted(.number.precision(.fractionLength(0...5))))")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("EditBundleQuantity-\(snapshot.catalogItemID)")
            ForEach(Array((snapshot.bundle?.members ?? []).enumerated()), id: \.element.id) { index, member in
                HStack {
                    Button { onEdit(member.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(member.line.name)
                            Text("\(member.line.quantity.formatted(.number.precision(.fractionLength(0...5)))) × \(QuickBooksSalesLineContract.unitPriceLabel(member.line.unitPrice))\(member.line.isTaxable ? " · Taxable" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("EditBundleMember-\(snapshot.catalogItemID)-\(index)")
                    Spacer()
                    Text(member.line.extendedAmount, format: .currency(code: "USD"))
                    Button(role: .destructive) {
                        do { onChange(try CatalogBundlePolicy.editMember(snapshot, memberID: member.id, quantity: nil)); message = nil }
                        catch { message = error.localizedDescription }
                    } label: {
                        Image(systemName: "minus.circle").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove included item \(index + 1), \(member.line.name)")
                    .accessibilityIdentifier("RemoveBundleMember-\(snapshot.catalogItemID)-\(index)")
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            Text("Edits affect this document only. Office approval may be needed before QuickBooks sync.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disclosureGroupStyle(CatalogBundleDisclosureStyle())
    }
}

/// SwiftUI's automatic disclosure tap handling can activate another disclosure
/// inside the same composite List row. A scoped button toggles only this group.
struct CatalogBundleDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack {
                    configuration.label
                    Spacer()
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).accessibilityHidden(true)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}

/// The billing workspace owns this one presentation, outside lazy List rows.
/// One request identifies either the group quantity or one stable sold member.
struct CatalogBundleEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: CatalogBundleEditRequest
    let canAuthorize: Bool
    let actorEmail: String?
    let users: [AppUser]
    let onSave: (CatalogLineItemSnapshot) -> String?
    var body: some View {
        if let memberID = request.memberID {
            if let member = request.snapshot.bundle?.members.first(where: { $0.id == memberID }) {
                CatalogBundleMemberEditor(member: member, canAuthorize: canAuthorize) { qty, price, taxable, reason in
                    do {
                        return onSave(try CatalogBundlePolicy.editSale(request.snapshot, memberID: memberID,
                            quantity: qty, price: price, taxable: taxable, reason: reason, actorEmail: actorEmail, users: users))
                    } catch { return error.localizedDescription }
                }
            } else {
                NavigationStack {
                    ContentUnavailableView("Included Item Changed", systemImage: "exclamationmark.circle",
                        description: Text("Close this editor and select the included item again. Your draft has not changed."))
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                }
            }
        } else {
            CatalogBundleQuantityEditor(snapshot: request.snapshot, onSave: onSave)
        }
    }
}

private struct CatalogBundleQuantityEditor: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: CatalogLineItemSnapshot
    let onSave: (CatalogLineItemSnapshot) -> String?
    @State private var quantity: String
    @State private var message: String?
    @FocusState private var quantityFocused: Bool
    init(snapshot: CatalogLineItemSnapshot, onSave: @escaping (CatalogLineItemSnapshot) -> String?) {
        self.snapshot = snapshot; self.onSave = onSave
        _quantity = State(initialValue: String(snapshot.quantity))
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Bundle Quantity", text: $quantity).catalogNumericKeyboard()
                    .focused($quantityFocused)
                    .submitLabel(.done).onSubmit { quantityFocused = false }
                    .accessibilityIdentifier("BundleQuantity")
                Text("Changing this quantity scales the saved included items. Removed items stay removed; saved prices stay unchanged.")
                    .foregroundStyle(.secondary)
                if let message { Text(message).foregroundStyle(.orange) }
            }
            .navigationTitle("Bundle Quantity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { quantityFocused = false }
                        .accessibilityIdentifier("BundleKeyboardDone")
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            guard let value = Double(quantity) else { throw CatalogBundleError.invalidQuantity }
                            message = onSave(try CatalogBundlePolicy.resized(snapshot, quantity: value))
                            if message == nil { dismiss() }
                        } catch { message = error.localizedDescription }
                    }
                    .accessibilityIdentifier("SaveBundleQuantity")
                }
            }
        }
    }
}

private struct CatalogBundleMemberEditor: View {
    @Environment(\.dismiss) private var dismiss
    let member: CatalogBundleSnapshot.Member
    let canAuthorize: Bool
    let onSave: (Double, Double, Bool, String) -> String?
    @State private var quantity: String
    @State private var price: String
    @State private var taxable: Bool
    @State private var reason = ""
    @State private var error: String?
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case quantity, price, reason }

    init(member: CatalogBundleSnapshot.Member, canAuthorize: Bool,
         onSave: @escaping (Double, Double, Bool, String) -> String?) {
        self.member = member; self.canAuthorize = canAuthorize; self.onSave = onSave
        _quantity = State(initialValue: String(member.line.quantity))
        _price = State(initialValue: String(member.line.unitPrice))
        _taxable = State(initialValue: member.line.isTaxable)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(member.line.name) {
                    TextField("Quantity", text: $quantity).catalogNumericKeyboard()
                        .focused($focusedField, equals: .quantity)
                        .submitLabel(.done).onSubmit { focusedField = nil }
                        .accessibilityIdentifier("BundleMemberQuantity")
                    if canAuthorize {
                        TextField("Unit Price", text: $price).catalogNumericKeyboard()
                            .focused($focusedField, equals: .price)
                            .submitLabel(.done).onSubmit { focusedField = nil }
                            .accessibilityIdentifier("BundleMemberPrice")
                        Toggle("Taxable", isOn: $taxable)
                        TextField("Reason for price or tax change", text: $reason, axis: .vertical)
                            .focused($focusedField, equals: .reason)
                    } else {
                        LabeledContent("Unit Price", value: QuickBooksSalesLineContract.unitPriceLabel(member.line.unitPrice))
                    }
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("Included Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .accessibilityIdentifier("BundleKeyboardDone")
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let qty = Double(quantity), let cost = Double(price) else {
                            error = "Enter a valid quantity and price."; return
                        }
                        error = onSave(qty, cost, taxable, reason)
                        if error == nil { dismiss() }
                    }
                    .accessibilityIdentifier("SaveBundleMember")
                }
            }
        }
    }
}
