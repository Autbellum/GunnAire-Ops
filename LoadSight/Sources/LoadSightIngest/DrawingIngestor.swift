import Foundation
import PDFKit
import Vision
import ImageIO
import LoadSightCore

public enum DrawingOCRMode: String, Sendable { case whenNoText, everyPage, disabled }

public struct DrawingImportProgress: Sendable {
    public var filename: String
    public var page: Int
    public var totalPages: Int
    public init(filename: String, page: Int, totalPages: Int) {
        self.filename = filename; self.page = page; self.totalPages = totalPages
    }
}

/// PDFKit/Vision objects remain inside this actor; only Sendable value models cross it.
public actor DrawingIngestor {
    public init() {}
    public func ingest(url: URL, ocr: DrawingOCRMode = .whenNoText,
                       progress: @Sendable (DrawingImportProgress) async -> Void = { _ in }) async throws -> DrawingArchive {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try require(size <= 250_000_000, "Drawing exceeds the 250 MB per-file import limit.")
        return try await ingest(data: Data(contentsOf: url), filename: url.lastPathComponent, ocr: ocr, progress: progress)
    }
    public func ingest(data: Data, filename: String, ocr: DrawingOCRMode = .whenNoText,
                       progress: @Sendable (DrawingImportProgress) async -> Void = { _ in }) async throws -> DrawingArchive {
        try Task.checkCancellation()
        try require(!data.isEmpty && data.count <= 250_000_000, "Drawing is empty or exceeds the import limit.")
        let hash = DrawingArchive.fingerprint(data)
        var pages: [DrawingPage] = []
        let kind: String
        if let pdf = PDFDocument(data: data) {
            try require(!pdf.isLocked, "Unlock the encrypted PDF before importing it.")
            try require(pdf.pageCount > 0 && pdf.pageCount <= 1000, "PDF must contain 1 to 1000 pages.")
            kind = "pdf"
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                guard let page = pdf.page(at: index), let cgPage = page.pageRef else { throw LoadSightError.invalid("Unable to read PDF page \(index + 1).") }
                let bounds = page.bounds(for: .cropBox)
                try DrawingBounds(bounds).validate()
                var text = nativeText(page: page, prefix: "\(hash):\(index + 1)")
                var warnings = ["Sheet IDs and text are extraction candidates; geometry, symbols, revisions and scale require review."]
                if ocr == .everyPage || (ocr == .whenNoText && text.isEmpty) {
                    let rendered = try render(cgPage)
                    let recognized = try recognize(rendered.image, pageTransform: rendered.transform.inverted(), prefix: "\(hash):\(index + 1)")
                    // Preserve only OCR evidence not already covered by the same native text.
                    text += recognized.filter { found in !text.contains { $0.text == found.text && $0.bounds.rect.intersects(found.bounds.rect) } }
                } else {
                    warnings.append(ocr == .disabled ? "OCR disabled; raster content has not been read." : "Text layer extracted; image-only regions on this page have not been OCR-reviewed. Use full-page OCR when needed.")
                }
                if text.isEmpty { warnings.append("No readable text found. Manual review or a better scan is required.") }
                pages.append(.init(id: "\(hash):\(index + 1)", number: index + 1, bounds: .init(bounds), rotation: page.rotation, text: text, sheetCandidates: candidates(text), warnings: warnings))
                await progress(.init(filename: filename, page: index + 1, totalPages: pdf.pageCount))
            }
        } else if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            kind = "image"
            let count = CGImageSourceGetCount(source)
            try require(count > 0 && count <= 1000, "Image must contain 1 to 1000 frames.")
            for index in 0..<count {
                try Task.checkCancellation()
                // EXIF orientation is normalized. The stored coordinates use this displayed image.
                guard let image = Self.orientedImage(source: source, index: index) else { throw LoadSightError.invalid("Unable to decode image frame \(index + 1).") }
                let text = ocr == .disabled ? [] : try recognize(image, pageTransform: .identity, prefix: "\(hash):\(index + 1)")
                let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                pages.append(.init(id: "\(hash):\(index + 1)", number: index + 1, bounds: .init(bounds), rotation: 0, text: text, sheetCandidates: candidates(text), warnings: ["Image coordinates are normalized display pixels, not physical units. Calibrate each view; perspective distortion must be corrected or field-verified before measuring."] + (ocr == .disabled ? ["OCR disabled."] : [])))
                await progress(.init(filename: filename, page: index + 1, totalPages: count))
            }
        } else { throw LoadSightError.invalid("Unsupported or damaged drawing. Import PDF, PNG, JPEG, HEIC or TIFF; export CAD to PDF first.") }
        try Task.checkCancellation()
        var archive = DrawingArchive()
        try archive.insert(record: .init(id: hash, filename: filename, kind: kind, byteCount: data.count, pages: pages), data: data)
        return archive
    }
    public nonisolated static func orientedImage(source: CGImageSource, index: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, index, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 6000] as CFDictionary)
    }
    private func nativeText(page: PDFPage, prefix: String) -> [DrawingText] {
        guard let text = page.string else { return [] }
        let ns = text as NSString
        let expression = try! NSRegularExpression(pattern: "[^\\r\\n]+")
        return expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).enumerated().compactMap { index, match in
            let value = ns.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, let selection = page.selection(for: match.range) else { return nil }
            let rect = selection.bounds(for: page)
            guard rect.width > 0 && rect.height > 0 && !rect.isInfinite && !rect.isNull else { return nil }
            return .init(id: "\(prefix):text:\(index)", text: value, bounds: .init(rect), method: "PDF text layer", confidence: 1)
        }
    }
    private func render(_ page: CGPDFPage) throws -> (image: CGImage, transform: CGAffineTransform) {
        let box = page.getBoxRect(.cropBox)
        let rotated = abs(page.rotationAngle) % 180 == 90
        let width = rotated ? box.height : box.width, height = rotated ? box.width : box.height
        let scale = min(2, 4000 / max(width, height))
        let pixelWidth = max(1, Int(ceil(width * scale))), pixelHeight = max(1, Int(ceil(height * scale)))
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw LoadSightError.invalid("Unable to allocate drawing preview.") }
        let target = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(target)
        let transform = page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true)
        context.concatenate(transform); context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw LoadSightError.invalid("Unable to render PDF for recognition.") }
        return (image, transform)
    }
    private func recognize(_ image: CGImage, pageTransform: CGAffineTransform, prefix: String) throws -> [DrawingText] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false // Do not silently autocorrect equipment tags or dimensions.
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).enumerated().compactMap { index, observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            let box = observation.boundingBox
            let pixels = CGRect(x: box.minX * Double(image.width), y: box.minY * Double(image.height), width: box.width * Double(image.width), height: box.height * Double(image.height))
            return .init(id: "\(prefix):ocr:\(index)", text: candidate.string, bounds: .init(pixels.applying(pageTransform)), method: "Vision OCR", confidence: Double(candidate.confidence))
        }
    }
    private func candidates(_ text: [DrawingText]) -> [String] {
        let expression = try! NSRegularExpression(pattern: "\\b(?:M|MD|MH|MP|ME|P|FP|A|S|E)[- ]?\\d{3}(?:\\.\\d+)?\\b")
        var values = Set<String>()
        for anchor in text {
            let value = anchor.text.uppercased() as NSString
            for match in expression.matches(in: value as String, range: NSRange(location: 0, length: value.length)) {
                values.insert(value.substring(with: match.range))
            }
        }
        return values.sorted()
    }
}
