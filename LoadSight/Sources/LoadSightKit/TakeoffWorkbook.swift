import Foundation

public enum TakeoffWorkbook {
    private static let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    public static func xlsx(_ project: ProjectDocument, drawings: DrawingArchive? = nil) throws -> Data {
        if let drawings { try project.validateDrawingEvidence(in: drawings) } else { try project.validatePortableProject() }
        let review = try EstimatePricing.review(project)
        let itemKeys = ["id", "description", "quantity", "unit", "lifecycle", "scope", "quantityStatus", "source", "basis", "notes"]
        let rfiKeys = ["id", "title", "status", "question", "source", "impact", "response", "resolvedBy", "resolvedDate", "responseSource"]
        let qa = project.root["qa"].array ?? []
        let qaRows = try qa.map { gate -> [JSONValue] in
            [gate["id"], .string(gate["check"].string ?? QAWorkflow.title(for: gate["id"].string ?? "")), gate["status"], gate["reviewer"], dateValue(gate["date"]), gate["note"], .string(try project.isQACurrent(gate) ? (gate["reviewFingerprint"] == .null ? "Legacy / unversioned" : "Current") : "Open or stale")]
        }
        let catalog = try catalogTables(project)
        let sheets: [(String, [String], [[JSONValue]], [Double])] = [
            ("Takeoff", ["ID", "Description", "Quantity", "Unit", "Lifecycle", "Scope", "Quantity status", "Source", "Basis", "Notes"], project.items.map { row in itemKeys.map { row[$0] ?? .null } }, [14,55,12,10,22,14,22,55,60,60]),
            ("RFIs", ["ID", "Title", "Status", "Question", "Source", "Impact", "Response", "Answered by", "Answer date", "Answer source"], (project.root["rfis"].array ?? []).map { row in rfiKeys.map { $0 == "resolvedDate" ? dateValue(row[$0]) : row[$0] } }, [14,40,14,80,60,60,80,24,26,60]),
            ("Review", ["ID", "Check", "Status", "Reviewer", "Date", "Evidence", "Version status"], qaRows, [14,65,14,24,26,80,24]),
            ("Material costs", catalog.materialHeaders, catalog.materialRows, [14,45,14,14,20,18,20,38,40,65]),
            ("Catalog history", ["Item ID", "Revision ID", "Recorded by", "Recorded at (UTC)", "Reason", "Field", "Before value", "After value"], catalog.historyRows, [14,40,24,25,50,36,60,60])
        ]
        var files: [(String, Data)] = []
        func add(_ path: String, _ xml: String) { files.append((path, Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + xml).utf8))) }
        let sheetTypes = sheets.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined()
        add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>\(sheetTypes)</Types>")
        add("_rels/.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        let names = sheets.enumerated().map { "<sheet name=\"\($0.element.0)\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined()
        add("xl/workbook.xml", "<workbook xmlns=\"\(ns)\" xmlns:r=\"\(rel)\"><sheets>\(names)</sheets></workbook>")
        let links = sheets.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined()
        add("xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(links)<Relationship Id=\"rIdStyles\" Type=\"\(rel)/styles\" Target=\"styles.xml\"/></Relationships>")
        add("xl/styles.xml", styles)
        for (index, sheet) in sheets.enumerated() {
            let message = index < 3 ? "Export snapshot - not for bid release. Blank quantities are unknown. Review issues: \(review.blockers.count)." : "Export snapshot - not for bid release. Blank costs are unknown. Values do not refresh from the live catalog."
            add("xl/worksheets/sheet\(index + 1).xml", try worksheet(title: sheet.0 + " - " + project.name, note: message, headers: sheet.1, rows: sheet.2, widths: sheet.3, dateColumn: index == 1 ? 8 : (index == 2 ? 4 : (index == 4 ? 3 : nil)), moneyColumns: index == 3 ? [4, 6] : [], timestamp: index == 4, headerHeight: index >= 3 ? 44 : 30))
        }
        return try StoredZIP.encode(files)
    }
    private static func dateValue(_ value: JSONValue) -> JSONValue {
        guard let text = value.string else { return value }
        let plain = DateFormatter(); plain.locale = Locale(identifier: "en_US_POSIX"); plain.timeZone = TimeZone(secondsFromGMT: 0); plain.dateFormat = "yyyy-MM-dd"
        let date = ISO8601DateFormatter().date(from: text) ?? (text.count == 10 ? plain.date(from: text) : nil)
        return date.map { .number($0.timeIntervalSince1970 / 86400 + 25569) } ?? value
    }
    private static func escape(_ value: String) throws -> String {
        try require(value.utf16.count <= 32767, "A workbook cell exceeds Excel's text limit; shorten the source field before exporting.")
        try require(value.unicodeScalars.allSatisfy { $0.value == 9 || $0.value == 10 || $0.value == 13 || ($0.value >= 32 && $0.value != 0xfffe && $0.value != 0xffff) }, "A source field contains a character XML cannot represent.")
        return value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func column(_ index: Int) -> String {
        var n = index + 1, result = ""
        while n > 0 { n -= 1; result = String(UnicodeScalar(65 + n % 26)!) + result; n /= 26 }
        return result
    }
    private static func cell(_ value: JSONValue, row: Int, col: Int, style: Int = 0) throws -> String {
        let address = column(col) + String(row)
        if let number = value.number { return "<c r=\"\(address)\" s=\"\([5, 6, 7].contains(style) ? style : 3)\"><v>\(number)</v></c>" }
        if let string = value.string { return "<c r=\"\(address)\" s=\"\(style)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(try escape(string))</t></is></c>" }
        return "<c r=\"\(address)\" s=\"\(style)\"/>"
    }
    private static func worksheet(title: String, note: String, headers: [String], rows: [[JSONValue]], widths: [Double], dateColumn: Int?, moneyColumns: Set<Int> = [], timestamp: Bool = false, headerHeight: Int = 30) throws -> String {
        try require(rows.count < 1_048_571, "Too many worksheet rows.")
        var body = "<row r=\"2\" ht=\"24\" customHeight=\"1\">\(try cell(.string(title), row: 2, col: 0, style: 2))</row><row r=\"3\" ht=\"24\" customHeight=\"1\">\(try cell(.string(note), row: 3, col: 0, style: 4))</row>"
        body += "<row r=\"5\" ht=\"\(headerHeight)\" customHeight=\"1\">" + (try headers.enumerated().map { try cell(.string($0.element), row: 5, col: $0.offset, style: 1) }.joined()) + "</row>"
        for (index, values) in rows.enumerated() {
            let lines = values.enumerated().map { column, value in (value.string ?? "").split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / (widths[column] - 3)))) } }.max() ?? 1
            let height = max(30, lines * 15 + 10)
            try require(height <= 409, "A record needs more than Excel's maximum row height; shorten the source field before exporting.")
            body += "<row r=\"\(index + 6)\" ht=\"\(height)\" customHeight=\"1\">" + (try values.enumerated().map { try cell($0.element, row: index + 6, col: $0.offset, style: $0.offset == dateColumn ? (timestamp ? 7 : 5) : (moneyColumns.contains($0.offset) ? 6 : 0)) }.joined()) + "</row>"
        }
        let cols = widths.enumerated().map { "<col min=\"\($0.offset + 1)\" max=\"\($0.offset + 1)\" width=\"\($0.element)\" customWidth=\"1\"/>" }.joined()
        return "<worksheet xmlns=\"\(ns)\"><dimension ref=\"A1:\(column(headers.count - 1))\(rows.count + 5)\"/><sheetViews><sheetView workbookViewId=\"0\" showGridLines=\"0\"><pane xSplit=\"1\" ySplit=\"5\" topLeftCell=\"B6\" activePane=\"bottomRight\" state=\"frozen\"/></sheetView></sheetViews><cols>\(cols)</cols><sheetData>\(body)</sheetData><autoFilter ref=\"A5:\(column(headers.count - 1))\(rows.count + 5)\"/></worksheet>"
    }
    private static let styles = """
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="2"><numFmt numFmtId="164" formatCode="&quot;$&quot;#,##0.00########"/><numFmt numFmtId="165" formatCode="yyyy-mm-dd hh:mm:ss"/></numFmts><fonts count="3"><font><sz val="10"/><name val="Arial"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="10"/><name val="Arial"/></font><font><b/><sz val="14"/><name val="Arial"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF243746"/></patternFill></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="8"><xf fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf fontId="1" fillId="2" borderId="0" xfId="0" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf><xf fontId="2" fillId="0" borderId="0" xfId="0"/><xf fontId="0" fillId="0" borderId="0" numFmtId="0" xfId="0" applyNumberFormat="1"><alignment horizontal="right" vertical="top"/></xf><xf fontId="0" fillId="0" borderId="0" xfId="0"/><xf fontId="0" fillId="0" borderId="0" numFmtId="14" xfId="0" applyNumberFormat="1"><alignment horizontal="right" vertical="top"/></xf><xf fontId="0" fillId="0" borderId="0" numFmtId="164" xfId="0" applyNumberFormat="1"><alignment horizontal="right" vertical="top"/></xf><xf fontId="0" fillId="0" borderId="0" numFmtId="165" xfId="0" applyNumberFormat="1"><alignment horizontal="right" vertical="top"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
    """
}
