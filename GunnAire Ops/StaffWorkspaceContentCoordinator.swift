import Foundation
import CryptoKit

struct StaffWorkspaceContentDependencies {
    typealias Context = CloudKitStaffSetupController.Context
    let setup: () async throws -> (Context, [CloudKitStaffSharePlan])
    let check: (StaffReplicaSourceContext) throws -> Void
    let request: (String, String, Data?) async throws -> Data
    let store: SharedTimeLocalStore
    /// When non-nil, owner CloudKit publish of the sealed full-workspace package is required
    /// before the summary reports confirmed iCloud delivery. Tests may leave this nil.
    var ownerCloudIO: ((CloudKitStaffSharePlan, Context, @escaping CloudKitStaffRemote.Authorize) throws -> StaffReplicaCloudIO)? = nil
    /// When non-nil, staff participant CloudKit receive/lease is available.
    /// Signature mirrors StaffReplicaCloudTransfer.participantIO. Tests may leave this nil.
    var participantCloudIO: ((CloudKitStaffSharePlan, Context, URL, @escaping CloudKitStaffRemote.Authorize) async throws -> StaffReplicaCloudIO)? = nil
    /// Resolves the original accepted invitation URL (same source as StaffReplicaReceiveController).
    var invitationURL: ((CloudKitStaffSharePlan, Context) -> URL?)? = nil
    /// Staff-capable GET for `/content/cloud-key` only. Never uses the Admin-only owner helper.
    var staffRequest: ((String) async throws -> Data)? = nil
    /// Staff-capable GET for `/content/media` grant JSON or `/content/media/bytes`.
    var staffMediaRequest: ((String, Int) async throws -> Data)? = nil
    /// Staff-capable POST for `/content/commands` journal receipt.
    var staffCommandRequest: ((String, Data) async throws -> Data)? = nil
    /// Staff-author-only GET of historical office outcomes, never owner details.
    var staffFieldUpdatesRequest: ((String) async throws -> Data)? = nil
    /// Recheck the live account/session fence around every staff await/write.
    /// Test fixtures inject their own fence; live code never trusts context alone.
    var checkStaffSession: (Context) throws -> Void = { _ in }
    var now: () -> Date = Date.init
    var operation: () -> UUID = UUID.init
    static var live: Self {
        .init(setup: StaffReplicaAutomaticDependencies.live.setup, check: { try StaffReplicaSourceDependencies.verify($0) },
              request: { try await GunnAireBackendService.staffReplicaSourceRequest(path: $0, method: $1, body: $2) },
              store: StaffWorkspaceContentStorage.device, ownerCloudIO: StaffReplicaCloudTransfer.ownerIO,
              participantCloudIO: StaffReplicaCloudTransfer.participantIO,
              invitationURL: { plan, context in
                  guard let bytes = try? CloudKitStaffSetupStorage.device.read(context.scope.key),
                        let journal = try? JSONDecoder().decode(CloudKitStaffSetupJournal.self, from: bytes) else { return nil }
                  return journal.invitationURLs[plan.id.uuidString.lowercased()]
              },
              staffRequest: { try await GunnAireBackendService.staffWorkspaceCloudKeyRequest(path: $0) },
              staffMediaRequest: { try await GunnAireBackendService.staffWorkspaceMediaRequest(path: $0, maximum: $1) },
              staffCommandRequest: { try await GunnAireBackendService.staffWorkspaceCommandRequest(path: $0, body: $1) },
              staffFieldUpdatesRequest: { try await GunnAireBackendService.staffWorkspaceFieldUpdatesRequest(path: $0) },
              checkStaffSession: { context in
                  guard CloudKitStaffSetupStamp.current == context.stamp else { throw StaffReplicaDeliveryError.access }
              })
    }
}

enum StaffWorkspaceContentStorage {
    static var device: SharedTimeLocalStore {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .init(read: { _ in throw StaffReplicaDeliveryError.storage }, write: { _, _ in throw StaffReplicaDeliveryError.storage })
        }
        return .encrypted(directory: root.appendingPathComponent("StaffWorkspaceContent-v1", isDirectory: true), maximumBytes: 64 * 1024 * 1024) { create in
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
    /// Operation ID whose sealed full-workspace package was verified in CloudKit.
    /// Never stores key/nonce — only the selection identity that completed publish.
    var cloudPublishedOperation: String?
}
/// Staff-side durable lease marker after verified CK receive + HTTP key-open.
/// Never stores key, nonce, or opened payload bytes.
struct StaffWorkspaceCloudReceiveJournal: Codable {
    let scope: CloudKitStaffSetupScope
    let planID: UUID
    var cloudReceivedOperation: String?
}
struct StaffWorkspaceCloudReceiveResult: Equatable {
    let selectionID: String
    let alreadyLeased: Bool
    /// True when verified opened bytes are present in the durable operational mount.
    let operationalMounted: Bool
    /// True when mounted bytes parsed as `staff-workspace-content-v1` and the
    /// acceptance journal was written. Opaque or non-v1 mounts stay false; never
    /// flips `operationalWorkspaceReady`.
    let operationalAccepted: Bool
    var commandRecovery = StaffWorkspaceCommandRecoverySummary(recorded: 0, pending: 0)
}
struct StaffWorkspaceContentArchive: Codable, Equatable {
    let pending: StaffWorkspaceContentPending
    let outcome: String
}
struct StaffWorkspaceContentSummary {
    var prepared = 0
    var cloudPublished = 0
    var cloudReceived = 0
    var waitingForSetup = 0
    var hasMore = false
    var message: String {
        if hasMore { return "Preparing full company data for staff…" }
        if cloudReceived > 0 {
            return "Full company cloud data received and verified for staff lease."
        }
        if prepared > 0, cloudPublished >= prepared {
            return "Full company data prepared and confirmed in staff iCloud."
        }
        if prepared > 0 {
            return "Full company data prepared. Staff iCloud delivery still needs confirmation."
        }
        return "Full company data prepared. Staff iCloud delivery still needs confirmation."
    }
}

/// Owner preparation plus staff participant cloud receive/lease. Owner path never
/// mounts a staff store. Staff receiveAndLease verifies sealed CK bytes with an
/// HTTP cloud-key, installs the durable operational mount from opened bytes, then
/// records an operation-ID lease marker. Auto-attempts `acceptMountedOperationalView` for
/// semantic role-projection acceptance, then optional staff-scoped import adapters without full staff-store activation.
@MainActor final class StaffWorkspaceContentCoordinator {
    static let shared = StaffWorkspaceContentCoordinator(dependencies: .live)
    let dependencies: StaffWorkspaceContentDependencies
    private var running = false
    init(dependencies: StaffWorkspaceContentDependencies) { self.dependencies = dependencies }
    // No actor-bound cleanup: only release stored values/closures. A synthesized
    // executor hop aborts during synchronous disposal on the iOS 26.2 runtime.
    // Operational methods and mutable state remain MainActor-isolated.
    nonisolated deinit {}
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
            let journal = try StaffWorkspacePublicationContract.decode(StaffWorkspaceContentJournal.self, from: bytes, maximum: 64 * 1024 * 1024 - 64)
            guard journal.scope == source.scope, journal.planID == plan,
                  journal.lastReady.map(CloudKitStaffSetupPolicy.canonicalID) ?? true,
                  journal.cloudPublishedOperation.map(CloudKitStaffSetupPolicy.canonicalID) ?? true,
                  journal.cloudPublishedOperation == nil || journal.cloudPublishedOperation == journal.lastReady else {
                throw StaffReplicaDeliveryError.storage
            }
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
            guard bytes.count <= 64 * 1024 * 1024 - 64 else { throw StaffReplicaDeliveryError.storage }
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
        let result = try StaffWorkspacePublicationContract.decode(StaffWorkspaceContentArchive.self, from: data, maximum: 64 * 1024 * 1024 - 64)
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
        else if journal.cloudPublishedOperation == pending.request.operationID { journal.cloudPublishedOperation = nil }
        journal.pending = nil
        try save(journal, key, source: source, context: context)
    }

    private func sealAndPublish(_ pending: StaffWorkspaceContentPending, raw: Data, key: String,
                                source: StaffReplicaSourceContext, context: CloudKitStaffSetupController.Context) async throws {
        guard let ownerCloudIO = dependencies.ownerCloudIO else { return }
        guard let content = pending.content else { throw StaffReplicaDeliveryError.storage }
        try check(source, context)
        let postPath = StaffWorkspaceContentHTTPPolicy.root(pending.plan) + "/" + pending.request.operationID + "/content/cloud-seal"
        let getPath = StaffWorkspaceContentHTTPPolicy.path(pending.plan, request: pending.request, suffix: "/content/cloud-seal")
        let sealBytes = try await request(postPath, method: "POST", body: pending.contentRequestBytes, source: source, context: context)
        let seal = try StaffWorkspacePublicationContract.decode(StaffWorkspaceCloudSealResponse.self, from: sealBytes, maximum: 8192)
        try seal.validate(against: content)
        let package = try StaffWorkspaceCloudSealedPackage(content: content, raw: raw, response: seal)
        let authorize: CloudKitStaffRemote.Authorize = {
            let freshBytes = try await self.request(getPath, source: source, context: context)
            let fresh = try StaffWorkspacePublicationContract.decode(StaffWorkspaceCloudSealResponse.self, from: freshBytes, maximum: 8192)
            guard fresh == seal else { throw StaffReplicaDeliveryError.changed }
        }
        let io = try ownerCloudIO(pending.plan, context, authorize)
        try await StaffWorkspaceCloudTransfer.publish(package, plan: pending.plan, workspace: context.workspace, io: io, now: dependencies.now)
        try await StaffWorkspaceCloudTransfer.verifyOwnerPublication(package, plan: pending.plan, workspace: context.workspace,
                                                                     io: io, now: dependencies.now())
        // Idempotent re-read proves key material still matches after CK confirm.
        let confirmedBytes = try await request(getPath, source: source, context: context)
        let confirmed = try StaffWorkspacePublicationContract.decode(StaffWorkspaceCloudSealResponse.self, from: confirmedBytes, maximum: 8192)
        guard confirmed.sealedSHA256 == seal.sealedSHA256, confirmed.keyBase64 == seal.keyBase64,
              confirmed.nonceBase64 == seal.nonceBase64 else { throw StaffReplicaDeliveryError.changed }
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
                if dependencies.ownerCloudIO != nil, journal.cloudPublishedOperation != operation {
                    guard let content = original.pending.content, original.pending.indexComplete,
                          original.pending.offset == content.payloadBytes else { throw StaffReplicaDeliveryError.storage }
                    var assembly = try StaffWorkspaceContentAssembly(receipt: content, plan: plan, workspace: context.workspace,
                        selection: original.pending.request.operationID, selectionDigest: content.selectionSHA256,
                        sequence: content.sourceSequence, now: dependencies.now())
                    while let offset = assembly.nextOffset {
                        try check(source, context)
                        guard let bytes = try dependencies.store.read(Self.chunkKey(key, operation, offset)) else {
                            throw StaffReplicaDeliveryError.storage
                        }
                        try assembly.append(StaffWorkspaceContentChunk.decode(bytes))
                    }
                    try await sealAndPublish(original.pending, raw: assembly.completedBytes(), key: key, source: source, context: context)
                    journal.cloudPublishedOperation = operation
                    try save(journal, key, source: source, context: context)
                }
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
            let operationID = pending.request.operationID
            if dependencies.ownerCloudIO != nil {
                try await sealAndPublish(pending, raw: complete, key: key, source: source, context: context)
            }
            try finish(&journal, key: key, outcome: "ready", source: source, context: context)
            if dependencies.ownerCloudIO != nil {
                journal.cloudPublishedOperation = operationID
                try save(journal, key, source: source, context: context)
            }
            return true
        }
        throw StaffReplicaSourceSyncError.sourceChanged
    }

    static func receiveKey(_ scope: CloudKitStaffSetupScope, _ plan: UUID) -> String {
        "full-staff-content-receive-v1\n" + scope.key + "\n" + plan.uuidString.lowercased()
    }

    private func staffCheck(_ context: CloudKitStaffSetupController.Context, _ plan: CloudKitStaffSharePlan) throws {
        try Task.checkCancellation()
        try dependencies.checkStaffSession(context)
        guard !context.ownerAdministrator, context.owns(plan), context.member.isActive,
              context.member.email == context.stamp.session.email, context.member.role == plan.memberRole,
              context.account.environment == plan.environment,
              dependencies.now() < context.stamp.session.expiresAt else { throw StaffReplicaDeliveryError.access }
        try plan.validate(workspace: context.workspace, now: dependencies.now())
        guard plan.state == "accepted", plan.businessAccessEligible, !plan.reviewRequired, !plan.cloudKitRevocationRequired else {
            throw StaffReplicaDeliveryError.changed
        }
    }

    private func loadReceive(_ key: String, context: CloudKitStaffSetupController.Context, plan: UUID) throws -> StaffWorkspaceCloudReceiveJournal {
        do {
            guard let bytes = try dependencies.store.read(key) else {
                return .init(scope: context.scope, planID: plan)
            }
            let journal = try StaffWorkspacePublicationContract.decode(StaffWorkspaceCloudReceiveJournal.self, from: bytes, maximum: 8192)
            guard journal.scope == context.scope, journal.planID == plan,
                  journal.cloudReceivedOperation.map(CloudKitStaffSetupPolicy.canonicalID) ?? true else {
                throw StaffReplicaDeliveryError.storage
            }
            return journal
        } catch { throw StaffReplicaDeliveryError.storage }
    }

    private func saveReceive(_ journal: StaffWorkspaceCloudReceiveJournal, _ key: String,
                             context: CloudKitStaffSetupController.Context, plan: CloudKitStaffSharePlan) throws {
        try staffCheck(context, plan)
        do {
            let bytes = try StaffWorkspacePublicationContract.encode(journal)
            guard bytes.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
            try dependencies.store.write(key, bytes)
        } catch { throw StaffReplicaDeliveryError.storage }
    }

    private func staffHTTP(_ path: String, context: CloudKitStaffSetupController.Context,
                           plan: CloudKitStaffSharePlan) async throws -> Data {
        guard let staffRequest = dependencies.staffRequest else { throw StaffReplicaDeliveryError.unavailable }
        try staffCheck(context, plan)
        guard StaffWorkspaceContentHTTPPolicy.allows(path: path, method: "GET", body: nil),
              URLComponents(string: path)?.path.hasSuffix("/content/cloud-key") == true else {
            throw StaffReplicaDeliveryError.invalid
        }
        let data = try await staffRequest(path)
        try staffCheck(context, plan)
        guard data.count <= 8192 else { throw StaffReplicaDeliveryError.invalid }
        return data
    }

    /// Staff participant path: invitation → participantIO → HTTP cloud-key → CK
    /// sealed download → verified open → durable operational mount (opened bytes)
    /// → lease marker (operation ID only) → best-effort semantic acceptance when
    /// opened bytes are `staff-workspace-content-v1` (still not SwiftData /
    /// operationalWorkspaceReady). Non-v1 mounts leave `operationalAccepted` false.
    @discardableResult
    func receiveAndLease(plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context,
                         invitation: URL? = nil) async throws -> StaffWorkspaceCloudReceiveResult {
        guard let participantCloudIO = dependencies.participantCloudIO else { throw StaffReplicaDeliveryError.unavailable }
        try staffCheck(context, plan)
        let commandRecovery = try await recoverOperationalCommands(plan: plan, context: context)
        try staffCheck(context, plan)
        let resolved = invitation ?? dependencies.invitationURL?(plan, context)
        guard let resolved, CloudKitStaffSetupPolicy.invitationURL(resolved) else { throw StaffReplicaDeliveryError.access }
        let key = Self.receiveKey(context.scope, plan.id)
        let lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        var journal = try loadReceive(key, context: context, plan: plan.id)
        let authorize: CloudKitStaffRemote.Authorize = { try self.staffCheck(context, plan) }
        let io = try await participantCloudIO(plan, context, resolved, authorize)
        guard let head = try await StaffWorkspaceCloudTransfer.participantHead(
            plan: plan, workspace: context.workspace, io: io, now: dependencies.now()) else {
            throw StaffReplicaDeliveryError.pending
        }
        // A durable mount or lease marker never substitutes for current business
        // authority, including the exact-remount fast path and readiness proofs.
        let seal = try await authorizeStaffHead(head, plan: plan, context: context)
        guard let selection = UUID(uuidString: head.selectionID) else { throw StaffReplicaDeliveryError.invalid }
        let selectionRequest = StaffWorkspaceSelectionRequest(plan: plan, sequence: head.sourceSequence, operation: selection)
        let keyPath = StaffWorkspaceCloudTransfer.cloudKeyPath(plan: plan, request: selectionRequest)
        if let (existing, _) = try StaffWorkspaceOperationalMountStore.load(
            store: dependencies.store, scope: context.scope, plan: plan.id) {
            if existing.sourceSequence > head.sourceSequence {
                // Retained newer local mount must not be replaced by an older CK head.
                throw StaffReplicaDeliveryError.superseded
            }
            if journal.cloudReceivedOperation == head.selectionID,
               existing.selectionID == head.selectionID,
               existing.contentSHA256 == head.contentSHA256,
               existing.sealedSHA256 == head.sealedSHA256,
               existing.sourceSequence == head.sourceSequence {
                guard try await StaffWorkspaceCloudTransfer.participantHead(plan: plan, workspace: context.workspace,
                    io: io, now: dependencies.now()) == head else { throw StaffReplicaDeliveryError.superseded }
                let accepted = Self.tryAcceptMountedContentV1(
                    store: dependencies.store, scope: context.scope, plan: plan.id,
                    selectionID: head.selectionID, check: { try self.staffCheck(context, plan) })
                return .init(selectionID: head.selectionID, alreadyLeased: true,
                             operationalMounted: true, operationalAccepted: accepted, commandRecovery: commandRecovery)
            }
            // Equal-sequence identity mismatch is rejected later by install().
        } else if journal.cloudReceivedOperation == head.selectionID {
            // Lease marker without mount — recover by re-opening; do not clear the marker first.
        }
        let material = try StaffWorkspaceCloudSealResponse.material(seal.keyBase64, size: 32)
        let package = try await StaffWorkspaceCloudTransfer.download(
            plan: plan, workspace: context.workspace, io: io, key: material, now: dependencies.now)
        guard package.manifest == head,
              StaffReplicaManifest.hash(package.opened) == seal.content.contentSHA256,
              package.opened.count == seal.content.payloadBytes else { throw StaffReplicaDeliveryError.changed }
        let confirmedBytes = try await staffHTTP(keyPath, context: context, plan: plan)
        let confirmed = try StaffWorkspaceCloudTransfer.decodeKeyRelease(confirmedBytes, against: seal.content)
        guard confirmed.sealedSHA256 == seal.sealedSHA256, confirmed.keyBase64 == seal.keyBase64,
              confirmed.nonceBase64 == seal.nonceBase64 else { throw StaffReplicaDeliveryError.changed }
        try staffCheck(context, plan)
        // Payload then metadata before the lease marker — interrupted mounts retain
        // recoverable originals and cannot recreate lost encryption keys.
        _ = try StaffWorkspaceOperationalMountStore.install(
            opened: package.opened, manifest: package.manifest, store: dependencies.store,
            scope: context.scope, plan: plan.id, check: { try self.staffCheck(context, plan) })
        // Durable lease marker only — never key, nonce, or opened bytes.
        journal.cloudReceivedOperation = head.selectionID
        try saveReceive(journal, key, context: context, plan: plan)
        let accepted = Self.tryAcceptMountedContentV1(
            store: dependencies.store, scope: context.scope, plan: plan.id,
            selectionID: head.selectionID, check: { try self.staffCheck(context, plan) })
        return .init(selectionID: head.selectionID, alreadyLeased: false,
                     operationalMounted: true, operationalAccepted: accepted, commandRecovery: commandRecovery)
    }

    /// Best-effort semantic acceptance after a durable mount. Peek schema only;
    /// non-v1 / parse failures leave mount + lease untouched and return false.
    private static func tryAcceptMountedContentV1(
        store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID,
        selectionID: String, check: () throws -> Void
    ) -> Bool {
        do {
            guard let (_, payload) = try StaffWorkspaceOperationalMountStore.load(
                store: store, scope: scope, plan: plan) else { return false }
            guard let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  root["schema"] as? String == "staff-workspace-content-v1" else {
                return false
            }
            _ = try StaffWorkspaceOperationalAcceptanceStore.accept(
                store: store, scope: scope, plan: plan, selectionID: selectionID, check: check)
            return true
        } catch {
            return false
        }
    }

    /// Read-only semantic acceptance of mounted `staff-workspace-content-v1` bytes.
    /// Requires an existing durable mount. Writes a small acceptance journal bound to
    /// selectionID + contentSHA256 + sourceSequence. Never invents defaults for
    /// restricted/unavailable fields; never flips `operationalWorkspaceReady`.
    @discardableResult
    func acceptMountedOperationalView(plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context,
                                      selectionID: String? = nil) throws -> StaffWorkspaceOperationalView {
        try staffCheck(context, plan)
        let acceptKey = StaffWorkspaceOperationalAcceptanceStore.key(context.scope, plan.id)
        let lock = try SharedTimeMutationGate.begin(acceptKey)
        defer { SharedTimeMutationGate.finish(acceptKey, id: lock) }
        return try StaffWorkspaceOperationalAcceptanceStore.accept(
            store: dependencies.store, scope: context.scope, plan: plan.id,
            selectionID: selectionID, check: { try self.staffCheck(context, plan) })
    }

    /// Authenticated media grant for one attachment in the accepted operational view.
    /// Fail-closed without non-null backendDocumentID / HTTP media grant. Never flips
    /// `operationalWorkspaceReady`. Optional sandbox open uses verified downloaded bytes.
    @discardableResult
    func authorizeOperationalMedia(plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context,
                                   attachmentID: String, openSandboxIn directory: URL? = nil) async throws
    -> (StaffWorkspaceOperationalMediaGrant, URL?) {
        try staffCheck(context, plan)
        guard CloudKitStaffSetupPolicy.canonicalID(attachmentID) else { throw StaffReplicaDeliveryError.invalid }
        guard let staffMediaRequest = dependencies.staffMediaRequest else { throw StaffReplicaDeliveryError.unavailable }
        let mediaKey = StaffWorkspaceOperationalMediaStore.key(context.scope, plan.id, attachmentID: attachmentID)
        let lock = try SharedTimeMutationGate.begin(mediaKey)
        defer { SharedTimeMutationGate.finish(mediaKey, id: lock) }
        // Ensure acceptance journal exists for the current mount before media HTTP.
        let view = try StaffWorkspaceOperationalAcceptanceStore.accept(
            store: dependencies.store, scope: context.scope, plan: plan.id,
            check: { try self.staffCheck(context, plan) })
        let candidate = try StaffWorkspaceOperationalMediaStore.candidates(from: view)
            .first { $0.attachmentID == attachmentID }
        guard let candidate else { throw StaffReplicaDeliveryError.invalid }
        guard candidate.backendDocumentID != nil else { throw StaffReplicaDeliveryError.pending }
        guard let selectionUUID = UUID(uuidString: view.selectionID) else { throw StaffReplicaDeliveryError.invalid }
        let selection = StaffWorkspaceSelectionRequest(plan: plan, sequence: view.sourceSequence,
                                                       operation: selectionUUID)
        try selection.validate(plan)
        let grantPath = StaffWorkspaceContentHTTPPolicy.path(
            plan, request: selection, suffix: "/content/media", attachmentID: attachmentID)
        guard StaffWorkspaceContentHTTPPolicy.allows(path: grantPath, method: "GET", body: nil) else {
            throw StaffReplicaDeliveryError.invalid
        }
        try staffCheck(context, plan)
        let grantBytes = try await staffMediaRequest(grantPath, 8192)
        try staffCheck(context, plan)
        let httpGrant = try StaffWorkspacePublicationContract.decode(
            StaffWorkspaceOperationalMediaHTTPGrant.self, from: grantBytes, maximum: 8192)
        let grant = try StaffWorkspaceOperationalMediaStore.authorize(
            store: dependencies.store, scope: context.scope, plan: plan.id,
            attachmentID: attachmentID, httpGrant: httpGrant,
            check: { try self.staffCheck(context, plan) })
        guard let directory else { return (grant, nil) }
        let bytesPath = StaffWorkspaceContentHTTPPolicy.path(
            plan, request: selection, suffix: "/content/media/bytes", attachmentID: attachmentID)
        guard StaffWorkspaceContentHTTPPolicy.allows(path: bytesPath, method: "GET", body: nil) else {
            throw StaffReplicaDeliveryError.invalid
        }
        try staffCheck(context, plan)
        let mediaBytes = try await staffMediaRequest(bytesPath, grant.fileSizeBytes)
        try staffCheck(context, plan)
        let url = try StaffWorkspaceOperationalMediaStore.openSandbox(
            grant: grant, bytes: mediaBytes, directory: directory,
            check: { try self.staffCheck(context, plan) })
        return (grant, url)
    }

    /// Submit one operations-policy field command against the accepted operational view.
    /// Journals intent locally, POSTs for an HTTP receipt, and never flips
    /// `operationalWorkspaceReady` or mutates mounted content bytes.
    @discardableResult
    func submitOperationalCommand(plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context,
                                  recordKind: String, recordID: String, fieldName: String,
                                  value: StaffWorkspaceValue, commandID: UUID? = nil) async throws
    -> StaffWorkspaceOperationalCommandJournal {
        try staffCheck(context, plan)
        guard CloudKitStaffSetupPolicy.canonicalID(recordID),
              StaffWorkspaceOperationalCommandPolicy.isOperationsField(kind: recordKind, field: fieldName) else {
            throw StaffReplicaDeliveryError.invalid
        }
        let commandKeyPrefix = "full-staff-content-command-v1\n" + context.scope.key + "\n" + plan.id.uuidString.lowercased()
        let lock = try SharedTimeMutationGate.begin(commandKeyPrefix)
        defer { SharedTimeMutationGate.finish(commandKeyPrefix, id: lock) }
        if let commandID {
            let originals = try StaffWorkspaceOperationalCommandStore.listPending(store: dependencies.store, scope: context.scope, plan: plan.id)
            if let original = try StaffWorkspaceOperationalCommandStore.load(store: dependencies.store, scope: context.scope,
                    plan: plan.id, commandID: commandID.uuidString.lowercased()) ?? originals.first(where: { $0.request.commandID == commandID.uuidString.lowercased() }) {
                guard original.request.recordKind == recordKind, original.request.recordID == recordID,
                      original.request.fieldName == fieldName, original.request.value == value else { throw StaffReplicaDeliveryError.changed }
                return try await sendOriginalOperationalCommand(original.request, plan: plan, context: context)
            }
        }
        let view = try StaffWorkspaceOperationalAcceptanceStore.accept(
            store: dependencies.store, scope: context.scope, plan: plan.id,
            check: { try self.staffCheck(context, plan) })
        let candidate = try StaffWorkspaceOperationalCommandStore.candidates(from: view)
            .first { $0.recordKind == recordKind && $0.recordID == recordID && $0.fieldName == fieldName }
        guard let candidate else { throw StaffReplicaDeliveryError.invalid }
        if candidate.revision < 1 { throw StaffReplicaDeliveryError.changed }
        let id = commandID ?? dependencies.operation()
        let request = try StaffWorkspaceOperationalCommandRequest(
            companyID: view.companyID, environment: view.environment, replicaID: view.replicaID,
            commandID: id, selectionID: view.selectionID, sourceSequence: view.sourceSequence,
            contentSHA256: view.contentSHA256, candidate: candidate, value: value)
        return try await sendOriginalOperationalCommand(request, plan: plan, context: context)
    }

    func fieldEditorSnapshot(plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context,
                             selectionID: String, sourceSequence: Int, contentSHA256: String,
                             kind: String, recordID: String, revision: Int, field: String) throws -> StaffWorkspaceFieldEditorSnapshot {
        try staffCheck(context, plan)
        guard [AppUserRole.admin.rawValue, AppUserRole.dispatcher.rawValue, AppUserRole.fieldTechnician.rawValue].contains(context.member.role) else {
            throw StaffReplicaDeliveryError.access
        }
        let view = try acceptMountedOperationalView(plan: plan, context: context)
        guard view.selectionID == selectionID, view.sourceSequence == sourceSequence, view.contentSHA256 == contentSHA256,
              view.replicaID == plan.replicaID.uuidString.lowercased(),
              let candidate = try StaffWorkspaceOperationalCommandStore.candidates(from: view).first(where: {
                  $0.recordKind == kind && $0.recordID == recordID && $0.fieldName == field && $0.revision == revision
              }) else { throw StaffReplicaDeliveryError.changed }
        return .init(scope: context.scope, planID: plan.id, selectionID: selectionID, sourceSequence: sourceSequence,
                     contentSHA256: contentSHA256, candidate: candidate)
    }

    private func fieldEditorAccess(_ snapshot: StaffWorkspaceFieldEditorSnapshot, plan: CloudKitStaffSharePlan,
                                   context: CloudKitStaffSetupController.Context) throws {
        try staffCheck(context, plan)
        guard snapshot.scope == context.scope, snapshot.planID == plan.id,
              [AppUserRole.admin.rawValue, AppUserRole.dispatcher.rawValue, AppUserRole.fieldTechnician.rawValue].contains(context.member.role),
              CloudKitStaffSetupPolicy.canonicalID(snapshot.candidate.recordID),
              StaffWorkspaceOperationalCommandPolicy.isOperationsField(kind: snapshot.candidate.recordKind, field: snapshot.candidate.fieldName) else {
            throw StaffReplicaDeliveryError.access
        }
    }

    func fieldEditorHistory(_ snapshot: StaffWorkspaceFieldEditorSnapshot, plan: CloudKitStaffSharePlan,
                            context: CloudKitStaffSetupController.Context) throws -> [StaffWorkspaceOperationalCommandJournal] {
        try fieldEditorAccess(snapshot, plan: plan, context: context)
        let c = snapshot.candidate
        let history = try StaffWorkspaceFieldEditorStore.history(store: dependencies.store, scope: context.scope,
            plan: plan, kind: c.recordKind, recordID: c.recordID, field: c.fieldName)
        try staffCheck(context, plan)
        return history
    }

    /// Three bounded metadata reads for display freshness only. Opening, review,
    /// submission and content consumers retain full payload validation.
    func fieldEditorHead(_ snapshot: StaffWorkspaceFieldEditorSnapshot, plan: CloudKitStaffSharePlan,
                         context: CloudKitStaffSetupController.Context) throws -> StaffWorkspaceFieldEditorHead {
        try fieldEditorAccess(snapshot, plan: plan, context: context)
        guard let mount = try StaffWorkspaceOperationalMountStore.peekMetadata(store: dependencies.store, scope: context.scope, plan: plan.id),
              let accepted = try StaffWorkspaceOperationalAcceptanceStore.load(store: dependencies.store, scope: context.scope, plan: plan.id) else {
            throw StaffReplicaDeliveryError.pending
        }
        try accepted.validate(scope: context.scope, plan: plan.id, mount: mount)
        guard try StaffWorkspaceOperationalMountStore.peekMetadata(store: dependencies.store, scope: context.scope, plan: plan.id) == mount else {
            throw StaffReplicaDeliveryError.changed
        }
        try staffCheck(context, plan)
        return .init(mount: mount)
    }

    func fieldEditorDraft(_ snapshot: StaffWorkspaceFieldEditorSnapshot, plan: CloudKitStaffSharePlan,
                          context: CloudKitStaffSetupController.Context) throws -> StaffWorkspaceFieldDraft? {
        try fieldEditorAccess(snapshot, plan: plan, context: context)
        let draft = try StaffWorkspaceFieldDraftStore.load(store: dependencies.store, snapshot: snapshot, plan: plan)
        try staffCheck(context, plan)
        return draft
    }

    /// Serialized compare-and-swap protects two editor windows and late saves.
    /// Existing drafts may retain an old head; only an explicit review adopts a new one.
    func saveFieldEditorDraft(_ next: StaffWorkspaceFieldDraft, expected: StaffWorkspaceFieldDraft?,
                              reviewing: Bool, plan: CloudKitStaffSharePlan,
                              context: CloudKitStaffSetupController.Context) throws -> StaffWorkspaceFieldDraft {
        try staffCheck(context, plan); try next.validate(plan: plan)
        let key = "full-staff-content-command-v1\n" + context.scope.key + "\n" + plan.id.uuidString.lowercased()
        let lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        let previous = try fieldEditorDraft(next.snapshot, plan: plan, context: context)
        if previous == next { try staffCheck(context, plan); return next }
        guard previous == expected else { throw StaffReplicaDeliveryError.changed }
        if let previous, previous.commandID == next.commandID {
            guard previous.input != nil, previous.snapshot == next.snapshot, previous.initial == next.initial else {
                throw StaffReplicaDeliveryError.changed
            }
            if next.input != nil {
                // Keystrokes need only the original-ID lock, not every historical
                // receipt for this field. Keep the interrupted write-ahead fallback.
                let id = next.commandID.uuidString.lowercased()
                let original = try StaffWorkspaceOperationalCommandStore.load(store: dependencies.store,
                    scope: context.scope, plan: plan.id, commandID: id) ??
                    StaffWorkspaceOperationalCommandStore.listPending(store: dependencies.store, scope: context.scope, plan: plan.id)
                        .first(where: { $0.request.commandID == id })
                guard original == nil else { throw StaffReplicaDeliveryError.changed }
            }
        } else {
            let history = try fieldEditorHistory(next.snapshot, plan: plan, context: context)
            guard next.input != nil, !history.contains(where: { $0.state == "pending" }) else { throw StaffReplicaDeliveryError.changed }
            if let previous, previous.input != nil,
               !history.contains(where: { $0.request.commandID == previous.commandID.uuidString.lowercased() }) {
                guard reviewing, next.input == previous.input else { throw StaffReplicaDeliveryError.changed }
            }
            let s = next.snapshot, c = s.candidate
            let current = try fieldEditorSnapshot(plan: plan, context: context, selectionID: s.selectionID,
                sourceSequence: s.sourceSequence, contentSHA256: s.contentSHA256, kind: c.recordKind,
                recordID: c.recordID, revision: c.revision, field: c.fieldName)
            guard current == s else { throw StaffReplicaDeliveryError.changed }
        }
        try StaffWorkspaceFieldDraftStore.write(store: dependencies.store, next: next, expected: expected,
            plan: plan, check: { try self.staffCheck(context, plan) })
        return next
    }

    /// Commit locally before any network await. A stale editor must be reviewed,
    /// not rebased. An interrupted queue write is recovered through the original index.
    func queueFieldEditorUpdate(_ snapshot: StaffWorkspaceFieldEditorSnapshot, plan: CloudKitStaffSharePlan,
                                context: CloudKitStaffSetupController.Context, commandID: UUID,
                                value: StaffWorkspaceValue) throws -> StaffWorkspaceOperationalCommandJournal {
        try staffCheck(context, plan)
        guard snapshot.scope == context.scope, snapshot.planID == plan.id else { throw StaffReplicaDeliveryError.access }
        let key = "full-staff-content-command-v1\n" + context.scope.key + "\n" + plan.id.uuidString.lowercased()
        let lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        let request = try snapshot.request(plan: plan, commandID: commandID, value: value)
        let history = try fieldEditorHistory(snapshot, plan: plan, context: context)
        if let original = history.first(where: { $0.request.commandID == request.commandID }) {
            guard original.request == request else { throw StaffReplicaDeliveryError.changed }
            try StaffWorkspaceFieldEditorStore.remember(store: dependencies.store, scope: context.scope, plan: plan,
                original: original, check: { try self.staffCheck(context, plan) })
            return original
        }
        if let draft = try fieldEditorDraft(snapshot, plan: plan, context: context) {
            guard draft.commandID == commandID, draft.snapshot == snapshot, let input = draft.input,
                  let schema = StaffWorkspaceModelCatalog.all.first(where: { $0.kind == request.recordKind })?.fieldSchema[request.fieldName],
                  try input.value(schema: schema) == value else { throw StaffReplicaDeliveryError.changed }
        }
        guard !history.contains(where: { $0.state == "pending" }), !snapshot.alreadySubmitted(value, history: history), value != snapshot.candidate.currentValue else {
            throw StaffReplicaDeliveryError.changed
        }
        let c = snapshot.candidate
        let current = try fieldEditorSnapshot(plan: plan, context: context, selectionID: snapshot.selectionID,
            sourceSequence: snapshot.sourceSequence, contentSHA256: snapshot.contentSHA256, kind: c.recordKind,
            recordID: c.recordID, revision: c.revision, field: c.fieldName)
        guard current == snapshot else { throw StaffReplicaDeliveryError.changed }
        let original = try StaffWorkspaceOperationalCommandStore.enqueue(store: dependencies.store, scope: context.scope,
            plan: plan.id, request: request, check: { try self.staffCheck(context, plan) })
        try StaffWorkspaceFieldEditorStore.remember(store: dependencies.store, scope: context.scope, plan: plan,
            original: original, check: { try self.staffCheck(context, plan) })
        return original
    }

    /// Only an already durable original may use this retry, even if its mounted
    /// selection has advanced. It cannot create a new command from UI parameters.
    func sendFieldEditorUpdate(_ original: StaffWorkspaceOperationalCommandJournal, plan: CloudKitStaffSharePlan,
                               context: CloudKitStaffSetupController.Context) async throws -> StaffWorkspaceOperationalCommandJournal {
        try staffCheck(context, plan); try original.validate(scope: context.scope, plan: plan.id)
        guard [AppUserRole.admin.rawValue, AppUserRole.dispatcher.rawValue, AppUserRole.fieldTechnician.rawValue].contains(context.member.role) else {
            throw StaffReplicaDeliveryError.access
        }
        let key = "full-staff-content-command-v1\n" + context.scope.key + "\n" + plan.id.uuidString.lowercased()
        let lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        try StaffWorkspaceFieldEditorStore.remember(store: dependencies.store, scope: context.scope, plan: plan,
            original: original, check: { try self.staffCheck(context, plan) })
        return try await sendOriginalOperationalCommand(original.request, plan: plan, context: context)
    }

    /// Retries the saved request, never reconstructing it from a newer mount.
    private func sendOriginalOperationalCommand(_ request: StaffWorkspaceOperationalCommandRequest,
        plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context) async throws -> StaffWorkspaceOperationalCommandJournal {
        try staffCheck(context, plan)
        try request.validate()
        guard request.replicaID == plan.replicaID.uuidString.lowercased(),
              [AppUserRole.admin.rawValue, AppUserRole.dispatcher.rawValue, AppUserRole.fieldTechnician.rawValue].contains(context.member.role)
        else { throw StaffReplicaDeliveryError.access }
        let pending = try StaffWorkspaceOperationalCommandStore.enqueue(
            store: dependencies.store, scope: context.scope, plan: plan.id, request: request,
            check: { try self.staffCheck(context, plan) })
        if pending.state == "recorded" { return pending }
        // Recover the field's discoverability pointer before receipt recovery can
        // remove its original from the global pending index (including background retries).
        try StaffWorkspaceFieldEditorStore.remember(store: dependencies.store, scope: context.scope, plan: plan,
            original: pending, check: { try self.staffCheck(context, plan) })
        guard let staffCommandRequest = dependencies.staffCommandRequest else { throw StaffReplicaDeliveryError.unavailable }
        let path = StaffWorkspaceContentHTTPPolicy.root(plan) + "/" + request.selectionID + "/content/commands"
        let body = try StaffWorkspacePublicationContract.encode(request)
        guard StaffWorkspaceContentHTTPPolicy.allows(path: path, method: "POST", body: body),
              body.count <= 8192 else {
            throw StaffReplicaDeliveryError.invalid
        }
        try staffCheck(context, plan)
        let receiptBytes = try await staffCommandRequest(path, body)
        try staffCheck(context, plan)
        let receipt = try StaffWorkspacePublicationContract.decode(
            StaffWorkspaceOperationalCommandReceipt.self, from: receiptBytes, maximum: 32 * 1024)
        let journal = try StaffWorkspaceOperationalCommandStore.attachReceipt(
            store: dependencies.store, scope: context.scope, plan: plan.id,
            request: request, receipt: receipt,
            check: { try self.staffCheck(context, plan) })
        guard journal.operationalWorkspaceReady == false, journal.state == "recorded" else {
            throw StaffReplicaDeliveryError.storage
        }
        return journal
    }

    /// One bounded pass; a rejected or offline original remains discoverable
    /// and does not starve unrelated lost-receipt recoveries behind it.
    @discardableResult
    func recoverOperationalCommands(plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context,
                                    maximum: Int = 16) async throws -> StaffWorkspaceCommandRecoverySummary {
        try staffCheck(context, plan)
        guard (1...128).contains(maximum) else { throw StaffReplicaDeliveryError.invalid }
        let key = "full-staff-content-command-v1\n" + context.scope.key + "\n" + plan.id.uuidString.lowercased()
        let lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        let originals = try StaffWorkspaceOperationalCommandStore.listPending(store: dependencies.store, scope: context.scope, plan: plan.id)
        let cursorKey = key + "\nrecovery-cursor-v1"
        var ordered = originals
        if originals.count > maximum, let bytes = try dependencies.store.read(cursorKey) {
            let cursor = try StaffWorkspacePublicationContract.decode(StaffWorkspaceCommandRecoveryCursor.self, from: bytes, maximum: 8192)
            guard cursor.version == 1, cursor.scope == context.scope, cursor.planID == plan.id,
                  CloudKitStaffSetupPolicy.canonicalID(cursor.lastAttemptedID) else { throw StaffReplicaDeliveryError.storage }
            ordered = originals.filter { $0.request.commandID > cursor.lastAttemptedID }
                + originals.filter { $0.request.commandID <= cursor.lastAttemptedID }
        }
        let batch = Array(ordered.prefix(maximum))
        var recovered = 0
        for original in batch {
            do {
                _ = try await sendOriginalOperationalCommand(original.request, plan: plan, context: context)
                recovered += 1
            } catch {
                // Never hide sign-out/account changes or send another request
                // after them. Other failures retain this exact intent.
                try staffCheck(context, plan)
            }
        }
        try staffCheck(context, plan)
        if originals.count > maximum, let last = batch.last {
            let cursor = StaffWorkspaceCommandRecoveryCursor(version: 1, scope: context.scope, planID: plan.id,
                                                             lastAttemptedID: last.request.commandID)
            try dependencies.store.write(cursorKey, StaffWorkspacePublicationContract.encode(cursor))
            try staffCheck(context, plan)
        }
        let remaining = try StaffWorkspaceOperationalCommandStore.listPending(store: dependencies.store, scope: context.scope, plan: plan.id).count
        return .init(recorded: recovered, pending: remaining)
    }

    /// Staff-scoped ModelContext import adapters from an accepted operational view.
    /// Requires durable mount + acceptance bound to selection/content/sequence.
    /// Journals `staff-workspace-operational-import-v1` without flipping
    /// `operationalWorkspaceReady`, rewriting mount bytes, or activating a full staff store.
    @discardableResult
    func importAcceptedOperationalModels(plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context,
                                         selectionID: String? = nil) throws -> StaffWorkspaceOperationalImportPlan {
        try staffCheck(context, plan)
        let importKey = StaffWorkspaceOperationalImportStore.key(context.scope, plan.id)
        let lock = try SharedTimeMutationGate.begin(importKey)
        defer { SharedTimeMutationGate.finish(importKey, id: lock) }
        let imported = try StaffWorkspaceOperationalImportStore.importAccepted(
            store: dependencies.store, scope: context.scope, plan: plan.id,
            selectionID: selectionID, check: { try self.staffCheck(context, plan) })
        guard imported.operationalWorkspaceReady == false else { throw StaffReplicaDeliveryError.storage }
        return imported
    }

    /// Rebuild the staff-scoped import plan from the durable import journal + current
    /// accepted mount head, or nil when no import journal exists.
    func loadImportedOperationalModels(plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context) throws
    -> StaffWorkspaceOperationalImportPlan? {
        try staffCheck(context, plan)
        return try StaffWorkspaceOperationalImportStore.loadPlan(
            store: dependencies.store, scope: context.scope, plan: plan.id,
            check: { try self.staffCheck(context, plan) })
    }

    /// Discover original submissions across selections, including legacy recorded
    /// originals no longer present in the local pending index. Never rewrites them.
    func readFieldUpdates(plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context,
                          after: String? = nil, commandID: String? = nil) async throws -> StaffWorkspaceFieldUpdatesPage {
        try staffCheck(context, plan)
        guard [AppUserRole.admin.rawValue, AppUserRole.dispatcher.rawValue, AppUserRole.fieldTechnician.rawValue].contains(context.member.role),
              let read = dependencies.staffFieldUpdatesRequest else { throw StaffReplicaDeliveryError.access }
        let path = StaffWorkspaceFieldUpdatesHTTPPolicy.path(plan: plan, scope: context.scope, after: after, commandID: commandID)
        guard StaffWorkspaceFieldUpdatesHTTPPolicy.allows(path: path, method: "GET", body: nil) else { throw StaffReplicaDeliveryError.invalid }
        let bytes = try await read(path)
        try staffCheck(context, plan)
        let page = try StaffWorkspacePublicationContract.decode(StaffWorkspaceFieldUpdatesPage.self, from: bytes,
            maximum: StaffWorkspaceFieldUpdatesPage.maximumBytes)
        try page.validate(scope: context.scope, plan: plan, after: after, commandID: commandID)
        for entry in page.entries {
            if let original = try StaffWorkspaceOperationalCommandStore.load(store: dependencies.store,
                scope: context.scope, plan: plan.id, commandID: entry.id) {
                guard original.request == entry.request, original.receipt == nil || original.receipt == entry.receipt else {
                    throw StaffReplicaDeliveryError.changed
                }
            }
        }
        try staffCheck(context, plan)
        return page
    }

    /// OPERATIONS-policy write against an imported plan: records command intent only
    /// via `submitOperationalCommand`. Never mutates mounted content bytes and never
    /// flips `operationalWorkspaceReady`.
    @discardableResult
    func submitImportedOperationalWrite(plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context,
                                        recordKind: String, recordID: String, fieldName: String,
                                        value: StaffWorkspaceValue, commandID: UUID? = nil) async throws
    -> StaffWorkspaceOperationalCommandJournal {
        try staffCheck(context, plan)
        let imported = try StaffWorkspaceOperationalImportStore.importAccepted(
            store: dependencies.store, scope: context.scope, plan: plan.id,
            check: { try self.staffCheck(context, plan) })
        let id = commandID ?? dependencies.operation()
        _ = try StaffWorkspaceOperationalImportWriteAdapter.commandIntent(
            plan: imported, recordKind: recordKind, recordID: recordID, fieldName: fieldName,
            value: value, commandID: id)
        let journal = try await submitOperationalCommand(
            plan: plan, context: context, recordKind: recordKind, recordID: recordID,
            fieldName: fieldName, value: value, commandID: id)
        guard journal.operationalWorkspaceReady == false else { throw StaffReplicaDeliveryError.storage }
        return journal
    }

    /// Activate a dedicated live SwiftData staff projection store from an imported
    /// operational plan (`staff-workspace-operational-store-v1`). In-memory
    /// ModelContainer + durable activation journal. Never flips
    /// `operationalWorkspaceReady`, never calls owner `ModelCodec.make`, and never
    /// rewrites mount bytes.
    @discardableResult
    func activateImportedOperationalStore(plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context)
    throws -> StaffWorkspaceOperationalActivatedStore {
        try staffCheck(context, plan)
        let storeKey = StaffWorkspaceOperationalStoreActivator.key(context.scope, plan.id)
        let lock = try SharedTimeMutationGate.begin(storeKey)
        defer { SharedTimeMutationGate.finish(storeKey, id: lock) }
        let activated = try StaffWorkspaceOperationalStoreActivator.activate(
            store: dependencies.store, scope: context.scope, planID: plan.id,
            check: { try self.staffCheck(context, plan) })
        guard activated.journal.operationalWorkspaceReady == false,
              activated.journal.state == "activated" else {
            throw StaffReplicaDeliveryError.storage
        }
        return activated
    }

    /// Rebuild a live dedicated staff projection container from the durable
    /// activation journal + current import plan, or nil when not activated.
    func loadActivatedOperationalStore(plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context)
    throws -> StaffWorkspaceOperationalActivatedStore? {
        try staffCheck(context, plan)
        guard let activated = try StaffWorkspaceOperationalStoreActivator.loadActivated(
            store: dependencies.store, scope: context.scope, planID: plan.id,
            check: { try self.staffCheck(context, plan) }) else { return nil }
        guard activated.journal.operationalWorkspaceReady == false else {
            throw StaffReplicaDeliveryError.storage
        }
        return activated
    }

    /// Independent-account CloudKit convergence proof (`staff-workspace-operational-convergence-v1`).
    /// Reads participantHead via participantCloudIO, requires an activated store, matches
    /// selection/content/sequence/sealed digests against the mount, and journals the proof.
    /// Never flips `operationalWorkspaceReady`.
    @discardableResult
    func proveIndependentCloudKitConvergence(plan: CloudKitStaffSharePlan,
                                             context: CloudKitStaffSetupController.Context,
                                             invitation: URL? = nil) async throws
    -> StaffWorkspaceOperationalConvergenceJournal {
        guard let participantCloudIO = dependencies.participantCloudIO else {
            throw StaffReplicaDeliveryError.unavailable
        }
        try staffCheck(context, plan)
        let resolved = invitation ?? dependencies.invitationURL?(plan, context)
        guard let resolved, CloudKitStaffSetupPolicy.invitationURL(resolved) else {
            throw StaffReplicaDeliveryError.access
        }
        let convergenceKey = StaffWorkspaceOperationalConvergenceStore.key(context.scope, plan.id)
        let lock = try SharedTimeMutationGate.begin(convergenceKey)
        defer { SharedTimeMutationGate.finish(convergenceKey, id: lock) }
        let authorize: CloudKitStaffRemote.Authorize = { try self.staffCheck(context, plan) }
        let io = try await participantCloudIO(plan, context, resolved, authorize)
        try StaffWorkspaceOperationalConvergenceStore.requireParticipantZone(io, plan: plan)
        guard let head = try await StaffWorkspaceCloudTransfer.participantHead(
            plan: plan, workspace: context.workspace, io: io, now: dependencies.now()) else {
            throw StaffReplicaDeliveryError.pending
        }
        _ = try await authorizeStaffHead(head, plan: plan, context: context)
        guard try await StaffWorkspaceCloudTransfer.participantHead(plan: plan, workspace: context.workspace,
            io: io, now: dependencies.now()) == head else { throw StaffReplicaDeliveryError.superseded }
        let journal = try StaffWorkspaceOperationalConvergenceStore.prove(
            head: head, plan: plan, participantAccountHash: context.account.accountHash,
            zoneName: plan.zoneName, store: dependencies.store, scope: context.scope,
            planID: plan.id, check: { try self.staffCheck(context, plan) })
        guard journal.operationalWorkspaceReady == false, journal.state == "converged" else {
            throw StaffReplicaDeliveryError.storage
        }
        return journal
    }

    /// Reload the durable independent-account CloudKit convergence journal, or nil.
    func loadIndependentCloudKitConvergence(plan: CloudKitStaffSharePlan,
                                            context: CloudKitStaffSetupController.Context) throws
    -> StaffWorkspaceOperationalConvergenceJournal? {
        try staffCheck(context, plan)
        guard let journal = try StaffWorkspaceOperationalConvergenceStore.load(
            store: dependencies.store, scope: context.scope, plan: plan.id) else { return nil }
        guard journal.operationalWorkspaceReady == false else {
            throw StaffReplicaDeliveryError.storage
        }
        return journal
    }

    /// Fail-closed local operational-workspace ready flip
    /// (`staff-workspace-operational-ready-v1`). If the convergence journal is
    /// missing, prove independent-account CloudKit convergence first, then
    /// journal ready under SharedTimeMutationGate. Prior intermediate journals
    /// stay `operationalWorkspaceReady == false`; only the ready journal is true.
    @discardableResult
    func markOperationalWorkspaceReady(plan: CloudKitStaffSharePlan,
                                       context: CloudKitStaffSetupController.Context,
                                       invitation: URL? = nil) async throws
    -> StaffWorkspaceOperationalReadyJournal {
        try staffCheck(context, plan)
        _ = try await proveIndependentCloudKitConvergence(plan: plan, context: context, invitation: invitation)
        let readyKey = StaffWorkspaceOperationalReadyStore.key(context.scope, plan.id)
        let lock = try SharedTimeMutationGate.begin(readyKey)
        defer { SharedTimeMutationGate.finish(readyKey, id: lock) }
        let journal = try StaffWorkspaceOperationalReadyStore.markReady(
            plan: plan, store: dependencies.store, scope: context.scope, planID: plan.id,
            check: { try self.staffCheck(context, plan) })
        guard journal.operationalWorkspaceReady == true, journal.state == "ready" else {
            throw StaffReplicaDeliveryError.storage
        }
        return journal
    }

    /// Reload the durable operational-workspace ready journal, or nil.
    func loadOperationalWorkspaceReady(plan: CloudKitStaffSharePlan,
                                       context: CloudKitStaffSetupController.Context) throws
    -> StaffWorkspaceOperationalReadyJournal? {
        try staffCheck(context, plan)
        guard let journal = try StaffWorkspaceOperationalReadyStore.load(
            store: dependencies.store, scope: context.scope, plan: plan.id) else { return nil }
        guard journal.operationalWorkspaceReady == true, journal.state == "ready" else {
            throw StaffReplicaDeliveryError.storage
        }
        return journal
    }

    /// Return the activated dedicated staff projection store only when a ready
    /// journal authorizes the flip and digests match. Staff UI may attach the
    /// ModelContainer from this handle.
    func loadReadyOperationalStore(plan: CloudKitStaffSharePlan,
                                   context: CloudKitStaffSetupController.Context) throws
    -> StaffWorkspaceOperationalActivatedStore? {
        try staffCheck(context, plan)
        guard let ready = try StaffWorkspaceOperationalReadyStore.load(
            store: dependencies.store, scope: context.scope, plan: plan.id) else { return nil }
        guard ready.operationalWorkspaceReady == true, ready.state == "ready" else {
            throw StaffReplicaDeliveryError.storage
        }
        guard let activated = try StaffWorkspaceOperationalStoreActivator.loadActivated(
            store: dependencies.store, scope: context.scope, planID: plan.id,
            check: { try self.staffCheck(context, plan) }) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard activated.journal.selectionID == ready.selectionID,
              activated.journal.contentSHA256 == ready.contentSHA256,
              activated.journal.sourceSequence == ready.sourceSequence,
              activated.plan.selectionID == ready.selectionID,
              activated.plan.contentSHA256 == ready.contentSHA256,
              activated.plan.sourceSequence == ready.sourceSequence,
              activated.journal.operationalWorkspaceReady == false,
              activated.plan.operationalWorkspaceReady == false else {
            throw StaffReplicaDeliveryError.changed
        }
        return activated
    }

    /// Fail-closed staff projection host attach (`staff-workspace-operational-host-v1`).
    /// Requires a ready-v1 journal + matching activated store digests. Journals
    /// `state=hosted` under SharedTimeMutationGate. Never unlocks the owner
    /// ModelContainer, never calls owner `ModelCodec.make`, never rewrites mount bytes.
    @discardableResult
    func openOperationalHost(plan: CloudKitStaffSharePlan,
                             context: CloudKitStaffSetupController.Context) throws
    -> StaffWorkspaceOperationalHostedStore {
        try staffCheck(context, plan)
        let hostKey = StaffWorkspaceOperationalHostStore.key(context.scope, plan.id)
        let lock = try SharedTimeMutationGate.begin(hostKey)
        defer { SharedTimeMutationGate.finish(hostKey, id: lock) }
        let hosted = try StaffWorkspaceOperationalHostStore.open(
            plan: plan, store: dependencies.store, scope: context.scope, planID: plan.id,
            check: { try self.staffCheck(context, plan) })
        guard hosted.journal.operationalWorkspaceReady == true,
              hosted.journal.state == "hosted" else {
            throw StaffReplicaDeliveryError.storage
        }
        return hosted
    }

    /// Reload a hosted staff projection handle from the durable host journal, or nil.
    func loadOperationalHost(plan: CloudKitStaffSharePlan,
                             context: CloudKitStaffSetupController.Context) throws
    -> StaffWorkspaceOperationalHostedStore? {
        try staffCheck(context, plan)
        guard let hosted = try StaffWorkspaceOperationalHostStore.load(
            plan: plan, store: dependencies.store, scope: context.scope, planID: plan.id,
            check: { try self.staffCheck(context, plan) }) else { return nil }
        guard hosted.journal.operationalWorkspaceReady == true,
              hosted.journal.state == "hosted" else {
            throw StaffReplicaDeliveryError.storage
        }
        return hosted
    }

    /// Fail-closed staff projection identity bind
    /// (`staff-workspace-operational-identity-v1`). Requires an already-open
    /// host-v1 journal + matching digests, signed participant account, and a
    /// 64-hex device fingerprint. Journals under SharedTimeMutationGate with
    /// `operationalWorkspaceReady = false`.
    @discardableResult
    func bindOperationalIdentity(plan: CloudKitStaffSharePlan,
                                 context: CloudKitStaffSetupController.Context,
                                 deviceFingerprint: String,
                                 hosted: StaffWorkspaceOperationalHostedStore? = nil) throws
    -> StaffWorkspaceOperationalIdentityJournal {
        try staffCheck(context, plan)
        let identityKey = StaffWorkspaceOperationalIdentityStore.key(context.scope, plan.id)
        let lock = try SharedTimeMutationGate.begin(identityKey)
        defer { SharedTimeMutationGate.finish(identityKey, id: lock) }
        let journal = try StaffWorkspaceOperationalIdentityStore.bind(
            plan: plan, store: dependencies.store, scope: context.scope, planID: plan.id,
            account: context.account, deviceFingerprint: deviceFingerprint, hosted: hosted,
            check: { try self.staffCheck(context, plan) })
        guard journal.operationalWorkspaceReady == false, journal.state == "bound" else {
            throw StaffReplicaDeliveryError.storage
        }
        return journal
    }

    /// Complete the actual receive-to-screen handoff. Never authorize a new
    /// snapshot using an older ready/host/identity journal's state flag alone.
    func openReceivedOperationalWorkspace(plan: CloudKitStaffSharePlan,
        context: CloudKitStaffSetupController.Context, invitation: URL,
        selectionID: String, deviceFingerprint: String,
        previous: StaffWorkspaceOperationalSession? = nil) async throws -> StaffWorkspaceOperationalSession {
        try staffCheck(context, plan)
        guard CloudKitStaffSetupPolicy.canonicalID(selectionID),
              JobBillingAssignmentSnapshot.validConnectionRevision(deviceFingerprint) else {
            throw StaffReplicaDeliveryError.invalid
        }
        let key = "full-staff-open-v1\n" + context.scope.key + "\n" + plan.id.uuidString.lowercased()
        let lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        _ = try acceptMountedOperationalView(plan: plan, context: context, selectionID: selectionID)
        _ = try importAcceptedOperationalModels(plan: plan, context: context, selectionID: selectionID)
        let cached = previous.flatMap { $0.hosted.journal.selectionID == selectionID ? $0 : nil }
        if let cached {
            try cached.validate(plan: plan, context: context, selectionID: selectionID, deviceFingerprint: deviceFingerprint)
            guard try StaffWorkspaceOperationalStoreActivator.loadJournal(store: dependencies.store,
                scope: context.scope, plan: plan.id) == cached.hosted.activated.journal else {
                throw StaffReplicaDeliveryError.changed
            }
        } else {
            _ = try activateImportedOperationalStore(plan: plan, context: context)
        }
        // Includes fresh server authority and independent participant-head checks,
        // even when retaining an unchanged screen's existing ModelContainer.
        _ = try await markOperationalWorkspaceReady(plan: plan, context: context, invitation: invitation)
        try staffCheck(context, plan)
        let result: StaffWorkspaceOperationalSession
        if let cached {
            guard try loadOperationalIdentity(plan: plan, context: context) == cached.identity,
                  try StaffWorkspaceOperationalHostStore.loadJournal(store: dependencies.store,
                    scope: context.scope, plan: plan.id) == cached.hosted.journal else {
                throw StaffReplicaDeliveryError.changed
            }
            result = cached
        } else {
            let hosted = try openOperationalHost(plan: plan, context: context)
            let identity = try bindOperationalIdentity(plan: plan, context: context,
                deviceFingerprint: deviceFingerprint, hosted: hosted)
            result = .init(hosted: hosted, identity: identity)
        }
        try staffCheck(context, plan)
        try result.validate(plan: plan, context: context, selectionID: selectionID, deviceFingerprint: deviceFingerprint)
        guard let mount = try StaffWorkspaceOperationalMountStore.peekMetadata(store: dependencies.store,
            scope: context.scope, plan: plan.id), mount.selectionID == selectionID,
              mount.contentSHA256 == result.hosted.journal.contentSHA256,
              mount.sealedSHA256 == result.hosted.journal.sealedSHA256,
              mount.sourceSequence == result.hosted.journal.sourceSequence else {
            throw StaffReplicaDeliveryError.changed
        }
        return result
    }

    /// Reload the durable operational identity journal, or nil.
    func loadOperationalIdentity(plan: CloudKitStaffSharePlan,
                                 context: CloudKitStaffSetupController.Context) throws
    -> StaffWorkspaceOperationalIdentityJournal? {
        try staffCheck(context, plan)
        guard let journal = try StaffWorkspaceOperationalIdentityStore.load(
            store: dependencies.store, scope: context.scope, plan: plan.id) else { return nil }
        guard journal.operationalWorkspaceReady == false, journal.state == "bound" else {
            throw StaffReplicaDeliveryError.storage
        }
        return journal
    }

    private func authorizeStaffHead(_ head: StaffWorkspaceCloudSealManifest, plan: CloudKitStaffSharePlan,
                                    context: CloudKitStaffSetupController.Context) async throws -> StaffWorkspaceCloudSealResponse {
        try staffCheck(context, plan)
        guard let operation = UUID(uuidString: head.selectionID) else { throw StaffReplicaDeliveryError.invalid }
        let request = StaffWorkspaceSelectionRequest(plan: plan, sequence: head.sourceSequence, operation: operation)
        try request.validate(plan)
        let bytes = try await staffHTTP(StaffWorkspaceCloudTransfer.cloudKeyPath(plan: plan, request: request), context: context, plan: plan)
        let seal = try StaffWorkspacePublicationContract.decode(StaffWorkspaceCloudSealResponse.self, from: bytes, maximum: 8192)
        try seal.content.validate(plan: plan, workspace: context.workspace, selection: head.selectionID,
            selectionDigest: head.selectionSHA256, sequence: head.sourceSequence, now: dependencies.now())
        try seal.validate(against: seal.content)
        guard try StaffWorkspaceCloudSealManifest(content: seal.content, sealedSHA256: seal.sealedSHA256,
            sealedBytes: seal.sealedBytes) == head else { throw StaffReplicaDeliveryError.changed }
        return seal
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
            if try await member(plan, source: source, published: published, context: context) {
                result.prepared += 1
                let journal = try load(Self.key(source.scope, plan.id), source: source, plan: plan.id)
                if journal.cloudPublishedOperation != nil { result.cloudPublished += 1 }
            } else { result.hasMore = true }
        }
        return result
    }
}
