import SwiftUI
import LoadSightKit

struct ScheduleUnitDefinitionEditor: View {
    let field: EquipmentScheduleField
    let unitText: String
    @Binding var convention: ScheduleUnitConvention?
    @Binding var source: String
    var body: some View {
        Group {
            if !ScheduleUnitConvention.available(for: field).isEmpty {
                Picker("Source-defined unit convention", selection: $convention) {
                    Text("Not recorded").tag(ScheduleUnitConvention?.none)
                    ForEach(ScheduleUnitConvention.available(for: field), id: \.self) { value in
                        Text(value.title).tag(Optional(value))
                    }
                }.accessibilityIdentifier("ScheduleConvention-" + field.rawValue)
                if convention != nil {
                    TextField("Drawing legend or specification defining this unit", text: $source, axis: .vertical)
                        .accessibilityIdentifier("ScheduleConventionSource-" + field.rawValue)
                    Text("Keep the literal header unit unchanged. Cite the source that defines this abbreviation; a general conversion reference does not establish the drawing's convention.").font(.caption)
                }
            }
        }
        .onChange(of: field) { _, _ in convention = nil; source = "" }
        .onChange(of: unitText) { _, _ in convention = nil; source = "" }
        .onChange(of: convention) { _, _ in source = "" }
    }
}
