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
///
/// Two defects made customers unfindable from the schedule's Assign Customer
/// path. A calendar-imported job opens with the calendar placeholder already
/// bound to `customer`, and results were drawn only while `customer` was nil,
/// so typing in the search box changed nothing on screen. And results were cut
/// at the first eight rows, so most of the list never appeared. The placeholder
/// now counts as no selection, results show whenever the search text is not the
/// selected customer's name, and every match is listed (the Form is lazy).
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

    /// A real customer is selected. The calendar placeholder does not count:
    /// it is what an unassigned job carries, and treating it as a selection is
    /// what hid the results.
    private var selectedRealCustomer: Customer? {
        guard let customer, !CustomerDataMaintenance.isSystemCalendarCustomer(customer) else { return nil }
        return customer
    }

    /// Results are shown when nothing real is selected, or when the user has
    /// typed something other than the selected customer's name to replace it.
    private var showsResults: Bool {
        guard let selectedRealCustomer else { return true }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !query.isEmpty && query.caseInsensitiveCompare(selectedRealCustomer.name) != .orderedSame
    }

    private var canSaveNewCustomer: Bool {
        !newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // Filtered once per body pass (perf rule B), not per read.
        let matches = showsResults
            ? CustomerSearch.matches(in: selectableCustomers, query: searchText)
            : []
        Section("Customer") {
            TextField("Search customer name", text: $searchText)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier(identifierPrefix + "CustomerSearch")

            if let customer = selectedRealCustomer {
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

            if let customer, CustomerDataMaintenance.isSystemCalendarCustomer(customer) {
                Text("Unassigned calendar event. Search or create a customer below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(identifierPrefix + "UnassignedCustomerNotice")
            }

            if showsResults {
                if customer == nil, let placeholder {
                    Button {
                        select(placeholder)
                    } label: {
                        Text("Unassigned Calendar Event")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(identifierPrefix + "UnassignedCalendarCustomer")
                }
                if matches.isEmpty {
                    Text(selectableCustomers.isEmpty
                        ? "No customers on this device yet."
                        : "No matching customers found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(matches.count == 1 ? "1 customer" : "\(matches.count) customers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(identifierPrefix + "CustomerMatchCount")
                    ForEach(matches) { match in
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
                        .accessibilityIdentifier(identifierPrefix + "CustomerResult-" + match.id.uuidString)
                    }
                }
            }

            Button(creatingNewCustomer ? "Hide New Customer" : "Create New Customer") {
                creatingNewCustomer.toggle()
                if !creatingNewCustomer {
                    resetNewCustomerFields()
                } else if let customer = selectedRealCustomer {
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
        // The placeholder's name is not a search; leave the box empty so the
        // full list stays visible for picking a real customer.
        searchText = CustomerDataMaintenance.isSystemCalendarCustomer(selection) ? "" : selection.name
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

/// Customer search shared by the new-job and edit-job sheets.
///
/// Every whitespace-separated term must appear in the name, email, phone, or
/// address, ignoring case and diacritics, so "smith john", "john smith" and
/// "smith 78701" all find "John Smith" at a 78701 address. A term with three or
/// more digits also matches the phone's digits, so "5125550100" finds a phone
/// stored as "(512) 555-0100". Input order is kept; both sheets query
/// customers sorted by name, so no per-keystroke sort is needed.
enum CustomerSearch {
    static func matches(in customers: [Customer], query: String) -> [Customer] {
        let terms = searchTerms(query)
        guard !terms.isEmpty else { return customers }
        return customers.filter { customer in
            fieldsMatch(
                terms: terms,
                name: customer.name,
                email: customer.email,
                phone: customer.phone,
                address: customer.address
            )
        }
    }

    nonisolated static func searchTerms(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
    }

    nonisolated static func fieldsMatch(
        terms: [String],
        name: String,
        email: String?,
        phone: String?,
        address: String?
    ) -> Bool {
        let fields = [name, email, phone, address].compactMap { $0 }
        let phoneDigits = digits(phone ?? "")
        return terms.allSatisfy { term in
            if fields.contains(where: { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
                return true
            }
            let termDigits = digits(term)
            return termDigits.count >= 3 && termDigits.count == term.filter { !"()-.+ ".contains($0) }.count
                && phoneDigits.contains(termDigits)
        }
    }

    nonisolated private static func digits(_ value: String) -> String {
        String(value.filter(\.isASCII).filter(\.isNumber))
    }
}
