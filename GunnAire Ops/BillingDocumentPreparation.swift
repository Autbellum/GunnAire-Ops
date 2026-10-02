import Foundation
import SwiftData

/// Owns only a newly rendered URL until a caller adopts it for a preview,
/// attachment or draft. A later source change cannot erase a retained export.
@MainActor
final class BillingDocumentExportPublication {
    private let url: URL
    private let check: () throws -> Void
    private var adopted = false

    init(url: URL, check: @escaping () throws -> Void) {
        self.url = url
        self.check = check
    }

    func validate() throws {
        do { try check() }
        catch {
            if !adopted { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// Call immediately after a successful save, or immediately before a
    /// synchronous UI/draft handoff whose final validation already passed.
    func adopt() {
        adopted = true
    }
}

/// Keeps a document preparation on the authority captured by its initiating
/// action, including byte reads after the PDF renderer has suspended.
@MainActor
final class BillingDocumentPreparation {
    @TaskLocal static var exportOperation: WorkspaceProviderOperation?
    private let operation: WorkspaceProviderOperation
    private let provider: QuickBooksDataAPI.CapturedWorkspaceWorkflow?
    private let validate: () throws -> Void

    static func membership<Model: PersistentModel>(_ models: [Model], in context: ModelContext) -> () throws -> Void {
        let identifiers = models.map(\.persistentModelID)
        return {
            for (model, identifier) in zip(models, identifiers) {
                guard model.modelContext === context, !model.isDeleted,
                      model.persistentModelID == identifier,
                      let registered: Model = context.registeredModel(for: identifier), registered === model
                else { throw GmailDraftError.businessChanged }
            }
        }
    }

    init(operation: WorkspaceProviderOperation,
         provider: QuickBooksDataAPI.CapturedWorkspaceWorkflow? = nil,
         validate: @escaping () throws -> Void) throws {
        self.operation = operation
        self.provider = provider
        self.validate = validate
        try check()
    }

    static func capture(api: QuickBooksDataAPI? = nil,
                        isCurrent: @escaping () -> Bool,
                        validate: @escaping () throws -> Void) throws -> BillingDocumentPreparation {
        let api = api ?? .shared
        let connected = api.isAuthenticated
        let provider = connected ? try api.captureWorkspaceWorkflow() : nil
        let operation = try WorkspaceProviderOperation.capture {
            isCurrent() && api.isAuthenticated == connected
        }
        return try BillingDocumentPreparation(operation: operation, provider: provider, validate: validate)
    }

    func check() throws {
        try Task.checkCancellation()
        try operation.check()
        try provider?.check()
        try validate()
    }

    func perform<T>(_ body: () async throws -> T) async throws -> T {
        try check()
        let value: T
        if let provider {
            value = try await provider.perform { _ in try await body() }
        } else {
            value = try await body()
        }
        try check()
        return value
    }

    func read(_ url: URL, validateSource: () throws -> Void,
              load: (@Sendable (URL) async throws -> Data)? = nil) async throws -> Data {
        let data = try await Self.readExported(url, validate: { try self.check(); try validateSource() }, load: load)
        try check()
        try validateSource()
        return data
    }

    /// Dependent attachment tasks must finish while their initiating owner is
    /// still active; retiring it early would discard an otherwise valid result.
    func waitForAttachment(_ task: Task<Void, Never>?, validateSource: () throws -> Void) async throws {
        try check()
        try validateSource()
        await task?.value
        try check()
        try validateSource()
    }

    static func readExported(_ url: URL, validate: () throws -> Void,
                            load: (@Sendable (URL) async throws -> Data)? = nil) async throws -> Data {
        try Task.checkCancellation()
        try validate()
        let data: Data
        do {
            if let load { data = try await load(url) }
            else { data = try await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value }
        } catch {
            try Task.checkCancellation()
            try validate()
            throw error
        }
        try Task.checkCancellation()
        try validate()
        return data
    }
}
