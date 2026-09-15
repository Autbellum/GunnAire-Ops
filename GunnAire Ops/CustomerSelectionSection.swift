import SwiftData
import SwiftUI

/// Searchable customer selection with an inline path to create one.
///
/// New Service Call has always had this. Edit Service Call had only a bare
/// `Picker` over every customer — no search box, and no way to add a customer
/// who did not exist yet. That is the screen where it was needed most: a
/// calendar-imported job arrives with no customer whenever the event carried no
/// email matching an existing record, and maintenance and calendar work always
/// opens an existing job, so the one screen that had to attach a customer was
/// the one screen that could not.
///
/// Selection side effects stay with the caller. Add applies the customer's
/// preferred service location on selection; Edit deliberately does not, so
/// adopting this view does not silently start moving a committed job's address.
struct CustomerSelectionSection: View {
    @Binding var customer: Customer?
    let customers: [Customer]
    let identifierPrefix: String
    /// Kept selectable while the job still points at the calendar placeholder,
    /// so the current value does not vanish from a filtered list.
    var placeholder: Customer?
    var onSelect: (Customer) -> Void
    var onCreate: (Customer) -> Void

    init(
        customer: Binding<Customer?>,
        customers: [Customer],
        identifierPrefix: String,
        placeholder: Customer? = nil,
        onSelect: @escaping (Customer) -> Void = { _ in },
        onCreate: @escaping (Customer) -> Void = { _ in }
    ) {
        _customer = customer
        self.customers = customers
        self.identifierPrefix = identifierPrefix
        self.placeholder = placeholder
        self.onSelect = onSelect
        self.onCreate = onCreate
    }

    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var creatingNewCustomer = false
    @State private var newCustomerName = ""
    @State private var newCustomerPhone = ""
    @State private var newCustomerEmail = ""
    @State private var newCustomerAddress = ""

    /// The calendar placeholder is offered as its own row rather than mixed in
    /// with real customers, so it can never be picked by accident.
    private var selectableCustomers: [Customer] {
        customers.filter { !CustomerDataMaintenance.isSystemCalendarCustomer($0) }
    }

    private var matchingCustomers: [Customer] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return selectableCustomers }
        return selectableCustomers.filter { candidate in
            candidate.name.lowercased().contains(query) ||
            (candidate.email?.lowercased().contains(query) ?? false) ||
            (candidate.phone?.lowercased().contains(query) ?? false) ||
            (candidate.address?.lowercased().contains(query) ?? false)
        }
    }

    private var canSaveNewCustomer: Bool {
        !newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Section("Customer") {
            TextField("Search customer name", text: $searchText)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier(identifierPrefix + "CustomerSearch")

            if let customer {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(customer.name)
                            .font(.headline)
                        if let email = customer.email, !email.isEmpty {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let phone = customer.phone, !phone.isEmpty {
                            Text(phone)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Clear") {
                        self.customer = nil
                        searchText = ""
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(identifierPrefix + "ClearCustomer")
                }
            }

            if customer == nil {
                if let placeholder {
                    Button {
                        select(placeholder)
                    } label: {
                        Text("Unassigned Calendar Event")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(identifierPrefix + "UnassignedCalendarCustomer")
                }
                if matchingCustomers.isEmpty {
                    Text("No matching customers found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(matchingCustomers.prefix(8)) { match in
                        Button {
                            select(match)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.name)
                                    .foregroundStyle(.primary)
                                if let address = match.address, !address.isEmpty {
                                    Text(address)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button(creatingNewCustomer ? "Hide New Customer" : "Create New Customer") {
                creatingNewCustomer.toggle()
                if !creatingNewCustomer {
                    resetNewCustomerFields()
                } else if let customer {
                    newCustomerName = customer.name
                    newCustomerPhone = customer.phone ?? ""
                    newCustomerEmail = customer.email ?? ""
                    newCustomerAddress = customer.address ?? ""
                } else {
                    newCustomerName = searchText
                }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(identifierPrefix + "CreateNewCustomer")

            if creatingNewCustomer {
                TextField("Customer name", text: $newCustomerName)
                TextField("Phone", text: $newCustomerPhone)
                    .keyboardType(.phonePad)
                TextField("Email", text: $newCustomerEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                TextField("Billing / Default Address", text: $newCustomerAddress, axis: .vertical)
                    .lineLimit(2...3)

                Button("Save New Customer") {
                    saveNewCustomer()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSaveNewCustomer)
                .accessibilityIdentifier(identifierPrefix + "SaveNewCustomer")
            }
        }
    }

    private func select(_ selection: Customer) {
        customer = selection
        searchText = selection.name
        onSelect(selection)
    }

    private func saveNewCustomer() {
        let created = Customer(
            name: newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines),
            phone: trimmedOrNil(newCustomerPhone),
            email: trimmedOrNil(newCustomerEmail),
            address: trimmedOrNil(newCustomerAddress)
        )
        modelContext.insert(created)
        customer = created
        searchText = created.name
        creatingNewCustomer = false
        resetNewCustomerFields()
        onCreate(created)
    }

    /// Matches the `nilIfBlank` helpers used by the other entry sheets: a blank
    /// optional field is stored as nil rather than an empty string, so customer
    /// records stay consistent regardless of which sheet created them.
    private func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resetNewCustomerFields() {
        newCustomerName = ""
        newCustomerPhone = ""
        newCustomerEmail = ""
        newCustomerAddress = ""
    }
}
