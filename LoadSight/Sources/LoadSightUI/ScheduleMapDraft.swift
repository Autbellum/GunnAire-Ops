import Foundation
import LoadSightKit

struct ScheduleColumnDraft: Identifiable, Equatable {
    let id = UUID()
    var field: EquipmentScheduleField = .tag
    var minX = "", maxX = "", header = "", unit = ""
    init(field: EquipmentScheduleField) { self.field = field }
    init(_ column: EquipmentScheduleColumn) {
        field = column.field; minX = String(column.minX); maxX = String(column.maxX)
        header = column.headerText; unit = column.unitText ?? ""
    }
}
struct ScheduleRegionDraft: Identifiable, Equatable {
    let id = UUID()
    var sourceID = "", pageID = ""
    var minX = "", minY = "", maxX = "", maxY = ""
    var columns = [ScheduleColumnDraft(field: .tag), ScheduleColumnDraft(field: .airflow)]
    var textMode: ScheduleTextMode = .nativePDFWords
    var basis = ""
    init(drawings: DrawingArchive) {
        if let source = drawings.records.first { sourceID = source.id; pageID = source.pages.first?.id ?? ""; textMode = source.kind == "pdf" ? .nativePDFWords : .recordedAnchors }
    }
    init(_ region: EquipmentScheduleRegion) {
        sourceID = region.sourceID; pageID = region.pageID
        minX = String(region.bodyBounds.x); minY = String(region.bodyBounds.y)
        maxX = String(region.bodyBounds.x + region.bodyBounds.width); maxY = String(region.bodyBounds.y + region.bodyBounds.height)
        columns = region.columns.map(ScheduleColumnDraft.init); textMode = region.textMode; basis = region.mappingBasis
    }
    mutating func changeSource(_ source: DrawingRecord, pageID: String? = nil) {
        sourceID = source.id; self.pageID = pageID ?? source.pages.first?.id ?? ""
        minX = ""; minY = ""; maxX = ""; maxY = ""; basis = ""
        columns = columns.map { ScheduleColumnDraft(field: $0.field) }
        textMode = source.kind == "pdf" ? .nativePDFWords : .recordedAnchors
    }
    mutating func setBody(_ a: PagePoint, _ b: PagePoint) {
        minX = String(min(a.x, b.x)); maxX = String(max(a.x, b.x))
        minY = String(min(a.y, b.y)); maxY = String(max(a.y, b.y))
    }
    func region(author: String) throws -> EquipmentScheduleRegion {
        let left = try coordinate(minX), right = try coordinate(maxX), bottom = try coordinate(minY), top = try coordinate(maxY)
        try require(right > left && top > bottom, "Select a table body with positive width and height.")
        let body = DrawingBounds(CGRect(x: left, y: bottom, width: right-left, height: top-bottom))
        let mapped = try columns.map { column in
            EquipmentScheduleColumn(field: column.field, minX: try coordinate(column.minX), maxX: try coordinate(column.maxX),
                                    unitText: column.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : column.unit,
                                    headerText: column.header)
        }
        return .init(sourceID: sourceID, pageID: pageID, bodyBounds: body, columns: mapped, textMode: textMode, recordedBy: author, mappingBasis: basis)
    }
    private func coordinate(_ value: String) throws -> Double {
        guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else { throw LoadSightError.invalid("Enter finite page coordinates or select bounds on the drawing.") }
        return number
    }
}
struct ScheduleMapDraft: Equatable {
    var name = ""
    var regions: [ScheduleRegionDraft]
    init(drawings: DrawingArchive, name: String = "", request: EquipmentScheduleRequest? = nil) {
        self.name = name; regions = request?.regions.map(ScheduleRegionDraft.init) ?? [.init(drawings: drawings)]
    }
    func request(author: String) throws -> EquipmentScheduleRequest { .init(regions: try regions.map { try $0.region(author: author) }) }
}
