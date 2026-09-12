import Foundation
import SwiftData

struct SharedTimeSource: Codable, Equatable {
    let id: UUID
    let workerEmail: String
    let clockIn: Date
    let clockOut: Date?
    let activity: String
    let notes: String?
    let serviceCallID: UUID?
    let customerID: UUID?
    let reviewStatus: String
    let reviewer: String?
    let reviewedAt: Date?
    let reviewNote: String?
    let reviewAudit: String?
    init(_ entry: TimeEntry, context: ModelContext) throws {
        let entries = try context.fetch(FetchDescriptor<TimeEntry>()).filter { $0.id == entry.id }
        guard entries.count == 1, entries.first === entry, !entry.isDeleted else { throw SharedTimeError.changed }
        if let call = entry.serviceCall {
            let calls = try context.fetch(FetchDescriptor<ServiceCall>()).filter { $0.id == call.id }
            guard calls.count == 1, calls.first === call, !call.isDeleted, let customer = call.customer else { throw SharedTimeError.changed }
            let customers = try context.fetch(FetchDescriptor<Customer>()).filter { $0.id == customer.id }
            guard customers.count == 1, customers.first === customer, !customer.isDeleted else { throw SharedTimeError.changed }
        }
        id = entry.id; workerEmail = AppAccess.normalizedEmail(entry.userEmail); clockIn = entry.clockIn; clockOut = entry.clockOut
        activity = entry.activity.rawValue; notes = entry.notes; serviceCallID = entry.serviceCall?.id; customerID = entry.serviceCall?.customer?.id
        reviewStatus = entry.reviewStatusRawValue; reviewer = entry.reviewedByEmail; reviewedAt = entry.reviewedAt
        reviewNote = entry.reviewNote; reviewAudit = entry.reviewAuditJSON
    }
    var revision: String {
        get throws { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return SharedTimeError.digest(try encoder.encode(self)) }
    }
}

struct SharedTimeRequest: Codable, Equatable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let connectionRevision: String
    let localEntryID: UUID
    let workerEmail: String
    let mappingRevision: Int
    let entryRevision: String
    let clockIn: String
    let clockOut: String
    let timeZone: String
    let payableMinutes: Int
    let activity: String
    let notes: String
    let serviceCallID: UUID?
    let localCustomerID: UUID?
    let localItemID: UUID?
    let reviewedByEmail: String
    let reviewedAt: String

    init(source: SharedTimeSource, connection: SharedTimeWorkerContext, itemID: UUID?, timeZone: TimeZone = .current) throws {
        try connection.validate(.init(companyID: connection.companyID, workerEmail: source.workerEmail))
        guard let end = source.clockOut, let reviewDate = source.reviewedAt, let reviewer = source.reviewer,
              source.clockIn.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
              reviewDate.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSince(source.clockIn) <= 8760 * 3600,
              source.reviewStatus == TimeEntryReviewStatus.approved.rawValue, source.clockIn < end, end <= reviewDate,
              let activity = TimeEntryActivity(rawValue: source.activity), activity.isQuickBooksPublishable else { throw SharedTimeError.approval }
        guard let mapping = connection.mapping, mapping.usable else { throw SharedTimeError.mapping }
        companyID = connection.companyID; realmID = connection.realmID; environment = connection.environment
        connectionRevision = connection.connectionRevision; localEntryID = source.id; workerEmail = source.workerEmail
        mappingRevision = mapping.revision; entryRevision = try source.revision
        clockIn = SharedTimeError.instant(source.clockIn); clockOut = SharedTimeError.instant(end); self.timeZone = timeZone.identifier
        payableMinutes = max(1, Int((end.timeIntervalSince(source.clockIn) / 60).rounded()))
        self.activity = source.activity; notes = source.notes ?? ""; serviceCallID = source.serviceCallID; localCustomerID = source.customerID
        localItemID = itemID; reviewedByEmail = AppAccess.normalizedEmail(reviewer); reviewedAt = SharedTimeError.instant(reviewDate)
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case companyID, realmID, environment, connectionRevision, localEntryID, workerEmail, mappingRevision, entryRevision
        case clockIn, clockOut, timeZone, payableMinutes, activity, notes, serviceCallID, localCustomerID, localItemID, reviewedByEmail, reviewedAt
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(companyID, forKey: .companyID); try c.encode(realmID, forKey: .realmID); try c.encode(environment, forKey: .environment)
        try c.encode(connectionRevision, forKey: .connectionRevision); try c.encode(localEntryID, forKey: .localEntryID)
        try c.encode(workerEmail, forKey: .workerEmail); try c.encode(mappingRevision, forKey: .mappingRevision)
        try c.encode(entryRevision, forKey: .entryRevision); try c.encode(clockIn, forKey: .clockIn); try c.encode(clockOut, forKey: .clockOut)
        try c.encode(timeZone, forKey: .timeZone); try c.encode(payableMinutes, forKey: .payableMinutes)
        try c.encode(activity, forKey: .activity); try c.encode(notes, forKey: .notes)
        try c.encode(serviceCallID, forKey: .serviceCallID); try c.encode(localCustomerID, forKey: .localCustomerID); try c.encode(localItemID, forKey: .localItemID)
        try c.encode(reviewedByEmail, forKey: .reviewedByEmail); try c.encode(reviewedAt, forKey: .reviewedAt)
    }
    func validate() throws {
        guard PaymentAttemptRecord.isReference(realmID), ["sandbox", "production"].contains(environment),
              JobBillingAssignmentSnapshot.validConnectionRevision(connectionRevision), JobBillingAssignmentSnapshot.validConnectionRevision(entryRevision),
              SharedTimeError.validEmail(workerEmail), SharedTimeError.validEmail(reviewedByEmail), (1...2_147_483_647).contains(mappingRevision),
              let start = SharedTimeError.date(clockIn), let end = SharedTimeError.date(clockOut), let review = SharedTimeError.date(reviewedAt),
              start < end, end <= review, end.timeIntervalSince(start) <= 8760 * 3600,
              payableMinutes == max(1, Int((end.timeIntervalSince(start) / 60).rounded())), (1...525600).contains(payableMinutes),
              timeZone.count <= 100, TimeZone(identifier: timeZone) != nil, TimeEntryActivity(rawValue: activity)?.isQuickBooksPublishable == true,
              (serviceCallID == nil) == (localCustomerID == nil), activity != "job" || serviceCallID != nil,
              notes.unicodeScalars.count <= 3000, !notes.uppercased().contains("GUNNAIRE-TIME"),
              notes.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 || $0 == "\n" || $0 == "\t" }) else { throw SharedTimeError.invalid }
    }
}

struct SharedTimeReference: Codable, Equatable { let value: String }
struct SharedTimeDocument: Codable, Equatable {
    let TxnDate: String
    let NameOf: String
    let EmployeeRef: SharedTimeReference?
    let VendorRef: SharedTimeReference?
    let CustomerRef: SharedTimeReference?
    let ItemRef: SharedTimeReference?
    let Hours: Int
    let Minutes: Int
    let Description: String
}
struct SharedTimeReceipt: Codable, Equatable {
    let providerID: String
    let syncToken: String
    let confirmedAt: String
    let legacyAdoption: Bool
}
struct SharedTimePublication: Codable, Equatable, Identifiable {
    let id: UUID
    let companyID: UUID
    let realmID: String
    let environment: String
    let localEntryID: UUID
    let workerEmail: String
    let state: String
    let entryRevision: String
    let reviewHash: String
    let preparedByEmail: String
    let review: SharedTimeRequest
    let worker: SharedTimeWorkerMapping
    let timeActivity: SharedTimeDocument
    let receipt: SharedTimeReceipt?
    let createdAt: String
    let updatedAt: String
    let expiresAt: String

    func validate(company: UUID, entry: UUID) throws {
        try review.validate()
        try worker.validate(.init(companyID: company, workerEmail: workerEmail), realmID: realmID, environment: environment)
        guard companyID == company, localEntryID == entry, review.companyID == company, review.localEntryID == entry,
              realmID == review.realmID, environment == review.environment, entryRevision == review.entryRevision,
              workerEmail == review.workerEmail, worker.revision == review.mappingRevision, SharedTimeError.validEmail(preparedByEmail),
              JobBillingAssignmentSnapshot.validConnectionRevision(reviewHash), ["reserved", "sending", "unknown", "confirmed", "cancelled"].contains(state),
              SharedTimeError.date(createdAt) != nil, SharedTimeError.date(updatedAt) != nil, SharedTimeError.date(expiresAt) != nil,
              (state == "confirmed") == (receipt != nil), timeActivity.NameOf == worker.kind,
              timeActivity.Hours == review.payableMinutes / 60, timeActivity.Minutes == review.payableMinutes % 60,
              (worker.kind == "Employee" ? timeActivity.EmployeeRef?.value : timeActivity.VendorRef?.value) == worker.providerID,
              (worker.kind == "Employee" ? timeActivity.VendorRef == nil : timeActivity.EmployeeRef == nil),
              (timeActivity.CustomerRef == nil) == (review.localCustomerID == nil), (timeActivity.ItemRef == nil) == (review.localItemID == nil),
              timeActivity.Description.unicodeScalars.count <= 4000,
              timeActivity.Description.split(separator: "\n").contains(Substring("GUNNAIRE-TIME:" + entry.uuidString.uppercased())),
              timeActivity.Description.split(separator: "\n").contains(Substring("GUNNAIRE-TIME-PUBLICATION:" + id.uuidString.uppercased())) else { throw SharedTimeError.invalid }
        let expectedDescription = ["Activity: " + (TimeEntryActivity(rawValue: review.activity)?.displayName ?? ""), review.notes,
            "Clocked " + review.clockIn + " - " + review.clockOut,
            "GUNNAIRE-TIME:" + entry.uuidString.uppercased(), "GUNNAIRE-TIME-PUBLICATION:" + id.uuidString.uppercased()]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        guard timeActivity.Description == expectedDescription else { throw SharedTimeError.invalid }
        for ref in [timeActivity.CustomerRef, timeActivity.ItemRef].compactMap({ $0 }) {
            guard PaymentAttemptRecord.isReference(ref.value) else { throw SharedTimeError.invalid }
        }
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: review.timeZone); formatter.dateFormat = "yyyy-MM-dd"
        guard let start = SharedTimeError.date(review.clockIn), formatter.string(from: start) == timeActivity.TxnDate else { throw SharedTimeError.invalid }
        if let receipt {
            guard PaymentAttemptRecord.isReference(receipt.providerID), PaymentAttemptRecord.isReference(receipt.syncToken),
                  SharedTimeError.date(receipt.confirmedAt) != nil else { throw SharedTimeError.invalid }
        }
    }

    /// A server read can advance state, but cannot replace the reviewed worker,
    /// references, receipt or intent while reusing an old review hash.
    func validateSuccessor(of original: Self) throws {
        guard id == original.id, companyID == original.companyID, realmID == original.realmID,
              environment == original.environment, localEntryID == original.localEntryID,
              workerEmail == original.workerEmail, review == original.review, worker == original.worker,
              timeActivity == original.timeActivity, reviewHash == original.reviewHash,
              preparedByEmail == original.preparedByEmail, createdAt == original.createdAt, expiresAt == original.expiresAt,
              original.receipt == nil || receipt == original.receipt else { throw SharedTimeError.invalid }
        let allowed: [String: Set<String>] = [
            "reserved": ["reserved", "sending", "unknown", "confirmed", "cancelled"],
            "sending": ["sending", "unknown", "confirmed"], "unknown": ["unknown", "confirmed"],
            "confirmed": ["confirmed"], "cancelled": ["cancelled"]]
        guard allowed[original.state]?.contains(state) == true else { throw SharedTimeError.invalid }
    }
}
struct SharedTimeLegacyCandidate: Codable, Equatable {
    let providerID: String
    let syncToken: String
    let description: String
    let candidateRevision: String
}
struct SharedTimeResponse: Codable {
    let publication: SharedTimePublication
    let legacyCandidate: SharedTimeLegacyCandidate?
    let needsLegacyReview: Bool?
    func validate(company: UUID, entry: UUID) throws {
        try publication.validate(company: company, entry: entry)
        guard (needsLegacyReview == true) == (legacyCandidate != nil) else { throw SharedTimeError.invalid }
        if let candidate = legacyCandidate {
            guard PaymentAttemptRecord.isReference(candidate.providerID), PaymentAttemptRecord.isReference(candidate.syncToken),
                  candidate.description.unicodeScalars.count <= 4000,
                  JobBillingAssignmentSnapshot.validConnectionRevision(candidate.candidateRevision) else { throw SharedTimeError.invalid }
        }
    }
}
struct SharedTimeJournal: Codable {
    var version = 1
    let companyID: UUID
    let actorEmail: String
    let localEntryID: UUID
    var request: SharedTimeRequest?
    var publication: SharedTimePublication?
    var confirmationRequested = false
}

@MainActor final class SharedTimeOwner {
    let entry: TimeEntry
    let source: SharedTimeSource
    let context: ModelContext
    let access: SharedTimeAccess
    let client: SharedTimeClient
    let store: SharedTimeLocalStore
    private let saveModel: () throws -> Void
    var key: String { access.scope("entry", source.id.uuidString.lowercased()) }
    init(entry: TimeEntry, context: ModelContext, access: SharedTimeAccess, client: SharedTimeClient? = nil, store: SharedTimeLocalStore? = nil,
         saveModel: (() throws -> Void)? = nil) throws {
        if saveModel != nil { precondition(GunnAireCloudKit.usesTestDatabase) }
        self.entry = entry; self.context = context; self.access = access; self.client = client ?? .live; self.store = store ?? .device
        self.saveModel = saveModel ?? { try context.save() }
        source = try .init(entry, context: context); try check()
    }
    func check() throws {
        try access.check()
        guard try SharedTimeSource(entry, context: context) == source else { throw SharedTimeError.changed }
    }
    func journal() throws -> SharedTimeJournal {
        try check()
        do {
            guard let data = try store.read(key) else { return .init(companyID: access.companyID, actorEmail: access.actorEmail, localEntryID: source.id) }
            let value = try JSONDecoder().decode(SharedTimeJournal.self, from: data)
            guard value.version == 1, value.companyID == access.companyID, value.actorEmail == access.actorEmail,
                  value.localEntryID == source.id, !value.confirmationRequested || value.publication != nil else { throw SharedTimeError.storage }
            if let request = value.request {
                try request.validate()
                guard request.companyID == access.companyID, request.localEntryID == source.id else { throw SharedTimeError.storage }
            }
            if let publication = value.publication {
                try publication.validate(company: access.companyID, entry: source.id)
                guard value.request == publication.review else { throw SharedTimeError.storage }
            }
            return value
        } catch { throw SharedTimeError.storage }
    }
    private func persist(_ value: SharedTimeJournal) throws { try check(); try store.write(key, JSONEncoder().encode(value)) }
    func connection() async throws -> SharedTimeWorkerContext {
        try check()
        do {
            let value = try await client.worker(.init(companyID: access.companyID, workerEmail: source.workerEmail))
            try check(); return value
        } catch { try check(); throw SharedTimeError.safe(error) }
    }
    func refresh() async throws -> SharedTimeJournal {
        let claim = try SharedTimeMutationGate.begin(key); defer { SharedTimeMutationGate.finish(key, id: claim) }
        return try await refreshedJournal()
    }
    private func refreshedJournal() async throws -> SharedTimeJournal {
        try check()
        let saved = try journal()
        struct List: Decodable { let publications: [SharedTimePublication] }
        let path = "/api/time-publications?companyID=\(access.companyID.uuidString.lowercased())&localEntryID=\(source.id.uuidString.lowercased())"
        let response = try await client.request(List.self, path: path, method: "GET")
        try check()
        guard response.publications.count <= 128, Set(response.publications.map(\.id)).count == response.publications.count else { throw SharedTimeError.invalid }
        for value in response.publications { try value.validate(company: access.companyID, entry: source.id) }
        let active = response.publications.filter { $0.state != "cancelled" }
        guard active.count <= 1 else { throw SharedTimeError.review }
        if let record = active.first {
            if let original = saved.publication, original.id != record.id, original.state != "cancelled" { throw SharedTimeError.review }
            if let original = saved.publication, original.id == record.id { try record.validateSuccessor(of: original) }
            if saved.confirmationRequested, let original = saved.request, original != record.review { throw SharedTimeError.review }
            var current = saved; current.request = record.review; current.publication = record
            current.confirmationRequested = saved.confirmationRequested || ["sending", "unknown", "confirmed"].contains(record.state)
            try persist(current); return current
        }
        if let original = saved.publication {
            guard let cancelled = response.publications.first(where: { $0.id == original.id && $0.state == "cancelled" }) else { throw SharedTimeError.review }
            try cancelled.validateSuccessor(of: original)
            var current = saved; current.publication = cancelled; current.confirmationRequested = false; try persist(current); return current
        }
        return saved // A prepare request may not have reached the server; retain it.
    }
    func prepare(itemID: UUID?) async throws -> SharedTimeJournal {
        let claim = try SharedTimeMutationGate.begin(key); defer { SharedTimeMutationGate.finish(key, id: claim) }
        try check()
        guard Config.QuickBooksTime.projectRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Config.QuickBooksTime.payrollItemRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SharedTimeError.setup }
        guard Config.QuickBooksTime.itemRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || itemID != nil else { throw SharedTimeError.mapping }
        func validateItem() throws {
            guard let itemID else { return }
            let items = try context.fetch(FetchDescriptor<Item>()).filter { $0.id == itemID }
            guard items.count == 1, !items[0].isDeleted, items[0].itemType == .service else { throw SharedTimeError.changed }
        }
        try validateItem()
        var saved = try await refreshedJournal()
        if let existing = saved.publication, existing.state != "cancelled" { return saved }
        let connection = try await connection()
        try validateItem()
        let request: SharedTimeRequest
        if let retained = saved.request, saved.publication == nil {
            guard retained.entryRevision == (try source.revision), retained.localItemID == itemID,
                  retained.realmID == connection.realmID, retained.environment == connection.environment,
                  retained.connectionRevision == connection.connectionRevision else { throw SharedTimeError.review }
            request = retained
        } else { request = try .init(source: source, connection: connection, itemID: itemID) }
        saved.request = request; saved.publication = nil; saved.confirmationRequested = false; try persist(saved)
        let result = try await client.request(SharedTimeResponse.self, path: "/api/time-publications", method: "POST", body: JSONEncoder().encode(request))
        try check(); try result.validate(company: access.companyID, entry: source.id)
        guard result.publication.review == request else { throw SharedTimeError.invalid }
        saved.publication = result.publication; try persist(saved); return saved
    }
    func decide(_ original: SharedTimePublication, legacy: SharedTimeLegacyCandidate? = nil) async throws -> SharedTimeResponse {
        let claim = try SharedTimeMutationGate.begin(key); defer { SharedTimeMutationGate.finish(key, id: claim) }
        try check()
        var saved = try journal()
        guard saved.publication == original, original.state == "reserved", !saved.confirmationRequested,
              original.entryRevision == (try source.revision), original.preparedByEmail == access.actorEmail,
              let expires = SharedTimeError.date(original.expiresAt), expires > Date(),
              entry.quickBooksTimeActivityID == nil || (legacy != nil && entry.quickBooksTimeActivityID == legacy?.providerID) else { throw SharedTimeError.review }
        let connection = try await connection()
        guard connection.realmID == original.realmID, connection.environment == original.environment,
              connection.connectionRevision == original.review.connectionRevision, connection.mapping == original.worker else { throw SharedTimeError.review }
        var payload = ["companyID": access.companyID.uuidString.lowercased(), "entryRevision": original.entryRevision, "reviewHash": original.reviewHash]
        if let legacy { payload["providerID"] = legacy.providerID; payload["candidateRevision"] = legacy.candidateRevision }
        saved.confirmationRequested = true; try persist(saved)
        let response = try await access.operation.performExternalMutation {
            try await client.request(SharedTimeResponse.self, path: "/api/time-publications/\(original.id.uuidString.lowercased())/\(legacy == nil ? "confirm" : "adopt")",
                method: "POST", body: JSONEncoder().encode(payload))
        }
        try accept(response, original: original)
        return response
    }
    func recover(_ original: SharedTimePublication) async throws -> SharedTimeResponse {
        let claim = try SharedTimeMutationGate.begin(key); defer { SharedTimeMutationGate.finish(key, id: claim) }
        try check()
        let response = try await client.request(SharedTimeResponse.self,
            path: "/api/time-publications/\(original.id.uuidString.lowercased())/recover", method: "POST", body: Data("{}".utf8))
        try accept(response, original: original); return response
    }
    private func accept(_ response: SharedTimeResponse, original: SharedTimePublication) throws {
        try check(); try response.validate(company: access.companyID, entry: source.id)
        try response.publication.validateSuccessor(of: original)
        var saved = try journal()
        guard let retained = saved.publication, retained.id == original.id else { throw SharedTimeError.review }
        try response.publication.validateSuccessor(of: retained)
        saved.request = response.publication.review; saved.publication = response.publication
        if response.needsLegacyReview == true, response.publication.state == "reserved" {
            // Explicit server evidence of no dispatch, including after a lost
            // legacy-review reply. Linking still needs its own confirmation.
            saved.confirmationRequested = false
        }
        try persist(saved)
        if let receipt = response.publication.receipt {
            guard original.entryRevision == (try source.revision),
                  entry.quickBooksTimeActivityID == nil || entry.quickBooksTimeActivityID == receipt.providerID else { throw SharedTimeError.changed }
            let old = (entry.quickBooksTimeActivityID, entry.quickBooksTimeActivitySyncToken, entry.quickBooksTimeActivitySyncedAt, entry.quickBooksTimeActivitySyncError)
            entry.quickBooksTimeActivityID = receipt.providerID; entry.quickBooksTimeActivitySyncToken = receipt.syncToken
            entry.quickBooksTimeActivitySyncedAt = SharedTimeError.date(receipt.confirmedAt); entry.quickBooksTimeActivitySyncError = nil
            do { try saveModel() }
            catch {
                entry.quickBooksTimeActivityID = old.0; entry.quickBooksTimeActivitySyncToken = old.1
                entry.quickBooksTimeActivitySyncedAt = old.2; entry.quickBooksTimeActivitySyncError = old.3
                throw SharedTimeError.save
            }
        }
    }
    func restoreSavedLink() throws -> SharedTimeJournal {
        let claim = try SharedTimeMutationGate.begin(key); defer { SharedTimeMutationGate.finish(key, id: claim) }
        guard let original = try journal().publication, original.state == "confirmed" else { throw SharedTimeError.review }
        try accept(.init(publication: original, legacyCandidate: nil, needsLegacyReview: nil), original: original)
        return try journal()
    }

    /// Only a preparation can be cleared without a publication ID. Preparation
    /// never dispatches QBO time. A late server reservation still owns the same
    /// company/entry and prevents a competing publication until cancelled.
    func clearUnsentPreparation() async throws -> SharedTimeJournal {
        let claim = try SharedTimeMutationGate.begin(key); defer { SharedTimeMutationGate.finish(key, id: claim) }
        let current = try await refreshedJournal()
        guard current.publication == nil, !current.confirmationRequested, current.request != nil else { throw SharedTimeError.review }
        let empty = SharedTimeJournal(companyID: access.companyID, actorEmail: access.actorEmail, localEntryID: source.id)
        try persist(empty); return empty
    }
    func cancel(_ original: SharedTimePublication) async throws -> SharedTimeJournal {
        let claim = try SharedTimeMutationGate.begin(key); defer { SharedTimeMutationGate.finish(key, id: claim) }
        try check()
        guard original.state == "reserved", try journal().publication?.id == original.id else { throw SharedTimeError.review }
        let response = try await client.request(SharedTimeResponse.self,
            path: "/api/time-publications/\(original.id.uuidString.lowercased())/cancel", method: "POST",
            body: JSONEncoder().encode(["companyID": access.companyID.uuidString.lowercased(), "reviewHash": original.reviewHash]))
        try check(); try response.validate(company: access.companyID, entry: source.id)
        try response.publication.validateSuccessor(of: original)
        guard response.publication.id == original.id, response.publication.reviewHash == original.reviewHash,
              response.publication.state == "cancelled", response.publication.review == original.review else { throw SharedTimeError.invalid }
        var saved = try journal(); saved.publication = response.publication; saved.confirmationRequested = false; try persist(saved); return saved
    }
}
