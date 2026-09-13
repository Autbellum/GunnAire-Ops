import Foundation

enum WordBlock {
    case paragraph(String, String)
    case table(headers: [String], rows: [[String]], widths: [Int])
}

enum WordPackage {
    static func text(_ input: String) throws -> String {
        try require(input.unicodeScalars.allSatisfy { c in
            c.value == 9 || c.value == 10 || c.value == 13 || (32...0xD7FF).contains(c.value) || (0xE000...0xFFFD).contains(c.value) || (0x10000...0x10FFFF).contains(c.value)
        }, "Document text contains a character that Word XML cannot represent.")
        return input.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func paragraph(_ content: String, style: String = "Normal") throws -> String {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let runs = try lines.map { line in
            try line.components(separatedBy: "\t").map { "<w:t xml:space=\"preserve\">\(try text($0))</w:t>" }.joined(separator: "<w:tab/>")
        }.joined(separator: "<w:br/>")
        return "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr><w:r>\(runs)</w:r></w:p>"
    }
    static func encode(_ paragraphs: [(String, String)]) throws -> Data {
        try encodeBlocks(paragraphs.map { .paragraph($0.0, $0.1) })
    }
    static func encodeBlocks(_ blocks: [WordBlock]) throws -> Data {
        let body = try blocks.map { block -> String in
            switch block {
            case .paragraph(let text, let style): return try paragraph(text, style: style)
            case .table(let headers, let rows, let widths):
                try require(!headers.isEmpty && widths.count == headers.count && widths.allSatisfy { $0 > 0 && $0 <= 10080 } && widths.reduce(0,+) == 10080 && rows.allSatisfy { $0.count == headers.count }, "Invalid Word table dimensions.")
                func row(_ cells: [String], header: Bool) throws -> String {
                    let content = try cells.enumerated().map { index, value in
                        "<w:tc><w:tcPr><w:tcW w:w=\"\(widths[index])\" w:type=\"dxa\"/></w:tcPr>" + (try paragraph(value, style: header ? "TableHeader" : "TableBody")) + "</w:tc>"
                    }.joined()
                    return "<w:tr><w:trPr>" + (header ? "<w:tblHeader/>" : "") + "</w:trPr>" + content + "</w:tr>"
                }
                let grid = widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined()
                let borders = ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:color=\"B8B8B8\"/>" }.joined()
                return "<w:tbl><w:tblPr><w:tblW w:w=\"10080\" w:type=\"dxa\"/><w:tblLayout w:type=\"fixed\"/><w:tblBorders>\(borders)</w:tblBorders><w:tblCellMar><w:top w:w=\"80\" w:type=\"dxa\"/><w:left w:w=\"100\" w:type=\"dxa\"/><w:bottom w:w=\"80\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>\(grid)</w:tblGrid>" + (try row(headers, header: true)) + (try rows.map { try row($0, header: false) }.joined()) + "</w:tbl>"
            }
        }.joined()
        let document = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(body)<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1080\" w:right=\"1080\" w:bottom=\"1080\" w:left=\"1080\" w:header=\"360\" w:footer=\"360\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>"
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/><w:color w:val="000000"/><w:sz w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/><w:widowControl/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        <w:style w:type="paragraph" w:styleId="Metadata"><w:name w:val="Record field"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="264" w:lineRule="auto"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:after="180"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/></w:pPr><w:rPr><w:sz w:val="26"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="220" w:after="100"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="26"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="180"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="HistoryHeading"><w:name w:val="History appendix"/><w:basedOn w:val="Heading1"/><w:pPr><w:pageBreakBefore/><w:keepNext/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Emphasis"><w:name w:val="Record emphasis"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/></w:pPr><w:rPr><w:b/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Small"><w:name w:val="Record detail"/><w:basedOn w:val="Normal"/><w:rPr><w:sz w:val="20"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="TableBody"><w:name w:val="Table body"/><w:basedOn w:val="Small"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="TableHeader"><w:name w:val="Table header"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:keepNext/></w:pPr><w:rPr><w:b/></w:rPr></w:style>
        </w:styles>
        """
        let types = """
        <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
        """
        func relationships(_ type: String, _ target: String) -> String {
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(type)\" Target=\"\(target)\"/></Relationships>"
        }
        return try StoredZIP.encode([("[Content_Types].xml", Data(types.utf8)), ("_rels/.rels", Data(relationships("officeDocument", "word/document.xml").utf8)), ("word/document.xml", Data(document.utf8)), ("word/styles.xml", Data(styles.utf8)), ("word/_rels/document.xml.rels", Data(relationships("styles", "styles.xml").utf8))])
    }
}
