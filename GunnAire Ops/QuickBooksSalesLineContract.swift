import Foundation

/// Shared native boundary for saved proposals, provider confirmations and mapped
/// invoice reads. A Group header is never charged or substituted with a Service.
enum QuickBooksSalesLineContract {
    struct Totals {
        let gross: Decimal
        let discount: Decimal
        let taxable: Bool
        var net: Decimal { gross - discount }
    }

    static func totals(_ lines: [QuickBooksLineItem], allowsSubtotal: Bool = false) throws -> Totals {
        guard !lines.isEmpty, lines.count <= (allowsSubtotal ? 751 : 750) else { throw BillingPublicationError.invalidResponse }
        var count = 0, ids = Set<String>(), groupIDs = Set<String>(), leafIDs = Set<String>()
        var gross = Decimal.zero, discount = Decimal.zero, subtotal: Decimal?, discounted = false, taxable = false

        func identity(_ line: QuickBooksLineItem) throws {
            if let id = line.Id {
                guard validReference(id), ids.insert(id).inserted else { throw BillingPublicationError.invalidResponse }
            }
        }
        func sold(_ line: QuickBooksLineItem) throws -> Decimal {
            count += 1
            guard count <= 750, line.DetailType == "SalesItemLineDetail", line.GroupLineDetail == nil,
                  line.DiscountLineDetail == nil, line.hasExplicitAmount,
                  let amount = decimal(line.Amount, places: 2) else { throw BillingPublicationError.invalidResponse }
            try identity(line)
            let detail = line.SalesItemLineDetail
            guard validReference(detail.ItemRef.value),
                  let qty = detail.Qty.flatMap({ decimal($0, places: 5, maximum: 999_999) }), qty > 0,
                  let price = detail.UnitPrice.flatMap({ decimal($0, places: 5) }),
                  ["TAX", "NON"].contains(detail.TaxCodeRef?.value ?? ""), rounded(qty * price) == amount else {
                throw BillingPublicationError.invalidResponse
            }
            leafIDs.insert(detail.ItemRef.value)
            taxable = taxable || detail.TaxCodeRef?.value == "TAX"
            return amount
        }
        for (index, line) in lines.enumerated() {
            switch line.DetailType {
            case "SalesItemLineDetail":
                guard !discounted else { throw BillingPublicationError.invalidResponse }
                gross += try sold(line)
            case "GroupLineDetail":
                count += 1
                try identity(line)
                guard !discounted, count < 750, line.hasValidGroupHeaderAmount, line.Amount == 0,
                      line.DiscountLineDetail == nil, line.SalesItemLineDetail.ItemRef.value.isEmpty,
                      let group = line.GroupLineDetail, validReference(group.GroupItemRef.value),
                      let quantity = decimal(group.Quantity, places: 5, maximum: 999_999), quantity > 0,
                      !group.Line.isEmpty, group.Line.count < 750 else { throw BillingPublicationError.invalidResponse }
                groupIDs.insert(group.GroupItemRef.value)
                for member in group.Line { gross += try sold(member) }
            case "DiscountLineDetail":
                count += 1
                try identity(line)
                guard count <= 750, index > 0, index == lines.count - 1, !discounted, line.hasExplicitAmount,
                      line.GroupLineDetail == nil, let amount = decimal(line.Amount, places: 2), amount <= gross,
                      let detail = line.DiscountLineDetail else { throw BillingPublicationError.invalidResponse }
                if detail.PercentBased {
                    guard let percent = detail.DiscountPercent.flatMap({ decimal($0, places: 5, maximum: 100) }),
                          rounded(gross * percent / 100) == amount else { throw BillingPublicationError.invalidResponse }
                } else if detail.DiscountPercent != nil { throw BillingPublicationError.invalidResponse }
                discount = amount; discounted = true
            case "SubTotalLineDetail":
                try identity(line)
                guard allowsSubtotal, subtotal == nil, line.hasExplicitAmount,
                      let amount = decimal(line.Amount, places: 2) else { throw BillingPublicationError.invalidResponse }
                subtotal = amount
            default: throw BillingPublicationError.invalidResponse
            }
        }
        guard count > 0, groupIDs.isDisjoint(with: leafIDs), gross <= 99_999_999_999,
              subtotal == nil || subtotal == gross else { throw BillingPublicationError.invalidResponse }
        return .init(gross: gross, discount: discount, taxable: taxable)
    }

    static func decimal(_ value: Double, places: Int, maximum: Double = 99_999_999_999) -> Decimal? {
        guard value.isFinite, value >= 0, value <= maximum,
              var number = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var rounded = Decimal.zero
        NSDecimalRound(&rounded, &number, places, .plain)
        return rounded == number ? number : nil
    }

    static func rounded(_ value: Decimal) -> Decimal {
        var value = value, result = Decimal.zero
        NSDecimalRound(&result, &value, 2, .plain)
        return result
    }

    static func validReference(_ value: String) -> Bool {
        value != "." && value != ".." && value.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil
    }

    static func unitPriceLabel(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2...5)))
    }

    /// Used only for presentation; malformed data is shown as needing review.
    static func displayedAmount(_ line: QuickBooksLineItem) -> Double? {
        if line.DetailType == "DiscountLineDetail", line.hasExplicitAmount,
           decimal(line.Amount, places: 2) != nil { return -line.Amount }
        guard let total = try? totals([line]) else { return nil }
        return NSDecimalNumber(decimal: total.net).doubleValue
    }
}
