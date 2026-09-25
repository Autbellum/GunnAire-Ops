import Foundation
import LoadSightCore

/// Minimal RFC 4180 reader. NOAA station names embed commas ("BOSTON LOGAN
/// INTERNATIONAL AIRPORT, MA US"), so splitting on commas corrupts every row after
/// the name column. Quotes are honoured and doubled quotes unescape to one quote.
public enum DelimitedText {
    public static func fields(in line: Substring) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if quoted {
                if character == "\"" {
                    let next = line.index(after: index)
                    if next < line.endIndex, line[next] == "\"" { current.append("\""); index = next }
                    else { quoted = false }
                } else { current.append(character) }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                fields.append(current); current = ""
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        fields.append(current)
        return fields
    }

    /// Splits on newlines, tolerating CRLF and a trailing newline, and drops blank lines.
    public static func lines(of text: String) -> [Substring] {
        text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }
    }

    /// Maps a header row to column offsets so readers address columns by name.
    /// NOAA has added columns over the years; positional indexing silently rots.
    public struct Header: Sendable {
        private let offsets: [String: Int]
        public init(_ line: Substring) throws {
            var offsets: [String: Int] = [:]
            for (offset, name) in DelimitedText.fields(in: line).enumerated() {
                let key = name.trimmingCharacters(in: .whitespaces).uppercased()
                if !key.isEmpty && offsets[key] == nil { offsets[key] = offset }
            }
            try require(!offsets.isEmpty, "The file has no readable header row.")
            self.offsets = offsets
        }
        public func index(of column: String) throws -> Int {
            guard let offset = offsets[column.uppercased()] else {
                throw LoadSightError.invalid("Expected column \(column) is absent; the file layout has changed.")
            }
            return offset
        }
        public func contains(_ column: String) -> Bool { offsets[column.uppercased()] != nil }
    }
}

extension Array where Element == String {
    /// Bounds-checked column read. Short rows are common in NOAA files and must not trap.
    func value(at index: Int) -> String? {
        guard index >= 0, index < count else { return nil }
        let trimmed = self[index].trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
