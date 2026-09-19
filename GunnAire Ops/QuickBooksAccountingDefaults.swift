import Foundation

/// Derives the six accounting defaults for a QuickBooks company from what
/// QuickBooks itself returned during a sync, so the mapping record can be
/// created without a person choosing accounts by hand.
///
/// Every rule reads only records QuickBooks returned; nothing is invented.
/// A slot is filled either by observed usage (transactions or catalog items
/// that reference the candidate) or, when there is exactly one candidate, by
/// that single candidate. A slot with several candidates and no usage stays
/// unresolved: choosing among equally unused accounts would be a guess.
///
/// Model coverage (verified against `QuickBooksDataAPI.swift`):
/// - `QuickBooksBill` carries `APAccountRef` but no expense lines, so bills
///   contribute to the Accounts Payable choice only.
/// - `QuickBooksPurchase` carries `AccountRef` and `PaymentType` but no
///   expense lines, so purchases contribute to the credit-card choice only.
/// - `QuickBooksPayment` carries no `DepositToAccountRef`, so payments
///   contribute nothing to the bank choice; deposits do.
/// - `QuickBooksSalesReceipt` carries no `Line`, so sales receipts contribute
///   nothing to the sales-item choice; invoices do.
enum QuickBooksAccountingDefaults {
    enum Slot: String, CaseIterable, Equatable {
        case salesItem
        case incomeAccount
        case expenseAccount
        case accountsPayableAccount
        case bankAccount
        case creditCardAccount

        /// What QuickBooks would need to contain for the slot to resolve.
        var requirement: String {
            switch self {
            case .salesItem: "active Service item"
            case .incomeAccount: "active Income account"
            case .expenseAccount: "active Expense or Cost of Goods Sold account"
            case .accountsPayableAccount: "active Accounts Payable account"
            case .bankAccount: "active Bank account"
            case .creditCardAccount: "active Credit Card account"
            }
        }
    }

    enum MissingReason: Equatable {
        /// QuickBooks returned no active candidate for the slot.
        case noCandidates
        /// Several active candidates and no usage distinguished one.
        case ambiguous(candidateCount: Int)
    }

    struct MissingSlot: Equatable {
        let slot: Slot
        let reason: MissingReason

        var message: String {
            switch reason {
            case .noCandidates:
                "QuickBooks has no \(slot.requirement) yet"
            case .ambiguous(let count):
                "QuickBooks has \(count) \(slot.requirement)s and no usage singles one out as the default"
            }
        }
    }

    enum Proposal: Equatable {
        case complete(BackendQuickBooksAccountingConfiguration)
        case incomplete([MissingSlot])

        var configuration: BackendQuickBooksAccountingConfiguration? {
            if case .complete(let configuration) = self { return configuration }
            return nil
        }

        var missingSlots: [Slot] {
            if case .incomplete(let missing) = self { return missing.map(\.slot) }
            return []
        }
    }

    private static let incomeAccountTypes: Set<String> = ["income", "other income"]
    private static let expenseAccountTypes: Set<String> = ["expense", "cost of goods sold"]
    private static let accountsPayableType = "accounts payable"
    private static let bankType = "bank"
    private static let creditCardType = "credit card"
    private static let serviceItemType = "service"
    private static let creditCardPaymentTypes: Set<String> = ["creditcard", "credit card"]

    /// Returns `nil` when QuickBooks returned neither items nor accounts, an
    /// `.incomplete` proposal naming every slot that could not be resolved,
    /// or a `.complete` configuration ready for the server to validate.
    static func propose(
        items: [QuickBooksItem],
        accounts: [QuickBooksAccount],
        invoices: [QuickBooksInvoice],
        salesReceipts: [QuickBooksSalesReceipt],
        payments: [QuickBooksPayment],
        deposits: [QuickBooksDeposit],
        bills: [QuickBooksBill],
        purchases: [QuickBooksPurchase],
        realmID: String,
        environment: String
    ) -> Proposal? {
        guard !items.isEmpty || !accounts.isEmpty else { return nil }

        let activeItems = items.filter(isActive)
        let activeAccounts = accounts.filter(isActive)
        let serviceItems = activeItems.filter { matches($0.ItemType, serviceItemType) }

        // Invoice line usage per item id. Sales receipts carry no lines in
        // the app model, so they cannot contribute (see type note above).
        let invoiceLineUsage = countUsage(invoices.flatMap { salesItemIDs(in: $0.Line ?? []) })
        _ = salesReceipts

        // Sales item: the active Service item most used on invoice lines;
        // fallback the only active Service item.
        let salesItem = resolve(
            candidates: serviceItems,
            usage: invoiceLineUsage,
            id: \.Id,
            name: \.Name
        )

        // Income account: the active income-type account referenced by the
        // most Service items' IncomeAccountRef, ties broken by the invoice
        // line usage of those items; fallback the only active "Income"
        // account (not "Other Income", which is never a default by itself).
        let incomeCandidates = activeAccounts.filter { matches($0.AccountType, incomeAccountTypes) }
        let incomeReferenceCounts = countUsage(serviceItems.compactMap { $0.IncomeAccountRef?.value })
        var incomeLineUsage: [String: Int] = [:]
        for item in serviceItems {
            guard let accountID = item.IncomeAccountRef?.value, !accountID.isEmpty else { continue }
            incomeLineUsage[accountID, default: 0] += invoiceLineUsage[item.Id] ?? 0
        }
        let incomeAccount = resolve(
            candidates: incomeCandidates,
            usage: incomeReferenceCounts,
            secondaryUsage: incomeLineUsage,
            id: \.Id,
            name: \.displayName,
            fallbackCandidates: activeAccounts.filter { matches($0.AccountType, "income") }
        )

        // Expense account: the active Expense / Cost of Goods Sold account
        // referenced by the most bill or purchase account-based lines (the
        // app model carries none, so that count is always zero), then by the
        // most active items' ExpenseAccountRef; fallback the only active
        // such account.
        let expenseCandidates = activeAccounts.filter { matches($0.AccountType, expenseAccountTypes) }
        let expenseItemUsage = countUsage(activeItems.compactMap { $0.ExpenseAccountRef?.value })
        let expenseAccount = resolve(
            candidates: expenseCandidates,
            usage: [:],
            secondaryUsage: expenseItemUsage,
            id: \.Id,
            name: \.displayName
        )

        // Accounts Payable: the single active "Accounts Payable" account; if
        // several, the one referenced by the most Bills' APAccountRef.
        let accountsPayable = resolve(
            candidates: activeAccounts.filter { matches($0.AccountType, accountsPayableType) },
            usage: countUsage(bills.compactMap { $0.APAccountRef?.value }),
            id: \.Id,
            name: \.displayName
        )

        // Bank account: the active "Bank" account used by the most deposit
        // DepositToAccountRef values (payments carry none in the app model);
        // fallback the only active Bank account.
        _ = payments
        let bankAccount = resolve(
            candidates: activeAccounts.filter { matches($0.AccountType, bankType) },
            usage: countUsage(deposits.compactMap { $0.DepositToAccountRef?.value }),
            id: \.Id,
            name: \.displayName
        )

        // Credit-card account: the active "Credit Card" account used by the
        // most credit-card purchases; fallback the only active such account.
        let creditCardPurchaseAccountIDs = purchases
            .filter { matches($0.PaymentType, creditCardPaymentTypes) }
            .compactMap { $0.AccountRef?.value }
        let creditCardAccount = resolve(
            candidates: activeAccounts.filter { matches($0.AccountType, creditCardType) },
            usage: countUsage(creditCardPurchaseAccountIDs),
            id: \.Id,
            name: \.displayName
        )

        var missing: [MissingSlot] = []
        func record<T>(_ slot: Slot, _ resolution: Resolution<T>) -> T? {
            switch resolution {
            case .resolved(let value):
                return value
            case .noCandidates:
                missing.append(MissingSlot(slot: slot, reason: .noCandidates))
            case .ambiguous(let count):
                missing.append(MissingSlot(slot: slot, reason: .ambiguous(candidateCount: count)))
            }
            return nil
        }

        let resolvedSalesItem = record(.salesItem, salesItem)
        let resolvedIncome = record(.incomeAccount, incomeAccount)
        let resolvedExpense = record(.expenseAccount, expenseAccount)
        let resolvedAP = record(.accountsPayableAccount, accountsPayable)
        let resolvedBank = record(.bankAccount, bankAccount)
        let resolvedCreditCard = record(.creditCardAccount, creditCardAccount)

        guard let resolvedSalesItem, let salesItemType = trimmed(resolvedSalesItem.ItemType),
              let resolvedIncome, let incomeType = trimmed(resolvedIncome.AccountType),
              let resolvedExpense, let expenseType = trimmed(resolvedExpense.AccountType),
              let resolvedAP, let apType = trimmed(resolvedAP.AccountType),
              let resolvedBank, let bankAccountType = trimmed(resolvedBank.AccountType),
              let resolvedCreditCard, let creditCardAccountType = trimmed(resolvedCreditCard.AccountType),
              missing.isEmpty else {
            return .incomplete(missing)
        }

        return .complete(BackendQuickBooksAccountingConfiguration(
            realmID: realmID,
            environment: environment,
            defaultSalesItemRef: resolvedSalesItem.Id,
            defaultSalesItemName: resolvedSalesItem.Name,
            defaultSalesItemType: salesItemType,
            defaultIncomeAccountRef: resolvedIncome.Id,
            defaultIncomeAccountName: resolvedIncome.displayName,
            defaultIncomeAccountType: incomeType,
            defaultExpenseAccountRef: resolvedExpense.Id,
            defaultExpenseAccountName: resolvedExpense.displayName,
            defaultExpenseAccountType: expenseType,
            defaultAPAccountRef: resolvedAP.Id,
            defaultAPAccountName: resolvedAP.displayName,
            defaultAPAccountType: apType,
            defaultBankAccountRef: resolvedBank.Id,
            defaultBankAccountName: resolvedBank.displayName,
            defaultBankAccountType: bankAccountType,
            defaultCreditCardAccountRef: resolvedCreditCard.Id,
            defaultCreditCardAccountName: resolvedCreditCard.displayName,
            defaultCreditCardAccountType: creditCardAccountType,
            updatedAt: nil,
            updatedBy: nil
        ))
    }

    /// One sentence naming exactly what QuickBooks lacks, for the sync status.
    static func incompleteMessage(_ missing: [MissingSlot]) -> String {
        guard !missing.isEmpty else { return "" }
        return missing.map(\.message).joined(separator: ". ") + "."
    }

    // MARK: - Resolution

    enum Resolution<T> {
        case resolved(T)
        case noCandidates
        case ambiguous(candidateCount: Int)
    }

    /// Picks among `candidates` by usage count (desc), then `secondaryUsage`
    /// (desc), then name (asc), then id (asc). A candidate is only chosen by
    /// usage when its primary or secondary usage is positive; otherwise the
    /// slot resolves solely when `fallbackCandidates` (default: the
    /// candidates themselves) holds exactly one record. Several unused
    /// candidates are never ranked by name alone: that would be a guess.
    private static func resolve<T>(
        candidates: [T],
        usage: [String: Int],
        secondaryUsage: [String: Int] = [:],
        id: KeyPath<T, String>,
        name: KeyPath<T, String>,
        fallbackCandidates: [T]? = nil
    ) -> Resolution<T> {
        let fallback = fallbackCandidates ?? candidates
        let ranked = candidates
            .map { candidate -> (record: T, primary: Int, secondary: Int) in
                let key = candidate[keyPath: id]
                return (candidate, usage[key] ?? 0, secondaryUsage[key] ?? 0)
            }
            .filter { $0.primary > 0 || $0.secondary > 0 }
            .sorted { lhs, rhs in
                if lhs.primary != rhs.primary { return lhs.primary > rhs.primary }
                if lhs.secondary != rhs.secondary { return lhs.secondary > rhs.secondary }
                let nameOrder = lhs.record[keyPath: name]
                    .localizedCaseInsensitiveCompare(rhs.record[keyPath: name])
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.record[keyPath: id] < rhs.record[keyPath: id]
            }
        if let best = ranked.first { return .resolved(best.record) }

        // No usage: only a single fallback candidate may be chosen. An empty
        // fallback set (for example, only "Other Income" accounts exist) is
        // reported as having no candidate for the slot's requirement.
        if fallback.count == 1, let only = fallback.first { return .resolved(only) }
        if fallback.isEmpty { return .noCandidates }
        return .ambiguous(candidateCount: fallback.count)
    }

    private static func countUsage(_ ids: [String]) -> [String: Int] {
        ids.reduce(into: [:]) { counts, id in
            let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            counts[key, default: 0] += 1
        }
    }

    /// Item references on invoice lines, including the leaves of bundle
    /// (group) lines. Discount and blank references are skipped.
    private static func salesItemIDs(in lines: [QuickBooksLineItem]) -> [String] {
        lines.flatMap { line -> [String] in
            if let group = line.GroupLineDetail {
                return salesItemIDs(in: group.Line)
            }
            let id = line.SalesItemLineDetail.ItemRef.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? [] : [id]
        }
    }

    /// QuickBooks omits `Active` when it is true; only an explicit `false`
    /// marks a record inactive (the manual mapping picker applies the same reading).
    nonisolated private static func isActive(_ item: QuickBooksItem) -> Bool { item.Active != false }
    nonisolated private static func isActive(_ account: QuickBooksAccount) -> Bool { account.Active != false }

    private static func matches(_ value: String?, _ expected: String) -> Bool {
        matches(value, [expected])
    }

    private static func matches(_ value: String?, _ expected: Set<String>) -> Bool {
        guard let normalized = trimmed(value)?.lowercased() else { return false }
        return expected.contains(normalized)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
