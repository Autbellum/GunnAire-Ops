import SwiftUI

struct QuickBooksAccountingMappingView: View {
    @Environment(\.dismiss) private var dismiss

    let realmID: String
    let environment: String
    let items: [QuickBooksItem]
    let accounts: [QuickBooksAccount]
    let existingConfiguration: BackendQuickBooksAccountingConfiguration?
    let onSave: @MainActor (BackendQuickBooksAccountingConfiguration) async throws -> Void

    @State private var selectedSalesItemID: String?
    @State private var selectedIncomeAccountID: String?
    @State private var selectedExpenseAccountID: String?
    @State private var selectedAPAccountID: String?
    @State private var selectedBankAccountID: String?
    @State private var selectedCreditCardAccountID: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        realmID: String,
        environment: String,
        items: [QuickBooksItem],
        accounts: [QuickBooksAccount],
        existingConfiguration: BackendQuickBooksAccountingConfiguration?,
        onSave: @escaping @MainActor (BackendQuickBooksAccountingConfiguration) async throws -> Void
    ) {
        self.realmID = realmID
        self.environment = environment
        self.items = items
        self.accounts = accounts
        self.existingConfiguration = existingConfiguration
        self.onSave = onSave
        _selectedSalesItemID = State(initialValue: existingConfiguration?.defaultSalesItemRef)
        _selectedIncomeAccountID = State(initialValue: existingConfiguration?.defaultIncomeAccountRef)
        _selectedExpenseAccountID = State(initialValue: existingConfiguration?.defaultExpenseAccountRef)
        _selectedAPAccountID = State(initialValue: existingConfiguration?.defaultAPAccountRef)
        _selectedBankAccountID = State(initialValue: existingConfiguration?.defaultBankAccountRef)
        _selectedCreditCardAccountID = State(initialValue: existingConfiguration?.defaultCreditCardAccountRef)
    }

    private var salesItems: [QuickBooksItem] {
        items
            .filter { item in
                item.Active != false &&
                item.ItemType?.caseInsensitiveCompare("Category") != .orderedSame
            }
            .sorted { $0.Name.localizedCaseInsensitiveCompare($1.Name) == .orderedAscending }
    }

    private var incomeAccounts: [QuickBooksAccount] {
        accounts(ofTypes: ["Income", "Other Income"])
    }

    private var expenseAccounts: [QuickBooksAccount] {
        accounts(ofTypes: ["Expense", "Other Expense", "Cost of Goods Sold"])
    }

    private var accountsPayableAccounts: [QuickBooksAccount] {
        accounts(ofTypes: ["Accounts Payable"])
    }

    private var bankAccounts: [QuickBooksAccount] {
        accounts(ofTypes: ["Bank"])
    }

    private var creditCardAccounts: [QuickBooksAccount] {
        accounts(ofTypes: ["Credit Card"])
    }

    private var candidate: BackendQuickBooksAccountingConfiguration? {
        guard let salesItem = match(salesItems, id: selectedSalesItemID),
              let salesItemType = salesItem.ItemType,
              let incomeAccount = match(incomeAccounts, id: selectedIncomeAccountID),
              let incomeType = incomeAccount.AccountType,
              let expenseAccount = match(expenseAccounts, id: selectedExpenseAccountID),
              let expenseType = expenseAccount.AccountType,
              let accountsPayable = match(accountsPayableAccounts, id: selectedAPAccountID),
              let accountsPayableType = accountsPayable.AccountType,
              let bankAccount = match(bankAccounts, id: selectedBankAccountID),
              let bankType = bankAccount.AccountType,
              let creditCardAccount = match(creditCardAccounts, id: selectedCreditCardAccountID),
              let creditCardType = creditCardAccount.AccountType else {
            return nil
        }
        return BackendQuickBooksAccountingConfiguration(
            realmID: realmID,
            environment: environment,
            defaultSalesItemRef: salesItem.Id,
            defaultSalesItemName: salesItem.Name,
            defaultSalesItemType: salesItemType,
            defaultIncomeAccountRef: incomeAccount.Id,
            defaultIncomeAccountName: incomeAccount.displayName,
            defaultIncomeAccountType: incomeType,
            defaultExpenseAccountRef: expenseAccount.Id,
            defaultExpenseAccountName: expenseAccount.displayName,
            defaultExpenseAccountType: expenseType,
            defaultAPAccountRef: accountsPayable.Id,
            defaultAPAccountName: accountsPayable.displayName,
            defaultAPAccountType: accountsPayableType,
            defaultBankAccountRef: bankAccount.Id,
            defaultBankAccountName: bankAccount.displayName,
            defaultBankAccountType: bankType,
            defaultCreditCardAccountRef: creditCardAccount.Id,
            defaultCreditCardAccountName: creditCardAccount.displayName,
            defaultCreditCardAccountType: creditCardType,
            updatedAt: existingConfiguration?.updatedAt,
            updatedBy: existingConfiguration?.updatedBy
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connected Company") {
                    LabeledContent("Environment", value: environment.capitalized)
                    LabeledContent("Company Realm") {
                        Text(realmID)
                            .accessibilityIdentifier("QBOAccountingRealmValue")
                    }
                    Text("Mappings apply only to this QuickBooks company. Saving does not create or modify a transaction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Sales and Pricebook") {
                    SearchableDropdownPicker(
                        title: "Default sales item",
                        options: itemOptions(salesItems),
                        selectedID: $selectedSalesItemID,
                        placeholder: "Choose product or service"
                    )
                    .accessibilityIdentifier("QBOAccountingSalesItemPicker")

                    SearchableDropdownPicker(
                        title: "Income account",
                        options: accountOptions(incomeAccounts),
                        selectedID: $selectedIncomeAccountID,
                        placeholder: "Choose income account"
                    )
                    .accessibilityIdentifier("QBOAccountingIncomePicker")

                    Text("New GunnAire pricebook items use this income account when they are first published to QuickBooks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Purchases and Costs") {
                    SearchableDropdownPicker(
                        title: "Expense or cost account",
                        options: accountOptions(expenseAccounts),
                        selectedID: $selectedExpenseAccountID,
                        placeholder: "Choose expense account"
                    )
                    .accessibilityIdentifier("QBOAccountingExpensePicker")

                    SearchableDropdownPicker(
                        title: "Accounts Payable",
                        options: accountOptions(accountsPayableAccounts),
                        selectedID: $selectedAPAccountID,
                        placeholder: "Choose Accounts Payable"
                    )
                    .accessibilityIdentifier("QBOAccountingAPPicker")

                    Text("Reviewed supplier bills and vendor credits post through this liability account. GunnAire Ops never guesses an Accounts Payable mapping.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Payment Accounts") {
                    SearchableDropdownPicker(
                        title: "Cash and check account",
                        options: accountOptions(bankAccounts),
                        selectedID: $selectedBankAccountID,
                        placeholder: "Choose bank account"
                    )
                    .accessibilityIdentifier("QBOAccountingBankPicker")

                    SearchableDropdownPicker(
                        title: "Credit-card purchase account",
                        options: accountOptions(creditCardAccounts),
                        selectedID: $selectedCreditCardAccountID,
                        placeholder: "Choose credit-card account"
                    )
                    .accessibilityIdentifier("QBOAccountingCreditCardPicker")

                    Text("Cash and checks post to the selected bank account. Credit-card purchases post to the selected credit-card liability account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Accounting Mappings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        save()
                    }
                    .disabled(candidate == nil || isSaving)
                    .accessibilityIdentifier("QBOAccountingSaveButton")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        guard let candidate else {
            errorMessage = QuickBooksAccountingConfigurationError.incomplete.localizedDescription
            return
        }
        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await onSave(candidate)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func accounts(ofTypes types: Set<String>) -> [QuickBooksAccount] {
        accounts
            .filter { account in
                account.Active != false &&
                account.AccountType.map { accountType in
                    types.contains { $0.caseInsensitiveCompare(accountType) == .orderedSame }
                } == true
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func itemOptions(_ values: [QuickBooksItem]) -> [SearchableDropdownOption] {
        values.map {
            SearchableDropdownOption(
                id: $0.Id,
                title: $0.Name,
                subtitle: [$0.ItemType, "QBO ID \($0.Id)"].compactMap { $0 }.joined(separator: " • ")
            )
        }
    }

    private func accountOptions(_ values: [QuickBooksAccount]) -> [SearchableDropdownOption] {
        values.map {
            SearchableDropdownOption(
                id: $0.Id,
                title: $0.displayName,
                subtitle: [$0.AccountType, $0.AccountSubType].compactMap { $0 }.joined(separator: " • ")
            )
        }
    }

    private func match<T: Identifiable>(_ values: [T], id: String?) -> T? where T.ID == String {
        guard let id else { return nil }
        return values.first { $0.id == id }
    }
}
