import Foundation
import XCTest
@testable import GunnAire_Ops

@MainActor
final class StaffWorkspaceOperationalJournalAdvanceTests: XCTestCase {
    private typealias Journal = StaffWorkspaceOperationalAcceptance
    private let scope = CloudKitStaffSetupScope(origin: "https://fixture.gunnaire.invalid", company: UUID(),
        email: "technician@example.invalid", environment: "sandbox", accountHash: String(repeating: "a", count: 64))
    private let plan = UUID()
    private let key = "synthetic-journal-head"

    private final class Memory {
        var values: [String: Data] = [:]
        var writes = 0
        var failBefore: Int?
        var failAfter: Int?
        var store: SharedTimeLocalStore {
            .init(read: { self.values[$0] }, write: { key, bytes in
                self.writes += 1
                if self.failBefore == self.writes {
                    self.failBefore = nil
                    throw StaffReplicaDeliveryError.storage
                }
                self.values[key] = bytes
                if self.failAfter == self.writes {
                    self.failAfter = nil
                    throw StaffReplicaDeliveryError.storage
                }
            })
        }
    }

    private func journal(_ sequence: Int = 1, selection: String = UUID().uuidString.lowercased(),
                         scope: CloudKitStaffSetupScope? = nil, plan: UUID? = nil) throws -> Journal {
        try Journal(scope: scope ?? self.scope, planID: plan ?? self.plan, selectionID: selection,
                    sourceSequence: sequence, contentSHA256: String(repeating: "b", count: 64), recordCount: 1)
    }

    private func commit(_ next: Journal, _ previous: Journal?, _ memory: Memory,
                        check: () throws -> Void = {}) throws {
        try StaffWorkspaceOperationalJournalAdvance.commit(next, replacing: previous, key: key,
                                                           store: memory.store, check: check)
    }

    private func archive(_ previous: Journal) -> String {
        key + "\nprevious-generation-v1\n" + String(previous.sourceSequence) + "\n" + previous.selectionID
    }

    func testInitialCommitAndExactReplayDoNotRewriteOrArchive() throws {
        let memory = Memory(), first = try journal()
        try commit(first, nil, memory)
        let saved = memory.values
        try commit(first, first, memory)
        XCTAssertEqual(memory.values, saved)
        XCTAssertEqual(memory.writes, 1)
        XCTAssertEqual(memory.values.count, 1)
    }

    func testSuccessorRetainsExactPreviousEncodingAndOtherWork() throws {
        let memory = Memory(), first = try journal(), next = try journal(2)
        let original = Data(" \n".utf8) + (try StaffWorkspacePublicationContract.encode(first)) + Data("\n".utf8)
        memory.values[key] = original
        memory.values["pending-field-command"] = Data("unsent synthetic work".utf8)
        try commit(next, first, memory)
        XCTAssertEqual(memory.values[archive(first)], original)
        XCTAssertEqual(memory.values[key], try StaffWorkspacePublicationContract.encode(next))
        XCTAssertEqual(memory.values["pending-field-command"], Data("unsent synthetic work".utf8))
        XCTAssertEqual(memory.writes, 2)
    }

    func testEveryBeforeAndAfterWriteFailureCanResumeWithoutLosingPredecessor() throws {
        for after in [false, true] {
            for write in 1...2 {
                let memory = Memory(), first = try journal(), next = try journal(2)
                let original = try StaffWorkspacePublicationContract.encode(first)
                memory.values[key] = original
                memory.values["pending-field-command"] = Data("retain".utf8)
                if after { memory.failAfter = write } else { memory.failBefore = write }
                XCTAssertThrowsError(try commit(next, first, memory), "after=\(after), write=\(write)")
                XCTAssertTrue(memory.values[key] == original || memory.values[archive(first)] == original)
                let retained = try JSONDecoder().decode(Journal.self, from: XCTUnwrap(memory.values[key]))
                try commit(next, retained, memory)
                XCTAssertEqual(memory.values[key], try StaffWorkspacePublicationContract.encode(next))
                XCTAssertEqual(memory.values[archive(first)], original)
                XCTAssertEqual(memory.values["pending-field-command"], Data("retain".utf8))
            }
        }
    }

    func testOlderEqualSequenceAndReusedSelectionCannotReplaceHead() throws {
        let first = try journal(2)
        for next in [try journal(1), try journal(2), try journal(3, selection: first.selectionID)] {
            let memory = Memory()
            memory.values[key] = try StaffWorkspacePublicationContract.encode(first)
            let saved = memory.values
            XCTAssertThrowsError(try commit(next, first, memory))
            XCTAssertEqual(memory.values, saved)
            XCTAssertEqual(memory.writes, 0)
        }
    }

    func testScopeAndPlanCannotChangeAcrossGenerations() throws {
        let first = try journal()
        let other = CloudKitStaffSetupScope(origin: scope.origin, company: UUID(), email: scope.email,
                                           environment: scope.environment, accountHash: scope.accountHash)
        for next in [try journal(2, scope: other), try journal(2, plan: UUID())] {
            let memory = Memory()
            memory.values[key] = try StaffWorkspacePublicationContract.encode(first)
            let saved = memory.values
            XCTAssertThrowsError(try commit(next, first, memory))
            XCTAssertEqual(memory.values, saved)
            XCTAssertEqual(memory.writes, 0)
        }
    }

    func testConflictingArchiveIsNeverOverwritten() throws {
        let memory = Memory(), first = try journal(), next = try journal(2)
        memory.values[key] = try StaffWorkspacePublicationContract.encode(first)
        memory.values[archive(first)] = Data("conflicting recovery evidence".utf8)
        let saved = memory.values
        XCTAssertThrowsError(try commit(next, first, memory))
        XCTAssertEqual(memory.values, saved)
        XCTAssertEqual(memory.writes, 0)
    }

    func testMissingOrStaleExpectedHeadCannotOverwriteStoredWork() throws {
        let first = try journal(), other = try journal(), next = try journal(2)
        for expected in [nil, first] as [Journal?] {
            let memory = Memory()
            memory.values[key] = try StaffWorkspacePublicationContract.encode(other)
            let saved = memory.values
            XCTAssertThrowsError(try commit(next, expected, memory))
            XCTAssertEqual(memory.values, saved)
            XCTAssertEqual(memory.writes, 0)
        }
        let empty = Memory()
        XCTAssertThrowsError(try commit(next, first, empty))
        XCTAssertTrue(empty.values.isEmpty)
    }

    func testLateHeadChangeIsNotOverwrittenAfterArchive() throws {
        let memory = Memory(), first = try journal(), next = try journal(2), concurrent = try journal(3)
        let original = try StaffWorkspacePublicationContract.encode(first)
        let later = try StaffWorkspacePublicationContract.encode(concurrent)
        memory.values[key] = original
        XCTAssertThrowsError(try commit(next, first, memory) {
            if memory.values[self.archive(first)] != nil { memory.values[self.key] = later }
        })
        XCTAssertEqual(memory.values[key], later)
        XCTAssertEqual(memory.values[archive(first)], original)
        XCTAssertEqual(memory.writes, 1)
    }

    func testAuthorityLossAfterArchiveDoesNotAdvanceHead() throws {
        let memory = Memory(), first = try journal(), next = try journal(2)
        let original = try StaffWorkspacePublicationContract.encode(first)
        memory.values[key] = original
        XCTAssertThrowsError(try commit(next, first, memory) {
            if memory.values[self.archive(first)] != nil { throw StaffReplicaDeliveryError.changed }
        })
        XCTAssertEqual(memory.values[key], original)
        XCTAssertEqual(memory.values[archive(first)], original)
    }

    func testUnknownMalformedAndOversizedRetainedJournalsAreNotRepaired() throws {
        let first = try journal(), next = try journal(2)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: StaffWorkspacePublicationContract.encode(first)) as? [String: Any])
        object["unknownField"] = "untrusted"
        let unknown = try JSONSerialization.data(withJSONObject: object)
        for bytes in [unknown, Data("malformed JSON".utf8), Data(repeating: 32, count: 8193)] {
            let memory = Memory()
            memory.values[key] = bytes
            XCTAssertThrowsError(try commit(next, first, memory))
            XCTAssertEqual(memory.values, [key: bytes])
            XCTAssertEqual(memory.writes, 0)
        }
    }

    func testThreeGenerationsRetainBothPredecessorsExactly() throws {
        let memory = Memory(), first = try journal(), second = try journal(2), third = try journal(3)
        try commit(first, nil, memory)
        try commit(second, first, memory)
        try commit(third, second, memory)
        XCTAssertEqual(memory.values[archive(first)], try StaffWorkspacePublicationContract.encode(first))
        XCTAssertEqual(memory.values[archive(second)], try StaffWorkspacePublicationContract.encode(second))
        XCTAssertEqual(memory.values[key], try StaffWorkspacePublicationContract.encode(third))
        XCTAssertEqual(memory.values.count, 3)
    }

    func testInitialAuthorityRefusalDoesNotReadOrWriteStorage() throws {
        let first = try journal()
        let store = SharedTimeLocalStore(read: { _ in XCTFail("Unauthorized read"); return nil },
                                         write: { _, _ in XCTFail("Unauthorized write") })
        XCTAssertThrowsError(try StaffWorkspaceOperationalJournalAdvance.commit(first, replacing: nil, key: key,
            store: store, check: { throw StaffReplicaDeliveryError.changed }))
    }
}
