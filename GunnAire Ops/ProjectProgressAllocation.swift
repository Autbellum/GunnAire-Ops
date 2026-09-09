import Foundation

/// Ordinary staged invoices, not a synthetic QBO progress-invoice endpoint.
/// Allocate the entire approved contract together: every sold-row cent, quantity
/// tick (1e-5), and authorized discount is consumed exactly once across the plan.
/// Catalog lookup and provider writes remain at the existing publication boundary.
@MainActor enum ProjectProgressAllocation {
    private static let scale: Decimal = 100_000

    static func documents(from json: String?, targetAmounts: [Double]) throws -> [String] {
        let source: [CatalogLineItemSnapshot]
        do { source = try CatalogSnapshotPayload.read(json)?.lines ?? [] }
        catch { throw CatalogBundleError.invalidMembers }
        guard !source.isEmpty, Set(source.map(\.catalogItemID)).count == source.count else {
            throw ProjectBillingValidationError.missingCatalogSnapshot
        }
        for root in source {
            if root.bundle != nil || root.itemTypeRawValue == CatalogItemType.group.rawValue {
                try CatalogBundlePolicy.validate(root)
            }
        }
        let leaves = source.flatMap(\.soldLeaves)
        guard leaves.count + source.filter({ $0.bundle != nil }).count <= 750 else {
            throw ProjectBillingValidationError.invalidPersistedPlan
        }
        let lineCents = try leaves.map { line -> Int64 in
            try CatalogBundlePolicy.validQuantity(line.quantity)
            guard QuickBooksSalesLineContract.decimal(line.unitPrice, places: 5) != nil,
                  let cents = exactCents(line.extendedAmount),
                  line.purchaseCost.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                throw ProjectBillingValidationError.missingCatalogSnapshot
            }
            return cents
        }
        let gross = lineCents.reduce(0, +)
        guard gross > 0, gross <= 9_999_999_999_900 else {
            throw ProjectBillingValidationError.invalidContractAmount
        }
        let originalDiscount = CatalogLineItemSnapshot.documentDiscount(from: json)
        let discount: Int64
        if let originalDiscount {
            guard originalDiscount.value.isFinite, originalDiscount.value > 0,
                  originalDiscount.kind != .percentage || originalDiscount.value <= 100,
                  !originalDiscount.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !originalDiscount.authorizedByEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let value = originalDiscount.amount(for: amount(gross)),
                  let cents = exactCents(value), cents < gross else {
                throw ProjectBillingValidationError.invalidPersistedPlan
            }
            discount = cents
        } else { discount = 0 }
        let targets = try targetAmounts.map { value -> Int64 in
            guard let cents = exactCents(value), cents > 0 else {
                throw ProjectBillingValidationError.invalidPersistedPlan
            }
            return cents
        }
        guard !targets.isEmpty, targets.count <= 8, targets.reduce(0, +) == gross - discount else {
            throw ProjectBillingValidationError.invalidPersistedPlan
        }
        let discounts = allocate(discount, weights: targets)
        let grossTargets = zip(targets, discounts).map(+)

        // A transportation matrix whose row and column margins are both exact.
        // Remaining balances, not the full source, fund each successive stage.
        var remaining = lineCents
        var centsByStage: [[Int64]] = []
        for target in grossTargets {
            let row = allocate(target, weights: remaining)
            remaining = zip(remaining, row).map(-)
            centsByStage.append(row)
        }
        guard remaining.allSatisfy({ $0 == 0 }) else {
            throw ProjectBillingValidationError.invalidPersistedPlan
        }

        let quantitiesByLeaf = try leaves.enumerated().map { index, line in
            try quantities(for: line, cents: centsByStage.map { $0[index] }, weights: targets)
        }
        var rows = Array(repeating: [CatalogLineItemSnapshot](), count: targets.count)
        var leafIndex = 0
        for root in source {
            if let bundle = root.bundle {
                let first = leafIndex
                leafIndex += bundle.members.count
                let membersByStage = targets.indices.map { stage in
                    bundle.members.enumerated().compactMap { offset, member -> CatalogBundleSnapshot.Member? in
                        let ticks = quantitiesByLeaf[first + offset][stage]
                        guard ticks > 0 else { return nil }
                        return .init(id: member.id, line: member.line.replacingQuantity(with: quantity(ticks)),
                                     tracksInventory: member.tracksInventory)
                    }
                }
                let activeStages = membersByStage.map { !$0.isEmpty }
                let rootTicks = try ticks(root.quantity)
                guard rootTicks >= Int64(activeStages.filter { $0 }.count) else {
                    throw ProjectBillingValidationError.allocationPrecision(root.name)
                }
                var headerQuantities = allocate(rootTicks,
                    weights: zip(targets, activeStages).map { $1 ? $0 : 0 })
                for stage in targets.indices where activeStages[stage] { headerQuantities[stage] = max(1, headerQuantities[stage]) }
                var excess = headerQuantities.reduce(0, +) - rootTicks
                for stage in targets.indices where activeStages[stage] && excess > 0 {
                    let correction = min(excess, headerQuantities[stage] - 1)
                    headerQuantities[stage] -= correction; excess -= correction
                }
                for stage in targets.indices where activeStages[stage] {
                    let allocated = root.replacingBundle(bundle.replacingMembers(membersByStage[stage]),
                        quantity: quantity(headerQuantities[stage]))
                    try CatalogBundlePolicy.validate(allocated)
                    rows[stage].append(allocated)
                }
            } else {
                for stage in targets.indices where quantitiesByLeaf[leafIndex][stage] > 0 {
                    rows[stage].append(root.replacingQuantity(with: quantity(quantitiesByLeaf[leafIndex][stage])))
                }
                leafIndex += 1
            }
        }
        return try targets.indices.map { stage in
            let allocatedDiscount: AuthorizedDocumentDiscount?
            if discounts[stage] > 0, let originalDiscount {
                allocatedDiscount = .init(kind: .fixedAmount, value: amount(discounts[stage]),
                    grossSubtotalAtAuthorization: amount(grossTargets[stage]), reason: originalDiscount.reason,
                    authorizedByEmail: originalDiscount.authorizedByEmail, authorizedAt: originalDiscount.authorizedAt)
            } else { allocatedDiscount = nil }
            let count = rows[stage].reduce(0) { $0 + ($1.bundle.map { 1 + $0.members.count } ?? 1) }
            guard count + (allocatedDiscount == nil ? 0 : 1) <= 750,
                  let encoded = CatalogLineItemSnapshot.encoded(snapshots: rows[stage], documentDiscount: allocatedDiscount),
                  exactCents(BillingDocumentDiscountPolicy.netSubtotal(snapshotJSON: encoded) ?? -1) == targets[stage] else {
                throw ProjectBillingValidationError.invalidPersistedPlan
            }
            if let addresses = BillingTaxAddressContext.read(json) {
                return try BillingTaxAddressContext.attaching(addresses, to: encoded)
            }
            return encoded
        }
    }

    /// Integer bounds avoid unrepresentable repeating Double quantities. Within
    /// each cent's rounding interval choose quantities near the proportional
    /// share, then conserve the original exact quantity across all stages.
    private static func quantities(for line: CatalogLineItemSnapshot, cents: [Int64], weights: [Int64]) throws -> [Int64] {
        let total = try ticks(line.quantity)
        guard let price = QuickBooksSalesLineContract.decimal(line.unitPrice, places: 5) else {
            throw ProjectBillingValidationError.missingCatalogSnapshot
        }
        if price == 0 { return allocate(total, weights: weights) }
        func value(_ ticks: Int64) -> Decimal {
            QuickBooksSalesLineContract.rounded(Decimal(ticks) / scale * price) * 100
        }
        func lowerBound(_ target: Int64, strictly: Bool) -> Int64 {
            var lower: Int64 = 0, upper = total + 1
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if value(middle) > Decimal(target) || (!strictly && value(middle) == Decimal(target)) {
                    upper = middle
                } else { lower = middle + 1 }
            }
            return lower
        }
        let lower = cents.map { lowerBound($0, strictly: false) }
        let upper = cents.map { min(total, lowerBound($0, strictly: true) - 1) }
        guard zip(lower, upper).allSatisfy({ $0 <= $1 }),
              lower.reduce(0, +) <= total, upper.reduce(0, +) >= total else {
            throw ProjectBillingValidationError.allocationPrecision(line.name)
        }
        let preferred = allocate(total, weights: cents.contains(where: { $0 > 0 }) ? cents : weights)
        var result = preferred.indices.map { min(max(preferred[$0], lower[$0]), upper[$0]) }
        var residual = total - result.reduce(0, +)
        for index in result.indices {
            let change = residual > 0 ? min(residual, upper[index] - result[index])
                : -min(-residual, result[index] - lower[index])
            result[index] += change
            residual -= change
        }
        guard residual == 0, zip(result, cents).allSatisfy({ value($0) == Decimal($1) }) else {
            throw ProjectBillingValidationError.allocationPrecision(line.name)
        }
        return result
    }

    /// Decimal largest-remainder apportionment, stable source-order ties.
    private static func allocate(_ total: Int64, weights: [Int64]) -> [Int64] {
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return weights.map { _ in 0 } }
        let exact = weights.map { Decimal(total) * Decimal($0) / Decimal(sum) }
        // NSDecimalNumber.int64Value can return zero for a Decimal with a
        // 38-digit repeating fractional coefficient on this Foundation build.
        // Remove the fraction in Decimal before converting its bounded integer.
        var result = exact.map { value -> Int64 in
            var value = value, integral = Decimal.zero
            NSDecimalRound(&integral, &value, 0, .down)
            return NSDecimalNumber(decimal: integral).int64Value
        }
        let priority = exact.indices.sorted {
            let lhs = exact[$0] - Decimal(result[$0]), rhs = exact[$1] - Decimal(result[$1])
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        var remaining = total - result.reduce(0, +)
        for index in priority where remaining > 0 { result[index] += 1; remaining -= 1 }
        return result
    }

    private static func ticks(_ value: Double) throws -> Int64 {
        guard let decimal = QuickBooksSalesLineContract.decimal(value, places: 5, maximum: 999_999), decimal > 0 else {
            throw ProjectBillingValidationError.missingCatalogSnapshot
        }
        return NSDecimalNumber(decimal: decimal * scale).int64Value
    }
    private static func quantity(_ ticks: Int64) -> Double { QuickBooksSalesLineContract.double(Decimal(ticks) / scale) }
    private static func amount(_ cents: Int64) -> Double { QuickBooksSalesLineContract.double(Decimal(cents) / 100) }
    static func exactCents(_ value: Double) -> Int64? {
        QuickBooksSalesLineContract.decimal(value, places: 2).map { NSDecimalNumber(decimal: $0 * 100).int64Value }
    }
}
