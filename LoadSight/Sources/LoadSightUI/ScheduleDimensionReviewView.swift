import SwiftUI
import LoadSightKit

struct ScheduleDimensionReviewView: View {
    let interpretation: ScheduleDimensionInterpretation
    private var displayedValues: String {
        (interpretation.components ?? []).map { $0.formatted(.number.precision(.significantDigits(1...8))) }.joined(separator: " × ")
    }
    var body: some View {
        if let unit = interpretation.unit, interpretation.components != nil {
            Text("Dimensions in source order: " + displayedValues + " " + unit).accessibilityIdentifier("ScheduleDimensions")
        } else { Text("Dimensions: " + interpretation.status.rawValue).font(.caption) }
        DisclosureGroup("Dimension interpretation basis") {
            Text(interpretation.explanation).font(.caption)
            if let factor = interpretation.factor { Text("Each source dimension × \(factor.formatted()) m").font(.caption) }
            Link("Length conversion reference", destination: URL(string: ScheduleNumericInterpreter.reference)!)
        }
    }
}
