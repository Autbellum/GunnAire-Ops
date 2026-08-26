import Foundation

/// A non-sensitive reference to a customer-scoped payment method held by an
/// approved processor. Full card numbers, CVC values, and one-time card tokens
/// are never represented by this type; the opaque provider payment-method ID is
/// retained only for reconciliation.
struct StoredPaymentMethodReference: Codable, Identifiable, Equatable, Sendable {
    static let quickBooksPaymentsProvider = "quickbooks-payments"

    let id: String
    let provider: String
    let providerCustomerID: String
    var cardholderName: String?
    var cardBrand: String?
    var lastFour: String?
    var expirationMonth: String?
    var expirationYear: String?
    var active: Bool
    var updatedAt: Date

    init(
        id: String,
        provider: String = Self.quickBooksPaymentsProvider,
        providerCustomerID: String,
        cardholderName: String? = nil,
        cardBrand: String? = nil,
        lastFour: String? = nil,
        expirationMonth: String? = nil,
        expirationYear: String? = nil,
        active: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerCustomerID = providerCustomerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cardholderName = Self.normalized(cardholderName)
        self.cardBrand = Self.normalized(cardBrand)
        self.lastFour = Self.safeLastFour(lastFour)
        self.expirationMonth = Self.safeExpirationComponent(expirationMonth, maximumDigits: 2)
        self.expirationYear = Self.safeExpirationComponent(expirationYear, maximumDigits: 4)
        self.active = active
        self.updatedAt = updatedAt
    }

    var displayLabel: String {
        let brand = cardBrand ?? "Card"
        guard let lastFour else { return brand }
        return "\(brand) •••• \(lastFour)"
    }

    var expirationLabel: String? {
        guard let expirationMonth, let expirationYear else { return nil }
        return "Expires \(expirationMonth)/\(expirationYear)"
    }

    static func safeLastFour(_ value: String?) -> String? {
        guard let value else { return nil }
        let digits = value.filter(\.isNumber)
        guard digits.count >= 4 else { return nil }
        return String(digits.suffix(4))
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func safeExpirationComponent(_ value: String?, maximumDigits: Int) -> String? {
        guard let value else { return nil }
        let digits = String(value.filter(\.isNumber).prefix(maximumDigits))
        return digits.isEmpty ? nil : digits
    }
}
