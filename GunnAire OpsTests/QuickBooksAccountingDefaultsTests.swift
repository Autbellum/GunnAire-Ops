import Foundation
import Testing
@testable import GunnAire_Ops

/// Every derivation rule in `QuickBooksAccountingDefaults` is exercised here
/// with records shaped like QuickBooks responses. Nothing outside the fixture
/// arrays may influence a proposal.
struct QuickBooksAccountingDefaultsTests {
    private typealias Defaults = QuickBooksAccountingDefaults

    // MARK: - Fixtures

    private func account(
        _ id: String,
        _ name: String,
        type: String,
        active: Bool? = true
    ) -> QuickBooksAccount {
        QuickBooksAccount(
            Id: id, Name: name, FullyQualifiedName: nil, AccountType: type,
            AccountSubType: nil, Classification: nil, Active: active
        )
    }

    private func item(
        _ id: String,
        _ name: String,
        type: String = "Service",
        active: Bool? = true,
        income: String? = nil,
        expense: String? = nil
    ) -> QuickBooksItem {
        QuickBooksItem(
            Id: id, SyncToken: nil, Name: name, ItemType: type, Description: nil, Sku: nil,
            PurchaseDesc: nil, UnitPrice: nil, PurchaseCost: nil, Taxable: nil, Active: active,
            IncomeAccountRef: income.map { QuickBooksReference(value: $0, name: nil) },
            ExpenseAccountRef: expense.map { QuickBooksReference(value: $0, name: nil) },
            PrefVendorRef: nil
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    private func invoice(_ id: String, itemIDs: [String]) throws -> QuickBooksInvoice {
        try decode(QuickBooksInvoice.self, [
            "Id": id, "CustomerRef": ["value": "C1"], "TotalAmt": 100,
            "Line": itemIDs.map { itemID in
                [
                    "Amount": 50, "DetailType": "SalesItemLineDetail",
                    "SalesItemLineDetail": ["ItemRef": ["value": itemID]]
                ]
            }
        ])
    }

    private func bill(_ id: String, apAccount: String?) throws -> QuickBooksBill {
        var object: [String: Any] = ["Id": id, "VendorRef": ["value": "V1"], "TotalAmt": 40]
        if let apAccount { object["APAccountRef"] = ["value": apAccount] }
        return try decode(QuickBooksBill.self, object)
    }

    private func payment(_ id: String) throws -> QuickBooksPayment {
        try decode(QuickBooksPayment.self, ["Id": id, "TotalAmt": 10])
    }

    private func salesReceipt(_ id: String) throws -> QuickBooksSalesReceipt {
        try decode(QuickBooksSalesReceipt.self, ["Id": id, "TotalAmt": 10])
    }

    private func deposit(_ id: String, account: String?) -> QuickBooksDeposit {
        QuickBooksDeposit(
            Id: id, TxnDate: nil, TotalAmt: 10, PrivateNote: nil,
            DepositToAccountRef: account.map { QuickBooksReference(value: $0, name: nil) }, Line: nil
        )
    }

    private func purchase(_ id: String, account: String?, paymentType: String?) -> QuickBooksPurchase {
        QuickBooksPurchase(
            Id: id, AccountRef: account.map { QuickBooksReference(value: $0, name: nil) },
            EntityRef: nil, TotalAmt: 25, TxnDate: nil, PrivateNote: nil, PaymentType: paymentType
        )
    }

    /// One active record per slot, so every slot resolves by the single-candidate fallback.
    private var completeAccounts: [QuickBooksAccount] {
        [
            account("10", "Services", type: "Income"),
            account("20", "Job Materials", type: "Cost of Goods Sold"),
            account("30", "Accounts Payable (A/P)", type: "Accounts Payable"),
            account("40", "Checking", type: "Bank"),
            account("50", "Company Visa", type: "Credit Card")
        ]
    }

    private var completeItems: [QuickBooksItem] {
        [item("1", "HVAC Service", income: "10", expense: "20")]
    }

    private func propose(
        items: [QuickBooksItem]? = nil,
        accounts: [QuickBooksAccount]? = nil,
        invoices: [QuickBooksInvoice] = [],
        salesReceipts: [QuickBooksSalesReceipt] = [],
        payments: [QuickBooksPayment] = [],
        deposits: [QuickBooksDeposit] = [],
        bills: [QuickBooksBill] = [],
        purchases: [QuickBooksPurchase] = []
    ) -> Defaults.Proposal? {
        Defaults.propose(
            items: items ?? completeItems,
            accounts: accounts ?? completeAccounts,
            invoices: invoices,
            salesReceipts: salesReceipts,
            payments: payments,
            deposits: deposits,
            bills: bills,
            purchases: purchases,
            realmID: "9341455327810551",
            environment: "sandbox"
        )
    }

    // MARK: - Whole proposal

    @Test func nothingFromQuickBooksProducesNoProposal() {
        #expect(propose(items: [], accounts: []) == nil)
    }

    @Test func singleCandidatesFillEverySlotWithQuickBooksValues() throws {
        let configuration = try #require(propose()?.configuration)
        #expect(configuration.realmID == "9341455327810551")
        #expect(configuration.environment == "sandbox")
        #expect(configuration.defaultSalesItemRef == "1")
        #expect(configuration.defaultSalesItemName == "HVAC Service")
        #expect(configuration.defaultSalesItemType == "Service")
        #expect(configuration.defaultIncomeAccountRef == "10")
        #expect(configuration.defaultIncomeAccountName == "Services")
        #expect(configuration.defaultIncomeAccountType == "Income")
        #expect(configuration.defaultExpenseAccountRef == "20")
        #expect(configuration.defaultExpenseAccountType == "Cost of Goods Sold")
        #expect(configuration.defaultAPAccountRef == "30")
        #expect(configuration.defaultAPAccountType == "Accounts Payable")
        #expect(configuration.defaultBankAccountRef == "40")
        #expect(configuration.defaultBankAccountType == "Bank")
        #expect(configuration.defaultCreditCardAccountRef == "50")
        #expect(configuration.defaultCreditCardAccountType == "Credit Card")
        #expect(configuration.isComplete)
        #expect(configuration.updatedAt == nil)
        #expect(configuration.updatedBy == nil)
    }

    @Test func incompleteProposalListsExactlyTheMissingSlots() throws {
        let accounts = completeAccounts.filter { $0.AccountType != "Credit Card" && $0.AccountType != "Bank" }
        let proposal = try #require(propose(accounts: accounts))
        #expect(proposal.configuration == nil)
        #expect(proposal.missingSlots == [.bankAccount, .creditCardAccount])
        guard case .incomplete(let missing) = proposal else { return }
        #expect(missing.map(\.reason) == [.noCandidates, .noCandidates])
        #expect(Defaults.incompleteMessage(missing) ==
            "QuickBooks has no active Bank account yet. QuickBooks has no active Credit Card account yet.")
    }

    @Test func itemsOnlyReportEveryAccountSlotMissing() throws {
        let proposal = try #require(propose(accounts: []))
        #expect(proposal.missingSlots == [
            .incomeAccount, .expenseAccount, .accountsPayableAccount, .bankAccount, .creditCardAccount
        ])
    }

    @Test func inactiveAccountsAndItemsAreNeverChosen() throws {
        let accounts = completeAccounts + [
            account("51", "Closed Card", type: "Credit Card", active: false),
            account("41", "Closed Checking", type: "Bank", active: false)
        ]
        let items = completeItems + [item("2", "Retired Service", active: false)]
        let purchases = (0..<3).map { purchase("P\($0)", account: "51", paymentType: "CreditCard") }
        let deposits = (0..<3).map { deposit("D\($0)", account: "41") }
        let invoices = try (0..<3).map { try invoice("I\($0)", itemIDs: ["2"]) }
        let configuration = try #require(
            propose(items: items, accounts: accounts, invoices: invoices, deposits: deposits, purchases: purchases)?
                .configuration
        )
        #expect(configuration.defaultCreditCardAccountRef == "50")
        #expect(configuration.defaultBankAccountRef == "40")
        #expect(configuration.defaultSalesItemRef == "1")
    }

    @Test func onlyInactiveCandidatesLeaveTheSlotMissing() throws {
        let accounts = completeAccounts.filter { $0.AccountType != "Bank" }
            + [account("41", "Closed Checking", type: "Bank", active: false)]
        let proposal = try #require(propose(accounts: accounts, deposits: [deposit("D1", account: "41")]))
        #expect(proposal.missingSlots == [.bankAccount])
    }

    @Test func missingActiveFlagCountsAsActiveLikeQuickBooksDefault() throws {
        let accounts = completeAccounts.filter { $0.AccountType != "Bank" }
            + [account("42", "Checking", type: "Bank", active: nil)]
        let configuration = try #require(propose(accounts: accounts)?.configuration)
        #expect(configuration.defaultBankAccountRef == "42")
    }

    // MARK: - Accounts Payable

    @Test func multipleAccountsPayableResolvedByBillUsage() throws {
        let accounts = completeAccounts + [account("31", "A/P Canada", type: "Accounts Payable")]
        let bills = try [bill("B1", apAccount: "31"), bill("B2", apAccount: "31"), bill("B3", apAccount: "30")]
        let configuration = try #require(propose(accounts: accounts, bills: bills)?.configuration)
        #expect(configuration.defaultAPAccountRef == "31")
        #expect(configuration.defaultAPAccountName == "A/P Canada")
    }

    @Test func multipleAccountsPayableWithoutBillsStaysMissing() throws {
        let accounts = completeAccounts + [account("31", "A/P Canada", type: "Accounts Payable")]
        let proposal = try #require(propose(accounts: accounts, bills: [try bill("B1", apAccount: nil)]))
        #expect(proposal.missingSlots == [.accountsPayableAccount])
        guard case .incomplete(let missing) = proposal else { return }
        #expect(missing.first?.reason == .ambiguous(candidateCount: 2))
        #expect(Defaults.incompleteMessage(missing) ==
            "QuickBooks has 2 active Accounts Payable accounts and no usage singles one out as the default.")
    }

    @Test func accountsPayableTiesBreakByNameThenID() throws {
        let accounts = completeAccounts + [
            account("31", "Accounts Payable (A/P)", type: "Accounts Payable"),
            account("29", "Zeta Payables", type: "Accounts Payable")
        ]
        // "30" and "31" share a name and one bill each; "29" also has one bill.
        let bills = try [bill("B1", apAccount: "30"), bill("B2", apAccount: "31"), bill("B3", apAccount: "29")]
        let configuration = try #require(propose(accounts: accounts, bills: bills)?.configuration)
        #expect(configuration.defaultAPAccountRef == "30")
    }

    // MARK: - Sales item

    @Test func salesItemIsTheServiceItemMostUsedOnInvoiceLines() throws {
        let items = [
            item("1", "Diagnostic", income: "10"),
            item("2", "Maintenance", income: "10"),
            item("3", "Filter", type: "Inventory", income: "10")
        ]
        let invoices = try [
            invoice("I1", itemIDs: ["1", "3", "3", "3"]),
            invoice("I2", itemIDs: ["2", "2"])
        ]
        let configuration = try #require(propose(items: items, invoices: invoices)?.configuration)
        #expect(configuration.defaultSalesItemRef == "2")
        #expect(configuration.defaultSalesItemName == "Maintenance")
    }

    @Test func salesItemCountsBundleComponents() throws {
        let items = [item("1", "Diagnostic", income: "10"), item("2", "Maintenance", income: "10")]
        let invoice = try decode(QuickBooksInvoice.self, [
            "Id": "I1", "CustomerRef": ["value": "C1"], "TotalAmt": 100,
            "Line": [
                ["Amount": 50, "DetailType": "SalesItemLineDetail", "SalesItemLineDetail": ["ItemRef": ["value": "1"]]],
                [
                    "Amount": 0, "DetailType": "GroupLineDetail",
                    "GroupLineDetail": [
                        "GroupItemRef": ["value": "9"], "Quantity": 1,
                        "Line": [
                            ["Amount": 20, "DetailType": "SalesItemLineDetail", "SalesItemLineDetail": ["ItemRef": ["value": "2"]]],
                            ["Amount": 30, "DetailType": "SalesItemLineDetail", "SalesItemLineDetail": ["ItemRef": ["value": "2"]]]
                        ]
                    ]
                ]
            ]
        ])
        let configuration = try #require(propose(items: items, invoices: [invoice])?.configuration)
        #expect(configuration.defaultSalesItemRef == "2")
    }

    @Test func salesItemFallsBackToTheOnlyActiveServiceItem() throws {
        let items = [
            item("1", "Diagnostic", income: "10"),
            item("3", "Filter", type: "Inventory", income: "10"),
            item("4", "Old Service", active: false, income: "10")
        ]
        let configuration = try #require(propose(items: items, invoices: [try invoice("I1", itemIDs: ["3"])])?.configuration)
        #expect(configuration.defaultSalesItemRef == "1")
    }

    @Test func severalUnusedServiceItemsLeaveTheSalesItemMissing() throws {
        let items = [item("1", "Diagnostic", income: "10"), item("2", "Maintenance", income: "10")]
        let proposal = try #require(propose(items: items))
        #expect(proposal.missingSlots == [.salesItem])
    }

    @Test func salesItemTiesBreakByNameThenID() throws {
        let items = [item("2", "Maintenance", income: "10"), item("1", "Diagnostic", income: "10"),
                     item("0", "Diagnostic", income: "10")]
        let invoices = try [invoice("I1", itemIDs: ["2", "1", "0"])]
        let configuration = try #require(propose(items: items, invoices: invoices)?.configuration)
        #expect(configuration.defaultSalesItemRef == "0")
    }

    @Test func noServiceItemsLeaveTheSalesItemMissing() throws {
        let proposal = try #require(propose(items: [item("3", "Filter", type: "Inventory", income: "10")]))
        #expect(proposal.missingSlots == [.salesItem])
        guard case .incomplete(let missing) = proposal else { return }
        #expect(missing.first?.reason == .noCandidates)
    }

    // MARK: - Income account

    @Test func incomeAccountIsTheOneMostServiceItemsPostTo() throws {
        let accounts = completeAccounts + [account("11", "Installs", type: "Income"),
                                           account("12", "Interest", type: "Other Income")]
        let items = [
            item("1", "Diagnostic", income: "11"),
            item("2", "Maintenance", income: "11"),
            item("3", "Tune-up", income: "10"),
            item("4", "Parts", type: "Inventory", income: "10"),
            item("5", "Parts B", type: "Inventory", income: "10")
        ]
        let proposal = try #require(propose(items: items, accounts: accounts))
        // Two Service items post to "11"; the Inventory items posting to "10" do not count.
        #expect(proposal.missingSlots == [.salesItem])
        guard case .incomplete = proposal else { return }
        let resolved = try #require(propose(items: items, accounts: accounts, invoices: [try invoice("I1", itemIDs: ["1"])])?.configuration)
        #expect(resolved.defaultIncomeAccountRef == "11")
        #expect(resolved.defaultIncomeAccountName == "Installs")
    }

    @Test func incomeAccountTiesBreakByInvoiceUsageOfThoseItems() throws {
        let accounts = completeAccounts + [account("11", "Installs", type: "Income")]
        let items = [item("1", "Diagnostic", income: "10"), item("2", "Install", income: "11")]
        let invoices = try [invoice("I1", itemIDs: ["2", "2", "1"])]
        let configuration = try #require(propose(items: items, accounts: accounts, invoices: invoices)?.configuration)
        #expect(configuration.defaultIncomeAccountRef == "11")
    }

    @Test func incomeAccountFallsBackToTheOnlyIncomeTypedAccount() throws {
        let accounts = completeAccounts + [account("12", "Interest", type: "Other Income")]
        let items = [item("1", "Diagnostic")]
        let configuration = try #require(propose(items: items, accounts: accounts)?.configuration)
        #expect(configuration.defaultIncomeAccountRef == "10")
    }

    @Test func onlyOtherIncomeAccountsWithoutUsageLeaveIncomeMissing() throws {
        let accounts = completeAccounts.filter { $0.AccountType != "Income" }
            + [account("12", "Interest", type: "Other Income")]
        let proposal = try #require(propose(items: [item("1", "Diagnostic")], accounts: accounts))
        #expect(proposal.missingSlots == [.incomeAccount])
        guard case .incomplete(let missing) = proposal else { return }
        #expect(missing.first?.reason == .noCandidates)
    }

    @Test func otherIncomeAccountReferencedByServiceItemsIsAccepted() throws {
        let accounts = completeAccounts.filter { $0.AccountType != "Income" }
            + [account("12", "Interest", type: "Other Income")]
        let configuration = try #require(propose(items: [item("1", "Diagnostic", income: "12")], accounts: accounts)?.configuration)
        #expect(configuration.defaultIncomeAccountRef == "12")
        #expect(configuration.defaultIncomeAccountType == "Other Income")
    }

    // MARK: - Expense account

    @Test func expenseAccountIsTheOneMostItemsPurchaseAgainst() throws {
        let accounts = completeAccounts + [account("21", "Subcontractors", type: "Expense"),
                                           account("22", "Owner Draw", type: "Equity")]
        let items = [
            item("1", "Diagnostic", income: "10", expense: "21"),
            item("3", "Filter", type: "Inventory", income: "10", expense: "21"),
            item("4", "Coil", type: "Inventory", income: "10", expense: "20"),
            item("5", "Draw", type: "Inventory", income: "10", expense: "22")
        ]
        let configuration = try #require(propose(items: items, accounts: accounts)?.configuration)
        #expect(configuration.defaultExpenseAccountRef == "21")
        #expect(configuration.defaultExpenseAccountType == "Expense")
    }

    @Test func expenseAccountFallsBackToTheOnlyExpenseTypedAccount() throws {
        let configuration = try #require(propose(items: [item("1", "Diagnostic", income: "10")])?.configuration)
        #expect(configuration.defaultExpenseAccountRef == "20")
    }

    @Test func severalUnusedExpenseAccountsLeaveTheSlotMissing() throws {
        let accounts = completeAccounts + [account("21", "Subcontractors", type: "Expense")]
        let proposal = try #require(propose(items: [item("1", "Diagnostic", income: "10")], accounts: accounts))
        #expect(proposal.missingSlots == [.expenseAccount])
    }

    @Test func otherExpenseAccountsAreNotExpenseDefaults() throws {
        let accounts = completeAccounts.filter { $0.AccountType != "Cost of Goods Sold" }
            + [account("23", "Penalties", type: "Other Expense")]
        let proposal = try #require(propose(items: [item("1", "Diagnostic", income: "10", expense: "23")], accounts: accounts))
        #expect(proposal.missingSlots == [.expenseAccount])
    }

    // MARK: - Bank account

    @Test func bankAccountIsTheOneMostDepositsGoTo() throws {
        let accounts = completeAccounts + [account("41", "Savings", type: "Bank")]
        let deposits = [deposit("D1", account: "41"), deposit("D2", account: "41"), deposit("D3", account: "40"),
                        deposit("D4", account: nil)]
        let configuration = try #require(propose(accounts: accounts, deposits: deposits)?.configuration)
        #expect(configuration.defaultBankAccountRef == "41")
    }

    @Test func bankAccountTiesBreakByNameThenID() throws {
        let accounts = completeAccounts + [account("41", "Business Savings", type: "Bank")]
        let deposits = [deposit("D1", account: "41"), deposit("D2", account: "40")]
        let configuration = try #require(propose(accounts: accounts, deposits: deposits)?.configuration)
        #expect(configuration.defaultBankAccountRef == "41")
    }

    @Test func severalUnusedBankAccountsLeaveTheSlotMissing() throws {
        let accounts = completeAccounts + [account("41", "Savings", type: "Bank")]
        let proposal = try #require(propose(accounts: accounts, payments: [try payment("P1")]))
        #expect(proposal.missingSlots == [.bankAccount])
    }

    // MARK: - Credit-card account

    @Test func creditCardAccountIsTheOneMostCardPurchasesUse() throws {
        let accounts = completeAccounts + [account("51", "Fuel Card", type: "Credit Card")]
        let purchases = [
            purchase("P1", account: "51", paymentType: "CreditCard"),
            purchase("P2", account: "51", paymentType: "CreditCard"),
            purchase("P3", account: "50", paymentType: "CreditCard"),
            // Check purchases against a card id are not card usage.
            purchase("P4", account: "50", paymentType: "Check"),
            purchase("P5", account: "50", paymentType: "Check")
        ]
        let configuration = try #require(propose(accounts: accounts, purchases: purchases)?.configuration)
        #expect(configuration.defaultCreditCardAccountRef == "51")
    }

    @Test func severalUnusedCreditCardAccountsLeaveTheSlotMissing() throws {
        let accounts = completeAccounts + [account("51", "Fuel Card", type: "Credit Card")]
        let proposal = try #require(propose(accounts: accounts, purchases: [purchase("P1", account: "40", paymentType: "Check")]))
        #expect(proposal.missingSlots == [.creditCardAccount])
    }

    @Test func noCreditCardAccountNamesThatSlot() throws {
        let accounts = completeAccounts.filter { $0.AccountType != "Credit Card" }
        let proposal = try #require(propose(accounts: accounts))
        #expect(proposal.missingSlots == [.creditCardAccount])
        guard case .incomplete(let missing) = proposal else { return }
        #expect(Defaults.incompleteMessage(missing) == "QuickBooks has no active Credit Card account yet.")
    }

    // MARK: - Determinism

    @Test func proposalIsIndependentOfInputOrder() throws {
        let accounts = completeAccounts + [account("31", "A/P Canada", type: "Accounts Payable"),
                                           account("41", "Savings", type: "Bank")]
        let items = [item("1", "Diagnostic", income: "10"), item("2", "Maintenance", income: "10")]
        let invoices = try [invoice("I1", itemIDs: ["2", "1"]), invoice("I2", itemIDs: ["2"])]
        let bills = try [bill("B1", apAccount: "31"), bill("B2", apAccount: "30"), bill("B3", apAccount: "31")]
        let deposits = [deposit("D1", account: "41"), deposit("D2", account: "40"), deposit("D3", account: "41")]
        let forward = propose(items: items, accounts: accounts, invoices: invoices, deposits: deposits, bills: bills)
        let reversed = propose(
            items: items.reversed(), accounts: accounts.reversed(), invoices: invoices.reversed(),
            deposits: deposits.reversed(), bills: bills.reversed()
        )
        #expect(forward == reversed)
        let configuration = try #require(forward?.configuration)
        #expect(configuration.defaultSalesItemRef == "2")
        #expect(configuration.defaultAPAccountRef == "31")
        #expect(configuration.defaultBankAccountRef == "41")
    }

    @Test func salesReceiptsAndPaymentsCannotInfluenceTheProposalToday() throws {
        // The app's QuickBooksSalesReceipt has no lines and QuickBooksPayment
        // has no DepositToAccountRef, so these records add no usage.
        let items = [item("1", "Diagnostic", income: "10"), item("2", "Maintenance", income: "10")]
        let proposal = try #require(propose(
            items: items, salesReceipts: [try salesReceipt("S1")], payments: [try payment("P1")]
        ))
        #expect(proposal.missingSlots == [.salesItem])
    }
}

/// The automatic save may only follow an explicit "no mapping" answer from
/// the server; a failed refresh must never be read as absence.
@MainActor
struct QuickBooksAccountingDefaultsAbsenceGuardTests {
    private struct RefreshFailure: Error {}

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "GunnAireAccountingDefaultsTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func serverSayingNoMappingConfirmsAbsenceForThatCompanyOnly() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuickBooksAccountingConfigurationStore(defaults: defaults) { nil }
        await store.refresh(realmID: "realm-a", environment: "sandbox", force: true)
        #expect(store.configuration == nil)
        #expect(store.hasConfirmedNoConfiguration(realmID: "realm-a", environment: "sandbox"))
        #expect(store.hasConfirmedNoConfiguration(realmID: "realm-a", environment: "Sandbox"))
        #expect(!store.hasConfirmedNoConfiguration(realmID: "realm-b", environment: "sandbox"))
        #expect(!store.hasConfirmedNoConfiguration(realmID: "realm-a", environment: "production"))
        #expect(!store.hasConfirmedNoConfiguration(realmID: nil, environment: "sandbox"))
    }

    @Test func failedRefreshNeverConfirmsAbsence() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var succeed = true
        let store = QuickBooksAccountingConfigurationStore(defaults: defaults) {
            if succeed { return nil }
            throw RefreshFailure()
        }
        await store.refresh(realmID: "realm-a", environment: "sandbox", force: true)
        #expect(store.hasConfirmedNoConfiguration(realmID: "realm-a", environment: "sandbox"))
        succeed = false
        await store.refresh(realmID: "realm-a", environment: "sandbox", force: true)
        #expect(store.configuration == nil)
        #expect(!store.hasConfirmedNoConfiguration(realmID: "realm-a", environment: "sandbox"))
    }

    @Test func existingMappingNeverConfirmsAbsence() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = BackendQuickBooksAccountingConfiguration(
            realmID: "realm-a", environment: "sandbox",
            defaultSalesItemRef: "1", defaultSalesItemName: "HVAC Service", defaultSalesItemType: "Service",
            defaultIncomeAccountRef: "10", defaultIncomeAccountName: "Services", defaultIncomeAccountType: "Income",
            defaultExpenseAccountRef: "20", defaultExpenseAccountName: "Job Materials", defaultExpenseAccountType: "Cost of Goods Sold",
            defaultAPAccountRef: "30", defaultAPAccountName: "Accounts Payable (A/P)", defaultAPAccountType: "Accounts Payable",
            defaultBankAccountRef: "40", defaultBankAccountName: "Checking", defaultBankAccountType: "Bank",
            defaultCreditCardAccountRef: "50", defaultCreditCardAccountName: "Company Visa", defaultCreditCardAccountType: "Credit Card",
            updatedAt: nil, updatedBy: "admin@example.com"
        )
        let store = QuickBooksAccountingConfigurationStore(defaults: defaults) { saved }
        await store.refresh(realmID: "realm-a", environment: "sandbox", force: true)
        #expect(store.configuration == saved)
        #expect(!store.hasConfirmedNoConfiguration(realmID: "realm-a", environment: "sandbox"))
    }
}
