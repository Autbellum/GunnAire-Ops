import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct GmailAttachmentTests {
    private func body(_ data: Data, remote: String? = nil) -> GmailMessageBody {
        .init(data: remote == nil ? data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") : nil, size: data.count, attachmentId: remote)
    }

    private func part(_ name: String = "Equipment.txt", data: Data = Data("Fixture only".utf8),
                      remote: String? = nil) -> GmailAttachmentPart {
        .init(id: name, fileName: name, mimeType: "text/plain", body: body(data, remote: remote))
    }

    @MainActor private final class Fixture {
        var requests: [URLRequest] = []
        var current = true
        var status = 200
        var data = Data("Fixture only".utf8)
        var beforeResponse: (() -> Void)?
        lazy var auth = GoogleAuthManager(testTokens: .init(accessToken: "fixture-only",
            refreshToken: nil, idToken: nil, expiration: .distantFuture), email: "fixture@gunnaire.com",
            businessEmail: { "fixture@gunnaire.com" }) { [unowned self] request in
                requests.append(request)
                beforeResponse?()
                let body = GmailMessageBody(data: data.base64EncodedString(), size: data.count)
                return (try JSONEncoder().encode(body), HTTPURLResponse(url: request.url!,
                    statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        lazy var operation = WorkspaceProviderOperation { self.current }
    }

    @Test func base64URLDecodingUsesDecodedByteSizeNotEncodedLength() throws {
        let data = Data([251, 255, 0, 128, 10])
        #expect(try GmailAttachmentLoader.decode(body(data), expectedSize: data.count) == data)
    }

    @Test func malformedMissingAndMismatchedAttachmentDataAreRejected() {
        for value in [GmailMessageBody(data: "!invalid!", size: 2),
                      GmailMessageBody(data: nil, size: 1),
                      GmailMessageBody(data: "YWJj", size: 2),
                      GmailMessageBody(data: "", size: -1)] {
            #expect(throws: GmailComposeError.attachment) {
                try GmailAttachmentLoader.decode(value, expectedSize: nil)
            }
        }
        #expect(throws: GmailComposeError.attachment) {
            try GmailAttachmentLoader.decode(body(Data([1])), expectedSize: 2)
        }
    }

    @Test func validEmptyFilesAreRetainedInsteadOfSilentlyDiscarded() throws {
        let files = try GmailAttachmentLoader.inlineAttachments([part("Empty.txt", data: Data())])
        #expect(files.count == 1 && files[0].data.isEmpty)
        let message = try GmailOutgoingMessage(to: "fixture@example.invalid", subject: "Empty file", body: "Attached.", attachments: files)
        #expect(message.attachments.count == 1)
    }

    @Test func nestedAttachmentsStaySeparateFromTextBodyAndKeepOrder() throws {
        let file = GmailMessagePayload(headers: nil, mimeType: "text/plain", body: body(Data("Code file".utf8)), parts: nil, filename: "Code.txt")
        let text = GmailMessagePayload(headers: nil, mimeType: "text/plain", body: body(Data("Hello".utf8)), parts: nil, filename: nil)
        let nested = GmailMessagePayload(headers: nil, mimeType: "multipart/alternative", body: nil, parts: [text], filename: nil)
        let remote = GmailMessagePayload(headers: nil, mimeType: "image/png", body: body(Data([1]), remote: "image-id"), parts: nil, filename: "Photo.png")
        let payload = GmailMessagePayload(headers: nil, mimeType: "multipart/mixed", body: nil, parts: [file, nested, remote], filename: nil)
        let files = try GmailAttachmentLoader.parts(in: payload)
        #expect(files.map(\.fileName) == ["Code.txt", "Photo.png"])
        #expect(files.map(\.id) == ["0.0", "0.2"])
        #expect(GmailMessagePresentation.bodyText(from: payload) == "Hello")
    }

    @Test func unnamedInlineBinaryContentIsNotLostWhenForwarding() throws {
        let payload = GmailMessagePayload(headers: nil, mimeType: "image/png", body: body(Data([1, 2])), parts: nil, filename: nil)
        let files = try GmailAttachmentLoader.parts(in: payload)
        #expect(files.count == 1 && files[0].fileName == "Attachment")
    }

    @Test func overlyDeepAndTooManyMIMEPartsAreRejected() {
        var payload = GmailMessagePayload(headers: nil, mimeType: "text/plain", body: body(Data([1])), parts: nil, filename: "File.txt")
        let files = Array(repeating: payload, count: 51)
        let many = GmailMessagePayload(headers: nil, mimeType: "multipart/mixed", body: nil, parts: files, filename: nil)
        #expect(throws: GmailComposeError.attachment) { try GmailAttachmentLoader.parts(in: many) }
        for _ in 0..<32 {
            payload = GmailMessagePayload(headers: nil, mimeType: "multipart/mixed", body: nil, parts: [payload], filename: nil)
        }
        #expect(throws: GmailComposeError.attachment) { try GmailAttachmentLoader.parts(in: payload) }
    }

    @Test func attachmentHeaderAndAggregateBoundsAreEnforcedBeforeCompose() {
        let bad = GmailAttachment(fileName: "File\r\nBcc.txt", mimeType: "text/plain", data: Data([1]))
        #expect(throws: GmailComposeError.attachment) { try GmailOutgoingMessage.validateAttachments([bad]) }
        let large = GmailAttachment(fileName: "Large.txt", mimeType: "text/plain", data: Data(count: 12_500_001))
        #expect(throws: GmailComposeError.attachment) { try GmailOutgoingMessage.validateAttachments([large, large]) }
        let tooMany = Array(repeating: GmailAttachment(fileName: "File.txt", mimeType: "text/plain", data: Data()), count: 51)
        #expect(throws: GmailComposeError.attachment) { try GmailOutgoingMessage.validateAttachments(tooMany) }
    }

    @Test func embeddedLoaderCannotPretendARemoteFileWasLoaded() {
        #expect(throws: GmailComposeError.attachment) {
            try GmailAttachmentLoader.inlineAttachments([part(), part("Remote.txt", remote: "remote-id")])
        }
    }

    @Test func remoteDownloadUsesExactOriginalMessageAndAttachmentAndOnlyGET() async throws {
        let f = Fixture()
        let result = try await GmailAttachmentLoader.load([part(remote: "file-id")], messageID: "message-id", auth: f.auth, operation: f.operation)
        #expect(result.count == 1 && result[0].data == f.data)
        #expect(f.requests.count == 1)
        #expect(f.requests[0].httpMethod == "GET")
        #expect(f.requests[0].url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/messages/message-id/attachments/file-id")
    }

    @Test func invalidPathIdentifiersCannotIssueAnAttachmentRequest() async throws {
        for id in ["../secrets", "", "file/child"] {
            let f = Fixture()
            do {
                _ = try await GmailAttachmentLoader.load([part(remote: id)], messageID: "message-id", auth: f.auth, operation: f.operation)
                Issue.record("Invalid attachment identity was accepted")
            } catch { #expect(f.requests.isEmpty) }
        }
    }

    @Test func reservedCharactersRemainAnOpaqueAttachmentIDNotQueryOrFragment() async throws {
        let f = Fixture()
        _ = try await GmailAttachmentLoader.load([part(remote: "file?alt=media#part%20")], messageID: "message-id", auth: f.auth, operation: f.operation)
        #expect(f.requests.count == 1)
        let components = URLComponents(url: f.requests[0].url!, resolvingAgainstBaseURL: false)!
        #expect(components.query == nil && components.fragment == nil)
        #expect(components.percentEncodedPath.hasSuffix("/file%3Falt=media%23part%2520"))
    }

    @Test func partialDownloadFailureCannotReturnTheFirstFileAsACompleteForward() async throws {
        let f = Fixture()
        f.beforeResponse = { if f.requests.count == 2 { f.status = 404 } }
        do {
            _ = try await GmailAttachmentLoader.load([part("First.txt", remote: "first"), part("Second.txt", remote: "second")], messageID: "message-id", auth: f.auth, operation: f.operation)
            Issue.record("Partial forward was accepted")
        } catch { #expect(f.requests.count == 2) }
    }

    @Test func contextChangeDuringDownloadDiscardsResultAndStopsFollowingFiles() async throws {
        let f = Fixture()
        f.beforeResponse = { f.current = false }
        do {
            _ = try await GmailAttachmentLoader.load([part("First.txt", remote: "first"), part("Second.txt", remote: "second")], messageID: "message-id", auth: f.auth, operation: f.operation)
            Issue.record("Old account download was accepted")
        } catch { #expect(f.requests.count == 1) }
    }

    @Test func contextChangeBeforeInlineReadPreventsAnyFileFromEscaping() async throws {
        let f = Fixture(); f.current = false
        do {
            _ = try await GmailAttachmentLoader.load([part()], messageID: "message-id", auth: f.auth, operation: f.operation)
            Issue.record("Old context inline file was accepted")
        } catch { #expect(f.requests.isEmpty) }
    }

    @Test func previewUsesAnOwnedTemporaryDirectoryAndSanitizesPaths() throws {
        let file = GmailAttachment(fileName: "../../Equipment.txt", mimeType: "text/plain", data: Data("Fixture".utf8))
        let url = try GmailAttachmentLoader.previewFile(for: file)
        defer { GmailAttachmentLoader.removePreviewFile(url) }
        #expect(url.lastPathComponent == "Equipment.txt")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL)
        #expect(try Data(contentsOf: url) == file.data)
        GmailAttachmentLoader.removePreviewFile(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func remoteTextBodyLoadsBeforeReplyWithoutDownloadingUnopenedFiles() async throws {
        let f = Fixture()
        let text = GmailMessagePayload(headers: nil, mimeType: "text/plain", body: body(f.data, remote: "body-id"), parts: nil, filename: nil)
        let file = GmailMessagePayload(headers: nil, mimeType: "text/plain", body: body(f.data, remote: "file-id"), parts: nil, filename: "File.txt")
        let payload = GmailMessagePayload(headers: nil, mimeType: "multipart/mixed", body: nil, parts: [file, text], filename: nil)
        let message = GmailMessageDetail(id: "message-id", threadId: "thread-id", labelIds: ["INBOX"], snippet: "Partial snippet", internalDate: nil, payload: payload)
        let resolved = try await GmailAttachmentLoader.loadingTextBodies(in: message, auth: f.auth, operation: f.operation)
        #expect(GmailMessagePresentation.bodyText(from: resolved.payload) == "Fixture only")
        #expect(f.requests.count == 1 && f.requests[0].url?.lastPathComponent == "body-id")
        #expect(try GmailAttachmentLoader.parts(in: resolved.payload).first?.body.attachmentId == "file-id")
        #expect(resolved.threadId == message.threadId)
    }

    @Test func failedRemoteTextBodyCannotReturnSnippetAsCompleteReplyContent() async throws {
        let f = Fixture(); f.status = 404
        let payload = GmailMessagePayload(headers: nil, mimeType: "text/plain", body: body(f.data, remote: "body-id"), parts: nil, filename: nil)
        let message = GmailMessageDetail(id: "message-id", threadId: nil, labelIds: nil, snippet: "Incomplete", internalDate: nil, payload: payload)
        do {
            _ = try await GmailAttachmentLoader.loadingTextBodies(in: message, auth: f.auth, operation: f.operation)
            Issue.record("An incomplete body was returned")
        } catch { #expect(f.requests.count == 1) }
    }

    @Test func selectedFilesAreAddedTogetherAndAnUnreadableFilePreservesTheOriginalDraft() throws {
        let original = GmailAttachment(fileName: "Original.txt", mimeType: "text/plain", data: Data([1]))
        let urls = [URL(fileURLWithPath: "/fixture/First.txt"), URL(fileURLWithPath: "/fixture/Missing.txt")]
        #expect(throws: GmailComposeError.attachment) {
            try GmailOutgoingMessage.addingFiles(urls, to: [original]) { url in
                if url.lastPathComponent == "Missing.txt" { throw CocoaError(.fileReadNoSuchFile) }
                return Data([2])
            }
        }
        #expect(original.fileName == "Original.txt" && original.data == Data([1]))
        let added = try GmailOutgoingMessage.addingFiles([urls[0]], to: [original]) { _ in Data([2]) }
        #expect(added.map(\.fileName) == ["Original.txt", "First.txt"])
        #expect(added.map(\.data) == [Data([1]), Data([2])])
    }

    @Test func asynchronousFileImportRetainsSelectedBytesWithoutMutatingExistingFiles() async throws {
        let original = GmailAttachment(fileName: "Original.txt", mimeType: "text/plain", data: Data([1]))
        let source = GmailAttachment(fileName: "Selected.txt", mimeType: "text/plain", data: Data("Selected fixture".utf8))
        let url = try GmailAttachmentLoader.previewFile(for: source)
        defer { GmailAttachmentLoader.removePreviewFile(url) }
        let result = try await GmailOutgoingMessage.importingFiles([url], to: [original])
        #expect(result.map(\.fileName) == ["Original.txt", "Selected.txt"])
        #expect(result[1].data == source.data)
        #expect(try Data(contentsOf: url) == source.data)
        do {
            _ = try await GmailOutgoingMessage.importingFiles([url.deletingLastPathComponent()], to: [original])
            Issue.record("A directory was treated as a readable file")
        } catch { #expect(original.data == Data([1])) }
    }
}
