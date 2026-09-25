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
/// Everything one system produces.
public struct SystemResult: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let load: ProjectLoad
    public let profile: CoolingProfile?
    public let selection: SelectionResult?
    public let airflows: [ZoneAirflow]
    public let friction: FrictionRateResult?
    public let ducts: [DuctSizingResult]
    public let coolingCFM: Double
    public let heatingCFM: Double
    public let zoneNames: [String]

    public var warnings: [String] {
        load.warnings + (friction?.warnings ?? []) + ducts.flatMap(\.warnings)
    }
}

@Observable
@MainActor
public final class DesignEngine {

    /// The single source of truth. Everything below is derived from it.
    public var project: Project {
        didSet { recalculate() }
    }

    // MARK: Derived state

    /// One result per system, in project order.
    public private(set) var systems: [SystemResult] = []
    /// Whole-building load across every zone, whether assigned to a system or not.
    public private(set) var load: ProjectLoad?
    public private(set) var coolingProfile: CoolingProfile?

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
            // Whole building first, for the summary and for any zone no system claims.
            let whole = try LoadCalculator.calculate(project: project)
            load = whole
            coolingProfile = try LoadCalculator.coolingProfile(project: project)

            // Then each system independently. A system is sized on the coincident peak of
            // the zones it serves, which is not the building's peak: an upstairs system
            // and a downstairs one peak at different hours and carry different
            // sensible/latent splits, and averaging them selects the wrong coil for both.
            var results: [SystemResult] = []
            for system in project.systems {
                let served = project.zones(servedBy: system)
                var subProject = project
                subProject.zones = served
                subProject.systems = [system]

                let systemLoad = try LoadCalculator.calculate(project: subProject)
                let profile = served.isEmpty ? nil : try LoadCalculator.coolingProfile(project: subProject)

                let selection = try EquipmentSelector.evaluate(
                    load: systemLoad, equipment: system.equipment,
                    limits: project.sizingLimits,
                    supplyAirDeltaTF: system.supplyAirDeltaTF,
                    altitudeFeet: project.designConditions.altitudeFeet)

                let coefficient = try Psychrometrics.sensibleCoefficient(
                    altitudeFeet: project.designConditions.altitudeFeet)
                var coolingCFM = selection.requiredAirflowCFM
                if system.equipment.maximumAirflowCFM > 0 {
                    coolingCFM = min(coolingCFM, system.equipment.maximumAirflowCFM)
                }
                let heatingCFM = system.supplyAirDeltaTF > 0
                    ? systemLoad.heatingBtuh / (coefficient * system.supplyAirDeltaTF) : 0

                let airflows = AirDistributionCalculator.allocate(
                    load: systemLoad, systemCoolingCFM: coolingCFM, systemHeatingCFM: heatingCFM)

                let friction = DuctDesigner.frictionRate(
                    equipment: system.equipment, budget: system.staticPressureBudget,
                    runs: system.ductRuns)
                let ducts = DuctDesigner.size(
                    runs: system.ductRuns, airflows: airflows,
                    systemCFM: max(coolingCFM, heatingCFM),
                    frictionRate: friction.frictionRatePer100Feet)

                results.append(SystemResult(
                    id: system.id, name: system.name, load: systemLoad, profile: profile,
                    selection: selection, airflows: airflows, friction: friction, ducts: ducts,
                    coolingCFM: coolingCFM, heatingCFM: heatingCFM,
                    zoneNames: served.map(\.name)))
            }
            systems = results
            lastCalculated = Date()
        } catch {
            calculationError = error.localizedDescription
            load = nil; coolingProfile = nil; systems = []
        }
    }

    // MARK: Convenience

    public var systemCoolingCFM: Double { systems.reduce(0) { $0 + $1.coolingCFM } }
    public var systemHeatingCFM: Double { systems.reduce(0) { $0 + $1.heatingCFM } }
    public var zoneAirflows: [ZoneAirflow] { systems.flatMap(\.airflows) }
    public var ductSizing: [DuctSizingResult] { systems.flatMap(\.ducts) }
    /// Present only when the design has exactly one system, where "the" equipment match
    /// is a meaningful idea.
    public var selection: SelectionResult? {
        systems.count == 1 ? systems[0].selection : nil
    }
    public var frictionRate: FrictionRateResult? {
        systems.count == 1 ? systems[0].friction : nil
    }

    /// Everything the design wants the engineer to look at.
    public var allWarnings: [String] {
        var warnings = load?.warnings ?? []
        warnings += systems.flatMap(\.warnings)
        for zone in project.unassignedZones {
            warnings.append("Zone “\(zone.name)” is not assigned to any system, so it has no equipment, no airflow and no ducts.")
        }
        for system in project.systems where system.zoneIDs.isEmpty {
            warnings.append("System “\(system.name)” serves no zones.")
        }
        if let error = calculationError { warnings.insert(error, at: 0) }
        return Array(NSOrderedSet(array: warnings).compactMap { $0 as? String })
    }

    // MARK: Mutations

    public func addZone() {
        let zone = Zone(name: "Zone \(project.zones.count + 1)", floorAreaSquareFeet: 200)
        project.zones.append(zone)
        // A new zone joins the first system rather than falling through the cracks.
        if !project.systems.isEmpty { project.systems[0].zoneIDs.append(zone.id) }
    }

    public func removeZones(at offsets: IndexSet) {
        let removed = offsets.compactMap { project.zones.indices.contains($0) ? project.zones[$0].id : nil }
        for index in offsets.sorted(by: >) where project.zones.indices.contains(index) {
            project.zones.remove(at: index)
        }
        for index in project.systems.indices {
            project.systems[index].zoneIDs.removeAll { removed.contains($0) }
            for runIndex in project.systems[index].ductRuns.indices {
                if let serving = project.systems[index].ductRuns[runIndex].servingZoneID,
                   removed.contains(serving) {
                    project.systems[index].ductRuns[runIndex].servingZoneID = nil
                }
            }
        }
    }

    public func addSurface(to zoneID: UUID) {
        guard let index = project.zones.firstIndex(where: { $0.id == zoneID }) else { return }
        let wall = project.customLibrary.assemblies(for: .wall).first
        project.zones[index].surfaces.append(
            Surface(name: "New Surface", category: .wall, areaSquareFeet: 100,
                    construction: wall.map { .assembly($0) } ?? .manual(rValue: 13, shgc: 0)))
    }

    public func addSystem() {
        project.systems.append(HVACSystem(name: "System \(project.systems.count + 1)"))
    }

    public func removeSystems(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where project.systems.indices.contains(index) {
            project.systems.remove(at: index)
        }
        if project.systems.isEmpty { project.systems = [HVACSystem()] }
    }

    /// Moves a zone to a system, removing it from any other. A zone served by two systems
    /// would be counted twice in the building rollup.
    public func assign(zoneID: UUID, toSystem systemID: UUID?) {
        for index in project.systems.indices {
            project.systems[index].zoneIDs.removeAll { $0 == zoneID }
        }
        guard let systemID,
              let index = project.systems.firstIndex(where: { $0.id == systemID }) else { return }
        project.systems[index].zoneIDs.append(zoneID)
    }

    public func addDuctRun(toSystem systemID: UUID) {
        guard let index = project.systems.firstIndex(where: { $0.id == systemID }) else { return }
        project.systems[index].ductRuns.append(
            DuctRun(name: "Run \(project.systems[index].ductRuns.count + 1)",
                    role: .supplyBranch, physicalLengthFeet: 25))
    }

    public func removeDuctRuns(at offsets: IndexSet, fromSystem systemID: UUID) {
        guard let index = project.systems.firstIndex(where: { $0.id == systemID }) else { return }
        for offset in offsets.sorted(by: >) where project.systems[index].ductRuns.indices.contains(offset) {
            project.systems[index].ductRuns.remove(at: offset)
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

        let system = HVACSystem(
            name: "System 1 — whole house",
            equipment: equipment,
            staticPressureBudget: .typical,
            supplyAirDeltaTF: 20,
            ductRuns: [supplyTrunk, livingBranch, bedroomBranch, returnTrunk],
            zoneIDs: [living.id, bedroom.id])

        return Project(
            name: "Sample Residence — Piedmont Triad",
            customer: CustomerInformation(
                customerName: "Sample Customer", jobNumber: "1042",
                streetAddress: "100 Reynolda Road", city: "Winston-Salem",
                state: "NC", postalCode: "27106",
                phone: "(336) 555-0100", email: "",
                preparedBy: "GunnAire, LLC", contractorLicense: "NC #35052"),
            procedure: .residentialManualJ,
            designConditions: .piedmontTriad,
            zones: [living, bedroom],
            systems: [system],
            customLibrary: CustomLibrary(),
            sizingLimits: .standard)
    }
}
