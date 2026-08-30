import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct EquipmentAssetLabelContent: Equatable, Sendable {
    let equipmentID: UUID
    let systemName: String
    let equipmentSummary: String
    let serialNumber: String?
    let location: String?

    init(
        equipmentID: UUID,
        systemName: String,
        equipmentSummary: String,
        serialNumber: String?,
        location: String?
    ) {
        self.equipmentID = equipmentID
        self.systemName = Self.singleLine(systemName, fallback: "HVAC System")
        self.equipmentSummary = Self.singleLine(equipmentSummary, fallback: "Equipment profile")
        self.serialNumber = Self.optionalSingleLine(serialNumber)
        self.location = Self.optionalSingleLine(location)
    }

    var assetPayload: String {
        EquipmentCodeLookup.assetCode(for: equipmentID)
    }

    var shortAssetID: String {
        String(equipmentID.uuidString.suffix(8)).uppercased()
    }

    var safeFileName: String {
        "GunnAire-Equipment-\(shortAssetID).pdf"
    }

    private static func singleLine(_ value: String, fallback: String) -> String {
        optionalSingleLine(value) ?? fallback
    }

    private static func optionalSingleLine(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(96))
    }
}

enum EquipmentAssetLabelExportError: LocalizedError {
    case qrGenerationFailed

    var errorDescription: String? {
        switch self {
        case .qrGenerationFailed:
            "The equipment QR code could not be created. Try again before printing a label."
        }
    }
}

@MainActor
enum EquipmentAssetLabelExporter {
    static let pageBounds = CGRect(x: 0, y: 0, width: 288, height: 216)
    static let qrQuietZoneBounds = CGRect(x: 16, y: 50, width: 136, height: 136)
    static let qrImageInset: CGFloat = 14
    static let detailColumnX: CGFloat = 158

    static var qrImageBounds: CGRect {
        qrQuietZoneBounds.insetBy(dx: qrImageInset, dy: qrImageInset)
    }

    static func qrCGImage(for content: EquipmentAssetLabelContent) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.assetPayload.utf8)
        filter.correctionLevel = "H"
        guard let outputImage = filter.outputImage else { return nil }

        let targetDimension: CGFloat = 960
        let scale = max(1, floor(targetDimension / max(outputImage.extent.width, 1)))
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaledImage, from: scaledImage.extent)
    }

    static func pdfData(for content: EquipmentAssetLabelContent) throws -> Data {
        guard let qrCGImage = qrCGImage(for: content) else {
            throw EquipmentAssetLabelExportError.qrGenerationFailed
        }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "GunnAire Equipment Asset Label",
            kCGPDFContextCreator as String: "GunnAire Ops"
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds, format: format)
        return renderer.pdfData { rendererContext in
            rendererContext.beginPage()
            let context = rendererContext.cgContext

            UIColor.white.setFill()
            context.fill(pageBounds)
            context.setStrokeColor(UIColor.black.cgColor)
            context.setLineWidth(1)
            context.stroke(pageBounds.insetBy(dx: 6, dy: 6))

            "GunnAire Ops".draw(at: CGPoint(x: 18, y: 15), withAttributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .bold),
                .foregroundColor: UIColor.black
            ])
            "HVAC EQUIPMENT ASSET".draw(at: CGPoint(x: 154, y: 19), withAttributes: [
                .font: UIFont.systemFont(ofSize: 8, weight: .semibold),
                .foregroundColor: UIColor.darkGray
            ])

            UIColor.white.setFill()
            context.fill(qrQuietZoneBounds)
            UIImage(cgImage: qrCGImage)
                .withRenderingMode(.alwaysOriginal)
                .draw(in: qrImageBounds, blendMode: .normal, alpha: 1)

            var y: CGFloat = 45
            y = drawLabelValue("SYSTEM", content.systemName, at: y)
            y = drawLabelValue("EQUIPMENT", content.equipmentSummary, at: y)
            if let serialNumber = content.serialNumber {
                y = drawLabelValue("SERIAL", serialNumber, at: y)
            }
            if let location = content.location {
                y = drawLabelValue("AREA", location, at: y)
            }
            _ = drawLabelValue("ASSET ID", content.shortAssetID, at: y)

            "Scan in GunnAire Ops → Customers → Systems".draw(
                in: CGRect(x: detailColumnX, y: 196, width: 112, height: 12),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 7, weight: .medium),
                    .foregroundColor: UIColor.darkGray
                ]
            )
        }
    }

    static func exportPDF(for content: EquipmentAssetLabelContent) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GunnAire Equipment Labels", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(content.safeFileName, isDirectory: false)
        try pdfData(for: content).write(to: url, options: .atomic)
        return url
    }

    private static func drawLabelValue(_ label: String, _ value: String, at y: CGFloat) -> CGFloat {
        label.draw(at: CGPoint(x: detailColumnX, y: y), withAttributes: [
            .font: UIFont.systemFont(ofSize: 7, weight: .semibold),
            .foregroundColor: UIColor.darkGray
        ])
        let valueRect = CGRect(x: detailColumnX, y: y + 9, width: 112, height: 18)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: value, attributes: [
            .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]).draw(in: valueRect)
        return y + 29
    }
}

struct EquipmentAssetLabelSheet: View {
    @Environment(\.dismiss) private var dismiss

    let content: EquipmentAssetLabelContent

    @State private var exportURL: URL?
    @State private var exportError: String?

    private var qrImage: UIImage? {
        EquipmentAssetLabelExporter.qrCGImage(for: content).map { UIImage(cgImage: $0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 280)
                            .padding(16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            }
                            .accessibilityLabel("Equipment QR code for \(content.systemName)")
                    } else {
                        ContentUnavailableView(
                            "QR Code Unavailable",
                            systemImage: "qrcode",
                            description: Text("Close this label and try again before printing.")
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        labelRow("System", value: content.systemName)
                        labelRow("Equipment", value: content.equipmentSummary)
                        if let serialNumber = content.serialNumber {
                            labelRow("Serial", value: serialNumber)
                        }
                        if let location = content.location {
                            labelRow("Area", value: location)
                        }
                        labelRow("Asset ID", value: content.shortAssetID)
                    }
                    .frame(maxWidth: 440)

                    Label(
                        "The QR contains only GunnAire's internal equipment ID. Customer contact and address information are not embedded.",
                        systemImage: "lock.shield"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440, alignment: .leading)

                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share or Print Label PDF", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: 320)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("ShareEquipmentAssetLabel")
                    } else if let exportError {
                        Label(exportError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: 440, alignment: .leading)
                    } else {
                        ProgressView("Preparing printable label…")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .navigationTitle("Equipment QR Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: content.equipmentID) {
                prepareExport()
            }
        }
        .tint(Color.brandGold)
    }

    private func labelRow(_ label: String, value: String) -> some View {
        LabeledContent(label, value: value)
            .textSelection(.enabled)
    }

    private func prepareExport() {
        do {
            exportURL = try EquipmentAssetLabelExporter.exportPDF(for: content)
            exportError = nil
        } catch {
            exportURL = nil
            exportError = error.localizedDescription
        }
    }
}
