import SwiftUI
import HVACCore

/// Add any material and build any assembly from it.
///
/// The shipped library covers what turns up most, not everything that exists. Straw bale,
/// reflective barriers, proprietary panels, an unusual masonry — all of it needs somewhere
/// to go, and it belongs to the job rather than to the application, so it saves inside the
/// file and cannot be lost when the app is reinstalled.
struct MaterialsEditor: View {
    @Bindable var engine: DesignEngine
    @State private var tab: Tab = .materials

    enum Tab: String, CaseIterable, Identifiable {
        case materials = "Materials", assemblies = "Assemblies"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            switch tab {
            case .materials: materials
            case .assemblies: assemblies
            }
        }
    }

    // MARK: Materials

    private var materials: some View {
        List {
            SwiftUI.Section {
                Text("A material is either sold by thickness, in which case it carries a resistance per inch, or made in one form, in which case it carries a fixed resistance and its actual thickness. Density and specific heat give it thermal mass, which is what delays a load; leave density at zero for a material with none.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach($engine.project.customLibrary.materials) { $material in
                CustomMaterialRow(material: $material)
            }
            .onDelete { offsets in
                engine.project.customLibrary.materials.remove(atOffsets: offsets)
            }

            SwiftUI.Section {
                Button("Add Material", systemImage: "plus") {
                    engine.project.customLibrary.materials.append(
                        HVACCore.Material(name: "New Material", resistancePerInch: 1.0,
                                 category: .insulation, density: 2, specificHeat: 0.2))
                }
                .buttonStyle(.borderless)
                Menu("Duplicate a Shipped Material") {
                    ForEach(HVACCore.Material.library) { material in
                        Button(material.name) {
                            engine.project.customLibrary.materials.append(
                                HVACCore.Material(name: material.name + " (copy)",
                                         resistancePerInch: material.resistancePerInch,
                                         fixedResistance: material.fixedResistance,
                                         category: material.category,
                                         density: material.density,
                                         specificHeat: material.specificHeat,
                                         nominalThicknessInches: material.nominalThicknessInches))
                        }
                    }
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    // MARK: Assemblies

    private var assemblies: some View {
        List {
            SwiftUI.Section {
                Text("An assembly is a stack of layers from outside to inside. Mark the insulated cavity so the parallel-path calculation knows where the framing interrupts it. U-value, effective R and the framing penalty are computed as you go.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach($engine.project.customLibrary.assemblies) { $assembly in
                CustomAssemblyRow(assembly: $assembly, available: engine.project.customLibrary.allMaterials())
            }
            .onDelete { offsets in
                engine.project.customLibrary.assemblies.remove(atOffsets: offsets)
            }

            SwiftUI.Section {
                Button("Add Empty Assembly", systemImage: "plus") {
                    engine.project.customLibrary.assemblies.append(
                        Assembly(name: "New Assembly", category: .wall, layers: [
                            Layer(material: .outsideAirFilmWinter, thicknessInches: 0),
                            Layer(material: .insideAirFilmVertical, thicknessInches: 0)
                        ], framing: .woodStud2x4at16))
                }
                .buttonStyle(.borderless)
                Menu("Start From a Shipped Assembly") {
                    ForEach(AssemblyLibrary.standard) { assembly in
                        Button(assembly.name) {
                            var copy = assembly
                            copy.id = UUID()
                            copy.name = assembly.name + " (copy)"
                            engine.project.customLibrary.assemblies.append(copy)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
            }
        }
    }
}

// MARK: - Rows

struct CustomMaterialRow: View {
    @Binding var material: HVACCore.Material
    @State private var usesFixedResistance = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: Binding(
                    get: { material.name },
                    set: { material = rebuilt(name: $0) }))
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: Binding(
                    get: { material.category },
                    set: { material = rebuilt(category: $0) })) {
                    ForEach(HVACCore.Material.Category.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 150)
            }
            Toggle("Sold in one form (fixed resistance)", isOn: Binding(
                get: { material.fixedResistance != nil },
                set: { fixed in
                    material = fixed
                        ? rebuilt(resistancePerInch: 0,
                                  fixedResistance: material.resistancePerInch > 0 ? material.resistancePerInch : 1,
                                  thickness: material.nominalThicknessInches ?? 0.5)
                        : rebuilt(resistancePerInch: 1.0, fixedResistance: .some(nil), thickness: .some(nil))
                }))
                .font(.caption)
            HStack {
                if material.fixedResistance != nil {
                    LabeledNumberField("R", value: Binding(
                        get: { material.fixedResistance ?? 0 },
                        set: { material = rebuilt(fixedResistance: $0) }), unit: "")
                    LabeledNumberField("Thickness", value: Binding(
                        get: { material.nominalThicknessInches ?? 0 },
                        set: { material = rebuilt(thickness: $0) }), unit: "in")
                } else {
                    LabeledNumberField("R per inch", value: Binding(
                        get: { material.resistancePerInch },
                        set: { material = rebuilt(resistancePerInch: $0) }), unit: "")
                }
            }
            HStack {
                LabeledNumberField("Density", value: Binding(
                    get: { material.density }, set: { material = rebuilt(density: $0) }), unit: "pcf")
                LabeledNumberField("Specific Heat", value: Binding(
                    get: { material.specificHeat }, set: { material = rebuilt(specificHeat: $0) }), unit: "")
                Spacer()
                Text(material.isMassive ? "carries mass" : "massless")
                    .font(.caption2)
                    .foregroundStyle(material.isMassive ? .green : .secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// `Material` is immutable, so every edit rebuilds it. That is deliberate: a value
    /// type cannot be changed underneath a calculation that is already reading it.
    private func rebuilt(name: String? = nil, category: HVACCore.Material.Category? = nil,
                         resistancePerInch: Double? = nil,
                         fixedResistance: Double?? = nil,
                         density: Double? = nil, specificHeat: Double? = nil,
                         thickness: Double?? = nil) -> HVACCore.Material {
        HVACCore.Material(name: name ?? material.name,
                 resistancePerInch: resistancePerInch ?? material.resistancePerInch,
                 fixedResistance: fixedResistance ?? material.fixedResistance,
                 category: category ?? material.category,
                 density: density ?? material.density,
                 specificHeat: specificHeat ?? material.specificHeat,
                 nominalThicknessInches: thickness ?? material.nominalThicknessInches)
    }
}

struct CustomAssemblyRow: View {
    @Binding var assembly: Assembly
    let available: [HVACCore.Material]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: $assembly.name).textFieldStyle(.roundedBorder)
                Picker("", selection: $assembly.category) {
                    ForEach(SurfaceCategory.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 150)
            }
            HStack {
                Picker("Framing", selection: Binding(
                    get: { assembly.framing.name },
                    set: { name in
                        if let match = Self.framingChoices.first(where: { $0.name == name }) {
                            assembly.framing = match
                        }
                    })) {
                    ForEach(Self.framingChoices, id: \.name) { Text($0.name).tag($0.name) }
                }
                LabeledNumberField("Absorptance", value: $assembly.solarAbsorptance, unit: "")
            }

            ForEach($assembly.layers) { $layer in
                HStack {
                    Picker("", selection: Binding(
                        get: { layer.material.name },
                        set: { name in
                            if let match = available.first(where: { $0.name == name }) {
                                layer.material = match
                            }
                        })) {
                        ForEach(available) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                    LabeledNumberField("in", value: $layer.thicknessInches, unit: "")
                    Toggle("cavity", isOn: $layer.isCavity).font(.caption2)
                    Text(String(format: "R %.2f", layer.resistance))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .onDelete { assembly.layers.remove(atOffsets: $0) }

            HStack {
                Button("Add Layer", systemImage: "plus") {
                    assembly.layers.insert(
                        Layer(material: available.first ?? .fiberglassBatt, thicknessInches: 1),
                        at: max(0, assembly.layers.count - 1))
                }
                .buttonStyle(.borderless).font(.caption)
                Spacer()
                Text(String(format: "U %.4f · effective R-%.1f%@",
                            assembly.uValue, assembly.effectiveR,
                            assembly.framingDescription.map { " · " + $0 } ?? ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    static let framingChoices: [Framing] = [
        .none, .woodStud2x4at16, .woodStud2x4at24, .woodStud2x6at16, .woodStud2x6at24
    ]
}
