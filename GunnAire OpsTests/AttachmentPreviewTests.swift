import Foundation
import QuickLook
import Testing
@testable import GunnAire_Ops

@MainActor struct AttachmentPreviewTests {
    private func withFile(_ data: Data, name: String = "Equipment.txt",
                          check: (URL) throws -> Void) throws {
        let original = GmailAttachment(fileName: name, mimeType: "application/octet-stream", data: data)
        let url = try GmailAttachmentLoader.previewFile(for: original)
        defer { GmailAttachmentLoader.removePreviewFile(url) }
        try check(url)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func nativeTextKeepsOriginalUnicodeWhitespaceAndSourceBytes() throws {
        let original = "  Equipment\r\nΔ pressure: 125 psi\t🔥\n<script>not HTML</script>\n"
        try withFile(Data(original.utf8)) { url in
            #expect(AttachmentPreviewContent.read(url: url, allowsEditing: false) == .text(original))
        }
    }

    @Test func allExplicitUnicodeByteOrdersDecodeWithoutChangingTheFile() throws {
        let original = "Thermostat — 72° 🔧\n"
        for (mark, encoding) in [([0xEF, 0xBB, 0xBF], String.Encoding.utf8),
                                 ([0xFF, 0xFE], .utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian),
                                 ([0xFF, 0xFE, 0, 0], .utf32LittleEndian), ([0, 0, 0xFE, 0xFF], .utf32BigEndian)] {
            let data = Data(mark.map(UInt8.init)) + (try #require(original.data(using: encoding)))
            try withFile(data) { url in
                #expect(AttachmentPreviewContent.read(url: url, allowsEditing: false) == .text(original))
            }
        }
    }

    @Test func invalidEncodingsStayWithQuickLookRatherThanDroppingBytes() throws {
        for data in [Data([0x80, 0xFF]), Data([0xFF, 0xFE, 0x41]),
                     Data([0xFF, 0xFE, 0x00, 0xD8]), Data([0, 0, 0xFE, 0xFF, 0x41])] {
            try withFile(data) { url in
                #expect(AttachmentPreviewContent.read(url: url, allowsEditing: false) == .quickLook)
            }
        }
    }

    @Test func emptyFileIsAnExplicitReadableEmptyResult() throws {
        try withFile(Data()) { url in
            #expect(AttachmentPreviewContent.read(url: url, allowsEditing: false) == .text(""))
        }
    }

    @Test func shortReadsAreCombinedUntilEOFInsteadOfDisplayingAPartialFile() throws {
        let original = Data("Equipment 🔧\r\nOriginal pressure reading".utf8)
        var offset = 0
        let result = try AttachmentPreviewContent.readBounded { requested in
            #expect(requested == AttachmentPreviewContent.nativeTextByteLimit + 1 - offset)
            let end = min(offset + 3, original.count)
            defer { offset = end }
            return Data(original[offset..<end])
        }
        #expect(result == original && offset == original.count)
    }

    @Test func readErrorAfterPartialBytesCannotReturnIncompleteSuccess() {
        var requests = 0
        #expect(throws: CocoaError(.fileReadUnknown)) {
            try AttachmentPreviewContent.readBounded { _ in
                requests += 1
                if requests == 1 { return Data("Incomplete".utf8) }
                throw CocoaError(.fileReadUnknown)
            }
        }
        #expect(requests == 2)
    }

    @Test func nativeLimitDoesNotTruncateOrRejectTheOriginalLargerFile() throws {
        let limit = AttachmentPreviewContent.nativeTextByteLimit
        try withFile(Data(repeating: 65, count: limit)) { url in
            guard case .text(let text) = AttachmentPreviewContent.read(url: url, allowsEditing: false) else {
                Issue.record("The exact native bound should be readable"); return
            }
            #expect(text.utf8.count == limit)
        }
        try withFile(Data(repeating: 65, count: limit + 1)) { url in
            #expect(AttachmentPreviewContent.read(url: url, allowsEditing: false) == .quickLook)
        }
    }

    @Test func nonTextFormatsAndEditableFilesKeepQuickLook() throws {
        for name in ["Photo.png", "Invoice.pdf", "Notes.rtf", "Manual.docx", "Readings.xlsx", "Unknown", "Page.html"] {
            try withFile(Data("fixture only".utf8), name: name) { url in
                #expect(AttachmentPreviewContent.read(url: url, allowsEditing: false) == .quickLook)
            }
        }
        try withFile(Data("Editable evidence".utf8)) { url in
            #expect(AttachmentPreviewContent.read(url: url, allowsEditing: true) == .quickLook)
        }
    }

    @Test func unavailableFileCanRecoverAtTheSameURLWithoutChangingItsBytes() throws {
        try withFile(Data("Recovered original".utf8)) { url in
            let moved = url.deletingLastPathComponent().appendingPathComponent("Retained.txt")
            try FileManager.default.moveItem(at: url, to: moved)
            #expect(AttachmentPreviewContent.read(url: url, allowsEditing: false) == .unavailable)
            try FileManager.default.moveItem(at: moved, to: url)
            #expect(AttachmentPreviewContent.read(url: url, allowsEditing: false) == .text("Recovered original"))
            #expect(AttachmentPreviewContent.read(url: url.deletingLastPathComponent(), allowsEditing: false) == .unavailable)
        }
        #expect(AttachmentPreviewContent.read(url: URL(string: "https://example.invalid/Equipment.txt")!,
                                              allowsEditing: false) == .unavailable)
    }

    @Test func originalAttachmentBytesSurvivePreviewAndForwardCreation() throws {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("Original equipment\r\n".utf8)
        let file = GmailAttachment(fileName: "Equipment.txt", mimeType: "text/plain", data: bytes)
        let url = try GmailAttachmentLoader.previewFile(for: file)
        defer { GmailAttachmentLoader.removePreviewFile(url) }
        #expect(AttachmentPreviewContent.read(url: url, allowsEditing: false) == .text("Original equipment\r\n"))
        let draft = try GmailOutgoingMessage(to: "fixture@example.invalid", subject: "Fwd: Equipment",
                                             body: "Original attached.", attachments: [file])
        #expect(draft.attachments[0].data == bytes)
        #expect(draft.attachments[0].fileName == "Equipment.txt")
        #expect(try Data(contentsOf: url) == bytes)
    }

    private actor Gate {
        private var continuation: CheckedContinuation<AttachmentPreviewContent, Never>?
        private var started: CheckedContinuation<Void, Never>?
        func load() async -> AttachmentPreviewContent {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started?.resume(); started = nil
            }
        }
        func waitForStart() async {
            if continuation != nil { return }
            await withCheckedContinuation { started = $0 }
        }
        func finish(_ result: AttachmentPreviewContent) {
            continuation?.resume(returning: result); continuation = nil
        }
    }

    @Test func replacementFileCannotBeOverwrittenByAnOlderRead() async {
        let model = AttachmentPreviewModel(), gate = Gate()
        let first = URL(fileURLWithPath: "/fixture/First.txt")
        let second = URL(fileURLWithPath: "/fixture/Second.txt")
        let old = Task { await model.load(url: first, allowsEditing: false) { _, _ in await gate.load() } }
        await gate.waitForStart()
        #expect(model.content == nil)
        await model.load(url: second, allowsEditing: false) { _, _ in .text("Second original") }
        await gate.finish(.text("First original")); await old.value
        #expect(model.url == second && model.content == .text("Second original"))
    }

    @Test func dismissalDiscardsInFlightContent() async {
        let model = AttachmentPreviewModel(), gate = Gate()
        let task = Task { await model.load(url: URL(fileURLWithPath: "/fixture/Original.txt"),
                                          allowsEditing: false) { _, _ in await gate.load() } }
        await gate.waitForStart(); model.cancel()
        await gate.finish(.text("Must not reappear")); await task.value
        #expect(model.url == nil && model.content == nil)
    }

    @Test func cancelledReadCannotPublishAndSameFileCanRetry() async {
        let model = AttachmentPreviewModel(), gate = Gate()
        let url = URL(fileURLWithPath: "/fixture/Original.txt")
        let task = Task { await model.load(url: url, allowsEditing: false) { _, _ in await gate.load() } }
        await gate.waitForStart(); task.cancel()
        await gate.finish(.text("Cancelled")); await task.value
        #expect(model.content == nil)
        await model.load(url: url, allowsEditing: false) { _, _ in .unavailable }
        #expect(model.content == .unavailable)
        await model.load(url: url, allowsEditing: false) { _, _ in .text("Original recovered") }
        #expect(model.content == .text("Original recovered"))
    }

    private final class PreviewSpy: QLPreviewController {
        var reloads = 0
        var refreshes = 0
        override func reloadData() { reloads += 1 }
        override func refreshCurrentPreviewItem() { refreshes += 1 }
    }

    @Test func quickLookReloadsOnlyWhenItemChangesAndExplicitRefreshUsesCurrentItem() {
        let first = URL(fileURLWithPath: "/fixture/First.pdf")
        let second = URL(fileURLWithPath: "/fixture/Second.pdf")
        let coordinator = AttachmentQuickLookPreview.Coordinator(url: first, onSaveEditedCopy: nil, onDismiss: nil)
        let controller = PreviewSpy(); coordinator.controller = controller
        coordinator.update(url: first, onSaveEditedCopy: nil, onDismiss: nil)
        #expect(controller.reloads == 0 && controller.refreshes == 0)
        coordinator.reloadPreview()
        #expect(controller.refreshes == 1 && controller.reloads == 0)
        coordinator.update(url: second, onSaveEditedCopy: nil, onDismiss: nil)
        #expect(controller.reloads == 1 && controller.title == "Second.pdf")
        #expect(coordinator.previewController(controller, previewItemAt: 0).previewItemURL == second)
        #expect(coordinator.numberOfPreviewItems(in: controller) == 1)
    }

    @Test func quickLookStillDeliversEditedCopyAndCurrentDismissCallback() {
        let original = URL(fileURLWithPath: "/fixture/Original.pdf")
        let copy = URL(fileURLWithPath: "/fixture/Annotated.pdf")
        let coordinator = AttachmentQuickLookPreview.Coordinator(url: original, onSaveEditedCopy: nil, onDismiss: nil)
        let controller = PreviewSpy()
        #expect(coordinator.previewController(controller, editingModeFor: original as NSURL) == .disabled)
        var saved: URL?, dismissed = false
        coordinator.update(url: original, onSaveEditedCopy: { saved = $0 }, onDismiss: { dismissed = true })
        #expect(coordinator.previewController(controller, editingModeFor: original as NSURL) == .createCopy)
        coordinator.previewController(controller, didSaveEditedCopyOf: original as NSURL, at: copy)
        coordinator.dismissPreview()
        #expect(saved == copy && dismissed && coordinator.url == original)
    }
}
