import Foundation

/// The printable design report.
///
/// Structured rather than pre-formatted, so the same content can render to a PDF, a
/// printer, or a future web view without the layout code and the engineering content
/// drifting apart. Built as pure data, which also makes it testable without a UI.
///
/// The content mirrors what a Manual J worksheet is expected to show a reviewer: the
/// design conditions and where they came from, the load broken down by room and by
/// component, the equipment tested against it, the airflow allocation and the duct
/// schedule — plus an explicit statement of what this tool does and does not model.
public struct DesignReport: Sendable, Equatable {

    public struct Row: Sendable, Equatable {
        public let label: String
        public let value: String
        public let emphasis: Bool
        public init(_ label: String, _ value: String, emphasis: Bool = false) {
            self.label = label; self.value = value; self.emphasis = emphasis
        }
    }

    public struct Table: Sendable, Equatable {
        public let title: String
        public let columns: [String]
        public let rows: [[String]]
        public let note: String?
        public init(title: String, columns: [String], rows: [[String]], note: String? = nil) {
            self.title = title; self.columns = columns; self.rows = rows; self.note = note
        }
    }

    public struct Section: Sendable, Equatable {
        public let title: String
        public let rows: [Row]
        public let tables: [Table]
        public let notes: [String]
        public init(title: String, rows: [Row] = [], tables: [Table] = [], notes: [String] = []) {
            self.title = title; self.rows = rows; self.tables = tables; self.notes = notes
        }
    }

    public let projectName: String
    public let preparedOn: Date
    public let procedure: LoadProcedure
    public let sections: [Section]
    /// Printed at the foot of every page. A reviewer is entitled to know the basis.
    public let footnotes: [String]
}

public enum ReportBuilder {

    public static func build(project: Project,
                             load: ProjectLoad,
                             selection: SelectionResult?,
                             airflows: [ZoneAirflow],
                             friction: FrictionRateResult?,
                             ducts: [DuctSizingResult],
                             profile: CoolingProfile? = nil,
                             preparedOn: Date = Date()) -> DesignReport {

        var sections: [DesignReport.Section] = []
        let conditions = project.designConditions

        // MARK: Design conditions
        sections.append(.init(title: "Design Conditions", rows: [
            .init("Location", conditions.siteName),
            .init("Elevation", string(conditions.altitudeFeet, "ft")),
            .init("Latitude", String(format: "%.2f° N", conditions.latitude)),
            .init("Winter outdoor, 99.6%", string(conditions.winterOutdoorDryBulbF, "°F")),
            .init("Summer outdoor, 0.4% DB", string(conditions.summerOutdoorDryBulbF, "°F")),
            .init("Summer mean coincident WB", string(conditions.summerOutdoorWetBulbF, "°F")),
            .init("Summer daily range", "\(string(conditions.summerDailyRangeF, "°F")) — \(conditions.dailyRangeClass)"),
            .init("Indoor winter / summer",
                  "\(string(conditions.indoorWinterDryBulbF, "°F")) / \(string(conditions.indoorSummerDryBulbF, "°F")) at \(string(conditions.indoorSummerRelativeHumidityPercent, "% RH"))"),
            .init("Heating ΔT", string(conditions.heatingDeltaT, "°F"), emphasis: true),
            .init("Cooling ΔT", string(conditions.coolingDeltaT, "°F"), emphasis: true),
            .init("Climate", conditions.isHeatingDominantClimate ? "Heating dominant" : "Cooling dominant")
        ], notes: [conditions.weatherSource]))

        // MARK: Load summary
        sections.append(.init(title: "Load Summary — \(load.procedure.rawValue)", rows: [
            .init("Cooling sensible", btuh(load.coolingSensibleBtuh)),
            .init("Cooling latent", btuh(load.coolingLatentBtuh)),
            .init("Cooling total", btuh(load.coolingTotalBtuh), emphasis: true),
            .init("Cooling total", String(format: "%.2f tons", load.coolingTons)),
            .init("Load sensible heat ratio", load.sensibleHeatRatio.map { String(format: "%.2f", $0) } ?? "—"),
            .init("Heating total", btuh(load.heatingBtuh), emphasis: true)
        ], tables: [
            .init(title: "Room by Room",
                  columns: ["Room", "Area ft²", "Cooling Sens.", "Cooling Lat.", "Heating", "Design CFM"],
                  rows: load.zoneLoads.map { zone in
                      let area = project.zones.first { $0.id == zone.zoneID }?.floorAreaSquareFeet ?? 0
                      let cfm = airflows.first { $0.zoneID == zone.zoneID }?.designCFM ?? 0
                      return [zone.zoneName,
                              String(format: "%.0f", area),
                              btuh(zone.coolingSensibleBtuh),
                              btuh(zone.coolingLatentBtuh),
                              btuh(zone.heatingBtuh),
                              String(format: "%.0f", cfm)]
                  })
        ]))

        // MARK: Design day
        if let profile, profile.peakSensible > 0 {
            sections.append(.init(title: "Design Day — Coincident Peak", rows: [
                .init("Peak sensible load", btuh(profile.peakSensible), emphasis: true),
                .init("Occurs at", String(format: "%02d:00 solar", profile.peakHour), emphasis: true),
                .init("Sum of individual surface peaks", btuh(profile.sumOfIndividualPeaks)),
                .init("Diversity", String(format: "%.0f%%", profile.diversityFactor * 100))
            ], tables: [
                .init(title: "Hourly Sensible Load",
                      columns: ["Hour", "Btu/h", "Hour", "Btu/h"],
                      rows: (0..<12).map { hour in
                          [String(format: "%02d:00", hour), integer(profile.hourlySensible[hour]),
                           String(format: "%02d:00", hour + 12), integer(profile.hourlySensible[hour + 12])]
                      },
                      note: "Opaque assemblies are solved transiently across the design day, so each carries the lag and damping its own mass produces. Surfaces do not peak together; the coincident figure is the largest the sum ever reaches.")
            ]))
        }

        // MARK: Envelope
        var envelopeRows: [[String]] = []
        for zone in project.zones {
            for surface in zone.surfaces where surface.isValid {
                envelopeRows.append([
                    zone.name, surface.name, surface.category.rawValue,
                    String(format: "%.0f", surface.areaSquareFeet),
                    surface.orientation.rawValue,
                    String(format: "%.3f", surface.uValue),
                    surface.construction.name
                ])
            }
        }
        sections.append(.init(title: "Envelope", tables: [
            .init(title: "Surfaces",
                  columns: ["Room", "Surface", "Type", "Area ft²", "Facing", "U", "Construction"],
                  rows: envelopeRows,
                  note: "U-values are computed from assembly layers by the parallel-path method, not read from a table.")
        ]))

        // MARK: Equipment
        if let selection {
            var rows: [DesignReport.Row] = [
                .init("Manufacturer / model",
                      [project.equipment.manufacturer, project.equipment.modelNumber]
                        .filter { !$0.isEmpty }.joined(separator: " ")),
                .init("Type", project.equipment.type.rawValue),
                .init("Total cooling capacity", btuh(project.equipment.totalCoolingCapacityBtuh)),
                .init("Sensible cooling capacity", btuh(project.equipment.sensibleCoolingCapacityBtuh)),
                .init("Latent cooling capacity", btuh(project.equipment.latentCoolingCapacityBtuh)),
                .init("Heating capacity", btuh(project.equipment.heatingCapacityBtuh)),
                .init("Required airflow", String(format: "%.0f CFM", selection.requiredAirflowCFM), emphasis: true)
            ]
            if let ratio = selection.totalCapacityRatio {
                rows.append(.init("Capacity as % of load", String(format: "%.0f%%", ratio * 100), emphasis: true))
            }
            sections.append(.init(title: "Equipment Selection — Manual S", rows: rows, tables: [
                .init(title: "Acceptance Checks",
                      columns: ["Check", "Result", "Basis"],
                      rows: selection.checks.map { [$0.name, $0.status.rawValue, $0.detail] })
            ]))
        }

        // MARK: Air distribution
        if !airflows.isEmpty {
            sections.append(.init(title: "Air Distribution — Manual T", tables: [
                .init(title: "Room Airflow",
                      columns: ["Room", "Cooling CFM", "Heating CFM", "Design CFM", "Share"],
                      rows: airflows.map {
                          [$0.zoneName,
                           String(format: "%.0f", $0.coolingCFM),
                           String(format: "%.0f", $0.heatingCFM),
                           String(format: "%.0f", $0.designCFM),
                           String(format: "%.0f%%", $0.sensibleLoadFraction * 100)]
                      },
                      note: "Room CFM = System CFM × (Room Sensible ÷ Total Sensible). The duct is sized on the governing season.")
            ]))
        }

        // MARK: Ducts
        if let friction {
            let sized = ducts.filter { $0.nominalDiameterInches > 0 }
            sections.append(.init(title: "Duct Design — Manual D", rows: [
                .init("Blower external static", String(format: "%.2f in. w.g.", friction.blowerExternalStaticPressure)),
                .init("Component losses", String(format: "− %.2f in. w.g.", friction.componentLosses)),
                .init("Available static pressure", String(format: "%.3f in. w.g.", friction.availableStaticPressure), emphasis: true),
                .init("Governing total equivalent length", String(format: "%.0f ft", friction.governingTotalEquivalentLength)),
                .init("Friction rate", String(format: "%.3f in. w.g. per 100 ft", friction.frictionRatePer100Feet), emphasis: true)
            ], tables: [
                .init(title: "Duct Schedule",
                      columns: ["Run", "Role", "CFM", "TEL ft", "Round in", "Velocity FPM", "Rectangular"],
                      rows: sized.map { run in
                          [run.name, run.role.rawValue,
                           String(format: "%.0f", run.designCFM),
                           String(format: "%.0f", run.totalEquivalentLengthFeet),
                           String(format: "%.0f", run.nominalDiameterInches),
                           String(format: "%.0f", run.velocityFPM),
                           run.rectangularOptions.first.map { String(format: "%.0f × %.0f", $0.height, $0.width) } ?? "—"]
                      },
                      note: "FR = ASP × 100 ÷ TEL. Diameters solve Colebrook–White at that friction rate, then step up where the velocity limit governs.")
            ]))
        }

        // MARK: Anything the engineer should look at
        var review = load.warnings + (friction?.warnings ?? []) + ducts.flatMap(\.warnings)
        if let selection {
            review += selection.checks.filter { $0.status != .pass }.map { "\($0.name): \($0.detail)" }
        }
        if !review.isEmpty {
            sections.append(.init(title: "Review", notes: review))
        }

        return DesignReport(
            projectName: project.name,
            preparedOn: preparedOn,
            procedure: project.procedure,
            sections: sections,
            footnotes: [
                "Design conditions derived from NOAA Integrated Surface Database observations; not ASHRAE published design conditions.",
                "Envelope U-values computed from assembly layers by the parallel-path method. Glazing values are typical for the construction unless an NFRC label was entered.",
                "Solar gain uses computed solar position and the Bird & Hulstrom clear-sky model. Thermal mass and lag are not modelled, so sunlit opaque assemblies are a steady-state upper bound.",
                "This report is not ACCA-approved software output. Confirm against the current editions of Manual J, S, T and D before submittal."
            ])
    }

    // MARK: Formatting

    static func btuh(_ value: Double) -> String {
        String(format: "%@ Btu/h", integer(value))
    }
    static func string(_ value: Double, _ unit: String) -> String {
        "\(integer(value)) \(unit)"
    }
    static func integer(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value < 10 && value != value.rounded() ? 1 : 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }
}
