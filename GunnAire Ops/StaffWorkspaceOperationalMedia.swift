import Foundation

/// Authenticated media access for staff operational attachment content.
///
/// Attachment IDs, unavailable links, Drive/QBO fields, and device-local paths
/// are never capability by themselves. Authorization requires an accepted
/// operational mount plus an explicit non-null `backendDocumentID` (and, when
/// talking to HTTP, a staff-capable media grant). This does not flip
/// `operationalWorkspaceReady` and is not ModelContext import or command path.
struct StaffWorkspaceOperationalMediaCandidate: Equatable {
    let attachmentID: String
    let kindRaw: String
    let displayName: String
    let contentType: String
    let fileSizeBytes: Int
    /// Present only when company storage prepared media; nil means no access.
    let backendDocumentID: String?
}

struct StaffWorkspaceOperationalMediaGrant: Codable, Equatable {
    static let schema = "staff-workspace-operational-media-v1"
    let schema: String
    let scope: CloudKitStaffSetupScope
    let planID: UUID
    let selectionID: String
    let sourceSequence: Int
    let contentSHA256: String
    let attachmentID: String
    let backendDocumentID: String
    let contentType: String
    let fileSizeBytes: Int
    let displayName: String
    let kindRaw: String
    let state: String
    let operationalWorkspaceReady: Bool

    init(scope: CloudKitStaffSetupScope, planID: UUID, selectionID: String, sourceSequence: Int,
         contentSHA256: String, attachmentID: String, backendDocumentID: String, contentType: String,
         fileSizeBytes: Int, displayName: String, kindRaw: String) throws {
        guard CloudKitStaffSetupPolicy.canonicalID(selectionID),
              CloudKitStaffSetupPolicy.canonicalID(attachmentID),
              (1...2_147_483_647).contains(sourceSequence),
              JobBillingAssignmentSnapshot.validConnectionRevision(contentSHA256),
              Self.validDocumentID(backendDocumentID),
              Self.validContentType(contentType),
              (1...64 * 1024 * 1024).contains(fileSizeBytes),
              Self.validDisplayName(displayName),
              Self.validKindRaw(kindRaw) else {
            throw StaffReplicaDeliveryError.invalid
        }
        schema = Self.schema
        self.scope = scope
        self.planID = planID
        self.selectionID = selectionID
        self.sourceSequence = sourceSequence
        self.contentSHA256 = contentSHA256
        self.attachmentID = attachmentID
        self.backendDocumentID = backendDocumentID
        self.contentType = contentType
        self.fileSizeBytes = fileSizeBytes
        self.displayName = displayName
        self.kindRaw = kindRaw
        state = "authorized"
        operationalWorkspaceReady = false
    }

    func validate(scope: CloudKitStaffSetupScope, plan: UUID, acceptance: StaffWorkspaceOperationalAcceptance,
                  candidate: StaffWorkspaceOperationalMediaCandidate) throws {
        guard schema == Self.schema, state == "authorized", !operationalWorkspaceReady,
              self.scope == scope, planID == plan,
              selectionID == acceptance.selectionID, sourceSequence == acceptance.sourceSequence,
              contentSHA256 == acceptance.contentSHA256,
              attachmentID == candidate.attachmentID,
              backendDocumentID == candidate.backendDocumentID,
              contentType == candidate.contentType, fileSizeBytes == candidate.fileSizeBytes,
              displayName == candidate.displayName, kindRaw == candidate.kindRaw else {
            throw StaffReplicaDeliveryError.storage
        }
    }

    static func validDocumentID(_ value: String) -> Bool {
        validHeaderText(value, maximum: 128)
            && !value.contains("/") && !value.contains("\\") && !value.contains("..")
    }

    static func validContentType(_ value: String) -> Bool {
        validHeaderText(value, maximum: 128)
            && value.range(of: "^[A-Za-z0-9!#$%&'*+.^_`|~-]+/[A-Za-z0-9!#$%&'*+.^_`|~-]+$", options: .regularExpression) != nil
    }

    static func validDisplayName(_ value: String) -> Bool {
        validHeaderText(value, maximum: 255)
            && !value.contains("/") && !value.contains("\\") && !value.hasPrefix(".")
    }

    static func validKindRaw(_ value: String) -> Bool {
        validHeaderText(value, maximum: 64)
    }

    private static func validHeaderText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }
}

/// HTTP grant body from `GET .../content/media` (staff-capable). Same schema as
/// the durable journal without local scope/plan — bound by selection + digest.
struct StaffWorkspaceOperationalMediaHTTPGrant: Codable, Equatable {
    let schema: String
    let selectionID: String
    let sourceSequence: Int
    let contentSHA256: String
    let attachmentID: String
    let backendDocumentID: String
    let contentType: String
    let fileSizeBytes: Int
    let displayName: String
    let kindRaw: String
    let operationalWorkspaceReady: Bool

    func validate(against candidate: StaffWorkspaceOperationalMediaCandidate,
                  acceptance: StaffWorkspaceOperationalAcceptance) throws {
        guard schema == StaffWorkspaceOperationalMediaGrant.schema, !operationalWorkspaceReady,
              selectionID == acceptance.selectionID, sourceSequence == acceptance.sourceSequence,
              contentSHA256 == acceptance.contentSHA256,
              attachmentID == candidate.attachmentID,
              backendDocumentID == candidate.backendDocumentID,
              contentType == candidate.contentType, fileSizeBytes == candidate.fileSizeBytes,
              displayName == candidate.displayName, kindRaw == candidate.kindRaw,
              StaffWorkspaceOperationalMediaGrant.validDocumentID(backendDocumentID) else {
            throw StaffReplicaDeliveryError.invalid
        }
    }
}

enum StaffWorkspaceOperationalMediaStore {
    static func key(_ scope: CloudKitStaffSetupScope, _ plan: UUID, attachmentID: String) -> String {
        "full-staff-content-media-v1\n" + scope.key + "\n" + plan.uuidString.lowercased()
            + "\n" + attachmentID.lowercased()
    }

    /// Enumerate attachment media candidates from an accepted read-only view.
    /// Never invents backendDocumentID; null remains explicit unavailability.
    static func candidates(from view: StaffWorkspaceOperationalView) throws -> [StaffWorkspaceOperationalMediaCandidate] {
        var result: [StaffWorkspaceOperationalMediaCandidate] = []
        var seen = Set<String>()
        for record in view.records where record.kind == "attachment" {
            guard seen.insert(record.id).inserted else { throw StaffReplicaDeliveryError.invalid }
            guard case let .operational(partition) = record.body else { throw StaffReplicaDeliveryError.invalid }
            // Drive / QBO / sync links must never become media capability.
            let forbiddenCapability = [
                "googleDriveWebViewLink", "googleDriveFileID", "quickBooksAttachableID", "localFilePath",
            ]
            guard forbiddenCapability.allSatisfy({ partition.fields[$0] == nil }) else {
                throw StaffReplicaDeliveryError.invalid
            }
            let kindRaw = try text(partition.fields["kindRaw"], required: true)
            let displayName = try text(partition.fields["displayName"], required: true)
            let contentType = try text(partition.fields["contentType"], required: true)
            let fileSizeBytes = try integer(partition.fields["fileSizeBytes"], required: true)
            let backendDocumentID = try optionalText(partition.fields["backendDocumentID"])
            guard let kindRaw, let displayName, let contentType, let fileSizeBytes,
                  StaffWorkspaceOperationalMediaGrant.validKindRaw(kindRaw),
                  StaffWorkspaceOperationalMediaGrant.validDisplayName(displayName),
                  StaffWorkspaceOperationalMediaGrant.validContentType(contentType),
                  (1...64 * 1024 * 1024).contains(fileSizeBytes) else {
                throw StaffReplicaDeliveryError.invalid
            }
            if let backendDocumentID {
                guard StaffWorkspaceOperationalMediaGrant.validDocumentID(backendDocumentID) else {
                    throw StaffReplicaDeliveryError.invalid
                }
            }
            result.append(.init(attachmentID: record.id, kindRaw: kindRaw, displayName: displayName,
                                contentType: contentType, fileSizeBytes: fileSizeBytes,
                                backendDocumentID: backendDocumentID))
        }
        return result.sorted { $0.attachmentID < $1.attachmentID }
    }

    static func load(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID,
                     attachmentID: String) throws -> StaffWorkspaceOperationalMediaGrant? {
        do {
            guard let bytes = try store.read(key(scope, plan, attachmentID: attachmentID)) else { return nil }
            guard bytes.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
            let grant = try StaffWorkspacePublicationContract.decode(StaffWorkspaceOperationalMediaGrant.self,
                                                                     from: bytes, maximum: 8192)
            guard grant.schema == StaffWorkspaceOperationalMediaGrant.schema, grant.state == "authorized",
                  !grant.operationalWorkspaceReady, grant.scope == scope, grant.planID == plan,
                  grant.attachmentID == attachmentID else {
                throw StaffReplicaDeliveryError.storage
            }
            return grant
        } catch let error as StaffReplicaDeliveryError {
            throw error
        } catch {
            throw StaffReplicaDeliveryError.storage
        }
    }

    /// Authorize one attachment after acceptance. Without a non-null
    /// `backendDocumentID`, IDs alone fail closed (`pending`). Optional HTTP
    /// grant must match the local candidate and acceptance digest.
    @discardableResult
    static func authorize(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID,
                          attachmentID: String, httpGrant: StaffWorkspaceOperationalMediaHTTPGrant? = nil,
                          check: () throws -> Void = {}) throws -> StaffWorkspaceOperationalMediaGrant {
        try check()
        guard let acceptance = try StaffWorkspaceOperationalAcceptanceStore.load(store: store, scope: scope, plan: plan),
              let (mount, payload) = try StaffWorkspaceOperationalMountStore.load(store: store, scope: scope, plan: plan) else {
            throw StaffReplicaDeliveryError.pending
        }
        try acceptance.validate(scope: scope, plan: plan, mount: mount)
        guard payload.count == mount.contentBytes,
              StaffReplicaManifest.hash(payload) == mount.contentSHA256 else {
            throw StaffReplicaDeliveryError.changed
        }
        let view = try StaffWorkspaceOperationalAcceptanceStore.parse(opened: payload, mount: mount)
        guard view.selectionID == acceptance.selectionID,
              view.contentSHA256 == acceptance.contentSHA256,
              view.sourceSequence == acceptance.sourceSequence else {
            throw StaffReplicaDeliveryError.changed
        }
        let candidate = try candidates(from: view).first { $0.attachmentID == attachmentID }
        guard let candidate else { throw StaffReplicaDeliveryError.invalid }
        guard let documentID = candidate.backendDocumentID else {
            // Explicit: selection/index IDs grant no media access by themselves.
            throw StaffReplicaDeliveryError.pending
        }
        if let httpGrant {
            try httpGrant.validate(against: candidate, acceptance: acceptance)
        }
        try check()
        let next = try StaffWorkspaceOperationalMediaGrant(
            scope: scope, planID: plan, selectionID: acceptance.selectionID,
            sourceSequence: acceptance.sourceSequence, contentSHA256: acceptance.contentSHA256,
            attachmentID: candidate.attachmentID, backendDocumentID: documentID,
            contentType: candidate.contentType, fileSizeBytes: candidate.fileSizeBytes,
            displayName: candidate.displayName, kindRaw: candidate.kindRaw)
        if let existing = try load(store: store, scope: scope, plan: plan, attachmentID: attachmentID) {
            if existing == next {
                try existing.validate(scope: scope, plan: plan, acceptance: acceptance, candidate: candidate)
                return existing
            }
        }
        try check()
        let encoded = try StaffWorkspacePublicationContract.encode(next)
        guard encoded.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
        try store.write(key(scope, plan, attachmentID: attachmentID), encoded)
        try check()
        guard let confirmed = try load(store: store, scope: scope, plan: plan, attachmentID: attachmentID),
              confirmed == next else {
            throw StaffReplicaDeliveryError.storage
        }
        try confirmed.validate(scope: scope, plan: plan, acceptance: acceptance, candidate: candidate)
        return confirmed
    }

    /// Write authorized bytes into a fresh sandbox URL. Size must match the grant;
    /// never reuses owner localFilePath or provider URLs.
    static func openSandbox(grant: StaffWorkspaceOperationalMediaGrant, bytes: Data,
                            directory: URL, check: () throws -> Void = {}) throws -> URL {
        try check()
        guard grant.state == "authorized", !grant.operationalWorkspaceReady,
              bytes.count == grant.fileSizeBytes,
              bytes.count <= 64 * 1024 * 1024 else {
            throw StaffReplicaDeliveryError.changed
        }
        let folder = directory.appendingPathComponent("StaffOperationalMedia-v1", isDirectory: true)
            .appendingPathComponent(grant.planID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(grant.attachmentID.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent(grant.displayName, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try bytes.write(to: destination, options: [.atomic])
        try check()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = destination
        try mutable.setResourceValues(values)
        guard FileManager.default.fileExists(atPath: destination.path),
              let confirmed = try? Data(contentsOf: destination), confirmed.count == grant.fileSizeBytes else {
            throw StaffReplicaDeliveryError.storage
        }
        return destination
    }

    private static func text(_ value: StaffWorkspaceValue?, required: Bool) throws -> String? {
        switch value {
        case .none:
            if required { throw StaffReplicaDeliveryError.invalid }
            return nil
        case .some(.text(let text)):
            return text
        case .some(.null):
            if required { throw StaffReplicaDeliveryError.invalid }
            return nil
        default:
            throw StaffReplicaDeliveryError.invalid
        }
    }

    private static func optionalText(_ value: StaffWorkspaceValue?) throws -> String? {
        switch value {
        case .none, .some(.null):
            return nil
        case .some(.text(let text)):
            return text
        default:
            throw StaffReplicaDeliveryError.invalid
        }
    }

    private static func integer(_ value: StaffWorkspaceValue?, required: Bool) throws -> Int? {
        switch value {
        case .none:
            if required { throw StaffReplicaDeliveryError.invalid }
            return nil
        case .some(.integer(let number)):
            return number
        case .some(.null):
            if required { throw StaffReplicaDeliveryError.invalid }
            return nil
        default:
            throw StaffReplicaDeliveryError.invalid
        }
    }
}
