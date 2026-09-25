import Foundation
import Observation

/// The reactive calculation engine.
///
/// One mutation of `project` re-runs the whole cascade:
///
///   Manual J/N  →  Manual S  →  Manual T  →  Manual D
///   loads          equipment     room CFM    duct sizes
///
/// Each stage consumes the stage above it, so changing a window's R-value moves the
/// zone's sensible load, which moves the total load, which re-tests the equipment
/// against Manual S, which changes system airflow, which re-allocates every room's CFM,
/// which resizes every duct run. There is no partial-update path and no cache to
/// invalidate — the chain is cheap enough to run whole, and running it whole is what
/// makes it impossible for the dashboard to show a duct size computed from a load that
/// no longer exists.
///
/// The work is pure arithmetic over a handful of zones and runs, measured in tens of
/// microseconds, so it runs inline on the main actor. A project large enough to be felt —
/// hundreds of zones, or the radiant-time-series engine once it lands with its 8,760-hour
/// convolution — should move `recalculate()` into a background task and publish the
/// result back, which is why the results are `private(set)` behind a single assignment.
@Observable
@MainActor
public final class DesignEngine {

    /// The single source of truth. Everything below is derived from it.
    public var project: Project {
        didSet { recalculate() }
    }

    // MARK: Derived state

    public private(set) var load: ProjectLoad?
    public private(set) var selection: SelectionResult?
    public private(set) var zoneAirflows: [ZoneAirflow] = []
    public private(set) var frictionRate: FrictionRateResult?
    public private(set) var ductSizing: [DuctSizingResult] = []
    /// The design-day hourly profile, which carries the coincident peak and its hour.
    public private(set) var coolingProfile: CoolingProfile?

    /// Set when a stage threw rather than merely disagreeing with the design.
    public private(set) var calculationError: String?
    public private(set) var lastCalculated: Date?

    public init(project: Project = .sample) {
        self.project = project
        recalculate()
    }

    // MARK: The cascade

    public func recalculate() {
        calculationError = nil
        do {
            // Stage 1 — Manual J / Manual N.
            let load = try LoadCalculator.calculate(project: project)
            self.load = load
            coolingProfile = try LoadCalculator.coolingProfile(project: project)

            // Stage 2 — Manual S.
            let selection = try EquipmentSelector.evaluate(
                load: load,
                equipment: project.equipment,
                limits: project.sizingLimits,
                supplyAirDeltaTF: project.supplyAirDeltaTF,
                altitudeFeet: project.designConditions.altitudeFeet)
            self.selection = selection

            // System airflow. The sensible load sets what the air must carry; the blower
            // caps what it can. Sizing ducts for more air than the blower moves produces
            // a drawing that cannot be built to.
            let coefficient = try Psychrometrics.sensibleCoefficient(
                altitudeFeet: project.designConditions.altitudeFeet)
            var coolingCFM = selection.requiredAirflowCFM
            if project.equipment.maximumAirflowCFM > 0 {
                coolingCFM = min(coolingCFM, project.equipment.maximumAirflowCFM)
            }
            let heatingCFM = project.supplyAirDeltaTF > 0
                ? load.heatingBtuh / (coefficient * project.supplyAirDeltaTF)
                : 0

            // Stage 3 — Manual T.
            zoneAirflows = AirDistributionCalculator.allocate(
                load: load, systemCoolingCFM: coolingCFM, systemHeatingCFM: heatingCFM)

            // Stage 4 — Manual D.
            let friction = DuctDesigner.frictionRate(
                equipment: project.equipment,
                budget: project.staticPressureBudget,
                runs: project.ductRuns)
            frictionRate = friction

            ductSizing = DuctDesigner.size(
                runs: project.ductRuns,
                airflows: zoneAirflows,
                systemCFM: max(coolingCFM, heatingCFM),
                frictionRate: friction.frictionRatePer100Feet)

            lastCalculated = Date()
        } catch {
            calculationError = error.localizedDescription
            load = nil; selection = nil; coolingProfile = nil
            zoneAirflows = []; frictionRate = nil; ductSizing = []
        }
    }

    // MARK: Convenience for the dashboard

    public var systemCoolingCFM: Double { zoneAirflows.reduce(0) { $0 + $1.coolingCFM } }
    public var systemHeatingCFM: Double { zoneAirflows.reduce(0) { $0 + $1.heatingCFM } }

    /// Everything the design wants the engineer to look at, in one list.
    public var allWarnings: [String] {
        var warnings = load?.warnings ?? []
        warnings += frictionRate?.warnings ?? []
        warnings += ductSizing.flatMap(\.warnings)
        if let error = calculationError { warnings.insert(error, at: 0) }
        return warnings
    }

    // MARK: Mutations

    public func addZone() {
        project.zones.append(Zone(name: "Zone \(project.zones.count + 1)", floorAreaSquareFeet: 200))
    }

    public func removeZones(at offsets: IndexSet) {
        let removed = offsets.compactMap { project.zones.indices.contains($0) ? project.zones[$0].id : nil }
        // Removing high indices first keeps the lower ones valid. The core deliberately
        // does not import SwiftUI, so `remove(atOffsets:)` is not available here.
        for index in offsets.sorted(by: >) where project.zones.indices.contains(index) {
            project.zones.remove(at: index)
        }
        // A duct run pointing at a deleted zone would silently size itself to nothing.
        for index in project.ductRuns.indices {
            if let serving = project.ductRuns[index].servingZoneID, removed.contains(serving) {
                project.ductRuns[index].servingZoneID = nil
            }
        }
    }

    public func addSurface(to zoneID: UUID) {
        guard let index = project.zones.firstIndex(where: { $0.id == zoneID }) else { return }
        let wall = AssemblyLibrary.assemblies(for: .wall).first
        project.zones[index].surfaces.append(
            Surface(name: "New Surface", category: .wall, areaSquareFeet: 100,
                    construction: wall.map { .assembly($0) } ?? .manual(rValue: 13, shgc: 0)))
    }

    public func addDuctRun() {
        project.ductRuns.append(
            DuctRun(name: "Run \(project.ductRuns.count + 1)", role: .supplyBranch,
                    physicalLengthFeet: 25))
    }

    public func removeDuctRuns(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where project.ductRuns.indices.contains(index) {
            project.ductRuns.remove(at: index)
        }
    }
}

// MARK: - Sample project

public extension Project {
    /// A small Piedmont Triad house, so the interface opens with something calculable.
    static var sample: Project {
        let sampleWall = AssemblyLibrary.named("2×6 wall, R-21 batt, vinyl siding")
            ?? AssemblyLibrary.standard[0]
        let sampleCeiling = AssemblyLibrary.named("Vented attic, R-38 blown cellulose")
            ?? AssemblyLibrary.standard[0]

        let living = Zone(
            name: "Living Room",
            floorAreaSquareFeet: 320, ceilingHeightFeet: 9,
            surfaces: [
                Surface(name: "South Wall", category: .wall, areaSquareFeet: 180,
                        construction: .assembly(sampleWall), orientation: .south),
                Surface(name: "West Wall", category: .wall, areaSquareFeet: 144,
                        construction: .assembly(sampleWall), orientation: .west),
                Surface(name: "Ceiling", category: .roof, areaSquareFeet: 320,
                        construction: .assembly(sampleCeiling),
                        orientation: .horizontal, coolingEquivalentDeltaTF: 32),
                Surface(name: "South Windows", category: .window, areaSquareFeet: 45,
                        construction: .glazing(.doublePaneLowEArgon, .interiorBlindsLight),
                        orientation: .south),
                Surface(name: "West Windows", category: .window, areaSquareFeet: 24,
                        construction: .glazing(.doublePaneLowEArgon, .interiorBlindsLight),
                        orientation: .west)
            ],
            internalGains: InternalGains(occupantCount: 3, sensiblePerOccupant: 230,
                                         latentPerOccupant: 200,
                                         lightingWattsPerSquareFoot: 0,
                                         applianceSensibleBtuh: 0, applianceLatentBtuh: 0),
            airExchange: .average)

        let bedroom = Zone(
            name: "Primary Bedroom",
            floorAreaSquareFeet: 220, ceilingHeightFeet: 9,
            surfaces: [
                Surface(name: "North Wall", category: .wall, areaSquareFeet: 150,
                        construction: .assembly(sampleWall), orientation: .north),
                Surface(name: "East Wall", category: .wall, areaSquareFeet: 126,
                        construction: .assembly(sampleWall), orientation: .east),
                Surface(name: "Ceiling", category: .roof, areaSquareFeet: 220,
                        construction: .assembly(sampleCeiling),
                        orientation: .horizontal, coolingEquivalentDeltaTF: 32),
                Surface(name: "East Windows", category: .window, areaSquareFeet: 20,
                        construction: .glazing(.doublePaneLowEArgon, .interiorBlindsLight),
                        orientation: .east)
            ],
            internalGains: InternalGains(occupantCount: 2, sensiblePerOccupant: 230,
                                         latentPerOccupant: 200,
                                         lightingWattsPerSquareFoot: 0,
                                         applianceSensibleBtuh: 0, applianceLatentBtuh: 0),
            airExchange: .average)

        let equipment = EquipmentSpec(
            manufacturer: "—", modelNumber: "Entered from expanded performance data",
            type: .heatPump,
            totalCoolingCapacityBtuh: 8_400,
            sensibleCoolingCapacityBtuh: 6_300,
            heatingCapacityBtuh: 6_500,
            maximumAirflowCFM: 450,
            blowerExternalStaticPressure: 0.60)

        let supplyTrunk = DuctRun(
            name: "Supply Trunk", role: .supplyTrunk, physicalLengthFeet: 30,
            fittings: [Fitting(name: "Supply plenum take-off", equivalentLengthFeet: 35)])
        let livingBranch = DuctRun(
            name: "Living Room Branch", role: .supplyBranch, physicalLengthFeet: 22,
            fittings: [Fitting(name: "90° elbow", equivalentLengthFeet: 15, count: 2),
                       Fitting(name: "Ceiling register boot", equivalentLengthFeet: 35)],
            servingZoneID: living.id)
        let bedroomBranch = DuctRun(
            name: "Primary Bedroom Branch", role: .supplyBranch, physicalLengthFeet: 18,
            fittings: [Fitting(name: "90° elbow", equivalentLengthFeet: 15),
                       Fitting(name: "Ceiling register boot", equivalentLengthFeet: 35)],
            servingZoneID: bedroom.id)
        let returnTrunk = DuctRun(
            name: "Return Trunk", role: .returnTrunk, physicalLengthFeet: 20,
            fittings: [Fitting(name: "Return grille", equivalentLengthFeet: 35)])

        return Project(
            name: "Sample Residence — Piedmont Triad",
            procedure: .residentialManualJ,
            designConditions: .piedmontTriad,
            zones: [living, bedroom],
            equipment: equipment,
            sizingLimits: .standard,
            staticPressureBudget: .typical,
            ductRuns: [supplyTrunk, livingBranch, bedroomBranch, returnTrunk],
            supplyAirDeltaTF: 20)
    }
}
