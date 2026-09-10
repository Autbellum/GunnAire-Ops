import Foundation
import PDFKit
import LoadSightCore

/// These column meanings are supplied from the drawing's headers, never guessed from a number.
public enum EquipmentScheduleField: String, Codable, CaseIterable, Sendable {
    case tag, equipmentType, manufacturer, model, quantity, coolingTotal, coolingSensible
    case heatingCapacity, furnaceInput, furnaceOutput, airflow, outdoorAir, externalStaticPressure
    case enteringWaterTemperature, leavingWaterTemperature, waterFlow, voltage, phase, minimumCircuitAmpacity
    case maximumOvercurrentProtection, weight, dimensions, sound, accessories, notes
}
public enum ScheduleTextMode: String, Codable, Sendable { case nativePDFWords, recordedAnchors }
public struct EquipmentScheduleColumn: Codable, Equatable, Sendable {
    public var field: EquipmentScheduleField
    public var minX: Double
    public var maxX: Double
    /// Exact header/unit transcription. Nil means not recorded, not dimensionless or a default unit.
    public var unitText: String?
    public var headerText: String
    public var unitDefinition: ScheduleUnitDefinition?
    public init(field: EquipmentScheduleField, minX: Double, maxX: Double, unitText: String? = nil, headerText: String, unitDefinition: ScheduleUnitDefinition? = nil) {
        self.field = field; self.minX = minX; self.maxX = maxX; self.unitText = unitText; self.headerText = headerText; self.unitDefinition = unitDefinition
    }
}
public struct EquipmentScheduleRegion: Codable, Equatable, Sendable {
    public var sourceID: String
    public var pageID: String
    public var bodyBounds: DrawingBounds
    public var columns: [EquipmentScheduleColumn]
    public var textMode: ScheduleTextMode
    public var recordedBy: String
    public var mappingBasis: String
    public init(sourceID: String, pageID: String, bodyBounds: DrawingBounds, columns: [EquipmentScheduleColumn], textMode: ScheduleTextMode, recordedBy: String, mappingBasis: String) {
        self.sourceID = sourceID; self.pageID = pageID; self.bodyBounds = bodyBounds; self.columns = columns
        self.textMode = textMode; self.recordedBy = recordedBy; self.mappingBasis = mappingBasis
    }
}
public struct EquipmentScheduleRequest: Codable, Sendable {
    public var schemaVersion: Int
    public var regions: [EquipmentScheduleRegion]
    public init(regions: [EquipmentScheduleRegion]) { schemaVersion = 1; self.regions = regions }
    /// Strict external contract: typos must not silently discard evidence or change column meaning.
    public static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        func keys(_ value: JSONValue, allowed: Set<String>, required: Set<String>) throws {
            guard let object = value.object else { throw LoadSightError.invalid("Schedule request requires an object.") }
            try require(Set(object.keys).isSubset(of: allowed) && required.isSubset(of: Set(object.keys)), "Unknown or missing schedule request fields.")
        }
        try keys(value, allowed: ["schemaVersion", "regions"], required: ["schemaVersion", "regions"])
        guard let regions = value["regions"].array else { throw LoadSightError.invalid("Schedule regions must be an array.") }
        for region in regions {
            let fields: Set<String> = ["sourceID", "pageID", "bodyBounds", "columns", "textMode", "recordedBy", "mappingBasis"]
            try keys(region, allowed: fields, required: fields)
            try keys(region["bodyBounds"], allowed: ["x", "y", "width", "height"], required: ["x", "y", "width", "height"])
            guard let columns = region["columns"].array else { throw LoadSightError.invalid("Schedule columns must be an array.") }
            for column in columns {
                try keys(column, allowed: ["field", "minX", "maxX", "unitText", "headerText", "unitDefinition"], required: ["field", "minX", "maxX", "headerText"])
                if column["unitDefinition"] != .null { try keys(column["unitDefinition"], allowed: ["convention", "source"], required: ["convention", "source"]) }
            }
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
public struct EquipmentScheduleCell: Codable, Equatable, Sendable {
    public let field: EquipmentScheduleField
    public let unitText: String?
    public let unitDefinition: ScheduleUnitDefinition?
    public let text: String?
    public let evidence: [DrawingText]
}
public struct EquipmentScheduleRow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sourceID: String
    public let filename: String
    public let pageID: String
    public let pageNumber: Int
    public let region: EquipmentScheduleRegion
    public let rowBounds: DrawingBounds
    public let tag: String
    public let cells: [EquipmentScheduleCell]
    public let warnings: [String]
    public let matchingTagOccurrences: [MechanicalTextCandidate]
    /// Recompute from current originals/recognition, column map and row evidence before downstream use.
    public func validate(in archive: DrawingArchive) throws {
        let extraction = try EquipmentScheduleExtractor.extract(archive, request: .init(regions: [region]))
        try require(extraction.rows.contains(self), "Schedule row or its source/cross-reference evidence changed. Extract and review again.")
    }
}
public struct EquipmentScheduleUnassignedText: Codable, Equatable, Sendable {
    public let regionIndex: Int
    public let sourceID: String
    public let pageID: String
    public let evidence: DrawingText
    public let reason: String
}
public struct EquipmentScheduleExtraction: Codable, Sendable {
    public let method: String
    public let rows: [EquipmentScheduleRow]
    public let unassigned: [EquipmentScheduleUnassignedText]
    public let unmatchedTagOccurrences: [MechanicalTextCandidate]
    public let consistencyReview: [ScheduleConsistencyReview]
    public let dimensionReview: [ScheduleRowDimensionReview]
    public let numericReview: [ScheduleRowNumericReview]
    public let warnings: [String]
    public let limitations: [String]
}

public enum EquipmentScheduleExtractor {
    public static let method = "Mapped schedule rows v1"
    public static let partialRowWarning = "Row has unassigned or boundary-crossing text. Cell text may be partial; inspect all unassigned evidence before use."
    public static let limitations = [
        "Unreviewed row candidates from explicitly mapped table bodies and columns; not autonomous table/header detection or engineering approval.",
        "Row bands are inferred between tag baselines. Merged cells, multiline tags, continuations and repeated headers require visual review.",
        "All cell values and units remain literal source text. Missing cells are unknown. Separate numeric review interprets supported explicit scalar units; it does not approve values or perform equipment-capacity plausibility checks.",
        "Schedule quantities and repeated tags are not physical equipment counts. Exact tag-text matches are review links, not confirmed plan/schedule associations.",
        "Native PDF word mode reads only the text layer. Recorded-anchor mode uses existing recognition without splitting anchors that cross columns. Image-only content may remain unread.",
        "No project, takeoff, drawing or review state is changed. Mapping author names are recorded input, not authenticated identity."
    ]
    /// Validate configuration/source references without running text extraction or accepting row evidence.
    public static func validate(_ request: EquipmentScheduleRequest, in archive: DrawingArchive) throws {
        try Task.checkCancellation(); try archive.validate()
        try require(request.schemaVersion == 1 && !request.regions.isEmpty && request.regions.count <= 100, "Supply 1 to 100 schedule regions with schemaVersion 1.")
        for (index, region) in request.regions.enumerated() {
            guard let source = archive.records.first(where: { $0.id == region.sourceID }), let page = source.pages.first(where: { $0.id == region.pageID }) else {
                throw LoadSightError.invalid("Schedule region source/page is unavailable.")
            }
            try validate(region, page: page)
            try require(region.textMode != .nativePDFWords || source.kind == "pdf", "Native PDF word mode requires a PDF original.")
            for previous in request.regions.prefix(index) where previous.sourceID == region.sourceID && previous.pageID == region.pageID {
                try require(!previous.bodyBounds.rect.intersects(region.bodyBounds.rect), "Schedule bodies must not overlap; review repeated views separately.")
            }
        }
        try Task.checkCancellation()
    }
    public static func extract(_ archive: DrawingArchive, request: EquipmentScheduleRequest,
                               progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> EquipmentScheduleExtraction {
        try validate(request, in: archive)
        let occurrences = try MechanicalTextExtractor.extract(archive).candidates.filter { $0.kind == .equipmentTag }
        let occurrencesByTag = Dictionary(grouping: occurrences, by: { $0.matchedText.uppercased() })
        var rows: [EquipmentScheduleRow] = [], unassigned: [EquipmentScheduleUnassignedText] = [], warnings: [String] = []
        for (index, region) in request.regions.enumerated() {
            try Task.checkCancellation()
            guard let source = archive.records.first(where: { $0.id == region.sourceID }), let page = source.pages.first(where: { $0.id == region.pageID }) else {
                throw LoadSightError.invalid("Schedule region source/page is unavailable.")
            }
            try validate(region, page: page)
            for other in request.regions.prefix(index) where other.sourceID == region.sourceID && other.pageID == region.pageID {
                try require(!other.bodyBounds.rect.intersects(region.bodyBounds.rect), "Schedule bodies must not overlap; review repeated views separately.")
            }
            let anchors: [DrawingText]
            if region.textMode == .nativePDFWords {
                guard source.kind == "pdf", let data = archive.files[source.id] else { throw LoadSightError.invalid("Native PDF word mode requires a PDF original.") }
                anchors = try nativeWords(data, page: page)
            } else { anchors = page.text }
            let body = region.bodyBounds.rect
            let relevant = anchors.filter { $0.bounds.rect.intersects(body) }
            try require(relevant.count <= 100_000, "Schedule region exceeds the text-evidence limit.")
            let columns = region.columns.sorted { $0.minX < $1.minX }
            let tagColumn = columns.first { $0.field == .tag }!
            func inColumn(_ anchor: DrawingText, _ column: EquipmentScheduleColumn) -> Bool {
                body.contains(anchor.bounds.rect) && anchor.bounds.rect.minX >= column.minX && anchor.bounds.rect.maxX <= column.maxX
            }
            // Shared vertical overlap groups words in one tag cell; it cannot chain across distinct rows.
            var groups: [[DrawingText]] = [], overlaps: [CGRect] = []
            for anchor in relevant.filter({ inColumn($0, tagColumn) }).sorted(by: order) {
                if let last = overlaps.last, min(last.maxY, anchor.bounds.rect.maxY) - max(last.minY, anchor.bounds.rect.minY) > min(last.height, anchor.bounds.height) * 0.5 {
                    groups[groups.count - 1].append(anchor)
                    overlaps[overlaps.count - 1] = CGRect(x: 0, y: max(last.minY, anchor.bounds.rect.minY), width: 1, height: min(last.maxY, anchor.bounds.rect.maxY) - max(last.minY, anchor.bounds.rect.minY))
                } else { groups.append([anchor]); overlaps.append(CGRect(x: 0, y: anchor.bounds.y, width: 1, height: anchor.bounds.height)) }
            }
            let centers = overlaps.map(\.midY)
            let rowRects = groups.indices.map { i in
                let upper = i == 0 ? body.maxY : (centers[i - 1] + centers[i]) / 2
                let lower = i == groups.count - 1 ? body.minY : (centers[i] + centers[i + 1]) / 2
                return CGRect(x: body.minX, y: lower, width: body.width, height: upper - lower)
            }
            var buckets = Array(repeating: [EquipmentScheduleField: [DrawingText]](), count: groups.count)
            var partialRows = Set<Int>()
            func rowIndex(for y: Double) -> Int? {
                var lo = 0, hi = rowRects.count
                while lo < hi {
                    let mid = (lo + hi) / 2, rect = rowRects[mid]
                    if y > rect.maxY { hi = mid }
                    else if y < rect.minY { lo = mid + 1 }
                    else { return mid }
                }
                return nil
            }
            for anchor in relevant {
                try Task.checkCancellation()
                let rect = anchor.bounds.rect
                if let i = rowIndex(for: rect.midY), rowRects[i].contains(rect),
                   let column = columns.first(where: { inColumn(anchor, $0) }) {
                    buckets[i][column.field, default: []].append(anchor)
                } else {
                    for y in [rect.minY, rect.midY, rect.maxY] { if let i = rowIndex(for: y) { partialRows.insert(i) } }
                }
            }
            var assigned = Set<String>()
            for rowIndex in groups.indices {
                try Task.checkCancellation()
                let rowRect = rowRects[rowIndex]
                let cells = columns.map { column in
                    let evidence = (buckets[rowIndex][column.field] ?? []).sorted(by: order)
                    return EquipmentScheduleCell(field: column.field, unitText: column.unitText, unitDefinition: column.unitDefinition, text: evidence.isEmpty ? nil : evidence.map(\.text).joined(separator: " "), evidence: evidence)
                }
                guard let tag = cells.first(where: { $0.field == .tag })?.text else { continue }
                assigned.formUnion(cells.flatMap(\.evidence).map(\.id))
                let matching = (occurrencesByTag[tag.uppercased()] ?? []).filter { !($0.sourceID == source.id && $0.pageID == page.id && $0.anchor.bounds.rect.intersects(body)) }
                var flags = ["Unreviewed row; check header mapping, row boundaries, notes and source page."]
                if partialRows.contains(rowIndex) {
                    flags.append(partialRowWarning)
                }
                let missing = cells.filter { $0.text == nil }.map { $0.field.rawValue }
                if !missing.isEmpty { flags.append("Mapped cells without recognized text remain unknown: " + missing.joined(separator: ", ")) }
                if cells.flatMap(\.evidence).contains(where: { $0.confidence < 0.75 }) { flags.append("Low recognition confidence: manually verify the affected cell text.") }
                if matching.isEmpty { flags.append("No exact tag-text occurrence outside this table body was found. This does not establish missing equipment or a missing plan tag.") }
                let seed = EquipmentScheduleRow(id: "", sourceID: source.id, filename: source.filename, pageID: page.id, pageNumber: page.number, region: region, rowBounds: .init(rowRect), tag: tag, cells: cells, warnings: flags, matchingTagOccurrences: matching)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let seedValue = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(seed))
                let id = DrawingArchive.fingerprint(try encoder.encode(JSONValue.object(["method": .string(method), "row": seedValue])))
                rows.append(.init(id: id, sourceID: source.id, filename: source.filename, pageID: page.id, pageNumber: page.number, region: region, rowBounds: .init(rowRect), tag: tag, cells: cells, warnings: flags, matchingTagOccurrences: matching))
            }
            for anchor in relevant where !assigned.contains(anchor.id) {
                unassigned.append(.init(regionIndex: index, sourceID: source.id, pageID: page.id, evidence: anchor, reason: "Text crosses a body/column/row boundary, lies in an unmapped gap, or has no tag row. Review without assigning a value."))
            }
            if groups.isEmpty { warnings.append("Region \(index + 1): no contained tag-cell text found; absence of rows is not evidence of absent work.") }
            warnings += page.warnings.map { "Region \(index + 1): " + $0 }
            progress(index + 1, request.regions.count)
        }
        let tags = Dictionary(grouping: rows, by: { $0.tag.uppercased() })
        for tag in tags.keys.sorted() where tags[tag]!.count > 1 { warnings.append("Repeated schedule tag \(tag): \(tags[tag]!.count) row occurrences require reconciliation; no physical quantity inferred.") }
        let unmatched = occurrences.filter { candidate in
            tags[candidate.matchedText.uppercased()] == nil && !request.regions.contains { $0.sourceID == candidate.sourceID && $0.pageID == candidate.pageID && $0.bodyBounds.rect.intersects(candidate.anchor.bounds.rect) }
        }
        try Task.checkCancellation()
        return .init(method: method, rows: rows, unassigned: unassigned, unmatchedTagOccurrences: unmatched, consistencyReview: rows.map(\.consistencyReview), dimensionReview: rows.map(\.dimensionReview), numericReview: rows.map { .init(rowID: $0.id, cells: $0.cells.map(\.numericInterpretation)) }, warnings: warnings, limitations: limitations)
    }
    private static func order(_ a: DrawingText, _ b: DrawingText) -> Bool {
        if a.bounds.rect.midY != b.bounds.rect.midY { return a.bounds.rect.midY > b.bounds.rect.midY }
        if a.bounds.x != b.bounds.x { return a.bounds.x < b.bounds.x }
        return a.id < b.id
    }
    private static func validate(_ region: EquipmentScheduleRegion, page: DrawingPage) throws {
        try region.bodyBounds.validate()
        try require(page.rotation == 0, "Rotate/normalize the schedule page to zero rotation before mapping table columns.")
        try require(page.bounds.rect.contains(region.bodyBounds.rect), "Schedule body must fit inside the source page.")
        try require(!region.recordedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !region.mappingBasis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Record the column mapper and header/source basis.")
        try require((2...EquipmentScheduleField.allCases.count).contains(region.columns.count), "Supply a tag column and at least one schedule value column.")
        try require(Set(region.columns.map(\.field)).count == region.columns.count && region.columns.contains { $0.field == .tag }, "Schedule fields must be unique and include tag.")
        let columns = region.columns.sorted { $0.minX < $1.minX }
        for (index, column) in columns.enumerated() {
            try require(column.minX.isFinite && column.maxX.isFinite && column.minX < column.maxX && column.minX >= region.bodyBounds.rect.minX && column.maxX <= region.bodyBounds.rect.maxX, "Invalid schedule column bounds.")
            try require(!column.headerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Transcribe the source header for each mapped column.")
            try column.unitDefinition?.validate(field: column.field, unitText: column.unitText)
            if index > 0 { try require(columns[index - 1].maxX <= column.minX, "Schedule columns overlap.") }
        }
    }
    /// PDFKit range selections localize words without changing the archive's original line anchors.
    private static func nativeWords(_ data: Data, page record: DrawingPage) throws -> [DrawingText] {
        guard let pdf = PDFDocument(data: data), !pdf.isLocked, let page = pdf.page(at: record.number - 1) else { throw LoadSightError.invalid("Unable to localize schedule PDF text.") }
        try require(page.rotation == record.rotation && DrawingBounds(page.bounds(for: .cropBox)) == record.bounds, "Schedule page geometry differs from its original PDF.")
        guard let text = page.string else { return [] }
        let string = text as NSString
        try require(string.length <= 1_000_000 && string.length == page.numberOfCharacters, "PDF text index is unsupported or too large for schedule localization.")
        let regex = try NSRegularExpression(pattern: #"\S+"#)
        var result: [DrawingText] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            try Task.checkCancellation()
            guard let selection = page.selection(for: match.range) else { throw LoadSightError.invalid("PDF word selection is unavailable. Inspect the source using recorded anchors.") }
            let bounds = selection.bounds(for: page)
            try require(!bounds.isNull && !bounds.isInfinite && [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite) && bounds.width > 0 && bounds.height > 0, "PDF word has unavailable geometry. Use recorded anchors and inspect the source.")
            result.append(.init(id: "\(record.id):schedule-word:\(match.range.location):\(match.range.length)", text: string.substring(with: match.range), bounds: .init(bounds), method: "PDF text selection; UTF-16 \(match.range.location):\(match.range.length)", confidence: 1))
        }
        return result
    }
}
