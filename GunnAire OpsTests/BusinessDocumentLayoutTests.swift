import Foundation
import PDFKit
import Testing
import UIKit
@testable import GunnAire_Ops

@MainActor struct BusinessDocumentLayoutTests {
    private func exportForm(label: String, answer: String, name: String) throws -> PDFDocument {
        let customer = Customer(name: "Document Layout QA", address: "100 Fixture Lane")
        let job = ServiceCall(type: .repair, scheduledDate: Date(timeIntervalSinceReferenceDate: 810_123_456), customer: customer)
        let question = FieldFormQuestion(label: label, kind: .text, required: true)
        let template = FieldFormTemplate(title: name, questions: [question])
        let response = FieldFormResponse(serviceCallID: job.id, template: template, answers: [question.id: answer])
        let raw = response.answersJSON
        let url = try CustomerDocumentExporter.exportFieldFormResponse(response, serviceCall: job, template: template)
        let data = try Data(contentsOf: url)
        Attachment.record(Array(data), named: name + ".pdf")
        #expect(response.answersJSON == raw)
        return try #require(PDFDocument(data: data))
    }

    /// Text extraction alone can find glyphs drawn outside the visible page.
    /// Require every original evidence marker once and inside the body bounds.
    private func verifyVisible(_ markers: [String], in document: PDFDocument) throws {
        var issues: [String] = []
        for marker in markers {
            var matches = 0
            for index in 0..<document.pageCount {
                let page = try #require(document.page(at: index))
                let text = (page.string ?? "") as NSString
                var offset = 0
                while offset < text.length {
                    let range = text.range(of: marker, range: NSRange(location: offset, length: text.length - offset))
                    guard range.location != NSNotFound else { break }
                    matches += 1
                    if let selection = page.selection(for: range) {
                        let frame = selection.bounds(for: page)
                        let bounds = page.bounds(for: .mediaBox)
                        let body = CGRect(x: 40, y: 68, width: bounds.width - 80, height: bounds.height - 280)
                        if frame.isEmpty || frame.isInfinite || frame.isNull || !body.contains(frame) {
                            issues.append("\(marker) outside body on page \(index + 1): \(frame)")
                        }
                    } else { issues.append("\(marker) has no visible selection on page \(index + 1)") }
                    offset = NSMaxRange(range)
                }
            }
            if matches != 1 { issues.append("\(marker) appears \(matches) times") }
        }
        #expect(issues.count == 0, "Every original marker must be visible exactly once: \(issues.prefix(8))")
    }

    @Test func longServiceAnswersRemainVisibleAcrossPagesWithoutLosingEvidence() throws {
        let markers = (1...120).map { String(format: "Reading-%03d", $0) }
        let answer = markers.map { "\($0): Pressure verified; condensate drain clear." }.joined(separator: "\n")
        let document = try exportForm(label: "Detailed service notes", answer: answer, name: "Long service evidence")
        #expect(document.pageCount >= 4)
        try verifyVisible(markers, in: document)
    }

    @Test func longQuestionLabelsAndTheirAnswerBothSurvivePagination() throws {
        let markers = (1...48).map { String(format: "Question-%03d", $0) }
        let label = markers.map { "\($0) original inspection detail" }.joined(separator: "\n")
        let document = try exportForm(label: label, answer: "Original-Answer-Confirmed", name: "Long original question")
        #expect(document.pageCount >= 3)
        try verifyVisible(markers + ["Original-Answer-Confirmed"], in: document)
    }

    @Test func emptyReportSectionsDoNotLeaveOrphanHeadingsOrHideReadiness() throws {
        let customer = Customer(name: "Empty Report QA")
        let job = ServiceCall(type: .repair, scheduledDate: Date(), customer: customer)
        let url = try CustomerDocumentExporter.exportOnsiteReport(serviceCall: job, estimate: nil, invoice: nil,
                                                                  payments: [], includeFinancials: false)
        let data = try Data(contentsOf: url)
        Attachment.record(Array(data), named: "Unfinished repair report.pdf")
        let document = try #require(PDFDocument(data: data))
        let text = try #require(document.string)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(!lines.contains("Equipment"))
        #expect(!lines.contains("Service Notes"))
        #expect(text.contains("Report Readiness"))
        #expect(text.contains("Needs details"))
        #expect(text.contains("Closeout Readiness"))
        #expect(text.contains("Job ID"))
    }

    @Test func shortFormStaysOnOnePageWithoutAnEmptyContinuation() throws {
        let document = try exportForm(label: "Drain test", answer: "Drain-Verified-Once", name: "Short service form")
        #expect(document.pageCount == 1)
        #expect(document.string?.contains("(continued)") == false)
        try verifyVisible(["Drain-Verified-Once"], in: document)
    }

    @Test func sectionHeadingRemainsWithItsFirstAnswerAtThePageBoundary() throws {
        let customer = Customer(name: "Document Layout QA", address: "100 Fixture Lane")
        let job = ServiceCall(type: .repair, scheduledDate: Date(), customer: customer)
        let question = FieldFormQuestion(label: "Drain test", kind: .text, required: true)
        // This real completion block leaves 23 points after the next heading:
        // a nominal row fits, but the renderer's safe first-frame minimum does not.
        let template = FieldFormTemplate(title: Array(repeating: "Scope", count: 20).joined(separator: "\n"), questions: [question])
        let response = FieldFormResponse(serviceCallID: job.id, template: template, answers: [question.id: "Boundary-Answer"])
        let url = try CustomerDocumentExporter.exportFieldFormResponse(response, serviceCall: job, template: template)
        let data = try Data(contentsOf: url)
        Attachment.record(Array(data), named: "Boundary response heading.pdf")
        let document = try #require(PDFDocument(data: data))
        var headings = 0
        for index in 0..<document.pageCount {
            let text = try #require(document.page(at: index)?.string)
            if text.components(separatedBy: .newlines).contains("Responses") {
                headings += 1
                #expect(text.contains("Boundary-Answer"), "The first response must remain with its section heading on page \(index + 1)")
            }
        }
        #expect(headings == 1)
        try verifyVisible(["Boundary-Answer"], in: document)
    }

    @Test func longInvoiceAndEstimateNotesRetainEveryLineAndOriginalAmounts() throws {
        let customer = Customer(name: "Billing Layout QA", address: "100 Fixture Lane")
        let markers = (1...95).map { String(format: "Work-%03d", $0) }
        let notes = markers.map { "\($0): Original scope and completion detail." }.joined(separator: "\n")
        let internalNote = "Internal office note must remain internal"
        let invoice = Invoice(customer: customer, workType: .repair, lineItemSummary: "Contactor replacement",
                              amount: 125, notes: internalNote, completionNotes: notes)
        let estimate = Estimate(customer: customer, lineItemSummary: "Contactor replacement", amount: 125, notes: notes)
        let urls = [
            try CustomerDocumentExporter.exportInvoice(invoice, serviceCall: nil, payments: []),
            try CustomerDocumentExporter.exportEstimate(estimate, serviceCall: nil)
        ]
        for (index, url) in urls.enumerated() {
            let data = try Data(contentsOf: url)
            Attachment.record(Array(data), named: index == 0 ? "Long invoice.pdf" : "Long estimate.pdf")
            let document = try #require(PDFDocument(data: data))
            try verifyVisible(markers, in: document)
            #expect(document.string?.contains("$125.00") == true)
            #expect(document.string?.contains(internalNote) == false)
        }
        #expect(invoice.completionNotes == notes)
        #expect(invoice.notes == internalNote)
        #expect(estimate.notes == notes)
        #expect(invoice.amount == 125)
        #expect(estimate.amount == 125)
    }

    @Test func textFramesPreserveUnicodeClustersAndMakeBoundedForwardProgress() throws {
        let source = Array(repeating: "Cafe\u{301} • 👩🏽‍🔧 • 中文 • التبريد • 78°F\n", count: 35).joined()
        let original = source as NSString
        var layout = BusinessDocumentTextLayout(source, font: .systemFont(ofSize: 11), color: .black)
        let context = try #require(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var recovered = ""
        var frames = 0
        while !layout.isComplete && frames < 500 {
            let start = layout.offset
            let height = try layout.draw(in: CGRect(x: 0, y: 0, width: 95, height: 45), context: context)
            let range = NSRange(location: start, length: layout.offset - start)
            #expect(range.length > 0)
            #expect(Range(range, in: source) != nil)
            #expect(height > 0 && height <= 45)
            recovered += original.substring(with: range)
            frames += 1
        }
        #expect(layout.isComplete)
        #expect(frames > 1 && frames < 500)
        #expect(Array(recovered.utf16) == Array(source.utf16))
    }

    @Test func impossibleTextFrameFailsWithoutConsumingAnyOriginalText() throws {
        var layout = BusinessDocumentTextLayout("Original saved evidence", font: .systemFont(ofSize: 11), color: .black)
        let context = try #require(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        #expect(throws: CustomerDocumentExportError.self) {
            try layout.draw(in: CGRect(x: 0, y: 0, width: 100, height: 1), context: context)
        }
        #expect(layout.offset == 0)
        #expect(!layout.isComplete)
        _ = try layout.draw(in: CGRect(x: 0, y: 0, width: 140, height: 100), context: context)
        #expect(layout.isComplete)
    }
}
