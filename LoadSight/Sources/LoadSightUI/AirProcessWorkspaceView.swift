import SwiftUI
import LoadSightKit

struct AirProcessWorkspaceView: View {
    @Binding var document: LoadSightDocument
    @State private var deriving: AirProcessRecord?
    @State private var kind = AirProcessKind.mixing
    @State private var firstID = ""
    @State private var secondID = ""
    @State private var firstFlow = ""
    @State private var secondFlow = ""
    @State private var flowKind = AirInputClassification.userProvided
    @State private var name = ""
    @State private var author = ""
    @State private var source = ""
    @State private var result: AirProcessResult?
    @State private var failure: String?
    @State private var saved: String?
    var body: some View {
        Form {
            Section("Process inputs") {
                Picker("Process", selection: $kind) {
                    ForEach(AirProcessKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                switch conditions {
                case .success(let rows):
                    if rows.isEmpty { Text("Save air conditions in the Air conditions worksheet first.").foregroundStyle(.secondary) }
                    conditionPicker(kind == .mixing ? "First stream" : "Coil inlet", selection: $firstID, rows: rows)
                    conditionPicker(kind == .mixing ? "Second stream" : "Coil outlet", selection: $secondID, rows: rows)
                case .failure(let error): Text(error.localizedDescription).foregroundStyle(.red)
                }
                TextField(kind == .mixing ? "First stream actual CFM" : "Actual CFM at coil inlet", text: $firstFlow)
                derivedFlowButton(firstID, first: true)
                if kind == .mixing { TextField("Second stream actual CFM", text: $secondFlow); derivedFlowButton(secondID, first: false) }
                Picker("Airflow basis (all entered flows)", selection: $flowKind) {
                    ForEach(AirInputClassification.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Text("Use actual volume flow at each selected condition, not standard CFM. Conditions must share absolute pressure. Document each airflow source when saving.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Calculate process") {
                    do { result = try calculate(); failure = nil; saved = nil }
                    catch { failure = error.localizedDescription; result = nil }
                }
            }
            if let result { Section("Process result") { ProcessResultView(result: result) } }
            if let failure { Section { Text(failure).foregroundStyle(.red).textSelection(.enabled) } }
            Section("Save process to project") {
                TextField("Process name", text: $name)
                TextField("Recorded by", text: $author)
                TextField("Flow sources and assumptions", text: $source, axis: .vertical)
                Button("Save process") { save() }
                if let saved { Text(saved).foregroundStyle(.secondary) }
                Text("Retains the two condition references, actual airflow, classification, author, source and method. Saving reopens QA.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Saved processes") {
                switch Result(catching: { try document.project.airProcesses() }) {
                case .success(let rows):
                    if rows.isEmpty { Text("No processes saved.").foregroundStyle(.secondary) }
                    ForEach(rows) { row in
                        DisclosureGroup(row.name + " · " + row.kind.rawValue) {
                            Text(row.author + " · " + row.recordedAt)
                            Text(row.source).textSelection(.enabled)
                            if row.kind == .mixing { Button("Save output as a reusable condition") { deriving = row } }
                            Text("Flow basis: " + row.flowClassification.rawValue).font(.caption)
                            switch Result(catching: { try row.calculate(conditions: document.project.airConditions()) }) {
                            case .success(let output): ProcessResultView(result: output)
                            case .failure(let error): Text(error.localizedDescription).foregroundStyle(.red)
                            }
                        }
                    }
                case .failure(let error): Text(error.localizedDescription).foregroundStyle(.red)
                }
            }
        }.formStyle(.grouped)
        .sheet(item: $deriving) { process in
            MixedAirOutputEditor(document: $document, process: process) { deriving = nil; saved = "Output condition saved. It is available in the condition selectors." }
        }
        .onChange(of: [firstID, secondID, firstFlow, secondFlow, kind.rawValue, flowKind.rawValue]) { _, _ in result = nil; failure = nil; saved = nil }
        .onChange(of: document.project.root) { _, _ in result = nil }
    }
    private var conditions: Result<[AirConditionRecord], Error> { Result { try document.project.airConditions() } }
    private func conditionPicker(_ title: String, selection: Binding<String>, rows: [AirConditionRecord]) -> some View {
        Picker(title, selection: selection) {
            Text("Select condition").tag("")
            ForEach(rows) { row in Text(row.name + (row.derivation == nil ? "" : " · calculated") + " · " + row.id.prefix(6)).tag(row.id) }
        }
    }
    @ViewBuilder private func derivedFlowButton(_ id: String, first: Bool) -> some View {
        if case .success(let rows) = conditions, let d = rows.first(where: { $0.id == id })?.derivation {
            Button("Use saved mixed-stream airflow (" + d.actualCFM.formatted(.number.precision(.fractionLength(0...2))) + " CFM)") {
                if first { firstFlow = String(d.actualCFM) } else { secondFlow = String(d.actualCFM) }
                flowKind = .engineeringAssumption
                let basis = "Full mixed-stream outlet airflow from process " + d.processID
                source = source.isEmpty ? basis : source + "\n" + basis
            }
            Text("Use the full stream only when it matches this path; document a separate branch flow when needed.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func flows() throws -> (Double, Double?) {
        guard flowKind != .rfiRequired else { throw LoadSightError.invalid("Resolve the required airflow information before calculating.") }
        guard let first = Double(firstFlow), first.isFinite else { throw LoadSightError.invalid("Enter a numeric actual inlet airflow.") }
        if kind == .mixing {
            guard let second = Double(secondFlow), second.isFinite else { throw LoadSightError.invalid("Enter a numeric actual airflow for the second stream.") }
            return (first,second)
        }
        return (first,nil)
    }
    private func calculate() throws -> AirProcessResult {
        let rows = try conditions.get(), (flow1,flow2) = try flows()
        guard let first = rows.first(where: { $0.id == firstID }), let second = rows.first(where: { $0.id == secondID }) else { throw LoadSightError.invalid("Select both source conditions.") }
        switch kind {
        case .mixing: return .mixing(try AirProcesses.mix(first: first.calculate(), firstActualCFM: flow1, second: second.calculate(), secondActualCFM: flow2!))
        case .coolingCoil: return .coolingCoil(try AirProcesses.coolingCoil(inlet: first.calculate(), outlet: second.calculate(), inletActualCFM: flow1))
        }
    }
    private func save() {
        do {
            let (flow1,flow2) = try flows()
            try document.project.saveAirProcess(name: name, author: author, source: source, kind: kind, firstConditionID: firstID,
                secondConditionID: secondID, firstActualCFM: flow1, secondActualCFM: flow2, flowClassification: flowKind)
            result = try calculate(); failure = nil; saved = "Process saved. Project QA reopened."
        } catch { failure = error.localizedDescription; saved = nil }
    }
}

private struct ProcessResultView: View {
    let result: AirProcessResult
    var body: some View {
        Group {
            switch result {
            case .mixing(let mix):
                LabeledContent("Mixed dry bulb", value: format(mix.state.dryBulbC * 1.8 + 32, "°F"))
                LabeledContent("Mixed relative humidity", value: format(mix.state.relativeHumidity * 100, "%"))
                LabeledContent("Humidity ratio", value: format(mix.state.humidityRatio * 7000, "grains/lb dry air"))
                LabeledContent("Outlet actual airflow", value: format(mix.outletActualCFM, "CFM"))
                traceDetails(mix.traces)
            case .coolingCoil(let coil):
                LabeledContent("Total air-side cooling", value: format(coil.totalKW * AirProcesses.kwToBtuh, "Btuh"))
                LabeledContent("Sensible cooling", value: format(coil.sensibleKW * AirProcesses.kwToBtuh, "Btuh"))
                LabeledContent("Latent cooling", value: format(coil.latentKW * AirProcesses.kwToBtuh, "Btuh"))
                LabeledContent("Sensible heat ratio", value: coil.sensibleHeatRatio.map { format($0, "") } ?? "Undefined — zero load")
                LabeledContent("Water removed", value: format(coil.condensateKgPerHour * 2.20462262185, "lb/h"))
                traceDetails(coil.traces)
                if let analysis = coil.apparatusDewPoint { CoilADPResultView(analysis: analysis) }
            }
        }
    }
    private func traceDetails(_ traces: [CalculationTrace]) -> some View {
        Group {
            ForEach(traces.flatMap(\.assumptions), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Equations and substitutions") {
                ForEach(Array(traces.enumerated()), id: \.offset) { _, trace in
                    VStack(alignment: .leading) {
                        Text(trace.equation).bold()
                        Text(trace.substitution)
                        Text(format(trace.value, trace.unit))
                    }.font(.caption).textSelection(.enabled).padding(.vertical,4)
                }
            }
        }
    }
    private func format(_ value: Double, _ unit: String) -> String { value.formatted(.number.precision(.fractionLength(0...3))) + " " + unit }
}
