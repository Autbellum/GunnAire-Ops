import Foundation

/// Card and bank transactions use different Payments resources, including
/// refunds. Never infer the resource from whether an opaque ID looks numeric.
enum QuickBooksPaymentRail: String, Codable {
    case card = "charges"
    case bank = "echecks"

    static func forMethod(_ method: String) -> Self? {
        let value = method.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "ach" || value.hasPrefix("ach ") { return .bank }
        if value == "card" || value.hasPrefix("card ") { return .card }
        return nil
    }

    func refundPath(transactionID: String) -> String? {
        let id = transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !id.isEmpty, id.utf8.count <= 128,
              id.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return nil }
        return "\(rawValue)/\(id)/refunds"
    }
}

/// The eCheck contract deliberately has no card currency/capture fields.
struct QuickBooksPaymentsECheckCreate: Encodable {
    let amount: String
    let token: String
    let description: String?
    let context: QuickBooksPaymentsChargeContext?
    let paymentMode: String
    let checkNumber: String?
}
