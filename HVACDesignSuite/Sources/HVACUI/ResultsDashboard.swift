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
                    if let selection = engine.selection { equipmentSection(selection) }
                    airflowSection
                    ductSection
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
            Text(engine.project.procedure.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Loads

    private func loadSection(_ load: ProjectLoad) -> some View {
        DashboardCard(title: "Load — \(load.procedure.rawValue)", symbol: "thermometer.variable") {
            MetricRow(label: "Cooling Sensible", value: btuh(load.coolingSensibleBtuh))
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
                MetricRow(label: "Coincident peak",
                          value: String(format: "%.0f Btu/h at %02d:00",
                                        profile.peakSensible, profile.peakHour),
                          emphasis: true)
                MetricRow(label: "Sum of surface peaks",
                          value: btuh(profile.sumOfIndividualPeaks))
                MetricRow(label: "Diversity",
                          value: String(format: "%.0f%%", profile.diversityFactor * 100),
                          tint: .green)
                Text("Surfaces peak at different hours, so the coincident figure is the largest the sum ever reaches. Opaque assemblies are solved transiently, carrying the lag their mass produces. Equipment above is still sized on the steady-state sensible load, which is the more conservative of the two.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Equipment

    private func equipmentSection(_ selection: SelectionResult) -> some View {
        DashboardCard(title: "Manual S — Equipment Match",
                      symbol: selection.isAcceptable ? "checkmark.seal" : "xmark.seal",
                      tint: selection.isAcceptable ? (selection.hasCautions ? .orange : .green) : .red) {
            if let ratio = selection.totalCapacityRatio {
                MetricRow(label: "Total Capacity",
                          value: String(format: "%.0f%% of load", ratio * 100),
                          emphasis: true)
            }
            ForEach(selection.checks) { check in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: check.status.symbol)
                            .foregroundStyle(check.status.tint)
                            .font(.caption)
                        Text(check.name).font(.callout.weight(.medium))
                        Spacer()
                        Text(check.status.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(check.status.tint)
                    }
                    Text(check.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(check.reference)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
            }
        }
    }

    // MARK: Airflow

    private var airflowSection: some View {
        DashboardCard(title: "Manual T — Air Distribution", symbol: "wind") {
            MetricRow(label: "System Cooling",
                      value: String(format: "%.0f CFM", engine.systemCoolingCFM), emphasis: true)
            MetricRow(label: "System Heating",
                      value: String(format: "%.0f CFM", engine.systemHeatingCFM))
            Divider()
            ForEach(engine.zoneAirflows) { airflow in
                MetricRow(label: airflow.zoneName,
                          value: String(format: "%.0f CFM  (%.0f%%)",
                                        airflow.designCFM, airflow.sensibleLoadFraction * 100))
            }
            Text("Room CFM = System CFM × (Room Sensible / Total Sensible)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Ducts

    private var ductSection: some View {
        DashboardCard(title: "Manual D — Duct Sizing", symbol: "pipe.and.drop") {
            if let friction = engine.frictionRate {
                MetricRow(label: "Available Static",
                          value: String(format: "%.3f in. w.g.", friction.availableStaticPressure),
                          emphasis: true,
                          tint: friction.availableStaticPressure <= 0 ? .red : nil)
                MetricRow(label: "Governing TEL",
                          value: String(format: "%.0f ft", friction.governingTotalEquivalentLength))
                MetricRow(label: "Friction Rate",
                          value: String(format: "%.3f in/100 ft", friction.frictionRatePer100Feet),
                          emphasis: true)
                Divider()
            }
            ForEach(engine.ductSizing) { run in
                if run.nominalDiameterInches > 0 {
                    MetricRow(label: run.name,
                              value: String(format: "%.0f in  @ %.0f CFM",
                                            run.nominalDiameterInches, run.designCFM),
                              emphasis: run.role == .supplyTrunk || run.role == .returnTrunk,
                              tint: run.velocityFPM > run.role.maximumVelocityFPM ? .orange : nil)
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
