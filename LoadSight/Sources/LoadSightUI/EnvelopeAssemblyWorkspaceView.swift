import SwiftUI
import LoadSightKit

private struct LayerDraft: Identifiable, Equatable {
    let id = UUID()
    var name = "", resistance = "", source = ""
    var classification = AirInputClassification.userProvided
}
private struct PathDraft: Identifiable, Equatable {
    let id = UUID()
    var name = "", fraction = "", source = ""
    var classification = AirInputClassification.userProvided
    var layers = [LayerDraft()]
    func value() throws -> EnvelopePath {
        guard let fraction = Double(fraction), fraction.isFinite else { throw LoadSightError.invalid("Enter a numeric area fraction for \(name).") }
        return try .init(name: name, fraction: fraction, fractionSource: source, fractionClassification: classification, layers: layers.map {
            guard let r = Double($0.resistance), r.isFinite else { throw LoadSightError.invalid("Enter a numeric R-value for \($0.name).") }
            return .init(name: $0.name, resistance: r, source: $0.source, classification: $0.classification)
        })
    }
}
private struct AssemblyDraft: Equatable {
    var name = "", author = "", source = "", filmBasis = ""
    var construction = EnvelopeConstruction.woodFramed
    var paths = [PathDraft()]
}

struct EnvelopeAssemblyWorkspaceView: View {
    @Binding var document: LoadSightDocument
    @State private var draft = AssemblyDraft()
    @State private var result: EnvelopeAssemblyResult?
    @State private var error: String?
    @State private var saved: String?

    var body: some View {
        Form {
            Section("Envelope assembly") {
                Text("Build complete heat-flow paths through the assembly. Enter resistances in h·ft²·°F/Btu and area fractions from 0 to 1. No material values are supplied.").foregroundStyle(.secondary)
                TextField("Assembly name", text: $draft.name)
                Picker("Construction", selection: $draft.construction) {
                    ForEach(EnvelopeConstruction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextField("Recorded by", text: $draft.author)
                TextField("Drawing / assembly reference", text: $draft.source, axis: .vertical).accessibilityLabel("Drawing / assembly reference")
                TextField("Surface films: included layers or reason for omission", text: $draft.filmBasis, axis: .vertical).accessibilityLabel("Surface films: included layers or reason for omission")
                Text("Use this method for homogeneous layers or independent paths in wood framing. Metal framing, ground coupling and lateral thermal bridges need other methods.").font(.caption)
            }
            ForEach($draft.paths) { $path in
                Section("Heat-flow path") {
                    EnvelopePathEditor(path: $path)
                    Button("Remove path", role: .destructive) { draft.paths.removeAll { $0.id == path.id } }
                }
            }
            Section {
                Button("Add heat-flow path") { draft.paths.append(PathDraft()) }
                Text("Area fractions must cover the assembly and sum to 1. Enter all layers in every path, including common layers and applicable films.").font(.caption)
                Button("Review assembly") {
                    do {
                        var candidate = document.project
                        try save(to: &candidate)
                        result = try candidate.envelopeAssemblies().last?.calculate()
                        error = nil; saved = nil
                    } catch { result = nil; self.error = error.localizedDescription }
                }
                if let result { EnvelopeAssemblyResultRows(result: result) }
                Button("Save assembly to project") {
                    do {
                        try save(to: &document.project)
                        error = nil; saved = "Assembly saved. Project QA reopened."
                    } catch { self.error = error.localizedDescription; saved = nil }
                }
                if let saved { Text(saved).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("Saved assemblies") {
                switch records {
                case .failure(let error): Text(error.localizedDescription).foregroundStyle(.red)
                case .success(let records):
                    if records.isEmpty { Text("No assemblies saved.").foregroundStyle(.secondary) }
                    ForEach(records) { record in
                        DisclosureGroup(record.name) {
                            Text("\(record.author) · \(record.recordedAt)")
                            Text(record.source).textSelection(.enabled)
                            Text("\(record.construction.rawValue) · Surface films: \(record.filmBasis)")
                            ForEach(Array(record.paths.enumerated()), id: \.offset) { _, path in
                                DisclosureGroup("\(path.name) · area fraction \(path.fraction)") {
                                    Text("\(path.fractionClassification.rawValue): \(path.fractionSource)")
                                    ForEach(Array(path.layers.enumerated()), id: \.offset) { _, layer in
                                        Text("\(layer.name): R \(layer.resistance) h·ft²·°F/Btu\n\(layer.classification.rawValue): \(layer.source)")
                                    }
                                }
                            }
                            if let result = try? record.calculate() { EnvelopeAssemblyResultRows(result: result) }
                            ForEach(record.assumptionsLog, id: \.self) { Text($0).font(.caption) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: draft) { _, _ in result = nil; error = nil; saved = nil }
    }
    private var records: Result<[EnvelopeAssemblyRecord], Error> { Result { try document.project.envelopeAssemblies() } }
    private func save(to project: inout ProjectDocument) throws {
        try project.saveEnvelopeAssembly(name: draft.name, author: draft.author, source: draft.source,
            construction: draft.construction, filmBasis: draft.filmBasis, paths: draft.paths.map { try $0.value() })
    }
}

private struct EnvelopePathEditor: View {
    @Binding var path: PathDraft
    var body: some View {
        TextField("Path name (e.g. cavity or framing)", text: $path.name)
        LabeledContent("Area fraction (0–1)") { TextField("Area fraction (0–1)", text: $path.fraction).multilineTextAlignment(.trailing) }
        TextField("Area fraction source", text: $path.source, axis: .vertical).accessibilityLabel("Area fraction source")
        Picker("Area fraction classification", selection: $path.classification) {
            ForEach(AirInputClassification.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        ForEach($path.layers) { $layer in
            DisclosureGroup(layer.name.isEmpty ? "New resistance layer" : layer.name) {
                TextField("Layer name", text: $layer.name)
                LabeledContent("R-value (h·ft²·°F/Btu)") { TextField("R-value (h·ft²·°F/Btu)", text: $layer.resistance).multilineTextAlignment(.trailing) }
                TextField("Resistance source / thickness basis", text: $layer.source, axis: .vertical).accessibilityLabel("Resistance source / thickness basis")
                Picker("Resistance classification", selection: $layer.classification) {
                    ForEach(AirInputClassification.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Button("Remove layer", role: .destructive) { path.layers.removeAll { $0.id == layer.id } }
            }
        }
        Button("Add resistance layer") { path.layers.append(LayerDraft()) }
    }
}

private struct EnvelopeAssemblyResultRows: View {
    let result: EnvelopeAssemblyResult
    var body: some View {
        LabeledContent("Assembly U (Btuh/ft²·°F)", value: String(format: "%.6f", result.uFactor))
        LabeledContent("Effective R (h·ft²·°F/Btu)", value: String(format: "%.4f", result.effectiveR))
        DisclosureGroup("Calculation trace") {
            ForEach(Array(result.traces.enumerated()), id: \.offset) { _, trace in
                Text("\(trace.equation)\n\(trace.substitution) = \(trace.value) \(trace.unit)").font(.caption).textSelection(.enabled)
            }
        }
        Text("Assembly worksheet only. Room loads and code compliance remain separate.").font(.caption).foregroundStyle(.secondary)
    }
}
