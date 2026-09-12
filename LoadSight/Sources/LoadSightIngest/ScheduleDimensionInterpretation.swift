import Foundation

/// Ordered dimensions are not labeled width/height/depth unless that meaning is separately established.
public struct ScheduleDimensionInterpretation: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case interpreted, missing, unresolved }
    public let status: Status
    public let components: [Double]?
    public let unit: String?
    public let factor: Double?
    public let explanation: String
    public let method: String
}
public struct ScheduleRowDimensionReview: Codable, Equatable, Sendable {
    public let rowID: String
    public let interpretation: ScheduleDimensionInterpretation
}
public enum ScheduleDimensionInterpreter {
    public static let method = "Explicit schedule dimension sequence v1"
    public static func interpret(text: String?, unitText: String?) -> ScheduleDimensionInterpretation {
        func result(_ status: ScheduleDimensionInterpretation.Status, _ message: String, values: [Double]? = nil, factor: Double? = nil) -> ScheduleDimensionInterpretation {
            .init(status: status, components: values, unit: values == nil ? nil : "m", factor: factor, explanation: message, method: method)
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return result(.missing, "No recognized dimension sequence; dimensions remain unknown.")
        }
        guard text.count <= 256 else { return result(.unresolved, "Dimension sequence exceeds the supported text limit.") }
        guard let unit = unitText?.trimmingCharacters(in: .whitespacesAndNewlines), !unit.isEmpty else {
            return result(.unresolved, "Dimension unit is not recorded. No length unit or axis meaning is inferred.")
        }
        let factor: Double
        switch unit {
        case "in", "inch", "inches", "\"": factor = 0.0254
        case "ft", "foot", "feet", "'": factor = 0.3048
        case "mm": factor = 0.001
        case "cm": factor = 0.01
        case "m": factor = 1
        default: return result(.unresolved, "Unsupported or ambiguous dimension unit. Preserve the source and clarify its length convention.")
        }
        let tokens = text.components(separatedBy: CharacterSet(charactersIn: "xX×")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (2...3).contains(tokens.count) else { return result(.unresolved, "Supply two or three dimensions separated by x or ×. Single dimensions, labeled axes, clearances and other shapes require source review.") }
        let decimal = #"^(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#
        var values: [Double] = []
        for token in tokens {
            guard token.range(of: decimal, options: .regularExpression) != nil,
                  let value = Double(token), value.isFinite, value > 0, (value * factor).isFinite, value * factor > 0 else {
                return result(.unresolved, "Each component must be a positive finite decimal with no embedded units, fractions, ranges, footnotes or axis labels. No partial sequence is returned.")
            }
            values.append(value * factor)
        }
        return result(.interpreted, "Unreviewed dimensions in literal source order, each multiplied by the recorded factor. Axis names, orientation, clearance versus equipment size, mapping and recognition remain unconfirmed. No volume, area or takeoff quantity is inferred.", values: values, factor: factor)
    }
}
extension EquipmentScheduleCell {
    public var dimensionInterpretation: ScheduleDimensionInterpretation? {
        guard field == .dimensions else { return nil }
        return ScheduleDimensionInterpreter.interpret(text: text, unitText: unitText)
    }
}
extension EquipmentScheduleRow {
    public var dimensionReview: ScheduleRowDimensionReview {
        .init(rowID: id, interpretation: cells.first { $0.field == .dimensions }?.dimensionInterpretation ??
            .init(status: .missing, components: nil, unit: nil, factor: nil,
                  explanation: "Dimension column not mapped. Locate the source and confirm applicability; absence here does not establish missing drawing information.", method: ScheduleDimensionInterpreter.method))
    }
}
