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

                    DisclosureGroup("Envelope Surfaces (\(zone.surfaces.count))") {
                        ForEach($zone.surfaces) { $surface in
                            SurfaceRow(surface: $surface)
                        }
                        .onDelete { zone.surfaces.remove(atOffsets: $0) }

                        Button("Add Surface", systemImage: "plus") {
                            engine.addSurface(to: zone.id)
                        }
                        .buttonStyle(.borderless)
                    }

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

struct SurfaceRow: View {
    @Binding var surface: Surface

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: $surface.name)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $surface.category) {
                    ForEach(SurfaceCategory.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            HStack {
                LabeledNumberField("Area", value: $surface.areaSquareFeet, unit: "ft²")
                LabeledNumberField("R", value: $surface.rValue, unit: "")
                Text(String(format: "U = %.3f", surface.uValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if surface.category.admitsSolarGain {
                HStack {
                    Picker("Facing", selection: $surface.orientation) {
                        ForEach(Orientation.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 180)
                    LabeledNumberField("SHGC", value: $surface.solarHeatGainCoefficient, unit: "")
                }
            }
            if surface.category == .roof || surface.category == .wall {
                Toggle("Use equivalent ΔT for cooling", isOn: Binding(
                    get: { surface.coolingEquivalentDeltaTF != nil },
                    set: { surface.coolingEquivalentDeltaTF = $0 ? 30 : nil }))
                    .font(.caption)
                if surface.coolingEquivalentDeltaTF != nil {
                    LabeledNumberField("Equivalent ΔT", value: Binding(
                        get: { surface.coolingEquivalentDeltaTF ?? 30 },
                        set: { surface.coolingEquivalentDeltaTF = $0 }), unit: "°F")
                }
            }
        }
        .padding(.vertical, 4)
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
