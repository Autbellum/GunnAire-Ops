import Foundation

// MARK: - Module 3a: Manual T air distribution

/// The airflow allocated to one zone.
public struct ZoneAirflow: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let zoneID: UUID
    public let zoneName: String
    public let coolingCFM: Double
    public let heatingCFM: Double
    /// The governing airflow — the larger of the two, since one duct serves both seasons.
    public let designCFM: Double
    public let sensibleLoadFraction: Double
}

/// Module 3a — Manual T.
///
/// Each room receives system airflow in proportion to its share of the sensible load:
///
///   Room CFM = Total System CFM · (Room Sensible Load / Total Sensible Load)
///
/// Heating is allocated on the same principle against the heating load, and the duct is
/// sized on whichever season demands more air. Sizing on cooling alone is the usual way a
/// north-facing room ends up cold in January.
public enum AirDistributionCalculator {

    public static func allocate(load: ProjectLoad, systemCoolingCFM: Double,
                                systemHeatingCFM: Double) -> [ZoneAirflow] {
        let totalSensible = load.coolingSensibleBtuh
        let totalHeating = load.heatingBtuh

        return load.zoneLoads.map { zone in
            let coolingFraction = totalSensible > 0 ? zone.coolingSensibleBtuh / totalSensible : 0
            let heatingFraction = totalHeating > 0 ? zone.heatingBtuh / totalHeating : 0
            let cooling = systemCoolingCFM * coolingFraction
            let heating = systemHeatingCFM * heatingFraction
            return ZoneAirflow(id: UUID(), zoneID: zone.zoneID, zoneName: zone.zoneName,
                               coolingCFM: cooling, heatingCFM: heating,
                               designCFM: max(cooling, heating),
                               sensibleLoadFraction: coolingFraction)
        }
    }
}

// MARK: - Module 3b: Manual D duct design

/// A sized duct run.
public struct DuctSizingResult: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let runID: UUID
    public let name: String
    public let role: DuctRole
    public let designCFM: Double
    public let totalEquivalentLengthFeet: Double
    /// Required round diameter, in.
    public let roundDiameterInches: Double
    /// Next larger commercially available round size, in.
    public let nominalDiameterInches: Double
    public let velocityFPM: Double
    public let actualFrictionRate: Double
    /// Rectangular equivalents at common heights, as (height, width) in inches.
    public let rectangularOptions: [(height: Double, width: Double)]
    public let warnings: [String]

    public static func == (lhs: DuctSizingResult, rhs: DuctSizingResult) -> Bool {
        lhs.id == rhs.id && lhs.nominalDiameterInches == rhs.nominalDiameterInches
    }
}

/// The friction-rate budget for the whole system.
public struct FrictionRateResult: Sendable, Equatable {
    public let blowerExternalStaticPressure: Double
    public let componentLosses: Double
    public let availableStaticPressure: Double
    /// Total equivalent length of the governing run — the longest supply plus the
    /// longest return. Manual D sizes the system on this path, not on an average.
    public let governingTotalEquivalentLength: Double
    public let frictionRatePer100Feet: Double
    public let warnings: [String]
}

/// Module 3b — Manual D.
///
/// Sizing proceeds in three steps. Available static pressure is what remains of blower
/// external static after the coil, filter, registers, grilles and dampers take their
/// share. The friction rate spreads that remainder over the total equivalent length of
/// the governing path. Each run is then sized to carry its airflow at that friction rate.
public enum DuctDesigner {

    /// Kinematic viscosity of standard air at 70 °F, ft²/s.
    public static let kinematicViscosity = 1.57e-4

    /// Commercially available round duct diameters, in.
    public static let nominalRoundSizes: [Double] = [4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 36]

    /// Common rectangular duct heights offered as equivalents, in.
    public static let rectangularHeights: [Double] = [6, 8, 10, 12, 14, 16, 18, 20]

    // MARK: Friction rate

    /// Available static pressure and the friction rate it supports.
    ///
    ///   ASP = blower external static pressure − component losses
    ///   FR  = ASP · 100 / TEL
    public static func frictionRate(equipment: EquipmentSpec,
                                    budget: StaticPressureBudget,
                                    runs: [DuctRun]) -> FrictionRateResult {
        var warnings: [String] = []
        let available = equipment.blowerExternalStaticPressure - budget.total
        if available <= 0 {
            warnings.append(String(format: "Component losses of %.2f in. w.g. equal or exceed the blower's %.2f in. w.g. external static. No pressure is left to move air through any duct.",
                                   budget.total, equipment.blowerExternalStaticPressure))
        }

        // The governing path is the longest supply run plus the longest return run.
        let longestSupply = runs
            .filter { $0.role == .supplyTrunk || $0.role == .supplyBranch }
            .map(\.totalEquivalentLengthFeet).max() ?? 0
        let longestReturn = runs
            .filter { $0.role == .returnTrunk || $0.role == .returnBranch }
            .map(\.totalEquivalentLengthFeet).max() ?? 0
        let governing = longestSupply + longestReturn

        guard governing > 0 else {
            warnings.append("No duct runs have been entered, so there is no equivalent length to spread the available pressure over.")
            return FrictionRateResult(blowerExternalStaticPressure: equipment.blowerExternalStaticPressure,
                                      componentLosses: budget.total,
                                      availableStaticPressure: available,
                                      governingTotalEquivalentLength: 0,
                                      frictionRatePer100Feet: 0, warnings: warnings)
        }

        let rate = max(0, available) * 100 / governing
        if rate > 0 && rate < 0.06 {
            warnings.append(String(format: "A friction rate of %.3f in. w.g. per 100 ft is very low. Ducts sized at this rate become large and expensive; consider shortening the governing run or reducing component losses.", rate))
        }
        if rate > 0.18 {
            warnings.append(String(format: "A friction rate of %.3f in. w.g. per 100 ft is high. Ducts will be small and velocities may be audible.", rate))
        }

        return FrictionRateResult(blowerExternalStaticPressure: equipment.blowerExternalStaticPressure,
                                  componentLosses: budget.total,
                                  availableStaticPressure: available,
                                  governingTotalEquivalentLength: governing,
                                  frictionRatePer100Feet: rate, warnings: warnings)
    }

    // MARK: Duct friction physics

    /// Darcy friction factor from the Colebrook–White relation.
    ///
    ///   1/√f = −2·log₁₀( ε/(3.7·D) + 2.51/(Re·√f) )
    ///
    /// Solved by fixed-point iteration from the Swamee–Jain explicit estimate. Colebrook
    /// is used rather than a duct-chart curve fit so the result stays correct for flexible
    /// duct, whose roughness is far outside the range the charts were drawn for.
    public static func frictionFactor(reynolds: Double, relativeRoughness: Double) -> Double {
        guard reynolds > 2_300 else {
            // Laminar. Design duct flow is never here, but the branch keeps the solver
            // well behaved at very low airflow.
            return max(64 / max(reynolds, 1), 1e-6)
        }
        // Swamee–Jain starting estimate.
        var f = 0.25 / pow(log10(relativeRoughness / 3.7 + 5.74 / pow(reynolds, 0.9)), 2)
        for _ in 0..<40 {
            let root = sqrt(f)
            let right = -2 * log10(relativeRoughness / 3.7 + 2.51 / (reynolds * root))
            let updated = 1 / (right * right)
            if abs(updated - f) < 1e-10 { f = updated; break }
            f = updated
        }
        return f
    }

    /// Friction loss for a round duct, in. w.g. per 100 ft.
    ///
    ///   V  = Q / A,  A = πD²/4
    ///   Pv = (V/4005)²                    velocity pressure, in. w.g.
    ///   Δp = f · (100/D) · Pv             Darcy–Weisbach over 100 ft
    public static func frictionRate(cfm: Double, diameterInches: Double,
                                    roughnessFeet: Double) throws -> Double {
        guard cfm > 0 else { return 0 }
        guard diameterInches > 0 else {
            throw HVACError.invalidGeometry("Duct diameter must be positive.")
        }
        let diameterFeet = diameterInches / 12
        let area = Double.pi * diameterFeet * diameterFeet / 4
        let velocityFPM = cfm / area
        let velocityPressure = pow(velocityFPM / 4005, 2)
        let reynolds = (velocityFPM / 60) * diameterFeet / kinematicViscosity
        let f = frictionFactor(reynolds: reynolds, relativeRoughness: roughnessFeet / diameterFeet)
        return f * (100 / diameterFeet) * velocityPressure
    }

    /// The round diameter that carries `cfm` at `targetFrictionRate`, in.
    ///
    /// Friction rate falls monotonically as diameter grows, so bisection converges
    /// reliably and without the error band a slide-rule approximation carries.
    public static func diameter(cfm: Double, targetFrictionRate: Double,
                                roughnessFeet: Double) throws -> Double {
        guard cfm > 0 else { return 0 }
        guard targetFrictionRate > 0 else {
            throw HVACError.unsolvable("The friction rate is zero or negative, so no duct size can satisfy it. Check blower static pressure against the component losses.")
        }
        var low = 1.0, high = 60.0
        guard try frictionRate(cfm: cfm, diameterInches: high, roughnessFeet: roughnessFeet) <= targetFrictionRate else {
            throw HVACError.unsolvable(String(format: "Even a 60 in. duct cannot carry %.0f CFM at %.3f in. w.g. per 100 ft.", cfm, targetFrictionRate))
        }
        for _ in 0..<100 {
            let middle = (low + high) / 2
            let rate = try frictionRate(cfm: cfm, diameterInches: middle, roughnessFeet: roughnessFeet)
            if rate > targetFrictionRate { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    /// Equivalent round diameter of a rectangular duct, in.
    ///
    /// Huebscher's relation, the standard ASHRAE equivalence:
    ///   Dₑ = 1.30 · (a·b)^0.625 / (a+b)^0.25
    public static func equivalentDiameter(height: Double, width: Double) throws -> Double {
        guard height > 0, width > 0 else {
            throw HVACError.invalidGeometry("Rectangular duct dimensions must be positive.")
        }
        return 1.30 * pow(height * width, 0.625) / pow(height + width, 0.25)
    }

    /// Rectangular duct widths matching a required equivalent diameter, at common heights.
    ///
    /// Aspect ratios beyond about 4:1 are dropped: they cost more metal, lose more heat
    /// and carry more friction than the equivalence alone suggests.
    public static func rectangularOptions(equivalentTo diameterInches: Double,
                                          maximumAspectRatio: Double = 4) -> [(height: Double, width: Double)] {
        var options: [(height: Double, width: Double)] = []
        for height in rectangularHeights {
            // A height whose square already exceeds the required equivalent diameter
            // cannot be part of a solution: the width would have to fall below the
            // height, which is the same duct turned on its side. Skipping it keeps the
            // bisection from clamping at width == height and returning an oversized run.
            guard let square = try? equivalentDiameter(height: height, width: height),
                  square <= diameterInches else { continue }
            var low = height, high = 120.0
            for _ in 0..<60 {
                let middle = (low + high) / 2
                guard let equivalent = try? equivalentDiameter(height: height, width: middle) else { break }
                if equivalent < diameterInches { low = middle } else { high = middle }
            }
            let width = ((low + high) / 2 / 2).rounded(.up) * 2   // even inches
            if width / height <= maximumAspectRatio && width >= height {
                options.append((height, width))
            }
        }
        return options
    }

    // MARK: Sizing

    public static func size(runs: [DuctRun],
                            airflows: [ZoneAirflow],
                            systemCFM: Double,
                            frictionRate rate: Double) -> [DuctSizingResult] {
        runs.map { run in
            var warnings: [String] = []

            // A branch carries its zone's airflow; a trunk carries the whole system.
            let cfm: Double
            if let zoneID = run.servingZoneID, let airflow = airflows.first(where: { $0.zoneID == zoneID }) {
                cfm = airflow.designCFM
            } else if run.role == .supplyTrunk || run.role == .returnTrunk {
                cfm = systemCFM
            } else {
                cfm = 0
                warnings.append("This branch is not assigned to a zone, so it has no airflow to carry.")
            }

            var diameter = 0.0
            var nominal = 0.0
            var velocity = 0.0
            var actual = 0.0
            var options: [(height: Double, width: Double)] = []

            if cfm > 0 && rate > 0 {
                do {
                    diameter = try self.diameter(cfm: cfm, targetFrictionRate: rate,
                                                 roughnessFeet: run.roughnessFeet)
                    nominal = nominalRoundSizes.first { $0 >= diameter } ?? diameter.rounded(.up)
                    let area = Double.pi * pow(nominal / 12, 2) / 4
                    velocity = cfm / area
                    actual = (try? frictionRate(cfm: cfm, diameterInches: nominal,
                                                roughnessFeet: run.roughnessFeet)) ?? 0
                    options = rectangularOptions(equivalentTo: nominal)

                    if velocity > run.role.maximumVelocityFPM {
                        warnings.append(String(format: "%.0f FPM exceeds the %.0f FPM guideline for a %@; this run will be audible.",
                                               velocity, run.role.maximumVelocityFPM, run.role.rawValue.lowercased()))
                    }
                } catch {
                    warnings.append(error.localizedDescription)
                }
            } else if rate <= 0 {
                warnings.append("No friction rate is available, so this run cannot be sized.")
            }

            return DuctSizingResult(id: UUID(), runID: run.id, name: run.name, role: run.role,
                                    designCFM: cfm,
                                    totalEquivalentLengthFeet: run.totalEquivalentLengthFeet,
                                    roundDiameterInches: diameter,
                                    nominalDiameterInches: nominal,
                                    velocityFPM: velocity,
                                    actualFrictionRate: actual,
                                    rectangularOptions: options,
                                    warnings: warnings)
        }
    }
}
