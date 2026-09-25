import SwiftUI
import HVACCore

/// Right panel — the live consequence of everything on the left and in the centre.
///
/// Ordered to match the cascade, so the eye travels the same path the calculation does:
/// loads, then the equipment tested against them, then the air, then the ducts. A failure
/// upstream is visible above the results that depend on it.
struct ResultsDashboard: View {
    @Bindable var engine: DesignEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let load = engine.load {
                    loadSection(load)
                    ForEach(engine.systems) { system in
                        systemCard(system)
                    }
                } else {
                    ContentUnavailableView("Nothing to calculate",
                                           systemImage: "square.dashed",
                                           description: Text(engine.calculationError ?? "Add a zone to begin."))
                }

                warningsSection
            }
            .padding(16)
        }
        .background(.background.secondary)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Design Summary").font(.title3.weight(.semibold))
            Text(engine.project.procedure.rawValue
                 + (engine.systems.count > 1 ? " · \(engine.systems.count) systems" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !engine.project.customer.customerName.isEmpty {
                Text(engine.project.customer.customerName).font(.caption).foregroundStyle(.secondary)
            }
            if !engine.project.customer.addressLine.isEmpty {
                Text(engine.project.customer.addressLine).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Loads

    private func loadSection(_ load: ProjectLoad) -> some View {
        DashboardCard(title: "Load — \(load.procedure.rawValue)", symbol: "thermometer.variable") {
            MetricRow(label: "Cooling Sensible", value: btuh(load.coolingSensibleBtuh),
                      emphasis: true)
            if let profile = engine.coolingProfile, profile.peakSensible > 0 {
                MetricRow(label: "", value: String(format: "coincident peak at %02d:00", profile.peakHour))
            }
            MetricRow(label: "Cooling Latent", value: btuh(load.coolingLatentBtuh))
            Divider()
            MetricRow(label: "Cooling Total", value: btuh(load.coolingTotalBtuh), emphasis: true)
            MetricRow(label: "", value: String(format: "%.2f tons", load.coolingTons))
            if let shr = load.sensibleHeatRatio {
                MetricRow(label: "Load SHR", value: String(format: "%.2f", shr))
            }
            Divider()
            MetricRow(label: "Heating Total", value: btuh(load.heatingBtuh), emphasis: true)

            if let profile = engine.coolingProfile, profile.peakSensible > 0 {
                Divider()
                MetricRow(label: "Sum of surface peaks",
                          value: btuh(profile.sumOfIndividualPeaks))
                MetricRow(label: "Diversity saving",
                          value: String(format: "%.0f%%  (%@ avoided)",
                                        (1 - profile.diversityFactor) * 100,
                                        btuh(profile.sumOfIndividualPeaks - profile.peakSensible)),
                          tint: .green)
                Text("The sensible load above is the coincident peak — the largest the building total ever reaches. Opaque assemblies are solved transiently, so each carries the lag its mass produces. Sizing on the sum of individual surface peaks would describe a building that never exists.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: One system

    private func systemCard(_ system: SystemResult) -> some View {
        let failures = system.selection?.checks.filter { $0.status == .fail } ?? []
        let cautions = system.selection?.checks.filter { $0.status == .caution } ?? []
        let tint: Color = failures.isEmpty ? (cautions.isEmpty ? .green : .orange) : .red

        return DashboardCard(title: system.name,
                             symbol: failures.isEmpty ? "checkmark.seal" : "xmark.seal",
                             tint: tint) {
            Text(system.zoneNames.isEmpty ? "No zones assigned"
                                          : system.zoneNames.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            MetricRow(label: "Cooling total", value: btuh(system.load.coolingTotalBtuh), emphasis: true)
            MetricRow(label: "", value: String(format: "%.2f tons", system.load.coolingTons))
            MetricRow(label: "Heating total", value: btuh(system.load.heatingBtuh), emphasis: true)
            if let profile = system.profile, profile.peakSensible > 0 {
                MetricRow(label: "Coincident peak",
                          value: String(format: "%@ at %02d:00", btuh(profile.peakSensible), profile.peakHour))
            }

            if let selection = system.selection {
                Divider()
                if let ratio = selection.totalCapacityRatio {
                    MetricRow(label: "Capacity", value: String(format: "%.0f%% of load", ratio * 100), emphasis: true)
                }
                ForEach(selection.checks) { check in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: check.status.symbol)
                                .foregroundStyle(check.status.tint).font(.caption2)
                            Text(check.name).font(.caption.weight(.medium))
                            Spacer()
                            Text(check.status.rawValue)
                                .font(.caption2.weight(.semibold)).foregroundStyle(check.status.tint)
                        }
                        if check.status != .pass {
                            Text(check.detail).font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            if !system.airflows.isEmpty {
                Divider()
                MetricRow(label: "System airflow",
                          value: String(format: "%.0f CFM cooling · %.0f heating",
                                        system.coolingCFM, system.heatingCFM), emphasis: true)
                ForEach(system.airflows) { airflow in
                    MetricRow(label: airflow.zoneName,
                              value: String(format: "%.0f CFM (%.0f%%)",
                                            airflow.designCFM, airflow.sensibleLoadFraction * 100))
                }
            }

            if let friction = system.friction, friction.frictionRatePer100Feet > 0 {
                Divider()
                MetricRow(label: "Available static",
                          value: String(format: "%.3f in. w.g.", friction.availableStaticPressure),
                          tint: friction.availableStaticPressure <= 0 ? .red : nil)
                MetricRow(label: "Friction rate",
                          value: String(format: "%.3f in/100 ft", friction.frictionRatePer100Feet), emphasis: true)
                ForEach(system.ducts) { run in
                    if run.nominalDiameterInches > 0 {
                        MetricRow(label: run.name,
                                  value: String(format: "%.0f in @ %.0f CFM", run.nominalDiameterInches, run.designCFM),
                                  tint: run.velocityFPM > run.role.maximumVelocityFPM ? .orange : nil)
                    }
                }
            }
        }
    }

    // MARK: Warnings

    @ViewBuilder
    private var warningsSection: some View {
        let warnings = engine.allWarnings
        if !warnings.isEmpty {
            DashboardCard(title: "Review", symbol: "exclamationmark.triangle", tint: .orange) {
                ForEach(warnings, id: \.self) { warning in
                    Text("• " + warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func btuh(_ value: Double) -> String { String(format: "%.0f Btu/h", value) }
}

/// A titled group of metrics.
struct DashboardCard<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 5) { content }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }
}
