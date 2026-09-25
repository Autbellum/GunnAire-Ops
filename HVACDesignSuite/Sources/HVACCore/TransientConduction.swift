import Foundation

/// Transient heat conduction through an envelope assembly.
///
/// This replaces the steady-state equivalent temperature difference, which had no notion
/// of mass: it treated a brick wall and a sheet of foam board as reaching peak load at the
/// same instant. They do not. A massive assembly both *delays* its peak by hours and
/// *damps* its amplitude, which is why a west brick wall peaks in the evening and why
/// sizing on the steady-state figure oversizes masonry construction.
///
/// ASHRAE's Radiant Time Series method handles this with tabulated conduction time
/// factors, one set per generic wall type. Those tables are licensed, they are limited to
/// the constructions they happen to list, and they are a *result* — they are derived from
/// the thermal properties of the layers. This solves the underlying heat equation directly
/// instead, so it needs no table and works for any assembly, including ones no table
/// covers.
///
///   ρc ∂T/∂t = ∂/∂x ( k ∂T/∂x )
///
/// Discretised across the layers and marched with backward Euler, which is
/// unconditionally stable, so the time step is chosen for accuracy rather than to dodge a
/// stability limit. The 24-hour cycle is repeated until the wall reaches periodic steady
/// state — the condition a design day actually describes.
public enum TransientConduction {

    /// Outside surface heat-transfer coefficient at summer wind speed, Btu/(h·ft²·°F).
    public static let outsideFilmCoefficient = 4.0
    /// Inside surface coefficient for a vertical surface, Btu/(h·ft²·°F).
    public static let insideFilmCoefficient = 1.46

    // MARK: - Design day

    /// Outdoor dry bulb through the design day, °F.
    ///
    /// A design condition gives a peak and a daily range, not a curve. The profile used
    /// here is a cosine minimum at 05:00 and maximum at 15:00 solar, which is the shape a
    /// clear summer day actually takes and is stated rather than tabulated. ASHRAE
    /// publishes a fraction-of-daily-range table for the same purpose; this is the same
    /// idea without the table.
    public static func outdoorTemperature(hour: Double, peakF: Double, dailyRangeF: Double) -> Double {
        let phase = (hour - 15) / 24 * 2 * Double.pi
        return peakF - dailyRangeF * (1 - cos(phase)) / 2
    }

    /// Sol-air temperature, °F.
    ///
    ///   t_e = t_o + α·E / h_o − ε·ΔR / h_o
    ///
    /// The last term is long-wave radiation to the sky, which cools a surface that can
    /// see it. It is taken as 7 °F equivalent for a horizontal surface and zero for a
    /// vertical one, the conventional treatment: a wall sees as much ground as sky.
    public static func solAirTemperature(outdoorF: Double, irradiance: Double,
                                         absorptance: Double, tilt: Double) -> Double {
        let skyCorrection = tilt < 45 ? 7.0 : 0.0
        return outdoorF + absorptance * irradiance / outsideFilmCoefficient - skyCorrection
    }

    // MARK: - Discretisation

    struct Node {
        var capacitance: Double     // Btu/(ft²·°F)
        var conductanceToNext: Double   // Btu/(h·ft²·°F)
    }

    /// Builds the node network for an assembly along its cavity path.
    ///
    /// Massless layers — air films, thin claddings quoted only as a resistance — carry no
    /// capacitance, so they are folded into the conductance between the masses they
    /// separate rather than given nodes of their own. That keeps the matrix small and
    /// avoids a zero-capacitance row, which would make it singular.
    static func nodes(for assembly: Assembly, nodesPerLayer: Int = 4) -> (nodes: [Node], outsideConductance: Double, insideConductance: Double) {
        var nodes: [Node] = []
        var pendingResistance = 0.0        // massless resistance not yet attached
        var outsideConductance = 0.0
        var haveFirstMass = false

        for layer in assembly.layers {
            let material = layer.material
            if layer.isMassive, let conductivity = layer.conductivity {
                let thicknessFeet = layer.massThicknessFeet
                let sliceFeet = thicknessFeet / Double(nodesPerLayer)
                let capacitance = material.volumetricHeatCapacity * sliceFeet
                let halfSliceResistance = sliceFeet / (2 * conductivity)

                for slice in 0..<nodesPerLayer {
                    if !haveFirstMass && slice == 0 {
                        // Everything massless outboard of the first mass becomes the
                        // outside boundary conductance.
                        outsideConductance = 1 / (pendingResistance + halfSliceResistance)
                        pendingResistance = 0
                        haveFirstMass = true
                    } else if slice == 0 {
                        // Bridge from the previous mass across any massless layers.
                        let previousHalf = nodes.last?.conductanceToNext ?? 0
                        _ = previousHalf
                        let resistance = pendingResistance + halfSliceResistance
                        nodes[nodes.count - 1].conductanceToNext =
                            1 / (1 / nodes[nodes.count - 1].conductanceToNext + resistance)
                        pendingResistance = 0
                    }
                    // Conductance to the next slice within this layer.
                    let toNext = slice < nodesPerLayer - 1 ? conductivity / sliceFeet : 1 / halfSliceResistance
                    nodes.append(Node(capacitance: capacitance, conductanceToNext: toNext))
                }
            } else {
                pendingResistance += layer.resistance
            }
        }

        // Everything massless inboard of the last mass becomes the inside boundary.
        let insideConductance: Double
        if let last = nodes.last, last.conductanceToNext > 0 {
            insideConductance = 1 / (1 / last.conductanceToNext + pendingResistance)
            nodes[nodes.count - 1].conductanceToNext = 0
        } else {
            insideConductance = pendingResistance > 0 ? 1 / pendingResistance : 0
        }
        return (nodes, outsideConductance, insideConductance)
    }

    // MARK: - Solve

    public struct Response: Sendable, Equatable {
        /// Conduction into the room for each hour of the design day, Btu/(h·ft²).
        public let hourlyFlux: [Double]
        /// Hour at which conduction peaks.
        public let peakHour: Int
        public let peakFlux: Double
        /// Peak the same assembly would show with no thermal mass at all.
        public let steadyStatePeakFlux: Double
        /// Hours by which mass delays the peak.
        public var lagHours: Int {
            let steadyPeak = 15
            var difference = peakHour - steadyPeak
            if difference < -12 { difference += 24 }
            if difference > 12 { difference -= 24 }
            return difference
        }
        /// Fraction of the massless peak that survives. Below 1 means mass is damping it.
        public var decrementFactor: Double {
            steadyStatePeakFlux != 0 ? peakFlux / steadyStatePeakFlux : 1
        }
    }

    /// Solves one assembly against a design day.
    ///
    /// - Parameters:
    ///   - solAir: 24 hourly sol-air temperatures, °F.
    ///   - roomF: indoor design temperature, °F.
    public static func solve(assembly: Assembly, solAir: [Double], roomF: Double,
                             stepsPerHour: Int = 4, maximumDays: Int = 30,
                             tolerance: Double = 1e-4) throws -> Response {
        try require(solAir.count == 24, "A design day needs 24 hourly sol-air temperatures.")
        try require(stepsPerHour >= 1, "At least one step per hour is required.")

        let network = nodes(for: assembly)
        // The solver marches the cavity path, so the massless reference it is measured
        // against must be the cavity path too. Comparing it with the framed average
        // inverts the decrement wherever the framing outperforms the cavity — an
        // uninsulated stud bay, for instance.
        let cavity = assembly.cavityPathResistance
        let uValue = cavity > 0 ? 1 / cavity : 0

        // A massless assembly has no state to march; its response is instantaneous.
        guard !network.nodes.isEmpty else {
            let flux = solAir.map { uValue * ($0 - roomF) }
            let peak = flux.enumerated().max { $0.element < $1.element }
            return Response(hourlyFlux: flux, peakHour: peak?.offset ?? 0,
                            peakFlux: peak?.element ?? 0,
                            steadyStatePeakFlux: peak?.element ?? 0)
        }

        let count = network.nodes.count
        let dt = 1.0 / Double(stepsPerHour)
        var temperature = [Double](repeating: roomF, count: count)

        var hourly = [Double](repeating: 0, count: 24)
        var previousHourly = hourly

        for day in 0..<maximumDays {
            var accumulator = [Double](repeating: 0, count: 24)
            for hour in 0..<24 {
                for step in 0..<stepsPerHour {
                    // Linear interpolation of the boundary within the hour.
                    let fraction = (Double(step) + 1) / Double(stepsPerHour)
                    let outside = solAir[hour] * (1 - fraction) + solAir[(hour + 1) % 24] * fraction
                    temperature = try march(temperature: temperature, network: network,
                                            outsideF: outside, roomF: roomF, dt: dt)
                    // Flux into the room from the innermost node.
                    let flux = network.insideConductance * (temperature[count - 1] - roomF)
                    accumulator[hour] += flux / Double(stepsPerHour)
                }
            }
            hourly = accumulator
            if day > 1 {
                let drift = zip(hourly, previousHourly).map { abs($0 - $1) }.max() ?? 0
                if drift < tolerance { break }
            }
            previousHourly = hourly
        }

        let peak = hourly.enumerated().max { $0.element < $1.element }
        let steadyPeak = (solAir.max() ?? roomF).isFinite
            ? uValue * ((solAir.max() ?? roomF) - roomF) : 0

        return Response(hourlyFlux: hourly,
                        peakHour: peak?.offset ?? 0,
                        peakFlux: peak?.element ?? 0,
                        steadyStatePeakFlux: steadyPeak)
    }

    /// One backward-Euler step, solved with the Thomas algorithm.
    ///
    /// Backward Euler rather than explicit marching: the stability limit on an explicit
    /// scheme through a thin gypsum slice would force a step measured in seconds, and
    /// thirty simulated days of that is wasted arithmetic for no accuracy gained.
    static func march(temperature: [Double],
                      network: (nodes: [Node], outsideConductance: Double, insideConductance: Double),
                      outsideF: Double, roomF: Double, dt: Double) throws -> [Double] {
        let nodes = network.nodes
        let count = nodes.count
        var a = [Double](repeating: 0, count: count)   // sub-diagonal
        var b = [Double](repeating: 0, count: count)   // diagonal
        var c = [Double](repeating: 0, count: count)   // super-diagonal
        var d = [Double](repeating: 0, count: count)   // right-hand side

        for index in 0..<count {
            let capacityRate = nodes[index].capacitance / dt
            let left = index == 0 ? network.outsideConductance : nodes[index - 1].conductanceToNext
            let right = index == count - 1 ? network.insideConductance : nodes[index].conductanceToNext

            b[index] = capacityRate + left + right
            d[index] = capacityRate * temperature[index]
            if index == 0 { d[index] += left * outsideF } else { a[index] = -left }
            if index == count - 1 { d[index] += right * roomF } else { c[index] = -right }
        }

        // Thomas algorithm. The matrix is diagonally dominant by construction — every
        // diagonal carries the capacity rate on top of the conductances — so no pivoting
        // is needed and the solve cannot divide by zero.
        for index in 1..<count {
            let factor = a[index] / b[index - 1]
            b[index] -= factor * c[index - 1]
            d[index] -= factor * d[index - 1]
        }
        var solution = [Double](repeating: 0, count: count)
        solution[count - 1] = d[count - 1] / b[count - 1]
        if count > 1 {
            for index in stride(from: count - 2, through: 0, by: -1) {
                solution[index] = (d[index] - c[index] * solution[index + 1]) / b[index]
            }
        }
        try require(solution.allSatisfy(\.isFinite), "The conduction solve did not converge to finite temperatures.")
        return solution
    }

    // MARK: - Design-day driver

    /// Hourly sol-air temperatures for a surface on the cooling design day.
    public static func solAirDay(conditions: DesignConditions, orientation: Orientation,
                                 absorptance: Double) -> [Double] {
        let day = Solar.representativeDay(month: conditions.coolingDesignMonth)
        return (0..<24).map { hour in
            let sun = Solar.position(latitude: conditions.latitude, dayOfYear: day,
                                     solarHour: Double(hour))
            let sky = Solar.clearSky(position: sun, dayOfYear: day,
                                     altitudeFeet: conditions.altitudeFeet,
                                     atmosphere: .humidSummer)
            let irradiance = Solar.irradiance(on: orientation.azimuth, tilt: orientation.tilt,
                                              position: sun, clearSky: sky)
            let outdoor = outdoorTemperature(hour: Double(hour),
                                             peakF: conditions.summerOutdoorDryBulbF,
                                             dailyRangeF: conditions.summerDailyRangeF)
            return solAirTemperature(outdoorF: outdoor, irradiance: irradiance,
                                     absorptance: absorptance, tilt: orientation.tilt)
        }
    }
}
