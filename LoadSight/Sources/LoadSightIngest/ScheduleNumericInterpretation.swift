import Foundation

/// Recomputed review output, separate from literal cells and their source-bound identity.
public struct ScheduleNumericInterpretation: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case interpreted, missing, unresolved, notNumeric }
    public let field: EquipmentScheduleField
    public let status: Status
    public let value: Double?
    public let unit: String?
    public let factor: Double?
    public let offset: Double?
    public let explanation: String
    public let method: String
}

public struct ScheduleRowNumericReview: Codable, Equatable, Sendable {
    public let rowID: String
    public let cells: [ScheduleNumericInterpretation]
}

public enum ScheduleNumericInterpreter {
    public static let method = "Explicit scalar schedule units v1"
    public static let reference = "https://www.nist.gov/pml/special-publication-811/nist-guide-si-appendix-b-conversion-factors/nist-guide-si-appendix-b8"
    private struct Conversion {
        let unit: String
        let factor: Double
        var offset: Double = 0
    }
    public static func interpret(field: EquipmentScheduleField, text: String?, unitText: String?) -> ScheduleNumericInterpretation {
        func result(_ status: ScheduleNumericInterpretation.Status, _ explanation: String, value: Double? = nil, conversion: Conversion? = nil) -> ScheduleNumericInterpretation {
            .init(field: field, status: status, value: value, unit: conversion?.unit, factor: conversion?.factor, offset: conversion?.offset, explanation: explanation, method: method)
        }
        let supported: Set<EquipmentScheduleField> = [.quantity, .coolingTotal, .coolingSensible, .heatingCapacity, .furnaceInput, .furnaceOutput, .airflow, .outdoorAir, .externalStaticPressure, .enteringWaterTemperature, .leavingWaterTemperature, .waterFlow, .voltage, .phase, .minimumCircuitAmpacity, .maximumOvercurrentProtection, .weight]
        guard supported.contains(field) else { return result(.notNumeric, "Retained as literal text; no scalar interpretation.") }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result(.missing, "No recognized value; remains unknown.") }
        let scalar = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Explicit US-style thousands grouping only. Do not strip notes, ranges, suffixes or OCR errors.
        let pattern = #"^[+-]?(?:(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?|\.[0-9]+)$"#
        guard scalar.count <= 128, scalar.range(of: pattern, options: .regularExpression) != nil,
              let number = Double(scalar.replacingOccurrences(of: ",", with: "")), number.isFinite else {
            return result(.unresolved, "Requires one finite decimal scalar. Ranges, footnotes, embedded units and ambiguous number formats need source review.")
        }
        guard let rawUnit = unitText?.trimmingCharacters(in: .whitespacesAndNewlines), !rawUnit.isEmpty else {
            return result(.unresolved, "Unit not recorded. No unit inferred from the field name or number.")
        }
        let unit = rawUnit.replacingOccurrences(of: " ", with: "")
        let conversion: Conversion?
        switch field {
        case .airflow, .outdoorAir, .waterFlow:
            switch unit {
            case "CFM", "cfm", "ft3/min", "ft³/min": conversion = .init(unit: "m³/s", factor: 0.028316846592 / 60)
            case "L/s", "l/s": conversion = .init(unit: "m³/s", factor: 0.001)
            case "m3/s", "m³/s": conversion = .init(unit: "m³/s", factor: 1)
            case "m3/h", "m³/h": conversion = .init(unit: "m³/s", factor: 1 / 3600)
            case "USGPM", "USgal/min": conversion = .init(unit: "m³/s", factor: 0.003785411784 / 60)
            default: conversion = nil
            }
        case .coolingTotal, .coolingSensible, .heatingCapacity, .furnaceInput, .furnaceOutput:
            switch unit {
            case "W": conversion = .init(unit: "W", factor: 1)
            case "kW": conversion = .init(unit: "W", factor: 1000)
            case "MW": conversion = .init(unit: "W", factor: 1_000_000)
            case "Btu_IT/h", "BTU_IT/HR": conversion = .init(unit: "W", factor: 1055.05585262 / 3600)
            case "tonofrefrigeration", "tonR": conversion = .init(unit: "W", factor: 12000 * 1055.05585262 / 3600)
            default: conversion = nil
            }
        case .externalStaticPressure:
            switch unit {
            case "Pa": conversion = .init(unit: "Pa", factor: 1)
            case "kPa": conversion = .init(unit: "Pa", factor: 1000)
            default: conversion = nil
            }
        case .enteringWaterTemperature, .leavingWaterTemperature:
            switch unit {
            case "°F", "F": conversion = .init(unit: "°C", factor: 5 / 9, offset: -32 * 5 / 9)
            case "°C", "C": conversion = .init(unit: "°C", factor: 1)
            case "K": conversion = .init(unit: "°C", factor: 1, offset: -273.15)
            default: conversion = nil
            }
        case .weight:
            switch unit {
            case "lb", "lbs", "lbm": conversion = .init(unit: "kg", factor: 0.45359237)
            case "kg": conversion = .init(unit: "kg", factor: 1)
            default: conversion = nil
            }
        case .voltage: conversion = ["V", "volt", "volts"].contains(unit) ? .init(unit: "V", factor: 1) : nil
        case .minimumCircuitAmpacity, .maximumOvercurrentProtection: conversion = ["A", "amp", "amps"].contains(unit) ? .init(unit: "A", factor: 1) : nil
        case .phase: conversion = ["phase", "ph", "Ø"].contains(unit) ? .init(unit: "phase", factor: 1) : nil
        case .quantity: conversion = ["each", "EA", "ea", "count"].contains(unit) ? .init(unit: "each", factor: 1) : nil
        default: conversion = nil
        }
        guard let conversion else { return result(.unresolved, "Unsupported or ambiguous unit for this field. Record an explicit supported unit from the source; GPM, MBH, plain Btu/h and water-column pressure require a clarified convention.") }
        let value = number * conversion.factor + conversion.offset
        guard value.isFinite else { return result(.unresolved, "Conversion exceeds the finite numeric range.") }
        let temperature = field == .enteringWaterTemperature || field == .leavingWaterTemperature
        guard temperature ? value >= -273.15 : value >= 0 else { return result(.unresolved, "Value is outside the nonnegative scalar or absolute-temperature domain; inspect the source.") }
        if field == .quantity || field == .phase {
            // Binary rounding can turn literal 0.99999999999999999 into 1.
            // Counts require an integral source decimal, not just an integral Double.
            let integralLiteral = scalar.split(separator: ".", omittingEmptySubsequences: false)
                .dropFirst().allSatisfy { $0.allSatisfy { $0 == "0" } }
            guard integralLiteral, number.rounded() == number, number <= 9_007_199_254_740_991,
                  field != .phase || [1, 3].contains(number) else { return result(.unresolved, "Count must be an exactly representable nonnegative integer; supported phase values are 1 and 3.") }
        }
        return result(.interpreted, "Unreviewed arithmetic: source value × factor + offset. Verify number format, unit, mapping, recognition and row boundaries before use. No equipment count or engineering approval inferred.", value: value, conversion: conversion)
    }
}

extension EquipmentScheduleCell {
    public var numericInterpretation: ScheduleNumericInterpretation {
        ScheduleNumericInterpreter.interpret(field: field, text: text, unitText: unitText)
    }
}
