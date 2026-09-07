import SwiftUI

/// One compact entry point in the existing billing editor. Editing occurs in a
/// temporary form; Cancel never changes the draft, and Save rechecks its scope.
struct BillingTaxAddressReviewControl: View {
    let scope: BillingTaxAddressScope
    @Binding var addresses: BillingTaxAddressContext?
    @State private var showingReview = false

    private var reviewed: Bool { addresses.map { (try? $0.validate(for: scope)) != nil } ?? false }
    var body: some View {
        Button { showingReview = true } label: {
            HStack {
                Label("Tax addresses", systemImage: "mappin.and.ellipse")
                Spacer()
                Text(reviewed ? "Reviewed" : "Review needed").font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption)
            }
        }
        .accessibilityIdentifier("BillingTaxAddresses")
        .onChange(of: scope) { _, _ in showingReview = false }
        .sheet(isPresented: $showingReview) {
            BillingTaxAddressReview(scope: scope, initial: addresses) { value in
                guard value.scope == scope else { throw BillingTaxAddressError.changed }
                try value.validate(for: scope)
                addresses = value
            }
        }
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
                    if !sameAsService { fields($origin, prefix: "Origin") }
                } header: { Text("Sale location") } footer: {
                    Text("For goods that are shipped, use the ship-from address. Do not select the service location unless it is also the sale location.")
                }
                if let message { Section { Text(message).foregroundStyle(.orange).accessibilityIdentifier("BillingTaxReviewError") } }
            }
            .navigationTitle("Tax addresses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
        TextField("Street address", text: address.Line1).textContentType(.streetAddressLine1)
            .accessibilityIdentifier("BillingTax\(prefix)Street")
        TextField("City", text: address.City).textContentType(.addressCity)
            .accessibilityIdentifier("BillingTax\(prefix)City")
        TextField("State", text: address.CountrySubDivisionCode).textContentType(.addressState)
            .textInputAutocapitalization(.characters).autocorrectionDisabled()
            .accessibilityIdentifier("BillingTax\(prefix)State")
        TextField("ZIP code", text: address.PostalCode).textContentType(.postalCode)
            .keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
            .accessibilityIdentifier("BillingTax\(prefix)ZIP")
        LabeledContent("Country", value: "United States")
    }
}
