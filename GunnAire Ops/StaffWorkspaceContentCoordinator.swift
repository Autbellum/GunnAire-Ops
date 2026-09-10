import Foundation
import CryptoKit

struct StaffWorkspaceContentDependencies {
    let setup: () async throws -> (CloudKitStaffSetupController.Context, [CloudKitStaffSharePlan])
    let check: (StaffReplicaSourceContext) throws -> Void
    let request: (String, String, Data?) async throws -> Data
    let store: SharedTimeLocalStore
    var now: () -> Date = Date.init
    var operation: () -> UUID = UUID.init
    static var live: Self {
        .init(setup: StaffReplicaAutomaticDependencies.live.setup, check: { try StaffReplicaSourceDependencies.verify($0) },
              request: { try await GunnAireBackendService.staffReplicaSourceRequest(path: $0, method: $1, body: $2) },
              store: StaffWorkspaceContentStorage.device)
    }
}

enum StaffWorkspaceContentStorage {
    static var device: SharedTimeLocalStore {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .init(read: { _ in throw StaffReplicaDeliveryError.storage }, write: { _, _ in throw StaffReplicaDeliveryError.storage })
        }
        return .encrypted(directory: root.appendingPathComponent("StaffWorkspaceContent-v1", isDirectory: true), maximumBytes: 40 * 1024 * 1024) { create in
            let name = "StaffWorkspaceContentEncryption-v1"
            if let bytes = try KeychainStore.loadCodable(Data.self, account: name) {
                guard bytes.count == 32 else { throw StaffReplicaDeliveryError.storage }; return bytes
            }
            guard create else { throw StaffReplicaDeliveryError.storage }
            let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try KeychainStore.saveCodable(bytes, account: name); return bytes
        }
    }
}

struct StaffWorkspaceContentPending: Codable, Equatable {
    let plan: CloudKitStaffSharePlan
    let request: StaffWorkspaceSelectionRequest
    let requestBytes: Data
    let contentRequestBytes: Data
    var selection: StaffWorkspaceSelectionReceipt?
    var index: [StaffWorkspaceSelectionIndex] = []
    var indexComplete = false
    var content: StaffWorkspaceContentReceipt?
    var offset = 0
}
struct StaffWorkspaceContentJournal: Codable {
    let scope: StaffReplicaSourceScope
    let planID: UUID
    var pending: StaffWorkspaceContentPending?
    var lastReady: String?
}
struct StaffWorkspaceContentArchive: Codable, Equatable {
    let pending: StaffWorkspaceContentPending
    let outcome: String
}
struct StaffWorkspaceContentSummary {
    var prepared = 0
    var waitingForSetup = 0
    var hasMore = false
    var message: String { hasMore ? "Preparing full company data for staff…" : "Full company data prepared. Staff iCloud delivery still needs confirmation." }
}

/// Live owner-only preparation. Each original request, index and verified chunk
/// is recoverable across a new process. This never mounts a staff store or claims
/// that downloading the owner's payload constitutes independent CloudKit receipt.
@MainActor final class StaffWorkspaceContentCoordinator {
    static let shared = StaffWorkspaceContentCoordinator(dependencies: .live)
    let dependencies: StaffWorkspaceContentDependencies
    private var running = false
    init(dependencies: StaffWorkspaceContentDependencies) { self.dependencies = dependencies }
    static func key(_ source: StaffReplicaSourceScope, _ plan: UUID) -> String {
        "full-staff-content-v1\n" + source.key + "\n" + plan.uuidString.lowercased()
    }
    static func archiveKey(_ key: String, _ operation: String) -> String { key + "\noriginal-" + operation }
    static func chunkKey(_ key: String, _ operation: String, _ offset: Int) -> String { key + "\nchunk-" + operation + "-" + String(offset) }

    private func check(_ source: StaffReplicaSourceContext, _ context: CloudKitStaffSetupController.Context) throws {
        try Task.checkCancellation(); try dependencies.check(source)
        guard context.ownerAdministrator, context.member.isActive, context.member.email == source.scope.actorEmail,
              context.stamp.session == source.stamp.session, dependencies.now() < context.stamp.session.expiresAt,
              context.workspace.binding(for: context.account.environment) == source.scope.binding,
              context.account.accountHash == source.scope.binding.cloudAccountHash else { throw StaffReplicaDeliveryError.access }
    }
    private func validate(_ pending: StaffWorkspaceContentPending) throws {
        try pending.request.validate(pending.plan)
        guard try StaffWorkspacePublicationContract.decode(StaffWorkspaceSelectionRequest.self, from: pending.requestBytes) == pending.request,
              try StaffWorkspacePublicationContract.decode(StaffWorkspaceContentRequest.self, from: pending.contentRequestBytes) == StaffWorkspaceContentRequest(pending.request),
              pending.index.count <= 20_000, pending.index.map(\.key) == Array(Set(pending.index.map(\.key))).sorted(),
              (0...StaffWorkspaceContentReceipt.maximumBytes).contains(pending.offset) else { throw StaffReplicaDeliveryError.storage }
        if let selection = pending.selection {
            guard selection.operationID == pending.request.operationID, selection.sourceSequence == pending.request.expectedSourceSequence,
                  pending.index.count <= selection.recordCount else { throw StaffReplicaDeliveryError.storage }
            if pending.indexComplete { try selection.verifyIndex(pending.index) }
        } else if !pending.index.isEmpty || pending.indexComplete || pending.content != nil || pending.offset != 0 { throw StaffReplicaDeliveryError.storage }
        if let content = pending.content {
            guard let selection = pending.selection, pending.indexComplete, content.selectionID == selection.operationID,
                  content.selectionSHA256 == selection.snapshotSHA256, pending.offset <= content.payloadBytes,
                  pending.offset == content.payloadBytes || pending.offset % StaffWorkspaceContentReceipt.chunkSize == 0 else { throw StaffReplicaDeliveryError.storage }
        } else if pending.offset != 0 { throw StaffReplicaDeliveryError.storage }
    }
    private func load(_ key: String, source: StaffReplicaSourceContext, plan: UUID) throws -> StaffWorkspaceContentJournal {
        try dependencies.check(source)
        do {
            guard let bytes = try dependencies.store.read(key) else { return .init(scope: source.scope, planID: plan) }
            let journal = try StaffWorkspacePublicationContract.decode(StaffWorkspaceContentJournal.self, from: bytes, maximum: 40 * 1024 * 1024 - 64)
            guard journal.scope == source.scope, journal.planID == plan,
                  journal.lastReady.map(CloudKitStaffSetupPolicy.canonicalID) ?? true else { throw StaffReplicaDeliveryError.storage }
            if let pending = journal.pending { try validate(pending); guard pending.plan.id == plan else { throw StaffReplicaDeliveryError.storage } }
            return journal
        } catch { throw StaffReplicaDeliveryError.storage }
    }
    private func save(_ journal: StaffWorkspaceContentJournal, _ key: String, source: StaffReplicaSourceContext,
                      context: CloudKitStaffSetupController.Context) throws {
        try check(source, context)
        do {
            if let pending = journal.pending { try validate(pending) }
            let bytes = try StaffWorkspacePublicationContract.encode(journal)
            guard bytes.count <= 40 * 1024 * 1024 - 64 else { throw StaffReplicaDeliveryError.storage }
            try dependencies.store.write(key, bytes)
        } catch { throw StaffReplicaDeliveryError.storage }
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil, source: StaffReplicaSourceContext,
                         context: CloudKitStaffSetupController.Context) async throws -> Data {
        try check(source, context)
        guard StaffWorkspaceContentHTTPPolicy.allows(path: path, method: method, body: body) else { throw StaffReplicaDeliveryError.invalid }
        let data = try await dependencies.request(path, method, body)
        try check(source, context)
        guard data.count <= 8 * 1024 * 1024 else { throw StaffReplicaDeliveryError.invalid }
        return data
    }
    private func archive(_ key: String, operation: String) throws -> StaffWorkspaceContentArchive? {
        guard let data = try dependencies.store.read(Self.archiveKey(key, operation)) else { return nil }
        let result = try StaffWorkspacePublicationContract.decode(StaffWorkspaceContentArchive.self, from: data, maximum: 40 * 1024 * 1024 - 64)
        try validate(result.pending)
        guard result.pending.request.operationID == operation, ["ready", "sourceAdvanced", "rejected", "authorityChanged"].contains(result.outcome) else { throw StaffReplicaDeliveryError.storage }
        return result
    }
    private func finish(_ journal: inout StaffWorkspaceContentJournal, key: String, outcome: String,
                        source: StaffReplicaSourceContext, context: CloudKitStaffSetupController.Context) throws {
        try check(source, context)
        guard let pending = journal.pending else { throw StaffReplicaDeliveryError.storage }
        let result = StaffWorkspaceContentArchive(pending: pending, outcome: outcome)
        if let original = try archive(key, operation: pending.request.operationID) {
            guard original == result else { throw StaffReplicaDeliveryError.storage }
        } else {
            try dependencies.store.write(Self.archiveKey(key, pending.request.operationID), StaffWorkspacePublicationContract.encode(result))
        }
        if outcome == "ready" { journal.lastReady = pending.request.operationID }
        journal.pending = nil
        try save(journal, key, source: source, context: context)
    }

    private func verifyReady(_ pending: StaffWorkspaceContentPending, key: String, source: StaffReplicaSourceContext,
                             published: StaffWorkspacePublicationSummary, context: CloudKitStaffSetupController.Context) async throws {
        guard let selection = pending.selection, let content = pending.content, pending.indexComplete,
              pending.offset == content.payloadBytes else { throw StaffReplicaDeliveryError.storage }
        try selection.validate(pending.request, plan: pending.plan, workspace: context.workspace, now: dependencies.now())
        try selection.verifyIndex(pending.index)
        let path = StaffWorkspaceContentHTTPPolicy.path(pending.plan, request: pending.request, suffix: "/content")
        let current = try StaffWorkspacePublicationContract.decode(StaffWorkspaceContentReceipt.self,
            from: await request(path, source: source, context: context), maximum: 8192)
        guard current == content, current.sourceCurrent, current.sourceSequence == published.sourceSequence else { throw StaffReplicaSourceSyncError.sourceChanged }
        var assembly = try StaffWorkspaceContentAssembly(receipt: content, plan: pending.plan, workspace: context.workspace,
            selection: selection.operationID, selectionDigest: selection.snapshotSHA256, sequence: selection.sourceSequence, now: dependencies.now())
        while let offset = assembly.nextOffset {
            try check(source, context)
            guard let bytes = try dependencies.store.read(Self.chunkKey(key, selection.operationID, offset)) else { throw StaffReplicaDeliveryError.storage }
            try assembly.append(StaffWorkspaceContentChunk.decode(bytes))
        }
        try StaffWorkspaceContentVerification.validate(assembly.completedBytes(), receipt: content, index: pending.index,
            originals: published.publishedRecords, stage: published.preparedStage, source: source, plan: pending.plan,
            workspace: context.workspace, now: dependencies.now())
        let final = try StaffWorkspacePublicationContract.decode(StaffWorkspaceContentReceipt.self,
            from: await request(path, source: source, context: context), maximum: 8192)
        guard final == current else { throw StaffReplicaSourceSyncError.sourceChanged }
    }

    private func member(_ plan: CloudKitStaffSharePlan, source: StaffReplicaSourceContext,
                        published: StaffWorkspacePublicationSummary, context: CloudKitStaffSetupController.Context) async throws -> Bool {
        let key = Self.key(source.scope, plan.id), lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        var journal = try load(key, source: source, plan: plan.id)
        // Finish an archive-before-pointer transition before any network action.
        if let pending = journal.pending, let original = try archive(key, operation: pending.request.operationID) {
            guard original.pending == pending else { throw StaffReplicaDeliveryError.storage }
            try finish(&journal, key: key, outcome: original.outcome, source: source, context: context)
        }
        if let pending = journal.pending, pending.plan != plan {
            // A freshly verified successor plan cannot inherit the old request.
            // Retain the original under this owner-only scope before proceeding.
            try finish(&journal, key: key, outcome: "authorityChanged", source: source, context: context)
        }
        if journal.pending == nil, let operation = journal.lastReady {
            guard let original = try archive(key, operation: operation), original.outcome == "ready" else { throw StaffReplicaDeliveryError.storage }
            if original.pending.plan == plan, original.pending.request.expectedSourceSequence == published.sourceSequence {
                try await verifyReady(original.pending, key: key, source: source, published: published, context: context)
                return true
            }
        }
        for _ in 0..<2 {
            if journal.pending == nil {
                let selection = StaffWorkspaceSelectionRequest(plan: plan, sequence: published.sourceSequence, operation: dependencies.operation())
                guard try archive(key, operation: selection.operationID) == nil else { throw StaffReplicaDeliveryError.storage }
                journal.pending = .init(plan: plan, request: selection, requestBytes: try StaffWorkspacePublicationContract.encode(selection),
                    contentRequestBytes: try StaffWorkspacePublicationContract.encode(StaffWorkspaceContentRequest(selection)))
                try save(journal, key, source: source, context: context) // Before either POST.
            }
            guard var pending = journal.pending else { throw StaffReplicaDeliveryError.storage }
            let root = StaffWorkspaceContentHTTPPolicy.root(plan)
            let receipt: StaffWorkspaceSelectionReceipt
            do {
                let bytes = try await request(root, method: "POST", body: pending.requestBytes, source: source, context: context)
                receipt = try StaffWorkspacePublicationContract.decode(StaffWorkspaceSelectionReceipt.self, from: bytes, maximum: 8192)
            } catch let rejection as StaffReplicaSourceRejected where rejection.code == "source_changed" {
                guard pending.selection == nil else { throw StaffReplicaDeliveryError.invalid }
                try finish(&journal, key: key, outcome: "rejected", source: source, context: context)
                throw StaffReplicaSourceSyncError.sourceChanged
            }
            try receipt.validate(pending.request, plan: plan, workspace: context.workspace, now: dependencies.now())
            guard pending.selection.map({ receipt.sameOriginal(as: $0) }) ?? true else { throw StaffReplicaDeliveryError.invalid }
            pending.selection = receipt; journal.pending = pending
            try save(journal, key, source: source, context: context)
            if !receipt.sourceCurrent {
                try finish(&journal, key: key, outcome: "sourceAdvanced", source: source, context: context)
                guard receipt.currentSourceSequence == published.sourceSequence else { throw StaffReplicaSourceSyncError.sourceChanged }
                continue
            }
            guard receipt.sourceSequence == published.sourceSequence else { throw StaffReplicaSourceSyncError.sourceChanged }
            let originals = Dictionary(uniqueKeysWithValues: published.publishedRecords.map { ($0.key, $0) })
            for entry in pending.index {
                guard let original = originals[entry.key] else { throw StaffReplicaDeliveryError.invalid }; try entry.validate(original: original)
            }
            for _ in 0..<8 where !pending.indexComplete {
                let after = pending.index.last?.key
                let bytes = try await request(StaffWorkspaceContentHTTPPolicy.path(plan, request: pending.request, suffix: "/records", after: after), source: source, context: context)
                let page = try StaffWorkspacePublicationContract.decode(StaffWorkspaceSelectionPage.self, from: bytes)
                guard page.receipt == receipt, page.records.count <= 100,
                      !page.records.isEmpty || receipt.recordCount == 0 && pending.index.isEmpty,
                      page.records.map(\.key) == Array(Set(page.records.map(\.key))).sorted(),
                      page.records.allSatisfy({ $0.key > (after ?? "") }),
                      pending.index.count + page.records.count <= receipt.recordCount else { throw StaffReplicaDeliveryError.invalid }
                for entry in page.records {
                    guard let original = originals[entry.key] else { throw StaffReplicaDeliveryError.invalid }; try entry.validate(original: original)
                }
                let count = pending.index.count + page.records.count
                guard page.nextCursor == (count < receipt.recordCount ? page.records.last?.key : nil) else { throw StaffReplicaDeliveryError.invalid }
                pending.index += page.records; pending.indexComplete = page.nextCursor == nil
                if pending.indexComplete { try receipt.verifyIndex(pending.index) }
                journal.pending = pending; try save(journal, key, source: source, context: context)
            }
            if !pending.indexComplete { return false }
            let contentBytes: Data
            do {
                contentBytes = try await request(root + "/" + pending.request.operationID + "/content", method: "POST", body: pending.contentRequestBytes, source: source, context: context)
            } catch let rejection as StaffReplicaSourceRejected where rejection.code == "source_changed" {
                guard pending.content == nil else { throw StaffReplicaDeliveryError.invalid }
                try finish(&journal, key: key, outcome: "sourceAdvanced", source: source, context: context)
                throw StaffReplicaSourceSyncError.sourceChanged
            }
            let content = try StaffWorkspacePublicationContract.decode(StaffWorkspaceContentReceipt.self, from: contentBytes, maximum: 8192)
            try content.validate(plan: plan, workspace: context.workspace, selection: receipt.operationID,
                selectionDigest: receipt.snapshotSHA256, sequence: receipt.sourceSequence, now: dependencies.now(), requireCurrent: false)
            guard content.recordCount == receipt.recordCount else { throw StaffReplicaDeliveryError.invalid }
            if let old = pending.content {
                guard old.contentSHA256 == content.contentSHA256, old.payloadBytes == content.payloadBytes else { throw StaffReplicaDeliveryError.invalid }
            }
            pending.content = content; journal.pending = pending; try save(journal, key, source: source, context: context)
            if !content.sourceCurrent {
                try finish(&journal, key: key, outcome: "sourceAdvanced", source: source, context: context)
                throw StaffReplicaSourceSyncError.sourceChanged
            }
            var assembly = try StaffWorkspaceContentAssembly(receipt: content, plan: plan, workspace: context.workspace,
                selection: receipt.operationID, selectionDigest: receipt.snapshotSHA256, sequence: receipt.sourceSequence, now: dependencies.now())
            while assembly.bytes.count < pending.offset {
                try check(source, context)
                guard let saved = try dependencies.store.read(Self.chunkKey(key, receipt.operationID, assembly.bytes.count)) else { throw StaffReplicaDeliveryError.storage }
                try assembly.append(StaffWorkspaceContentChunk.decode(saved))
            }
            guard assembly.bytes.count == pending.offset else { throw StaffReplicaDeliveryError.storage }
            for _ in 0..<8 {
                guard let offset = assembly.nextOffset else { break }
                let chunkKey = Self.chunkKey(key, receipt.operationID, offset)
                let bytes: Data
                try check(source, context)
                if let saved = try dependencies.store.read(chunkKey) { bytes = saved }
                else {
                    bytes = try await request(StaffWorkspaceContentHTTPPolicy.path(plan, request: pending.request, suffix: "/content/chunks", offset: offset), source: source, context: context)
                }
                let chunk = try StaffWorkspaceContentChunk.decode(bytes)
                try assembly.append(chunk)
                try check(source, context)
                if let saved = try dependencies.store.read(chunkKey) {
                    guard saved == bytes else { throw StaffReplicaDeliveryError.storage }
                } else { try dependencies.store.write(chunkKey, bytes) }
                pending.offset = assembly.bytes.count; journal.pending = pending
                try save(journal, key, source: source, context: context) // Chunk durable before advancing its offset.
            }
            guard assembly.nextOffset == nil else { return false }
            let complete = try assembly.completedBytes()
            try StaffWorkspaceContentVerification.validate(complete, receipt: content, index: pending.index,
                originals: published.publishedRecords, stage: published.preparedStage, source: source, plan: plan,
                workspace: context.workspace, now: dependencies.now())
            // One final server head/authority check after local assembly, before
            // committing a ready pointer. The caller then rechecks saved history.
            let finalBytes = try await request(StaffWorkspaceContentHTTPPolicy.path(plan, request: pending.request, suffix: "/content"), source: source, context: context)
            let final = try StaffWorkspacePublicationContract.decode(StaffWorkspaceContentReceipt.self, from: finalBytes, maximum: 8192)
            guard final == content else { throw StaffReplicaSourceSyncError.sourceChanged }
            try finish(&journal, key: key, outcome: "ready", source: source, context: context)
            return true
        }
        throw StaffReplicaSourceSyncError.sourceChanged
    }

    func synchronize(_ source: StaffReplicaSourceContext, published: StaffWorkspacePublicationSummary) async throws -> StaffWorkspaceContentSummary {
        guard !running else { throw StaffReplicaDeliveryError.unavailable }
        running = true; defer { running = false }
        try dependencies.check(source)
        guard !published.hasMore, published.conflicts.isEmpty, published.waitingForCloudKit == 0,
              published.preparedStage.scope == source.scope,
              published.publishedRecords.map(\.key) == Array(Set(published.publishedRecords.map(\.key))).sorted() else { throw StaffReplicaDeliveryError.invalid }
        try published.preparedStage.validate(source.scope)
        try published.publishedRecords.forEach { try $0.validate(source.scope) }
        guard published.publishedRecords.compactMap(\.live) == published.preparedStage.records else { throw StaffReplicaDeliveryError.changed }
        let (context, plans) = try await dependencies.setup()
        try check(source, context)
        guard plans.count <= 5000, Set(plans.map(\.id)).count == plans.count, Set(plans.map(\.zoneName)).count == plans.count else { throw StaffReplicaDeliveryError.invalid }
        var result = StaffWorkspaceContentSummary()
        for plan in plans {
            try check(source, context); try plan.validate(workspace: context.workspace, now: dependencies.now())
            guard plan.state == "accepted", plan.businessAccessEligible, !plan.reviewRequired, !plan.cloudKitRevocationRequired,
                  published.sourceSequence > 0 else { if plan.state != "revoked" { result.waitingForSetup += 1 }; continue }
            if try await member(plan, source: source, published: published, context: context) { result.prepared += 1 }
            else { result.hasMore = true }
        }
        return result
    }
}
