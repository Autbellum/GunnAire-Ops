import Combine
import Foundation
import UniformTypeIdentifiers

enum AttachmentPreviewContent: Equatable, Sendable {
    case text(String)
    case quickLook
    case unavailable

    // A native reader bound, not a file/import limit. Larger files keep Quick Look.
    nonisolated static let nativeTextByteLimit = 2 * 1_024 * 1_024

    nonisolated static func load(url: URL, allowsEditing: Bool) async -> Self {
        let task = Task.detached(priority: .userInitiated) {
            read(url: url, allowsEditing: allowsEditing)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated static func read(url: URL, allowsEditing: Bool) -> Self {
        guard url.isFileURL, !Task.isCancelled else { return .unavailable }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { return .unavailable }
            guard !allowsEditing,
                  UTType(filenameExtension: url.pathExtension)?.conforms(to: .plainText) == true,
                  let size = values.fileSize, size <= nativeTextByteLimit else { return .quickLook }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // Bound the actual read too: the file can grow after metadata is read.
            let data = try readBounded { try handle.read(upToCount: $0) }
            guard !Task.isCancelled else { return .unavailable }
            guard data.count <= nativeTextByteLimit else { return .quickLook }
            guard let text = decode(data) else { return .quickLook }
            return .text(text)
        } catch {
            return .unavailable
        }
    }

    nonisolated static func readBounded(_ read: (Int) throws -> Data?) throws -> Data {
        var data = Data()
        while data.count < nativeTextByteLimit + 1 {
            try Task.checkCancellation()
            let chunk = try read(nativeTextByteLimit + 1 - data.count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }

    nonisolated static func decode(_ data: Data) -> String? {
        // Do not guess legacy encodings or replace invalid bytes. Quick Look can
        // handle formats outside this reader; sharing always uses the original URL.
        let encodings: [([UInt8], String.Encoding)] = [
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
            ([0xEF, 0xBB, 0xBF], .utf8)
        ]
        for (mark, encoding) in encodings where data.starts(with: mark) {
            return decodeExactly(Data(data.dropFirst(mark.count)), encoding: encoding)
        }
        return decodeExactly(data, encoding: .utf8)
    }

    nonisolated private static func decodeExactly(_ data: Data, encoding: String.Encoding) -> String? {
        // Foundation accepts some incomplete UTF-16/32 sequences as empty text.
        // An exact round trip rejects dropped code units and lossy substitutions.
        guard let text = String(data: data, encoding: encoding),
              text.data(using: encoding, allowLossyConversion: false) == data else { return nil }
        return text
    }
}

@MainActor
final class AttachmentPreviewModel: ObservableObject {
    @Published private(set) var content: AttachmentPreviewContent?
    private(set) var url: URL?
    private var requestID = UUID()

    func load(
        url: URL, allowsEditing: Bool,
        loader: @Sendable (URL, Bool) async -> AttachmentPreviewContent = AttachmentPreviewContent.load
    ) async {
        let request = UUID()
        requestID = request
        self.url = url
        content = nil
        let result = await loader(url, allowsEditing)
        guard !Task.isCancelled, requestID == request else { return }
        content = result
    }

    func cancel() {
        requestID = UUID()
        url = nil
        content = nil
    }
}
