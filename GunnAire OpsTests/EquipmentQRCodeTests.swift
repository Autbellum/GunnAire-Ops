import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct EquipmentQRCodeTests {
    private func content(_ id: String) -> EquipmentAssetLabelContent {
        EquipmentAssetLabelContent(equipmentID: UUID(uuidString: id)!,
            systemName: "Main System", equipmentSummary: "Heat Pump",
            serialNumber: "QA-9000", location: "Mechanical Room")
    }

    @Test func generatedImageIncludesItsOwnFourModuleQuietZone() throws {
        let fixture = content("C06B1A7D-18DD-4EE8-8C22-77838F51C8BB")
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(fixture.assetPayload.utf8)
        filter.correctionLevel = "H"
        let unpadded = try #require(filter.outputImage)
        let paddedModules = unpadded.extent.width + 8
        let expectedDimension = Int(paddedModules * floor(960 / paddedModules))
        let image = try #require(EquipmentAssetLabelExporter.qrCGImage(for: fixture))
        #expect(image.width == expectedDimension)
        #expect(image.height == expectedDimension)
    }

    @Test(arguments: [
        "C06B1A7D-18DD-4EE8-8C22-77838F51C8BB",
        "DDF6E386-732C-439B-9411-6576A2B9C3FA",
        "B763BA19-ABC5-48B0-B7FD-E35CBFB9C67C",
        "A1000000-0000-4000-8000-000000000010",
        "00000000-0000-4000-8000-000000000000",
        "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"
    ])
    func equipmentQRDecodesWithSoftwareImageProcessing(id: String) throws {
        let fixture = content(id)
        let image = try #require(EquipmentAssetLabelExporter.qrCGImage(for: fixture))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode,
            context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let payloads = detector.features(in: CIImage(cgImage: image))
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(payloads == [fixture.assetPayload])
    }

    @Test func retainEquipmentLabelFixtureForVisualQA() throws {
        let fixture = content("C06B1A7D-18DD-4EE8-8C22-77838F51C8BB")
        let url = try EquipmentAssetLabelExporter.exportPDF(for: fixture)
        #expect(FileManager.default.fileExists(atPath: url.path))
        print("EQUIPMENT_QR_QA_PDF: \(url.path)")
    }
}
