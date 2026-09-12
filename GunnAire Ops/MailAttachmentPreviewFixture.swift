#if DEBUG
import UIKit

/// Local-only files for the existing isolated Mail UI fixture. No provider access.
@MainActor enum MailAttachmentPreviewFixture {
    static var attachment: GmailAttachment {
        if ProcessInfo.processInfo.arguments.contains("-uiTestMailPDFAttachment") {
            let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
                context.beginPage()
                ("Original equipment report" as NSString).draw(at: CGPoint(x: 48, y: 64),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black])
            }
            return .init(fileName: "EquipmentReport.pdf", mimeType: "application/pdf", data: data)
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestMailImageAttachment") {
            let data = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400)).pngData { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
                ("Original equipment photo" as NSString).draw(at: CGPoint(x: 40, y: 170),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.white])
            }
            return .init(fileName: "EquipmentPhoto.png", mimeType: "image/png", data: data)
        }
        return .init(fileName: "Equipment.txt", mimeType: "text/plain",
                     data: Data("Fixture equipment list.\n".utf8))
    }
}
#endif
