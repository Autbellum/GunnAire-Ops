import Foundation
import LoadSightCore

public struct DiscoveredScheduleColumn: Codable, Equatable, Sendable {
    public let headerText: String
    public let field: EquipmentScheduleField?
    public let unitText: String?
    public let bounds: DrawingBounds
    public let evidence: [DrawingText]
}
public struct EquipmentScheduleCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sourceID: String
    public let filename: String
    public let pageID: String
    public let pageNumber: Int
    public let headers: [DiscoveredScheduleColumn]
    public let tagEvidence: [[DrawingText]]
    public let proposedRegion: EquipmentScheduleRegion
    public let warnings: [String]
    /// External candidates must be recomputed against current originals before being used as a draft.
    public func draftRequest(in archive: DrawingArchive) throws -> EquipmentScheduleRequest {
        let current = try EquipmentScheduleDiscoverer.discover(archive)
        try require(current.candidates.contains(self), "Schedule discovery evidence changed. Discover tables again before mapping.")
        return .init(regions: [proposedRegion])
    }
}
public struct EquipmentScheduleDiscovery: Codable, Sendable {
    public let method: String
    public let pageCount: Int
    public let candidates: [EquipmentScheduleCandidate]
    public let warnings: [String]
    public let limitations: [String]
}

/// Text-layout proposals. No physical quantities, source-defined conventions or approved mappings.
public enum EquipmentScheduleDiscoverer {
    public static let method = "Schedule header and tag alignment discovery v1"
    public static let limitations = [
        "Proposed bodies and column edges are inferred from text, not table ruling or engineering interpretation. Review and correct them on the original page before saving a map.",
        "This pass supports horizontal single-line headers with a leftmost TAG, EQUIPMENT TAG, MARK or EQUIPMENT MARK cell. Stacked/merged/rotated headers, image-only text without usable OCR anchors and other layouts may not be detected.",
        "Unknown and duplicate field headers stay visible but are omitted from mapped columns, leaving gaps. Repeated tags are row occurrences, never physical equipment counts.",
        "Body limits follow aligned tag rows and can omit multiline continuations, notes or footers. Missing tables or fields are not evidence of absent work.",
        "Header meanings are proposals. Recognition confidence is not engineering confidence. Ambiguous units retain their literal labels without a source-convention definition.",
        "No source, quantity, cost, project or review state is changed by discovery. Saving a reviewed map remains a separate authored action."
    ]
    public static func discover(_ archive: DrawingArchive, progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> EquipmentScheduleDiscovery {
        try Task.checkCancellation(); try archive.validate()
        let total = archive.records.reduce(0) { $0 + $1.pages.count }
        var done = 0, candidates: [EquipmentScheduleCandidate] = [], warnings: [String] = []
        for source in archive.records {
            for page in source.pages {
                try Task.checkCancellation()
                defer { done += 1; progress(done, total) }
                guard page.rotation == 0 else {
                    warnings.append("\(source.filename), page \(page.number): rotated page requires manual schedule mapping."); continue
                }
                let words: [DrawingText], mode: ScheduleTextMode
                if source.kind == "pdf", page.text.contains(where: { $0.method.hasPrefix("PDF") }) {
                    guard let data = archive.files[source.id] else { throw LoadSightError.invalid("Missing discovery source.") }
                    words = try EquipmentScheduleExtractor.nativeWords(data, page: page); mode = .nativePDFWords
                } else { words = page.text; mode = .recordedAnchors }
                try require(words.count <= 100_000, "Page exceeds the schedule discovery text limit.")
                guard !words.isEmpty else {
                    warnings.append("\(source.filename), page \(page.number): no usable text; review the original or import OCR evidence."); continue
                }
                let lines = alignedLines(words.filter { page.bounds.rect.contains($0.bounds.rect) })
                for (lineIndex, line) in lines.enumerated() {
                    try Task.checkCancellation()
                    let cells = headerCells(line)
                    let starts = cells.indices.filter { meaning(cells[$0].map(\.text).joined(separator: " ")).0 == .tag }
                    for (startIndex, start) in starts.enumerated() {
                        let end = startIndex + 1 < starts.count ? starts[startIndex + 1] : cells.count
                        let segment = Array(cells[start..<end])
                        guard segment.count >= 2 else { continue }
                        let headers = segment.map { evidence in
                            let text = evidence.map(\.text).joined(separator: " "), matched = meaning(text)
                            return DiscoveredScheduleColumn(headerText: text, field: matched.0, unitText: matched.1,
                                bounds: .init(union(evidence)), evidence: evidence)
                        }
                        let recognized = headers.compactMap(\.field)
                        let counts = Dictionary(grouping: recognized, by: { $0 }).mapValues(\.count)
                        guard recognized.first == .tag, recognized.contains(where: { $0 != .tag }) else { continue }
                        let height = headers.map { $0.bounds.height }.max()!
                        let left = max(page.bounds.rect.minX, headers[0].bounds.x - height * 2)
                        let right = min(page.bounds.rect.maxX, headers.last!.bounds.rect.maxX + height * 2)
                        var edges = [left]
                        for pair in zip(headers, headers.dropFirst()) { edges.append((pair.0.bounds.rect.maxX + pair.1.bounds.rect.minX) / 2) }
                        edges.append(right)
                        let headerBottom = headers.map { $0.bounds.rect.minY }.min()!
                        var tagRows: [[DrawingText]] = [], rowY: [Double] = []
                        var lastY = headerBottom
                        var gap = height * 8
                        for bodyLine in lines.dropFirst(lineIndex + 1) {
                            let y = union(bodyLine).midY
                            if lastY - y > gap { break }
                            let tagWords = bodyLine.filter { $0.bounds.rect.minX >= edges[0] && $0.bounds.rect.maxX <= edges[1] }
                            let tag = tagWords.map(\.text).joined(separator: " ")
                            if meaning(tag).0 == .tag { break }
                            guard isTag(tag) else { continue }
                            if let previous = rowY.last { gap = max(height * 4, (previous - y) * 1.8) }
                            lastY = y; rowY.append(y); tagRows.append(tagWords)
                        }
                        guard !tagRows.isEmpty, tagRows.count >= 2 || recognized.count >= 3 else { continue }
                        let top = headerBottom - height * 0.25
                        let bottom = max(page.bounds.rect.minY, tagRows.last!.map { $0.bounds.rect.minY }.min()! - height * 0.5)
                        guard top > bottom else { continue }
                        var flags = ["Review every proposed column and expand the table body for any continued rows, notes or multiline cells."]
                        let omitted = headers.filter { $0.field == nil || counts[$0.field!] != 1 }
                        if !omitted.isEmpty { flags.append("Unmapped or ambiguous headers: " + omitted.map(\.headerText).joined(separator: ", ")) }
                        if headers.flatMap(\.evidence).contains(where: { $0.confidence < 0.75 }) || tagRows.flatMap({ $0 }).contains(where: { $0.confidence < 0.75 }) {
                            flags.append("Low recognition confidence: verify header/tag text on the original.")
                        }
                        let mapped = headers.indices.compactMap { i -> EquipmentScheduleColumn? in
                            guard let field = headers[i].field, counts[field] == 1 else { return nil }
                            return .init(field: field, minX: edges[i], maxX: edges[i+1], unitText: headers[i].unitText, headerText: headers[i].headerText)
                        }
                        guard mapped.contains(where: { $0.field == .tag }), mapped.count >= 2 else { continue }
                        let region = EquipmentScheduleRegion(sourceID: source.id, pageID: page.id,
                            bodyBounds: .init(CGRect(x: left, y: bottom, width: right-left, height: top-bottom)), columns: mapped,
                            textMode: mode, recordedBy: "Automatic discovery — unreviewed",
                            mappingBasis: method + ". Proposed text-alignment bounds and header meanings; review against the original. " + flags.joined(separator: " "))
                        try EquipmentScheduleExtractor.validate(region, page: page)
                        let seed = EquipmentScheduleCandidate(id: "", sourceID: source.id, filename: source.filename, pageID: page.id,
                            pageNumber: page.number, headers: headers, tagEvidence: tagRows, proposedRegion: region, warnings: flags)
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                        let id = DrawingArchive.fingerprint(try encoder.encode(seed))
                        candidates.append(.init(id: id, sourceID: seed.sourceID, filename: seed.filename, pageID: seed.pageID,
                            pageNumber: seed.pageNumber, headers: headers, tagEvidence: tagRows, proposedRegion: region, warnings: flags))
                        try require(candidates.count <= 500, "Too many possible schedules; review a smaller drawing set.")
                    }
                }
            }
        }
        if candidates.isEmpty { warnings.append("No supported header/tag layout found. This is not evidence that equipment schedules are absent; use manual mapping.") }
        try Task.checkCancellation()
        return .init(method: method, pageCount: total, candidates: candidates, warnings: warnings, limitations: limitations)
    }
    private static func union(_ words: [DrawingText]) -> CGRect {
        words.reduce(CGRect.null) { $0.union($1.bounds.rect) }
    }
    private static func alignedLines(_ words: [DrawingText]) -> [[DrawingText]] {
        var lines: [[DrawingText]] = [], overlap: CGRect?
        for word in words.sorted(by: { a, b in a.bounds.rect.midY == b.bounds.rect.midY ? a.bounds.x < b.bounds.x : a.bounds.rect.midY > b.bounds.rect.midY }) {
            let rect = word.bounds.rect
            if let current = overlap, min(current.maxY, rect.maxY) - max(current.minY, rect.minY) > min(current.height, rect.height) * 0.5 {
                lines[lines.count-1].append(word)
                overlap = CGRect(x: 0, y: max(current.minY, rect.minY), width: 1, height: min(current.maxY, rect.maxY)-max(current.minY, rect.minY))
            } else { lines.append([word]); overlap = CGRect(x: 0, y: rect.minY, width: 1, height: rect.height) }
        }
        return lines.map { $0.sorted { $0.bounds.x < $1.bounds.x } }
    }
    private static func headerCells(_ line: [DrawingText]) -> [[DrawingText]] {
        var cells: [[DrawingText]] = []
        for word in line {
            if let last = cells.last, word.bounds.rect.minX - union(last).maxX <= max(word.bounds.height, union(last).height) {
                cells[cells.count-1].append(word)
            } else { cells.append([word]) }
        }
        return cells
    }
    private static func isTag(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z]{1,12}[- ]?\d+[A-Za-z]?$"#, options: .regularExpression) != nil
    }
    private static func meaning(_ text: String) -> (EquipmentScheduleField?, String?) {
        let normalized = text.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let exact: [String: EquipmentScheduleField] = [
            "TAG": .tag, "EQUIPMENT TAG": .tag, "MARK": .tag, "EQUIPMENT MARK": .tag,
            "TYPE": .equipmentType, "EQUIPMENT TYPE": .equipmentType, "MANUFACTURER": .manufacturer, "MFR": .manufacturer,
            "MODEL": .model, "MODEL NUMBER": .model, "QTY": .quantity, "QUANTITY": .quantity,
            "CFM": .airflow, "AIRFLOW": .airflow, "TOTAL CFM": .airflow, "OA CFM": .outdoorAir, "OUTDOOR AIR CFM": .outdoorAir,
            "MCA": .minimumCircuitAmpacity, "MOP": .maximumOvercurrentProtection, "MOCP": .maximumOvercurrentProtection,
            "ESP": .externalStaticPressure, "EWT": .enteringWaterTemperature, "LWT": .leavingWaterTemperature,
            "GPM": .waterFlow, "VOLTS": .voltage, "VOLTAGE": .voltage, "PHASE": .phase, "PH": .phase,
            "WEIGHT": .weight, "DIMENSIONS": .dimensions, "SOUND": .sound, "ACCESSORIES": .accessories, "NOTES": .notes,
            "TOTAL COOLING": .coolingTotal, "SENSIBLE COOLING": .coolingSensible, "HEATING CAPACITY": .heatingCapacity,
            "FURNACE INPUT": .furnaceInput, "FURNACE OUTPUT": .furnaceOutput
        ]
        if let field = exact[normalized] {
            let unit = normalized == "CFM" || normalized.hasSuffix(" CFM") || normalized == "GPM" ? text.split(whereSeparator: \.isWhitespace).last.map(String.init) : nil
            return (field, unit)
        }
        // Remove only an explicit trailing unit token; never infer a unit from MCA/ESP/EWT/etc.
        let pieces = text.split(whereSeparator: \.isWhitespace)
        guard let suffix = pieces.last, pieces.count >= 2 else { return (nil, nil) }
        let allowed: Set<String> = ["CFM", "GPM", "MBH", "Btu/h", "Btu_IT/h", "kW", "W", "TONS", "tons", "IN", "in", "mm", "cm", "m", "LB", "lb", "kg", "V", "A", "F", "C", "°F", "°C", "Pa", "kPa", "L/s", "m³/s", "m³/h"]
        let base = pieces.dropLast().joined(separator: " ").uppercased()
        guard allowed.contains(String(suffix)), let field = exact[base], field != .tag else { return (nil, nil) }
        return (field, String(suffix))
    }
}
