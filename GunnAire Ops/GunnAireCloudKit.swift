import Foundation
import SwiftData
import CloudKit
import CoreData
import Combine
import os

/// The private database is the durable SwiftData replica for the company-owned
/// iPad and Mac signed in to the same approved business iCloud account.
/// Company-user authorization remains enforced by the GunnAire backend.
enum GunnAireCloudKit {
    static let containerIdentifier = "iCloud.com.gunnaire.businesssuite"

    enum AccountReadiness: Equatable, Sendable {
        case available
        case unavailable
        case restricted
        case couldNotDetermine

        var isReady: Bool {
            self == .available
        }

        var statusTitle: String {
            switch self {
            case .available:
                "Ready"
            case .unavailable:
                "Sign in required"
            case .restricted:
                "Restricted"
            case .couldNotDetermine:
                "Check required"
            }
        }

        var userFacingDetail: String {
            switch self {
            case .available:
                "This device is signed in to iCloud and can use the GunnAire CloudKit container."
            case .unavailable:
                "Sign in to the approved business iCloud account in Settings, then reopen GunnAire Ops before relying on cross-device continuity."
            case .restricted:
                "iCloud access is restricted on this device. Remove the restriction or use an approved company device before relying on cross-device continuity."
            case .couldNotDetermine:
                "GunnAire Ops could not verify iCloud on this device. Check the network and iCloud account, then refresh this screen."
            }
        }
    }

    static func accountReadiness() async -> AccountReadiness {
        // An unsigned XCTest host has no CloudKit entitlement. Constructing a
        // named CKContainer in that process traps before Swift can catch an
        // error, so mirror the test-store policy and report an indeterminate
        // state without touching CloudKit.
        if usesTestDatabase {
            return .couldNotDetermine
        }
        do {
            switch try await CKContainer(identifier: containerIdentifier).accountStatus() {
            case .available:
                return .available
            case .noAccount:
                return .unavailable
            case .restricted:
                return .restricted
            case .couldNotDetermine, .temporarilyUnavailable:
                return .couldNotDetermine
            @unknown default:
                return .couldNotDetermine
            }
        } catch {
            return .couldNotDetermine
        }
    }

    static var usesTestDatabase: Bool {
        #if DEBUG
        // UI tests run in an unsigned simulator process without the production
        // CloudKit entitlement. This switch is compiled out of release builds.
        let processInfo = ProcessInfo.processInfo
        if processInfo.arguments.contains("-disableCloudKitForTesting") ||
            processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        #endif
        return false
    }

    private static var database: ModelConfiguration.CloudKitDatabase {
        if usesTestDatabase {
            return .none
        }
        return .private(containerIdentifier)
    }

    /// Always uses the signed app's production private database. This is kept
    /// separate so automated tests can prove release configuration without
    /// attempting to attach an unsigned XCTest host to iCloud.
    static func productionModelConfiguration(for schema: Schema) -> ModelConfiguration {
        ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private(containerIdentifier)
        )
    }

    static func modelConfiguration(for schema: Schema) -> ModelConfiguration {
        if usesTestDatabase {
            return ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        }

        #if DEBUG
        if GunnAireCloudKitRoundTripProbe.isRequested {
            return GunnAireCloudKitRoundTripProbe.modelConfiguration(for: schema)
        }
        if GunnAireCloudKitSchemaBootstrap.isRequested {
            return GunnAireCloudKitSchemaBootstrap.modelConfiguration(for: schema)
        }
        #endif

        return productionModelConfiguration(for: schema)
    }
}

enum CloudKitMirroringOperation: String, CaseIterable, Codable, Hashable, Sendable {
    case setup
    case importRecords
    case exportRecords

    var activityDescription: String {
        switch self {
        case .setup:
            "preparing cloud sync"
        case .importRecords:
            "receiving updates"
        case .exportRecords:
            "uploading saved work"
        }
    }

    fileprivate var attentionPriority: Int {
        switch self {
        case .exportRecords: 0
        case .setup: 1
        case .importRecords: 2
        }
    }
}

enum CloudKitMirroringOutcome: Equatable, Sendable {
    case running
    case succeeded
    case failed
}

struct CloudKitMirroringEventSnapshot: Equatable, Sendable {
    let identifier: UUID
    let operation: CloudKitMirroringOperation
    let outcome: CloudKitMirroringOutcome
    let occurredAt: Date

    init(
        identifier: UUID = UUID(),
        operation: CloudKitMirroringOperation,
        outcome: CloudKitMirroringOutcome,
        occurredAt: Date = Date()
    ) {
        self.identifier = identifier
        self.operation = operation
        self.outcome = outcome
        self.occurredAt = occurredAt
    }

    init?(_ event: NSPersistentCloudKitContainer.Event) {
        let operation: CloudKitMirroringOperation
        switch event.type {
        case .setup:
            operation = .setup
        case .import:
            operation = .importRecords
        case .export:
            operation = .exportRecords
        @unknown default:
            return nil
        }

        let outcome: CloudKitMirroringOutcome
        if event.endDate == nil {
            outcome = .running
        } else if event.succeeded {
            outcome = .succeeded
        } else {
            outcome = .failed
        }

        self.init(
            identifier: event.identifier,
            operation: operation,
            outcome: outcome,
            occurredAt: event.endDate ?? event.startDate
        )
    }
}

struct CloudKitMirroringFailure: Codable, Equatable, Sendable {
    let operation: CloudKitMirroringOperation
    let occurredAt: Date

    var title: String {
        switch operation {
        case .setup:
            "Cloud sync setup failed"
        case .importRecords:
            "Cloud updates need attention"
        case .exportRecords:
            "Changes waiting for CloudKit"
        }
    }

    var statusDetail: String {
        switch operation {
        case .setup:
            "CloudKit could not finish preparing this device for cross-device operations."
        case .importRecords:
            "CloudKit could not receive the latest changes from another company device."
        case .exportRecords:
            "CloudKit could not upload the latest work saved on this device."
        }
    }

    var recoveryDetail: String {
        switch operation {
        case .setup:
            "Existing local data was not removed. Confirm this is an approved company device signed in to the business iCloud account, use a stable network, and check again before relying on another device."
        case .importRecords:
            "Keep this app open on a stable network and check again. Do not assume another device's newer schedule, invoice, or job changes are present until this warning clears."
        case .exportRecords:
            "Your work remains saved on this device. Keep the app open on a stable network and check again before signing out, reinstalling, or relying on another device."
        }
    }
}

struct CloudKitMirroringState: Codable, Equatable, Sendable {
    private(set) var runningOperations: Set<CloudKitMirroringOperation> = []
    private(set) var failures: [CloudKitMirroringOperation: CloudKitMirroringFailure] = [:]
    private(set) var latestSuccessAt: [CloudKitMirroringOperation: Date] = [:]

    mutating func apply(_ event: CloudKitMirroringEventSnapshot) {
        switch event.outcome {
        case .running:
            runningOperations.insert(event.operation)
        case .succeeded:
            runningOperations.remove(event.operation)
            failures.removeValue(forKey: event.operation)
            latestSuccessAt[event.operation] = event.occurredAt
        case .failed:
            runningOperations.remove(event.operation)
            failures[event.operation] = CloudKitMirroringFailure(
                operation: event.operation,
                occurredAt: event.occurredAt
            )
        }
    }

    var attentionFailure: CloudKitMirroringFailure? {
        failures.values.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt {
                return lhs.occurredAt > rhs.occurredAt
            }
            return lhs.operation.attentionPriority < rhs.operation.attentionPriority
        }.first
    }

    var needsAttention: Bool {
        attentionFailure != nil
    }

    var operatorStatusDetail: String {
        if let failure = attentionFailure {
            return "\(failure.statusDetail) \(failure.recoveryDetail)"
        }
        if !runningOperations.isEmpty {
            let activities = runningOperations
                .sorted { $0.attentionPriority < $1.attentionPriority }
                .map(\.activityDescription)
            return "CloudKit is \(activities.joined(separator: " and "))."
        }
        if !latestSuccessAt.isEmpty {
            return "The latest observed CloudKit transfer completed successfully."
        }
        return "No CloudKit transfer failure has been reported in this app session."
    }

    /// Failures must survive relaunch so staff cannot mistake a restart for a
    /// successful upload. In-progress operations are intentionally discarded;
    /// they either emit a completion event or are restarted by CloudKit.
    var durableSnapshot: Self {
        var snapshot = self
        snapshot.runningOperations = []
        return snapshot
    }
}

/// Observes the mirroring events emitted by the persistent CloudKit container.
/// The reducer stores no customer data and keeps successful routine sync quiet.
final class GunnAireCloudKitEventMonitor: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "GunnAireOps",
        category: "CloudKitContinuity"
    )

    @Published private(set) var state = CloudKitMirroringState()

    private let notificationCenter: NotificationCenter
    private let userDefaults: UserDefaults
    private let persistenceEnabled: Bool
    private var eventObserver: NSObjectProtocol?
    private var retainedContainer: CKContainer?

    private static let persistedStateKey = "GunnAireCloudKitMirroringStateV1"

    init(
        notificationCenter: NotificationCenter = .default,
        userDefaults: UserDefaults = .standard,
        isEnabled: Bool = !GunnAireCloudKit.usesTestDatabase
    ) {
        self.notificationCenter = notificationCenter
        self.userDefaults = userDefaults
        self.persistenceEnabled = isEnabled
        guard isEnabled else { return }

        if let data = userDefaults.data(forKey: Self.persistedStateKey),
           let restored = try? JSONDecoder().decode(CloudKitMirroringState.self, from: data) {
            state = restored.durableSnapshot
        }

        // Retaining the named container ensures CloudKit posts account-change
        // notifications while SwiftData owns the private-database mirroring.
        retainedContainer = CKContainer(identifier: GunnAireCloudKit.containerIdentifier)
        eventObserver = notificationCenter.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  let snapshot = CloudKitMirroringEventSnapshot(event) else { return }

            if let error = event.error {
                let nsError = error as NSError
                Self.logger.error(
                    "CloudKit \(snapshot.operation.rawValue, privacy: .public) failed: \(nsError.domain, privacy: .public)#\(nsError.code, privacy: .public)"
                )
            }
            self?.record(snapshot)
        }
    }

    deinit {
        if let eventObserver {
            notificationCenter.removeObserver(eventObserver)
        }
    }

    func record(_ event: CloudKitMirroringEventSnapshot) {
        state.apply(event)
        guard persistenceEnabled,
              let data = try? JSONEncoder().encode(state.durableSnapshot) else { return }
        userDefaults.set(data, forKey: Self.persistedStateKey)
    }
}

#if DEBUG
/// A Development-only, privacy-safe signed-device acceptance canary.
///
/// The canary uses one fixed-ID BusinessTask in its own local store. It never
/// opens the normal business store, never contains a customer relationship,
/// and is compiled out of Release builds. Explicit launch arguments make each
/// phase reviewable and allow both a Mac -> iPad create/update/delete round
/// trip and an offline same-record conflict/recovery sequence to be proved
/// without adding another production UI or persistence type. Conflict writes
/// retain fixed, append-only BusinessTaskEvent witnesses so a last-writer-wins
/// task value can never be mistaken for proof that both device edits arrived.
@MainActor
enum GunnAireCloudKitRoundTripProbe {
    enum Mode: String, CaseIterable, Codable, Sendable {
        case create
        case observeCreated
        case update
        case observeUpdated
        case delete
        case observeDeleted
        case seedConflict
        case observeConflictSeed
        case writeConflictA
        case writeConflictB
        case observeConflictConverged
        case resolveConflict
        case observeConflictResolved
        case cleanupConflict
        case observeConflictDeleted
        case purgeLocal

        var launchArgument: String {
            switch self {
            case .create: "-createCloudKitRoundTripCanary"
            case .observeCreated: "-observeCreatedCloudKitRoundTripCanary"
            case .update: "-updateCloudKitRoundTripCanary"
            case .observeUpdated: "-observeUpdatedCloudKitRoundTripCanary"
            case .delete: "-deleteCloudKitRoundTripCanary"
            case .observeDeleted: "-observeDeletedCloudKitRoundTripCanary"
            case .seedConflict: "-seedCloudKitConflictCanary"
            case .observeConflictSeed: "-observeCloudKitConflictSeed"
            case .writeConflictA: "-writeCloudKitConflictA"
            case .writeConflictB: "-writeCloudKitConflictB"
            case .observeConflictConverged: "-observeCloudKitConflictConverged"
            case .resolveConflict: "-resolveCloudKitConflictCanary"
            case .observeConflictResolved: "-observeCloudKitConflictResolved"
            case .cleanupConflict: "-cleanupCloudKitConflictCanary"
            case .observeConflictDeleted: "-observeCloudKitConflictDeleted"
            case .purgeLocal: "-purgeLocalCloudKitRoundTripProbe"
            }
        }
    }

    enum CanaryState: String, Codable, Sendable {
        case absent
        case original
        case updated
        case conflictA
        case conflictB
        case conflictWritePending
        case conflictConverged
        case conflictResolutionPending
        case conflictResolved
        case cleanupPending
        case duplicate
        case unexpected
        case error
    }

    struct ActionResult: Equatable, Sendable {
        let state: CanaryState
        let matchCount: Int
        let actionPerformed: Bool
    }

    private struct Report: Codable {
        let schemaVersion: Int
        let generatedAtUTC: Date
        let applicationBuild: String
        let mode: Mode
        let attempt: Int
        let state: CanaryState
        let matchCount: Int
        let actionPerformed: Bool
        let expectationMet: Bool
        let errorCode: String?
    }

    static let schemaVersion = 2
    static let storeFileName = "GunnAireCloudKitRoundTripProbeV2.store"
    static let reportFileName = "GunnAireCloudKitRoundTripProbeV2.json"
    static let canaryID = UUID(uuidString: "C10DA1A0-0000-4000-8000-000000000001")!
    static let canaryCreationOperationID = UUID(uuidString: "C10DA1A0-0000-4000-8000-000000000002")!
    static let conflictEventAID = UUID(uuidString: "C10DA1A0-0000-4000-8000-000000000003")!
    static let conflictEventAOperationID = UUID(uuidString: "C10DA1A0-0000-4000-8000-000000000004")!
    static let conflictEventBID = UUID(uuidString: "C10DA1A0-0000-4000-8000-000000000005")!
    static let conflictEventBOperationID = UUID(uuidString: "C10DA1A0-0000-4000-8000-000000000006")!
    static let conflictResolutionEventID = UUID(uuidString: "C10DA1A0-0000-4000-8000-000000000007")!
    static let conflictResolutionOperationID = UUID(uuidString: "C10DA1A0-0000-4000-8000-000000000008")!
    static let canaryTitle = "__GUNNAIRE_CLOUDKIT_ROUND_TRIP__"
    static let originalDescription = "__GUNNAIRE_CLOUDKIT_ROUND_TRIP_CREATED__"
    static let updatedDescription = "__GUNNAIRE_CLOUDKIT_ROUND_TRIP_UPDATED__"
    static let conflictADescription = "__GUNNAIRE_CLOUDKIT_CONFLICT_A__"
    static let conflictBDescription = "__GUNNAIRE_CLOUDKIT_CONFLICT_B__"
    static let conflictResolvedDescription = "__GUNNAIRE_CLOUDKIT_CONFLICT_RESOLVED_A_B__"
    static let canaryEmail = "cloudkit-roundtrip@gunnaire.invalid"
    static let canaryDate = Date(timeIntervalSinceReferenceDate: 900_000_000)

    private static let maximumAttempt = 5
    private static let attemptDelays: [TimeInterval] = [0, 2, 5, 10, 20]

    static func requestedModes(processArguments: [String] = ProcessInfo.processInfo.arguments) -> [Mode] {
        Mode.allCases.filter { processArguments.contains($0.launchArgument) }
    }

    static func mode(processArguments: [String] = ProcessInfo.processInfo.arguments) -> Mode? {
        let modes = requestedModes(processArguments: processArguments)
        return modes.count == 1 ? modes[0] : nil
    }

    static var isRequested: Bool {
        !requestedModes().isEmpty
    }

    private static var storeURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(storeFileName)
    }

    private static var reportURL: URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return supportDirectory.appendingPathComponent(reportFileName)
    }

    static func modelConfiguration(for schema: Schema) -> ModelConfiguration {
        if mode() == .purgeLocal || mode() == nil {
            return ModelConfiguration(
                "GunnAireCloudKitRoundTripProbePurge",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        }

        return ModelConfiguration(
            "GunnAireCloudKitRoundTripProbeV2",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .private(GunnAireCloudKit.containerIdentifier)
        )
    }

    static func prepareBeforeContainerIfRequested() throws {
        let modes = requestedModes()
        guard !modes.isEmpty else { return }
        guard modes.count == 1 else {
            throw ProbeError.multipleModes
        }
        guard modes[0] == .purgeLocal else { return }

        let fileManager = FileManager.default
        let storeDirectory = storeURL.deletingLastPathComponent()
        let storeBaseName = storeURL.deletingPathExtension().lastPathComponent
        let exactURLs = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-shm"),
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.deletingPathExtension().path + "_SUPPORT"),
            URL(fileURLWithPath: storeURL.deletingPathExtension().path + "_ckAssets"),
            storeDirectory.appendingPathComponent(".\(storeBaseName)_SUPPORT"),
            storeDirectory.appendingPathComponent(".\(storeBaseName)_ckAssets"),
            reportURL
        ]
        for url in exactURLs where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    static func runIfRequested(in modelContext: ModelContext) throws {
        let modes = requestedModes()
        guard !modes.isEmpty else { return }
        guard modes.count == 1 else {
            throw ProbeError.multipleModes
        }
        let mode = modes[0]
        guard mode != .purgeLocal else { return }

        schedule(mode: mode, in: modelContext)
    }

    private static func schedule(mode: Mode, in modelContext: ModelContext) {
        Task { @MainActor in
            var previousDelay: TimeInterval = 0
            for (index, absoluteDelay) in attemptDelays.enumerated() {
                let incrementalDelay = absoluteDelay - previousDelay
                previousDelay = absoluteDelay
                if incrementalDelay > 0 {
                    try? await Task.sleep(for: .seconds(incrementalDelay))
                }

                do {
                    let result = try apply(mode, in: modelContext)
                    let attempt = index + 1
                    let expectationMet = expectationMet(
                        mode: mode,
                        result: result,
                        attempt: attempt
                    )
                    try writeReport(
                        mode: mode,
                        attempt: attempt,
                        result: result,
                        expectationMet: expectationMet,
                        errorCode: nil
                    )
                    debugLog(
                        "mode=\(mode.rawValue) attempt=\(attempt) state=\(result.state.rawValue) " +
                        "matches=\(result.matchCount) action=\(result.actionPerformed) passed=\(expectationMet)"
                    )
                    if expectationMet { return }
                } catch {
                    let attempt = index + 1
                    try? writeReport(
                        mode: mode,
                        attempt: attempt,
                        result: ActionResult(state: .error, matchCount: 0, actionPerformed: false),
                        expectationMet: false,
                        errorCode: String(describing: error)
                    )
                    debugLog("mode=\(mode.rawValue) attempt=\(attempt) failed: \(String(describing: error))")
                }
            }
        }
    }

    static func apply(
        _ mode: Mode,
        in modelContext: ModelContext,
        now: Date = Date()
    ) throws -> ActionResult {
        guard mode != .purgeLocal else {
            return ActionResult(state: .absent, matchCount: 0, actionPerformed: false)
        }

        var snapshot = try conflictSnapshot(in: modelContext)
        var state = canaryState(snapshot: snapshot)
        guard state != .duplicate else {
            return ActionResult(state: state, matchCount: snapshot.matchCount, actionPerformed: false)
        }

        var actionPerformed = false
        switch mode {
        case .create, .seedConflict:
            if state == .absent {
                modelContext.insert(makeCanary())
                try modelContext.save()
                actionPerformed = true
            }
        case .update:
            if state == .original, let canary = snapshot.canary {
                canary.taskDescription = updatedDescription
                canary.updatedAt = now
                try modelContext.save()
                actionPerformed = true
            }
        case .delete:
            if [.original, .updated].contains(state), let canary = snapshot.canary {
                modelContext.delete(canary)
                try modelContext.save()
                actionPerformed = true
            }
        case .writeConflictA, .writeConflictB:
            let expectedState: CanaryState = mode == .writeConflictA ? .conflictA : .conflictB
            if state == .original, let canary = snapshot.canary,
               let event = makeConflictEvent(for: mode, at: now) {
                canary.taskDescription = mode == .writeConflictA ? conflictADescription : conflictBDescription
                canary.updatedAt = now
                modelContext.insert(event)
                try modelContext.save()
                actionPerformed = true
            } else if state == expectedState {
                // The first save may have completed even if its caller did not
                // observe the response. Keep retries idempotent.
            }
        case .resolveConflict:
            let eventIDs = Set(snapshot.events.map(\.id))
            let convergedIDs = Set([conflictEventAID, conflictEventBID])
            if eventIDs.isSuperset(of: convergedIDs), let canary = snapshot.canary,
               [conflictADescription, conflictBDescription, conflictResolvedDescription]
                .contains(canary.taskDescription ?? "") {
                if canary.taskDescription != conflictResolvedDescription {
                    canary.taskDescription = conflictResolvedDescription
                    canary.updatedAt = now
                    actionPerformed = true
                }
                if !eventIDs.contains(conflictResolutionEventID),
                   let event = makeConflictEvent(for: mode, at: now) {
                    modelContext.insert(event)
                    actionPerformed = true
                }
                try modelContext.save()
            }
        case .cleanupConflict:
            if [.conflictResolved, .cleanupPending].contains(state) {
                if let canary = snapshot.canary {
                    modelContext.delete(canary)
                }
                for event in snapshot.events {
                    modelContext.delete(event)
                }
                try modelContext.save()
                actionPerformed = snapshot.matchCount > 0
            }
        case .observeCreated, .observeUpdated, .observeDeleted,
                .observeConflictSeed, .observeConflictConverged,
                .observeConflictResolved, .observeConflictDeleted:
            break
        case .purgeLocal:
            break
        }

        snapshot = try conflictSnapshot(in: modelContext)
        state = canaryState(snapshot: snapshot)
        return ActionResult(
            state: state,
            matchCount: snapshot.matchCount,
            actionPerformed: actionPerformed
        )
    }

    private struct ConflictSnapshot {
        let canaryMatches: [BusinessTask]
        let events: [BusinessTaskEvent]

        var canary: BusinessTask? { canaryMatches.first }
        var matchCount: Int { canaryMatches.count + events.count }
    }

    private static func conflictSnapshot(in modelContext: ModelContext) throws -> ConflictSnapshot {
        let canaryID = canaryID
        let taskDescriptor = FetchDescriptor<BusinessTask>(
            predicate: #Predicate { $0.id == canaryID }
        )
        let eventDescriptor = FetchDescriptor<BusinessTaskEvent>(
            predicate: #Predicate { $0.taskID == canaryID }
        )
        return ConflictSnapshot(
            canaryMatches: try modelContext.fetch(taskDescriptor),
            events: try modelContext.fetch(eventDescriptor)
        )
    }

    private static func makeCanary() -> BusinessTask {
        BusinessTask(
            id: canaryID,
            creationOperationID: canaryCreationOperationID,
            title: canaryTitle,
            taskDescription: originalDescription,
            priority: .low,
            assignedToEmail: canaryEmail,
            dueAt: canaryDate,
            createdAt: canaryDate,
            createdByEmail: canaryEmail
        )
    }

    static func makeConflictEvent(for mode: Mode, at date: Date = Date()) -> BusinessTaskEvent? {
        let identity: (id: UUID, operationID: UUID, detail: String)
        switch mode {
        case .writeConflictA:
            identity = (conflictEventAID, conflictEventAOperationID, conflictADescription)
        case .writeConflictB:
            identity = (conflictEventBID, conflictEventBOperationID, conflictBDescription)
        case .resolveConflict:
            identity = (conflictResolutionEventID, conflictResolutionOperationID, conflictResolvedDescription)
        default:
            return nil
        }
        return BusinessTaskEvent(
            id: identity.id,
            operationID: identity.operationID,
            taskID: canaryID,
            kind: .updated,
            occurredAt: date,
            actorEmail: canaryEmail,
            detail: identity.detail,
            titleSnapshot: canaryTitle,
            assignedToEmailSnapshot: canaryEmail,
            dueAtSnapshot: canaryDate,
            priority: .low
        )
    }

    private static func canaryState(snapshot: ConflictSnapshot) -> CanaryState {
        guard snapshot.canaryMatches.count <= 1 else { return .duplicate }
        let groupedEvents = Dictionary(grouping: snapshot.events, by: \BusinessTaskEvent.id)
        guard groupedEvents.values.allSatisfy({ $0.count == 1 }) else { return .duplicate }
        let eventsByID = Dictionary(uniqueKeysWithValues: snapshot.events.map { ($0.id, $0) })
        let expectedIDs = Set([conflictEventAID, conflictEventBID, conflictResolutionEventID])
        guard Set(eventsByID.keys).isSubset(of: expectedIDs),
              eventsByID.values.allSatisfy(conflictEventIsValid) else {
            return .unexpected
        }
        guard let canary = snapshot.canary else {
            return snapshot.events.isEmpty ? .absent : .cleanupPending
        }
        guard exactCanaryIdentity(canary) else { return .unexpected }

        let eventIDs = Set(eventsByID.keys)
        if eventIDs.isEmpty {
            if canary.taskDescription == originalDescription { return .original }
            if canary.taskDescription == updatedDescription { return .updated }
            if [conflictADescription, conflictBDescription].contains(canary.taskDescription ?? "") {
                return .conflictWritePending
            }
            if canary.taskDescription == conflictResolvedDescription { return .cleanupPending }
            return .unexpected
        }
        if eventIDs == [conflictEventAID], canary.taskDescription == conflictADescription {
            return .conflictA
        }
        if eventIDs == [conflictEventBID], canary.taskDescription == conflictBDescription {
            return .conflictB
        }
        let convergedIDs = Set([conflictEventAID, conflictEventBID])
        if eventIDs == convergedIDs,
           [conflictADescription, conflictBDescription].contains(canary.taskDescription ?? "") {
            return .conflictConverged
        }
        if eventIDs.isSubset(of: convergedIDs),
           [originalDescription, conflictADescription, conflictBDescription]
            .contains(canary.taskDescription ?? "") {
            return .conflictWritePending
        }
        if eventIDs.isSuperset(of: convergedIDs),
           [conflictADescription, conflictBDescription].contains(canary.taskDescription ?? "") {
            return .conflictResolutionPending
        }
        if eventIDs == expectedIDs, canary.taskDescription == conflictResolvedDescription {
            return .conflictResolved
        }
        if eventIDs.isSubset(of: expectedIDs), canary.taskDescription == conflictResolvedDescription {
            return .cleanupPending
        }
        return .unexpected
    }

    private static func exactCanaryIdentity(_ canary: BusinessTask) -> Bool {
        canary.title == canaryTitle &&
            canary.creationOperationID == canaryCreationOperationID &&
            canary.assignedToEmail == canaryEmail &&
            canary.createdByEmail == canaryEmail
    }

    private static func conflictEventIsValid(_ event: BusinessTaskEvent) -> Bool {
        let expected: (operationID: UUID, detail: String)?
        switch event.id {
        case conflictEventAID:
            expected = (conflictEventAOperationID, conflictADescription)
        case conflictEventBID:
            expected = (conflictEventBOperationID, conflictBDescription)
        case conflictResolutionEventID:
            expected = (conflictResolutionOperationID, conflictResolvedDescription)
        default:
            expected = nil
        }
        guard let expected else { return false }
        return event.operationID == expected.operationID &&
            event.taskID == canaryID &&
            event.kind == .updated &&
            event.actorEmail == canaryEmail &&
            event.detail == expected.detail &&
            event.titleSnapshot == canaryTitle &&
            event.assignedToEmailSnapshot == canaryEmail &&
            event.dueAtSnapshot == canaryDate &&
            event.prioritySnapshot == .low
    }

    private static func expectationMet(
        mode: Mode,
        result: ActionResult,
        attempt: Int
    ) -> Bool {
        switch mode {
        case .create, .observeCreated:
            result.state == .original
        case .update, .observeUpdated:
            result.state == .updated
        case .delete:
            result.state == .absent && (result.actionPerformed || attempt == maximumAttempt)
        case .observeDeleted:
            result.state == .absent && attempt == maximumAttempt
        case .seedConflict, .observeConflictSeed:
            result.state == .original
        case .writeConflictA:
            result.state == .conflictA
        case .writeConflictB:
            result.state == .conflictB
        case .observeConflictConverged:
            result.state == .conflictConverged
        case .resolveConflict, .observeConflictResolved:
            result.state == .conflictResolved
        case .cleanupConflict:
            result.state == .absent && (result.actionPerformed || attempt == maximumAttempt)
        case .observeConflictDeleted:
            result.state == .absent && attempt == maximumAttempt
        case .purgeLocal:
            true
        }
    }

    private static func writeReport(
        mode: Mode,
        attempt: Int,
        result: ActionResult,
        expectationMet: Bool,
        errorCode: String?
    ) throws {
        let report = Report(
            schemaVersion: schemaVersion,
            generatedAtUTC: Date(),
            applicationBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            mode: mode,
            attempt: attempt,
            state: result.state,
            matchCount: result.matchCount,
            actionPerformed: result.actionPerformed,
            expectationMet: expectationMet,
            errorCode: errorCode
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let directory = reportURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: reportURL, options: .atomic)
    }

    private static func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[GunnAireCloudKitRoundTripProbe] \(message)\n".utf8))
    }

    private enum ProbeError: Error {
        case multipleModes
    }
}

/// Development-only tooling for making SwiftData publish every production
/// entity to the CloudKit development schema. SwiftData creates CloudKit
/// record types lazily, so launching an empty store only creates types for
/// entities that are actually saved. This path is never compiled into Release.
@MainActor
enum GunnAireCloudKitSchemaBootstrap {
    static let initializeArgument = "-initializeCloudKitSchema"
    static let cleanupArgument = "-cleanupCloudKitSchemaBootstrap"
    static let schemaVersion = 23

    private static let marker = "__GUNNAIRE_CLOUDKIT_SCHEMA_BOOTSTRAP__"
    private static let bootstrapEmail = "schema-bootstrap@gunnaire.invalid"
    private static let completionKey = "GunnAireCloudKitSchemaBootstrapV\(schemaVersion)"
    static let storeFileName = "GunnAireCloudKitSchemaBootstrapV\(schemaVersion).store"

    static var isRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(initializeArgument) || arguments.contains(cleanupArgument)
    }

    /// Keeps schema publishing and marker cleanup away from the developer's
    /// normal app store. A stale local Debug store must never prevent a newer
    /// CloudKit schema from being initialized or its marker graph removed.
    static func modelConfiguration(for schema: Schema) -> ModelConfiguration {
        ModelConfiguration(
            "GunnAireCloudKitSchemaBootstrapV\(schemaVersion)",
            schema: schema,
            url: FileManager.default.temporaryDirectory.appendingPathComponent(storeFileName),
            allowsSave: true,
            cloudKitDatabase: .private(GunnAireCloudKit.containerIdentifier)
        )
    }

    static func runIfRequested(in modelContext: ModelContext) throws {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(initializeArgument) {
            try initialize(in: modelContext)
        } else if arguments.contains(cleanupArgument) {
            do {
                try cleanup(in: modelContext)
            } catch {
                debugLog("initial cleanup failed: \(String(describing: error))")
                throw error
            }
            scheduleFollowUpCleanup(in: modelContext)
        }
    }

    /// CloudKit can finish its first import after startup cleanup has already
    /// run, temporarily restoring a bootstrap marker from the development
    /// database. Repeat the idempotent marker-only cleanup after that import
    /// window so the corresponding deletions are exported as well.
    private static func scheduleFollowUpCleanup(in modelContext: ModelContext) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            runFollowUpCleanup(in: modelContext, pass: 1)
            try? await Task.sleep(for: .seconds(6))
            runFollowUpCleanup(in: modelContext, pass: 2)
        }
    }

    private static func runFollowUpCleanup(in modelContext: ModelContext, pass: Int) {
        do {
            try cleanup(in: modelContext)
            debugLog("follow-up cleanup pass \(pass) saved")
        } catch {
            debugLog("follow-up cleanup pass \(pass) failed: \(error.localizedDescription)")
        }
    }

    private static func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[GunnAireCloudKitSchemaBootstrap] \(message)\n".utf8))
    }

    private static func initialize(in modelContext: ModelContext) throws {
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return }

        try seedDevelopmentSchema(in: modelContext)
        UserDefaults.standard.set(true, forKey: completionKey)
    }

    /// Keeps the Debug-only CloudKit migration seed directly testable without
    /// changing the process arguments or completion state used by the app.
    static func seedDevelopmentSchemaForTesting(in modelContext: ModelContext) throws {
        try seedDevelopmentSchema(in: modelContext)
    }

    /// Keeps marker cleanup directly testable so bounded model fields cannot
    /// silently strand synthetic records in CloudKit Development.
    static func cleanupDevelopmentSchemaForTesting(in modelContext: ModelContext) throws {
        try cleanup(in: modelContext)
    }

    private static func seedDevelopmentSchema(in modelContext: ModelContext) throws {
        // Versioned bootstraps can be run repeatedly as the shared schema grows.
        // Remove only prior marker records so one migration does not leave a
        // second synthetic company graph in the Development database.
        try cleanup(in: modelContext)

        let now = Date()
        let customer = Customer(
            quickBooksID: "SCHEMA-BOOTSTRAP-CUSTOMER",
            name: marker,
            phone: "000-000-0000",
            email: bootstrapEmail,
            address: "1 Schema Bootstrap Way",
            communicationConsentUpdatedAt: now,
            storedPaymentMethods: [
                StoredPaymentMethodReference(
                    id: "SCHEMA-BOOTSTRAP-PAYMENT-METHOD",
                    providerCustomerID: "SCHEMA-BOOTSTRAP-CUSTOMER",
                    cardBrand: "Test",
                    lastFour: "0000",
                    active: false,
                    updatedAt: now
                )
            ]
        )
        let technician = Technician(
            name: marker,
            contactInfo: bootstrapEmail,
            supportedEquipmentTypes: [.splitSystemAC],
            qualificationNotes: marker,
            serviceAreas: ["Schema Bootstrap"],
            laborCostPerHour: 1,
            quickBooksTimeEntityKind: .employee,
            quickBooksTimeEntityRef: "SCHEMA-BOOTSTRAP"
        )
        let assemblyComponentItem = Item(
            quickBooksID: "SCHEMA-BOOTSTRAP-COMPONENT",
            quickBooksSyncStatus: "synced",
            name: marker,
            itemType: .nonInventory,
            unitPrice: 0,
            purchaseCost: 0,
            itemDescription: marker,
            sku: "SCHEMA-COMPONENT",
            tracksInventory: true,
            reorderPoint: 0,
            defaultInventoryLocation: marker,
            createdAt: now
        )
        let assemblyDefinition = CatalogAssemblyDefinition(
            revision: 1,
            presentation: .flatRate,
            components: [
                CatalogAssemblyComponentDefinition(itemID: assemblyComponentItem.id, quantity: 1)
            ]
        )
        let item = Item(
            quickBooksID: "SCHEMA-BOOTSTRAP-ITEM",
            quickBooksSyncStatus: "synced",
            quickBooksSyncDetail: marker,
            quickBooksLastSyncedAt: now,
            pricebookReviewStatus: .approved,
            pricebookCreatedByEmail: bootstrapEmail,
            pricebookReviewedByEmail: bootstrapEmail,
            pricebookReviewedAt: now,
            name: marker,
            itemType: .service,
            unitPrice: 0,
            purchaseCost: 0,
            itemDescription: marker,
            sku: "SCHEMA-PACKAGE",
            preferredVendorName: marker,
            preferredVendorQuickBooksID: "SCHEMA-BOOTSTRAP-VENDOR",
            vendorPartNumber: marker,
            purchaseURL: "https://example.invalid/schema-bootstrap",
            purchaseDescription: marker,
            tracksInventory: true,
            reorderPoint: 0,
            defaultInventoryLocation: marker,
            flatRateAssemblyJSON: assemblyDefinition.encodedJSON,
            createdAt: now
        )
        let bootstrapCatalogSnapshot = CatalogLineItemSnapshot.encoded(from: [item]) ?? "[]"
        let serviceLocation = CustomerServiceLocation(
            customer: customer,
            name: marker,
            address: "1 Schema Bootstrap Way",
            contactName: marker,
            contactPhone: "000-000-0000",
            accessNotes: marker,
            isPrimary: true,
            isActive: false,
            createdAt: now,
            updatedAt: now
        )
        let customerEquipment = CustomerEquipment(
            customer: customer,
            serviceLocationID: serviceLocation.id,
            equipmentType: .splitSystemAC,
            name: marker,
            manufacturer: marker,
            modelNumber: marker,
            serialNumber: "SCHEMA-BOOTSTRAP-SERIAL",
            location: marker,
            installDate: now.addingTimeInterval(-86_400),
            warrantyExpiration: now.addingTimeInterval(86_400),
            filterSize: marker,
            notes: marker,
            technicalBaselineReadingsJSON: "{\"schema\":\"bootstrap\"}",
            isActive: false,
            createdAt: now
        )
        let serviceCall = ServiceCall(
            googleCalendarID: "SCHEMA-BOOTSTRAP-CALENDAR",
            googleEventID: "SCHEMA-BOOTSTRAP-EVENT",
            googleEventManagedByApp: true,
            eventTitle: marker,
            siteAddress: serviceLocation.address,
            serviceLocationID: serviceLocation.id,
            equipmentName: customerEquipment.name,
            equipmentManufacturer: customerEquipment.manufacturer,
            equipmentModel: customerEquipment.modelNumber,
            equipmentSerialNumber: customerEquipment.serialNumber,
            equipmentLocation: customerEquipment.location,
            equipmentInstallDate: customerEquipment.installDate,
            equipmentWarrantyExpiration: customerEquipment.warrantyExpiration,
            customerEquipmentID: customerEquipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            equipmentNotes: marker,
            serviceReportReadingsJSON: "{\"schema\":\"bootstrap\"}",
            serviceActionChecklistJSON: "{\"schema\":\"bootstrap\"}",
            filterSize: marker,
            filterCondition: marker,
            indoorCoilCondition: marker,
            outdoorCoilCondition: marker,
            drainLineCondition: marker,
            thermostatOperation: marker,
            serviceReportSummary: marker,
            type: .service,
            scheduledDate: now,
            promisedArrivalWindowStart: now,
            promisedArrivalWindowEnd: now.addingTimeInterval(3_600),
            assignedTechnician: technician,
            additionalTechnicianIDs: [UUID()],
            customer: customer,
            cancelledAt: now,
            cancellationReason: marker,
            notes: marker,
            findingsSummary: marker,
            recommendedWorkSummary: marker,
            visitDisposition: .callback,
            visitDispositionNotes: marker,
            followUpRequired: true,
            followUpAction: marker,
            followUpDueDate: now.addingTimeInterval(86_400),
            maintenanceAgreementID: UUID(),
            maintenanceAgreementDueDate: now,
            technicianEnRouteAt: now,
            technicianArrivedAt: now,
            documentationStartedAt: now,
            documentationCompletedAt: now,
            linkedEstimateID: UUID(),
            linkedInvoiceID: UUID(),
            correctiveWorkReason: .unresolvedConcern
        )
        let correctiveFollowUp = ServiceCall(
            eventTitle: marker,
            type: .service,
            scheduledDate: now.addingTimeInterval(3_600),
            assignedTechnician: technician,
            customer: customer,
            notes: marker,
            visitDisposition: .callback,
            originatingServiceCallID: serviceCall.id,
            correctiveWorkReason: .unresolvedConcern
        )
        serviceCall.scheduledFollowUpServiceCallID = correctiveFollowUp.id
        let invoice = Invoice(
            serviceCallID: serviceCall.id,
            serviceLocationID: serviceLocation.id,
            siteAddress: serviceLocation.address,
            customer: customer,
            quickBooksID: "SCHEMA-BOOTSTRAP-INVOICE",
            quickBooksBalanceDue: 1.08,
            quickBooksSyncStatus: "synced",
            quickBooksSyncDetail: marker,
            quickBooksLastSyncedAt: now,
            catalogSnapshotJSON: bootstrapCatalogSnapshot,
            amount: 1.08,
            salesTaxAmount: 0.08,
            taxCalculationStatus: .calculatedByQuickBooks,
            taxCalculatedAt: now,
            projectMilestoneID: UUID(),
            projectMilestoneSequence: 0,
            projectMilestoneTitle: marker,
            projectContractAmount: 1,
            projectBillingPercent: 100,
            dueDate: now,
            notes: marker,
            customerSignatureName: marker,
            customerSignatureImageBase64: Data(marker.utf8).base64EncodedString(),
            customerSignedAt: now,
            completionNotes: marker,
            finalizedAt: now
        )
        let estimate = Estimate(
            serviceCallID: serviceCall.id,
            serviceLocationID: serviceLocation.id,
            siteAddress: serviceLocation.address,
            scheduledServiceCallID: correctiveFollowUp.id,
            parentEstimateID: UUID(),
            changeOrderReason: marker,
            proposalGroupID: UUID(),
            proposalOption: EstimateProposalOption.good.rawValue,
            proposalIsRecommended: true,
            customer: customer,
            quickBooksID: "SCHEMA-BOOTSTRAP-ESTIMATE",
            catalogSnapshotJSON: bootstrapCatalogSnapshot,
            amount: 1.08,
            salesTaxAmount: 0.08,
            taxCalculationStatus: .calculatedByQuickBooks,
            taxCalculatedAt: now,
            status: "accepted",
            customerApprovedByName: marker,
            customerApprovedAt: now,
            customerApprovalMethodRaw: EstimateApprovalMethod.inPersonSignature.rawValue,
            customerApprovalReference: marker,
            customerApprovalRecordedByEmail: bootstrapEmail,
            customerApprovalSignatureImageBase64: Data(marker.utf8).base64EncodedString(),
            notes: marker
        )
        serviceCall.linkedEstimateID = estimate.id
        serviceCall.linkedInvoiceID = invoice.id
        let template = FieldFormTemplate(title: marker, questions: [])
        let projectMilestone = ProjectMilestone(
            projectServiceCallID: serviceCall.id,
            estimateID: estimate.id,
            sequence: 0,
            title: marker,
            milestoneDescription: marker,
            plannedDate: now,
            billingPercent: 100,
            plannedAmount: 1,
            billingTrigger: .customerApproval,
            status: .invoiced,
            scheduledVisitID: correctiveFollowUp.id,
            invoiceID: invoice.id,
            completedAt: now,
            completedByEmail: bootstrapEmail,
            createdAt: now,
            createdByEmail: bootstrapEmail
        )
        invoice.projectMilestoneID = projectMilestone.id
        let maintenanceAgreement = RecurringMaintenanceContract(
            customer: customer,
            planName: marker,
            schedulePattern: "Annual",
            nextDate: now,
            active: false,
            termEndsOn: now.addingTimeInterval(365 * 86_400),
            pricePerVisit: 1,
            includedVisitsPerTerm: 1,
            coveredEquipmentIDs: [customerEquipment.id]
        )
        maintenanceAgreement.configureDraft(
            agreementPrice: 1,
            billingInterval: .annual,
            memberDiscountPercent: 1,
            autoRenews: true,
            termsSummary: marker,
            createdByEmail: bootstrapEmail,
            sourceServiceCallID: serviceCall.id,
            createdAt: now
        )
        let maintenanceAgreementDocument = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCall.id,
            maintenanceContractID: maintenanceAgreement.id,
            kind: .maintenanceAgreement,
            displayName: marker,
            localFilePath: "/tmp/gunnaire-cloudkit-schema-bootstrap-agreement",
            contentType: "application/pdf",
            fileSizeBytes: 0
        )
        let fleetVehicle = FleetVehicle(
            unitNumber: marker,
            vin: "1GUNNAIRE00000001",
            licensePlate: "SCHEMA",
            vehicleYear: 2026,
            make: marker,
            model: marker,
            stockLocation: marker,
            assignedTechnicianID: technician.id,
            assignedTechnicianName: technician.name,
            administrativeStatus: .outOfService,
            odometer: 1,
            odometerUpdatedAt: now,
            latestInspectionAt: now,
            nextInspectionDueAt: now,
            nextServiceDueAt: now,
            nextServiceDueOdometer: 2,
            notes: marker,
            createdAt: now,
            updatedAt: now,
            updatedByEmail: bootstrapEmail
        )
        let fleetEvent = FleetVehicleEvent(
            vehicleID: fleetVehicle.id,
            vehicleUnitNumber: fleetVehicle.unitNumber,
            kind: .inspectionCompleted,
            occurredAt: now,
            actorEmail: bootstrapEmail,
            detail: marker,
            odometer: 1,
            inspectionResults: FleetInspectionItem.allCases.map {
                FleetInspectionResult(item: $0, passed: false)
            },
            serviceCategory: .repair,
            serviceCost: 1,
            serviceCenter: marker,
            invoiceNumber: marker,
            assignmentTechnicianID: technician.id,
            assignmentTechnicianName: technician.name,
            priorStatus: .inService,
            newStatus: .outOfService,
            resolvesOutOfService: false
        )
        let fieldExpenseReceiptID = UUID()
        let fieldExpenseClaim = FieldExpenseClaim(
            serviceCallID: serviceCall.id,
            customerID: customer.id,
            customerName: customer.name,
            jobSummary: marker,
            claimantEmail: bootstrapEmail,
            claimantName: marker,
            claimType: .mileage,
            category: .mileage,
            expenseDate: now,
            merchant: "Mileage",
            businessPurpose: marker,
            amount: 1,
            mileageMiles: 1,
            mileageRatePerMile: 1,
            mileageOrigin: marker,
            mileageDestination: marker,
            reimbursable: true,
            receiptAttachmentID: fieldExpenseReceiptID,
            submittedAt: now,
            createdAt: now
        )
        try fieldExpenseClaim.approve(
            reviewerEmail: bootstrapEmail,
            reviewerRole: .admin,
            note: marker,
            hasReceipt: true,
            now: now
        )
        try fieldExpenseClaim.markReimbursed(
            reference: marker,
            actorEmail: bootstrapEmail,
            actorRole: .admin,
            now: now
        )
        let operationalAlert = CustomerOperationalAlert(
            customerID: customer.id,
            customerName: customer.name,
            serviceLocationID: serviceLocation.id,
            serviceLocationName: serviceLocation.displayName,
            kind: .safety,
            title: marker,
            detail: marker,
            createdAt: now,
            createdByEmail: bootstrapEmail
        )
        try CustomerOperationalAlertPolicy.resolve(
            operationalAlert,
            actorEmail: bootstrapEmail,
            note: marker,
            now: now,
            resolutionOperationID: UUID()
        )
        let businessTask = BusinessTask(
            creationOperationID: UUID(),
            title: marker,
            taskDescription: marker,
            priority: .urgent,
            assignedToEmail: bootstrapEmail,
            dueAt: now,
            customerID: customer.id,
            customerName: customer.name,
            serviceLocationID: serviceLocation.id,
            serviceLocationName: serviceLocation.displayName,
            serviceCallID: serviceCall.id,
            serviceCallSummary: marker,
            estimateID: estimate.id,
            estimateSummary: marker,
            createdAt: now,
            createdByEmail: bootstrapEmail
        )
        businessTask.completedAt = now
        businessTask.completedByEmail = bootstrapEmail
        businessTask.completionNote = marker
        businessTask.completionOperationID = UUID()
        businessTask.cancelledAt = now
        businessTask.cancelledByEmail = bootstrapEmail
        businessTask.cancellationReason = marker
        businessTask.cancellationOperationID = UUID()
        let businessTaskEvent = BusinessTaskEvent(
            operationID: UUID(),
            taskID: businessTask.id,
            kind: .updated,
            occurredAt: now,
            actorEmail: bootstrapEmail,
            detail: marker,
            titleSnapshot: marker,
            assignedToEmailSnapshot: bootstrapEmail,
            dueAtSnapshot: now,
            priority: .urgent
        )
        let timeOffRequest = TechnicianTimeOffRequest(
            creationOperationID: UUID(),
            technicianID: technician.id,
            technicianNameSnapshot: technician.name,
            requestedByEmail: bootstrapEmail,
            startsAt: now,
            endsAt: now.addingTimeInterval(3_600),
            privateReason: marker,
            createdAt: now
        )
        timeOffRequest.status = .approved
        timeOffRequest.updatedAt = now
        timeOffRequest.reviewedAt = now
        timeOffRequest.reviewedByEmail = bootstrapEmail
        timeOffRequest.privateReviewNote = marker
        timeOffRequest.reviewOperationID = UUID()
        timeOffRequest.withdrawnAt = now
        timeOffRequest.withdrawnByEmail = bootstrapEmail
        timeOffRequest.withdrawalOperationID = UUID()
        timeOffRequest.cancelledAt = now
        timeOffRequest.cancelledByEmail = bootstrapEmail
        timeOffRequest.cancellationReason = marker
        timeOffRequest.cancellationOperationID = UUID()
        timeOffRequest.status = .cancelled
        let availabilityBlock = TechnicianAvailabilityBlock(
            creationOperationID: UUID(),
            technicianID: technician.id,
            startsAt: timeOffRequest.startsAt,
            endsAt: timeOffRequest.endsAt,
            kind: .timeOff,
            reason: marker,
            createdAt: now,
            createdByEmail: bootstrapEmail,
            sourceTimeOffRequestID: timeOffRequest.id
        )
        availabilityBlock.cancelledAt = now
        availabilityBlock.cancelledByEmail = bootstrapEmail
        availabilityBlock.cancellationReason = marker
        availabilityBlock.cancellationOperationID = UUID()
        timeOffRequest.approvedAvailabilityBlockID = availabilityBlock.id
        let availabilityEvent = TechnicianAvailabilityEvent(
            operationID: UUID(),
            requestID: timeOffRequest.id,
            availabilityBlockID: availabilityBlock.id,
            kind: .blockCancelled,
            technicianID: technician.id,
            technicianNameSnapshot: technician.name,
            startsAt: timeOffRequest.startsAt,
            endsAt: timeOffRequest.endsAt,
            actorEmail: bootstrapEmail,
            occurredAt: now,
            privateDetail: marker,
            requestStatus: .cancelled
        )
        let workShift = TechnicianWorkShift(
            creationOperationID: UUID(),
            technicianID: technician.id,
            technicianNameSnapshot: technician.name,
            weekday: .monday,
            startMinute: 8 * 60,
            durationMinutes: 9 * 60,
            kind: .regular,
            effectiveFrom: now,
            effectiveUntil: now.addingTimeInterval(7 * 86_400),
            timeZoneIdentifier: "America/New_York",
            note: marker,
            createdAt: now,
            createdByEmail: bootstrapEmail
        )
        workShift.retiredAt = now
        workShift.retiredByEmail = bootstrapEmail
        workShift.retirementReason = marker
        workShift.retirementOperationID = UUID()

        let payment = Payment(
            invoice: invoice,
            quickBooksID: "SCHEMA-BOOTSTRAP-PAYMENT",
            quickBooksChargeID: "SCHEMA-BOOTSTRAP-CHARGE",
            quickBooksClientTransID: "SCHEMA-BOOTSTRAP-CLIENT-TRANSACTION",
            quickBooksRefundReceiptID: "SCHEMA-BOOTSTRAP-REFUND",
            quickBooksDepositID: "SCHEMA-BOOTSTRAP-DEPOSIT",
            quickBooksSalesReceiptID: "SCHEMA-BOOTSTRAP-SALES-RECEIPT",
            quickBooksAccountingSyncStatus: "synced",
            quickBooksAccountingSyncDetail: marker,
            processorSyncStatus: "synced",
            processorSyncDetail: marker,
            settlementBatchID: "SCHEMA-BOOTSTRAP-BATCH",
            storedCardID: "SCHEMA-BOOTSTRAP-STORED-CARD",
            amount: 0,
            date: now,
            method: "card",
            cardLast4: "0000",
            authorizationReference: "SCHEMA-BOOTSTRAP-AUTHORIZATION",
            notes: marker,
            processor: OnsitePaymentProcessor.quickBooksPayments.rawValue,
            refundedPaymentID: UUID()
        )
        let timeEntry = TimeEntry(
            userEmail: bootstrapEmail,
            clockIn: now,
            clockOut: now,
            serviceCall: serviceCall,
            notes: marker,
            activity: .job,
            quickBooksTimeActivityID: "SCHEMA-BOOTSTRAP-TIME-ACTIVITY",
            quickBooksTimeActivitySyncToken: "1",
            quickBooksTimeActivitySyncedAt: now,
            quickBooksTimeActivitySyncError: marker,
            reviewStatus: .approved,
            reviewedByEmail: bootstrapEmail,
            reviewedAt: now,
            reviewNote: marker,
            reviewAuditJSON: TimeEntryReviewAudit.appending(
                TimeEntryReviewEvent(
                    action: .approved,
                    actorEmail: bootstrapEmail,
                    occurredAt: now,
                    detail: marker
                ),
                to: nil
            )
        )
        let vendor = Vendor(
            quickBooksID: "SCHEMA-BOOTSTRAP-VENDOR",
            name: marker,
            contactInfo: bootstrapEmail
        )
        let customerCommunication = CustomerCommunication(
            customer: customer,
            serviceCallID: serviceCall.id,
            invoiceID: invoice.id,
            estimateID: estimate.id,
            maintenanceContractID: maintenanceAgreement.id,
            recipient: bootstrapEmail,
            subject: marker,
            deliveryStatus: "sent",
            workflow: .appointmentConfirmation,
            actorEmail: bootstrapEmail,
            consentSnapshot: CustomerCommunicationConsentSnapshot(customer: customer),
            providerStatusDetail: marker,
            deliveredAt: now,
            attachmentFileNames: [marker],
            providerMessageID: "SCHEMA-BOOTSTRAP-PROVIDER-MESSAGE",
            backendCommunicationID: "SCHEMA-BOOTSTRAP-COMMUNICATION",
            backendSyncError: marker,
            createdAt: now
        )
        let purchaseOrder = PurchaseOrder(
            vendorName: marker,
            vendorQuickBooksID: vendor.quickBooksID,
            serviceCallID: serviceCall.id,
            itemName: marker,
            itemSKU: item.sku,
            vendorPartNumber: item.vendorPartNumber,
            quantity: 1,
            unitCost: 0,
            status: .received,
            notes: marker,
            createdByEmail: bootstrapEmail,
            createdAt: now
        )
        purchaseOrder.orderedAt = now
        purchaseOrder.receivedAt = now
        purchaseOrder.receivedToLocation = marker
        let inventoryMovement = InventoryMovement(
            item: item,
            type: .transfer,
            quantity: 1,
            sourceLocation: marker,
            destinationLocation: marker,
            serviceCallID: serviceCall.id,
            notes: marker,
            createdByEmail: bootstrapEmail,
            createdAt: now
        )
        let serviceRequest = ServiceRequest(
            backendRequestID: "SCHEMA-BOOTSTRAP-REQUEST",
            customerName: marker,
            phone: "000-000-0000",
            email: bootstrapEmail,
            address: serviceLocation.address,
            requestedServiceType: .service,
            urgency: .normal,
            summary: marker,
            preferredDate: now,
            status: .qualified,
            qualificationNotes: marker,
            createdByEmail: bootstrapEmail,
            createdAt: now
        )
        serviceRequest.qualifiedAt = now
        serviceRequest.convertedCustomerID = customer.id
        serviceRequest.convertedServiceCallID = serviceCall.id

        let models: [any PersistentModel] = [
            item,
            assemblyComponentItem,
            serviceLocation,
            serviceCall,
            correctiveFollowUp,
            customer,
            technician,
            availabilityBlock,
            workShift,
            maintenanceAgreement,
            invoice,
            estimate,
            payment,
            timeEntry,
            vendor,
            AppUser(email: bootstrapEmail),
            ServiceDocumentAttachment(
                id: fieldExpenseReceiptID,
                customer: customer,
                serviceCallID: serviceCall.id,
                customerEquipmentID: UUID(),
                invoiceID: invoice.id,
                estimateID: estimate.id,
                maintenanceContractID: maintenanceAgreement.id,
                fleetVehicleID: fleetVehicle.id,
                fleetVehicleEventID: fleetEvent.id,
                expenseClaimID: fieldExpenseClaim.id,
                kind: .expenseReceipt,
                displayName: marker,
                caption: marker,
                localFilePath: "/tmp/gunnaire-cloudkit-schema-bootstrap",
                contentType: "application/octet-stream",
                fileSizeBytes: 0,
                backendDocumentID: marker,
                sharedCompanySyncStatus: marker,
                sharedCompanySyncDetail: marker,
                quickBooksAttachableID: marker,
                quickBooksSyncError: marker,
                quickBooksAttachedEntityKeysRaw: "[]",
                googleDriveFileID: "GUNNAIRE-SCHEMA-BOOTSTRAP-DRIVE",
                googleDriveWebViewLink: "https://drive.google.com/file/d/GUNNAIRE-SCHEMA-BOOTSTRAP-DRIVE/view",
                googleDriveSyncStatus: GoogleDriveDocumentSyncState.archived.rawValue,
                googleDriveSyncDetail: marker,
                googleDriveLastSyncedAt: now,
                googleDriveArchivedByEmail: bootstrapEmail
            ),
            maintenanceAgreementDocument,
            customerEquipment,
            customerCommunication,
            purchaseOrder,
            inventoryMovement,
            serviceRequest,
            ServiceCallActivity(serviceCallID: serviceCall.id, action: marker, detail: marker, actorEmail: bootstrapEmail),
            projectMilestone,
            template,
            FieldFormResponse(serviceCallID: serviceCall.id, template: template, answers: [:], completedByEmail: bootstrapEmail),
            fleetVehicle,
            fleetEvent,
            fieldExpenseClaim,
            operationalAlert,
            businessTask,
            businessTaskEvent,
            timeOffRequest,
            availabilityEvent,
        ]

        for model in models {
            modelContext.insert(model)
        }
        try modelContext.save()
    }

    private static func cleanup(in modelContext: ModelContext) throws {
        for value in try modelContext.fetch(FetchDescriptor<TechnicianWorkShift>()) where value.technicianNameSnapshot == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<TechnicianAvailabilityEvent>()) where value.privateDetail == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<TechnicianTimeOffRequest>()) where value.technicianNameSnapshot == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<BusinessTaskEvent>()) where value.detail == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<BusinessTask>()) where value.title == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<CustomerOperationalAlert>()) where value.createdByEmail == bootstrapEmail {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<FieldExpenseClaim>()) where value.claimantEmail == bootstrapEmail {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<FleetVehicleEvent>()) where value.detail == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<FleetVehicle>()) where value.unitNumber == marker {
            modelContext.delete(value)
        }
        let projectMilestones = try modelContext.fetch(FetchDescriptor<ProjectMilestone>())
        debugLog("cleanup found \(projectMilestones.filter { $0.title == marker }.count) project milestone marker(s)")
        for value in projectMilestones where value.title == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<CustomerServiceLocation>()) where value.name == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<ServiceDocumentAttachment>()) where value.displayName == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<CustomerCommunication>()) where value.subject == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<Payment>()) where value.notes == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<TimeEntry>()) where value.notes == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<FieldFormResponse>()) where value.templateTitle == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<ServiceCallActivity>()) where value.action == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<InventoryMovement>()) where value.notes == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<PurchaseOrder>()) where value.notes == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<RecurringMaintenanceContract>()) where value.planName == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<Invoice>()) where value.notes == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<Estimate>()) where value.notes == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<ServiceCall>()) where value.eventTitle == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<CustomerEquipment>()) where value.name == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<TechnicianAvailabilityBlock>()) where value.reason == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<ServiceRequest>()) where value.summary == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<FieldFormTemplate>()) where value.title == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<Item>()) where value.name == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<Vendor>()) where value.name == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<Technician>()) where value.name == marker {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<AppUser>()) where value.email == bootstrapEmail {
            modelContext.delete(value)
        }
        for value in try modelContext.fetch(FetchDescriptor<Customer>()) where value.name == marker {
            modelContext.delete(value)
        }

        try modelContext.save()
        debugLog("cleanup save completed")
    }
}
#endif
