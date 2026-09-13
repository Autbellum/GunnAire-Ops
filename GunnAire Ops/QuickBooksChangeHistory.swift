import Foundation
import CryptoKit

enum QuickBooksChangeHistoryError: Error, LocalizedError, Equatable {
    case access, changed, invalid, incomplete, lifecycleReview, unavailable, limit

    var errorDescription: String? {
        switch self {
        case .access: "Reopen QuickBooks with the original business administrator account."
        case .changed: "The accounting connection or saved history changed. Refresh again before applying it."
        case .invalid: "The accounting history could not be verified. Saved work has been kept."
        case .incomplete: "QuickBooks history is not complete yet. Refresh again; if this continues, check Shared Server Readiness."
        case .lifecycleReview: "QuickBooks has deleted or conflicting records that need reconciliation. Saved work and change alerts have been kept."
        case .unavailable: "Shared accounting history is unavailable. Check the server connection and version in Shared Server Readiness."
        case .limit: "This accounting history needs a larger, staged transfer. No partial collection was applied."
        }
    }

    static func safe(_ error: Error) -> Self {
        if let own = error as? Self { return own }
        if error is WorkspaceProviderAccessError || error is CompanyWorkspaceFailure { return .access }
        if error is DecodingError { return .invalid }
        if case GunnAireBackendError.server(let status, _) = error {
            if status == 401 || status == 403 { return .access }
            if status == 409 { return .changed }
            if status == 400 { return .invalid }
        }
        return .unavailable
    }
}

enum QuickBooksChangeEntity: String, Codable, CaseIterable {
    case account = "Account", bill = "Bill", customer = "Customer", deposit = "Deposit"
    case estimate = "Estimate", invoice = "Invoice", item = "Item", payment = "Payment"
    case paymentMethod = "PaymentMethod", purchase = "Purchase", salesReceipt = "SalesReceipt"
    case vendor = "Vendor", vendorCredit = "VendorCredit"

    var resourceID: String {
        switch self {
        case .item: "catalog"
        case .account: "accounts"
        case .bill: "bills"
        case .customer: "customers"
        case .deposit: "deposits"
        case .estimate: "estimates"
        case .invoice: "invoices"
        case .payment: "payments"
        case .paymentMethod: "paymentMethods"
        case .purchase: "purchases"
        case .salesReceipt: "salesReceipts"
        case .vendor: "vendors"
        case .vendorCredit: "vendorCredits"
        }
    }

    init?(resourceID: String) {
        guard let entity = Self.allCases.first(where: { $0.resourceID == resourceID }) else { return nil }
        self = entity
    }
}

struct QuickBooksChangeHistoryScope: Codable, Equatable {
    let companyID: UUID
    let realmID: String
    let environment: String

    func validate() throws {
        guard Self.validReference(realmID), ["sandbox", "production"].contains(environment)
        else { throw QuickBooksChangeHistoryError.invalid }
    }

    nonisolated static func validReference(_ value: String) -> Bool {
        QuickBooksProviderReference.isValid(value)
    }

    nonisolated static func validDigest(_ value: String) -> Bool {
        value.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil
    }
}

/// Compare provider time, not arrival order. Preserve microseconds: Foundation's
/// ISO8601 Date formatter can discard fractional precision when parsing.
struct QuickBooksHistoryTimestamp: Equatable, Comparable {
    let seconds: Int64
    let microseconds: Int

    init(_ value: String) throws {
        let pattern = #"\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})\z"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let base = Range(match.range(at: 1), in: value),
              let zone = Range(match.range(at: 3), in: value) else { throw QuickBooksChangeHistoryError.invalid }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        guard let date = formatter.date(from: String(value[base]) + String(value[zone]))
        else { throw QuickBooksChangeHistoryError.invalid }
        let fraction = Range(match.range(at: 2), in: value).map { String(value[$0]) } ?? ""
        seconds = Int64(date.timeIntervalSince1970.rounded())
        microseconds = Int(fraction + String(repeating: "0", count: 6 - fraction.count)) ?? 0
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.seconds == rhs.seconds ? lhs.microseconds < rhs.microseconds : lhs.seconds < rhs.seconds
    }
}

struct QuickBooksHistoryVersion: Decodable {
    let sequence: Int
    let entityID: String
    let updatedAt: String
    let status: String
    let recordJSON: String
    let payloadSHA256: String

    private struct Identity: Decodable {
        struct Metadata: Decodable { let LastUpdatedTime: String }
        let Id: String
        let SyncToken: String?
        let MetaData: Metadata
        let sparse: Bool?
        let status: String?
    }

    private struct FiniteAmount: Decodable {
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if (try? value.decode(Bool.self)) != nil { throw QuickBooksChangeHistoryError.invalid }
            let number = (try? value.decode(Double.self)) ?? (try? value.decode(String.self)).flatMap(Double.init)
            guard number?.isFinite == true else { throw QuickBooksChangeHistoryError.invalid }
        }
    }
    private struct FinancialHeader: Decodable { let TotalAmt: FiniteAmount }
    private struct PaymentAllocations: Decodable {
        struct LineAmount: Decodable { let Amount: FiniteAmount }
        let Line: [LineAmount]?
    }

    func validateProjection(for entity: QuickBooksChangeEntity) throws {
        let raw = Data(recordJSON.utf8)
        // Some legacy display decoders default a missing amount to zero. A
        // shared accounting snapshot must not turn missing financial evidence
        // into a real zero-dollar bill, payment or allocation.
        if [.bill, .deposit, .estimate, .invoice, .payment, .purchase, .salesReceipt, .vendorCredit].contains(entity) {
            _ = try JSONDecoder().decode(FinancialHeader.self, from: raw)
        }
        if entity == .payment { _ = try JSONDecoder().decode(PaymentAllocations.self, from: raw) }
    }

    func validate() throws -> QuickBooksHistoryTimestamp {
        guard sequence > 0, QuickBooksChangeHistoryScope.validReference(entityID),
              ["present", "deleted"].contains(status),
              QuickBooksChangeHistoryScope.validDigest(payloadSHA256)
        else { throw QuickBooksChangeHistoryError.invalid }
        let raw = Data(recordJSON.utf8)
        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        guard digest == payloadSHA256 else { throw QuickBooksChangeHistoryError.invalid }
        let identity = try JSONDecoder().decode(Identity.self, from: raw)
        let updated = try QuickBooksHistoryTimestamp(updatedAt)
        guard identity.Id == entityID, identity.sparse != true,
              try QuickBooksHistoryTimestamp(identity.MetaData.LastUpdatedTime) == updated,
              status == "deleted" ? identity.status == "Deleted" :
                (identity.status == nil && identity.SyncToken.map(QuickBooksChangeHistoryScope.validReference) == true)
        else { throw QuickBooksChangeHistoryError.invalid }
        return updated
    }
}

struct QuickBooksHistoryPage: Decodable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let entityType: QuickBooksChangeEntity
    let connectionRevision: String
    let revision: Int
    let capturedThrough: String?
    let baselineAt: String?
    let issueCode: String?
    let legacyEventsNeedingReview: Int
    let applicationState: String
    let versions: [QuickBooksHistoryVersion]
    let versionCount: Int
    let afterSequence: Int
    let throughSequence: Int
    let nextAfterSequence: Int?

    var metadataOnly: Self {
        .init(companyID: companyID, realmID: realmID, environment: environment, entityType: entityType,
              connectionRevision: connectionRevision, revision: revision, capturedThrough: capturedThrough,
              baselineAt: baselineAt, issueCode: issueCode, legacyEventsNeedingReview: legacyEventsNeedingReview,
              applicationState: applicationState, versions: [], versionCount: versionCount,
              afterSequence: afterSequence, throughSequence: throughSequence, nextAfterSequence: nextAfterSequence)
    }

    func validate(scope: QuickBooksChangeHistoryScope, entity: QuickBooksChangeEntity,
                  connection: String?, after: Int, original: QuickBooksHistoryPage?) throws {
        guard companyID == scope.companyID, realmID == scope.realmID, environment == scope.environment,
              entityType == entity, QuickBooksChangeHistoryScope.validDigest(connectionRevision),
              connection == nil || connection == connectionRevision
        else { throw QuickBooksChangeHistoryError.changed }
        guard revision > 0, applicationState == "not_applied", versionCount >= 0,
              legacyEventsNeedingReview >= 0, afterSequence == after, after >= 0,
              throughSequence >= after, versions.count <= 50,
              (versionCount == 0) == (throughSequence == 0)
        else { throw QuickBooksChangeHistoryError.invalid }
        guard let capturedThrough, let baselineAt, issueCode == nil, legacyEventsNeedingReview == 0
        else { throw QuickBooksChangeHistoryError.incomplete }
        _ = try QuickBooksHistoryTimestamp(capturedThrough)
        _ = try QuickBooksHistoryTimestamp(baselineAt)
        if let original {
            guard revision == original.revision, capturedThrough == original.capturedThrough,
                  baselineAt == original.baselineAt, throughSequence == original.throughSequence,
                  versionCount == original.versionCount else { throw QuickBooksChangeHistoryError.changed }
        }
        var preceding = after
        for version in versions {
            guard version.sequence > preceding, version.sequence <= throughSequence
            else { throw QuickBooksChangeHistoryError.invalid }
            preceding = version.sequence
        }
        if let nextAfterSequence {
            guard nextAfterSequence == versions.last?.sequence, nextAfterSequence > after,
                  nextAfterSequence < throughSequence else { throw QuickBooksChangeHistoryError.invalid }
        } else {
            // Sequence numbers can have gaps belonging to other collections.
            // A complete page must still end at this collection's pinned max.
            guard (versions.last?.sequence ?? after) == throughSequence
            else { throw QuickBooksChangeHistoryError.invalid }
        }
    }
}

/// A full observation-history projection, not an applied-event receipt. The
/// server retains the canonical versions; no raw customer/accounting history is
/// written to UserDefaults or a device cache. Every refresh reads from zero, so
/// late arrivals cannot be skipped by a premature local consumption cursor.
@MainActor final class QuickBooksChangeHistoryClient {
    typealias Request = (String, String, Data?) async throws -> Data
    static let maximumPageBytes = 16 * 1024 * 1024
    static let maximumHistoryBytes = 64 * 1024 * 1024
    let scope: QuickBooksChangeHistoryScope
    private let checkAccess: () throws -> Void
    private let transport: Request
    private(set) var connectionRevision: String?
    private var proofs: [QuickBooksChangeEntity: QuickBooksHistoryPage] = [:]
    private var catalogBatch: QuickBooksCatalogHistoryBatch?

    init(scope: QuickBooksChangeHistoryScope, check: @escaping () throws -> Void,
         request: @escaping Request) throws {
        try scope.validate(); try check()
        self.scope = scope; checkAccess = check; transport = request
    }

    func check() throws { try checkAccess(); try Task.checkCancellation() }

    private func request(entity: QuickBooksChangeEntity, original: QuickBooksHistoryPage? = nil,
                         after: Int = 0) async throws -> QuickBooksHistoryPage {
        try check()
        var payload = ["companyID": scope.companyID.uuidString.lowercased(), "realmID": scope.realmID,
                       "environment": scope.environment, "entityType": entity.rawValue]
        if let connectionRevision { payload["connectionRevision"] = connectionRevision }
        let path: String, method: String, body: Data?
        if let original {
            payload["afterSequence"] = String(after)
            payload["throughSequence"] = String(original.throughSequence)
            payload["captureRevision"] = String(original.revision)
            var url = URLComponents()
            url.path = "/api/qbo/change-capture"
            url.queryItems = payload.keys.sorted().map { URLQueryItem(name: $0, value: payload[$0]) }
            guard let encoded = url.string else { throw QuickBooksChangeHistoryError.invalid }
            path = encoded; method = "GET"; body = nil
        } else {
            path = "/api/qbo/change-capture"; method = "POST"
            body = try JSONEncoder().encode(payload)
        }
        do {
            // This POST captures GET-only Intuit reads. It cannot publish an
            // accounting mutation and is not an application acknowledgement.
            let data = try await transport(path, method, body)
            try check()
            guard data.count <= Self.maximumPageBytes else { throw QuickBooksChangeHistoryError.limit }
            let page = try JSONDecoder().decode(QuickBooksHistoryPage.self, from: data)
            try page.validate(scope: scope, entity: entity, connection: connectionRevision, after: after, original: original)
            connectionRevision = page.connectionRevision
            return page
        } catch {
            try check()
            throw QuickBooksChangeHistoryError.safe(error)
        }
    }

    func records<T: Decodable>(entity: QuickBooksChangeEntity, as type: T.Type = T.self) async throws -> [T] {
        proofs.removeValue(forKey: entity)
        if entity == .item { catalogBatch = nil }
        let first = try await request(entity: entity)
        var page = first
        var latest: [String: (QuickBooksHistoryVersion, QuickBooksHistoryTimestamp, Bool)] = [:]
        var count = 0, bytes = 0
        while true {
            try check()
            for version in page.versions {
                bytes += version.recordJSON.utf8.count
                guard bytes <= Self.maximumHistoryBytes, count < 100_000 else { throw QuickBooksChangeHistoryError.limit }
                let updated: QuickBooksHistoryTimestamp
                do { updated = try version.validate() }
                catch { throw QuickBooksChangeHistoryError.safe(error) }
                count += 1
                if let prior = latest[version.entityID] {
                    if updated > prior.1 { latest[version.entityID] = (version, updated, false) }
                    else if updated == prior.1 && version.payloadSHA256 != prior.0.payloadSHA256 {
                        latest[version.entityID] = (prior.0, prior.1, true)
                    }
                } else { latest[version.entityID] = (version, updated, false) }
            }
            guard count <= first.versionCount else { throw QuickBooksChangeHistoryError.invalid }
            guard let after = page.nextAfterSequence else { break }
            page = try await request(entity: entity, original: first, after: after)
        }
        guard count == first.versionCount else { throw QuickBooksChangeHistoryError.invalid }
        // Deletion/merge/void/reallocation application needs its own durable
        // model receipt. Never convert tombstones into an empty successful list.
        guard latest.values.allSatisfy({ $0.0.status == "present" && !$0.2 })
        else { throw QuickBooksChangeHistoryError.lifecycleReview }
        let records: [T]
        do {
            records = try latest.keys.sorted().map { key in
                guard let version = latest[key]?.0 else { throw QuickBooksChangeHistoryError.invalid }
                try version.validateProjection(for: entity)
                return try JSONDecoder().decode(T.self, from: Data(version.recordJSON.utf8))
            }
        } catch { throw QuickBooksChangeHistoryError.safe(error) }
        // An empty final read rechecks the server session, role, grant and
        // collection revision before even exposing this collection to the UI.
        _ = try await request(entity: entity, original: first, after: first.throughSequence)
        try check()
        if entity == .item {
            catalogBatch = try QuickBooksCatalogHistoryBatch(scope: scope,
                connectionRevision: first.connectionRevision, versions: latest.values.map { $0.0 })
        }
        proofs[entity] = first.metadataOnly
        return records
    }

    func catalogHistory() throws -> QuickBooksCatalogHistoryBatch {
        try check()
        guard proofs[.item] != nil, let catalogBatch else { throw QuickBooksChangeHistoryError.incomplete }
        return catalogBatch
    }

    func revalidate(_ entities: Set<QuickBooksChangeEntity>) async throws {
        try check()
        guard entities.allSatisfy({ proofs[$0] != nil }) else { throw QuickBooksChangeHistoryError.incomplete }
        for entity in entities.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let proof = proofs[entity] else { throw QuickBooksChangeHistoryError.incomplete }
            _ = try await request(entity: entity, original: proof, after: proof.throughSequence)
        }
        try check()
    }
}
