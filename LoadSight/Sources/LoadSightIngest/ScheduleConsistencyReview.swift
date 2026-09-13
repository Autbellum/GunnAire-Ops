import Foundation

public struct ScheduleConsistencyCheck: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case missing, unresolved, needsReview, noConflict, recorded }
    public let id: String
    public let fields: [EquipmentScheduleField]
    public let status: Status
    public let detail: String
    public let values: [ScheduleNumericInterpretation]
}

public struct ScheduleConsistencyReview: Codable, Equatable, Sendable {
    public let rowID: String
    public let method: String
    public let checks: [ScheduleConsistencyCheck]
    public let limitations: String
}

extension EquipmentScheduleRow {
    /// Conditional arithmetic screening, not equipment applicability, selection or design approval.
    public var consistencyReview: ScheduleConsistencyReview {
        let method = "Schedule consistency screening v1"
        var checks: [ScheduleConsistencyCheck] = []
        func cell(_ field: EquipmentScheduleField) -> EquipmentScheduleCell? { cells.first { $0.field == field } }
        func add(_ id: String, _ fields: [EquipmentScheduleField], _ status: ScheduleConsistencyCheck.Status, _ detail: String) {
            checks.append(.init(id: id, fields: fields, status: status, detail: detail,
                                values: fields.compactMap { cell($0)?.numericInterpretation }))
        }
        let partial = warnings.contains(EquipmentScheduleExtractor.partialRowWarning)
        func unreliable(_ fields: [EquipmentScheduleField]) -> Bool {
            partial || fields.contains { field in
                guard let evidence = cell(field)?.evidence, !evidence.isEmpty else { return true }
                return evidence.contains { $0.confidence < 0.75 }
            }
        }
        for field in [EquipmentScheduleField.minimumCircuitAmpacity, .maximumOvercurrentProtection, .weight, .externalStaticPressure, .outdoorAir] {
            let id = "coordination." + field.rawValue
            guard let value = cell(field) else {
                add(id, [field], .missing, "Column not mapped. Determine whether this field applies to the equipment and locate its source; absence here does not prove it is absent from the drawing.")
                continue
            }
            guard let text = value.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                add(id, [field], .missing, "Mapped cell has no recognized value. Check the original schedule and notes; applicability remains unreviewed.")
                continue
            }
            if unreliable([field]) {
                add(id, [field], .unresolved, "Recognized text exists, but partial-row or recognition evidence prevents a consistency conclusion. Inspect source boundaries and text.")
            } else if value.numericInterpretation.status != .interpreted {
                add(id, [field], .unresolved, "Recognized text exists, but its scalar value or unit is unresolved. Preserve the literal value and clarify its source convention.")
            } else {
                add(id, [field], .recorded, "A scalar value and explicit unit are recorded. Confirm equipment applicability, rating basis and source accuracy; this is not an approval.")
            }
        }
        func compare(_ id: String, _ smaller: EquipmentScheduleField, _ larger: EquipmentScheduleField, basis: String) {
            let fields = [smaller, larger]
            guard !unreliable(fields), let a = cell(smaller)?.numericInterpretation, let b = cell(larger)?.numericInterpretation,
                  a.status == .interpreted, b.status == .interpreted,
                  let av = a.value, let bv = b.value, a.unit == b.unit else {
                add(id, fields, .unresolved, "Comparison not evaluated: both fields need complete, sufficiently recognized scalar values and compatible explicit units. " + basis)
                return
            }
            // Relative tolerance is only for floating-point conversion noise, not an engineering allowance.
            let tolerance = max(abs(av), abs(bv)) * 1e-12
            if av - bv > tolerance {
                add(id, fields, .needsReview, "First value exceeds the second after unit conversion. " + basis)
            } else {
                add(id, fields, .noConflict, "No ordering conflict at the interpreted values. " + basis)
            }
        }
        compare("cooling.sensibleTotal", .coolingSensible, .coolingTotal,
                basis: "Compare only if sensible and total capacities describe the same equipment, operating conditions and rating basis; these relationships are not confirmed by tag matching.")
        compare("airflow.outdoorTotal", .outdoorAir, .airflow,
                basis: "Compare only if outdoor air is a component of this same total airstream at the same operating condition and volume reference. The airflow column's basis remains unconfirmed.")
        for field in [EquipmentScheduleField.coolingTotal, .coolingSensible, .heatingCapacity, .furnaceInput, .furnaceOutput] {
            guard let value = cell(field)?.numericInterpretation else { continue }
            if value.status == .interpreted && value.value == 0 && !unreliable([field]) {
                add("zero." + field.rawValue, [field], .needsReview, "A zero capacity is recorded. Verify whether it means an intentionally absent function, operating condition, placeholder or recognition error; no positive capacity is invented.")
            } else if value.status == .unresolved {
                add("capacity." + field.rawValue, [field], .unresolved, "Capacity text cannot be interpreted under the current scalar/unit/domain contract. Review its literal source and notes.")
            }
        }
        return .init(rowID: id, method: method, checks: checks,
                     limitations: "Conditional source screening only. No finding proves equipment suitability, code compliance, electrical protection sizing, design approval or physical quantity. Unmapped fields, unread content and unconfirmed rating bases remain unknown.")
    }
}
