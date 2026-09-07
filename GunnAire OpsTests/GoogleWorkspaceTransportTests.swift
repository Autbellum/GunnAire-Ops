import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct GoogleWorkspaceTransportTests {
    private let email = "provider-fixture@gunnaire.com"

    private func manager(expired: Bool = false, businessEmail: (() -> String?)? = nil,
                         transport: @escaping WorkspaceProviderOperation.Transport) -> GoogleAuthManager {
        GoogleAuthManager(
            testTokens: GoogleOAuthTokens(
                accessToken: "fixture-bearer", refreshToken: "fixture-refresh", idToken: nil,
                expiration: expired ? .distantPast : .distantFuture,
                scopeSignature: Config.Google.scopeSignature(for: [Config.Google.driveFileScope])
            ),
            email: email, businessEmail: businessEmail ?? { email }, transport: transport
        )
    }

    private func response(_ request: URLRequest, _ payload: String = "{}", status: Int = 200,
                          headers: [String: String]? = nil) -> (Data, URLResponse) {
        (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
             httpVersion: nil, headerFields: headers)!)
    }

    private enum Family: CaseIterable {
        case profile, mailRead, mailSend, mailTrash, calendarRead, calendarCreate, calendarPatch, calendarDelete
        var isWrite: Bool {
            switch self {
            case .profile, .mailRead, .calendarRead: false
            default: true
            }
        }
        var payload: String {
            switch self {
            case .profile: #"{"sub":"fixture-subject","email":"provider-fixture@gunnaire.com","hd":"gunnaire.com"}"#
            case .mailRead: #"{"id":"fixture-message"}"#
            case .mailSend: #"{"id":"fixture-message","threadId":"fixture-thread"}"#
            case .mailTrash: #"{"id":"fixture-message","threadId":"fixture-thread","labelIds":["TRASH"]}"#
            case .calendarDelete: "{}"
            case .calendarRead: #"{"items":[{"id":"fixture-calendar"}]}"#
            case .calendarCreate, .calendarPatch: #"{"id":"fixture-event","start":{},"end":{}}"#
            }
        }
    }

    private func invoke(_ family: Family, _ auth: GoogleAuthManager,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        let date = GoogleWritableCalendarEventDate(dateTime: "2026-09-07T12:00:00Z", timeZone: "UTC")
        switch family {
        case .profile: auth.fetchUserProfile { completion($0.map { _ in () }) }
        case .mailRead: auth.fetchGmailMessage(id: "fixture-message") { completion($0.map { _ in () }) }
        case .mailSend: auth.sendGmailMessage(to: "recipient@example.invalid", subject: "Fixture", body: "Not sent") { completion($0.map { _ in () }) }
        case .mailTrash: auth.moveGmailMessageToTrash(id: "fixture-message", completion: completion)
        case .calendarRead: auth.fetchCalendars { completion($0.map { _ in () }) }
        case .calendarCreate:
            auth.createCalendarEvent(event: GoogleWritableCalendarEvent(
                summary: "Fixture", description: nil, location: nil, start: date, end: date,
                attendees: nil, extendedProperties: nil)) { completion($0.map { _ in () }) }
        case .calendarPatch:
            auth.patchCalendarEvent(eventID: "fixture-event", patch: GoogleCalendarEventPatch(start: date, end: nil)) { completion($0.map { _ in () }) }
        case .calendarDelete: auth.deleteCalendarEvent(eventID: "fixture-event", completion: completion)
        }
    }

    @Test func everyGoogleRequestFamilyDeliversValidResultsWithinTheOriginalConnection() async throws {
        for family in Family.allCases {
            var requests: [URLRequest] = []
            let auth = manager { request in
                requests.append(request)
                return response(request, family.payload)
            }
            let result = await withCheckedContinuation { continuation in
                invoke(family, auth) { continuation.resume(returning: $0) }
            }
            try result.get()
            #expect(requests.count == 1)
            #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-bearer")
        }
    }

    @Test func everyGoogleRequestFamilyRejectsResponsesAfterSignOutWithoutRestoringIdentity() async {
        for family in Family.allCases {
            for status in [200, 401] {
                var requests: [URLRequest] = []
                var auth: GoogleAuthManager!
                auth = manager { request in
                    requests.append(request)
                    await Task.yield()
                    auth.signOut()
                    return response(request, family.payload, status: status)
                }
                let result = await withCheckedContinuation { continuation in
                    invoke(family, auth) { continuation.resume(returning: $0) }
                }
                if case .failure(let error) = result {
                    #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: family.isWrite))
                } else { Issue.record("Stale Google result escaped for \(family)") }
                #expect(requests.count == 1)
                #expect(auth.accessToken == nil)
                #expect(auth.signedInEmail == nil)
                #expect(!auth.isAuthenticated)
            }
        }
    }

    @Test func identityBootstrapWorksBeforeBusinessLinkButCannotBypassOperationalAccess() async throws {
        var requests: [URLRequest] = []
        let auth = manager(businessEmail: { nil }) { request in
            requests.append(request)
            return response(request, Family.profile.payload)
        }
        let profile: GoogleUserProfile = try await withCheckedThrowingContinuation { continuation in
            auth.fetchUserProfile { continuation.resume(with: $0) }
        }
        #expect(profile.email == email)
        #expect(!auth.canUseCurrentBusinessIdentity)
        let result = await withCheckedContinuation { continuation in
            auth.fetchCalendars { continuation.resume(returning: $0) }
        }
        if case .success = result { Issue.record("Operational access escaped the business-account check") }
        #expect(requests.count == 1)
        #expect(requests[0].url?.path == "/oauth2/v3/userinfo")
    }

    @Test func businessLoginReplacementRejectsAnOtherwiseValidGoogleResponse() async {
        var businessEmail: String? = email
        let auth = manager(businessEmail: { businessEmail }) { request in
            businessEmail = "replacement@example.invalid"
            return response(request, Family.mailRead.payload)
        }
        let result = await withCheckedContinuation { continuation in
            auth.fetchGmailMessage(id: "fixture-message") { continuation.resume(returning: $0) }
        }
        if case .failure(let error) = result {
            #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: false))
        } else { Issue.record("Message from the prior business login was returned") }
        #expect(auth.signedInEmail == email)
        #expect(auth.accessToken == "fixture-bearer")
    }

    @Test func signOutDuringOAuthRefreshCannotRestoreTokensOrSendMail() async {
        var requests: [URLRequest] = []
        var auth: GoogleAuthManager!
        auth = manager(expired: true) { request in
            requests.append(request)
            auth.signOut()
            return response(request, #"{"access_token":"late-fixture-bearer","expires_in":3600}"#)
        }
        let result = await withCheckedContinuation { continuation in
            auth.sendGmailMessage(to: "recipient@example.invalid", subject: "Fixture", body: "Not sent") {
                continuation.resume(returning: $0)
            }
        }
        if case .failure(let error) = result {
            #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: false))
        } else { Issue.record("Mail was sent after sign-out") }
        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString == Config.Google.tokenEndpoint)
        #expect(auth.accessToken == nil)
        #expect(auth.refreshToken == nil)
    }

    @Test func refreshedBearerRemainsUsableWithinTheSameConnection() async throws {
        var requests: [URLRequest] = []
        let auth = manager(expired: true) { request in
            requests.append(request)
            if requests.count == 1 {
                return response(request, #"{"access_token":"refreshed-fixture-bearer","expires_in":3600}"#)
            }
            return response(request, Family.mailRead.payload)
        }
        let message: GmailMessageDetail = try await withCheckedThrowingContinuation { continuation in
            auth.fetchGmailMessage(id: "fixture-message") { continuation.resume(with: $0) }
        }
        #expect(message.id == "fixture-message")
        #expect(requests.count == 2)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-fixture-bearer")
        #expect(auth.signedInEmail == email)
    }

    @Test func calendarPaginationAndGmailFanoutDiscardTheWholeOldResult() async {
        for mail in [false, true] {
            var count = 0
            var auth: GoogleAuthManager!
            auth = manager { request in
                count += 1
                if count == 1 {
                    return response(request, mail
                        ? #"{"messages":[{"id":"fixture-message","threadId":"fixture-thread"}]}"#
                        : #"{"items":[{"id":"page-one"}],"nextPageToken":"next-page"}"#)
                }
                auth.signOut()
                return response(request, mail ? Family.mailRead.payload : #"{"items":[{"id":"page-two"}]}"#)
            }
            let result: Result<Void, Error> = await withCheckedContinuation { continuation in
                if mail {
                    auth.fetchGmailMessages { continuation.resume(returning: $0.map { _ in () }) }
                } else {
                    auth.fetchCalendars { continuation.resume(returning: $0.map { _ in () }) }
                }
            }
            if case .failure(let error) = result {
                #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: false))
            } else { Issue.record("Partial prior-account aggregate escaped") }
            #expect(count == 2)
        }
    }

    @Test func driveUploadStopsAtEveryChangedConnectionBoundaryIncludingRecovery() async {
        for disconnectAt in 1...4 {
            let auth = manager { _ in
                Issue.record("A non-expiring fixture must not refresh credentials")
                throw URLError(.unsupportedURL)
            }
            var count = 0
            let drive = GoogleDriveAPI(authManager: auth, transport: { request in
                count += 1
                if count == disconnectAt {
                    auth.signOut()
                    return response(request)
                }
                if count == 1 { return response(request, status: 404) }
                if count == 2 {
                    return response(request, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture"])
                }
                throw URLError(.networkConnectionLost)
            })
            do {
                _ = try await drive.uploadFile(fileID: "fixture-file", displayName: "Fixture.txt", mimeType: "text/plain",
                    attachmentID: UUID(), documentKind: "serviceReport", data: Data("fixture".utf8))
                Issue.record("Drive continued an old upload")
            } catch {
                #expect(error as? WorkspaceProviderAccessError == .changed(mayHaveReachedProvider: disconnectAt > 1))
            }
            #expect(count == disconnectAt)
        }
    }

    @Test func driveDroppedResponseReconcilesTheSameUploadAndReservedFile() async throws {
        let auth = manager { _ in throw URLError(.unsupportedURL) }
        let attachmentID = UUID()
        let metadata = GoogleDriveUploadMetadata.document(fileID: "fixture-file", displayName: "Fixture.txt",
            mimeType: "text/plain", attachmentID: attachmentID, documentKind: "serviceReport")
        let file = GoogleDriveFile(id: metadata.id, name: metadata.name, mimeType: metadata.mimeType,
            webViewLink: "https://drive.google.com/file/d/fixture-file/view", trashed: false, appProperties: metadata.appProperties)
        var requests: [URLRequest] = []
        let drive = GoogleDriveAPI(authManager: auth, transport: { request in
            requests.append(request)
            switch requests.count {
            case 1: return response(request, status: 404)
            case 2: return response(request, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture"])
            case 3: throw URLError(.networkConnectionLost)
            default: return (try JSONEncoder().encode(file), response(request).1)
            }
        })
        let result = try await drive.uploadFile(fileID: metadata.id, displayName: metadata.name, mimeType: metadata.mimeType,
            attachmentID: attachmentID, documentKind: "serviceReport", data: Data("fixture".utf8))
        #expect(result == file)
        #expect(requests.count == 4)
        guard requests.count == 4 else { return }
        #expect(requests[2].url == requests[3].url)
        #expect(requests[2].httpMethod == "PUT")
        #expect(requests[3].httpMethod == "PUT")
        #expect(requests[3].value(forHTTPHeaderField: "Content-Range") == "bytes */7")
        #expect(requests[3].httpBody?.isEmpty != false)
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 1)
    }
}
