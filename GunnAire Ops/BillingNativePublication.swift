import Foundation
import CryptoKit

struct BillingNativeContext: Decodable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let documentType: BillingPublicationDocumentKind
    let localDocumentID: UUID
    let localCustomerID: UUID
    let serviceCallID: UUID?
    let connectionRevision: String
    let customerProviderID: String
    let providerID: String?
    let authority: String
    let assignment: JobBillingAssignment?
    let syncToken: String?
    let invoice: QuickBooksInvoice?
    let estimate: QuickBooksEstimate?

    private enum CodingKeys: String, CodingKey {
        case companyID, realmID, environment, documentType, localDocumentID, localCustomerID, serviceCallID
        case connectionRevision, customerProviderID, providerID, authority, assignment, document
    }
    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        companyID = try v.decode(UUID.self, forKey: .companyID)
        realmID = try v.decode(String.self, forKey: .realmID)
        environment = try v.decode(String.self, forKey: .environment)
        documentType = try v.decode(BillingPublicationDocumentKind.self, forKey: .documentType)
        localDocumentID = try v.decode(UUID.self, forKey: .localDocumentID)
        localCustomerID = try v.decode(UUID.self, forKey: .localCustomerID)
        serviceCallID = try v.decodeIfPresent(UUID.self, forKey: .serviceCallID)
        connectionRevision = try v.decode(String.self, forKey: .connectionRevision)
        customerProviderID = try v.decode(String.self, forKey: .customerProviderID)
        providerID = try v.decodeIfPresent(String.self, forKey: .providerID)
        authority = try v.decode(String.self, forKey: .authority)
        assignment = try v.decodeIfPresent(JobBillingAssignment.self, forKey: .assignment)
        struct Version: Decodable { let SyncToken: String? }
        syncToken = try v.decodeIfPresent(Version.self, forKey: .document)?.SyncToken
        switch documentType {
        case .invoice: invoice = try v.decodeIfPresent(QuickBooksInvoice.self, forKey: .document); estimate = nil
        case .estimate: estimate = try v.decodeIfPresent(QuickBooksEstimate.self, forKey: .document); invoice = nil
        }
    }

    func validate(_ scope: BillingDocumentScope, customerID: UUID, jobID: UUID?) throws {
        guard companyID == scope.companyID, realmID == scope.realmID, environment == scope.environment,
              documentType == scope.documentType, localDocumentID == scope.localDocumentID,
              localCustomerID == customerID, serviceCallID == jobID,
              JobBillingAssignmentSnapshot.validConnectionRevision(connectionRevision),
              !customerProviderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["office", "assigned"].contains(authority) else { throw BillingPublicationError.invalidResponse }
        if let assignment {
            guard let jobID else { throw BillingPublicationError.invalidResponse }
            try assignment.validate(.init(companyID: companyID, realmID: realmID, environment: environment, serviceCallID: jobID), customerID: customerID)
        }
        if authority == "assigned", assignment?.usable != true { throw BillingPublicationError.invalidResponse }
        guard let providerID else {
            guard invoice == nil, estimate == nil else { throw BillingPublicationError.invalidResponse }
            return
        }
        let id = invoice?.Id ?? estimate?.Id
        let ref = invoice?.CustomerRef.value ?? estimate?.CustomerRef.value
        let token = syncToken
        let date = invoice?.TxnDate ?? estimate?.TxnDate
        guard !providerID.isEmpty, id == providerID, ref == customerProviderID, token?.isEmpty == false,
              let date, date.count == 10,
              QuickBooksDateOnly.date(from: date).map({ QuickBooksDateOnly.string(from: $0) == date }) == true,
              let lines = invoice?.Line ?? estimate?.Line, !lines.isEmpty, lines.count <= 750,
              let total = invoice?.TotalAmt ?? estimate?.TotalAmt,
              let tax = invoice?.TxnTaxDetail?.TotalTax ?? estimate?.TxnTaxDetail?.TotalTax,
              let totalMoney = BillingPublicationResponse.money(total), let taxMoney = BillingPublicationResponse.money(tax) else {
            throw BillingPublicationError.invalidResponse
        }
        var sold = Decimal.zero
        for line in lines {
            guard line.hasExplicitAmount, let amount = BillingPublicationResponse.money(line.Amount),
                  ["SalesItemLineDetail", "DiscountLineDetail"].contains(line.DetailType) else { throw BillingPublicationError.invalidResponse }
            sold += line.DetailType == "DiscountLineDetail" ? -amount : amount
        }
        guard sold >= 0, sold + taxMoney == totalMoney else { throw BillingPublicationError.invalidResponse }
        if let invoice {
            guard let balance = invoice.Balance, BillingPublicationResponse.money(balance) != nil, balance <= total else {
                throw BillingPublicationError.invalidResponse
            }
        }
    }
}

struct BillingOriginalProposal: Decodable {
    let publication: BillingPublicationRecord
    let proposal: BillingPublicationRequest
    var reviewableByOffice: Bool? = nil
    var connectionChanged: Bool? = nil
}

extension BillingPublicationRequest {
    /// Compare the normalized server intent, not cosmetic reference names or
    /// UUID casing. No sold amounts, notes, dates or assignment revisions are
    /// excluded from this equality check.
    func canonicalData() throws -> Data {
        func normalize(_ value: Any, key: String? = nil) -> Any {
            if var object = value as? [String: Any] {
                if object["value"] != nil { object.removeValue(forKey: "name") }
                if object["Description"] as? String == "" { object.removeValue(forKey: "Description") }
                return object.reduce(into: [String: Any]()) { result, pair in
                    result[pair.key] = normalize(pair.value, key: pair.key)
                }
            }
            if let values = value as? [Any] { return values.map { normalize($0) } }
            if let text = value as? String, ["companyID", "localDocumentID", "localCustomerID", "serviceCallID"].contains(key ?? "") {
                return text.lowercased()
            }
            return value
        }
        return try JSONSerialization.data(withJSONObject: normalize(JSONSerialization.jsonObject(with: JSONEncoder().encode(self))), options: [.sortedKeys])
    }
    func matches(_ other: Self) throws -> Bool { try canonicalData() == other.canonicalData() }
}

enum BillingNativeError: LocalizedError, Equatable {
    case storage, originalDraft, pending, connection, mapping
    var errorDescription: String? {
        switch self {
        case .storage: "The original billing request could not be saved or verified on this device. Your draft was retained; no replacement request was sent."
        case .originalDraft: "This draft changed after its original QuickBooks request. Open Billing Review to check that request before publishing changes."
        case .pending: "Open Billing Review to recover or review the original request. No replacement invoice or estimate was sent."
        case .connection: "The QuickBooks connection changed. Keep the original request for office review."
        case .mapping: "The saved QuickBooks link does not match the shared business record. An administrator can review Existing Links in QuickBooks settings."
        }
    }
}

struct BillingNativeJournalScope: Codable, Equatable {
    let document: BillingDocumentScope
    let actorEmail: String
    var key: String {
        SHA256.hash(data: Data([document.companyID.uuidString.lowercased(), document.realmID, document.environment,
            document.documentType.rawValue, document.localDocumentID.uuidString.lowercased(), actorEmail].joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    func validate() throws {
        guard !document.realmID.isEmpty, !document.realmID.contains("\n"), document.realmID.count <= 128,
              ["sandbox", "production"].contains(document.environment), actorEmail == AppAccess.normalizedEmail(actorEmail),
              actorEmail.contains("@"), !actorEmail.contains("\n") else { throw BillingNativeError.storage }
    }
}

struct BillingNativePending: Codable {
    let request: BillingPublicationRequest
    var draftRevision: String
    var submitted = false
    var publicationID: UUID?
    var settled = false
}

struct BillingNativeJournal: Codable {
    var version = 1
    let scope: BillingNativeJournalScope
    var pending: BillingNativePending?
    func validate(_ expected: BillingNativeJournalScope) throws {
        try expected.validate()
        guard version == 1, scope == expected else { throw BillingNativeError.storage }
        if let pending {
            try pending.request.validate()
            guard pending.request.scope == scope.document,
                  JobBillingAssignmentSnapshot.validConnectionRevision(pending.draftRevision),
                  !pending.settled || (pending.submitted && pending.publicationID != nil) else { throw BillingNativeError.storage }
        }
    }
}

struct BillingNativeJournalStore {
    let read: (BillingNativeJournalScope) throws -> BillingNativeJournal
    let write: (BillingNativeJournal) throws -> Void

    static func encrypted(directory: URL, key: @escaping (Bool) throws -> Data) -> Self {
        func file(_ scope: BillingNativeJournalScope) -> URL { directory.appendingPathComponent(scope.key + ".sealed") }
        return .init(read: { scope in
            do {
                try scope.validate()
                let url = file(scope)
                guard FileManager.default.fileExists(atPath: url.path) else { return .init(scope: scope) }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1024 * 1024 else { throw BillingNativeError.storage }
                let data = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)),
                    using: SymmetricKey(data: key(false)), authenticating: Data(scope.key.utf8))
                let journal = try JSONDecoder().decode(BillingNativeJournal.self, from: data)
                try journal.validate(scope)
                return journal
            } catch { throw BillingNativeError.storage }
        }, write: { journal in
            do {
                try journal.validate(journal.scope)
                let data = try JSONEncoder().encode(journal)
                guard data.count < 1024 * 1024 - 64 else { throw BillingNativeError.storage }
                let sealed = try AES.GCM.seal(data, using: SymmetricKey(data: key(!FileManager.default.fileExists(atPath: file(journal.scope).path))),
                                            authenticating: Data(journal.scope.key.utf8))
                guard let combined = sealed.combined else { throw BillingNativeError.storage }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var folder = directory, values = URLResourceValues()
                values.isExcludedFromBackup = true
                try folder.setResourceValues(values)
                try combined.write(to: file(journal.scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { throw BillingNativeError.storage }
        })
    }

    static var device: Self {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .init(read: { _ in throw BillingNativeError.storage }, write: { _ in throw BillingNativeError.storage })
        }
        return encrypted(directory: root.appendingPathComponent("BillingOriginalProposals-v1", isDirectory: true)) { create in
            let account = "BillingOriginalProposalsEncryption-v1"
            if let data = try KeychainStore.loadCodable(Data.self, account: account) {
                guard data.count == 32 else { throw BillingNativeError.storage }
                return data
            }
            guard create else { throw BillingNativeError.storage }
            let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try KeychainStore.saveCodable(data, account: account)
            return data
        }
    }
}

/// One immutable proposal, persisted before POST. Automatic follow-up reads
/// the original attempt only. Only a separate, explicit review action may
/// resubmit the exact reserved proposal; unknown/sending attempts cannot send.
@MainActor
final class BillingNativePublication {
    let scope: BillingNativeJournalScope
    let client: BillingPublicationClient
    let workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow
    let store: BillingNativeJournalStore
    private let checkCurrent: () throws -> Void
    private(set) var journal: BillingNativeJournal

    init(scope: BillingNativeJournalScope, client: BillingPublicationClient,
         workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow, store: BillingNativeJournalStore,
         check: @escaping () throws -> Void) throws {
        try scope.document.validate(workflow)
        self.scope = scope; self.client = client; self.workflow = workflow; self.store = store
        checkCurrent = check
        journal = try store.read(scope)
        try journal.validate(scope)
        try check()
    }

    func check() throws { try workflow.check(); try checkCurrent() }
    private func save(_ value: BillingNativeJournal) throws {
        try check(); try store.write(value); journal = value
    }

    func original(customerID: UUID) async throws -> BillingOriginalProposal? {
        try check()
        if let id = journal.pending?.publicationID {
            return try await client.original(id, scope: scope.document, customerID: customerID, workflow: workflow)
        }
        var cursor: String?, seen = Set<String>()
        repeat {
            let page = try await client.list(scope.document, customerID: customerID, cursor: cursor, workflow: workflow)
            try check()
            for row in page.publications where row.state != .cancelled {
                if let pending = journal.pending {
                    let value = try await client.original(row.id, scope: scope.document, customerID: customerID, workflow: workflow)
                    if try value.proposal.matches(pending.request) {
                        var updated = journal; updated.pending?.publicationID = row.id
                        try save(updated)
                        return value
                    }
                    if [.reserved, .sending, .unknown].contains(row.state) { throw BillingNativeError.pending }
                } else {
                    return try await client.original(row.id, scope: scope.document, customerID: customerID, workflow: workflow)
                }
            }
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw BillingPublicationError.invalidResponse }
            guard seen.count < 100 else { throw BillingNativeError.pending }
        } while cursor != nil
        return nil
    }

    func prepare(_ request: BillingPublicationRequest, revision: String) throws {
        guard journal.pending == nil || journal.pending?.settled == true else { throw BillingNativeError.pending }
        var value = journal
        value.pending = .init(request: request, draftRevision: revision)
        try save(value)
    }

    func adoptOriginal(_ original: BillingOriginalProposal, revision: String) throws {
        guard journal.pending == nil, original.proposal.scope == scope.document,
              original.proposal.draftRevision == revision, original.publication.state != .cancelled else {
            throw BillingNativeError.originalDraft
        }
        var value = journal
        value.pending = .init(request: original.proposal, draftRevision: revision, submitted: true,
                              publicationID: original.publication.id)
        try save(value)
    }

    func submitOriginal() async throws -> BillingPublicationResponse {
        guard let pending = journal.pending, !pending.settled else { throw BillingNativeError.pending }
        if pending.submitted {
            if let original = try await original(customerID: pending.request.localCustomerID) {
                guard original.connectionChanged != true, original.publication.state == .reserved, try original.proposal.matches(pending.request) else {
                    throw BillingNativeError.pending
                }
            }
        }
        var attempted = journal; attempted.pending?.submitted = true
        try save(attempted) // before any transport suspension
        let result = try await client.publish(pending.request, workflow: workflow)
        try check()
        var confirmed = journal; confirmed.pending?.publicationID = result.publication.id
        try save(confirmed)
        return result
    }

    func recover(revision: String) async throws -> BillingPublicationResponse {
        guard let pending = journal.pending else { throw BillingNativeError.pending }
        guard pending.draftRevision == revision else { throw BillingNativeError.originalDraft }
        guard let original = try await original(customerID: pending.request.localCustomerID),
              try original.proposal.matches(pending.request),
              [.sending, .unknown, .confirmed].contains(original.publication.state) else { throw BillingNativeError.pending }
        let result = try await client.recover(original.publication.id, scope: scope.document,
            customerID: pending.request.localCustomerID, providerCustomerID: pending.request.document.CustomerRef.value, workflow: workflow)
        try check()
        let remoteLines = result.invoice?.Line ?? result.estimate?.Line
        guard result.publication.operation == pending.request.operation,
              pending.request.document.Id == nil || pending.request.document.Id == result.publication.providerID,
              QuickBooksBillingLineEvidence.matches(expected: pending.request.document.Line, reported: remoteLines),
              (result.invoice?.TxnDate ?? result.estimate?.TxnDate) == pending.request.document.TxnDate,
              pending.request.document.DueDate == nil || result.invoice?.DueDate == pending.request.document.DueDate else {
            throw BillingPublicationError.invalidResponse
        }
        return result
    }

    func settle(revision: String) throws {
        guard journal.pending?.publicationID != nil else { throw BillingNativeError.pending }
        var value = journal; value.pending?.settled = true; value.pending?.draftRevision = revision
        try save(value)
    }

    func cancelUnsent() async throws {
        guard let pending = journal.pending, !pending.settled else { throw BillingNativeError.pending }
        if pending.submitted {
            guard let original = try await original(customerID: pending.request.localCustomerID),
                  [.reserved, .cancelled].contains(original.publication.state), try original.proposal.matches(pending.request) else { throw BillingNativeError.pending }
            if original.publication.state == .reserved {
                _ = try await client.cancel(original.publication.id, scope: scope.document,
                    customerID: pending.request.localCustomerID, workflow: workflow)
            }
        }
        var value = journal; value.pending = nil
        try save(value)
    }
}
