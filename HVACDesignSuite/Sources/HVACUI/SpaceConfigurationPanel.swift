import SwiftUI
import HVACCore

/// Centre panel — everything the engineer describes about the building.
struct SpaceConfigurationPanel: View {
    @Bindable var engine: DesignEngine
    @Binding var selection: CentrePanel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                ForEach(CentrePanel.allCases) { panel in
                    Label(panel.rawValue, systemImage: panel.symbol).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch selection {
            case .spaces: ZoneEditor(engine: engine)
            case .equipment: EquipmentEditor(engine: engine)
            case .ducts: DuctEditor(engine: engine)
            case .detail: LoadDetailList(engine: engine)
            case .library: LibraryBrowser()
            }
        }
    }
}

// MARK: - Zones and surfaces

struct ZoneEditor: View {
    @Bindable var engine: DesignEngine

    var body: some View {
        List {
            ForEach($engine.project.zones) { $zone in
                Section {
                    LabeledNumberField("Floor Area", value: $zone.floorAreaSquareFeet, unit: "ft²")
                    LabeledNumberField("Ceiling Height", value: $zone.ceilingHeightFeet, unit: "ft")
                    LabeledContent("Volume", value: String(format: "%.0f ft³", zone.volumeCubicFeet))

                    // Surfaces are the substance of a load calculation, so they are
                    // visible rather than folded behind a disclosure triangle. The
                    // supporting inputs below them collapse instead.
                    HStack {
                        Text("Envelope Surfaces").font(.subheadline.weight(.semibold))
                        Text("\(zone.surfaces.count)").foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Button("Add Surface", systemImage: "plus") {
                            engine.addSurface(to: zone.id)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(.top, 4)

                    ForEach($zone.surfaces) { $surface in
                        SurfaceRow(surface: $surface)
                    }
                    .onDelete { zone.surfaces.remove(atOffsets: $0) }

                    DisclosureGroup("Internal Gains") {
                        LabeledNumberField("Occupants", value: $zone.internalGains.occupantCount, unit: "ppl")
                        LabeledNumberField("Sensible / person", value: $zone.internalGains.sensiblePerOccupant, unit: "Btu")
                        LabeledNumberField("Latent / person", value: $zone.internalGains.latentPerOccupant, unit: "Btu")
                        if engine.project.procedure == .commercialManualN {
                            LabeledNumberField("Lighting", value: $zone.internalGains.lightingWattsPerSquareFoot, unit: "W/ft²")
                        }
                        LabeledNumberField("Appliance Sensible", value: $zone.internalGains.applianceSensibleBtuh, unit: "Btu")
                        LabeledNumberField("Appliance Latent", value: $zone.internalGains.applianceLatentBtuh, unit: "Btu")
                    }

                    DisclosureGroup("Air Exchange") {
                        LabeledNumberField("Infiltration", value: $zone.airExchange.airChangesPerHour, unit: "ACH")
                        LabeledNumberField("Ventilation", value: $zone.airExchange.ventilationCFM, unit: "CFM")
                        LabeledContent("Infiltration Airflow",
                                       value: String(format: "%.0f CFM",
                                                     zone.airExchange.infiltrationCFM(volumeCubicFeet: zone.volumeCubicFeet)))
                    }

                    if let result = engine.load?.zoneLoads.first(where: { $0.zoneID == zone.id }) {
                        Divider()
                        MetricRow(label: "Cooling Sensible", value: format(result.coolingSensibleBtuh))
                        MetricRow(label: "Cooling Latent", value: format(result.coolingLatentBtuh))
                        MetricRow(label: "Heating", value: format(result.heatingBtuh))
                        if let airflow = engine.zoneAirflows.first(where: { $0.zoneID == zone.id }) {
                            MetricRow(label: "Design Airflow",
                                      value: String(format: "%.0f CFM", airflow.designCFM),
                                      emphasis: true)
                        }
                    }
                } header: {
                    TextField("Zone Name", text: $zone.name)
                        .textFieldStyle(.plain)
                        .font(.headline)
                }
            }
            .onDelete { engine.removeZones(at: $0) }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Add Zone", systemImage: "plus.circle.fill") { engine.addZone() }
                Spacer()
            }
            .padding(10)
            .background(.bar)
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.0f Btu/h", value)
    }
}

/// One surface. The construction is chosen from the library; the U-value is a result,
/// never an input. Typing an R-value from a book is what this replaces.
struct SurfaceRow: View {
    @Binding var surface: Surface

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $surface.name)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $surface.category) {
                    ForEach(SurfaceCategory.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: surface.category) { _, category in
                    // The old construction is meaningless on a new category — a wall
                    // assembly on a window would silently keep a wall's U-value.
                    surface.construction = Self.defaultConstruction(for: category)
                }
            }

            if surface.category == .window {
                glazingPicker
            } else {
                assemblyPicker
            }

            // What the choice produced. Shown, not entered.
            HStack(spacing: 14) {
                LabeledNumberField("Area", value: $surface.areaSquareFeet, unit: "ft²")
                Picker("Facing", selection: $surface.orientation) {
                    ForEach(Orientation.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 150)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "U %.3f", surface.uValue))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Text(String(format: "R %.1f", surface.rValue))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Text(surface.construction.basis)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    // MARK: Pickers

    private var assemblyPicker: some View {
        let options = AssemblyLibrary.assemblies(for: surface.category)
        return HStack {
            Text("Construction").frame(width: 90, alignment: .leading)
            Menu {
                ForEach(options) { assembly in
                    Button {
                        surface.construction = .assembly(assembly)
                    } label: {
                        Text(String(format: "%@   —   U %.3f  (R-%.0f effective)",
                                    assembly.name, assembly.uValue, assembly.effectiveR))
                    }
                }
                if options.isEmpty {
                    Text("No library assemblies for this surface type").disabled(true)
                }
            } label: {
                HStack {
                    Text(surface.construction.name).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity)
        }
    }

    private var glazingPicker: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Glazing").frame(width: 90, alignment: .leading)
                Menu {
                    ForEach(GlazingType.library) { glazing in
                        Button {
                            surface.construction = .glazing(glazing, currentShading)
                        } label: {
                            Text(String(format: "%@   —   U %.2f, SHGC %.2f",
                                        glazing.name, glazing.uFactor,
                                        glazing.solarHeatGainCoefficient))
                        }
                    }
                } label: {
                    HStack {
                        Text(currentGlazing?.name ?? "Choose glazing").lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity)
            }
            HStack {
                Text("Shading").frame(width: 90, alignment: .leading)
                Picker("", selection: Binding(
                    get: { currentShading.name },
                    set: { name in
                        guard let shading = Shading.library.first(where: { $0.name == name }),
                              let glazing = currentGlazing else { return }
                        surface.construction = .glazing(glazing, shading)
                    })) {
                    ForEach(Shading.library, id: \.name) { shading in
                        Text(shading.factor < 1
                             ? String(format: "%@ (×%.2f)", shading.name, shading.factor)
                             : shading.name).tag(shading.name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var currentGlazing: GlazingType? {
        if case .glazing(let glazing, _) = surface.construction { return glazing }
        return nil
    }
    private var currentShading: Shading {
        if case .glazing(_, let shading) = surface.construction { return shading }
        return .none
    }

    static func defaultConstruction(for category: SurfaceCategory) -> Construction {
        if category == .window { return .glazing(.doublePaneLowEArgon, .none) }
        if let first = AssemblyLibrary.assemblies(for: category).first { return .assembly(first) }
        return .manual(rValue: 13, shgc: 0)
    }
}

// MARK: - Library

/// A browsable catalogue of everything the app can build a surface from, with the numbers
/// it computes for each. The point is that the data is visible before it is needed —
/// an engineer should be able to see that a 2×4 closed-cell wall loses 40% of its
/// labelled R to framing without first building a job around it.
struct LibraryBrowser: View {
    @State private var section: Section = .assemblies

    enum Section: String, CaseIterable, Identifiable {
        case assemblies = "Assemblies", glazing = "Glazing", materials = "Materials", fittings = "Fittings"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            switch section {
            case .assemblies: assemblies
            case .glazing: glazing
            case .materials: materials
            case .fittings: fittings
            }
        }
    }

    private var assemblies: some View {
        List {
            ForEach(SurfaceCategory.allCases) { category in
                let entries = AssemblyLibrary.assemblies(for: category)
                if !entries.isEmpty {
                    SwiftUI.Section(category.rawValue) {
                        ForEach(entries) { assembly in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(assembly.name).font(.callout.weight(.medium))
                                HStack(spacing: 16) {
                                    Text(String(format: "U %.3f", assembly.uValue))
                                    Text(String(format: "nominal R-%.0f", assembly.nominalR))
                                    Text(String(format: "effective R-%.1f", assembly.effectiveR))
                                    if let framing = assembly.framingDescription {
                                        Text(framing)
                                            .foregroundStyle(assembly.framingPenalty > 0.3 ? .orange : .secondary)
                                    }
                                }
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    private var glazing: some View {
        List {
            ForEach(GlazingType.library) { glazing in
                HStack {
                    Text(glazing.name).font(.callout)
                    Spacer()
                    Text(String(format: "U %.2f", glazing.uFactor)).monospacedDigit()
                    Text(String(format: "SHGC %.2f", glazing.solarHeatGainCoefficient))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            SwiftUI.Section("Shading multipliers") {
                ForEach(Shading.library, id: \.name) { shading in
                    HStack {
                        Text(shading.name)
                        Spacer()
                        Text(String(format: "×%.2f", shading.factor)).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var materials: some View {
        List {
            ForEach(Material.Category.allCases, id: \.rawValue) { category in
                let entries = Material.library.filter { $0.category == category }
                if !entries.isEmpty {
                    SwiftUI.Section(category.rawValue) {
                        ForEach(entries) { material in
                            HStack {
                                Text(material.name)
                                Spacer()
                                if let fixed = material.fixedResistance {
                                    Text(String(format: "R-%.2f", fixed)).monospacedDigit()
                                } else {
                                    Text(String(format: "R-%.2f / in", material.resistancePerInch)).monospacedDigit()
                                }
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }

    private var fittings: some View {
        List {
            SwiftUI.Section("Loss coefficients — equivalent length is computed per duct size") {
                ForEach(FittingType.library) { fitting in
                    HStack {
                        Text(fitting.name)
                        Spacer()
                        Text(String(format: "C %.2f", fitting.lossCoefficient)).monospacedDigit()
                        Text(String(format: "≈ %.0f ft @ 8 in", fitting.equivalentLength(
                            diameterInches: 8, cfm: 300,
                            roughnessFeet: DuctMaterial.galvanizedSteel.roughnessFeet)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

// MARK: - Equipment

struct EquipmentEditor: View {
    @Bindable var engine: DesignEngine

    var body: some View {
        Form {
            Section("Expanded Performance Data") {
                Text("Manual S selects against performance at the design condition, not against nameplate tonnage. Enter the values from the manufacturer's expanded data table at your outdoor design temperature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Manufacturer", text: $engine.project.equipment.manufacturer)
                TextField("Model", text: $engine.project.equipment.modelNumber)
                Picker("Type", selection: $engine.project.equipment.type) {
                    ForEach(EquipmentType.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section("Capacity at Design Condition") {
                LabeledNumberField("Total Cooling", value: $engine.project.equipment.totalCoolingCapacityBtuh, unit: "Btu")
                LabeledNumberField("Sensible Cooling", value: $engine.project.equipment.sensibleCoolingCapacityBtuh, unit: "Btu")
                LabeledContent("Latent Cooling",
                               value: String(format: "%.0f Btu/h", engine.project.equipment.latentCoolingCapacityBtuh))
                if let shr = engine.project.equipment.sensibleHeatRatio {
                    LabeledContent("Equipment SHR", value: String(format: "%.2f", shr))
                }
                LabeledNumberField("Heating", value: $engine.project.equipment.heatingCapacityBtuh, unit: "Btu")
            }

            Section("Blower") {
                LabeledNumberField("Maximum Airflow", value: $engine.project.equipment.maximumAirflowCFM, unit: "CFM")
                LabeledNumberField("External Static", value: $engine.project.equipment.blowerExternalStaticPressure, unit: "in")
            }

            Section("Manual S Sizing Limits") {
                Text("Verified against the published Manual S selection table. A heat pump's heating output has no percentage cap — it is selected on cooling, with supplemental heat covering the balance point.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledNumberField("Cooling Minimum", value: $engine.project.sizingLimits.coolingMinimumFraction, unit: "×")
                LabeledNumberField("A/C Cooling Max", value: $engine.project.sizingLimits.airConditionerCoolingMaximum, unit: "×")
                LabeledNumberField("Heat Pump Max (cooling-dominant)", value: $engine.project.sizingLimits.heatPumpCoolingMaximumCoolingDominant, unit: "×")
                LabeledNumberField("Heat Pump Max (heating-dominant)", value: $engine.project.sizingLimits.heatPumpCoolingMaximumHeatingDominant, unit: "×")
                LabeledNumberField("Furnace Heating Max", value: $engine.project.sizingLimits.furnaceHeatingMaximumFraction, unit: "×")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Ducts

struct DuctEditor: View {
    @Bindable var engine: DesignEngine

    var body: some View {
        List {
            if let friction = engine.frictionRate {
                Section("Friction Rate") {
                    MetricRow(label: "Blower External Static",
                              value: String(format: "%.2f in", friction.blowerExternalStaticPressure))
                    MetricRow(label: "Component Losses",
                              value: String(format: "− %.2f in", friction.componentLosses))
                    MetricRow(label: "Available Static Pressure",
                              value: String(format: "%.3f in", friction.availableStaticPressure),
                              emphasis: true,
                              tint: friction.availableStaticPressure <= 0 ? .red : nil)
                    MetricRow(label: "Governing TEL",
                              value: String(format: "%.0f ft", friction.governingTotalEquivalentLength))
                    MetricRow(label: "Friction Rate",
                              value: String(format: "%.3f in/100 ft", friction.frictionRatePer100Feet),
                              emphasis: true)
                    Text("FR = ASP × 100 / TEL")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            ForEach($engine.project.ductRuns) { $run in
                Section {
                    Picker("Role", selection: $run.role) {
                        ForEach(DuctRole.allCases) { Text($0.rawValue).tag($0) }
                    }
                    LabeledNumberField("Physical Length", value: $run.physicalLengthFeet, unit: "ft")

                    Picker("Serves", selection: $run.servingZoneID) {
                        Text("— trunk —").tag(UUID?.none)
                        ForEach(engine.project.zones) { zone in
                            Text(zone.name).tag(UUID?.some(zone.id))
                        }
                    }

                    Picker("Material", selection: Binding(
                        get: {
                            DuctMaterial.allCases.first { $0.roughnessFeet == run.roughnessFeet }
                                ?? .galvanizedSteel
                        },
                        set: { run.roughnessFeet = $0.roughnessFeet })) {
                        ForEach(DuctMaterial.allCases) { Text($0.rawValue).tag($0) }
                    }

                    DisclosureGroup("Fittings (\(run.fittings.count)) — \(Int(run.totalEquivalentLengthFeet)) ft TEL") {
                        ForEach($run.fittings) { $fitting in
                            HStack {
                                TextField("Fitting", text: $fitting.name)
                                    .textFieldStyle(.roundedBorder)
                                LabeledNumberField("EL", value: $fitting.equivalentLengthFeet, unit: "ft")
                                Stepper("×\(fitting.count)", value: $fitting.count, in: 1...20)
                                    .frame(width: 100)
                            }
                        }
                        .onDelete { run.fittings.remove(atOffsets: $0) }
                        Button("Add Fitting", systemImage: "plus") {
                            run.fittings.append(Fitting(name: "90° elbow", equivalentLengthFeet: 15))
                        }
                        .buttonStyle(.borderless)
                    }

                    if let sized = engine.ductSizing.first(where: { $0.runID == run.id }), sized.nominalDiameterInches > 0 {
                        Divider()
                        MetricRow(label: "Design Airflow", value: String(format: "%.0f CFM", sized.designCFM))
                        MetricRow(label: "Required Round",
                                  value: String(format: "%.1f in", sized.roundDiameterInches))
                        MetricRow(label: "Nominal Size",
                                  value: String(format: "%.0f in", sized.nominalDiameterInches),
                                  emphasis: true)
                        MetricRow(label: "Velocity",
                                  value: String(format: "%.0f FPM", sized.velocityFPM),
                                  tint: sized.velocityFPM > run.role.maximumVelocityFPM ? .orange : nil)
                        if let option = sized.rectangularOptions.first {
                            MetricRow(label: "Rectangular",
                                      value: String(format: "%.0f × %.0f in", option.height, option.width))
                        }
                        ForEach(sized.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    TextField("Run Name", text: $run.name)
                        .textFieldStyle(.plain)
                        .font(.headline)
                }
            }
            .onDelete { engine.removeDuctRuns(at: $0) }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Add Duct Run", systemImage: "plus.circle.fill") { engine.addDuctRun() }
                Spacer()
            }
            .padding(10)
            .background(.bar)
        }
    }
}

// MARK: - Load detail

/// Every component with the arithmetic that produced it — the view that makes the
/// calculation reviewable rather than merely believable.
struct LoadDetailList: View {
    @Bindable var engine: DesignEngine

    var body: some View {
        List {
            if let load = engine.load {
                ForEach(load.zoneLoads) { zone in
                    Section("\(zone.zoneName) — Cooling") {
                        ForEach(zone.coolingComponents) { ComponentRow(component: $0) }
                    }
                    Section("\(zone.zoneName) — Heating") {
                        ForEach(zone.heatingComponents) { ComponentRow(component: $0) }
                    }
                }
            } else {
                ContentUnavailableView("No load calculated",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(engine.calculationError ?? "Add a zone to begin."))
            }
        }
    }
}

struct ComponentRow: View {
    let component: LoadComponent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(component.name).font(.callout)
                Spacer()
                Text(String(format: "%.0f Btu/h", component.btuh))
                    .font(.callout.monospacedDigit().weight(.medium))
            }
            Text(component.formula)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(component.substitution)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            Text(component.reference)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
