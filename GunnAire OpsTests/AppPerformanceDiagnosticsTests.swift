import Foundation
import Testing
@testable import GunnAire_Ops

/// The performance record is only worth keeping if the stack Apple hands back
/// survives the trip into something readable, and if a stored record still
/// reads correctly after the launch that follows a crash.
struct AppPerformanceDiagnosticsTests {

    // MARK: - Reading Apple's call stacks

    /// The shape MetricKit documents: a list of call stacks, each with root
    /// frames, each frame nesting its callee under `subFrames`.
    private func callStackJSON(
        threadAttributed: Bool = true,
        depth: Int = 3,
        binaryName: String = "GunnAire Ops",
        extraUnattributedStack: Bool = false
    ) -> Data {
        func frame(_ index: Int) -> [String: Any] {
            var value: [String: Any] = [
                "binaryUUID": "1CE9BB23-C1A7-4E68-9C07-1A1D64A2E56B",
                "offsetIntoBinaryTextSegment": 0x1000 * (index + 1),
                "sampleCount": 20 - index,
                "binaryName": binaryName,
                "address": 4_382_253_808 + index
            ]
            if index + 1 < depth {
                value["subFrames"] = [frame(index + 1)]
            }
            return value
        }

        var stacks: [[String: Any]] = []
        if extraUnattributedStack {
            stacks.append([
                "threadAttributed": false,
                "callStackRootFrames": [[
                    "binaryName": "libsystem_pthread.dylib",
                    "offsetIntoBinaryTextSegment": 0x99,
                    "address": 1
                ]]
            ])
        }
        stacks.append([
            "threadAttributed": threadAttributed,
            "callStackRootFrames": [frame(0)]
        ])

        return try! JSONSerialization.data(
            withJSONObject: ["callStacks": stacks, "callStackPerThread": true]
        )
    }

    @Test
    func callStackFramesAreReadOutermostFirstWithHexOffsets() throws {
        let text = try #require(
            AppPerformanceDiagnosticTranslator.topFrames(inCallStackJSON: callStackJSON(depth: 3))
        )
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines == [
            "GunnAire Ops +0x1000",
            "GunnAire Ops +0x2000",
            "GunnAire Ops +0x3000"
        ])
    }

    /// A crash payload carries every thread. Only the one iOS blamed explains
    /// the crash, so a stack of pthread start frames must not win.
    @Test
    func attributedThreadIsPreferredOverOtherThreads() throws {
        let text = try #require(
            AppPerformanceDiagnosticTranslator.topFrames(
                inCallStackJSON: callStackJSON(depth: 2, extraUnattributedStack: true)
            )
        )
        #expect(text.hasPrefix("GunnAire Ops +0x1000"))
        #expect(!text.contains("libsystem_pthread"))
    }

    /// Hang stacks can be hundreds of frames deep; the summary keeps the top of
    /// the stack, which is where the blame sits.
    @Test
    func frameCountIsCappedAtTheRequestedLimit() throws {
        let text = try #require(
            AppPerformanceDiagnosticTranslator.topFrames(
                inCallStackJSON: callStackJSON(depth: 40),
                limit: 5
            )
        )
        #expect(text.split(separator: "\n").count == 5)
    }

    /// When no thread is flagged there is still a stack worth showing.
    @Test
    func firstStackIsUsedWhenNoThreadIsAttributed() throws {
        let text = try #require(
            AppPerformanceDiagnosticTranslator.topFrames(
                inCallStackJSON: callStackJSON(threadAttributed: false, depth: 2)
            )
        )
        #expect(text.split(separator: "\n").count == 2)
    }

    @Test
    func malformedCallStacksAreReportedAsMissingRatherThanCrashing() {
        #expect(AppPerformanceDiagnosticTranslator.topFrames(inCallStackJSON: Data()) == nil)
        #expect(AppPerformanceDiagnosticTranslator.topFrames(
            inCallStackJSON: Data("{\"callStacks\": []}".utf8)
        ) == nil)
        #expect(AppPerformanceDiagnosticTranslator.topFrames(
            inCallStackJSON: Data("{\"callStacks\": [{\"threadAttributed\": true}]}".utf8)
        ) == nil)
    }

    /// A frame with no offset still names its binary, so a partial stack is not
    /// discarded entirely.
    @Test
    func framesWithoutAnOffsetStillNameTheirBinary() throws {
        let json = Data("""
        {"callStacks":[{"threadAttributed":true,"callStackRootFrames":[{"binaryName":"GunnAire Ops"}]}]}
        """.utf8)
        #expect(AppPerformanceDiagnosticTranslator.topFrames(inCallStackJSON: json) == "GunnAire Ops")
    }

    // MARK: - What is kept between launches

    /// The record survives the relaunch that follows a crash, which is the only
    /// launch at which anyone reads it.
    @Test
    func storedEventsSurviveEncodingAndDecoding() throws {
        let original = AppPerformanceEvent(
            id: UUID(),
            kind: .crash,
            occurredAt: Date(timeIntervalSince1970: 1_788_800_000),
            headline: "Crash: signal 11",
            detail: "GunnAire Ops +0x1000",
            seconds: nil,
            appVersion: "1.0 (2026091612)",
            context: "Command Center",
            payloadFileName: "payload-1788800000.json"
        )
        let decoded = try JSONDecoder().decode(
            AppPerformanceEvent.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }

    /// A launch that completed is routine. Everything else is something the
    /// owner needs to see, so the list he opens must not bury a crash under
    /// ordinary launch timings.
    @Test
    func onlyOrdinaryLaunchesAreExcludedFromTheProblemList() {
        #expect(AppPerformanceEvent.Kind.launch.isFault == false)
        for kind: AppPerformanceEvent.Kind in [.stall, .crash, .hang, .slowLaunch, .cpuException, .diskWriteException] {
            #expect(kind.isFault, "\(kind.rawValue) should be shown as a problem")
        }
    }

    @Test
    func durationsReadInMillisecondsBelowASecondAndSecondsAbove() {
        func text(_ seconds: Double?) -> String? {
            AppPerformanceEvent(
                id: UUID(),
                kind: .stall,
                occurredAt: Date(),
                headline: "",
                detail: "",
                seconds: seconds,
                appVersion: "1.0",
                context: nil,
                payloadFileName: nil
            ).durationText
        }
        #expect(text(nil) == nil)
        #expect(text(0.42) == "420 ms")
        #expect(text(1) == "1.00 s")
        #expect(text(4.567) == "4.57 s")
    }
}
