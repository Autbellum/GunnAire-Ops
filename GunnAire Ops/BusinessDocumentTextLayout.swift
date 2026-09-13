import CoreText
import UIKit

/// One immutable text backing store, consumed only by ranges Core Text actually
/// fits. UTF-16 offsets stay in the original string across page boundaries.
struct BusinessDocumentTextLayout {
    private let text: NSAttributedString
    private let framesetter: CTFramesetter
    private(set) var offset = 0

    init(_ value: String, font: UIFont, color: UIColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        let text = NSAttributedString(string: value, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ])
        self.text = text
        framesetter = CTFramesetterCreateWithAttributedString(text)
    }

    var isComplete: Bool { offset == text.length }

    func height(width: CGFloat) -> CGFloat {
        guard !isComplete else { return 0 }
        return ceil(CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: offset, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil
        ).height)
    }

    mutating func draw(in rect: CGRect, context: CGContext) throws -> CGFloat {
        guard !isComplete else { return 0 }
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else {
            throw CustomerDocumentExportError.textLayoutUnavailable
        }
        let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.location == offset, visible.length > 0,
              visible.length <= text.length - offset else {
            // Never silently drop text or loop forever if a page cannot fit it.
            throw CustomerDocumentExportError.textLayoutUnavailable
        }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var usedHeight: CGFloat = 0
        for (line, origin) in zip(lines, origins) {
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, nil, &descent, nil)
            usedHeight = max(usedHeight, rect.height - origin.y + descent)
        }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
        offset += visible.length
        return ceil(usedHeight)
    }
}
