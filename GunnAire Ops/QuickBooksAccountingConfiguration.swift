import Foundation
import Combine

struct BackendQuickBooksAccountingConfiguration: Codable, Equatable {
    let realmID: String
    let environment: String
    let defaultSalesItemRef: String
    let defaultSalesItemName: String
    let defaultSalesItemType: String
    let defaultIncomeAccountRef: String
    let defaultIncomeAccountName: String
    let defaultIncomeAccountType: String
    let defaultExpenseAccountRef: String
    let defaultExpenseAccountName: String
    let defaultExpenseAccountType: String
    let defaultAPAccountRef: String
    let defaultAPAccountName: String
    let defaultAPAccountType: String
    let defaultBankAccountRef: String
    let defaultBankAccountName: String
    let defaultBankAccountType: String
    let defaultCreditCardAccountRef: String
    let defaultCreditCardAccountName: String
    let defaultCreditCardAccountType: String
    let updatedAt: String?
    let updatedBy: String?

    var isComplete: Bool {
        ![
            realmID,
            environment,
            defaultSalesItemRef,
            defaultSalesItemName,
            defaultSalesItemType,
            defaultIncomeAccountRef,
            defaultIncomeAccountName,
            defaultIncomeAccountType,
            defaultExpenseAccountRef,
            defaultExpenseAccountName,
            defaultExpenseAccountType,
            defaultAPAccountRef,
            defaultAPAccountName,
            defaultAPAccountType,
            defaultBankAccountRef,
            defaultBankAccountName,
            defaultBankAccountType,
            defaultCreditCardAccountRef,
            defaultCreditCardAccountName,
            defaultCreditCardAccountType
        ].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func matches(realmID: String?, environment: String) -> Bool {
        guard let realmID else { return false }
        return self.realmID.trimmingCharacters(in: .whitespacesAndNewlines) == realmID.trimmingCharacters(in: .whitespacesAndNewlines) &&
            self.environment.caseInsensitiveCompare(environment.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    var salesItemReference: QuickBooksReference {
        QuickBooksReference(value: defaultSalesItemRef, name: defaultSalesItemName)
    }

    var incomeAccountReference: QuickBooksReference {
        QuickBooksReference(value: defaultIncomeAccountRef, name: defaultIncomeAccountName)
    }

    var expenseAccountReference: QuickBooksReference {
        QuickBooksReference(value: defaultExpenseAccountRef, name: defaultExpenseAccountName)
    }

    var accountsPayableReference: QuickBooksReference {
        QuickBooksReference(value: defaultAPAccountRef, name: defaultAPAccountName)
    }

    var bankAccountReference: QuickBooksReference {
        QuickBooksReference(value: defaultBankAccountRef, name: defaultBankAccountName)
    }

    var creditCardAccountReference: QuickBooksReference {
        QuickBooksReference(value: defaultCreditCardAccountRef, name: defaultCreditCardAccountName)
    }

    func paymentAccountReference(for paymentType: String) -> QuickBooksReference? {
        switch paymentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "cash", "check": bankAccountReference
        case "creditcard", "credit card": creditCardAccountReference
        default: nil
        }
    }
}

enum QuickBooksAccountingConfigurationError: LocalizedError, Equatable {
    case missingConnectionContext
    case contextMismatch
    case incomplete
    case unavailable

    var errorDescription: String? {
        switch self {
        case .missingConnectionContext:
            "Connect QuickBooks before loading accounting mappings."
        case .contextMismatch:
            "Accounting mappings belong to a different QuickBooks company or environment. Refresh them before posting."
        case .incomplete:
            "Choose the default sales item, income account, expense account, Accounts Payable account, bank account, and credit-card account."
        case .unavailable:
            "Accounting mappings are unavailable. Ask an administrator to open QuickBooks Management → Overview → Accounting Mappings."
        }
    }
}

@MainActor
final class QuickBooksAccountingConfigurationStore: ObservableObject {
    static let shared = QuickBooksAccountingConfigurationStore()

    @Published private(set) var configuration: BackendQuickBooksAccountingConfiguration?
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage: String?

    private let defaults: UserDefaults
    private var loadingContext: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func configuration(
        for realmID: String?,
        environment: String
    ) -> BackendQuickBooksAccountingConfiguration? {
        guard let realmID = normalizedRealmID(realmID) else { return nil }
        if let configuration, configuration.matches(realmID: realmID, environment: environment) {
            return configuration
        }
        guard let cached = cachedConfiguration(realmID: realmID, environment: environment),
              cached.matches(realmID: realmID, environment: environment),
              cached.isComplete else {
            return nil
        }
        configuration = cached
        return cached
    }

    func refresh(
        realmID: String?,
        environment: String,
        force: Bool = false
    ) async {
        guard let realmID = normalizedRealmID(realmID) else {
            statusMessage = QuickBooksAccountingConfigurationError.missingConnectionContext.localizedDescription
            return
        }
        if !force, configuration(for: realmID, environment: environment) != nil {
            return
        }
        let context = cacheKey(realmID: realmID, environment: environment)
        guard loadingContext != context else { return }
        loadingContext = context
        isLoading = true
        defer {
            isLoading = false
            loadingContext = nil
        }
        do {
            let remote = try await GunnAireBackendService.fetchQuickBooksAccountingConfiguration()
            if let remote {
                guard remote.matches(realmID: realmID, environment: environment), remote.isComplete else {
                    throw QuickBooksAccountingConfigurationError.contextMismatch
                }
                configuration = remote
                cache(remote)
                statusMessage = "Accounting mappings are ready for this QuickBooks company."
            } else {
                configuration = nil
                defaults.removeObject(forKey: context)
                statusMessage = QuickBooksAccountingConfigurationError.unavailable.localizedDescription
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @discardableResult
    func save(
        _ candidate: BackendQuickBooksAccountingConfiguration,
        realmID: String?,
        environment: String
    ) async throws -> BackendQuickBooksAccountingConfiguration {
        guard let realmID = normalizedRealmID(realmID) else {
            throw QuickBooksAccountingConfigurationError.missingConnectionContext
        }
        guard candidate.isComplete else {
            throw QuickBooksAccountingConfigurationError.incomplete
        }
        guard candidate.matches(realmID: realmID, environment: environment) else {
            throw QuickBooksAccountingConfigurationError.contextMismatch
        }
        isLoading = true
        defer { isLoading = false }
        let saved = try await GunnAireBackendService.updateQuickBooksAccountingConfiguration(candidate)
        guard saved.matches(realmID: realmID, environment: environment), saved.isComplete else {
            throw QuickBooksAccountingConfigurationError.contextMismatch
        }
        configuration = saved
        cache(saved)
        statusMessage = "Accounting mappings saved for this QuickBooks company."
        return saved
    }

    #if DEBUG
    func installFixture(_ fixture: BackendQuickBooksAccountingConfiguration?) {
        configuration = fixture
        if let fixture { cache(fixture) }
    }
    #endif

    private func cache(_ configuration: BackendQuickBooksAccountingConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(
            data,
            forKey: cacheKey(realmID: configuration.realmID, environment: configuration.environment)
        )
    }

    private func cachedConfiguration(
        realmID: String,
        environment: String
    ) -> BackendQuickBooksAccountingConfiguration? {
        guard let data = defaults.data(forKey: cacheKey(realmID: realmID, environment: environment)) else {
            return nil
        }
        return try? JSONDecoder().decode(BackendQuickBooksAccountingConfiguration.self, from: data)
    }

    private func cacheKey(realmID: String, environment: String) -> String {
        "GunnAireQBOAccountingConfiguration.\(environment.lowercased()).\(realmID)"
    }

    private func normalizedRealmID(_ realmID: String?) -> String? {
        guard let normalized = realmID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else { return nil }
        return normalized
    }
}
