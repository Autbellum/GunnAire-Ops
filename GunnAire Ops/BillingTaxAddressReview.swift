import SwiftUI
import UIKit

/// Captured once when a review opens. The workspace, not its lazy list row,
/// owns this session while keyboard avoidance changes the underlying layout.
struct BillingTaxAddressReviewRequest: Identifiable {
    let id = UUID()
    let scope: BillingTaxAddressScope
    let initial: BillingTaxAddressContext?
}

/// One compact, stateless entry point in the existing billing editor.
struct BillingTaxAddressReviewControl: View {
    let scope: BillingTaxAddressScope
    let addresses: BillingTaxAddressContext?
    let onReview: () -> Void

    private var reviewed: Bool { addresses.map { (try? $0.validate(for: scope)) != nil } ?? false }
    var body: some View {
        Button(action: onReview) {
            HStack {
                Label("Tax addresses", systemImage: "mappin.and.ellipse")
                Spacer()
                Text(reviewed ? "Reviewed" : "Review needed").font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption)
            }
        }
        .accessibilityIdentifier("BillingTaxAddresses")
    }
}

struct BillingTaxAddressReview: View {
    @Environment(\.dismiss) private var dismiss
    let scope: BillingTaxAddressScope
    let save: (BillingTaxAddressContext) throws -> Void
    @State private var service: BillingPublicationAddress
    @State private var origin: BillingPublicationAddress
    @State private var sameAsService = false
    @State private var message: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case serviceStreet, serviceCity, serviceState, serviceZIP
        case originStreet, originCity, originState, originZIP

        func next(sameAsService: Bool) -> Field? {
            switch self {
            case .serviceStreet: return .serviceCity
            case .serviceCity: return .serviceState
            case .serviceState: return .serviceZIP
            case .serviceZIP: return sameAsService ? nil : .originStreet
            case .originStreet: return .originCity
            case .originCity: return .originState
            case .originState: return .originZIP
            case .originZIP: return nil
            }
        }
    }

    init(scope: BillingTaxAddressScope, initial: BillingTaxAddressContext?,
         save: @escaping (BillingTaxAddressContext) throws -> Void) {
        self.scope = scope; self.save = save
        let matching = initial?.scope == scope ? initial : nil
        _service = State(initialValue: matching?.service ?? .empty)
        _origin = State(initialValue: matching?.origin ?? .empty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let address = scope.siteAddress { Text(address).accessibilityIdentifier("BillingTaxOriginalSite") }
                    Text("Confirm where the work is performed and where the sale took place. QuickBooks calculates the tax; this does not change your line prices.")
                        .font(.callout).foregroundStyle(.secondary)
                } header: { Text("This draft") }
                Section("Service location") { fields($service, prefix: "Service") }
                Section {
                    Toggle("Sale took place at the service location", isOn: $sameAsService)
                        .accessibilityIdentifier("BillingTaxSameLocation")
                        .onChange(of: sameAsService) { _, same in
                            if same, let field = focusedField,
                               [.originStreet, .originCity, .originState, .originZIP].contains(field) {
                                focusedField = nil
                            }
                        }
                    if !sameAsService { fields($origin, prefix: "Origin") }
                } header: { Text("Sale location") } footer: {
                    Text("For goods that are shipped, use the ship-from address. Do not select the service location unless it is also the sale location.")
                }
                if let message { Section { Text(message).foregroundStyle(.orange).accessibilityIdentifier("BillingTaxReviewError") } }
            }
            .accessibilityIdentifier("BillingTaxAddressForm")
            .navigationTitle("Tax addresses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .accessibilityIdentifier("BillingTaxKeyboardDone")
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("BillingTaxCancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use addresses") {
                        do {
                            try save(.init(scope: scope, service: service, origin: sameAsService ? service : origin))
                            dismiss()
                        } catch { message = error.localizedDescription }
                    }
                    .disabled(!service.isValidUS || !(sameAsService ? service : origin).isValidUS)
                    .accessibilityIdentifier("BillingTaxUseAddresses")
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private func fields(_ address: Binding<BillingPublicationAddress>, prefix: String) -> some View {
        addressField("Street address", text: address.Line1,
            field: prefix == "Service" ? .serviceStreet : .originStreet,
            identifier: "BillingTax\(prefix)Street", contentType: .streetAddressLine1)
        addressField("City", text: address.City,
            field: prefix == "Service" ? .serviceCity : .originCity,
            identifier: "BillingTax\(prefix)City", contentType: .addressCity)
        addressField("State", text: address.CountrySubDivisionCode,
            field: prefix == "Service" ? .serviceState : .originState,
            identifier: "BillingTax\(prefix)State", contentType: .addressState, capitalization: .characters)
        addressField("ZIP code", text: address.PostalCode,
            field: prefix == "Service" ? .serviceZIP : .originZIP,
            identifier: "BillingTax\(prefix)ZIP", contentType: .postalCode, keyboard: .numbersAndPunctuation)
        LabeledContent("Country", value: "United States")
    }

    private func addressField(_ title: String, text: Binding<String>, field: Field,
                              identifier: String, contentType: UITextContentType,
                              capitalization: TextInputAutocapitalization = .words,
                              keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(title, text: text)
                .textContentType(contentType)
                .textInputAutocapitalization(capitalization)
                .keyboardType(keyboard).autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .submitLabel(field.next(sameAsService: sameAsService) == nil ? .done : .next)
                .onSubmit { focusedField = field.next(sameAsService: sameAsService) }
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        // The label and blank area belong to the same edit target; native text
        // selection still receives its own gesture within the field.
        .simultaneousGesture(TapGesture().onEnded { focusedField = field })
    }
}
