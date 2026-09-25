import SwiftUI
import HVACCore

/// Equipment and ductwork, one block per system.
///
/// A house is not always one system. Each block carries its own equipment, its own static
/// pressure budget and its own duct tree, because each is selected against the load of the
/// zones it actually serves.
struct SystemsEditor: View {
    @Bindable var engine: DesignEngine

    var body: some View {
        List {
            ForEach($engine.project.systems) { $system in
                SwiftUI.Section {
                    servedZones(system: system)

                    DisclosureGroup("Equipment") {
                        Text("Manual S selects against performance at the design condition, not nameplate tonnage. Enter the values from the manufacturer's expanded data at your outdoor design temperature.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Manufacturer", text: $system.equipment.manufacturer)
                        TextField("Model", text: $system.equipment.modelNumber)
                        Picker("Type", selection: $system.equipment.type) {
                            ForEach(EquipmentType.allCases) { Text($0.rawValue).tag($0) }
                        }
                        LabeledNumberField("Total Cooling", value: $system.equipment.totalCoolingCapacityBtuh, unit: "Btu")
                        LabeledNumberField("Sensible Cooling", value: $system.equipment.sensibleCoolingCapacityBtuh, unit: "Btu")
                        LabeledContent("Latent Cooling",
                                       value: String(format: "%.0f Btu/h", system.equipment.latentCoolingCapacityBtuh))
                        LabeledNumberField("Heating", value: $system.equipment.heatingCapacityBtuh, unit: "Btu")
                        LabeledNumberField("Maximum Airflow", value: $system.equipment.maximumAirflowCFM, unit: "CFM")
                        LabeledNumberField("External Static", value: $system.equipment.blowerExternalStaticPressure, unit: "in")
                        LabeledNumberField("Supply ΔT", value: $system.supplyAirDeltaTF, unit: "°F")
                    }

                    DisclosureGroup("Static Pressure Budget — \(String(format: "%.2f in", system.staticPressureBudget.total)) total") {
                        LabeledNumberField("Cooling Coil", value: $system.staticPressureBudget.coolingCoil, unit: "in")
                        LabeledNumberField("Filter", value: $system.staticPressureBudget.filter, unit: "in")
                        LabeledNumberField("Supply Registers", value: $system.staticPressureBudget.supplyRegisters, unit: "in")
                        LabeledNumberField("Return Grilles", value: $system.staticPressureBudget.returnGrilles, unit: "in")
                        LabeledNumberField("Balancing Dampers", value: $system.staticPressureBudget.balancingDampers, unit: "in")
                        LabeledNumberField("Other", value: $system.staticPressureBudget.other, unit: "in")
                    }

                    ductSection(system: $system)
                    results(for: system.id)
                } header: {
                    HStack {
                        TextField("System Name", text: $system.name)
                            .textFieldStyle(.plain).font(.headline)
                        Spacer()
                        Text("\(system.zoneIDs.count) zone\(system.zoneIDs.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { engine.removeSystems(at: $0) }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Add System", systemImage: "plus.circle.fill") { engine.addSystem() }
                Spacer()
                if !engine.project.unassignedZones.isEmpty {
                    Label("\(engine.project.unassignedZones.count) unassigned zone(s)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(10).background(.bar)
        }
    }

    // MARK: Zones

    private func servedZones(system: HVACSystem) -> some View {
        DisclosureGroup("Zones Served") {
            if engine.project.zones.isEmpty {
                Text("No zones yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(engine.project.zones) { zone in
                Toggle(zone.name, isOn: Binding(
                    get: { system.zoneIDs.contains(zone.id) },
                    set: { on in
                        // Assignment is exclusive: a zone counted by two systems would be
                        // double-counted in the building rollup.
                        engine.assign(zoneID: zone.id, toSystem: on ? system.id : nil)
                    }))
            }
        }
    }

    // MARK: Ducts

    private func ductSection(system: Binding<HVACSystem>) -> some View {
        DisclosureGroup("Duct Runs (\(system.wrappedValue.ductRuns.count))") {
            ForEach(system.ductRuns) { $run in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        TextField("Run Name", text: $run.name).textFieldStyle(.roundedBorder)
                        Picker("", selection: $run.role) {
                            ForEach(DuctRole.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 150)
                    }
                    HStack {
                        LabeledNumberField("Length", value: $run.physicalLengthFeet, unit: "ft")
                        Picker("Serves", selection: $run.servingZoneID) {
                            Text("— trunk —").tag(UUID?.none)
                            ForEach(engine.project.zones(servedBy: system.wrappedValue)) { zone in
                                Text(zone.name).tag(UUID?.some(zone.id))
                            }
                        }
                        .frame(width: 190)
                    }
                    Picker("Material", selection: Binding(
                        get: { DuctMaterial.allCases.first { $0.roughnessFeet == run.roughnessFeet } ?? .galvanizedSteel },
                        set: { run.roughnessFeet = $0.roughnessFeet })) {
                        ForEach(DuctMaterial.allCases) { Text($0.rawValue).tag($0) }
                    }
                    DisclosureGroup("Fittings (\(run.fittings.count)) — \(Int(run.totalEquivalentLengthFeet)) ft TEL") {
                        ForEach($run.fittings) { $fitting in
                            HStack {
                                TextField("Fitting", text: $fitting.name).textFieldStyle(.roundedBorder)
                                LabeledNumberField("EL", value: $fitting.equivalentLengthFeet, unit: "ft")
                                Stepper("×\(fitting.count)", value: $fitting.count, in: 1...20).frame(width: 96)
                            }
                        }
                        .onDelete { run.fittings.remove(atOffsets: $0) }
                        Menu("Add Fitting") {
                            ForEach(FittingType.library) { type in
                                Button(String(format: "%@  (C %.2f)", type.name, type.lossCoefficient)) {
                                    // Equivalent length is computed for the duct this
                                    // fitting sits in rather than read from a table.
                                    let sized = engine.ductSizing.first { $0.runID == run.id }
                                    run.fittings.append(.computed(
                                        type,
                                        diameterInches: sized?.nominalDiameterInches ?? 8,
                                        cfm: sized?.designCFM ?? 300,
                                        roughnessFeet: run.roughnessFeet))
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                    }
                    if let sized = engine.ductSizing.first(where: { $0.runID == run.id }),
                       sized.nominalDiameterInches > 0 {
                        MetricRow(label: "Size",
                                  value: String(format: "%.0f in @ %.0f CFM, %.0f FPM",
                                                sized.nominalDiameterInches, sized.designCFM, sized.velocityFPM),
                                  emphasis: true,
                                  tint: sized.velocityFPM > run.role.maximumVelocityFPM ? .orange : nil)
                    }
                }
                .padding(.vertical, 3)
            }
            .onDelete { engine.removeDuctRuns(at: $0, fromSystem: system.wrappedValue.id) }
            Button("Add Duct Run", systemImage: "plus") {
                engine.addDuctRun(toSystem: system.wrappedValue.id)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: Results

    @ViewBuilder
    private func results(for systemID: UUID) -> some View {
        if let result = engine.systems.first(where: { $0.id == systemID }) {
            Divider()
            MetricRow(label: "Cooling Total", value: String(format: "%.0f Btu/h", result.load.coolingTotalBtuh), emphasis: true)
            MetricRow(label: "Heating Total", value: String(format: "%.0f Btu/h", result.load.heatingBtuh))
            if let selection = result.selection {
                MetricRow(label: "Required Airflow", value: String(format: "%.0f CFM", selection.requiredAirflowCFM))
                let failures = selection.checks.filter { $0.status == .fail }
                let cautions = selection.checks.filter { $0.status == .caution }
                MetricRow(label: "Manual S",
                          value: failures.isEmpty ? (cautions.isEmpty ? "All checks pass" : "\(cautions.count) caution")
                                                  : "\(failures.count) fail",
                          emphasis: true,
                          tint: failures.isEmpty ? (cautions.isEmpty ? .green : .orange) : .red)
            }
            if let friction = result.friction, friction.frictionRatePer100Feet > 0 {
                MetricRow(label: "Friction Rate",
                          value: String(format: "%.3f in/100 ft", friction.frictionRatePer100Feet))
            }
        }
    }
}
