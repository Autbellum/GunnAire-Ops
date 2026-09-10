import Foundation

public typealias LoadSightProgressHandler = @Sendable (LoadSightProgress) -> Void

public struct LoadSightProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case running, succeeded, failed, cancelled }
    public let phase: Phase
    public let stage: String
    public let completedUnits: Int
    public let totalUnits: Int
    public init(phase: Phase = .running, stage: String, completedUnits: Int, totalUnits: Int) {
        self.phase = phase; self.stage = stage; self.completedUnits = completedUnits; self.totalUnits = totalUnits
    }
}

/// UI-independent, on-device operations over recorded evidence. No provider or accounting authority.
public protocol LoadSightServicing: Sendable {
    func ingestDrawings(_ urls: [URL], ocr: DrawingOCRMode, progress: @escaping LoadSightProgressHandler) async throws -> DrawingArchive
    func reviewEstimate(_ project: ProjectDocument, asOf: Date, progress: @escaping LoadSightProgressHandler) async throws -> BidReview
    func reviewRecordedEngineering(_ project: ProjectDocument, progress: @escaping LoadSightProgressHandler) async throws -> JSONValue
    func draftProposal(_ project: ProjectDocument, generatedAt: Date, progress: @escaping LoadSightProgressHandler) async throws -> Data
    func draftRFI(_ project: ProjectDocument, rfiID: String, generatedAt: Date, progress: @escaping LoadSightProgressHandler) async throws -> Data
    func draftCO(_ project: ProjectDocument, changeOrderID: String, generatedAt: Date, progress: @escaping LoadSightProgressHandler) async throws -> Data
    func exportTakeoff(_ project: ProjectDocument, progress: @escaping LoadSightProgressHandler) async throws -> Data
}

/// Isolates synchronous engine/document work from the main actor. Each call uses an immutable input snapshot.
public actor LocalLoadSightService: LoadSightServicing {
    public init() {}
    public func ingestDrawings(_ urls: [URL], ocr: DrawingOCRMode = .whenNoText, progress: @escaping LoadSightProgressHandler = { _ in }) async throws -> DrawingArchive {
        try Task.checkCancellation()
        try require(!urls.isEmpty && urls.count <= 500, "Supply 1 to 500 drawing URLs.")
        try require(urls.allSatisfy(\.isFileURL), "The local service accepts file URLs only; download or select drawings explicitly in the host app.")
        let ingestor = DrawingIngestor()
        var archive = DrawingArchive()
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            progress(.init(stage: "Importing drawing \(index + 1) of \(urls.count)", completedUnits: index, totalUnits: urls.count))
            let imported = try await ingestor.ingest(url: url, ocr: ocr) { page in
                progress(.init(stage: "Drawing \(index + 1): page \(page.page) of \(page.totalPages)", completedUnits: index, totalUnits: urls.count))
            }
            try Task.checkCancellation()
            for record in imported.records {
                guard let data = imported.files[record.id] else { throw LoadSightError.invalid("Imported drawing source is missing.") }
                try archive.insert(record: record, data: data)
            }
            progress(.init(stage: "Imported drawing \(index + 1) of \(urls.count)", completedUnits: index + 1, totalUnits: urls.count))
        }
        try Task.checkCancellation()
        return archive
    }
    public func reviewEstimate(_ project: ProjectDocument, asOf: Date = Date(), progress: @escaping LoadSightProgressHandler = { _ in }) async throws -> BidReview {
        try perform("Reviewing estimate evidence", progress: progress) { try EstimatePricing.review(project, asOf: asOf) }
    }
    public func reviewRecordedEngineering(_ project: ProjectDocument, progress: @escaping LoadSightProgressHandler = { _ in }) async throws -> JSONValue {
        try Task.checkCancellation()
        try project.validatePortableProject()
        let stages: [(String, () throws -> JSONValue)] = [
            ("Air processes", { try project.airProcessReview() }),
            ("Envelope assemblies", { try project.envelopeReview() }),
            ("Room transmission", { try project.roomTransmissionReview() })
        ]
        var result: [String: JSONValue] = [:]
        for (index, stage) in stages.enumerated() {
            try Task.checkCancellation()
            progress(.init(stage: stage.0, completedUnits: index, totalUnits: stages.count))
            result[stage.0] = try stage.1()
        }
        try Task.checkCancellation()
        progress(.init(stage: "Recorded engineering reviewed", completedUnits: stages.count, totalUnits: stages.count))
        return .object(["scope": .string("Recomputed recorded worksheets only; not semantic drawing extraction or complete building loads"), "reviews": .object(result)])
    }
    public func draftProposal(_ project: ProjectDocument, generatedAt: Date = Date(), progress: @escaping LoadSightProgressHandler = { _ in }) async throws -> Data {
        try perform("Drafting proposal PDF", progress: progress) { try DraftProposal.pdf(project, generatedAt: generatedAt) }
    }
    public func draftRFI(_ project: ProjectDocument, rfiID: String, generatedAt: Date = Date(), progress: @escaping LoadSightProgressHandler = { _ in }) async throws -> Data {
        try perform("Drafting RFI Word document", progress: progress) { try RFIWordDocument.docx(project, rfiID: rfiID, generatedAt: generatedAt) }
    }
    public func draftCO(_ project: ProjectDocument, changeOrderID: String, generatedAt: Date = Date(), progress: @escaping LoadSightProgressHandler = { _ in }) async throws -> Data {
        try perform("Drafting change-order Word document", progress: progress) { try ChangeOrderWordDocument.docx(project, changeOrderID: changeOrderID, generatedAt: generatedAt) }
    }
    public func exportTakeoff(_ project: ProjectDocument, progress: @escaping LoadSightProgressHandler = { _ in }) async throws -> Data {
        try perform("Exporting takeoff workbook", progress: progress) { try TakeoffWorkbook.xlsx(project) }
    }
    /// Unreviewed text occurrences only; this is not the complete semantic extraction pipeline.
    public func extractMechanicalText(_ drawings: DrawingArchive, progress: @escaping LoadSightProgressHandler = { _ in }) async throws -> MechanicalTextExtraction {
        try MechanicalTextExtractor.extract(drawings) { done, total in
            progress(.init(stage: "Scanning drawing text", completedUnits: done, totalUnits: total))
        }
    }
    /// Native package hosts keep drawing bytes outside project JSON; validate that exact archive.
    public func exportTakeoff(_ project: ProjectDocument, drawings: DrawingArchive, progress: @escaping LoadSightProgressHandler = { _ in }) async throws -> Data {
        try perform("Exporting takeoff workbook", progress: progress) { try TakeoffWorkbook.xlsx(project, drawings: drawings) }
    }
    private func perform<T>(_ stage: String, progress: LoadSightProgressHandler, work: () throws -> T) throws -> T {
        try Task.checkCancellation()
        progress(.init(stage: stage, completedUnits: 0, totalUnits: 1))
        let result = try work()
        try Task.checkCancellation()
        progress(.init(stage: stage, completedUnits: 1, totalUnits: 1))
        return result
    }
}
