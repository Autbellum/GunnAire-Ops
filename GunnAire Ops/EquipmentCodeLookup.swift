import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Vision

#if !targetEnvironment(macCatalyst)
import VisionKit
#endif

nonisolated struct EquipmentNameplateDraft: Equatable, Sendable {
    var manufacturer: String
    var modelNumber: String
    var serialNumber: String
    let sourceLines: [String]

    var hasSuggestedValues: Bool {
        [manufacturer, modelNumber, serialNumber]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var suggestedValueCount: Int {
        [manufacturer, modelNumber, serialNumber]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    var sourceSummary: String {
        sourceLines.joined(separator: "\n")
    }
}

nonisolated enum EquipmentNameplateParser {
    private static let manufacturerAliases: [(canonical: String, aliases: [String])] = [
        ("American Standard", ["AMERICAN STANDARD"]),
        ("Mitsubishi Electric", ["MITSUBISHI ELECTRIC", "MITSUBISHI"]),
        ("International Comfort Products", ["INTERNATIONAL COMFORT PRODUCTS", "ICP"]),
        ("Honeywell Home", ["HONEYWELL HOME", "HONEYWELL"]),
        ("Comfortmaker", ["COMFORTMAKER"]),
        ("ClimateMaster", ["CLIMATEMASTER"]),
        ("WaterFurnace", ["WATERFURNACE"]),
        ("Aprilaire", ["APRILAIRE"]),
        ("Tempstar", ["TEMPSTAR"]),
        ("Fujitsu", ["FUJITSU"]),
        ("Goodman", ["GOODMAN"]),
        ("Coleman", ["COLEMAN"]),
        ("Carrier", ["CARRIER"]),
        ("Lennox", ["LENNOX"]),
        ("Trane", ["TRANE"]),
        ("Bryant", ["BRYANT"]),
        ("Payne", ["PAYNE"]),
        ("Daikin", ["DAIKIN"]),
        ("Amana", ["AMANA"]),
        ("Rheem", ["RHEEM"]),
        ("Ruud", ["RUUD"]),
        ("York", ["YORK"]),
        ("Bosch", ["BOSCH"]),
        ("Navien", ["NAVIEN"]),
        ("Noritz", ["NORITZ"]),
        ("Rinnai", ["RINNAI"]),
        ("Heil", ["HEIL"]),
        ("AAON", ["AAON"]),
        ("LG", ["LG"]),
        ("Samsung", ["SAMSUNG"])
    ]

    private static let modelPattern = try? NSRegularExpression(
        pattern: #"(?i)(?:^|\s)(?:MODEL(?:\s*(?:NUMBER|NO\.?|#))?|M\s*/\s*N)\s*[:#=\-]?\s*([A-Z0-9][A-Z0-9._/\-]{2,47})"#
    )
    private static let serialPattern = try? NSRegularExpression(
        pattern: #"(?i)(?:^|\s)(?:SERIAL(?:\s*(?:NUMBER|NO\.?|#))?|S\s*/\s*N|SN)\s*[:#=\-]?\s*([A-Z0-9][A-Z0-9._/\-]{2,47})"#
    )

    static func parse(lines rawLines: [String]) -> EquipmentNameplateDraft {
        let lines = rawLines
            .flatMap { $0.components(separatedBy: .newlines) }
            .map(cleanLine)
            .filter { !$0.isEmpty }

        return EquipmentNameplateDraft(
            manufacturer: manufacturer(in: lines) ?? "",
            modelNumber: labeledIdentifier(in: lines, pattern: modelPattern, standaloneLabels: ["MODEL", "MODEL NUMBER", "MODEL NO", "MODEL NO.", "M/N"]) ?? "",
            serialNumber: labeledIdentifier(in: lines, pattern: serialPattern, standaloneLabels: ["SERIAL", "SERIAL NUMBER", "SERIAL NO", "SERIAL NO.", "S/N", "SN"]) ?? "",
            sourceLines: lines
        )
    }

    private static func manufacturer(in lines: [String]) -> String? {
        for line in lines {
            let words = normalizedWords(in: line)
            for entry in manufacturerAliases {
                if entry.aliases.contains(where: { alias in
                    let aliasWords = normalizedWords(in: alias)
                    return containsContiguous(aliasWords, in: words)
                }) {
                    return entry.canonical
                }
            }
        }

        for line in lines {
            guard let value = valueAfterLabel(
                in: line,
                labels: ["MANUFACTURER", "MFR", "MAKE", "BRAND"]
            ) else { continue }
            let trimmed = cleanLine(value)
            if isPlausibleManufacturer(trimmed) { return trimmed }
        }
        return nil
    }

    private static func labeledIdentifier(
        in lines: [String],
        pattern: NSRegularExpression?,
        standaloneLabels: [String]
    ) -> String? {
        if let pattern {
            for line in lines {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard let match = pattern.firstMatch(in: line, range: range),
                      match.numberOfRanges > 1,
                      let valueRange = Range(match.range(at: 1), in: line) else { continue }
                let value = cleanIdentifier(String(line[valueRange]))
                if isPlausibleIdentifier(value) { return value }
            }
        }

        for index in lines.indices.dropLast() {
            let normalized = normalizedLabel(lines[index])
            guard standaloneLabels.contains(normalized) else { continue }
            let nextValue = cleanIdentifier(lines[lines.index(after: index)])
            if isPlausibleIdentifier(nextValue) { return nextValue }
        }
        return nil
    }

    private static func valueAfterLabel(in line: String, labels: [String]) -> String? {
        let uppercase = line.uppercased()
        for label in labels.sorted(by: { $0.count > $1.count }) {
            guard uppercase.hasPrefix(label) else { continue }
            let boundaryIndex = uppercase.index(uppercase.startIndex, offsetBy: label.count)
            if boundaryIndex < uppercase.endIndex,
               uppercase[boundaryIndex].isLetter || uppercase[boundaryIndex].isNumber {
                continue
            }
            let originalBoundary = line.index(line.startIndex, offsetBy: label.count)
            let remainder = line[originalBoundary...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " .:#=-\t"))
            return remainder.isEmpty ? nil : remainder
        }
        return nil
    }

    private static func cleanLine(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;#=()[]{}"))
    }

    private static func isPlausibleIdentifier(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard (3...48).contains(scalars.count),
              scalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else {
            return false
        }
        let normalized = value.uppercased()
        return !["NUMBER", "MODEL", "SERIAL", "UNKNOWN", "NONE"].contains(normalized)
    }

    private static func isPlausibleManufacturer(_ value: String) -> Bool {
        guard (2...64).contains(value.count),
              value.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            return false
        }
        return !["MODEL", "SERIAL", "UNKNOWN", "NONE"].contains(value.uppercased())
    }

    private static func normalizedLabel(_ value: String) -> String {
        value.uppercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " .:#=-\t"))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizedWords(in value: String) -> [String] {
        value.uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func containsContiguous(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }
}

nonisolated enum EquipmentNameplateRecognitionError: LocalizedError {
    case invalidImage
    case noReadableText

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "That image could not be read. Try another photo or enter the plate text manually."
        case .noReadableText:
            "No readable nameplate text was found. Improve the lighting or enter the values manually."
        }
    }
}

nonisolated enum EquipmentNameplateTextRecognizer {
    static func recognizeLines(in imageData: Data) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                throw EquipmentNameplateRecognitionError.invalidImage
            }

            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
            let orientationValue = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.006

            let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
            try handler.perform([request])
            let observations = (request.results ?? []).sorted { lhs, rhs in
                if abs(lhs.boundingBox.maxY - rhs.boundingBox.maxY) > 0.015 {
                    return lhs.boundingBox.maxY > rhs.boundingBox.maxY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            let lines = observations.compactMap { observation -> String? in
                guard let candidate = observation.topCandidates(1).first,
                      candidate.confidence >= 0.2 else { return nil }
                let line = candidate.string
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return line.isEmpty ? nil : line
            }
            guard !lines.isEmpty else { throw EquipmentNameplateRecognitionError.noReadableText }
            return lines
        }.value
    }
}

struct EquipmentNameplateCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onApply: (EquipmentNameplateDraft) -> Void

    @State private var showingCamera = false
    @State private var showingImageImporter = false
    @State private var isRecognizing = false
    @State private var enteredText = ""
    @State private var draft: EquipmentNameplateDraft?
    @State private var statusMessage: String?
    @FocusState private var manualTextIsFocused: Bool

    private var cameraIsAvailable: Bool {
        #if !targetEnvironment(macCatalyst)
        UIImagePickerController.isSourceTypeAvailable(.camera)
        #else
        false
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        "Recognition runs on this device. Review every suggested value before applying it to the open equipment editor.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ViewThatFits(in: .horizontal) {
                        HStack {
                            captureActions
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            captureActions
                        }
                    }
                }

                Section("Manual Recovery") {
                    Text("Paste or type the visible plate text when the camera is unavailable or a label is damaged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $enteredText)
                        .frame(minHeight: 96)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($manualTextIsFocused)
                        .accessibilityIdentifier("EquipmentNameplateManualText")
                    Button("Read Entered Text") {
                        manualTextIsFocused = false
                        review(lines: enteredText.components(separatedBy: .newlines))
                    }
                    .disabled(enteredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("ReadEquipmentNameplateText")
                }

                if isRecognizing {
                    Section {
                        ProgressView("Reading equipment data plate…")
                    }
                }

                if let draft {
                    Section("Review Before Applying") {
                        TextField("Manufacturer", text: draftBinding(\.manufacturer))
                            .accessibilityIdentifier("EquipmentNameplateManufacturer")
                        TextField("Model", text: draftBinding(\.modelNumber))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("EquipmentNameplateModel")
                        TextField("Serial Number", text: draftBinding(\.serialNumber))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("EquipmentNameplateSerial")

                        Text("Only these reviewed fields are copied. The equipment record is not saved until you use the editor's Save action.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            onApply(draft)
                            dismiss()
                        } label: {
                            Label("Apply to Equipment", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.hasSuggestedValues)
                        .accessibilityIdentifier("ApplyEquipmentNameplate")
                    }

                    if !draft.sourceLines.isEmpty {
                        Section {
                            DisclosureGroup("Recognized Text (\(draft.sourceLines.count) lines)") {
                                Text(draft.sourceSummary)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if let statusMessage {
                    Section {
                        Label(statusMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("EquipmentNameplateStatus")
                    }
                }
            }
            .navigationTitle("Read Equipment Data Plate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            #if !targetEnvironment(macCatalyst)
            .sheet(isPresented: $showingCamera) {
                EquipmentNameplateCameraPicker { image in
                    recognize(image)
                }
            }
            #endif
            .fileImporter(
                isPresented: $showingImageImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false,
                onCompletion: handleImageImport
            )
        }
        .tint(Color.brandGold)
    }

    @ViewBuilder
    private var captureActions: some View {
        if cameraIsAvailable {
            Button {
                showingCamera = true
            } label: {
                Label("Take Plate Photo", systemImage: "camera")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("TakeEquipmentNameplatePhoto")
        }

        Button {
            showingImageImporter = true
        } label: {
            Label("Import Plate Image", systemImage: "photo")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("ImportEquipmentNameplateImage")
    }

    private func draftBinding(_ keyPath: WritableKeyPath<EquipmentNameplateDraft, String>) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard var current = draft else { return }
                current[keyPath: keyPath] = newValue
                draft = current
            }
        )
    }

    private func recognize(_ image: UIImage) {
        guard let imageData = image.jpegData(compressionQuality: 0.96) else {
            statusMessage = EquipmentNameplateRecognitionError.invalidImage.localizedDescription
            return
        }
        isRecognizing = true
        statusMessage = nil
        Task {
            do {
                let lines = try await EquipmentNameplateTextRecognizer.recognizeLines(in: imageData)
                review(lines: lines)
            } catch {
                statusMessage = error.localizedDescription
            }
            isRecognizing = false
        }
    }

    private func review(lines: [String]) {
        let parsed = EquipmentNameplateParser.parse(lines: lines)
        draft = parsed
        statusMessage = parsed.hasSuggestedValues
            ? nil
            : "No manufacturer, model, or serial label was identified. Edit the recognized text or enter the values in the equipment editor."
    }

    private func handleImageImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            guard let image = UIImage(data: data) else {
                throw EquipmentNameplateRecognitionError.invalidImage
            }
            recognize(image)
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

#if !targetEnvironment(macCatalyst)
private struct EquipmentNameplateCameraPicker: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: EquipmentNameplateCameraPicker

        init(parent: EquipmentNameplateCameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif

struct EquipmentCodeCandidate: Equatable, Sendable {
    let id: UUID
    let customerID: UUID?
    let serialNumber: String?
}

enum EquipmentCodeResolution: Equatable, Sendable {
    case matched(UUID)
    case ambiguous(serial: String, equipmentIDs: [UUID])
    case outsideCustomer
    case notFound
    case empty
}

enum EquipmentCodeLookup {
    static let assetCodePrefix = "gunnaire-equipment:"

    static func assetCode(for equipmentID: UUID) -> String {
        "\(assetCodePrefix)\(equipmentID.uuidString.lowercased())"
    }

    static func resolve(
        _ rawValue: String,
        customerID: UUID,
        candidates: [EquipmentCodeCandidate]
    ) -> EquipmentCodeResolution {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        if let equipmentID = explicitEquipmentID(from: trimmed) {
            guard let match = candidates.first(where: { $0.id == equipmentID }) else {
                return .notFound
            }
            return match.customerID == customerID ? .matched(match.id) : .outsideCustomer
        }

        let normalizedScannedSerial = normalizedSerial(trimmed)
        guard normalizedScannedSerial.count >= 4 else { return .notFound }

        let allSerialMatches = candidates.filter {
            guard let serialNumber = $0.serialNumber else { return false }
            return normalizedSerial(serialNumber) == normalizedScannedSerial
        }
        let customerMatches = allSerialMatches.filter { $0.customerID == customerID }
        let uniqueCustomerIDs = Array(Set(customerMatches.map(\.id))).sorted { $0.uuidString < $1.uuidString }

        if uniqueCustomerIDs.count == 1, let match = uniqueCustomerIDs.first {
            return .matched(match)
        }
        if uniqueCustomerIDs.count > 1 {
            return .ambiguous(serial: trimmed, equipmentIDs: uniqueCustomerIDs)
        }
        return allSerialMatches.isEmpty ? .notFound : .outsideCustomer
    }

    nonisolated static func normalizedSerial(_ value: String) -> String {
        value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0).uppercased() }
            .joined()
    }

    private static func explicitEquipmentID(from value: String) -> UUID? {
        if let directID = UUID(uuidString: value) {
            return directID
        }

        let lowercaseValue = value.lowercased()
        if lowercaseValue.hasPrefix(assetCodePrefix) {
            let idStart = value.index(value.startIndex, offsetBy: assetCodePrefix.count)
            return UUID(uuidString: String(value[idStart...]))
        }

        guard let url = URL(string: value),
              url.scheme?.lowercased() == "gunnaireops",
              url.host?.lowercased() == "equipment" else {
            return nil
        }
        return UUID(uuidString: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

@MainActor
enum EquipmentBarcodeScannerAvailability {
    static var isSupported: Bool {
        #if !targetEnvironment(macCatalyst)
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
        #else
        false
        #endif
    }
}

struct EquipmentBarcodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onScan: (String) -> Void
    @State private var scannerMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                #if !targetEnvironment(macCatalyst)
                EquipmentBarcodeScannerRepresentable(
                    onScan: { payload in
                        onScan(payload)
                        dismiss()
                    },
                    onError: { scannerMessage = $0 }
                )
                .ignoresSafeArea(edges: .bottom)
                #else
                ContentUnavailableView(
                    "Camera Scan Unavailable",
                    systemImage: "barcode.viewfinder",
                    description: Text("Enter the equipment serial number in the customer Systems workspace.")
                )
                #endif
            }
            .navigationTitle("Scan Equipment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    Text(scannerMessage ?? "Point at a serial barcode or equipment QR code, then tap the highlighted code.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(scannerMessage == nil ? Color.secondary : Color.orange)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.regularMaterial)
            }
        }
    }
}

#if !targetEnvironment(macCatalyst)
private struct EquipmentBarcodeScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [.qr, .code128, .code39, .code93, .dataMatrix, .pdf417, .aztec])
            ],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        do {
            try scanner.startScanning()
        } catch {
            onError("Camera scanning could not start. Enter the serial number manually.")
        }
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private let onError: (String) -> Void

        init(onScan: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onScan = onScan
            self.onError = onError
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            guard case .barcode(let barcode) = item,
                  let payload = barcode.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !payload.isEmpty else {
                onError("That code did not contain a readable equipment value. Try another code or enter the serial number.")
                return
            }
            dataScanner.stopScanning()
            onScan(payload)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            onError("Camera scanning became unavailable. Enter the serial number manually.")
        }
    }
}
#endif
