import Foundation

/// Generates candidate equipment from a calculated load.
///
/// Model strings are produced from published naming conventions, which are mechanical:
/// residential outdoor units carry their nominal capacity as a three-digit code in
/// thousands of Btu/h. Nothing here invents certified performance. Capacities are nominal
/// — tonnage × 12,000 — and every result says so, because Manual S selects against the
/// manufacturer's expanded performance data at the design condition and no public source
/// carries it.
public enum EquipmentCatalog {

    /// Nominal capacity codes. 1 ton = 12,000 Btu/h.
    public static let nominalCodes: [(code: String, tons: Double)] = [
        ("018", 1.5), ("024", 2.0), ("030", 2.5), ("036", 3.0),
        ("042", 3.5), ("048", 4.0), ("060", 5.0)
    ]

    public enum Brand: String, Codable, Sendable, CaseIterable {
        case lennox = "Lennox"
        case americanStandard = "American Standard"

        /// Outdoor-unit series, most efficient first.
        ///
        /// Lennox carries the capacity in its dash group (`ML14XP1-036-230`). American
        /// Standard carries it at positions 6–8 (`4A6H4036G1000A`); the digit before it
        /// is the series tier. Both verified against manufacturer listings.
        func outdoorUnit(code: String, heatPump: Bool) -> [String] {
            switch self {
            case .lennox:
                let series = heatPump ? ["SL25XPV", "EL16XP1", "ML14XP1"]
                                      : ["SL28XCV", "EL16XC1", "ML14XC1"]
                return series.map { "\($0)-\(code)-230" }
            case .americanStandard:
                // 4A6H = heat pump, 4A7A = air conditioner; 5 and 4 are series tiers.
                let family = heatPump ? "4A6H" : "4A7A"
                return ["\(family)5\(code)H1000A", "\(family)4\(code)G1000A"]
            }
        }
    }

    /// One matched system.
    public struct Candidate: Sendable, Equatable {
        public let brand: Brand
        public let systemType: String
        public let outdoorUnit: String
        /// Null where the size code could not be verified. A fabricated coil number is
        /// worse than an absent one: it would be ordered.
        public let indoorCoil: String?
        public let furnaceOrAirHandler: String?
        public let nominalTons: Double
        public let totalCoolingBtu: Int
        public let sensibleCoolingBtu: Int
        public let latentCoolingBtu: Int
        public let estimatedSeer2: Double?
        public let capacityRatio: Double
    }

    public enum MatchStatus: String, Sendable {
        case passed = "PASSED", oversized = "OVERSIZED", undersized = "UNDERSIZED"
    }

    public struct Result: Sendable {
        public let status: MatchStatus
        public let targetTonnage: Double
        public let candidates: [Candidate]
        public let notes: [String]
    }

    /// Assumed equipment sensible heat ratio, used only to split a nominal capacity.
    /// Real coils vary from roughly 0.68 to 0.82 at the design condition.
    public static let assumedSensibleHeatRatio = 0.75

    public static func recommend(load: ProjectLoad,
                                 limits: SizingLimits = .standard,
                                 brands: [Brand] = [.lennox, .americanStandard],
                                 heatPump: Bool = true,
                                 sensibleHeatRatio: Double = assumedSensibleHeatRatio) -> Result {
        let totalLoad = load.coolingTotalBtuh
        guard totalLoad > 0 else {
            return Result(status: .undersized, targetTonnage: 0, candidates: [],
                          notes: ["No cooling load has been calculated."])
        }

        let heatingDominant = load.designConditions.isHeatingDominantClimate
        let type: EquipmentType = heatPump ? .heatPump : .airConditioner
        let ceiling = limits.coolingMaximum(for: type, heatingDominant: heatingDominant)
        let floor = limits.coolingMinimumFraction
        let targetTons = totalLoad / 12_000

        var candidates: [Candidate] = []
        var notes: [String] = [
            String(format: "Manual S window for a %@ in a %@ climate: %.0f–%.0f%% of the %.0f Btu/h total load.",
                   type.rawValue.lowercased(),
                   heatingDominant ? "heating-dominant" : "cooling-dominant",
                   floor * 100, ceiling * 100, totalLoad),
            "Capacities are nominal (tons × 12,000), not certified ratings. Select against the manufacturer's expanded performance data at the design condition before ordering.",
            "Indoor coil and air-handler size codes are not emitted: their encoding could not be verified, and a fabricated part number would be ordered."
        ]

        for (code, tons) in nominalCodes {
            let nominalTotal = tons * 12_000
            let ratio = nominalTotal / totalLoad
            guard ratio >= floor, ratio <= ceiling else { continue }

            let sensible = nominalTotal * sensibleHeatRatio
            let latent = nominalTotal - sensible
            // A nominal split that cannot cover the calculated split is reported rather
            // than silently offered, because sensible and latent must be met separately.
            if sensible < load.coolingSensibleBtuh {
                notes.append(String(format: "%.1f ton: nominal sensible %.0f Btu/h would not cover the %.0f Btu/h sensible load at an assumed SHR of %.2f.",
                                    tons, sensible, load.coolingSensibleBtuh, sensibleHeatRatio))
                continue
            }
            if latent < load.coolingLatentBtuh {
                notes.append(String(format: "%.1f ton: nominal latent %.0f Btu/h would not cover the %.0f Btu/h latent load at an assumed SHR of %.2f.",
                                    tons, latent, load.coolingLatentBtuh, sensibleHeatRatio))
                continue
            }

            for brand in brands {
                for model in brand.outdoorUnit(code: code, heatPump: heatPump) {
                    candidates.append(Candidate(
                        brand: brand,
                        systemType: heatPump ? "Heat Pump" : "Split System AC",
                        outdoorUnit: model,
                        indoorCoil: nil,
                        furnaceOrAirHandler: nil,
                        nominalTons: tons,
                        totalCoolingBtu: Int(nominalTotal.rounded()),
                        sensibleCoolingBtu: Int(sensible.rounded()),
                        latentCoolingBtu: Int(latent.rounded()),
                        estimatedSeer2: nil,
                        capacityRatio: ratio))
                }
            }
        }

        let status: MatchStatus
        if !candidates.isEmpty {
            status = .passed
        } else if targetTons * 12_000 * floor > nominalCodes.last!.tons * 12_000 {
            status = .undersized
            notes.append("No stock size reaches this load; a larger or multiple-system design is required.")
        } else if targetTons < nominalCodes.first!.tons * floor {
            status = .oversized
            notes.append(String(format: "The smallest stock size, %.1f ton, exceeds the %.0f%% ceiling on a %.0f Btu/h load. Consider a variable-capacity or ductless system.",
                                nominalCodes.first!.tons, ceiling * 100, totalLoad))
        } else {
            status = .oversized
            notes.append("No stock size falls inside the Manual S window; the nearest sizes are listed in the notes above.")
        }

        return Result(status: status, targetTonnage: (targetTons * 100).rounded() / 100,
                      candidates: candidates, notes: notes)
    }

    // MARK: JSON

    /// Rounds for JSON without the binary-float tail.
    ///
    /// `(x * 100).rounded() / 100` still serialises 0.73 as 0.72999999999999998, because
    /// 0.73 has no exact binary representation. A decimal carries the intended precision
    /// through serialisation, which matters when the value is read by another system.
    static func decimal(_ value: Double, places: Int = 2) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.\(places)f", value))
    }

    /// Emits the agreed schema, with `data_basis` added so a consumer cannot mistake a
    /// nominal figure for an AHRI rating.
    public static func json(_ result: Result, pretty: Bool = true) throws -> String {
        var recommendations: [[String: Any]] = []
        for candidate in result.candidates {
            recommendations.append([
                "brand": candidate.brand.rawValue,
                "system_type": candidate.systemType,
                "nominal_tons": decimal(candidate.nominalTons, places: 1),
                "capacity_percent_of_load": decimal(candidate.capacityRatio * 100, places: 1),
                "components": [
                    "outdoor_unit": candidate.outdoorUnit,
                    "indoor_coil": candidate.indoorCoil as Any? ?? NSNull(),
                    "furnace_or_air_handler": candidate.furnaceOrAirHandler as Any? ?? NSNull()
                ],
                "estimated_performance": [
                    "total_cooling_btu": candidate.totalCoolingBtu,
                    "sensible_cooling_btu": candidate.sensibleCoolingBtu,
                    "latent_cooling_btu": candidate.latentCoolingBtu,
                    "estimated_seer2": candidate.estimatedSeer2 as Any? ?? NSNull()
                ],
                "data_basis": "nominal_derived"
            ])
        }
        let payload: [String: Any] = [
            "load_match_status": result.status.rawValue,
            "target_tonnage": decimal(result.targetTonnage),
            "recommendations": recommendations,
            "notes": result.notes
        ]
        let options: JSONSerialization.WritingOptions = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        let data = try JSONSerialization.data(withJSONObject: payload, options: options)
        return String(decoding: data, as: UTF8.self)
    }
}
