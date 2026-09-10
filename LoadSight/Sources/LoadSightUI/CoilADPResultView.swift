import SwiftUI
import LoadSightKit

struct CoilADPResultView: View {
    let analysis: CoilADPAnalysis
    var body: some View {
        DisclosureGroup("Apparatus dew point and bypass factors") {
            Text(analysis.status.rawValue).font(.headline)
            ForEach(analysis.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(analysis.candidates.enumerated()), id: \.offset) { index, candidate in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Candidate \(index+1)").font(.headline)
                    LabeledContent("Apparatus dew point", value: value(candidate.temperatureC*1.8+32) + " °F")
                    LabeledContent("Temperature bypass factor", value: value(candidate.bypassFactorTemperature))
                    LabeledContent("Humidity bypass factor", value: value(candidate.bypassFactorHumidity))
                    LabeledContent("Enthalpy bypass factor", value: value(candidate.bypassFactorEnthalpy))
                    if candidate.nearTangent { Text("Near-tangent result — sensitive to input precision.").font(.caption).foregroundStyle(.orange) }
                    DisclosureGroup("Candidate equations") {
                        ForEach(Array(candidate.traces.enumerated()), id: \.offset) { _, trace in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(trace.equation).bold()
                                Text(trace.substitution)
                                Text(value(trace.value) + " " + trace.unit)
                            }.font(.caption).textSelection(.enabled).padding(.vertical,4)
                        }
                    }
                }.padding(.vertical,8)
            }
            Text(analysis.method).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func value(_ number: Double) -> String { number.formatted(.number.precision(.fractionLength(0...5))) }
}
