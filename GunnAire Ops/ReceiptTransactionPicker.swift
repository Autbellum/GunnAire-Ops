import SwiftUI
import Combine

/// Display metadata never establishes identity. Every selection retains both the
/// provider entity type and its opaque ID; job ownership is resolved separately.
struct ReceiptTransactionChoice: Identifiable, Equatable {
    let type: QuickBooksAttachableEntityType
    let providerID: String
    let documentNumber: String?
    let partyName: String?
    let amount: Double
    let transactionDate: String?

    var id: String { type.rawValue + ":" + providerID }
    var title: String {
        Self.title(for: type) + (documentNumber.map { " #" + $0 } ?? "")
    }
    var party: String { partyName ?? "Name unavailable" }
    var formattedAmount: String { amount.formatted(.currency(code: "USD")) }
    var formattedDate: String {
        guard let transactionDate else { return "Date unavailable" }
        guard let date = Self.dayParser.date(from: transactionDate),
              Self.dayParser.string(from: date) == transactionDate else { return "Date unavailable" }
        return Self.dayDisplay.string(from: date)
    }

    // Reuse main-actor formatters while searching a large transaction list.
    // QBO dates are calendar days, not UTC timestamps to shift into local time.
    private static let dayParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        parser.isLenient = false
        return parser
    }()
    private static let dayDisplay: DateFormatter = {
        let display = DateFormatter()
        display.locale = .autoupdatingCurrent
        display.timeZone = TimeZone(secondsFromGMT: 0)
        display.dateStyle = .medium
        return display
    }()

    init(type: QuickBooksAttachableEntityType, providerID: String, documentNumber: String? = nil,
         partyName: String?, amount: Double, transactionDate: String?) {
        self.type = type
        self.providerID = QuickBooksBillingIdentity.identifier(providerID) ?? ""
        self.documentNumber = QuickBooksBillingIdentity.identifier(documentNumber)
        self.partyName = QuickBooksBillingIdentity.identifier(partyName)
        self.amount = amount
        self.transactionDate = transactionDate
    }

    static func title(for type: QuickBooksAttachableEntityType) -> String {
        switch type {
        case .salesReceipt: return "Sales Receipt"
        case .purchase: return "Expense"
        default: return type.rawValue
        }
    }

    func matches(search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || title.localizedStandardContains(query) || party.localizedStandardContains(query)
            || formattedAmount.localizedStandardContains(query) || formattedDate.localizedStandardContains(query)
    }

    static func linked(to call: ServiceCall, invoices: [Invoice], estimates: [Estimate],
                       payments: [Payment]) -> Self? {
        guard let target = JobBillingDocumentLinks.attachmentTarget(for: call,
            invoices: invoices, estimates: estimates, payments: payments) else { return nil }
        let amount: Double, date: Date
        if target.type == .invoice,
           let original = JobBillingDocumentLinks.invoice(for: call, in: invoices, payments: payments) {
            amount = original.amount; date = original.createdAt
        } else if target.type == .estimate,
                  let original = JobBillingDocumentLinks.estimate(for: call, in: estimates) {
            amount = original.amount; date = original.createdAt
        } else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Local createdAt is an instant; preserve its day in the user's calendar.
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return Self(type: target.type, providerID: target.id, partyName: call.customer?.name,
                    amount: amount, transactionDate: formatter.string(from: date))
    }
}

/// One browsing session. Canceling never changes the parent screen's selection.
/// Late responses and selection after an account/role change cannot be accepted.
@MainActor final class ReceiptTransactionBrowser: ObservableObject {
    typealias Completion = @MainActor (Result<[ReceiptTransactionChoice], Error>) -> Void
    typealias Loader = @MainActor (QuickBooksAttachableEntityType, @escaping Completion) -> Void
    @Published private(set) var type: QuickBooksAttachableEntityType = .invoice
    @Published private(set) var choices: [ReceiptTransactionChoice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    private var requestID = UUID()
    private var checkAccess: (() throws -> Void)?

    func load(type: QuickBooksAttachableEntityType, checkAccess: @escaping () throws -> Void,
              using loader: Loader = ReceiptTransactionBrowser.fetch) {
        cancel()
        self.type = type
        self.checkAccess = checkAccess
        guard accessIsCurrent() else { return }
        isLoading = true
        let request = requestID
        loader(type) { [weak self] result in
            guard let self, self.requestID == request, self.accessIsCurrent() else { return }
            self.isLoading = false
            switch result {
            case .success(let rows):
                let counts = Dictionary(grouping: rows, by: \.id).mapValues(\.count)
                self.choices = rows.filter {
                    $0.type == type && !$0.providerID.isEmpty && $0.amount.isFinite && counts[$0.id] == 1
                }
                self.message = self.choices.count != rows.count
                    ? "Some transactions need identity review in QuickBooks and cannot be selected."
                    : self.choices.isEmpty ? "No transactions found in this category." : nil
            case .failure:
                self.choices = []
                self.message = "Transactions could not be loaded. Check your connection and try again. Your selection has not changed."
            }
        }
    }

    func select(_ choice: ReceiptTransactionChoice) -> ReceiptTransactionChoice? {
        guard accessIsCurrent(), !isLoading, choices.filter({ $0.id == choice.id }).count == 1,
              choices.contains(choice) else { return nil }
        return choice
    }

    func cancel() {
        requestID = UUID()
        checkAccess = nil
        choices = []
        isLoading = false
        message = nil
    }

    private func accessIsCurrent() -> Bool {
        do {
            guard let checkAccess else { return false }
            try checkAccess()
            return true
        } catch {
            cancel()
            message = "Business or QuickBooks access changed. Close this picker and reconnect before choosing a transaction."
            return false
        }
    }

    private static func fetch(_ type: QuickBooksAttachableEntityType, completion: @escaping Completion) {
        func deliver<T>(_ result: Result<[T], Error>, map: (T) -> ReceiptTransactionChoice) {
            let mapped = result.map { $0.map(map) }
            DispatchQueue.main.async { completion(mapped) }
        }
        let api = QuickBooksDataAPI.shared
        switch type {
        case .invoice:
            api.fetchInvoices { result in deliver(result) {
                .init(type: type, providerID: $0.Id, documentNumber: $0.DocNumber,
                      partyName: $0.CustomerRef.name, amount: $0.TotalAmt, transactionDate: $0.TxnDate)
            } }
        case .estimate:
            api.fetchEstimates { result in deliver(result) {
                .init(type: type, providerID: $0.Id, documentNumber: $0.DocNumber,
                      partyName: $0.CustomerRef.name, amount: $0.TotalAmt, transactionDate: $0.TxnDate)
            } }
        case .bill:
            api.fetchBills { result in deliver(result) {
                .init(type: type, providerID: $0.Id, documentNumber: $0.DocNumber,
                      partyName: $0.VendorRef.name, amount: $0.TotalAmt, transactionDate: $0.TxnDate)
            } }
        case .payment:
            api.fetchPayments { result in deliver(result) {
                .init(type: type, providerID: $0.Id, documentNumber: $0.PaymentRefNum,
                      partyName: $0.CustomerRef?.name, amount: $0.TotalAmt, transactionDate: $0.TxnDate)
            } }
        case .salesReceipt:
            api.fetchSalesReceipts { result in deliver(result) {
                .init(type: type, providerID: $0.Id, documentNumber: $0.DocNumber,
                      partyName: $0.CustomerRef?.name, amount: $0.TotalAmt, transactionDate: $0.TxnDate)
            } }
        case .purchase:
            api.fetchPurchases { result in deliver(result) {
                .init(type: type, providerID: $0.Id, partyName: $0.EntityRef?.name,
                      amount: $0.TotalAmt, transactionDate: $0.TxnDate)
            } }
        }
    }
}

#if DEBUG
/// Synthetic read-only choices for the real picker; never compiled in Release.
@MainActor enum ReceiptTransactionPickerFixture {
    static var enabled: Bool {
        GunnAireCloudKit.usesTestDatabase &&
            ProcessInfo.processInfo.arguments.contains("-uiTestReceiptTransactions")
    }
    static func load(_ type: QuickBooksAttachableEntityType, completion: ReceiptTransactionBrowser.Completion) {
        completion(.success([
            .init(type: type, providerID: "fixture-original", documentNumber: "RECEIPT-42",
                  partyName: "Receipt test customer", amount: 189, transactionDate: "2026-09-09"),
            .init(type: type, providerID: "fixture-other", documentNumber: "RECEIPT-43",
                  partyName: "Another customer", amount: 295, transactionDate: "2026-09-08")
        ]))
    }
}
#endif

struct ReceiptTransactionLabel: View {
    let choice: ReceiptTransactionChoice
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(choice.title).font(.headline).foregroundStyle(Color(uiColor: .label))
            Text(choice.party).foregroundStyle(Color(uiColor: .label))
            Text("\(choice.formattedAmount) • \(choice.formattedDate)")
                .font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct ReceiptTransactionPicker: View {
    @ObservedObject var browser: ReceiptTransactionBrowser
    let load: (QuickBooksAttachableEntityType) -> Void
    let select: (ReceiptTransactionChoice) -> Void
    let cancel: () -> Void
    @State private var search = ""

    private var results: [ReceiptTransactionChoice] {
        browser.choices.filter { $0.matches(search: search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Transaction type", selection: Binding(get: { browser.type }, set: {
                        search = ""; load($0)
                    })) {
                        ForEach(QuickBooksAttachableEntityType.allCases, id: \.self) { type in
                            Text(ReceiptTransactionChoice.title(for: type)).tag(type)
                        }
                    }
                    .accessibilityIdentifier("ReceiptTransactionCategory")
                }
                if browser.isLoading {
                    ProgressView("Loading transactions…")
                } else {
                    if let message = browser.message {
                        Section {
                            Text(message).foregroundStyle(.secondary)
                            Button("Try Again") { load(browser.type) }
                        }
                    }
                    if !browser.choices.isEmpty && results.isEmpty {
                        Text("No matching transactions. Try a name, document number, amount, or date.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(results) { choice in
                        Button { select(choice) } label: { ReceiptTransactionLabel(choice: choice) }
                            .accessibilityIdentifier("ReceiptTransaction-\(choice.id)")
                    }
                }
            }
            .searchable(text: $search, prompt: "Name or document number")
            .navigationTitle("Choose Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel).accessibilityIdentifier("ReceiptTransactionCancel")
                }
            }
        }
        .presentationSizing(.form)
    }
}
