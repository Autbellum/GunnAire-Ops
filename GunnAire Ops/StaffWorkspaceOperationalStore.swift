import Foundation
import SwiftData

/// Dedicated live SwiftData staff projection store after operational import.
///
/// Activates a dedicated `ModelContainer` of staff-only projection records from
/// an already-imported plan (`staff-workspace-operational-import-v1`). Never
/// calls owner `ModelCodec.make`, never rewrites mount bytes, never flips
/// `operationalWorkspaceReady`, and never claims independent-account CloudKit
/// convergence. Writes remain OPERATIONS command intents only.
struct StaffWorkspaceOperationalStoreJournal: Codable, Equatable {
    static let schema = "staff-workspace-operational-store-v1"
    let schema: String
    let scope: CloudKitStaffSetupScope
    let planID: UUID
    let selectionID: String
    let sourceSequence: Int
    let contentSHA256: String
    let recordCount: Int
    let state: String
    let operationalWorkspaceReady: Bool

    init(scope: CloudKitStaffSetupScope, planID: UUID, selectionID: String,
         sourceSequence: Int, contentSHA256: String, recordCount: Int) throws {
        guard CloudKitStaffSetupPolicy.canonicalID(selectionID),
              (1...2_147_483_647).contains(sourceSequence),
              JobBillingAssignmentSnapshot.validConnectionRevision(contentSHA256),
              (0...20_000).contains(recordCount) else {
            throw StaffReplicaDeliveryError.invalid
        }
        schema = Self.schema
        self.scope = scope
        self.planID = planID
        self.selectionID = selectionID
        self.sourceSequence = sourceSequence
        self.contentSHA256 = contentSHA256
        self.recordCount = recordCount
        state = "activated"
        operationalWorkspaceReady = false
    }

    func validate(scope: CloudKitStaffSetupScope, plan: UUID,
                  importJournal: StaffWorkspaceOperationalImportJournal,
                  mount: StaffWorkspaceOperationalMount) throws {
        guard schema == Self.schema, state == "activated", !operationalWorkspaceReady,
              self.scope == scope, planID == plan,
              selectionID == importJournal.selectionID,
              sourceSequence == importJournal.sourceSequence,
              contentSHA256 == importJournal.contentSHA256,
              recordCount == importJournal.recordCount,
              selectionID == mount.selectionID,
              sourceSequence == mount.sourceSequence,
              contentSHA256 == mount.contentSHA256 else {
            throw StaffReplicaDeliveryError.storage
        }
    }
}

/// Staff-only SwiftData projection. Stores explicit partitions as encoded blobs —
/// never an owner `@Model` reconstructed via `ModelCodec.make`.
@Model
final class StaffWorkspaceOperationalProjectionRecord {
    // Schema scaffolding defaults only — never used as owner restricted-field values.
    var kind: String = ""
    var recordID: String = ""
    var revision: Int = 0
    var unavailableLinksJSON: String = "[]"
    /// `"billing"` or `"operational"`.
    var bodyKind: String = ""
    var availableFieldsJSON: String = "{}"
    var unavailableFieldsJSON: String = "{}"
    var structuredFieldsJSON: String = "{}"

    init(kind: String, recordID: String, revision: Int, unavailableLinksJSON: String,
         bodyKind: String, availableFieldsJSON: String, unavailableFieldsJSON: String,
         structuredFieldsJSON: String) {
        self.kind = kind
        self.recordID = recordID
        self.revision = revision
        self.unavailableLinksJSON = unavailableLinksJSON
        self.bodyKind = bodyKind
        self.availableFieldsJSON = availableFieldsJSON
        self.unavailableFieldsJSON = unavailableFieldsJSON
        self.structuredFieldsJSON = structuredFieldsJSON
    }
}

/// Billing extras preserved alongside field partitions (not owner-model defaults).
private struct StaffWorkspaceOperationalBillingExtras: Codable, Equatable {
    let kind: String
    let id: UUID
    let catalog: StaffWorkspaceBillingProjection.Catalog
}

/// Live handle for an activated dedicated staff projection container.
/// Explicitly nonisolated: module default isolation is MainActor, and XCTest
/// releases locals off the main actor — a MainActor class deinit aborts via
/// `swift_task_deinitOnExecutorImpl`.
nonisolated final class StaffWorkspaceOperationalActivatedStore: @unchecked Sendable {
    let journal: StaffWorkspaceOperationalStoreJournal
    let plan: StaffWorkspaceOperationalImportPlan
    let container: ModelContainer
    /// Ephemeral on-disk sandbox for this activation; retained for ModelContainer lifetime.
    let storageDirectory: URL

    init(journal: StaffWorkspaceOperationalStoreJournal, plan: StaffWorkspaceOperationalImportPlan,
         container: ModelContainer, storageDirectory: URL) {
        self.journal = journal
        self.plan = plan
        self.container = container
        self.storageDirectory = storageDirectory
    }

    /// The handle may outlive its actor, but ModelContext and shared codecs may not.
    @MainActor func fetch(kind: String? = nil, id: String? = nil) throws -> [StaffWorkspaceOperationalImportRecord] {
        guard journal.schema == StaffWorkspaceOperationalStoreJournal.schema,
              journal.state == "activated",
              !journal.operationalWorkspaceReady,
              !plan.operationalWorkspaceReady else {
            throw StaffReplicaDeliveryError.storage
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let rows = try context.fetch(FetchDescriptor<StaffWorkspaceOperationalProjectionRecord>())
        var records: [StaffWorkspaceOperationalImportRecord] = []
        for row in rows {
            if let kind, row.kind != kind { continue }
            if let id {
                guard CloudKitStaffSetupPolicy.canonicalID(id) else { throw StaffReplicaDeliveryError.invalid }
                if row.recordID != id { continue }
            }
            records.append(try StaffWorkspaceOperationalStoreCodec.rehydrate(row))
        }
        return records.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.id < rhs.id
        }
    }
}

enum StaffWorkspaceOperationalStoreCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    private static func utf8JSON<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw StaffReplicaDeliveryError.storage
        }
        return text
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        guard let data = text.data(using: .utf8), !data.isEmpty else {
            throw StaffReplicaDeliveryError.storage
        }
        return try decoder.decode(type, from: data)
    }

    static func materialize(_ record: StaffWorkspaceOperationalImportRecord) throws
    -> StaffWorkspaceOperationalProjectionRecord {
        let linksJSON = try utf8JSON(record.unavailableLinks)
        switch record.body {
        case let .billing(document):
            try validateBilling(document)
            let extras = StaffWorkspaceOperationalBillingExtras(
                kind: document.kind, id: document.id, catalog: document.catalog)
            return StaffWorkspaceOperationalProjectionRecord(
                kind: record.kind, recordID: record.id, revision: record.revision,
                unavailableLinksJSON: linksJSON, bodyKind: "billing",
                availableFieldsJSON: try utf8JSON(document.fields),
                unavailableFieldsJSON: try utf8JSON(document.unavailableFields),
                structuredFieldsJSON: try utf8JSON(extras))
        case let .operational(partition):
            try validateOperational(partition)
            return StaffWorkspaceOperationalProjectionRecord(
                kind: record.kind, recordID: record.id, revision: record.revision,
                unavailableLinksJSON: linksJSON, bodyKind: "operational",
                availableFieldsJSON: try utf8JSON(partition.fields),
                unavailableFieldsJSON: try utf8JSON(partition.unavailableFields),
                structuredFieldsJSON: try utf8JSON(partition.structuredFields))
        }
    }

    static func rehydrate(_ row: StaffWorkspaceOperationalProjectionRecord) throws
    -> StaffWorkspaceOperationalImportRecord {
        let links = try decodeJSON([String].self, row.unavailableLinksJSON)
        switch row.bodyKind {
        case "billing":
            let fields = try decodeJSON([String: StaffWorkspaceValue].self, row.availableFieldsJSON)
            let unavailable = try decodeJSON(
                [String: StaffWorkspaceBillingProjection.Unavailable].self, row.unavailableFieldsJSON)
            let extras = try decodeJSON(StaffWorkspaceOperationalBillingExtras.self, row.structuredFieldsJSON)
            let document = StaffWorkspaceBillingProjection.Document(
                kind: extras.kind, id: extras.id, fields: fields,
                unavailableFields: unavailable, catalog: extras.catalog)
            try validateBilling(document)
            return .init(kind: row.kind, id: row.recordID, revision: row.revision,
                         unavailableLinks: links, body: .billing(document))
        case "operational":
            let fields = try decodeJSON([String: StaffWorkspaceValue].self, row.availableFieldsJSON)
            let unavailable = try decodeJSON(
                [String: StaffWorkspaceBillingProjection.Unavailable].self, row.unavailableFieldsJSON)
            let structured = try decodeJSON([String: Data].self, row.structuredFieldsJSON)
            let partition = StaffWorkspaceOperationalView.OperationalPartition(
                fields: fields, unavailableFields: unavailable, structuredFields: structured)
            try validateOperational(partition)
            return .init(kind: row.kind, id: row.recordID, revision: row.revision,
                         unavailableLinks: links, body: .operational(partition))
        default:
            throw StaffReplicaDeliveryError.storage
        }
    }

    private static func validateBilling(_ document: StaffWorkspaceBillingProjection.Document) throws {
        let fieldKeys = Set(document.fields.keys)
        let unavailableKeys = Set(document.unavailableFields.keys)
        guard fieldKeys.isDisjoint(with: unavailableKeys) else { throw StaffReplicaDeliveryError.invalid }
        guard document.unavailableFields.values.allSatisfy({
            $0 == .roleRestricted || $0 == .serviceOnly
        }) else { throw StaffReplicaDeliveryError.invalid }
    }

    private static func validateOperational(_ partition: StaffWorkspaceOperationalView.OperationalPartition) throws {
        let fieldKeys = Set(partition.fields.keys)
        let unavailableKeys = Set(partition.unavailableFields.keys)
        let structuredKeys = Set(partition.structuredFields.keys)
        guard fieldKeys.isDisjoint(with: unavailableKeys),
              fieldKeys.isDisjoint(with: structuredKeys),
              unavailableKeys.isDisjoint(with: structuredKeys),
              partition.unavailableFields.values.allSatisfy({
                  $0 == .roleRestricted || $0 == .serviceOnly
              }) else {
            throw StaffReplicaDeliveryError.invalid
        }
    }
}

enum StaffWorkspaceOperationalStoreActivator {
    static func key(_ scope: CloudKitStaffSetupScope, _ plan: UUID) -> String {
        "full-staff-content-store-v1\n" + scope.key + "\n" + plan.uuidString.lowercased()
    }

    static func loadJournal(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID) throws
    -> StaffWorkspaceOperationalStoreJournal? {
        do {
            guard let bytes = try store.read(key(scope, plan)) else { return nil }
            guard bytes.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
            let journal = try StaffWorkspacePublicationContract.decode(
                StaffWorkspaceOperationalStoreJournal.self, from: bytes, maximum: 8192)
            guard journal.schema == StaffWorkspaceOperationalStoreJournal.schema,
                  journal.state == "activated",
                  journal.operationalWorkspaceReady == false,
                  journal.scope == scope, journal.planID == plan else {
                throw StaffReplicaDeliveryError.storage
            }
            return journal
        } catch let error as StaffReplicaDeliveryError {
            throw error
        } catch {
            throw StaffReplicaDeliveryError.storage
        }
    }

    /// Build a dedicated ModelContainer and insert projection rows.
    /// Prefer ephemeral on-disk under a unique staff-scoped temp path (more reliable
    /// than shared in-memory names across XCTest process restarts).
    @MainActor
    static func makeContainer(from plan: StaffWorkspaceOperationalImportPlan) throws
    -> (ModelContainer, URL) {
        guard plan.schema == StaffWorkspaceOperationalImportJournal.schema,
              !plan.operationalWorkspaceReady,
              plan.records.count <= 20_000 else {
            throw StaffReplicaDeliveryError.invalid
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StaffWorkspaceOperationalStore-v1", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var folder = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let storeURL = root.appendingPathComponent("projection.store", isDirectory: false)
        let schema = Schema([StaffWorkspaceOperationalProjectionRecord.self])
        let configuration = ModelConfiguration(
            schema: schema, url: storeURL, cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            for record in plan.records {
                context.insert(try StaffWorkspaceOperationalStoreCodec.materialize(record))
            }
            try context.save()
            let confirm = try context.fetch(FetchDescriptor<StaffWorkspaceOperationalProjectionRecord>())
            guard confirm.count == plan.recordCount else {
                try? FileManager.default.removeItem(at: root)
                throw StaffReplicaDeliveryError.storage
            }
            return (container, root)
        } catch let error as StaffReplicaDeliveryError {
            try? FileManager.default.removeItem(at: root)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw StaffReplicaDeliveryError.storage
        }
    }

    /// Require a valid import journal + loadable import plan bound to current
    /// mount+acceptance, materialize projection models, journal activation.
    /// Idempotent for the same imported head; refuses superseded heads.
    @MainActor
    static func activate(plan importPlan: StaffWorkspaceOperationalImportPlan? = nil,
                         store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, planID: UUID,
                         check: () throws -> Void = {}) throws -> StaffWorkspaceOperationalActivatedStore {
        try check()
        guard let importJournal = try StaffWorkspaceOperationalImportStore.load(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard let (mount, payload) = try StaffWorkspaceOperationalMountStore.load(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard let acceptance = try StaffWorkspaceOperationalAcceptanceStore.load(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        // Import must still bind the current mount/acceptance head.
        if importJournal.sourceSequence < mount.sourceSequence
            || importJournal.contentSHA256 != mount.contentSHA256
            || importJournal.selectionID != mount.selectionID {
            throw StaffReplicaDeliveryError.superseded
        }
        try importJournal.validate(scope: scope, plan: planID, acceptance: acceptance, mount: mount)
        let loadedPlan: StaffWorkspaceOperationalImportPlan
        if let importPlan {
            guard importPlan.selectionID == importJournal.selectionID,
                  importPlan.contentSHA256 == importJournal.contentSHA256,
                  importPlan.sourceSequence == importJournal.sourceSequence,
                  importPlan.recordCount == importJournal.recordCount,
                  !importPlan.operationalWorkspaceReady,
                  importPlan.schema == StaffWorkspaceOperationalImportJournal.schema else {
                throw StaffReplicaDeliveryError.changed
            }
            loadedPlan = importPlan
        } else {
            guard let rebuilt = try StaffWorkspaceOperationalImportStore.loadPlan(
                store: store, scope: scope, plan: planID, check: check) else {
                throw StaffReplicaDeliveryError.pending
            }
            loadedPlan = rebuilt
        }
        guard loadedPlan.recordCount == importJournal.recordCount,
              loadedPlan.contentSHA256 == importJournal.contentSHA256,
              !loadedPlan.operationalWorkspaceReady else {
            throw StaffReplicaDeliveryError.changed
        }
        try check()
        let nextJournal = try StaffWorkspaceOperationalStoreJournal(
            scope: scope, planID: planID, selectionID: importJournal.selectionID,
            sourceSequence: importJournal.sourceSequence, contentSHA256: importJournal.contentSHA256,
            recordCount: importJournal.recordCount)
        if let existing = try loadJournal(store: store, scope: scope, plan: planID) {
            if existing.selectionID == nextJournal.selectionID,
               existing.contentSHA256 == nextJournal.contentSHA256,
               existing.sourceSequence == nextJournal.sourceSequence,
               existing.recordCount == nextJournal.recordCount {
                try existing.validate(scope: scope, plan: planID, importJournal: importJournal, mount: mount)
                guard existing.operationalWorkspaceReady == false else {
                    throw StaffReplicaDeliveryError.storage
                }
                // Idempotent: rebuild live container for the same head.
                let (container, directory) = try makeContainer(from: loadedPlan)
                return StaffWorkspaceOperationalActivatedStore(
                    journal: existing, plan: loadedPlan, container: container, storageDirectory: directory)
            }
            if existing.sourceSequence > nextJournal.sourceSequence {
                throw StaffReplicaDeliveryError.superseded
            }
        }
        try check()
        let (container, directory) = try makeContainer(from: loadedPlan)
        let encoded = try StaffWorkspacePublicationContract.encode(nextJournal)
        guard encoded.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
        try store.write(key(scope, planID), encoded)
        try check()
        // Mount payload bytes must be unchanged by store activation.
        guard let (_, confirmedPayload) = try StaffWorkspaceOperationalMountStore.load(
            store: store, scope: scope, plan: planID),
              confirmedPayload == payload else {
            try? FileManager.default.removeItem(at: directory)
            throw StaffReplicaDeliveryError.changed
        }
        guard let confirmed = try loadJournal(store: store, scope: scope, plan: planID),
              confirmed == nextJournal,
              confirmed.operationalWorkspaceReady == false else {
            try? FileManager.default.removeItem(at: directory)
            throw StaffReplicaDeliveryError.storage
        }
        try confirmed.validate(scope: scope, plan: planID, importJournal: importJournal, mount: mount)
        return StaffWorkspaceOperationalActivatedStore(
            journal: confirmed, plan: loadedPlan, container: container, storageDirectory: directory)
    }

    /// Rebuild a live dedicated staff projection container from durable activation
    /// journal + current import plan, or nil when no activation journal exists.
    @MainActor
    static func loadActivated(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, planID: UUID,
                              check: () throws -> Void = {}) throws -> StaffWorkspaceOperationalActivatedStore? {
        try check()
        guard let journal = try loadJournal(store: store, scope: scope, plan: planID) else { return nil }
        guard let importJournal = try StaffWorkspaceOperationalImportStore.load(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard let (mount, _) = try StaffWorkspaceOperationalMountStore.load(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        if journal.sourceSequence < mount.sourceSequence
            || journal.contentSHA256 != mount.contentSHA256
            || journal.selectionID != mount.selectionID {
            throw StaffReplicaDeliveryError.superseded
        }
        try journal.validate(scope: scope, plan: planID, importJournal: importJournal, mount: mount)
        guard let loadedPlan = try StaffWorkspaceOperationalImportStore.loadPlan(
            store: store, scope: scope, plan: planID, check: check) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard loadedPlan.recordCount == journal.recordCount,
              loadedPlan.contentSHA256 == journal.contentSHA256,
              !loadedPlan.operationalWorkspaceReady,
              !journal.operationalWorkspaceReady else {
            throw StaffReplicaDeliveryError.changed
        }
        let (container, directory) = try makeContainer(from: loadedPlan)
        return StaffWorkspaceOperationalActivatedStore(
            journal: journal, plan: loadedPlan, container: container, storageDirectory: directory)
    }
}
