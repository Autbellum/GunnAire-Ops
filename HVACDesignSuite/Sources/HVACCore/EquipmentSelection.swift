import Foundation

/// Severity of a Manual S finding.
public enum SelectionStatus: String, Sendable, Equatable {
    case pass = "Pass"
    case caution = "Caution"
    case fail = "Fail"
}

/// One Manual S check and its outcome.
public struct SelectionCheck: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let status: SelectionStatus
    public let detail: String
    public let reference: String

    public init(name: String, status: SelectionStatus, detail: String, reference: String) {
        self.id = UUID(); self.name = name; self.status = status
        self.detail = detail; self.reference = reference
    }
}

/// The result of matching equipment to the calculated load.
public struct SelectionResult: Sendable, Equatable {
    public let checks: [SelectionCheck]
    public let totalCapacityRatio: Double?
    public let sensibleCapacityRatio: Double?
    public let latentCapacityRatio: Double?
    public let heatingCapacityRatio: Double?
    public let requiredAirflowCFM: Double
    public let equipmentSensibleHeatRatio: Double?
    public let loadSensibleHeatRatio: Double?

    /// The design does not proceed past a failure. Sizing the ducts for equipment that
    /// cannot meet the load produces a coherent drawing of the wrong system.
    public var isAcceptable: Bool { !checks.contains { $0.status == .fail } }
    public var hasCautions: Bool { checks.contains { $0.status == .caution } }
}

/// Module 2 — Manual S equipment selection.
///
/// Manual S is a set of acceptance tests, not a sizing formula: the load fixes what the
/// equipment must do, and the manufacturer's expanded performance data at the design
/// condition either satisfies it or does not. Each test below reports independently so a
/// near miss on one term is not hidden by comfortable margins on the others.
public enum EquipmentSelector {

    public static func evaluate(load: ProjectLoad,
                                equipment: EquipmentSpec,
                                limits: SizingLimits,
                                supplyAirDeltaTF: Double,
                                altitudeFeet: Double) throws -> SelectionResult {
        var checks: [SelectionCheck] = []

        // Airflow the sensible load demands: CFM = q_s / (1.08 · ΔT), altitude corrected.
        let sensibleCoefficient = try Psychrometrics.sensibleCoefficient(altitudeFeet: altitudeFeet)
        let requiredCFM = supplyAirDeltaTF > 0
            ? load.coolingSensibleBtuh / (sensibleCoefficient * supplyAirDeltaTF)
            : 0

        guard load.coolingTotalBtuh > 0 else {
            checks.append(SelectionCheck(
                name: "Load available",
                status: .caution,
                detail: "No cooling load has been calculated yet, so equipment cannot be checked against it.",
                reference: "Manual S"))
            return SelectionResult(checks: checks, totalCapacityRatio: nil, sensibleCapacityRatio: nil,
                                   latentCapacityRatio: nil, heatingCapacityRatio: nil,
                                   requiredAirflowCFM: 0, equipmentSensibleHeatRatio: equipment.sensibleHeatRatio,
                                   loadSensibleHeatRatio: nil)
        }

        // MARK: Total cooling capacity window.
        let totalRatio = equipment.totalCoolingCapacityBtuh / load.coolingTotalBtuh
        let lowerPercent = limits.coolingMinimumFraction * 100
        let upperPercent = limits.coolingMaximumFraction * 100
        if equipment.totalCoolingCapacityBtuh <= 0 {
            checks.append(SelectionCheck(
                name: "Total cooling capacity",
                status: .fail,
                detail: "No total cooling capacity has been entered from the expanded performance data.",
                reference: "Manual S — selection at the design condition"))
        } else if totalRatio < limits.coolingMinimumFraction {
            checks.append(SelectionCheck(
                name: "Total cooling capacity",
                status: .fail,
                detail: String(format: "Undersized. %.0f Btu/h is %.0f%% of the %.0f Btu/h total load, below the %.0f%% minimum. The space will not hold setpoint at design.",
                               equipment.totalCoolingCapacityBtuh, totalRatio * 100,
                               load.coolingTotalBtuh, lowerPercent),
                reference: "Manual S — total capacity window"))
        } else if totalRatio > limits.coolingMaximumFraction {
            checks.append(SelectionCheck(
                name: "Total cooling capacity",
                status: .fail,
                detail: String(format: "Oversized. %.0f Btu/h is %.0f%% of the %.0f Btu/h total load, above the %.0f%% maximum. Oversized cooling short-cycles and leaves humidity behind.",
                               equipment.totalCoolingCapacityBtuh, totalRatio * 100,
                               load.coolingTotalBtuh, upperPercent),
                reference: "Manual S — total capacity window"))
        } else {
            checks.append(SelectionCheck(
                name: "Total cooling capacity",
                status: .pass,
                detail: String(format: "%.0f Btu/h is %.0f%% of the %.0f Btu/h total load, inside the %.0f–%.0f%% window.",
                               equipment.totalCoolingCapacityBtuh, totalRatio * 100,
                               load.coolingTotalBtuh, lowerPercent, upperPercent),
                reference: "Manual S — total capacity window"))
        }

        // MARK: Sensible capacity, checked independently.
        let sensibleRatio = load.coolingSensibleBtuh > 0
            ? equipment.sensibleCoolingCapacityBtuh / load.coolingSensibleBtuh : nil
        if equipment.sensibleCoolingCapacityBtuh < load.coolingSensibleBtuh {
            checks.append(SelectionCheck(
                name: "Sensible capacity",
                status: .fail,
                detail: String(format: "Sensible capacity %.0f Btu/h does not cover the %.0f Btu/h sensible load — short by %.0f Btu/h. Temperature setpoint will not be held.",
                               equipment.sensibleCoolingCapacityBtuh, load.coolingSensibleBtuh,
                               load.coolingSensibleBtuh - equipment.sensibleCoolingCapacityBtuh),
                reference: "Manual S — sensible capacity must be met independently"))
        } else {
            checks.append(SelectionCheck(
                name: "Sensible capacity",
                status: .pass,
                detail: String(format: "%.0f Btu/h covers the %.0f Btu/h sensible load.",
                               equipment.sensibleCoolingCapacityBtuh, load.coolingSensibleBtuh),
                reference: "Manual S — sensible capacity"))
        }

        // MARK: Latent capacity, checked independently.
        let latentRatio = load.coolingLatentBtuh > 0
            ? equipment.latentCoolingCapacityBtuh / load.coolingLatentBtuh : nil
        if equipment.latentCoolingCapacityBtuh < load.coolingLatentBtuh {
            checks.append(SelectionCheck(
                name: "Latent capacity",
                status: .fail,
                detail: String(format: "Latent capacity %.0f Btu/h does not cover the %.0f Btu/h latent load — short by %.0f Btu/h. The space will hold temperature and stay humid.",
                               equipment.latentCoolingCapacityBtuh, load.coolingLatentBtuh,
                               load.coolingLatentBtuh - equipment.latentCoolingCapacityBtuh),
                reference: "Manual S — latent capacity must be met independently"))
        } else {
            checks.append(SelectionCheck(
                name: "Latent capacity",
                status: .pass,
                detail: String(format: "%.0f Btu/h covers the %.0f Btu/h latent load.",
                               equipment.latentCoolingCapacityBtuh, load.coolingLatentBtuh),
                reference: "Manual S — latent capacity"))
        }

        // MARK: Sensible heat ratio match.
        // Equipment can pass every capacity test and still be the wrong shape for the
        // space: a dry-climate coil in a humid climate satisfies total capacity by doing
        // too much sensible and not enough latent.
        if let equipmentSHR = equipment.sensibleHeatRatio, let loadSHR = load.sensibleHeatRatio {
            let difference = equipmentSHR - loadSHR
            if difference > 0.10 {
                checks.append(SelectionCheck(
                    name: "Sensible heat ratio",
                    status: .caution,
                    detail: String(format: "Equipment SHR %.2f is well above the load's %.2f. The coil is drier than the space needs and may leave humidity behind even at full capacity.",
                                   equipmentSHR, loadSHR),
                    reference: "Manual S — SHR matching"))
            } else {
                checks.append(SelectionCheck(
                    name: "Sensible heat ratio",
                    status: .pass,
                    detail: String(format: "Equipment SHR %.2f against a load SHR of %.2f.", equipmentSHR, loadSHR),
                    reference: "Manual S — SHR matching"))
            }
        }

        // MARK: Heating capacity.
        var heatingRatio: Double?
        if load.heatingBtuh > 0 && equipment.type != .airConditioner {
            let ratio = equipment.heatingCapacityBtuh / load.heatingBtuh
            heatingRatio = ratio
            let maximum = equipment.type == .heatPump
                ? limits.heatPumpHeatingMaximumFraction
                : limits.furnaceHeatingMaximumFraction
            if ratio < 1 {
                // A heat pump short of the heating load is normal design practice; the
                // balance point is covered by supplemental heat rather than by a larger
                // compressor, which would oversize cooling.
                let status: SelectionStatus = equipment.type == .heatPump ? .caution : .fail
                checks.append(SelectionCheck(
                    name: "Heating capacity",
                    status: status,
                    detail: String(format: "%.0f Btu/h meets %.0f%% of the %.0f Btu/h heating load. %@",
                                   equipment.heatingCapacityBtuh, ratio * 100, load.heatingBtuh,
                                   equipment.type == .heatPump
                                     ? "Size supplemental heat for the shortfall below the balance point."
                                     : "A furnace must meet the full heating load."),
                    reference: "Manual S — heating capacity"))
            } else if ratio > maximum {
                checks.append(SelectionCheck(
                    name: "Heating capacity",
                    status: .fail,
                    detail: String(format: "%.0f Btu/h is %.0f%% of the %.0f Btu/h heating load, above the %.0f%% maximum for a %@.",
                                   equipment.heatingCapacityBtuh, ratio * 100, load.heatingBtuh,
                                   maximum * 100, equipment.type.rawValue.lowercased()),
                    reference: "Manual S — heating capacity"))
            } else {
                checks.append(SelectionCheck(
                    name: "Heating capacity",
                    status: .pass,
                    detail: String(format: "%.0f Btu/h is %.0f%% of the %.0f Btu/h heating load.",
                                   equipment.heatingCapacityBtuh, ratio * 100, load.heatingBtuh),
                    reference: "Manual S — heating capacity"))
            }
        }

        // MARK: Blower airflow.
        if equipment.maximumAirflowCFM > 0 && requiredCFM > equipment.maximumAirflowCFM {
            checks.append(SelectionCheck(
                name: "Blower airflow",
                status: .fail,
                detail: String(format: "The sensible load needs %.0f CFM at a %.0f °F supply difference, above the blower's %.0f CFM maximum.",
                               requiredCFM, supplyAirDeltaTF, equipment.maximumAirflowCFM),
                reference: "Manual S — airflow at the design condition"))
        } else if equipment.maximumAirflowCFM > 0 {
            checks.append(SelectionCheck(
                name: "Blower airflow",
                status: .pass,
                detail: String(format: "%.0f CFM required of %.0f CFM available.",
                               requiredCFM, equipment.maximumAirflowCFM),
                reference: "Manual S — airflow"))
        }

        return SelectionResult(checks: checks,
                               totalCapacityRatio: equipment.totalCoolingCapacityBtuh > 0 ? totalRatio : nil,
                               sensibleCapacityRatio: sensibleRatio,
                               latentCapacityRatio: latentRatio,
                               heatingCapacityRatio: heatingRatio,
                               requiredAirflowCFM: requiredCFM,
                               equipmentSensibleHeatRatio: equipment.sensibleHeatRatio,
                               loadSensibleHeatRatio: load.sensibleHeatRatio)
    }
}
