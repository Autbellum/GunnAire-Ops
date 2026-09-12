import Foundation
import CoreGraphics
import CoreText

/// Draft-only document output. Final release and authenticated approval are separate workflows.
public enum DraftProposal {
    public static func pdf(_ project: ProjectDocument, generatedAt: Date = Date()) throws -> Data {
        try require(generatedAt.timeIntervalSince1970.isFinite, "Proposal generation time must be finite.")
        try project.validate(); try project.validateMarkupQuantities()
        let review = try EstimatePricing.review(project, asOf: generatedAt)
        let text = NSMutableAttributedString(string: "")
        let ink = CGColor(gray: 0.12, alpha: 1)
        var pendingGroup: String?
        func append(_ value: String, size: CGFloat = 10, bold: Bool = false) {
            let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            let group = pendingGroup ?? UUID().uuidString
            pendingGroup = bold ? group : nil
            text.append(NSAttributedString(string: value + "\n\n", attributes: [
                NSAttributedString.Key("LoadSightParagraphGroup"): group,
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink]))
        }
        func value(_ field: JSONValue) -> String {
            guard let result = field.string, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Unknown / not supplied" }
            return result
        }
        func section(_ heading: String) { append(heading, size: 14, bold: true) }
        append(project.name, size: 22, bold: true)
        append("DRAFT PROPOSAL - NOT FOR BID RELEASE", size: 12, bold: true)
        append("Prepared \(generatedAt.ISO8601Format())\nCustomer: \(value(project.root["inputs"]["customer"]))\nResponsible estimator: \(value(project.root["reviewer"]))")
        append("This draft reproduces recorded project evidence. Inherited takeoff records are not a new drawing verification. No final selling price or purchase authorization is issued by this export.")
        section("1. Scope and commercial basis")
        append(value(project.root["scopePolicy"]))
        append("Commercial terms: \(value(project.root["inputs"]["proposalTerms"]))")
        for field in ProposalDetails.fields {
            let entry = project.root["proposalDetails"][field.id]
            if let supplied = entry.string, !supplied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                append(field.label, size: 11, bold: true)
                append(supplied)
            }
        }
        let costLabels = [("laborRate", "Loaded labor rate ($/hour)"), ("markupPct", "Markup on cost (%)"), ("taxAllowance", "Tax allowance ($)"), ("jobCosts", "Other job costs ($)"), ("contingency", "Contingency ($)")]
        append(costLabels.map { key, label in "\(label): \(project.root["inputs"][key].number.map { String($0) } ?? "Unknown")" }.joined(separator: "\n"))
        if review.pricedCount > 0 { append("Known direct cost: \(String(format: "%.2f", review.knownDirectCost)) USD from \(review.pricedCount) of \(review.includedCount) included rows. Unpriced rows are not zero-valued.") }
        else { append("No included rows have complete costs. Project selling price is withheld.") }
        section("2. Review issues")
        append(review.blockers.isEmpty ? "Recorded review gates pass. This document still requires final proposal comparison and authorized release." : review.blockers.map { "- " + $0 }.joined(separator: "\n"))
        section("3. Drawing and addenda basis")
        let sheets = project.root["sheets"].array ?? []
        append(sheets.isEmpty ? "No drawing register supplied." : sheets.map { "\(value($0["sheet"])) | \(value($0["title"])) | Revision: \(value($0["revision"]))" }.joined(separator: "\n"))
        append("Source fingerprint: \(value(project.root["sourceSha256"]))")
        for sheet in sheets where sheet["sourceID"].string != nil { append("\(value(sheet["sheet"])): source \(value(sheet["sourceID"]))", size: 8) }
        section("4. Recorded quantities and scope decisions")
        if project.items.isEmpty { append("No takeoff items supplied.") }
        for item in project.items {
            append("\(item["id"]?.string ?? "") | \(item["description"]?.string ?? "")", size: 11, bold: true)
            append("\(item["quantity"]?.number.map { String($0) } ?? "Unknown quantity") \(item["unit"]?.string ?? "") | \(item["scope"]?.string ?? "") | \(item["lifecycle"]?.string ?? "") | \(item["quantityStatus"]?.string ?? "")\nSource: \(value(item["source"] ?? .null))\nBasis: \(value(item["basis"] ?? .null))\nAllowance: \(value(item["allowanceNote"] ?? .null))\nNotes: \(value(item["notes"] ?? .null))")
        }
        section("5. Requests for information")
        let rfis = project.root["rfis"].array ?? []
        if rfis.isEmpty { append("No RFIs recorded. This is not confirmation that no clarifications are required.") }
        for rfi in rfis {
            append("\(value(rfi["id"])) | \(value(rfi["status"])) | \(value(rfi["title"]))", size: 11, bold: true)
            append("Question: \(value(rfi["question"]))\nSource: \(value(rfi["source"]))\nImpact: \(value(rfi["impact"]))\nResponse: \(value(rfi["response"]))\nAnswered by: \(value(rfi["resolvedBy"]))\nAnswer source: \(value(rfi["responseSource"]))")
        }
        section("6. Outstanding proposal inputs")
        append("Address, explicit inclusions/exclusions, alternates, bonds, schedule, lead times, validity, attachments and accepted addenda must be confirmed wherever not supplied in the recorded terms. Do not infer agreement from a blank field. Plumbing and electrical trade scope follows the recorded project scope policy.")
        append("Project review fingerprint: \(try project.qaFingerprint())", size: 8)
        return try paginate(text)
    }

    private static func paginate(_ text: NSAttributedString) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { throw LoadSightError.invalid("Unable to allocate PDF output.") }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw LoadSightError.invalid("Unable to create PDF context.") }
        let setter = CTFramesetterCreateWithAttributedString(text)
        var offset = 0, page = 0
        while offset < text.length {
            page += 1; context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(mediaBox)
            let path = CGPath(rect: CGRect(x: 48, y: 58, width: 516, height: 680), transform: nil)
            var frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil)
            var visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw LoadSightError.invalid("PDF text cannot fit within the page.") }
            let end = offset + visible.length
            if end < text.length {
                var groupRange = NSRange()
                _ = text.attribute(NSAttributedString.Key("LoadSightParagraphGroup"), at: end - 1, longestEffectiveRange: &groupRange, in: NSRange(location: 0, length: text.length))
                if groupRange.location > offset && NSMaxRange(groupRange) > end {
                    let nextPage = CTFramesetterCreateFrame(setter, CFRange(location: groupRange.location, length: groupRange.length), path, nil)
                    if CTFrameGetVisibleStringRange(nextPage).length == groupRange.length {
                        frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: groupRange.location - offset), path, nil)
                        visible = CTFrameGetVisibleStringRange(frame)
                    }
                }
            }
            CTFrameDraw(frame, context)
            let footer = NSAttributedString(string: "LOADSIGHT  |  DRAFT - NOT FOR BID RELEASE  |  Page \(page)", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 8, nil)])
            context.textPosition = CGPoint(x: 48, y: 30)
            CTLineDraw(CTLineCreateWithAttributedString(footer), context)
            context.endPDFPage(); offset += visible.length
        }
        context.closePDF()
        return output as Data
    }
}
