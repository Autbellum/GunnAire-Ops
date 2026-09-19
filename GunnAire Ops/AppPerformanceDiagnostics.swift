import Combine
import Foundation
import MetricKit
import os
import QuartzCore
import UIKit

/// One recorded observation about how the app behaved: a launch that was timed,
/// a stretch where the main thread stopped answering, or a termination Apple
/// reported back after the fact.
nonisolated struct AppPerformanceEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case launch
        case stall
        case crash
        case hang
        case slowLaunch
        case cpuException
        case diskWriteException

        var label: String {
            switch self {
            case .launch: return "Launch"
            case .stall: return "Screen froze"
            case .crash: return "Crash"
            case .hang: return "Hang"
            case .slowLaunch: return "Slow launch"
            case .cpuException: return "Runaway CPU"
            case .diskWriteException: return "Heavy disk writing"
            }
        }

        /// Launch timings are routine; the rest are the ones worth reading.
        var isFault: Bool {
            switch self {
            case .launch: return false
            default: return true
            }
        }
    }

    var id: UUID
    var kind: Kind
    var occurredAt: Date
    var headline: String
    var detail: String
    /// Duration in seconds where the kind carries one, so the list can be
    /// sorted and summarized without re-parsing the text.
    var seconds: Double?
    var appVersion: String
    /// The screen that was open, for anything the running app measured itself.
    var context: String?
    /// Name of the raw MetricKit JSON kept alongside, when Apple supplied one.
    var payloadFileName: String?

    var durationText: String? {
        guard let seconds else { return nil }
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        return String(format: "%.2f s", seconds)
    }
}

/// Signposts emitted through MetricKit's log handle are persisted by the system,
/// so an interval marked with one is visible both in an Instruments recording
/// taken on a tethered device and in the daily metric payload from ordinary use.
///
/// Use these to mark the work that is suspected of being slow, so a trace says
/// which piece of the app spent the time rather than only which function did.
enum AppPerformanceSignposts {
    static let signposter = OSSignposter(
        logHandle: MXMetricManager.makeLogHandle(category: "AppPerformance")
    )

    /// Measures a synchronous stretch of work and names it in the trace.
    static func measure<T>(_ name: StaticString, perform work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try work()
    }
}

/// Records what the app can observe about its own launch time, main-thread
/// stalls and terminations.
///
/// This exists because "the app is slow and it crashes" had no evidence behind
/// it. App Store Connect reports nothing for a business this size, and crash
/// logs written on the iPad are never read by anyone. Two sources feed the
/// record and they answer different questions:
///
/// - MetricKit reports crashes, hangs and slow launches from real use, with the
///   call stack Apple captured. It arrives at most once a day and always
///   describes a window that has already closed, so it explains yesterday.
/// - The launch stopwatch and the stall monitor measure the app that is running
///   right now, so today's session shows up the moment it happens.
///
/// Everything is kept on the device. Nothing here is sent anywhere.
@MainActor
final class AppPerformanceDiagnostics: NSObject, ObservableObject {
    static let shared = AppPerformanceDiagnostics()

    /// A main-thread pause longer than this is something the owner can feel.
    /// Apple treats a quarter second as the threshold for a perceptible hang;
    /// half a second keeps the log to stalls worth explaining.
    private static let stallThreshold: TimeInterval = 0.5
    /// A cold launch slower than this is a defect, not a slow device.
    private static let slowLaunchThreshold: TimeInterval = 2.0
    private static let eventLimit = 250
    private static let payloadRetention: TimeInterval = 30 * 24 * 60 * 60

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "GunnAireOps",
        category: "AppPerformance"
    )

    @Published private(set) var events: [AppPerformanceEvent] = []
    /// Set when the launch stopwatch finishes, so the current session's number
    /// can be shown without waiting for a MetricKit payload.
    @Published private(set) var lastLaunchSeconds: Double?

    nonisolated private let store = AppPerformanceEventStore()
    /// Which named operation was running when a stall happened; read by the
    /// stall monitor's callback on the main thread, written by `operation`.
    nonisolated private let operations = AppPerformanceOperationLog()
    private let persistence: AppPerformanceEventPersistence
    private let stallMonitor = MainThreadStallMonitor(threshold: AppPerformanceDiagnostics.stallThreshold)
    private var launchStopwatch: AppLaunchStopwatch?
    private var hasStarted = false
    /// Set once the record on disk has been read back. Until then nothing is
    /// written, so an event recorded during the first second of launch cannot
    /// overwrite the history with a file that holds only itself.
    private var hasRestored = false
    private var persistSequence = 0
    private var currentContext: String?

    private override init() {
        persistence = AppPerformanceEventPersistence(store: store)
        super.init()
    }

    // MARK: - Lifecycle

    /// Called once from the application delegate. Begins the launch
    /// measurement, subscribes to MetricKit, and starts watching the main
    /// thread.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        launchStopwatch = AppLaunchStopwatch { [weak self] seconds in
            self?.recordLaunch(seconds: seconds)
        }
        launchStopwatch?.start()

        MXMetricManager.shared.add(self)

        stallMonitor.onStall = { [weak self] seconds in
            self?.recordStall(seconds: seconds)
        }
        stallMonitor.start()

        // Reading the record back, pruning old payload files and translating
        // whatever MetricKit held while no subscriber was attached are all
        // disk work; none of it belongs on the main thread during launch.
        let store = self.store
        let retention = Self.payloadRetention
        Task.detached(priority: .utility) { [weak self] in
            let stored = store.load()
            store.pruneExpiredPayloads(olderThan: retention)
            let pastPayloads = MXMetricManager.shared.pastDiagnosticPayloads
            let prepared = AppPerformanceDiagnosticTranslator.prepare(pastPayloads, writingPayloadsTo: store)
            await self?.restore(stored, thenIngest: prepared)
        }
    }

    /// Merges the record read from disk under the events recorded since
    /// launch, then ingests the diagnostics MetricKit kept from earlier runs.
    private func restore(_ stored: [AppPerformanceEvent], thenIngest prepared: [AppPerformanceDiagnosticTranslator.Result]) {
        let liveIDs = Set(events.map(\.id))
        let unseen = stored.filter { !liveIDs.contains($0.id) }
        if !unseen.isEmpty {
            events.append(contentsOf: unseen)
            events.sort { $0.occurredAt > $1.occurredAt }
            if events.count > Self.eventLimit {
                events.removeLast(events.count - Self.eventLimit)
            }
        }
        hasRestored = true
        ingest(prepared: prepared)
        persist()
    }

    /// Names the screen the owner is looking at, so a recorded stall says where
    /// it happened rather than only how long it lasted.
    func noteContext(_ context: String) {
        currentContext = context
    }

    /// Names a stretch of work so a stall that overlaps it is attributed to
    /// it. Used around the steps of the staff-replica source pass, which the
    /// recorder had only been able to place on a screen, never on a step.
    func operation<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        operations.begin(name)
        defer { operations.end() }
        return try await work()
    }

    // MARK: - Recording

    private func recordLaunch(seconds: Double) {
        lastLaunchSeconds = seconds
        let slow = seconds >= Self.slowLaunchThreshold
        append(
            AppPerformanceEvent(
                id: UUID(),
                kind: slow ? .slowLaunch : .launch,
                occurredAt: Date(),
                headline: slow
                    ? String(format: "Launch took %.1f seconds", seconds)
                    : String(format: "Launched in %.1f seconds", seconds),
                detail: slow
                    ? "From starting the app to the first screen being drawn. Anything over \(Int(Self.slowLaunchThreshold)) seconds is the app's own startup work, not the iPad."
                    : "From starting the app to the first screen being drawn.",
                seconds: seconds,
                appVersion: Self.appVersion,
                context: nil,
                payloadFileName: nil
            )
        )
    }

    private func recordStall(seconds: Double) {
        let screen = currentContext
        let now = Date()
        let running = operations.names(overlapping: now.addingTimeInterval(-seconds), end: now)
        let attribution = running.isEmpty ? "" : " Running at the time: " + running.joined(separator: ", ") + "."
        append(
            AppPerformanceEvent(
                id: UUID(),
                kind: .stall,
                occurredAt: now,
                headline: screen.map { String(format: "%@ froze for %.1f seconds", $0, seconds) }
                    ?? String(format: "The app froze for %.1f seconds", seconds),
                detail: "The screen could not respond to taps for this long because the app was busy on the main thread." + attribution,
                seconds: seconds,
                appVersion: Self.appVersion,
                context: screen,
                payloadFileName: nil
            )
        )
    }

    private func append(_ event: AppPerformanceEvent) {
        events.insert(event, at: 0)
        if events.count > Self.eventLimit {
            events.removeLast(events.count - Self.eventLimit)
        }
        logger.log("Performance event: \(event.kind.rawValue, privacy: .public) \(event.headline, privacy: .public)")
        persist()
    }

    private func append(_ newEvents: [AppPerformanceEvent]) {
        guard !newEvents.isEmpty else { return }
        events.insert(contentsOf: newEvents, at: 0)
        events.sort { $0.occurredAt > $1.occurredAt }
        if events.count > Self.eventLimit {
            events.removeLast(events.count - Self.eventLimit)
        }
        persist()
    }

    /// Writes the current record off the main thread. Writes carry a sequence
    /// number so one that finishes late can never replace a newer record.
    private func persist() {
        guard hasRestored else { return }
        persistSequence += 1
        let snapshot = events
        let sequence = persistSequence
        let persistence = self.persistence
        Task.detached(priority: .utility) {
            await persistence.save(snapshot, sequence: sequence)
        }
    }

    // MARK: - Reading

    /// Faults only, newest first: what the owner actually needs to look at.
    var faults: [AppPerformanceEvent] {
        events.filter(\.kind.isFault)
    }

    var recentLaunchSummary: String? {
        let launches = events
            .filter { $0.kind == .launch || $0.kind == .slowLaunch }
            .compactMap(\.seconds)
        guard !launches.isEmpty else { return nil }
        let slowest = launches.max() ?? 0
        let average = launches.reduce(0, +) / Double(launches.count)
        return String(
            format: "%d launches recorded, %.1fs average, %.1fs slowest",
            launches.count, average, slowest
        )
    }

    /// Everything on record as plain text, for sending to whoever is fixing it.
    func exportText() -> String {
        var lines = [
            "GunnAire Ops performance record",
            "App version \(Self.appVersion)",
            "Device \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)",
            ""
        ]
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        for event in events {
            lines.append("[\(formatter.string(from: event.occurredAt))] \(event.kind.label): \(event.headline)")
            if !event.detail.isEmpty {
                lines.append("    \(event.detail)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func removeAll() {
        events = []
        store.removeAll()
    }

    fileprivate static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - MetricKit

extension AppPerformanceDiagnostics: MXMetricManagerSubscriber {
    /// MetricKit calls this on a background queue, which is why the work hops
    /// back to the main actor before touching published state.
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // Translation and the payload file writes happen here, on MetricKit's
        // queue; only the finished events cross to the main actor.
        let prepared = AppPerformanceDiagnosticTranslator.prepare(payloads, writingPayloadsTo: store)
        Task { @MainActor [weak self] in
            self?.ingest(prepared: prepared)
        }
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        // Aggregate metrics are not what the slowness complaint needs; the
        // diagnostics above carry the call stacks. Kept so the subscription
        // stays valid if aggregate metrics become useful later.
    }

    /// Adds translated diagnostics to the record, skipping anything already on
    /// record from a previous delivery of the same window; MetricKit can
    /// repeat payloads.
    private func ingest(prepared: [AppPerformanceDiagnosticTranslator.Result]) {
        var recorded: [AppPerformanceEvent] = []
        for result in prepared {
            for var event in result.events {
                guard !events.contains(where: {
                    $0.kind == event.kind
                        && $0.occurredAt == event.occurredAt
                        && $0.headline == event.headline
                }) else { continue }
                event.payloadFileName = result.payloadFileName
                recorded.append(event)
            }
        }
        append(recorded)
    }
}

/// The last few named operations and when each ran, so a stall recorded after
/// the fact can be matched to the work that overlapped it. Steps of one pass
/// run one after another, so a short ring is enough.
nonisolated final class AppPerformanceOperationLog: @unchecked Sendable {
    struct Entry: Equatable {
        let name: String
        let startedAt: Date
        var endedAt: Date?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int
    private let clock: () -> Date

    init(capacity: Int = 8, clock: @escaping () -> Date = Date.init) {
        self.capacity = capacity
        self.clock = clock
    }

    func begin(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(name: name, startedAt: clock(), endedAt: nil))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// Ends the most recent operation that is still open.
    func end() {
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.lastIndex(where: { $0.endedAt == nil }) else { return }
        entries[index].endedAt = clock()
    }

    /// Names of the operations that ran at any point between `start` and
    /// `end`, oldest first, without duplicates.
    func names(overlapping start: Date, end: Date) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var seen: [String] = []
        for entry in entries where entry.startedAt <= end && (entry.endedAt ?? end) >= start {
            if !seen.contains(entry.name) { seen.append(entry.name) }
        }
        return seen
    }
}

/// Serializes the record's writes off the main thread. A write that finishes
/// after a newer one is dropped by its sequence number.
private actor AppPerformanceEventPersistence {
    private let store: AppPerformanceEventStore
    private var lastSequence = 0

    init(store: AppPerformanceEventStore) {
        self.store = store
    }

    func save(_ events: [AppPerformanceEvent], sequence: Int) {
        guard sequence > lastSequence else { return }
        lastSequence = sequence
        store.save(events)
    }
}

// MARK: - Translating Apple's diagnostics into something readable

/// Pure translation plus the payload file write; runs wherever the payload
/// arrives, never on the main actor.
nonisolated enum AppPerformanceDiagnosticTranslator {
    nonisolated struct Result: Sendable {
        var events: [AppPerformanceEvent]
        var rawJSON: Data?
        var windowEnd: Date
        /// Name of the file holding Apple's original JSON, once written.
        var payloadFileName: String?
    }

    /// Translates each payload and keeps its original JSON beside the record.
    fileprivate static func prepare(
        _ payloads: [MXDiagnosticPayload],
        writingPayloadsTo store: AppPerformanceEventStore
    ) -> [Result] {
        payloads.map { payload in
            var result = translate(payload)
            result.payloadFileName = store.writePayload(result.rawJSON, at: result.windowEnd)
            return result
        }
    }

    static func translate(_ payload: MXDiagnosticPayload) -> Result {
        // The payload's own window is the only timestamp Apple gives; each
        // diagnostic inside it has no time of its own.
        let stamp = payload.timeStampEnd
        var events: [AppPerformanceEvent] = []

        for crash in payload.crashDiagnostics ?? [] {
            events.append(
                AppPerformanceEvent(
                    id: UUID(),
                    kind: .crash,
                    occurredAt: stamp,
                    headline: crashHeadline(crash),
                    detail: [
                        crash.terminationReason,
                        crash.virtualMemoryRegionInfo.map { "Memory: \($0)" },
                        topFramesText(crash.callStackTree)
                    ].compactMap { $0 }.joined(separator: "\n"),
                    seconds: nil,
                    appVersion: crash.applicationVersion,
                    context: nil,
                    payloadFileName: nil
                )
            )
        }

        for hang in payload.hangDiagnostics ?? [] {
            let seconds = hang.hangDuration.converted(to: .seconds).value
            events.append(
                AppPerformanceEvent(
                    id: UUID(),
                    kind: .hang,
                    occurredAt: stamp,
                    headline: String(format: "The app was unresponsive for %.1f seconds", seconds),
                    detail: topFramesText(hang.callStackTree) ?? "",
                    seconds: seconds,
                    appVersion: hang.applicationVersion,
                    context: nil,
                    payloadFileName: nil
                )
            )
        }

        for launch in payload.appLaunchDiagnostics ?? [] {
            let seconds = launch.launchDuration.converted(to: .seconds).value
            events.append(
                AppPerformanceEvent(
                    id: UUID(),
                    kind: .slowLaunch,
                    occurredAt: stamp,
                    headline: String(format: "A launch took %.1f seconds", seconds),
                    detail: topFramesText(launch.callStackTree) ?? "",
                    seconds: seconds,
                    appVersion: launch.applicationVersion,
                    context: nil,
                    payloadFileName: nil
                )
            )
        }

        for cpu in payload.cpuExceptionDiagnostics ?? [] {
            events.append(
                AppPerformanceEvent(
                    id: UUID(),
                    kind: .cpuException,
                    occurredAt: stamp,
                    headline: "The app used enough CPU for iOS to flag it",
                    detail: topFramesText(cpu.callStackTree) ?? "",
                    seconds: nil,
                    appVersion: cpu.applicationVersion,
                    context: nil,
                    payloadFileName: nil
                )
            )
        }

        for disk in payload.diskWriteExceptionDiagnostics ?? [] {
            events.append(
                AppPerformanceEvent(
                    id: UUID(),
                    kind: .diskWriteException,
                    occurredAt: stamp,
                    headline: "The app wrote enough to storage for iOS to flag it",
                    detail: topFramesText(disk.callStackTree) ?? "",
                    seconds: nil,
                    appVersion: disk.applicationVersion,
                    context: nil,
                    payloadFileName: nil
                )
            )
        }

        return Result(events: events, rawJSON: payload.jsonRepresentation(), windowEnd: stamp)
    }

    private static func crashHeadline(_ crash: MXCrashDiagnostic) -> String {
        if let reason = crash.exceptionReason?.composedMessage, !reason.isEmpty {
            return "Crash: \(reason)"
        }
        if let type = crash.exceptionType {
            return "Crash: Mach exception \(type.intValue)" + (crash.signal.map { ", signal \($0.intValue)" } ?? "")
        }
        if let signal = crash.signal {
            return "Crash: signal \(signal.intValue)"
        }
        return "Crash"
    }

    /// Pulls the deepest frames Apple attributed to our own binary. They are not
    /// symbolicated on the device, but the binary offsets are enough to resolve
    /// against the matching build's dSYM with `atos`.
    static func topFramesText(_ tree: MXCallStackTree, limit: Int = 12) -> String? {
        topFrames(inCallStackJSON: tree.jsonRepresentation(), limit: limit)
    }

    /// Split out from the call above so the tree walk can be tested; a real
    /// `MXCallStackTree` can only be produced by the system.
    ///
    /// The shape Apple documents is a list of call stacks, each with root
    /// frames, each frame nesting its callee in `subFrames`. Walking down the
    /// first branch reproduces the stack from the outside in.
    static func topFrames(inCallStackJSON json: Data, limit: Int = 12) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let stacks = object["callStacks"] as? [[String: Any]]
        else { return nil }

        let attributed = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        guard let roots = attributed?["callStackRootFrames"] as? [[String: Any]] else { return nil }

        var frames: [String] = []
        var next = roots.first
        while let frame = next, frames.count < limit {
            let binary = frame["binaryName"] as? String ?? "?"
            if let offset = frame["offsetIntoBinaryTextSegment"] as? NSNumber {
                frames.append(String(format: "%@ +0x%llx", binary, offset.uint64Value))
            } else {
                frames.append(binary)
            }
            next = (frame["subFrames"] as? [[String: Any]])?.first
        }
        guard !frames.isEmpty else { return nil }
        return frames.joined(separator: "\n")
    }
}

// MARK: - Launch timing

/// Times the app from process start to the first frame the owner can see.
///
/// `UIApplication.didBecomeActiveNotification` is not the mark to use, because
/// it fires before the first draw. A CATransaction completion handler runs once
/// the first committed frame is on screen, which is the moment the app stops
/// looking like it is still starting.
@MainActor
private final class AppLaunchStopwatch {
    private let onFinish: (Double) -> Void
    private var finished = false

    init(onFinish: @escaping (Double) -> Void) {
        self.onFinish = onFinish
    }

    func start() {
        guard let started = Self.processStartDate() else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.onFinish(Date().timeIntervalSince(started))
        }
        CATransaction.commit()
    }

    /// The kernel's own record of when this process began, which includes the
    /// dynamic-linker and pre-main time the app cannot measure from inside.
    private static func processStartDate() -> Date? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&name, UInt32(name.count), &info, &size, nil, 0)
        guard result == 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        let seconds = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - Main-thread stall monitor

/// Watches the main thread from a background queue and reports how long it went
/// without answering.
///
/// The probe is an empty block, so the cost of watching is a timer tick and one
/// queue hop every interval. It reports the pause only once it ends, which is
/// the only point at which the length is known.
private final class MainThreadStallMonitor: @unchecked Sendable {
    /// Callback is delivered on the main thread.
    var onStall: ((Double) -> Void)?

    private let threshold: TimeInterval
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "com.gunnaire.performance.stall-monitor", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var probeOutstanding = false

    init(threshold: TimeInterval, interval: TimeInterval = 0.25) {
        self.threshold = threshold
        self.interval = interval
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.interval, repeating: self.interval, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.probe() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func probe() {
        // While the main thread is still holding an earlier probe there is
        // nothing to learn from sending another, and queuing them up would make
        // the backlog worse than the stall being measured.
        lock.lock()
        if probeOutstanding {
            lock.unlock()
            return
        }
        probeOutstanding = true
        lock.unlock()

        let sent = DispatchTime.now()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let waited = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000_000
            self.lock.lock()
            self.probeOutstanding = false
            self.lock.unlock()
            if waited >= self.threshold {
                self.onStall?(waited)
            }
        }
    }
}

// MARK: - Storage

/// Keeps the record on the device between launches. A crash is only useful if
/// it survives the launch that follows it.
nonisolated private struct AppPerformanceEventStore {
    private static let directoryName = "PerformanceDiagnostics-v1"
    private static let eventsFileName = "events.json"

    private var directory: URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return root.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private func preparedDirectory() -> URL? {
        guard var directory else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try directory.setResourceValues(resources)
            return directory
        } catch {
            return nil
        }
    }

    func load() -> [AppPerformanceEvent] {
        guard
            let url = directory?.appendingPathComponent(Self.eventsFileName),
            let data = try? Data(contentsOf: url),
            let events = try? JSONDecoder().decode([AppPerformanceEvent].self, from: data)
        else { return [] }
        return events
    }

    func save(_ events: [AppPerformanceEvent]) {
        guard
            let directory = preparedDirectory(),
            let data = try? JSONEncoder().encode(events)
        else { return }
        try? data.write(
            to: directory.appendingPathComponent(Self.eventsFileName),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    /// Keeps Apple's original JSON beside the summary, so a stack that the
    /// summary shortened can still be read in full.
    func writePayload(_ json: Data?, at date: Date) -> String? {
        guard let json, let directory = preparedDirectory() else { return nil }
        let name = "payload-\(Int(date.timeIntervalSince1970)).json"
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return name }
        do {
            try json.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return name
        } catch {
            return nil
        }
    }

    func pruneExpiredPayloads(olderThan age: TimeInterval) {
        guard let directory else { return }
        let cutoff = Date().addingTimeInterval(-age)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in contents where url.lastPathComponent.hasPrefix("payload-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func removeAll() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
