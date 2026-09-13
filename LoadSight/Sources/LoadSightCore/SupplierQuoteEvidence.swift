import Foundation

/// Estimator-recorded evidence for the exact cost/unit/source in its containing mapping.
/// Dates are assertions from the supplied quote, not live supplier guarantees.
public struct SupplierQuoteEvidence: Codable, Equatable, Sendable {
    public let supplier: String
    public let reference: String
    public let source: String
    public let issuedAt: String
    public let validUntil: String?
    public let conditions: String
    public init(supplier: String, reference: String, source: String, issuedAt: String, validUntil: String?, conditions: String) {
        self.supplier = supplier; self.reference = reference; self.source = source
        self.issuedAt = issuedAt; self.validUntil = validUntil; self.conditions = conditions
    }
    private enum CodingKeys: String, CodingKey { case supplier, reference, source, issuedAt, validUntil, conditions }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(supplier, forKey: .supplier); try c.encode(reference, forKey: .reference)
        try c.encode(source, forKey: .source); try c.encode(issuedAt, forKey: .issuedAt)
        try c.encode(validUntil, forKey: .validUntil); try c.encode(conditions, forKey: .conditions)
    }
    public func validate() throws {
        for value in [supplier, reference, source, conditions] {
            try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Quote supplier, reference, source and conditions are required.")
        }
        guard let issued = ISO8601DateFormatter().date(from: issuedAt) else { throw LoadSightError.invalid("Quote issue time must include an ISO 8601 date, time and timezone.") }
        if let validUntil {
            guard let end = ISO8601DateFormatter().date(from: validUntil) else { throw LoadSightError.invalid("Quote expiry must include an ISO 8601 date, time and timezone, or remain unknown.") }
            try require(end > issued, "Quote expiry must be after its issue time.")
        }
    }
    public func review(asOf: Date) throws -> SupplierQuoteReview {
        try validate()
        try require(asOf.timeIntervalSince1970.isFinite, "Quote review time must be finite.")
        let issued = ISO8601DateFormatter().date(from: issuedAt)!
        let status: SupplierQuoteStatus
        if asOf < issued { status = .notYetIssued }
        else if let validUntil {
            status = asOf >= ISO8601DateFormatter().date(from: validUntil)! ? .expired : .withinRecordedPeriod
        } else { status = .expiryUnknown }
        return .init(status: status, asOf: ISO8601DateFormatter().string(from: asOf))
    }
}
public enum SupplierQuoteStatus: String, Codable, Sendable {
    case notYetIssued, expired, expiryUnknown, withinRecordedPeriod
}
public struct SupplierQuoteReview: Codable, Sendable {
    public let status: SupplierQuoteStatus
    public let asOf: String
    public var message: String {
        switch status {
        case .notYetIssued: "The recorded quote issue time is in the future. Review its dates."
        case .expired: "The recorded quote has expired. Obtain and record renewed cost evidence."
        case .expiryUnknown: "Quote expiry is unknown. Record the supplier's validity terms before release."
        case .withinRecordedPeriod: "Within the recorded quote period; supplier availability and all quote conditions still require review."
        }
    }
}
