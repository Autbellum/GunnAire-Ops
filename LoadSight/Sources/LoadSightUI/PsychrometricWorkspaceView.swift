import SwiftUI
import LoadSightKit

struct CalculationWorkspaceView: View {
    @Binding var document: LoadSightDocument
    @State private var mode = "Air conditions"
    var body: some View {
        VStack(spacing: 0) {
            Picker("Calculation", selection: $mode) {
                Text("Room transmission").tag("Room transmission")
                Text("Envelope assemblies").tag("Envelope assemblies")
                Text("Air conditions").tag("Air conditions")
                Text("Air processes").tag("Air processes")
                Text("Sensible air load").tag("Sensible air load")
            }.pickerStyle(.menu).accessibilityIdentifier("calculation.mode").padding()
            if mode == "Room transmission" { RoomTransmissionWorkspaceView(document: $document) }
            else if mode == "Envelope assemblies" { EnvelopeAssemblyWorkspaceView(document: $document) }
            else if mode == "Air conditions" { PsychrometricWorkspaceView(document: $document) }
            else if mode == "Air processes" { AirProcessWorkspaceView(document: $document) }
            else { CalculationWorkbench() }
        }
    }
}

struct PsychrometricWorkspaceView: View {
    @Binding var document: LoadSightDocument
    private enum EntryFocus: Hashable { case dry, humidity, pressure }
    @FocusState private var entryFocus: EntryFocus?
    @State private var dry = ""
    @State private var rh = ""
    @State private var humidityMode = HumidityInputKind.relativeHumidity
    @State private var pressure = ""
    @State private var dryKind = AirInputClassification.userProvided
    @State private var rhKind = AirInputClassification.userProvided
    @State private var pressureKind = AirInputClassification.userProvided
    @State private var name = ""
    @State private var author = ""
    @State private var source = ""
    @State private var result: MoistAirState?
    @State private var error: String?
    @State private var saved: String?
    var body: some View {
        Form {
            Section("Air conditions") {
                Text("Calculate a moist-air state from dry bulb, humidity and absolute station pressure. Enter the pressure at the site, not a sea-level weather correction.")
                    .foregroundStyle(.secondary)
                LabeledContent("Dry bulb (°F)") {
                    TextField("Dry bulb (°F)", text: $dry).multilineTextAlignment(.trailing).focused($entryFocus,equals:.dry)
                }
                classification("Dry-bulb basis", selection: $dryKind)
                Picker("Humidity input", selection: $humidityMode) {
                    ForEach(HumidityInputKind.allCases, id: \.self) { Text(humidityTitle($0)).tag($0) }
                }
                LabeledContent(humidityTitle(humidityMode) + (humidityMode == .relativeHumidity ? " (%)" : " (°F)")) {
                    TextField(humidityTitle(humidityMode) + (humidityMode == .relativeHumidity ? " (%)" : " (°F)"), text: $rh).multilineTextAlignment(.trailing).focused($entryFocus,equals:.humidity)
                }
                classification("Humidity basis", selection: $rhKind)
                LabeledContent("Absolute station pressure (psia)") {
                    TextField("Absolute station pressure (psia)", text: $pressure).multilineTextAlignment(.trailing).focused($entryFocus,equals:.pressure)
                }
                classification("Pressure basis", selection: $pressureKind)
                Text("Supported range: −148 to 176 °F, 0–100% RH, 2.901–17.405 psia (20–120 kPa); saturation pressure must remain below total pressure. Wet bulb and dew/frost point cannot exceed dry bulb.").font(.caption)
                Button("Calculate air state") {
                    entryFocus = nil
                    do { result = try calculate(); error = nil; saved = nil }
                    catch { self.error = error.localizedDescription; result = nil }
                }
            }
            if let result { Section("Calculated air state") {
                stateRows(result)
                if let input = try? enteredHumidity() { humidityTrace(input, dryBulbC:result.dryBulbC, pressurePa:result.pressurePa) }
            } }
            if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            Section("Save condition to project") {
                TextField("Condition name (room, outdoor or coil location)", text: $name)
                TextField("Recorded by", text: $author)
                TextField("Source and design basis", text: $source, axis: .vertical)
                Button("Save condition") {
                    do {
                        let state = try calculate()
                        try document.project.saveAirCondition(name: name, author: author, source: source,
                            dryBulbC: state.dryBulbC, humidity: try enteredHumidity(), pressurePa: state.pressurePa, dryBulbClassification: dryKind, humidityClassification: rhKind, pressureClassification: pressureKind)
                        result = state; error = nil; saved = "Condition saved. Project QA reopened."
                    } catch { self.error = error.localizedDescription; saved = nil }
                }
                Text("Saving retains inputs, source, author and method. These conditions do not yet drive room or equipment loads.").font(.caption).foregroundStyle(.secondary)
                if let saved { Text(saved).foregroundStyle(.secondary) }
            }
            Section("Saved conditions") {
                switch savedRecords {
                case .success(let records):
                    if records.isEmpty { Text("No conditions saved.").foregroundStyle(.secondary) }
                    ForEach(records) { record in
                        DisclosureGroup(record.name) {
                            Text("\(record.author) · \(record.recordedAt)")
                            Text(record.source).textSelection(.enabled)
                            if let derivation = record.derivation {
                                Text("Calculated from mixed-air process " + derivation.processID)
                                Text("Full-stream outlet: " + number(derivation.actualCFM,"actual CFM"))
                                Text("Upstream evidence fingerprint: " + derivation.sourceFingerprint).font(.caption).textSelection(.enabled)
                            } else if let input = record.humidityInput {
                                Text("Original humidity input: " + humidityTitle(input.kind) + " " + number(input.kind == .relativeHumidity ? input.value*100 : input.value*1.8+32, input.kind == .relativeHumidity ? "%" : "°F"))
                            } else { Text("Original humidity basis: relative humidity (legacy record)").font(.caption) }
                            Text("Dry bulb: \(record.dryBulbClassification.rawValue); humidity: \(record.humidityClassification.rawValue); pressure: \(record.pressureClassification.rawValue)")
                            ForEach(record.assumptionsLog, id: \.self) { Text($0).font(.caption) }
                            if let state = try? record.calculate() {
                                stateRows(state)
                                if record.derivation == nil { humidityTrace(record.humidityInput ?? .init(kind:.relativeHumidity,value:record.relativeHumidity), dryBulbC:record.dryBulbC, pressurePa:record.pressurePa) }
                            }
                            Text(record.method).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .failure(let failure): Text(failure.localizedDescription).foregroundStyle(.red)
                }
            }
            Section("Method and units") {
                Text("W = 0.621945 × Pv / (P − Pv); Pv = RH × Pws(T). h(IP) = 0.240 × T°F + W × (1061 + 0.444 × T°F). Dew/frost point inverts saturation pressure; thermodynamic wet bulb solves the ASHRAE moist-air balance.")
                    .font(.caption).textSelection(.enabled)
                Text("Ideal-gas moist-air equations on a dry-air mass basis. IP enthalpy uses a 0 °F datum. SI calculations use a separate 0 °C datum; do not mix absolute enthalpies between them. This is an engineering worksheet, not a completed Manual J/N load calculation.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("PsychroLib equation references", destination: URL(string: Psychrometrics.sourceURL)!)
                DisclosureGroup("Third-party license") { Text(Psychrometrics.license).font(.caption).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: humidityMode) { _, _ in rh = ""; result = nil; error = nil; saved = nil }
        .onChange(of: [dry, rh, pressure, dryKind.rawValue, rhKind.rawValue, pressureKind.rawValue]) { _, _ in result = nil; error = nil; saved = nil }
    }
    private func classification(_ title: String, selection: Binding<AirInputClassification>) -> some View {
        Picker(title, selection: selection) {
            ForEach(AirInputClassification.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
    }
    @ViewBuilder private func humidityTrace(_ input: HumidityInput, dryBulbC: Double, pressurePa: Double) -> some View {
        switch Result(catching: { try Psychrometrics.humidityInputTrace(dryBulbC:dryBulbC,humidity:input,pressurePa:pressurePa) }) {
        case .success(let trace):
            DisclosureGroup("Original humidity-input equation") {
                Text(trace.equation).bold()
                Text(trace.substitution)
                Text(number(trace.value,trace.unit))
                ForEach(trace.assumptions,id: \.self) { Text($0) }
            }.font(.caption).textSelection(.enabled)
        case .failure(let failure): Text(failure.localizedDescription).foregroundStyle(.red)
        }
    }
    private func humidityTitle(_ kind: HumidityInputKind) -> String {
        switch kind { case .relativeHumidity: "Relative humidity"; case .wetBulbC: "Thermodynamic wet bulb"; case .dewPointC: "Dew / frost point" }
    }
    private func enteredHumidity() throws -> HumidityInput {
        guard let value = Double(rh), value.isFinite else { throw LoadSightError.invalid("Enter a numeric humidity measurement in the displayed units.") }
        return .init(kind:humidityMode,value:humidityMode == .relativeHumidity ? value/100 : (value-32)/1.8)
    }
    private var savedRecords: Result<[AirConditionRecord], Error> { Result { try document.project.airConditions() } }
    private func calculate() throws -> MoistAirState {
        guard ![dryKind, rhKind, pressureKind].contains(.rfiRequired) else { throw LoadSightError.invalid("Resolve the required air-condition information before calculating.") }
        guard let t = Double(dry), let p = Double(pressure) else {
            throw LoadSightError.invalid("Enter numeric dry bulb and absolute pressure.")
        }
        return try Psychrometrics.state(dryBulbC: (t - 32) / 1.8, humidity: try enteredHumidity(), pressurePa: p * 6894.757293168)
    }
    @ViewBuilder private func stateRows(_ s: MoistAirState) -> some View {
        LabeledContent("Dry bulb", value: number(s.dryBulbC * 1.8 + 32, "°F"))
        LabeledContent("Relative humidity", value: number(s.relativeHumidity * 100, "%"))
        LabeledContent("Absolute pressure", value: number(s.pressurePa / 6894.757293168, "psia"))
        LabeledContent("Humidity ratio", value: number(s.humidityRatio * 7000, "grains/lb dry air"))
        LabeledContent("Dew / frost point", value: s.dewPointC.map { number($0 * 1.8 + 32, "°F") } ?? "Unavailable — see note")
        LabeledContent("Thermodynamic wet bulb", value: s.wetBulbC.map { number($0 * 1.8 + 32, "°F") } ?? "Unavailable — see note")
        LabeledContent("Enthalpy (IP datum)", value: number(s.enthalpyBtuPerLbDryAir, "Btu/lb dry air"))
        LabeledContent("Specific volume", value: number(s.volumeM3PerKgDryAir * 16.018463, "ft³/lb dry air"))
        DisclosureGroup("Equations with these inputs") {
            Text("Pv = RH × Pws(T) = \(s.relativeHumidity) × \(s.relativeHumidity > 0 ? s.vaporPressurePa / s.relativeHumidity : (try? Psychrometrics.saturationPressurePa(atC: s.dryBulbC)) ?? 0) = \(s.vaporPressurePa) Pa")
            Text("W = 0.621945 × \(s.vaporPressurePa) / (\(s.pressurePa) − \(s.vaporPressurePa)) = \(s.humidityRatio) lb/lb dry air")
            Text("h = 0.240 × \(s.dryBulbC * 1.8 + 32) + \(s.humidityRatio) × (1061 + 0.444 × \(s.dryBulbC * 1.8 + 32)) = \(s.enthalpyBtuPerLbDryAir) Btu/lb dry air")
            Text("v(SI) = 287.042 × \(s.dryBulbC + 273.15) × (1 + 1.607858 × \(s.humidityRatio)) / \(s.pressurePa) = \(s.volumeM3PerKgDryAir) m³/kg dry air")
        }.font(.caption).textSelection(.enabled)
        ForEach(s.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
    }
    private func number(_ value: Double, _ unit: String) -> String { value.formatted(.number.precision(.fractionLength(0...3))) + " " + unit }
}
