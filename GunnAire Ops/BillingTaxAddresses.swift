import Foundation

enum BillingTaxAddressError: LocalizedError, Equatable {
    case required, invalid, changed
    var errorDescription: String? {
        switch self {
        case .required: "Open Tax addresses in the billing editor and confirm the service and sale locations before syncing taxable work. The draft is saved."
        case .invalid: "Enter a complete US street address, city, state and ZIP code for both locations."
        case .changed: "The customer or service location changed. Review Tax addresses again for this draft."
        }
    }
}

struct BillingTaxAddressScope: Codable, Equatable {
    let customerID: UUID
    let serviceLocationID: UUID?
    let siteAddress: String?

    init(customerID: UUID, serviceLocationID: UUID?, siteAddress: String?) {
        self.customerID = customerID; self.serviceLocationID = serviceLocationID
        let text = siteAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.siteAddress = text?.isEmpty == false ? text : nil
    }
}

/// Stored inside the existing CloudKit-backed immutable line snapshot, not in
/// device preferences. This is address evidence, never a tax-rate calculation or
/// a financial approval. Estimate-to-invoice conversion retains the same scope.
struct BillingTaxAddressContext: Codable, Equatable {
    let version: Int
    let scope: BillingTaxAddressScope
    let service: BillingPublicationAddress
    let origin: BillingPublicationAddress
    let reviewedAt: Date

    init(scope: BillingTaxAddressScope, service: BillingPublicationAddress,
         origin: BillingPublicationAddress, now: Date = Date()) throws {
        guard service.isValidUS, origin.isValidUS, now.timeIntervalSince1970.isFinite else {
            throw BillingTaxAddressError.invalid
        }
        version = 1; self.scope = scope; self.service = service.trimmed
        self.origin = origin.trimmed; reviewedAt = now
    }

    func validate(for scope: BillingTaxAddressScope) throws {
        guard version == 1, service.isValidUS, origin.isValidUS,
              reviewedAt.timeIntervalSince1970.isFinite else { throw BillingTaxAddressError.invalid }
        guard self.scope == scope else { throw BillingTaxAddressError.changed }
    }

    private struct Envelope: Decodable { let taxAddresses: BillingTaxAddressContext? }
    static func read(_ snapshotJSON: String?) -> BillingTaxAddressContext? {
        guard let data = snapshotJSON?.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.taxAddresses
    }

    /// Preserve sold lines, discounts and unknown snapshot metadata byte values.
    /// Legacy line arrays are wrapped using the existing version-one envelope.
    static func attaching(_ addresses: Self, to snapshotJSON: String) throws -> String {
        guard let data = snapshotJSON.data(using: .utf8),
              !CatalogLineItemSnapshot.decoded(from: snapshotJSON).isEmpty else {
            throw BillingTaxAddressError.invalid
        }
        try addresses.validate(for: addresses.scope)
        let parsed = try JSONSerialization.jsonObject(with: data)
        var envelope: [String: Any]
        if let existing = parsed as? [String: Any] { envelope = existing }
        else if let lines = parsed as? [[String: Any]] { envelope = ["version": 1, "lines": lines] }
        else { throw BillingTaxAddressError.invalid }
        envelope["taxAddresses"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(addresses))
        let result = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard let text = String(data: result, encoding: .utf8) else { throw BillingTaxAddressError.invalid }
        return text
    }

    @MainActor static func forPublication(_ document: QuickBooksBillingDocument) throws -> Self? {
        let scope: BillingTaxAddressScope
        switch document {
        case .invoice(let value): scope = .init(customerID: value.customer.id,
            serviceLocationID: value.serviceLocationID, siteAddress: value.siteAddress)
        case .estimate(let value): scope = .init(customerID: value.customer.id,
            serviceLocationID: value.serviceLocationID, siteAddress: value.siteAddress)
        }
        guard let addresses = read(document.snapshotJSON) else {
            if BillingTaxPolicy.hasTaxableLines(document.snapshotJSON) { throw BillingTaxAddressError.required }
            return nil
        }
        try addresses.validate(for: scope)
        return addresses
    }
}

extension BillingPublicationAddress {
    static var empty: Self { .init(Line1: "", City: "", CountrySubDivisionCode: "", PostalCode: "") }
    var trimmed: Self {
        .init(Line1: Line1.trimmingCharacters(in: .whitespacesAndNewlines),
              City: City.trimmingCharacters(in: .whitespacesAndNewlines),
              CountrySubDivisionCode: CountrySubDivisionCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              PostalCode: PostalCode.trimmingCharacters(in: .whitespacesAndNewlines),
              Country: Country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }
    var isValidUS: Bool {
        let value = trimmed
        let fields = [(value.Line1, 500), (value.City, 255), (value.CountrySubDivisionCode, 2),
                      (value.PostalCode, 10), (value.Country, 3)]
        let states = Set("AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY AS GU MP PR VI AA AE AP".split(separator: " ").map(String.init))
        return fields.allSatisfy { text, limit in
            !text.isEmpty && text.count <= limit && !text.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
        } && states.contains(value.CountrySubDivisionCode) && ["US", "USA"].contains(value.Country) &&
            value.PostalCode.range(of: #"^[0-9]{5}(-[0-9]{4})?$"#, options: .regularExpression) != nil
    }
    var quickBooksAddress: QuickBooksAddress {
        .init(Line1: Line1, City: City, CountrySubDivisionCode: CountrySubDivisionCode,
              PostalCode: PostalCode, Country: Country)
    }
}
