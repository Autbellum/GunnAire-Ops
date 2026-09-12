import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct GmailMailboxTests {
    private func message(_ id: String, labels: [String] = ["INBOX"], thread: String? = nil) -> GmailMessageDetail {
        .init(id: id, threadId: thread ?? "thread-\(id)", labelIds: labels, snippet: "Fixture message",
              internalDate: "1788442200000", payload: .init(headers: [
                .init(name: "From", value: "Fixture Sender"), .init(name: "To", value: "Fixture Recipient"),
                .init(name: "Subject", value: "Fixture subject")], mimeType: "text/plain",
                body: nil, parts: nil, filename: nil))
    }

    @MainActor private final class Fixture {
        var current = true
        var pages: [String: GmailMailboxPage] = [:]
        var loads: [(GmailMailboxFolder, String, String?)] = []
        var writes: [(String, GmailMailboxAction)] = []
        var failPage = false
        var failWrite = false
        var beforePage: (() async -> Void)?
        var beforeWrite: (() async -> Void)?
        var replacement: GmailMessageDetail?
        lazy var provider = WorkspaceProviderOperation { [unowned self] in current }
        lazy var mailbox = GmailMailbox(loader: { [unowned self] folder, query, token, _ in
            loads.append((folder, query, token))
            await beforePage?()
            if failPage { throw URLError(.notConnectedToInternet) }
            return pages[token ?? "first"] ?? .init(messages: [], nextPageToken: nil)
        }, mutator: { [unowned self] message, action, _ in
            writes.append((message.id, action))
            await beforeWrite?()
            if failWrite { throw URLError(.networkConnectionLost) }
            if let replacement { return replacement }
            var labels = Set(message.labelIds ?? [])
            switch action {
            case .read: labels.remove("UNREAD")
            case .unread: labels.insert("UNREAD")
            case .archive: labels.remove("INBOX")
            case .trash: labels.insert("TRASH")
            case .restore: labels.remove("TRASH")
            }
            return message.replacingLabels(Array(labels).sorted())
        })
        func open(_ folder: GmailMailboxFolder = .inbox, query: String = "") async {
            await mailbox.refresh(folder: folder, query: query, provider: provider)?.value
        }
    }

    @MainActor private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?
        func hold() async { await withCheckedContinuation { continuation = $0 } }
        func ready() async throws {
            for _ in 0..<1_000 {
                if continuation != nil { return }
                await Task.yield()
            }
            throw URLError(.timedOut)
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @Test func foldersUseStableLabelsAndSentRowsShowRecipients() {
        #expect(GmailMailboxFolder.inbox.labelID == "INBOX")
        #expect(GmailMailboxFolder.sent.labelID == "SENT")
        #expect(GmailMailboxFolder.trash.labelID == "TRASH")
        #expect(GmailMailboxFolder.allMail.labelID == nil)
        #expect(GmailMailboxFolder.sent.correspondent(message("one")) == "Fixture Recipient")
        #expect(GmailMailboxFolder.inbox.correspondent(message("one")) == "Fixture Sender")
    }

    @Test func foldersDoNotLeakTrashSpamOrUneditableProviderDrafts() {
        for folder in [GmailMailboxFolder.inbox, .sent, .allMail] {
            for excluded in ["TRASH", "SPAM", "DRAFT"] {
                #expect(!folder.contains(message("one", labels: ["INBOX", "SENT", excluded])))
            }
        }
        #expect(GmailMailboxFolder.allMail.contains(message("archived", labels: [])))
        #expect(GmailMailboxFolder.trash.contains(message("trashed", labels: ["TRASH"])))
    }

    @Test func nextPageIsReachableAndOverlappingRowsHaveOneStableIdentity() async {
        let f = Fixture()
        f.pages["first"] = .init(messages: [message("one")], nextPageToken: "second")
        f.pages["second"] = .init(messages: [message("one"), message("two")], nextPageToken: nil)
        await f.open()
        #expect(f.mailbox.nextPageToken == "second")
        await f.mailbox.loadMore()?.value
        #expect(f.mailbox.messages.map(\.id) == ["one", "two"])
        #expect(f.loads.count == 2 && f.loads[1].2 == "second")
        #expect(f.mailbox.hasLoaded && !f.mailbox.isLoading && f.mailbox.nextPageToken == nil)
        #expect(f.mailbox.loadMore() == nil)
    }

    @Test func olderPageFailureRetainsRowsAndCursorForAnExplicitRetry() async {
        let f = Fixture()
        f.pages["first"] = .init(messages: [message("one")], nextPageToken: "second")
        f.pages["second"] = .init(messages: [message("two")], nextPageToken: nil)
        await f.open()
        f.failPage = true
        await f.mailbox.loadMore()?.value
        #expect(f.mailbox.messages.map(\.id) == ["one"])
        #expect(f.mailbox.nextPageToken == "second" && f.mailbox.status != nil)
        f.failPage = false
        await f.mailbox.loadMore()?.value
        #expect(f.mailbox.messages.map(\.id) == ["one", "two"])
        #expect(f.loads.map { $0.2 } == [nil, "second", "second"])
    }

    @Test func failedRefreshKeepsLoadedMailButFailedFolderSwitchDoesNotShowOldMail() async {
        let f = Fixture()
        f.pages["first"] = .init(messages: [message("one")], nextPageToken: "second")
        await f.open()
        f.failPage = true
        await f.open()
        #expect(f.mailbox.messages.count == 1 && f.mailbox.hasLoaded)
        await f.open(.sent)
        #expect(f.mailbox.messages.isEmpty && !f.mailbox.hasLoaded)
        #expect(f.mailbox.nextPageToken == nil && f.mailbox.folder == .sent)
    }

    @Test func emptyPageMayStillHaveAnotherPageAndMustNotEndTheMailbox() async {
        let f = Fixture()
        f.pages["first"] = .init(messages: [], nextPageToken: "second")
        f.pages["second"] = .init(messages: [message("one")], nextPageToken: nil)
        await f.open()
        #expect(f.mailbox.hasLoaded && f.mailbox.nextPageToken == "second")
        await f.mailbox.loadMore()?.value
        #expect(f.mailbox.messages.count == 1)
    }

    @Test func repeatedAndCyclicCursorsRejectTheWholePageWithoutAdvancing() async {
        for next in ["second", "third"] {
            let f = Fixture()
            f.pages["first"] = .init(messages: [message("one")], nextPageToken: "second")
            f.pages["second"] = .init(messages: [message("two")], nextPageToken: next)
            f.pages["third"] = .init(messages: [message("three")], nextPageToken: "second")
            await f.open()
            await f.mailbox.loadMore()?.value
            if next == "third" { await f.mailbox.loadMore()?.value }
            #expect(f.mailbox.messages.map(\.id) == (next == "second" ? ["one"] : ["one", "two"]))
            #expect(f.mailbox.nextPageToken == next && f.mailbox.status != nil)
        }
    }

    @Test func conflictingThreadIdentityRejectsPageRatherThanMergingDifferentMail() async {
        let f = Fixture()
        f.pages["first"] = .init(messages: [message("one")], nextPageToken: "second")
        f.pages["second"] = .init(messages: [message("two"), message("one", thread: "other-thread")], nextPageToken: nil)
        await f.open()
        await f.mailbox.loadMore()?.value
        #expect(f.mailbox.messages.map(\.id) == ["one"] && f.mailbox.nextPageToken == "second")
    }

    @Test func cancelledOldFolderPageCannotAppendToReplacementFolder() async throws {
        let f = Fixture(), gate = Gate()
        f.beforePage = { await gate.hold() }
        let old = f.mailbox.refresh(folder: .inbox, query: "old", provider: f.provider)
        try await gate.ready()
        f.beforePage = nil
        f.pages["first"] = .init(messages: [message("sent", labels: ["SENT"])], nextPageToken: nil)
        await f.open(.sent, query: "new")
        gate.release()
        await old?.value
        #expect(f.mailbox.messages.map(\.id) == ["sent"])
        #expect(f.mailbox.folder == .sent && f.mailbox.query == "new" && f.mailbox.status == nil)
    }

    @Test func onlyOneLoadMoreRunsAndClearingRejectsItsLateResult() async throws {
        let f = Fixture(), gate = Gate()
        f.pages["first"] = .init(messages: [message("one")], nextPageToken: "second")
        await f.open()
        f.beforePage = { await gate.hold() }
        let old = f.mailbox.loadMore()
        try await gate.ready()
        #expect(f.mailbox.loadMore() == nil)
        f.mailbox.clear()
        gate.release()
        await old?.value
        #expect(f.mailbox.messages.isEmpty && f.mailbox.nextPageToken == nil && !f.mailbox.isLoading)
        #expect(f.mailbox.status == nil)
    }

    @Test func accountOrRoleLossRejectsLateMailAndClearsTheCollection() async {
        let f = Fixture()
        f.pages["first"] = .init(messages: [message("one")], nextPageToken: "second")
        f.beforePage = { f.current = false }
        await f.open()
        #expect(f.mailbox.messages.isEmpty && f.mailbox.provider == nil && f.mailbox.status != nil)
    }

    @Test func refreshingCollectionDoesNotCancelOriginalDetailProvider() async throws {
        let f = Fixture()
        await f.open()
        let original = f.mailbox.provider
        await f.open(.sent)
        try #require(original).check()
    }

    @Test func allFiveActionsKeepBodyAndApplyOnlyConfirmedLabels() async {
        for action in GmailMailboxAction.allCases {
            let f = Fixture()
            let original = message("one", labels: action == .restore ? ["TRASH"] : ["INBOX", "UNREAD"])
            f.pages["first"] = .init(messages: [original], nextPageToken: nil)
            await f.open(action == .restore ? .trash : .allMail)
            await f.mailbox.perform(action, on: original)?.value
            #expect(f.writes.count == 1 && f.writes[0].0 == "one" && f.writes[0].1 == action)
            if let retained = f.mailbox.messages.first {
                #expect(action.confirmed(by: retained))
                #expect(retained.snippet == original.snippet && retained.payload?.headers?.count == 3)
            }
            #expect(f.mailbox.busyIDs.isEmpty)
        }
    }

    @Test func archiveLeavesInboxAndRestoreLeavesTrashWithoutInventingInboxMembership() async {
        for action in [GmailMailboxAction.archive, .restore, .trash] {
            let f = Fixture()
            let original = message("one", labels: action == .restore ? ["TRASH"] : ["INBOX"])
            f.pages["first"] = .init(messages: [original], nextPageToken: nil)
            await f.open(action == .restore ? .trash : .inbox)
            await f.mailbox.perform(action, on: original)?.value
            #expect(f.mailbox.messages.isEmpty && f.mailbox.status == action.confirmation)
        }
    }

    @Test func sameMessageCannotBeChangedTwiceAndFolderWaitsForConfirmation() async throws {
        let f = Fixture(), gate = Gate()
        let original = message("one")
        f.pages["first"] = .init(messages: [original], nextPageToken: "second")
        await f.open()
        f.beforeWrite = { await gate.hold() }
        let pending = f.mailbox.perform(.trash, on: original)
        try await gate.ready()
        #expect(f.mailbox.perform(.trash, on: original) == nil)
        #expect(f.mailbox.refresh(folder: .sent, query: "", provider: f.provider) == nil)
        #expect(f.mailbox.loadMore() == nil && f.mailbox.messages.count == 1)
        gate.release()
        await pending?.value
        #expect(f.writes.count == 1 && f.mailbox.messages.isEmpty)
    }

    @Test func uncertainActionDoesNotRemoveMailOrAutomaticallyRetry() async {
        let f = Fixture(), original = message("one")
        f.pages["first"] = .init(messages: [original], nextPageToken: nil)
        await f.open()
        f.failWrite = true
        await f.mailbox.perform(.trash, on: original)?.value
        #expect(f.mailbox.messages.count == 1 && f.writes.count == 1)
        #expect(f.mailbox.status?.contains("hasn't confirmed") == true && f.mailbox.busyIDs.isEmpty)
    }

    @Test func changedAccountCannotApplyLateActionOrLeaveBusyUIBehind() async {
        let f = Fixture(), original = message("one")
        f.pages["first"] = .init(messages: [original], nextPageToken: nil)
        await f.open()
        f.beforeWrite = { f.current = false }
        await f.mailbox.perform(.trash, on: original)?.value
        #expect(f.mailbox.messages.isEmpty && f.mailbox.busyIDs.isEmpty && f.mailbox.provider == nil)
        #expect(f.mailbox.status?.contains("original account") == true)
    }

    @Test func malformedOrWrongActionConfirmationDoesNotChangeLocalMail() async {
        for replacement in [message("different", labels: ["TRASH"]), message("one", labels: ["INBOX"]),
                            message("one", labels: ["TRASH"], thread: "different")] {
            let f = Fixture(), original = message("one")
            f.pages["first"] = .init(messages: [original], nextPageToken: nil)
            await f.open()
            f.replacement = replacement
            await f.mailbox.perform(.trash, on: original)?.value
            #expect(f.mailbox.messages.first?.labelIds == ["INBOX"] && f.mailbox.status?.contains("hasn't confirmed") == true)
        }
    }

    @Test func readStateIsRetainedAcrossAnOverlappingOlderPage() async {
        let f = Fixture(), original = message("one", labels: ["INBOX", "UNREAD"])
        f.pages["first"] = .init(messages: [original], nextPageToken: "second")
        f.pages["second"] = .init(messages: [original, message("two")], nextPageToken: nil)
        await f.open()
        await f.mailbox.perform(.read, on: original)?.value
        await f.mailbox.loadMore()?.value
        #expect(f.mailbox.messages.first?.labelIds == ["INBOX"])
        #expect(f.mailbox.perform(.read, on: original) == nil)
    }

    @Test func queryDependentActionRefreshesSearchUsingOriginalFolderAndProvider() async {
        let f = Fixture(), original = message("one", labels: ["INBOX", "UNREAD"])
        f.pages["first"] = .init(messages: [original], nextPageToken: nil)
        await f.open(query: "is:unread")
        f.beforeWrite = { f.pages["first"] = .init(messages: [], nextPageToken: nil) }
        await f.mailbox.perform(.read, on: original)?.value
        for _ in 0..<1_000 { if !f.mailbox.isLoading { break }; await Task.yield() }
        #expect(f.loads.count == 2 && f.loads.last?.1 == "is:unread")
        #expect(f.mailbox.messages.isEmpty && f.mailbox.hasLoaded)
    }

    @Test func anOldReaderCannotMutateAnIdenticalIDInAReplacementConnection() async {
        let f = Fixture(), original = message("one")
        f.pages["first"] = .init(messages: [original], nextPageToken: nil)
        await f.open()
        let oldProvider = f.provider
        f.current = false
        f.mailbox.clear()
        let replacement = WorkspaceProviderOperation { true }
        await f.mailbox.refresh(folder: .inbox, query: "", provider: replacement)?.value
        #expect(f.mailbox.perform(.trash, on: original, provider: oldProvider) == nil)
        #expect(f.writes.isEmpty && f.mailbox.messages.count == 1 && f.mailbox.provider === replacement)
    }

    @Test func accessLossBeforeActionSchedulingPreventsAnyMutation() async {
        let f = Fixture(), original = message("one")
        f.pages["first"] = .init(messages: [original], nextPageToken: nil)
        await f.open()
        f.current = false
        #expect(f.mailbox.perform(.trash, on: original) == nil)
        #expect(f.writes.isEmpty && f.mailbox.messages.isEmpty && f.mailbox.status != nil)
    }

    @Test func missingOrConflictingMessageCannotStartAnAction() async {
        let f = Fixture()
        f.pages["first"] = .init(messages: [message("one")], nextPageToken: nil)
        await f.open()
        #expect(f.mailbox.perform(.trash, on: message("missing")) == nil)
        #expect(f.mailbox.perform(.trash, on: message("one", thread: "other")) == nil)
        #expect(f.writes.isEmpty)
    }
}

@MainActor
struct GmailMailboxTransportTests {
    @MainActor private final class Fixture {
        var requests: [URLRequest] = []
        var status = 200
        var response: ((URLRequest) -> String)?
        lazy var auth = GoogleAuthManager(testTokens: .init(accessToken: "fixture-only", refreshToken: nil,
            idToken: nil, expiration: .distantFuture), email: "mail-fixture@gunnaire.com",
            businessEmail: { "mail-fixture@gunnaire.com" }) { [unowned self] request in
                requests.append(request)
                let text = response?(request) ?? #"{"messages":[],"nextPageToken":"next"}"#
                return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        func page(_ folder: GmailMailboxFolder = .inbox, query: String = "", token: String? = nil, size: Int = 25) async -> Result<GmailMailboxPage, Error> {
            await withCheckedContinuation { continuation in
                auth.fetchGmailMessagePage(folder: folder, query: query, pageToken: token, maxResults: size) { continuation.resume(returning: $0) }
            }
        }
        func change(_ action: GmailMailboxAction, id: String = "one", thread: String = "thread-one") async -> Result<GmailMessageDetail, Error> {
            await withCheckedContinuation { continuation in
                auth.changeGmailMessage(id: id, threadID: thread, action: action) { continuation.resume(returning: $0) }
            }
        }
    }

    @Test func folderSearchAndOpaqueCursorStaySeparateQueryParameters() async throws {
        for folder in GmailMailboxFolder.allCases {
            let f = Fixture()
            _ = try await f.page(folder, query: "from:vendor OR in:trash&labelIds=SPAM", token: "a+b&labelIds=SPAM#?").get()
            let request = try #require(f.requests.first)
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let items = try #require(components.queryItems)
            #expect(request.httpMethod == "GET" && url.host == "gmail.googleapis.com")
            #expect(items.filter { $0.name == "labelIds" }.compactMap(\.value) == (folder.labelID.map { [$0] } ?? []))
            #expect(items.first { $0.name == "q" }?.value == "from:vendor OR in:trash&labelIds=SPAM")
            #expect(items.first { $0.name == "pageToken" }?.value == "a+b&labelIds=SPAM#?")
            #expect(items.first { $0.name == "includeSpamTrash" }?.value == (folder == .trash ? "true" : "false"))
            #expect(components.fragment == nil)
        }
    }

    @Test func invalidCursorQueryOrPageSizeDoesNotIssueRequests() async {
        for token in ["", "bad\r\ntoken", String(repeating: "a", count: 8_193)] {
            let f = Fixture()
            if case .success = await f.page(token: token) { Issue.record("Invalid cursor accepted") }
            #expect(f.requests.isEmpty)
        }
        for size in [0, 51, Int.max, -1] {
            let f = Fixture()
            if case .success = await f.page(size: size) { Issue.record("Invalid page size accepted") }
            #expect(f.requests.isEmpty)
        }
        let f = Fixture()
        if case .success = await f.page(query: "bad\r\nquery") { Issue.record("Invalid query accepted") }
        #expect(f.requests.isEmpty)
    }

    @Test func completeMetadataPagePreservesProviderOrderAndNextCursor() async throws {
        let f = Fixture()
        f.response = { request in
            if request.url?.path.hasSuffix("/messages") == true {
                return #"{"messages":[{"id":"two","threadId":"thread-two"},{"id":"one","threadId":"thread-one"}],"nextPageToken":"next"}"#
            }
            let id = request.url!.lastPathComponent
            return "{\"id\":\"\(id)\",\"threadId\":\"thread-\(id)\",\"labelIds\":[\"INBOX\"]}"
        }
        let page = try await f.page().get()
        #expect(page.messages.map(\.id) == ["two", "one"] && page.nextPageToken == "next")
        #expect(f.requests.count == 3 && f.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func invalidDuplicateOrOversizedReferencePageNeverStartsFanout() async {
        for body in [
            #"{"messages":[{"id":"../one","threadId":"thread-one"}]}"#,
            #"{"messages":[{"id":"one","threadId":"thread/one"}]}"#,
            #"{"messages":[{"id":"one","threadId":"thread-one"},{"id":"one","threadId":"thread-one"}]}"#,
            #"{"messages":[{"id":"one","threadId":"thread-one"},{"id":"two","threadId":"thread-two"}]}"#,
            #"{"messages":[],"nextPageToken":""}"#
        ] {
            let f = Fixture()
            f.response = { _ in body }
            if case .success = await f.page(size: 1) { Issue.record("Invalid references accepted") }
            #expect(f.requests.count == 1)
        }
    }

    @Test func wrongMetadataIdentityOrMalformedPayloadRejectsWholePage() async {
        for body in [#"{"id":"different","threadId":"thread-one"}"#,
                     #"{"id":"one","threadId":"different"}"#, "not-json"] {
            let f = Fixture()
            f.response = { request in request.url?.path.hasSuffix("/messages") == true
                ? #"{"messages":[{"id":"one","threadId":"thread-one"}]}"# : body }
            if case .success = await f.page() { Issue.record("Incomplete page accepted") }
            #expect(f.requests.count == 2)
        }
    }

    @Test func eachActionUsesExactMessagePOSTAndExpectedLabelsOrEmptyBody() async throws {
        for action in GmailMailboxAction.allCases {
            let f = Fixture()
            f.response = { _ in
                let labels = action == .trash ? ["TRASH"] : action == .unread ? ["UNREAD"] : []
                return "{\"id\":\"one\",\"threadId\":\"thread-one\",\"labelIds\":\(String(data: try! JSONEncoder().encode(labels), encoding: .utf8)!)}"
            }
            _ = try await f.change(action).get()
            let request = try #require(f.requests.first)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/messages/one/\(action.endpoint)")
            if action == .trash || action == .restore { #expect(request.httpBody?.isEmpty != false) }
            else {
                let data = try #require(request.httpBody)
                let labels = try JSONDecoder().decode(GmailLabelModificationRequest.self, from: data)
                #expect(labels.addLabelIds == action.labels.addLabelIds && labels.removeLabelIds == action.labels.removeLabelIds)
            }
        }
    }

    @Test func mutationIdentifiersCannotInjectPathsQueriesOrFragments() async throws {
        let invalid = Fixture()
        if case .success = await invalid.change(.trash, id: "../other") { Issue.record("Invalid ID accepted") }
        #expect(invalid.requests.isEmpty)
        let f = Fixture()
        let id = "one?alt=media#frag"
        f.response = { _ in #"{"id":"one?alt=media#frag","threadId":"thread-one","labelIds":["TRASH"]}"# }
        _ = try await f.change(.trash, id: id).get()
        let components = try #require(URLComponents(url: f.requests[0].url!, resolvingAgainstBaseURL: false))
        #expect(components.query == nil && components.fragment == nil)
    }

    @Test func successfulHTTPDoesNotConfirmWrongMessageThreadOrDesiredState() async {
        for body in [#"{"id":"different","threadId":"thread-one","labelIds":["TRASH"]}"#,
                     #"{"id":"one","threadId":"different","labelIds":["TRASH"]}"#,
                     #"{"id":"one","threadId":"thread-one","labelIds":["INBOX"]}"#, "{}"] {
            let f = Fixture()
            f.response = { _ in body }
            if case .success = await f.change(.trash) { Issue.record("Unconfirmed change reported successful") }
            #expect(f.requests.count == 1)
        }
    }

    @Test func providerErrorsNeverRetryAMessageMutation() async {
        for status in [401, 403, 404, 429, 500] {
            let f = Fixture()
            f.status = status
            if case .success = await f.change(.trash) { Issue.record("Provider failure reported successful") }
            #expect(f.requests.count == 1)
        }
    }
}
