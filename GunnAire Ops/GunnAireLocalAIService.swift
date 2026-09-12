import Foundation

/// JSON-safe context passed to the authenticated local-AI gateway.
/// The gateway rejects secret-bearing keys and values before inference.
indirect enum GunnAireLocalAIValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([GunnAireLocalAIValue])
    case object([String: GunnAireLocalAIValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([GunnAireLocalAIValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: GunnAireLocalAIValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported local-AI JSON value."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct GunnAireLocalAITaskModel: Codable, Equatable, Sendable {
    let role: String
    let model: String
}

struct GunnAireLocalAIStatus: Codable, Equatable, Sendable {
    let enabled: Bool
    let available: Bool
    let status: String
    let code: String?
    let provider: String
    let local: Bool
    let endpointScope: String
    let hostedFallbackEnabled: Bool
    let hostedCreditsUsed: Int
    let stableDiffusionScope: String
    let supportedTasks: [String]
    let serviceVersion: String?
    let installedModels: [String]?
    let missingModels: [String]?
    let availableTasks: [String]?
    let unavailableTasks: [String]?
    let taskModels: [String: GunnAireLocalAITaskModel]?

    var isLocalOnly: Bool {
        local && provider.caseInsensitiveCompare("ollama") == .orderedSame && !hostedFallbackEnabled
    }

    var displayTitle: String {
        if available && status == "ready" { return "Local AI Ready" }
        if available { return "Local AI Partially Ready" }
        if !enabled { return "Local AI Disabled" }
        return "Local AI Unavailable"
    }

    var displayDetail: String {
        if available {
            let count = availableTasks?.count ?? supportedTasks.count
            return "\(count) task\(count == 1 ? "" : "s") available through loopback Ollama. Hosted fallback is off."
        }
        return "The app will retain deterministic behavior and will not consume hosted-model credits."
    }
}

struct GunnAireLocalAIAssistRequest: Codable, Equatable, Sendable {
    let task: String
    let input: String
    let context: [String: GunnAireLocalAIValue]
    let baseline: [String: GunnAireLocalAIValue]

    init(
        task: String,
        input: String,
        context: [String: GunnAireLocalAIValue] = [:],
        baseline: [String: GunnAireLocalAIValue] = [:]
    ) {
        self.task = task
        self.input = input
        self.context = context
        self.baseline = baseline
    }
}

struct GunnAireLocalAIResult: Codable, Equatable, Sendable {
    let subject: String?
    let body: String?
    let headline: String?
    let summary: String?
    let documentType: String?
    let confidence: Double?
    let reason: String?
    let scope: String?
    let warnings: [String]?
    let priorities: [String]?
    let observations: [String]?
    let followUp: [String]?
    let exclusions: [String]?
    let clarifications: [String]?
    let likelyCauses: [String]?
    let recommendedChecks: [String]?
    let findings: [String]?
    let requiredControls: [String]?
    let tests: [String]?

    enum CodingKeys: String, CodingKey {
        case subject, body, headline, summary, confidence, reason, scope, warnings
        case priorities, observations, exclusions, clarifications, findings, tests
        case documentType = "document_type"
        case followUp = "follow_up"
        case likelyCauses = "likely_causes"
        case recommendedChecks = "recommended_checks"
        case requiredControls = "required_controls"
    }

    func displayText(for task: GunnAireLocalAITask) -> String {
        var sections: [(String?, String)] = []
        func append(_ title: String?, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            sections.append((title, value))
        }
        func appendList(_ title: String, _ values: [String]?) {
            let values = (values ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !values.isEmpty else { return }
            sections.append((title, values.map { "• \($0)" }.joined(separator: "\n")))
        }

        switch task {
        case .customerEmailDraft:
            append("Subject", subject)
            append("Draft", body)
        case .customerTextDraft:
            append("Draft", body)
        case .operationsNarrative:
            append(nil, headline)
            append("Management Brief", summary)
            appendList("Priorities", priorities)
        case .serviceNoteSummary:
            append("Summary", summary)
            appendList("Observed Facts", observations)
            appendList("Follow-Up", followUp)
        case .documentClassification:
            append("Document Type", documentType)
            if let confidence { append("Confidence", confidence.formatted(.percent.precision(.fractionLength(0)))) }
            append("Reason", reason)
        case .estimateScopeDraft:
            append("Scope", scope)
            appendList("Exclusions", exclusions)
            appendList("Clarifications", clarifications)
        case .failureTriage:
            append("Summary", summary)
            appendList("Likely Causes", likelyCauses)
            appendList("Recommended Checks", recommendedChecks)
        case .securityReview:
            append("Summary", summary)
            appendList("Findings", findings)
            appendList("Required Controls", requiredControls)
            appendList("Tests", tests)
        }
        appendList("Warnings", warnings)
        return sections.map { title, value in
            title.map { "\($0)\n\(value)" } ?? value
        }.joined(separator: "\n\n")
    }
}

struct GunnAireLocalAIMetrics: Codable, Equatable, Sendable {
    let elapsedSeconds: Double?
    let promptEvalCount: Int?
    let evalCount: Int?

    enum CodingKeys: String, CodingKey {
        case elapsedSeconds = "elapsed_seconds"
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
    }
}

struct GunnAireLocalAIAssistResponse: Codable, Equatable, Sendable {
    let requestID: String
    let generatedAt: String
    let task: String
    let provider: String
    let model: String
    let local: Bool
    let cached: Bool
    let advisoryOnly: Bool
    let hostedFallbackUsed: Bool
    let hostedCreditsUsed: Int
    let stableDiffusionUsed: Bool
    let needsHumanApproval: Bool
    let redactions: Int
    let inputDigest: String
    let metrics: GunnAireLocalAIMetrics
    let result: GunnAireLocalAIResult
}

private struct GunnAireLocalAIErrorPayload: Codable {
    let error: String
    let code: String?
}

enum GunnAireLocalAIServiceError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case missingBusinessIdentity
    case invalidResponse
    case server(statusCode: Int, code: String?, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "The GunnAire backend is not configured."
        case .invalidURL:
            return "The GunnAire local-AI backend URL is invalid."
        case .missingBusinessIdentity:
            return "Sign in with Apple or Google again before using the local assistant."
        case .invalidResponse:
            return "The local assistant returned an invalid response."
        case .server(let statusCode, let code, let message):
            let suffix = code.map { " [\($0)]" } ?? ""
            return "Local AI returned HTTP \(statusCode)\(suffix): \(message)"
        }
    }
}

enum GunnAireLocalAIService {
    static func fetchStatus() async throws -> GunnAireLocalAIStatus {
        let data = try await send(path: "/api/local-ai/status", method: "GET", body: nil)
        do {
            return try JSONDecoder().decode(GunnAireLocalAIStatus.self, from: data)
        } catch {
            throw GunnAireLocalAIServiceError.invalidResponse
        }
    }

    static func assist(_ request: GunnAireLocalAIAssistRequest) async throws -> GunnAireLocalAIAssistResponse {
        let body: Data
        do {
            body = try JSONEncoder().encode(request)
        } catch {
            throw GunnAireLocalAIServiceError.invalidResponse
        }
        let data = try await send(path: "/api/local-ai/assist", method: "POST", body: body)
        do {
            let response = try JSONDecoder().decode(GunnAireLocalAIAssistResponse.self, from: data)
            guard response.local,
                  response.provider.caseInsensitiveCompare("ollama") == .orderedSame,
                  !response.hostedFallbackUsed,
                  response.hostedCreditsUsed == 0,
                  !response.stableDiffusionUsed,
                  response.advisoryOnly,
                  response.needsHumanApproval else {
                throw GunnAireLocalAIServiceError.invalidResponse
            }
            return response
        } catch let error as GunnAireLocalAIServiceError {
            throw error
        } catch {
            throw GunnAireLocalAIServiceError.invalidResponse
        }
    }

    private static func send(path: String, method: String, body: Data?) async throws -> Data {
        guard Config.Backend.isConfigured else {
            throw GunnAireLocalAIServiceError.notConfigured
        }
        guard let url = URL(string: "\(Config.Backend.normalizedBaseURL)\(path)") else {
            throw GunnAireLocalAIServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 130
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        try applyAuthentication(to: &request)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 130
        configuration.timeoutIntervalForResource = 140
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GunnAireLocalAIServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(GunnAireLocalAIErrorPayload.self, from: data)
            let message = payload?.error
                ?? String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GunnAireLocalAIServiceError.server(
                statusCode: http.statusCode,
                code: payload?.code,
                message: message
            )
        }
        return data
    }

    private static func applyAuthentication(to request: inout URLRequest) throws {
        if Config.Backend.usesBusinessIdentity {
            if let token = AppleAuthManager.shared.sessionToken?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } else if let token = GoogleAuthManager.shared.applicationSessionToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } else if let token = GoogleAuthManager.shared.idToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: "X-GunnAire-Google-ID-Token")
            } else {
                throw GunnAireLocalAIServiceError.missingBusinessIdentity
            }
        } else {
            request.setValue("Bearer \(Config.Backend.apiToken)", forHTTPHeaderField: "Authorization")
        }
    }
}
