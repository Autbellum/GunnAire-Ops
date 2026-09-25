import AppKit
import CoreText
import HVACCore

/// Renders a `DesignReport` to a paginated US Letter PDF.
///
/// CoreText framesetting rather than a rendered SwiftUI view: a design report is a text
/// document that has to break across pages at sensible places, and a screenshot of a
/// scroll view is not a document. Tables use paragraph tab stops rather than hand-drawn
/// cells, which keeps columns aligned without a layout engine of its own.
public enum ReportPDF {

    static let pageSize = CGSize(width: 612.0, height: 792.0)     // US Letter at 72 dpi
    static let margin: CGFloat = 54                            // 0.75 in
    static var contentWidth: CGFloat { pageSize.width - margin * 2 }

    // MARK: Ink
    //
    // Explicit colours, never the dynamic system ones. `NSColor.labelColor` resolves
    // against the current appearance, so on a Mac in dark mode it renders near-white and
    // the headings disappear into a white page. A printed document is black on white
    // regardless of what the screen is doing.
    private static var ink: NSColor { NSColor(white: 0.0, alpha: 1) }
    private static var softInk: NSColor { NSColor(white: 0.38, alpha: 1) }
    private static var faintInk: NSColor { NSColor(white: 0.55, alpha: 1) }

    // MARK: Fonts

    private static var titleFont: NSFont { NSFont.systemFont(ofSize: 18, weight: .semibold) }
    private static var sectionFont: NSFont { NSFont.systemFont(ofSize: 12, weight: .semibold) }
    private static var tableTitleFont: NSFont { NSFont.systemFont(ofSize: 10, weight: .semibold) }
    private static var bodyFont: NSFont { NSFont.systemFont(ofSize: 9.5, weight: .regular) }
    private static var boldBody: NSFont { NSFont.systemFont(ofSize: 9.5, weight: .semibold) }
    private static var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular) }
    private static var monoBold: NSFont { NSFont.monospacedSystemFont(ofSize: 8.5, weight: .semibold) }
    private static var noteFont: NSFont { NSFont.systemFont(ofSize: 8, weight: .regular) }

    // MARK: Public

    public static func data(for report: DesignReport) -> Data {
        let text = attributedString(for: report)
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return Data() }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }

        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let textRect = CGRect(x: margin, y: margin + 26,
                              width: contentWidth, height: pageSize.height - margin * 2 - 26)
        var start = 0
        var page = 1
        let length = text.length

        repeat {
            context.beginPDFPage(nil)
            context.textMatrix = .identity

            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(start, 0), path, nil)
            CTFrameDraw(frame, context)

            drawFooter(report: report, page: page, in: context)

            let visible = CTFrameGetVisibleStringRange(frame)
            // Guard against a zero-length frame, which would loop forever on content that
            // cannot fit — a single table row taller than the page, for instance.
            if visible.length <= 0 { context.endPDFPage(); break }
            start += visible.length
            page += 1
            context.endPDFPage()
        } while start < length

        context.closePDF()
        return output as Data
    }

    @discardableResult
    public static func write(_ report: DesignReport, to url: URL) throws -> URL {
        try data(for: report).write(to: url, options: .atomic)
        return url
    }

    // MARK: Composition

    static func attributedString(for report: DesignReport) -> NSAttributedString {
        let out = NSMutableAttributedString()

        out.append(line(report.projectName, font: titleFont, spaceAfter: 2))
        let stamp = DateFormatter()
        stamp.dateStyle = .long; stamp.timeStyle = .short
        out.append(line("\(report.procedure.rawValue) load calculation · prepared \(stamp.string(from: report.preparedOn))",
                        font: noteFont, colour: softInk, spaceAfter: 14))

        for section in report.sections {
            out.append(line(section.title.uppercased(), font: sectionFont, spaceBefore: 10, spaceAfter: 5))

            if !section.rows.isEmpty {
                let style = NSMutableParagraphStyle()
                style.tabStops = [NSTextTab(textAlignment: .left, location: 210)]
                style.paragraphSpacing = 1.5
                for row in section.rows {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: row.emphasis ? boldBody : bodyFont,
                        .foregroundColor: ink,
                        .paragraphStyle: style
                    ]
                    out.append(NSAttributedString(string: "\(row.label)\t\(row.value)\n",
                                                  attributes: attributes))
                }
            }

            for table in section.tables {
                out.append(line(table.title, font: tableTitleFont, spaceBefore: 8, spaceAfter: 3))
                out.append(rendered(table))
                if let note = table.note {
                    out.append(line(note, font: noteFont, colour: softInk,
                                    spaceBefore: 2, spaceAfter: 4))
                }
            }

            for note in section.notes {
                out.append(line("• " + note, font: noteFont, colour: softInk, spaceAfter: 2))
            }
        }

        return out
    }

    /// Lays a table out on tab stops sized to the widest cell in each column.
    static func rendered(_ table: DesignReport.Table) -> NSAttributedString {
        let columnCount = table.columns.count
        guard columnCount > 0 else { return NSAttributedString() }

        // Measure. The last column absorbs whatever is left, so a long description wraps
        // rather than pushing the table off the page.
        var widths = [CGFloat](repeating: 0, count: columnCount)
        for (index, heading) in table.columns.enumerated() {
            widths[index] = measure(heading, font: monoBold)
        }
        for row in table.rows {
            for (index, cell) in row.enumerated() where index < columnCount {
                widths[index] = max(widths[index], measure(cell, font: monoFont))
            }
        }
        let gutter: CGFloat = 10
        var stops: [NSTextTab] = []
        var x: CGFloat = 0
        for index in 0..<(columnCount - 1) {
            x += min(widths[index], contentWidth * 0.34) + gutter
            stops.append(NSTextTab(textAlignment: .left, location: x))
        }

        let style = NSMutableParagraphStyle()
        style.tabStops = stops
        style.defaultTabInterval = 60
        style.headIndent = stops.last?.location ?? 0
        style.paragraphSpacing = 0.5
        style.lineBreakMode = .byWordWrapping

        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: table.columns.joined(separator: "\t") + "\n",
                                      attributes: [.font: monoBold, .foregroundColor: ink, .paragraphStyle: style]))
        for row in table.rows {
            let cells = (0..<columnCount).map { $0 < row.count ? row[$0] : "" }
            out.append(NSAttributedString(string: cells.joined(separator: "\t") + "\n",
                                          attributes: [.font: monoFont, .foregroundColor: ink, .paragraphStyle: style]))
        }
        return out
    }

    static func measure(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    static func line(_ text: String, font: NSFont, colour: NSColor = ink,
                     spaceBefore: CGFloat = 0, spaceAfter: CGFloat = 0) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spaceBefore
        style.paragraphSpacing = spaceAfter
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text + "\n",
                                  attributes: [.font: font, .foregroundColor: colour,
                                               .paragraphStyle: style])
    }

    // MARK: Footer

    static func drawFooter(report: DesignReport, page: Int, in context: CGContext) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let text = NSAttributedString(
            string: report.footnotes.first.map { "\($0)   ·   Page \(page)" } ?? "Page \(page)",
            attributes: [.font: NSFont.systemFont(ofSize: 6.5),
                         .foregroundColor: faintInk,
                         .paragraphStyle: style])
        let path = CGPath(rect: CGRect(x: margin, y: margin - 32,
                                       width: contentWidth, height: 28), transform: nil)
        let frame = CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(text as CFAttributedString),
            CFRangeMake(0, 0), path, nil)
        CTFrameDraw(frame, context)
    }
}
