import Foundation
import Combine
import CloudKit

struct CloudKitStaffSetupDependencies {
    let stamp: () -> CloudKitStaffSetupStamp?
    let account: () async throws -> CompanyCloudKitAccount
    let request: (String, String, Data?) async throws -> Data
    let store: SharedTimeLocalStore
    let remote: CloudKitStaffRemote
    var now: () -> Date = Date.init
    static var live: Self {
        .init(stamp: { .current }, account: { try await CompanyCloudKitRuntimeAccount.current() },
              request: { try await GunnAireBackendService.staffCloudKitSetupRequest(path: $0, method: $1, body: $2) },
              store: CloudKitStaffSetupStorage.device, remote: .live)
    }
}

/// Setup deliberately has no ModelContext, owner-store lease or business-data
/// bypass. Server membership and Apple's sharing permission remain independent.
@MainActor final class CloudKitStaffSetupController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var error: CloudKitStaffSharingError?
    @Published private(set) var plans: [CloudKitStaffSharePlan] = []
    @Published private(set) var journal: CloudKitStaffSetupJournal?
    @Published private(set) var context: Context?
    let dependencies: CloudKitStaffSetupDependencies

    struct Context {
        let stamp: CloudKitStaffSetupStamp
        let workspace: CompanyWorkspaceIdentity
        let member: BackendAppUserRecord
        let account: CompanyCloudKitAccount
        var scope: CloudKitStaffSetupScope {
            .init(origin: stamp.session.backendOrigin, company: workspace.companyID, email: stamp.session.email,
                  environment: account.environment, accountHash: account.accountHash)
        }
        var ownerAdministrator: Bool {
            member.role == AppUserRole.admin.rawValue && workspace.binding(for: account.environment)?.cloudAccountHash == account.accountHash
        }
        func owns(_ plan: CloudKitStaffSharePlan) -> Bool {
            plan.memberEmail == member.email && plan.participantAccountHash == account.accountHash
        }
    }

    init(dependencies: CloudKitStaffSetupDependencies? = nil) { self.dependencies = dependencies ?? .live }
    var needsRecovery: Bool { journal?.pending != nil || journal?.lastCloudOperation != nil }
    var canEnroll: Bool {
        guard let context, !needsRecovery, !busy,
              context.account.accountHash != context.workspace.binding(for: context.account.environment)?.cloudAccountHash else { return false }
        return !plans.contains { $0.memberEmail == context.member.email && $0.state != "revoked" }
    }
    var visiblePlans: [CloudKitStaffSharePlan] {
        guard let context else { return [] }
        return plans.filter { context.ownerAdministrator || $0.memberEmail == context.member.email }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func checkLifetime() {
        guard let context, dependencies.stamp() != context.stamp || dependencies.now() >= context.stamp.session.expiresAt else { return }
        self.context = nil; plans = []; journal = nil; error = .changed
    }
    private func check(_ stamp: CloudKitStaffSetupStamp) throws {
        guard !Task.isCancelled, dependencies.stamp() == stamp, dependencies.now() < stamp.session.expiresAt else {
            throw CloudKitStaffSharingError.changed
        }
    }
    private func request<T: Decodable>(_ path: String, _ stamp: CloudKitStaffSetupStamp,
                                       method: String = "GET", body: Data? = nil) async throws -> T {
        try check(stamp)
        guard CloudKitStaffSetupPolicy.allows(path: path, method: method, bytes: body?.count) else { throw CloudKitStaffSharingError.invalid }
        let bytes = try await dependencies.request(path, method, body)
        try check(stamp)
        guard bytes.count <= 512 * 1024 else { throw CloudKitStaffSharingError.invalid }
        return try JSONDecoder().decode(T.self, from: bytes)
    }
    private func authority(_ stamp: CloudKitStaffSetupStamp, prior: Context? = nil) async throws -> Context {
        try check(stamp)
        let account = try await dependencies.account()
        try check(stamp)
        let result: BackendCompanyWorkspaceResponse = try await request("/api/workspace", stamp)
        guard result.user.email == stamp.session.email, SharedTimeError.validEmail(result.user.email), result.user.isActive,
              AppUserRole(rawValue: result.user.role) != nil,
              result.workspace.binding(for: account.environment) != nil,
              let name = account.recordName, (1...255).contains(name.utf8.count), name != CKCurrentUserDefaultName,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              CloudKitStaffSharePlan.accountHash(recordName: name, environment: account.environment) == account.accountHash
        else { throw CloudKitStaffSharingError.access }
        let value = Context(stamp: stamp, workspace: result.workspace, member: result.user, account: account)
        if let prior {
            guard value.scope == prior.scope, value.member.role == prior.member.role,
                  value.workspace.binding(for: account.environment) == prior.workspace.binding(for: account.environment) else {
                throw CloudKitStaffSharingError.changed
            }
        }
        return value
    }

    func refresh() async {
        guard !busy else { return }
        busy = true; error = nil
        context = nil; plans = []; journal = nil
        defer { busy = false }
        do {
            guard let stamp = dependencies.stamp() else { throw CloudKitStaffSharingError.access }
            let context = try await authority(stamp)
            try CloudKitStaffSetupLocks.acquire(context.scope.key)
            defer { CloudKitStaffSetupLocks.release(context.scope.key) }
            let saved = try load(context)
            let values = try await list(context)
            try check(stamp)
            for old in saved.originalPlans {
                guard let current = values.first(where: { $0.id == old.id }) else { throw CloudKitStaffSharingError.review }
                try current.validateSuccessor(of: old, workspace: context.workspace, now: dependencies.now())
            }
            self.context = context; journal = saved; plans = values
        } catch { self.error = CloudKitStaffSetupPolicy.safe(error) }
    }

    private func list(_ context: Context) async throws -> [CloudKitStaffSharePlan] {
        var values: [CloudKitStaffSharePlan] = [], ids: Set<UUID> = [], zones: Set<String> = [], cursors: Set<UUID> = [], cursor: UUID?
        repeat {
            let page: CloudKitStaffShareList = try await request(CloudKitStaffSetupPolicy.query(company: context.workspace.companyID,
                environment: context.account.environment, after: cursor), context.stamp)
            guard page.shares.count <= 50, values.count + page.shares.count <= 5000,
                  page.nextCursor == nil || (page.shares.count == 50 && page.shares.last?.id == page.nextCursor) else { throw CloudKitStaffSharingError.invalid }
            var previous = cursor?.uuidString.lowercased() ?? ""
            for plan in page.shares {
                try plan.validate(workspace: context.workspace, now: dependencies.now())
                guard plan.environment == context.account.environment, ids.insert(plan.id).inserted, zones.insert(plan.zoneName).inserted,
                      plan.id.uuidString.lowercased() > previous,
                      context.member.role == "Admin" || plan.memberEmail == context.member.email else { throw CloudKitStaffSharingError.invalid }
                previous = plan.id.uuidString.lowercased(); values.append(plan)
            }
            cursor = page.nextCursor
            if let cursor, !cursors.insert(cursor).inserted { throw CloudKitStaffSharingError.invalid }
        } while cursor != nil
        let active = values.filter { $0.state != "revoked" }.map(\.memberEmail)
        guard Set(active).count == active.count else { throw CloudKitStaffSharingError.invalid }
        return values
    }

    private func load(_ context: Context) throws -> CloudKitStaffSetupJournal {
        guard let bytes = try dependencies.store.read(context.scope.key) else { return .init(scope: context.scope) }
        do {
            guard bytes.count <= 64 * 1024 else { throw CloudKitStaffSharingError.storage }
            let saved = try JSONDecoder().decode(CloudKitStaffSetupJournal.self, from: bytes)
            try saved.validate(context: context, now: dependencies.now())
            return saved
        } catch { throw CloudKitStaffSharingError.storage }
    }
    private func save(_ saved: CloudKitStaffSetupJournal, _ context: Context) throws {
        try check(context.stamp)
        try saved.validate(context: context, now: dependencies.now())
        let bytes = try JSONEncoder().encode(saved)
        guard bytes.count <= 64 * 1024 else { throw CloudKitStaffSharingError.storage }
        try dependencies.store.write(context.scope.key, bytes)
        journal = saved
    }
    private func read(_ old: CloudKitStaffSharePlan, _ context: Context, ownerAuthority: Bool = false) async throws -> CloudKitStaffSharePlan {
        let current: CloudKitStaffSharePlan = try await request(CloudKitStaffSetupPolicy.query(company: context.workspace.companyID,
            environment: context.account.environment, id: old.id, ownerAuthority: ownerAuthority), context.stamp)
        try current.validateSuccessor(of: old, workspace: context.workspace, now: dependencies.now())
        return current
    }
    private func authorize(_ plan: CloudKitStaffSharePlan, _ context: Context) async throws {
        _ = try await authority(context.stamp, prior: context)
        guard try await read(plan, context, ownerAuthority: context.ownerAdministrator) == plan else { throw CloudKitStaffSharingError.changed }
    }
    private func perform(_ action: (Context) async throws -> Void) async {
        guard !busy, let context else { return }
        busy = true; error = nil
        defer { busy = false; checkLifetime() }
        do {
            try CloudKitStaffSetupLocks.acquire(context.scope.key)
            defer { CloudKitStaffSetupLocks.release(context.scope.key) }
            _ = try await authority(context.stamp, prior: context)
            // Another window may have advanced the original journal.
            journal = try load(context)
            try await action(context)
        } catch { self.error = CloudKitStaffSetupPolicy.safe(error) }
    }
    private func select(_ id: UUID, _ context: Context) async throws -> CloudKitStaffSharePlan {
        guard !needsRecovery, let old = plans.first(where: { $0.id == id }) else { throw CloudKitStaffSharingError.review }
        let plan = try await read(old, context)
        guard plan == old else { update(plan); throw CloudKitStaffSharingError.changed }
        return plan
    }
    private func update(_ plan: CloudKitStaffSharePlan) {
        if let index = plans.firstIndex(where: { $0.id == plan.id }) { plans[index] = plan }
        else { plans.append(plan) }
    }

    func enroll(confirmed: Bool) async {
        guard confirmed else { return }
        await perform { context in
            guard !self.needsRecovery else { throw CloudKitStaffSharingError.review }
            self.plans = try await self.list(context)
            guard context.account.accountHash != context.workspace.binding(for: context.account.environment)?.cloudAccountHash,
                  !self.plans.contains(where: { $0.memberEmail == context.member.email && $0.state != "revoked" }),
                  let name = context.account.recordName else { throw CloudKitStaffSharingError.review }
            let operation = UUID()
            let body = CloudKitStaffSetupBody(companyID: context.workspace.companyID.uuidString.lowercased(), environment: context.account.environment,
                operationID: operation.uuidString.lowercased(), participantAccountHash: context.account.accountHash, participantRecordName: name)
            var saved = CloudKitStaffSetupJournal(scope: context.scope)
            saved.pending = .init(operationID: operation, shareID: nil, action: "enroll", body: try JSONEncoder().encode(body))
            try self.save(saved, context)
            try await self.submit(context)
        }
    }

    func approve(_ id: UUID, confirmed: Bool) async { await transition(id, action: "approve", confirmed: confirmed) }
    func revoke(_ id: UUID, confirmed: Bool) async { await transition(id, action: "revoke", confirmed: confirmed) }
    private func transition(_ id: UUID, action: String, confirmed: Bool) async {
        guard confirmed else { return }
        await perform { context in
            let plan = try await self.select(id, context)
            if action == "approve" {
                guard context.ownerAdministrator, plan.state == "requested", !plan.reviewRequired,
                      plan.participantIdentityAvailable == true else { throw CloudKitStaffSharingError.review }
            } else {
                guard plan.state != "revoked", context.ownerAdministrator || plan.memberEmail == context.member.email else { throw CloudKitStaffSharingError.access }
            }
            try self.prepare(plan, action: action, context)
            try await self.submit(context)
        }
    }
    private func prepare(_ plan: CloudKitStaffSharePlan, action: String, _ context: Context) throws {
        var saved = journal ?? .init(scope: context.scope)
        guard saved.pending == nil else { throw CloudKitStaffSharingError.review }
        if saved.originalPlans.first?.id != plan.id { saved = .init(scope: context.scope) }
        saved.originalPlans = [plan]
        let operation = UUID()
        let body = CloudKitStaffSetupBody.change(plan, action: action, operation: operation)
        saved.pending = .init(operationID: operation, shareID: plan.id, action: action, body: try JSONEncoder().encode(body))
        try save(saved, context)
    }
    private func submit(_ context: Context) async throws {
        guard let pending = journal?.pending else { throw CloudKitStaffSharingError.review }
        let path = CloudKitStaffSetupPolicy.base + (pending.shareID.map { "/\($0.uuidString.lowercased())/\(pending.action)" } ?? "")
        let old = journal?.originalPlans.first
        let current: CloudKitStaffSharePlan
        do { current = try await request(path, context.stamp, method: "POST", body: pending.body) }
        catch {
            // A different device can already have completed or revoked the
            // original action. A fresh read may prove that outcome, never an
            // empty success or permission to create a replacement operation.
            guard case GunnAireBackendError.server(let status, _) = error, status == 409, let old else { throw error }
            let recovered = try await read(old, context)
            guard Self.satisfies(pending.action, plan: recovered) else { throw error }
            current = recovered
        }
        try current.validate(workspace: context.workspace, now: dependencies.now())
        if let old { try current.validateSuccessor(of: old, workspace: context.workspace, now: dependencies.now()) }
        else {
            guard current.id == pending.operationID, current.memberEmail == context.member.email,
                  current.participantAccountHash == context.account.accountHash, current.environment == context.account.environment,
                  current.participantIdentityAvailable == true else { throw CloudKitStaffSharingError.changed }
        }
        guard Self.satisfies(pending.action, plan: current) else { throw CloudKitStaffSharingError.invalid }
        var saved = journal!
        saved.pending = nil; saved.originalPlans = [current]
        saved.lastCloudOperation = nil; saved.lastCloudShareID = nil
        if current.state == "revoked" { saved.invitationURLs = [:] }
        try save(saved, context) // Keep the old request when a reply cannot be saved.
        update(current)
    }
    static func satisfies(_ action: String, plan: CloudKitStaffSharePlan) -> Bool {
        if plan.state == "revoked" { return action != "confirm-cleanup" || !plan.cloudKitRevocationRequired }
        switch action {
        case "enroll": return true
        case "approve": return ["approved", "invited", "accepted"].contains(plan.state)
        case "invite": return ["invited", "accepted"].contains(plan.state)
        case "accept": return plan.state == "accepted"
        default: return false
        }
    }

    func invite(_ id: UUID, confirmed: Bool) async { await cloud(id, action: "invite", url: nil, confirmed: confirmed) }
    func accept(_ id: UUID, url: URL, confirmed: Bool) async { await cloud(id, action: "accept", url: url, confirmed: confirmed) }
    func cleanup(_ id: UUID, confirmed: Bool) async { await cloud(id, action: "cleanup", url: nil, confirmed: confirmed) }
    private func cloud(_ id: UUID, action: String, url: URL?, confirmed: Bool) async {
        guard confirmed else { return }
        await perform { context in
            let plan = try await self.select(id, context)
            try self.cloudPermission(plan, action: action, context)
            var saved = CloudKitStaffSetupJournal(scope: context.scope)
            saved.originalPlans = [plan]; saved.lastCloudOperation = action; saved.lastCloudShareID = plan.id
            if action == "accept" {
                guard let url, CloudKitStaffSetupPolicy.invitationURL(url) else { throw CloudKitStaffSharingError.invalid }
                saved.invitationURLs[plan.id.uuidString.lowercased()] = url
            }
            try self.save(saved, context)
            try await self.continueCloud(plan, action: action, context)
        }
    }
    private func cloudPermission(_ plan: CloudKitStaffSharePlan, action: String, _ context: Context) throws {
        switch action {
        case "invite":
            guard context.ownerAdministrator, ["approved", "invited", "accepted"].contains(plan.state),
                  plan.participantIdentityAvailable == true, !plan.reviewRequired, !plan.cloudKitRevocationRequired else { throw CloudKitStaffSharingError.review }
        case "accept":
            guard context.owns(plan), context.member.role == plan.memberRole, ["invited", "accepted"].contains(plan.state),
                  !plan.reviewRequired, !plan.cloudKitRevocationRequired else { throw CloudKitStaffSharingError.review }
        case "cleanup":
            guard context.ownerAdministrator, plan.state == "revoked", plan.cloudKitRevocationRequired else { throw CloudKitStaffSharingError.review }
        default: throw CloudKitStaffSharingError.invalid
        }
    }
    private func continueCloud(_ plan: CloudKitStaffSharePlan, action: String, _ context: Context) async throws {
        try cloudPermission(plan, action: action, context)
        let authorize: CloudKitStaffRemote.Authorize = { try await self.authorize(plan, context) }
        try await authorize()
        switch action {
        case "invite":
            let identity: CloudKitStaffParticipantIdentity = try await request(CloudKitStaffSetupPolicy.query(company: context.workspace.companyID,
                environment: context.account.environment, id: plan.id, participant: true), context.stamp)
            try identity.validate(plan)
            let url = try await dependencies.remote.invitation(plan, context.workspace, context.account, identity.recordName, authorize)
            try await authorize()
            guard CloudKitStaffSetupPolicy.invitationURL(url) else { throw CloudKitStaffSharingError.invalid }
            var saved = journal!; saved.invitationURLs[plan.id.uuidString.lowercased()] = url
            try save(saved, context)
            if plan.state == "approved" { try prepare(plan, action: "invite", context); try await submit(context) }
            else { try finishCloud(plan, context) }
        case "accept":
            guard let url = journal?.invitationURLs[plan.id.uuidString.lowercased()] else { throw CloudKitStaffSharingError.storage }
            try await dependencies.remote.accept(plan, context.workspace, context.account, context.member, url, authorize)
            try await authorize()
            if plan.state == "invited" { try prepare(plan, action: "accept", context); try await submit(context) }
            else { try finishCloud(plan, context) }
        case "cleanup":
            try await dependencies.remote.cleanup(plan, context.workspace, context.account, authorize)
            try await authorize()
            try prepare(plan, action: "confirm-cleanup", context); try await submit(context)
        default: throw CloudKitStaffSharingError.invalid
        }
    }
    private func finishCloud(_ plan: CloudKitStaffSharePlan, _ context: Context) throws {
        var saved = journal!; saved.originalPlans = [plan]; saved.lastCloudOperation = nil; saved.lastCloudShareID = nil
        try save(saved, context); update(plan)
    }
    func recover() async {
        await perform { context in
            if self.journal?.pending != nil { try await self.submit(context); return }
            guard let old = self.journal?.originalPlans.first, let action = self.journal?.lastCloudOperation else { throw CloudKitStaffSharingError.review }
            let plan = try await self.read(old, context)
            if plan.state == "revoked" && (action != "cleanup" || !plan.cloudKitRevocationRequired) {
                try self.finishCloud(plan, context); return
            }
            try await self.continueCloud(plan, action: action, context)
        }
    }
}

struct CloudKitStaffSetupBody: Codable {
    let companyID: String
    let environment: String
    let operationID: String
    var participantAccountHash: String?
    var participantRecordName: String?
    var expectedRevision: Int?
    var confirmRoleScopedReadOnlySharing: Bool?
    var confirmPrivateReadOnlyCloudKitShare: Bool?
    var confirmLocalCloudKitProof: Bool?
    var confirmBusinessAccessRevocation: Bool?
    var confirmCloudKitAccessRemoved: Bool?
    static func change(_ plan: CloudKitStaffSharePlan, action: String, operation: UUID) -> Self {
        var body = Self(companyID: plan.companyID.uuidString.lowercased(), environment: plan.environment,
                        operationID: operation.uuidString.lowercased(), expectedRevision: plan.revision)
        switch action {
        case "approve": body.confirmRoleScopedReadOnlySharing = true
        case "invite": body.confirmPrivateReadOnlyCloudKitShare = true
        case "accept": body.confirmLocalCloudKitProof = true; body.participantAccountHash = plan.participantAccountHash
        case "revoke": body.confirmBusinessAccessRevocation = true
        case "confirm-cleanup": body.confirmCloudKitAccessRemoved = true
        default: break
        }
        return body
    }
}

extension CloudKitStaffSetupJournal {
    func validate(context: CloudKitStaffSetupController.Context, now: Date) throws {
        guard scope == context.scope, originalPlans.count <= 1, invitationURLs.count <= 1,
              (lastCloudOperation == nil) == (lastCloudShareID == nil) else { throw CloudKitStaffSharingError.storage }
        for plan in originalPlans {
            try plan.validate(workspace: context.workspace, now: now)
            guard plan.environment == scope.environment,
                  context.member.role == "Admin" || plan.memberEmail == scope.email else { throw CloudKitStaffSharingError.storage }
        }
        for (id, url) in invitationURLs {
            guard originalPlans.first?.id.uuidString.lowercased() == id, CloudKitStaffSetupPolicy.invitationURL(url) else { throw CloudKitStaffSharingError.storage }
        }
        if let action = lastCloudOperation {
            guard ["invite", "accept", "cleanup"].contains(action), originalPlans.first?.id == lastCloudShareID,
                  action != "accept" || invitationURLs.count == 1 else { throw CloudKitStaffSharingError.storage }
        }
        if let pending {
            guard pending.body.count <= 8192 else { throw CloudKitStaffSharingError.storage }
            let body = try JSONDecoder().decode(CloudKitStaffSetupBody.self, from: pending.body)
            let expected: CloudKitStaffSetupBody
            if pending.action == "enroll" {
                guard pending.shareID == nil, originalPlans.isEmpty, lastCloudOperation == nil,
                      let name = body.participantRecordName, name == context.account.recordName else { throw CloudKitStaffSharingError.storage }
                expected = .init(companyID: scope.company.uuidString.lowercased(), environment: scope.environment,
                                 operationID: pending.operationID.uuidString.lowercased(), participantAccountHash: scope.accountHash, participantRecordName: name)
            } else {
                guard let plan = originalPlans.first, pending.shareID == plan.id,
                      CloudKitStaffSetupPolicy.actions.contains(pending.action) else { throw CloudKitStaffSharingError.storage }
                expected = .change(plan, action: pending.action, operation: pending.operationID)
            }
            let actual = try JSONSerialization.jsonObject(with: pending.body) as? NSDictionary
            let canonical = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? NSDictionary
            guard actual != nil, actual == canonical else { throw CloudKitStaffSharingError.storage }
        }
    }
}
