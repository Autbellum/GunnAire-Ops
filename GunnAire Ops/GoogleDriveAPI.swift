import Foundation

enum GoogleDriveAuthorizationState: Equatable {
    case disconnected
    case businessAccountMismatch
    case reauthorizationRequired
    case ready

    static func evaluate(
        isAuthenticated: Bool,
        businessIdentityMatches: Bool,
        hasDriveFileScope: Bool
    ) -> Self {
        guard isAuthenticated else { return .disconnected }
        guard businessIdentityMatches else { return .businessAccountMismatch }
        guard hasDriveFileScope else { return .reauthorizationRequired }
        return .ready
    }

    var title: String {
        switch self {
        case .disconnected: "Connect Google"
        case .businessAccountMismatch: "Account mismatch"
        case .reauthorizationRequired: "Reconnect required"
        case .ready: "Ready"
        }
    }

    var detail: String {
        switch self {
        case .disconnected:
            "Connect the approved GunnAire Google account in Settings."
        case .businessAccountMismatch:
            "The connected Google account must match the signed-in GunnAire business account."
        case .reauthorizationRequired:
            "Reconnect Google once to grant per-file Drive access. Existing Calendar and Gmail access stays unchanged."
        case .ready:
            "Files are archived with least-privilege per-file access; GunnAire cannot browse unrelated Drive content."
        }
    }
}

extension GoogleAuthManager {
    var googleDriveAuthorizationState: GoogleDriveAuthorizationState {
        GoogleDriveAuthorizationState.evaluate(
            isAuthenticated: isAuthenticated,
            businessIdentityMatches: canUseCurrentBusinessIdentity,
            hasDriveFileScope: hasGrantedScope(Config.Google.driveFileScope)
        )
    }
}

struct GoogleDriveFile: Codable, Equatable, Identifiable {
    let id: String
    let name: String?
    let mimeType: String?
    let webViewLink: String?
    let trashed: Bool?
    let appProperties: [String: String]?

    func matchesArchiveIdentity(_ metadata: GoogleDriveUploadMetadata) -> Bool {
        id == metadata.id &&
        appProperties?["gunnaireAttachmentID"] == metadata.appProperties["gunnaireAttachmentID"] &&
        appProperties?["gunnaireDocumentKind"] == metadata.appProperties["gunnaireDocumentKind"] &&
        appProperties?["gunnaireSchema"] == metadata.appProperties["gunnaireSchema"]
    }
}

struct GoogleDriveUploadMetadata: Codable, Equatable {
    let id: String
    let name: String
    let mimeType: String
    let appProperties: [String: String]

    static func document(
        fileID: String,
        displayName: String,
        mimeType: String,
        attachmentID: UUID,
        documentKind: String
    ) -> Self {
        Self(
            id: fileID,
            name: GoogleDriveRequestFactory.sanitizedFileName(displayName),
            mimeType: GoogleDriveRequestFactory.sanitizedMIMEType(mimeType),
            appProperties: [
                "gunnaireAttachmentID": attachmentID.uuidString.lowercased(),
                "gunnaireDocumentKind": String(documentKind.prefix(80)),
                "gunnaireSchema": "1"
            ]
        )
    }
}

enum GoogleDriveRequestFactory {
    static let returnedFileFields = "id,name,mimeType,webViewLink,trashed,appProperties"

    static func generateFileID(accessToken: String) throws -> URLRequest {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/generateIds")
        components?.queryItems = [
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "space", value: "drive"),
            URLQueryItem(name: "type", value: "files")
        ]
        guard let url = components?.url else { throw GoogleDriveAPIError.invalidEndpoint }
        return authorizedRequest(url: url, accessToken: accessToken)
    }

    static func fetchFile(fileID: String, accessToken: String) throws -> URLRequest {
        let validatedID = try validatedFileID(fileID)
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(validatedID)")
        components?.queryItems = [URLQueryItem(name: "fields", value: returnedFileFields)]
        guard let url = components?.url else { throw GoogleDriveAPIError.invalidEndpoint }
        return authorizedRequest(url: url, accessToken: accessToken)
    }

    static func initiateResumableUpload(
        metadata: GoogleDriveUploadMetadata,
        contentLength: Int,
        accessToken: String
    ) throws -> URLRequest {
        _ = try validatedFileID(metadata.id)
        var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")
        components?.queryItems = [
            URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "fields", value: returnedFileFields)
        ]
        guard let url = components?.url else { throw GoogleDriveAPIError.invalidEndpoint }
        var request = authorizedRequest(url: url, accessToken: accessToken)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(metadata.mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(contentLength), forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = try JSONEncoder().encode(metadata)
        return request
    }

    static func uploadContent(
        sessionURL: URL,
        data: Data,
        totalLength: Int,
        offset: Int,
        mimeType: String,
        accessToken: String
    ) throws -> URLRequest {
        try validateSessionURL(sessionURL)
        guard offset >= 0, offset < totalLength, data.count == totalLength - offset else {
            throw GoogleDriveAPIError.invalidUploadRange
        }
        var request = authorizedRequest(url: sessionURL, accessToken: accessToken)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.setValue(
            "bytes \(offset)-\(totalLength - 1)/\(totalLength)",
            forHTTPHeaderField: "Content-Range"
        )
        request.httpBody = data
        return request
    }

    static func queryUploadStatus(
        sessionURL: URL,
        totalLength: Int,
        accessToken: String
    ) throws -> URLRequest {
        try validateSessionURL(sessionURL)
        var request = authorizedRequest(url: sessionURL, accessToken: accessToken)
        request.httpMethod = "PUT"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.setValue("bytes */\(totalLength)", forHTTPHeaderField: "Content-Range")
        return request
    }

    static func nextUploadOffset(from rangeHeader: String?) -> Int {
        guard let rangeHeader,
              let finalComponent = rangeHeader.split(separator: "-").last,
              let finalByte = Int(finalComponent.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return finalByte + 1
    }

    static func sanitizedFileName(_ value: String) -> String {
        let disallowed = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = value.unicodeScalars
            .map { disallowed.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = cleaned.isEmpty ? "GunnAire Document" : cleaned
        guard fallback.count > 200 else { return fallback }

        let nsValue = fallback as NSString
        let pathExtension = nsValue.pathExtension
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension.prefix(20))"
        return "\(fallback.prefix(max(1, 200 - suffix.count)))\(suffix)"
    }

    static func sanitizedMIMEType(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        let tokenCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~"
        )
        guard components.count == 2,
              components.allSatisfy({ component in
                  !component.isEmpty && component.unicodeScalars.allSatisfy(tokenCharacters.contains)
              }) else {
            return "application/octet-stream"
        }
        return trimmed
    }

    static func validatedFileID(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !normalized.isEmpty,
              normalized.count <= 200,
              normalized.unicodeScalars.allSatisfy(allowed.contains) else {
            throw GoogleDriveAPIError.invalidFileID
        }
        return normalized
    }

    static func isTrustedWebViewLink(_ value: String?) -> Bool {
        guard let value,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "google.com" || host.hasSuffix(".google.com") else {
            return false
        }
        return true
    }

    private static func authorizedRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func validateSessionURL(_ url: URL) throws {
        let host = url.host?.lowercased() ?? ""
        guard url.scheme?.lowercased() == "https",
              host == "googleapis.com" || host.hasSuffix(".googleapis.com") else {
            throw GoogleDriveAPIError.invalidUploadSession
        }
    }
}

@MainActor
final class GoogleDriveAPI {
    static let shared = GoogleDriveAPI()

    private let authManager: GoogleAuthManager
    private let session: URLSession

    init(
        authManager: GoogleAuthManager,
        session: URLSession = .shared
    ) {
        self.authManager = authManager
        self.session = session
    }

    convenience init(session: URLSession = .shared) {
        self.init(authManager: .shared, session: session)
    }

    func generateFileID() async throws -> String {
        let token = try await validAccessToken()
        let request = try GoogleDriveRequestFactory.generateFileID(accessToken: token)
        let (data, response) = try await send(request)
        guard (200...299).contains(response.statusCode) else {
            throw providerError(data: data, statusCode: response.statusCode)
        }
        let payload = try decode(GoogleDriveGeneratedIDs.self, from: data)
        guard let rawID = payload.ids.first else {
            throw GoogleDriveAPIError.missingGeneratedFileID
        }
        return try GoogleDriveRequestFactory.validatedFileID(rawID)
    }

    func uploadFile(
        fileID: String,
        displayName: String,
        mimeType: String,
        attachmentID: UUID,
        documentKind: String,
        data: Data
    ) async throws -> GoogleDriveFile {
        guard !data.isEmpty else { throw GoogleDriveAPIError.emptyFile }
        let token = try await validAccessToken()

        let metadata = GoogleDriveUploadMetadata.document(
            fileID: try GoogleDriveRequestFactory.validatedFileID(fileID),
            displayName: displayName,
            mimeType: mimeType,
            attachmentID: attachmentID,
            documentKind: documentKind
        )

        if let existing = try await fetchFileIfPresent(fileID: fileID, accessToken: token) {
            return try validatedArchiveFile(existing, expected: metadata)
        }

        let initiation = try GoogleDriveRequestFactory.initiateResumableUpload(
            metadata: metadata,
            contentLength: data.count,
            accessToken: token
        )
        let (initiationData, initiationResponse) = try await send(initiation)
        if initiationResponse.statusCode == 409,
           let existing = try await fetchFileIfPresent(fileID: fileID, accessToken: token) {
            return try validatedArchiveFile(existing, expected: metadata)
        }
        guard (200...299).contains(initiationResponse.statusCode) else {
            throw providerError(data: initiationData, statusCode: initiationResponse.statusCode)
        }
        guard let location = initiationResponse.value(forHTTPHeaderField: "Location"),
              let sessionURL = URL(string: location) else {
            throw GoogleDriveAPIError.missingUploadSession
        }
        return try await uploadThroughSession(
            sessionURL: sessionURL,
            data: data,
            mimeType: metadata.mimeType,
            accessToken: token,
            expectedMetadata: metadata
        )
    }

    func fetchFileIfPresent(fileID: String) async throws -> GoogleDriveFile? {
        let token = try await validAccessToken()
        return try await fetchFileIfPresent(fileID: fileID, accessToken: token)
    }

    private func fetchFileIfPresent(
        fileID: String,
        accessToken: String
    ) async throws -> GoogleDriveFile? {
        let request = try GoogleDriveRequestFactory.fetchFile(
            fileID: fileID,
            accessToken: accessToken
        )
        let (data, response) = try await send(request)
        if response.statusCode == 404 { return nil }
        guard (200...299).contains(response.statusCode) else {
            throw providerError(data: data, statusCode: response.statusCode)
        }
        return try decode(GoogleDriveFile.self, from: data)
    }

    private func uploadThroughSession(
        sessionURL: URL,
        data: Data,
        mimeType: String,
        accessToken: String,
        expectedMetadata: GoogleDriveUploadMetadata
    ) async throws -> GoogleDriveFile {
        var offset = 0
        var shouldQueryStatus = false

        for _ in 0..<4 {
            do {
                let request: URLRequest
                if shouldQueryStatus {
                    request = try GoogleDriveRequestFactory.queryUploadStatus(
                        sessionURL: sessionURL,
                        totalLength: data.count,
                        accessToken: accessToken
                    )
                } else {
                    request = try GoogleDriveRequestFactory.uploadContent(
                        sessionURL: sessionURL,
                        data: Data(data.dropFirst(offset)),
                        totalLength: data.count,
                        offset: offset,
                        mimeType: mimeType,
                        accessToken: accessToken
                    )
                }

                let (responseData, response) = try await send(request)
                switch response.statusCode {
                case 200, 201:
                    let file = try decode(GoogleDriveFile.self, from: responseData)
                    return try validatedArchiveFile(file, expected: expectedMetadata)
                case 308:
                    offset = GoogleDriveRequestFactory.nextUploadOffset(
                        from: response.value(forHTTPHeaderField: "Range")
                    )
                    guard offset < data.count else {
                        throw GoogleDriveAPIError.invalidUploadRange
                    }
                    shouldQueryStatus = false
                case 500...599:
                    shouldQueryStatus = true
                default:
                    throw providerError(data: responseData, statusCode: response.statusCode)
                }
            } catch let error as GoogleDriveAPIError {
                guard error == .network else { throw error }
                // A dropped upload response is ambiguous. Always reconcile the
                // server offset before sending content again; status queries are
                // idempotent and may themselves be retried within this budget.
                shouldQueryStatus = true
            }
        }
        throw GoogleDriveAPIError.uploadIncomplete
    }

    private func validatedArchiveFile(
        _ file: GoogleDriveFile,
        expected metadata: GoogleDriveUploadMetadata
    ) throws -> GoogleDriveFile {
        guard file.trashed != true else { throw GoogleDriveAPIError.fileIsTrashed }
        guard file.matchesArchiveIdentity(metadata) else {
            throw GoogleDriveAPIError.archiveIdentityMismatch
        }
        guard GoogleDriveRequestFactory.isTrustedWebViewLink(file.webViewLink) else {
            throw GoogleDriveAPIError.invalidFileMetadata
        }
        return file
    }

    private func validAccessToken() async throws -> String {
        switch authManager.googleDriveAuthorizationState {
        case .disconnected:
            throw GoogleDriveAPIError.notAuthenticated
        case .businessAccountMismatch:
            throw GoogleDriveAPIError.businessAccountMismatch
        case .reauthorizationRequired:
            throw GoogleDriveAPIError.driveScopeRequired
        case .ready:
            break
        }

        try await withCheckedThrowingContinuation { continuation in
            authManager.refreshTokensIfNeeded { result in
                continuation.resume(with: result)
            }
        }
        guard authManager.canUseCurrentBusinessIdentity,
              authManager.hasGrantedScope(Config.Google.driveFileScope),
              let token = authManager.accessToken,
              !token.isEmpty else {
            throw GoogleDriveAPIError.authorizationChanged
        }
        return token
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw GoogleDriveAPIError.invalidResponse
            }
            return (data, response)
        } catch let error as GoogleDriveAPIError {
            throw error
        } catch {
            throw GoogleDriveAPIError.network
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GoogleDriveAPIError.decoding
        }
    }

    private func providerError(data: Data, statusCode: Int) -> GoogleDriveAPIError {
        let message = (try? JSONDecoder().decode(GoogleDriveErrorEnvelope.self, from: data))?.error.message
        return .provider(statusCode: statusCode, message: message)
    }
}

enum GoogleDriveAPIError: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case invalidFileID
    case invalidUploadSession
    case invalidUploadRange
    case invalidResponse
    case notAuthenticated
    case businessAccountMismatch
    case driveScopeRequired
    case authorizationChanged
    case missingGeneratedFileID
    case missingUploadSession
    case emptyFile
    case fileIsTrashed
    case archiveIdentityMismatch
    case invalidFileMetadata
    case uploadIncomplete
    case network
    case decoding
    case provider(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Google Drive endpoint is invalid."
        case .invalidFileID: "The saved Google Drive file identifier is invalid."
        case .invalidUploadSession: "Google returned an untrusted upload session."
        case .invalidUploadRange: "Google Drive upload progress was inconsistent."
        case .invalidResponse: "Google Drive returned an invalid response."
        case .notAuthenticated: "Connect the approved GunnAire Google account first."
        case .businessAccountMismatch: "The connected Google account does not match the signed-in GunnAire business account."
        case .driveScopeRequired: "Reconnect Google to grant least-privilege per-file Drive access."
        case .authorizationChanged: "Google authorization changed during the upload. Reconnect and retry."
        case .missingGeneratedFileID: "Google Drive did not reserve a file identifier."
        case .missingUploadSession: "Google Drive did not start a resumable upload session."
        case .emptyFile: "The selected document is empty and was not uploaded."
        case .fileIsTrashed: "The existing Drive copy is in Trash. Restore it or create a new archive copy."
        case .archiveIdentityMismatch: "The saved Drive file does not belong to this GunnAire attachment. Archive recovery stopped without linking it."
        case .invalidFileMetadata: "Google Drive returned an untrusted or incomplete file link."
        case .uploadIncomplete: "Google Drive upload did not finish. The same reserved file will be retried."
        case .network: "Google Drive could not be reached. The same reserved file will be retried."
        case .decoding: "Google Drive response could not be read."
        case .provider(let statusCode, let message):
            "Google Drive request failed (HTTP \(statusCode))\(message.map { ": \($0)" } ?? "")."
        }
    }
}

private struct GoogleDriveGeneratedIDs: Codable {
    let ids: [String]
}

private struct GoogleDriveErrorEnvelope: Codable {
    let error: GoogleDriveErrorPayload
}

private struct GoogleDriveErrorPayload: Codable {
    let message: String
}
