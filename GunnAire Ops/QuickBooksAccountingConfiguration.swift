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

/// What the server said when asked for the accounting mapping: the company it
/// answered for and the mapping, if any. `realmID`/`environment` are nil only
/// for legacy fetches that never carried the server's context.
struct QuickBooksAccountingConfigurationReply: Equatable {
    let realmID: String?
    let environment: String?
    let configuration: BackendQuickBooksAccountingConfiguration?
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
    /// Cache key of the company/environment whose most recent server refresh
    /// answered definitively that no mapping exists. A failed refresh never
    /// sets it, so an automatic derivation cannot overwrite a saved mapping
    /// the app merely failed to fetch.
    @Published private(set) var confirmedAbsentContext: String?

    private let defaults: UserDefaults
    private let fetchReply: () async throws -> QuickBooksAccountingConfigurationReply
    private var loadingContext: String?
    private var refreshID: UUID?

    init(defaults: UserDefaults = .standard,
         fetchReply: @escaping () async throws -> QuickBooksAccountingConfigurationReply = {
             try await GunnAireBackendService.fetchQuickBooksAccountingConfigurationReply()
         }) {
        self.defaults = defaults
        self.fetchReply = fetchReply
    }

    /// A fetch that returns only the mapping cannot say which company the server
    /// answered for, so it can load a mapping but never confirm that none exists.
    convenience init(defaults: UserDefaults = .standard,
                     fetchConfiguration: @escaping () async throws -> BackendQuickBooksAccountingConfiguration?) {
        self.init(defaults: defaults, fetchReply: {
            let configuration = try await fetchConfiguration()
            return QuickBooksAccountingConfigurationReply(
                realmID: configuration?.realmID, environment: configuration?.environment, configuration: configuration
            )
        })
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

    /// True only when the latest refresh for this company and environment
    /// received an explicit "no configuration" answer from the server.
    func hasConfirmedNoConfiguration(realmID: String?, environment: String) -> Bool {
        guard let realmID = normalizedRealmID(realmID) else { return false }
        return confirmedAbsentContext == cacheKey(realmID: realmID, environment: environment)
    }

    func refresh(
        realmID: String?,
        environment: String,
        force: Bool = false,
        validate: () throws -> Void = {}
    ) async {
        do { try validate() } catch { return }
        guard let realmID = normalizedRealmID(realmID) else {
            statusMessage = QuickBooksAccountingConfigurationError.missingConnectionContext.localizedDescription
            return
        }
        if !force, configuration(for: realmID, environment: environment) != nil {
            return
        }
        let context = cacheKey(realmID: realmID, environment: environment)
        guard force || loadingContext != context else { return }
        let requestID = UUID()
        refreshID = requestID
        loadingContext = context
        confirmedAbsentContext = nil
        isLoading = true
        defer {
            if refreshID == requestID {
                isLoading = false
                loadingContext = nil
                refreshID = nil
            }
        }
        do {
            let reply = try await fetchReply()
            try validate()
            guard refreshID == requestID else { return }
            if let remote = reply.configuration {
                guard remote.matches(realmID: realmID, environment: environment), remote.isComplete else {
                    throw QuickBooksAccountingConfigurationError.contextMismatch
                }
                configuration = remote
                cache(remote)
                statusMessage = "Accounting mappings are ready for this QuickBooks company."
            } else {
                configuration = nil
                defaults.removeObject(forKey: context)
                // "No mapping" is a fact only for the company the server answered
                // for; a device still holding another realm's token must not read
                // the server's answer as absence for its own.
                if normalizedRealmID(reply.realmID) == realmID,
                   reply.environment?.caseInsensitiveCompare(environment) == .orderedSame {
                    confirmedAbsentContext = context
                    statusMessage = QuickBooksAccountingConfigurationError.unavailable.localizedDescription
                } else {
                    statusMessage = QuickBooksAccountingConfigurationError.contextMismatch.localizedDescription
                }
            }
        } catch {
            do { try validate() } catch { return }
            guard refreshID == requestID else { return }
            statusMessage = error.localizedDescription
        }
    }

    nonisolated static let savedStatusMessage = "Accounting mappings saved for this QuickBooks company."

    /// Sends `candidate` to the server, which validates every mapping and
    /// requires an administrator session. `statusMessage` is shown after a
    /// successful save so an automatic derivation can say where it came from.
    @discardableResult
    func save(
        _ candidate: BackendQuickBooksAccountingConfiguration,
        realmID: String?,
        environment: String,
        statusMessage successMessage: String = QuickBooksAccountingConfigurationStore.savedStatusMessage
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
        confirmedAbsentContext = nil
        statusMessage = successMessage
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
