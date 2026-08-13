// ServiceCall.swift
// Model for scheduled jobs and service calls
import Foundation
import SwiftData

enum ServiceCallType: String, Codable, CaseIterable {
    case service
    case estimate
    case install
    case maintenance
    case meeting
    case reminder
    case siteVisit = "site visit"
    case other

    var displayName: String {
        switch self {
        case .service:
            return "Service"
        case .estimate:
            return "Estimate"
        case .install:
            return "Install"
        case .maintenance:
            return "Maintenance"
        case .meeting:
            return "Meeting"
        case .reminder:
            return "Reminder"
        case .siteVisit:
            return "Site Visit"
        case .other:
            return "Other"
        }
    }
}

enum JobStatus: String, Codable, CaseIterable {
    case scheduled, inProgress, completed, invoiced, cancelled
}

enum HVACEquipmentType: String, Codable, CaseIterable, Identifiable {
    case splitSystemAC = "split_system_ac"
    case heatPump = "heat_pump"
    case gasFurnace = "gas_furnace"
    case airHandler = "air_handler"
    case packageUnit = "package_unit"
    case miniSplit = "mini_split"
    case boiler = "boiler"
    case waterHeater = "water_heater"
    case ventilation = "ventilation"
    case other = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .splitSystemAC: return "Split System AC"
        case .heatPump: return "Heat Pump"
        case .gasFurnace: return "Gas Furnace"
        case .airHandler: return "Air Handler"
        case .packageUnit: return "Package Unit"
        case .miniSplit: return "Mini Split"
        case .boiler: return "Boiler"
        case .waterHeater: return "Water Heater"
        case .ventilation: return "Ventilation"
        case .other: return "Other"
        }
    }

    private static let refrigerantOptions = [
        "R-410A",
        "R-22",
        "R-32",
        "R-454B",
        "R-407C",
        "R-134a",
        "Other"
    ]

    private static let meteringDeviceOptions = [
        "TXV",
        "Piston",
        "EEV",
        "Capillary Tube",
        "Fixed Orifice",
        "Unknown"
    ]

    private static let conditionOptions = [
        "Normal",
        "Monitor",
        "Needs Cleaning",
        "Needs Repair",
        "Failed",
        "Not Tested",
        "Not Applicable"
    ]

    private static let blowerTypeOptions = [
        "PSC",
        "ECM Constant Torque",
        "ECM Variable Speed",
        "Belt Drive",
        "Direct Drive",
        "Unknown"
    ]

    private static let gasFuelOptions = [
        "Natural Gas",
        "Propane",
        "Oil",
        "Electric",
        "Other"
    ]

    private static let ignitionOptions = [
        "Hot Surface Ignition",
        "Spark Ignition",
        "Intermittent Pilot",
        "Standing Pilot",
        "Not Applicable"
    ]

    private static let ventingOptions = [
        "Natural Draft",
        "Induced Draft",
        "Direct Vent",
        "Power Vent",
        "Condensing",
        "Not Applicable"
    ]

    private static let packageHeatTypeOptions = [
        "Gas Heat",
        "Electric Heat",
        "Heat Pump",
        "Dual Fuel",
        "Cooling Only",
        "Unknown"
    ]

    private static let tankConditionOptions = [
        "Normal",
        "Sediment Present",
        "Flushed",
        "Leaking",
        "Corroded",
        "Replacement Recommended",
        "Not Accessible"
    ]

    var readingDefinitions: [HVACTechnicalReadingDefinition] {
        let common = [
            HVACTechnicalReadingDefinition(key: "return_air_temp", label: "Return Air Temp", unit: "F"),
            HVACTechnicalReadingDefinition(key: "supply_air_temp", label: "Supply Air Temp", unit: "F"),
            HVACTechnicalReadingDefinition(key: "temperature_split", label: "Temperature Split", unit: "F"),
            HVACTechnicalReadingDefinition(key: "line_voltage", label: "Line Voltage", unit: "V"),
            HVACTechnicalReadingDefinition(key: "control_voltage", label: "Control Voltage", unit: "V")
        ]

        switch self {
        case .splitSystemAC:
            return common + coolingCircuitDefinitions + [
                HVACTechnicalReadingDefinition(key: "condenser_condition", label: "Condenser Condition", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "evaporator_condition", label: "Evaporator Condition", unit: nil, options: Self.conditionOptions)
            ]
        case .heatPump:
            return common + coolingCircuitDefinitions + [
                HVACTechnicalReadingDefinition(key: "mode_tested", label: "Mode Tested", unit: nil, options: ["Cooling", "Heating", "Both"]),
                HVACTechnicalReadingDefinition(key: "reversing_valve_operation", label: "Reversing Valve", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "defrost_control_status", label: "Defrost Control", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "aux_heat_amps", label: "Aux Heat Amps", unit: "A")
            ]
        case .packageUnit:
            return common + coolingCircuitDefinitions + [
                HVACTechnicalReadingDefinition(key: "economizer_operation", label: "Economizer", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "package_heat_type", label: "Package Heat Type", unit: nil, options: Self.packageHeatTypeOptions),
                HVACTechnicalReadingDefinition(key: "ignition_type", label: "Ignition Type", unit: nil, options: Self.ignitionOptions),
                HVACTechnicalReadingDefinition(key: "gas_pressure_inlet", label: "Gas Pressure Inlet", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "gas_pressure_manifold", label: "Gas Pressure Manifold", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "blower_amps", label: "Blower Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "heat_strip_amps", label: "Heat Strip Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "condenser_condition", label: "Condenser Condition", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "evaporator_condition", label: "Evaporator Condition", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "heat_exchanger_condition", label: "Heat Exchanger", unit: nil, options: Self.conditionOptions)
            ]
        case .miniSplit:
            return common + coolingCircuitDefinitions + [
                HVACTechnicalReadingDefinition(key: "indoor_head_delta_t", label: "Indoor Head Delta T", unit: "F"),
                HVACTechnicalReadingDefinition(key: "communication_voltage", label: "Communication Voltage", unit: "V"),
                HVACTechnicalReadingDefinition(key: "inverter_frequency", label: "Inverter Frequency", unit: "Hz"),
                HVACTechnicalReadingDefinition(key: "indoor_fan_operation", label: "Indoor Fan", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "indoor_filter_condition", label: "Indoor Filter", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "indoor_coil_condition", label: "Indoor Coil", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "condensate_pump_status", label: "Condensate Pump", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "remote_operation", label: "Remote Operation", unit: nil, options: Self.conditionOptions)
            ]
        case .gasFurnace:
            return common + [
                HVACTechnicalReadingDefinition(key: "fuel_type", label: "Fuel Type", unit: nil, options: Self.gasFuelOptions),
                HVACTechnicalReadingDefinition(key: "ignition_type", label: "Ignition Type", unit: nil, options: Self.ignitionOptions),
                HVACTechnicalReadingDefinition(key: "venting_type", label: "Venting Type", unit: nil, options: Self.ventingOptions),
                HVACTechnicalReadingDefinition(key: "gas_pressure_inlet", label: "Gas Pressure Inlet", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "gas_pressure_manifold", label: "Gas Pressure Manifold", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "flame_sensor_microamps", label: "Flame Sensor", unit: "uA"),
                HVACTechnicalReadingDefinition(key: "inducer_amps", label: "Inducer Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "blower_amps", label: "Blower Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "temperature_rise", label: "Temperature Rise", unit: "F"),
                HVACTechnicalReadingDefinition(key: "draft_pressure", label: "Draft Pressure", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "flue_temp", label: "Flue Temp", unit: "F"),
                HVACTechnicalReadingDefinition(key: "o2_percent", label: "O2", unit: "%"),
                HVACTechnicalReadingDefinition(key: "co2_percent", label: "CO2", unit: "%"),
                HVACTechnicalReadingDefinition(key: "co_ppm", label: "CO Reading", unit: "ppm"),
                HVACTechnicalReadingDefinition(key: "heat_exchanger_condition", label: "Heat Exchanger", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "limit_switch_operation", label: "Limit Switch", unit: nil, options: Self.conditionOptions)
            ]
        case .airHandler:
            return common + [
                HVACTechnicalReadingDefinition(key: "blower_type", label: "Blower Type", unit: nil, options: Self.blowerTypeOptions),
                HVACTechnicalReadingDefinition(key: "blower_amps", label: "Blower Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "heat_strip_amps", label: "Heat Strip Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "static_pressure_return", label: "Return Static", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "static_pressure_supply", label: "Supply Static", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "total_external_static", label: "Total External Static", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "blower_wheel_condition", label: "Blower Wheel", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "duct_condition", label: "Duct Condition", unit: nil, options: Self.conditionOptions)
            ]
        case .boiler:
            return [
                HVACTechnicalReadingDefinition(key: "fuel_type", label: "Fuel Type", unit: nil, options: Self.gasFuelOptions),
                HVACTechnicalReadingDefinition(key: "water_temp_supply", label: "Supply Water Temp", unit: "F"),
                HVACTechnicalReadingDefinition(key: "water_temp_return", label: "Return Water Temp", unit: "F"),
                HVACTechnicalReadingDefinition(key: "system_pressure", label: "System Pressure", unit: "psi"),
                HVACTechnicalReadingDefinition(key: "expansion_tank_pressure", label: "Expansion Tank Pressure", unit: "psi"),
                HVACTechnicalReadingDefinition(key: "gas_pressure_inlet", label: "Gas Pressure Inlet", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "gas_pressure_manifold", label: "Gas Pressure Manifold", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "circulator_amps", label: "Circulator Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "relief_valve_status", label: "Relief Valve", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "backflow_preventer_status", label: "Backflow Preventer", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "flue_temp", label: "Flue Temp", unit: "F"),
                HVACTechnicalReadingDefinition(key: "co_ppm", label: "CO Reading", unit: "ppm")
            ]
        case .waterHeater:
            return [
                HVACTechnicalReadingDefinition(key: "fuel_type", label: "Fuel Type", unit: nil, options: Self.gasFuelOptions),
                HVACTechnicalReadingDefinition(key: "water_temp_out", label: "Outlet Water Temp", unit: "F"),
                HVACTechnicalReadingDefinition(key: "incoming_water_temp", label: "Incoming Water Temp", unit: "F"),
                HVACTechnicalReadingDefinition(key: "gas_pressure_inlet", label: "Gas Pressure Inlet", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "gas_pressure_manifold", label: "Gas Pressure Manifold", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "draft_pressure", label: "Draft Pressure", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "venting_type", label: "Venting Type", unit: nil, options: Self.ventingOptions),
                HVACTechnicalReadingDefinition(key: "tank_condition", label: "Tank Condition", unit: nil, options: Self.tankConditionOptions),
                HVACTechnicalReadingDefinition(key: "anode_rod_condition", label: "Anode Rod", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "relief_valve_status", label: "T&P Relief Valve", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "co_ppm", label: "CO Reading", unit: "ppm")
            ]
        case .ventilation:
            return [
                HVACTechnicalReadingDefinition(key: "airflow", label: "Airflow", unit: "CFM"),
                HVACTechnicalReadingDefinition(key: "outside_air_cfm", label: "Outside Air", unit: "CFM"),
                HVACTechnicalReadingDefinition(key: "exhaust_air_cfm", label: "Exhaust Air", unit: "CFM"),
                HVACTechnicalReadingDefinition(key: "motor_amps", label: "Motor Amps", unit: "A"),
                HVACTechnicalReadingDefinition(key: "line_voltage", label: "Line Voltage", unit: "V"),
                HVACTechnicalReadingDefinition(key: "static_pressure", label: "Static Pressure", unit: "in. w.c."),
                HVACTechnicalReadingDefinition(key: "belt_condition", label: "Belt Condition", unit: nil, options: Self.conditionOptions),
                HVACTechnicalReadingDefinition(key: "damper_operation", label: "Damper Operation", unit: nil, options: Self.conditionOptions)
            ]
        case .other:
            return common
        }
    }

    private var coolingCircuitDefinitions: [HVACTechnicalReadingDefinition] {
        [
            HVACTechnicalReadingDefinition(key: "refrigerant_type", label: "Refrigerant Type", unit: nil, options: Self.refrigerantOptions),
            HVACTechnicalReadingDefinition(key: "metering_device", label: "Metering Device", unit: nil, options: Self.meteringDeviceOptions),
            HVACTechnicalReadingDefinition(key: "outdoor_ambient_temp", label: "Outdoor Ambient", unit: "F"),
            HVACTechnicalReadingDefinition(key: "indoor_wet_bulb", label: "Indoor Wet Bulb", unit: "F"),
            HVACTechnicalReadingDefinition(key: "indoor_dry_bulb", label: "Indoor Dry Bulb", unit: "F"),
            HVACTechnicalReadingDefinition(key: "suction_pressure", label: "Suction Pressure", unit: "psig"),
            HVACTechnicalReadingDefinition(key: "liquid_pressure", label: "Liquid Pressure", unit: "psig"),
            HVACTechnicalReadingDefinition(key: "head_pressure", label: "Head Pressure", unit: "psig"),
            HVACTechnicalReadingDefinition(key: "suction_saturation_temp", label: "Suction Saturation Temp", unit: "F"),
            HVACTechnicalReadingDefinition(key: "liquid_saturation_temp", label: "Liquid Saturation Temp", unit: "F"),
            HVACTechnicalReadingDefinition(key: "suction_line_temp", label: "Suction Line Temp", unit: "F"),
            HVACTechnicalReadingDefinition(key: "liquid_line_temp", label: "Liquid Line Temp", unit: "F"),
            HVACTechnicalReadingDefinition(key: "target_superheat", label: "Target Superheat", unit: "F"),
            HVACTechnicalReadingDefinition(key: "superheat", label: "Superheat", unit: "F"),
            HVACTechnicalReadingDefinition(key: "target_subcooling", label: "Target Subcooling", unit: "F"),
            HVACTechnicalReadingDefinition(key: "subcooling", label: "Subcooling", unit: "F"),
            HVACTechnicalReadingDefinition(key: "compressor_rla", label: "Compressor RLA", unit: "A"),
            HVACTechnicalReadingDefinition(key: "compressor_amps", label: "Compressor Amps", unit: "A"),
            HVACTechnicalReadingDefinition(key: "outdoor_fan_fla", label: "Outdoor Fan FLA", unit: "A"),
            HVACTechnicalReadingDefinition(key: "outdoor_fan_amps", label: "Outdoor Fan Amps", unit: "A"),
            HVACTechnicalReadingDefinition(key: "capacitor_rating", label: "Capacitor Rating", unit: "uF"),
            HVACTechnicalReadingDefinition(key: "capacitor_actual", label: "Capacitor Actual", unit: "uF"),
            HVACTechnicalReadingDefinition(key: "contactor_condition", label: "Contactor Condition", unit: nil, options: Self.conditionOptions)
        ]
    }

    var requiredReadingKeysForCompleteServiceReport: [String] {
        switch self {
        case .splitSystemAC:
            return [
                "return_air_temp", "supply_air_temp", "temperature_split",
                "refrigerant_type", "metering_device", "suction_pressure", "liquid_pressure", "head_pressure",
                "suction_saturation_temp", "liquid_saturation_temp", "suction_line_temp", "liquid_line_temp",
                "superheat", "subcooling",
                "line_voltage", "compressor_rla", "compressor_amps"
            ]
        case .heatPump:
            return [
                "return_air_temp", "supply_air_temp", "temperature_split",
                "refrigerant_type", "mode_tested", "suction_pressure", "liquid_pressure", "head_pressure",
                "suction_saturation_temp", "liquid_saturation_temp", "suction_line_temp", "liquid_line_temp",
                "superheat", "subcooling", "reversing_valve_operation", "defrost_control_status",
                "line_voltage", "compressor_rla", "compressor_amps"
            ]
        case .packageUnit:
            return [
                "return_air_temp", "supply_air_temp", "temperature_split",
                "refrigerant_type", "suction_pressure", "liquid_pressure", "head_pressure",
                "suction_saturation_temp", "liquid_saturation_temp", "suction_line_temp", "liquid_line_temp",
                "superheat", "subcooling", "line_voltage", "compressor_rla", "compressor_amps",
                "economizer_operation", "package_heat_type", "blower_amps",
                "condenser_condition", "evaporator_condition", "heat_exchanger_condition"
            ]
        case .miniSplit:
            return [
                "return_air_temp", "supply_air_temp", "temperature_split",
                "refrigerant_type", "suction_pressure", "liquid_pressure",
                "line_voltage", "communication_voltage", "indoor_head_delta_t",
                "indoor_fan_operation", "indoor_filter_condition", "indoor_coil_condition",
                "condensate_pump_status", "remote_operation"
            ]
        case .gasFurnace:
            return [
                "return_air_temp", "supply_air_temp", "temperature_rise",
                "fuel_type", "ignition_type", "venting_type",
                "gas_pressure_inlet", "gas_pressure_manifold", "flame_sensor_microamps",
                "inducer_amps", "blower_amps", "draft_pressure",
                "co_ppm", "heat_exchanger_condition", "limit_switch_operation"
            ]
        case .airHandler:
            return [
                "return_air_temp", "supply_air_temp", "temperature_split",
                "blower_type", "blower_amps", "static_pressure_return",
                "static_pressure_supply", "total_external_static",
                "blower_wheel_condition", "duct_condition"
            ]
        case .boiler:
            return [
                "fuel_type", "water_temp_supply", "water_temp_return",
                "system_pressure", "expansion_tank_pressure",
                "gas_pressure_inlet", "gas_pressure_manifold",
                "circulator_amps", "relief_valve_status", "co_ppm"
            ]
        case .waterHeater:
            return [
                "fuel_type", "water_temp_out", "incoming_water_temp",
                "gas_pressure_inlet", "gas_pressure_manifold",
                "venting_type", "tank_condition", "relief_valve_status", "co_ppm"
            ]
        case .ventilation:
            return [
                "airflow", "outside_air_cfm", "exhaust_air_cfm",
                "motor_amps", "line_voltage", "static_pressure",
                "belt_condition", "damper_operation"
            ]
        case .other:
            return ["return_air_temp", "supply_air_temp", "line_voltage"]
        }
    }
}

struct HVACTechnicalReadingDefinition: Identifiable, Hashable {
    let key: String
    let label: String
    let unit: String?
    let options: [String]

    init(key: String, label: String, unit: String? = nil, options: [String] = []) {
        self.key = key
        self.label = label
        self.unit = unit
        self.options = options
    }

    var id: String { key }

    var displayLabel: String {
        if let unit, !unit.isEmpty {
            return "\(label) (\(unit))"
        }
        return label
    }

    var expectedRange: ClosedRange<Double>? {
        switch key {
        case "return_air_temp", "supply_air_temp", "outdoor_ambient_temp", "indoor_dry_bulb", "indoor_wet_bulb":
            return 30...130
        case "temperature_split", "indoor_head_delta_t", "target_superheat", "superheat", "target_subcooling", "subcooling", "temperature_rise":
            return 0...80
        case "suction_pressure", "liquid_pressure", "head_pressure":
            return 0...700
        case "suction_saturation_temp", "liquid_saturation_temp", "suction_line_temp", "liquid_line_temp", "water_temp_supply", "water_temp_return", "water_temp_out", "incoming_water_temp", "flue_temp":
            return 0...450
        case "line_voltage":
            return 90...600
        case "control_voltage", "communication_voltage":
            return 0...60
        case "compressor_rla", "compressor_amps", "outdoor_fan_fla", "outdoor_fan_amps", "aux_heat_amps", "blower_amps", "heat_strip_amps", "inducer_amps", "circulator_amps", "motor_amps":
            return 0...200
        case "capacitor_rating", "capacitor_actual":
            return 0...120
        case "gas_pressure_inlet", "gas_pressure_manifold", "draft_pressure", "static_pressure_return", "static_pressure_supply", "total_external_static", "static_pressure":
            return -10...10
        case "flame_sensor_microamps":
            return 0...20
        case "o2_percent", "co2_percent":
            return 0...25
        case "co_ppm":
            return 0...2000
        case "system_pressure", "expansion_tank_pressure":
            return 0...100
        case "airflow", "outside_air_cfm", "exhaust_air_cfm":
            return 0...10000
        case "inverter_frequency":
            return 0...250
        default:
            return nil
        }
    }

    var expectedRangeLabel: String? {
        guard let expectedRange else { return nil }
        let lower = Self.formatRangeBound(expectedRange.lowerBound)
        let upper = Self.formatRangeBound(expectedRange.upperBound)
        if let unit, !unit.isEmpty {
            return "\(lower)-\(upper) \(unit)"
        }
        return "\(lower)-\(upper)"
    }

    var inputHint: String? {
        switch key {
        case "return_air_temp":
            return "Measure at return before coil/heat exchanger."
        case "supply_air_temp":
            return "Measure at nearest representative supply."
        case "temperature_split":
            return "Use calculated supply/return difference when possible."
        case "refrigerant_type":
            return "Match equipment nameplate or known retrofit refrigerant."
        case "metering_device":
            return "Select installed metering device."
        case "suction_pressure", "liquid_pressure", "head_pressure":
            return "Gauge pressure measured at service ports."
        case "suction_saturation_temp", "liquid_saturation_temp":
            return "Use refrigerant PT chart or manifold saturation reading."
        case "suction_line_temp", "liquid_line_temp":
            return "Clamp temperature at service valve/line."
        case "target_superheat", "target_subcooling":
            return "Manufacturer target or calculated target."
        case "superheat", "subcooling":
            return "Use Calculate button when supporting readings are entered."
        case "line_voltage":
            return "Measured line voltage under operating load."
        case "control_voltage", "communication_voltage":
            return "Low-voltage/control circuit measurement."
        case "compressor_rla", "outdoor_fan_fla":
            return "Nameplate running-load/full-load amp rating."
        case "compressor_amps", "outdoor_fan_amps", "aux_heat_amps", "blower_amps", "heat_strip_amps", "inducer_amps", "circulator_amps", "motor_amps":
            return "Compare measured amps to nameplate/RLA where applicable."
        case "capacitor_rating", "capacitor_actual":
            return "Rated and measured microfarads."
        case "gas_pressure_inlet", "gas_pressure_manifold":
            return "Measure with calibrated manometer."
        case "draft_pressure", "static_pressure_return", "static_pressure_supply", "total_external_static", "static_pressure":
            return "Record pressure in inches water column."
        case "flame_sensor_microamps":
            return "Measure flame rectification signal."
        case "co_ppm":
            return "Record carbon monoxide reading; investigate unsafe readings."
        case "o2_percent", "co2_percent", "flue_temp":
            return "Combustion analyzer reading."
        case "system_pressure", "expansion_tank_pressure":
            return "Hydronic pressure reading."
        case "airflow", "outside_air_cfm", "exhaust_air_cfm":
            return "Measured or balanced airflow."
        case "inverter_frequency":
            return "Inverter operating frequency when available."
        default:
            return nil
        }
    }

    func validationIssue(for rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let expectedRange else { return nil }
        guard let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")) else {
            return "\(displayLabel) must be numeric"
        }
        guard expectedRange.contains(value) else {
            return "\(displayLabel) outside expected range\(expectedRangeLabel.map { " (\($0))" } ?? "")"
        }
        return nil
    }

    private static func formatRangeBound(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct HVACTechnicalReadingGroup: Identifiable, Hashable {
    let title: String
    let definitions: [HVACTechnicalReadingDefinition]

    var id: String { title }
}

struct HVACTechnicalReadingGroupProgress: Equatable {
    let totalCount: Int
    let capturedCount: Int
    let requiredCount: Int
    let missingRequiredCount: Int
    let validationIssueCount: Int

    var isComplete: Bool {
        missingRequiredCount == 0 && validationIssueCount == 0
    }

    var needsAttention: Bool {
        missingRequiredCount > 0 || validationIssueCount > 0
    }

    var summary: String {
        var parts = ["\(capturedCount)/\(totalCount) captured"]
        if requiredCount > 0 {
            parts.append("\(max(0, requiredCount - missingRequiredCount))/\(requiredCount) required")
        }
        if validationIssueCount > 0 {
            parts.append("\(validationIssueCount) invalid")
        } else if missingRequiredCount > 0 {
            parts.append("\(missingRequiredCount) missing")
        }
        return parts.joined(separator: " - ")
    }
}

struct JobCloseoutReadiness: Equatable {
    let requiredItems: [String]
    let missingItems: [String]

    var completedItems: [String] {
        requiredItems.filter { !missingItems.contains($0) }
    }

    var completedCount: Int {
        completedItems.count
    }

    var totalCount: Int {
        requiredItems.count
    }

    var isReady: Bool {
        missingItems.isEmpty
    }

    var statusLabel: String {
        isReady ? "Ready for closeout" : "Needs closeout details"
    }

    var summary: String {
        "\(completedCount)/\(totalCount) complete"
    }
}

@Model
final class ServiceCall {
    @Attribute(.unique) var id: UUID
    var googleCalendarID: String?
    var googleEventID: String?
    var googleEventManagedByApp: Bool = false
    var eventTitle: String?
    var siteAddress: String?
    var equipmentName: String?
    var equipmentManufacturer: String?
    var equipmentModel: String?
    var equipmentSerialNumber: String?
    var equipmentLocation: String?
    var equipmentInstallDate: Date?
    var equipmentWarrantyExpiration: Date?
    var customerEquipmentID: UUID?
    var equipmentTypeRaw: String?
    var serviceReportReadingsJSON: String?
    var filterSize: String?
    var filterCondition: String?
    var indoorCoilCondition: String?
    var outdoorCoilCondition: String?
    var drainLineCondition: String?
    var thermostatOperation: String?
    var serviceReportSummary: String?
    var type: ServiceCallType
    var scheduledDate: Date
    var duration: TimeInterval
    var assignedTechnician: Technician?
    var customer: Customer
    var status: JobStatus
    var notes: String?
    var findingsSummary: String?
    var recommendedWorkSummary: String?
    var followUpRequired: Bool
    var followUpAction: String?
    var followUpDueDate: Date?
    var diagnosticsCaptured: Bool
    var quoteReviewedWithCustomer: Bool
    var equipmentVerifiedChecklist: Bool
    var startupChecklistComplete: Bool
    var maintenanceChecklistComplete: Bool
    var safetyChecklistComplete: Bool
    var customerNotified: Bool
    var arrivalConfirmed: Bool
    var workCompletedChecklist: Bool
    var documentationChecklist: Bool
    var paymentCollectedChecklist: Bool
    var beforePhotoCount: Int
    var afterPhotoCount: Int
    var documentationStartedAt: Date?
    var documentationCompletedAt: Date?
    var linkedEstimateID: UUID?
    var linkedInvoiceID: UUID?
    
    init(
        id: UUID = UUID(),
        googleCalendarID: String? = nil,
        googleEventID: String? = nil,
        googleEventManagedByApp: Bool = false,
        eventTitle: String? = nil,
        siteAddress: String? = nil,
        equipmentName: String? = nil,
        equipmentManufacturer: String? = nil,
        equipmentModel: String? = nil,
        equipmentSerialNumber: String? = nil,
        equipmentLocation: String? = nil,
        equipmentInstallDate: Date? = nil,
        equipmentWarrantyExpiration: Date? = nil,
        customerEquipmentID: UUID? = nil,
        equipmentTypeRaw: String? = nil,
        serviceReportReadingsJSON: String? = nil,
        filterSize: String? = nil,
        filterCondition: String? = nil,
        indoorCoilCondition: String? = nil,
        outdoorCoilCondition: String? = nil,
        drainLineCondition: String? = nil,
        thermostatOperation: String? = nil,
        serviceReportSummary: String? = nil,
        type: ServiceCallType,
        scheduledDate: Date,
        duration: TimeInterval = 3600,
        assignedTechnician: Technician? = nil,
        customer: Customer,
        status: JobStatus = .scheduled,
        notes: String? = nil,
        findingsSummary: String? = nil,
        recommendedWorkSummary: String? = nil,
        followUpRequired: Bool = false,
        followUpAction: String? = nil,
        followUpDueDate: Date? = nil,
        diagnosticsCaptured: Bool = false,
        quoteReviewedWithCustomer: Bool = false,
        equipmentVerifiedChecklist: Bool = false,
        startupChecklistComplete: Bool = false,
        maintenanceChecklistComplete: Bool = false,
        safetyChecklistComplete: Bool = false,
        customerNotified: Bool = false,
        arrivalConfirmed: Bool = false,
        workCompletedChecklist: Bool = false,
        documentationChecklist: Bool = false,
        paymentCollectedChecklist: Bool = false,
        beforePhotoCount: Int = 0,
        afterPhotoCount: Int = 0,
        documentationStartedAt: Date? = nil,
        documentationCompletedAt: Date? = nil,
        linkedEstimateID: UUID? = nil,
        linkedInvoiceID: UUID? = nil
    ) {
        self.id = id
        self.googleCalendarID = googleCalendarID
        self.googleEventID = googleEventID
        self.googleEventManagedByApp = googleEventManagedByApp
        self.eventTitle = eventTitle
        self.siteAddress = siteAddress
        self.equipmentName = equipmentName
        self.equipmentManufacturer = equipmentManufacturer
        self.equipmentModel = equipmentModel
        self.equipmentSerialNumber = equipmentSerialNumber
        self.equipmentLocation = equipmentLocation
        self.equipmentInstallDate = equipmentInstallDate
        self.equipmentWarrantyExpiration = equipmentWarrantyExpiration
        self.customerEquipmentID = customerEquipmentID
        self.equipmentTypeRaw = equipmentTypeRaw
        self.serviceReportReadingsJSON = serviceReportReadingsJSON
        self.filterSize = filterSize
        self.filterCondition = filterCondition
        self.indoorCoilCondition = indoorCoilCondition
        self.outdoorCoilCondition = outdoorCoilCondition
        self.drainLineCondition = drainLineCondition
        self.thermostatOperation = thermostatOperation
        self.serviceReportSummary = serviceReportSummary
        self.type = type
        self.scheduledDate = scheduledDate
        self.duration = duration
        self.assignedTechnician = assignedTechnician
        self.customer = customer
        self.status = status
        self.notes = notes
        self.findingsSummary = findingsSummary
        self.recommendedWorkSummary = recommendedWorkSummary
        self.followUpRequired = followUpRequired
        self.followUpAction = followUpAction
        self.followUpDueDate = followUpDueDate
        self.diagnosticsCaptured = diagnosticsCaptured
        self.quoteReviewedWithCustomer = quoteReviewedWithCustomer
        self.equipmentVerifiedChecklist = equipmentVerifiedChecklist
        self.startupChecklistComplete = startupChecklistComplete
        self.maintenanceChecklistComplete = maintenanceChecklistComplete
        self.safetyChecklistComplete = safetyChecklistComplete
        self.customerNotified = customerNotified
        self.arrivalConfirmed = arrivalConfirmed
        self.workCompletedChecklist = workCompletedChecklist
        self.documentationChecklist = documentationChecklist
        self.paymentCollectedChecklist = paymentCollectedChecklist
        self.beforePhotoCount = beforePhotoCount
        self.afterPhotoCount = afterPhotoCount
        self.documentationStartedAt = documentationStartedAt
        self.documentationCompletedAt = documentationCompletedAt
        self.linkedEstimateID = linkedEstimateID
        self.linkedInvoiceID = linkedInvoiceID
    }
    
    var isUpcomingThisWeek: Bool {
        let now = Date()
        let oneWeekLater = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        return scheduledDate >= now && scheduledDate <= oneWeekLater
    }

    var checklistCompletedCount: Int {
        [customerNotified, arrivalConfirmed, workCompletedChecklist, documentationChecklist, paymentCollectedChecklist]
            .filter { $0 }
            .count
    }

    var checklistTotalCount: Int { 5 }

    var isExternallyLinked: Bool {
        googleEventID != nil || googleCalendarID != nil || linkedEstimateID != nil || linkedInvoiceID != nil
    }

    var equipmentSummary: String? {
        let decoratedParts: [String] = [
            equipmentType?.displayName,
            equipmentName?.trimmingCharacters(in: .whitespacesAndNewlines),
            equipmentManufacturer?.trimmingCharacters(in: .whitespacesAndNewlines),
            equipmentModel?.trimmingCharacters(in: .whitespacesAndNewlines),
            equipmentSerialNumber.flatMap { serial -> String? in
                let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : "S/N \(trimmed)"
            }
        ].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }

        guard !decoratedParts.isEmpty else { return nil }
        return decoratedParts.joined(separator: " • ")
    }

    var equipmentProfileServiceHistoryNote: String? {
        let title = "\(scheduledDate.formatted(date: .abbreviated, time: .omitted)) \(type.displayName)"
        let details = [
            serviceReportSummary.map { "Report: \($0)" },
            findingsSummary.map { "Findings: \($0)" },
            recommendedWorkSummary.map { "Recommended: \($0)" },
            technicalReadingServiceHistorySummary.map { "Readings: \($0)" },
            filterCondition.map { "Filter: \($0)" },
            indoorCoilCondition.map { "Indoor coil: \($0)" },
            outdoorCoilCondition.map { "Outdoor coil: \($0)" },
            drainLineCondition.map { "Drain: \($0)" },
            thermostatOperation.map { "Thermostat: \($0)" },
            linkedEstimateID.map { "Estimate: \(Self.shortHistoryID($0))" },
            linkedInvoiceID.map { "Invoice: \(Self.shortHistoryID($0))" }
        ]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }

        guard !details.isEmpty else { return nil }
        return ([title] + details).joined(separator: " - ")
    }

    private static func shortHistoryID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).uppercased()
    }

    var technicalReadingServiceHistorySummary: String? {
        let priorityKeys = [
            "return_air_temp",
            "supply_air_temp",
            "temperature_split",
            "refrigerant_type",
            "suction_pressure",
            "head_pressure",
            "superheat",
            "subcooling",
            "line_voltage",
            "compressor_amps",
            "outdoor_fan_amps",
            "blower_amps",
            "static_pressure_return",
            "static_pressure_supply",
            "total_external_static",
            "gas_pressure_inlet",
            "gas_pressure_manifold",
            "flame_sensor_microamps",
            "co_ppm"
        ]
        let definitionsByKey = Dictionary(uniqueKeysWithValues: technicalReadingDefinitions.map { ($0.key, $0) })
        let captured = technicalReadings
            .compactMap { key, rawValue -> (key: String, label: String, value: String)? in
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                let label = definitionsByKey[key]?.displayLabel ?? key.replacingOccurrences(of: "_", with: " ").capitalized
                return (key, label, value)
            }
        let ordered = captured.sorted { lhs, rhs in
            let lhsIndex = priorityKeys.firstIndex(of: lhs.key) ?? Int.max
            let rhsIndex = priorityKeys.firstIndex(of: rhs.key) ?? Int.max
            if lhsIndex == rhsIndex {
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            return lhsIndex < rhsIndex
        }
        guard !ordered.isEmpty else { return nil }
        return ordered
            .prefix(12)
            .map { "\($0.label): \($0.value)" }
            .joined(separator: "; ")
    }

    var equipmentType: HVACEquipmentType? {
        get {
            guard let equipmentTypeRaw else { return nil }
            return HVACEquipmentType(rawValue: equipmentTypeRaw)
        }
        set {
            let previousValue = equipmentTypeRaw
            equipmentTypeRaw = newValue?.rawValue
            if previousValue != equipmentTypeRaw {
                pruneTechnicalReadingsToCurrentEquipmentType()
            }
        }
    }

    var technicalReadingDefinitions: [HVACTechnicalReadingDefinition] {
        (equipmentType ?? .splitSystemAC).readingDefinitions
    }

    var groupedTechnicalReadingDefinitions: [HVACTechnicalReadingGroup] {
        Self.groupedTechnicalReadingDefinitions(for: technicalReadingDefinitions)
    }

    static func groupedTechnicalReadingDefinitions(
        for definitions: [HVACTechnicalReadingDefinition]
    ) -> [HVACTechnicalReadingGroup] {
        let groupOrder = [
            "Air Temperatures",
            "Refrigerant Circuit",
            "Electrical",
            "Airflow & Static",
            "Combustion",
            "Hydronics",
            "Controls & Safeties",
            "Conditions",
            "General"
        ]
        var grouped: [String: [HVACTechnicalReadingDefinition]] = [:]
        for definition in definitions {
            grouped[technicalReadingGroupTitle(for: definition.key), default: []].append(definition)
        }
        return groupOrder.compactMap { title in
            guard let definitions = grouped[title], !definitions.isEmpty else { return nil }
            return HVACTechnicalReadingGroup(title: title, definitions: definitions)
        }
    }

    private static func technicalReadingGroupTitle(for key: String) -> String {
        if key.contains("refrigerant") ||
            key.contains("suction") ||
            key.contains("liquid") ||
            key.contains("superheat") ||
            key.contains("subcooling") ||
            key.contains("metering") {
            return "Refrigerant Circuit"
        }
        if key.contains("voltage") ||
            key.contains("amps") ||
            key.contains("capacitor") ||
            key.contains("contactor") ||
            key.contains("communication") ||
            key.contains("motor") ||
            key.contains("flame_sensor") {
            return "Electrical"
        }
        if key.contains("airflow") ||
            key.contains("cfm") ||
            key.contains("static") ||
            key.contains("blower") ||
            key.contains("duct") ||
            key.contains("belt") ||
            key.contains("damper") {
            return "Airflow & Static"
        }
        if key.contains("fuel") ||
            key.contains("ignition") ||
            key.contains("venting") ||
            key.contains("gas_pressure") ||
            key.contains("draft") ||
            key.contains("flue") ||
            key.contains("o2") ||
            key.contains("co2") ||
            key.contains("co_ppm") {
            return "Combustion"
        }
        if key.contains("water") ||
            key.contains("system_pressure") ||
            key.contains("expansion") ||
            key.contains("circulator") ||
            key.contains("relief") ||
            key.contains("backflow") ||
            key.contains("tank") ||
            key.contains("anode") {
            return "Hydronics"
        }
        if key.contains("temp") || key.contains("temperature") || key.contains("wet_bulb") || key.contains("dry_bulb") {
            return "Air Temperatures"
        }
        if key.contains("mode") ||
            key.contains("reversing") ||
            key.contains("defrost") ||
            key.contains("economizer") ||
            key.contains("condensate") ||
            key.contains("remote") ||
            key.contains("limit_switch") {
            return "Controls & Safeties"
        }
        if key.contains("condition") ||
            key.contains("coil") ||
            key.contains("heat_exchanger") {
            return "Conditions"
        }
        return "General"
    }

    var technicalReadings: [String: String] {
        guard let serviceReportReadingsJSON,
              let data = serviceReportReadingsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    func technicalReading(for key: String) -> String {
        technicalReadings[key] ?? ""
    }

    func pruneTechnicalReadingsToCurrentEquipmentType() {
        let allowedKeys = Set(technicalReadingDefinitions.map(\.key))
        let prunedReadings = technicalReadings.filter { allowedKeys.contains($0.key) }
        guard prunedReadings.count != technicalReadings.count else { return }
        if prunedReadings.isEmpty {
            serviceReportReadingsJSON = nil
        } else if let data = try? JSONEncoder().encode(prunedReadings),
                  let encoded = String(data: data, encoding: .utf8) {
            serviceReportReadingsJSON = encoded
        }
    }

    func setTechnicalReading(_ value: String, for key: String) {
        var readings = technicalReadings
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            readings.removeValue(forKey: key)
        } else {
            readings[key] = trimmed
            diagnosticsCaptured = true
        }
        Self.applyDerivedTechnicalReadings(to: &readings, afterChanging: key)
        if readings.isEmpty {
            serviceReportReadingsJSON = nil
        } else if let data = try? JSONEncoder().encode(readings),
                  let encoded = String(data: data, encoding: .utf8) {
            serviceReportReadingsJSON = encoded
        }
    }

    func calculateTemperatureSplitReading() -> Double? {
        guard let returnTemp = numericTechnicalReading(for: "return_air_temp"),
              let supplyTemp = numericTechnicalReading(for: "supply_air_temp") else {
            return nil
        }
        let split = abs(returnTemp - supplyTemp)
        setTechnicalReading(Self.formattedTechnicalReading(split), for: "temperature_split")
        return split
    }

    func calculateTemperatureRiseReading() -> Double? {
        guard let returnTemp = numericTechnicalReading(for: "return_air_temp"),
              let supplyTemp = numericTechnicalReading(for: "supply_air_temp") else {
            return nil
        }
        let rise = supplyTemp - returnTemp
        setTechnicalReading(Self.formattedTechnicalReading(rise), for: "temperature_rise")
        return rise
    }

    func calculateSuperheatReading() -> Double? {
        guard let suctionLineTemp = numericTechnicalReading(for: "suction_line_temp"),
              let suctionSaturationTemp = numericTechnicalReading(for: "suction_saturation_temp") else {
            return nil
        }
        let superheat = suctionLineTemp - suctionSaturationTemp
        setTechnicalReading(Self.formattedTechnicalReading(superheat), for: "superheat")
        return superheat
    }

    func calculateSubcoolingReading() -> Double? {
        guard let liquidLineTemp = numericTechnicalReading(for: "liquid_line_temp"),
              let liquidSaturationTemp = numericTechnicalReading(for: "liquid_saturation_temp") else {
            return nil
        }
        let subcooling = liquidSaturationTemp - liquidLineTemp
        setTechnicalReading(Self.formattedTechnicalReading(subcooling), for: "subcooling")
        return subcooling
    }

    func calculateTotalExternalStaticReading() -> Double? {
        guard let returnStatic = numericTechnicalReading(for: "static_pressure_return"),
              let supplyStatic = numericTechnicalReading(for: "static_pressure_supply") else {
            return nil
        }
        let totalExternalStatic = abs(returnStatic) + abs(supplyStatic)
        setTechnicalReading(Self.formattedTechnicalReading(totalExternalStatic), for: "total_external_static")
        return totalExternalStatic
    }

    private func numericTechnicalReading(for key: String) -> Double? {
        Double(technicalReading(for: key).replacingOccurrences(of: ",", with: "."))
    }

    private static func applyDerivedTechnicalReadings(to readings: inout [String: String], afterChanging changedKey: String) {
        let derivedTargets: Set<String> = [
            "temperature_split",
            "temperature_rise",
            "superheat",
            "subcooling",
            "total_external_static"
        ]
        guard !derivedTargets.contains(changedKey) else { return }

        if changedKey == "return_air_temp" || changedKey == "supply_air_temp",
           let returnTemp = numericTechnicalReading("return_air_temp", in: readings),
           let supplyTemp = numericTechnicalReading("supply_air_temp", in: readings) {
            readings["temperature_split"] = formattedTechnicalReading(abs(returnTemp - supplyTemp))
            readings["temperature_rise"] = formattedTechnicalReading(supplyTemp - returnTemp)
        }

        if changedKey == "suction_line_temp" || changedKey == "suction_saturation_temp",
           let suctionLineTemp = numericTechnicalReading("suction_line_temp", in: readings),
           let suctionSaturationTemp = numericTechnicalReading("suction_saturation_temp", in: readings) {
            readings["superheat"] = formattedTechnicalReading(suctionLineTemp - suctionSaturationTemp)
        }

        if changedKey == "liquid_line_temp" || changedKey == "liquid_saturation_temp",
           let liquidLineTemp = numericTechnicalReading("liquid_line_temp", in: readings),
           let liquidSaturationTemp = numericTechnicalReading("liquid_saturation_temp", in: readings) {
            readings["subcooling"] = formattedTechnicalReading(liquidSaturationTemp - liquidLineTemp)
        }

        if changedKey == "static_pressure_return" || changedKey == "static_pressure_supply",
           let returnStatic = numericTechnicalReading("static_pressure_return", in: readings),
           let supplyStatic = numericTechnicalReading("static_pressure_supply", in: readings) {
            readings["total_external_static"] = formattedTechnicalReading(abs(returnStatic) + abs(supplyStatic))
        }
    }

    private static func numericTechnicalReading(_ key: String, in readings: [String: String]) -> Double? {
        guard let value = readings[key] else { return nil }
        return Double(value.replacingOccurrences(of: ",", with: "."))
    }

    private static func formattedTechnicalReading(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    var populatedTechnicalReadingRows: [(label: String, value: String)] {
        technicalReadingDefinitions.compactMap { definition in
            let value = technicalReading(for: definition.key).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return (definition.displayLabel, value)
        }
    }

    var requiredTechnicalReadingDefinitions: [HVACTechnicalReadingDefinition] {
        let requiredKeys = Set((equipmentType ?? .splitSystemAC).requiredReadingKeysForCompleteServiceReport)
        return technicalReadingDefinitions.filter { requiredKeys.contains($0.key) }
    }

    var missingRequiredTechnicalReadingDefinitions: [HVACTechnicalReadingDefinition] {
        requiredTechnicalReadingDefinitions.filter {
            technicalReading(for: $0.key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func technicalReadingProgress(in group: HVACTechnicalReadingGroup) -> HVACTechnicalReadingGroupProgress {
        let requiredKeys = Set(requiredTechnicalReadingDefinitions.map(\.key))
        let capturedDefinitions = group.definitions.filter {
            !technicalReading(for: $0.key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let requiredInGroup = group.definitions.filter { requiredKeys.contains($0.key) }
        let missingRequiredInGroup = requiredInGroup.filter {
            technicalReading(for: $0.key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let validationIssueCount = group.definitions.filter {
            technicalReadingValidationIssue(for: $0) != nil
        }.count

        return HVACTechnicalReadingGroupProgress(
            totalCount: group.definitions.count,
            capturedCount: capturedDefinitions.count,
            requiredCount: requiredInGroup.count,
            missingRequiredCount: missingRequiredInGroup.count,
            validationIssueCount: validationIssueCount
        )
    }

    var serviceReportReadingValidationIssueLabels: [String] {
        let rangeIssues = technicalReadingDefinitions.compactMap { definition in
            definition.validationIssue(for: technicalReading(for: definition.key))
        }
        return rangeIssues + serviceReportCrossReadingValidationIssueLabels
    }

    func technicalReadingValidationIssue(for definition: HVACTechnicalReadingDefinition) -> String? {
        definition.validationIssue(for: technicalReading(for: definition.key)) ??
            serviceReportCrossReadingValidationIssue(for: definition.key)
    }

    var serviceReportCrossReadingValidationIssueLabels: [String] {
        [
            ampLoadValidationIssue(
                measuredKey: "compressor_amps",
                ratingKey: "compressor_rla",
                measuredLabel: "Compressor Amps",
                ratingLabel: "Compressor RLA",
                toleranceMultiplier: 1.15
            ),
            ampLoadValidationIssue(
                measuredKey: "outdoor_fan_amps",
                ratingKey: "outdoor_fan_fla",
                measuredLabel: "Outdoor Fan Amps",
                ratingLabel: "Outdoor Fan FLA",
                toleranceMultiplier: 1.15
            ),
            targetDeviationValidationIssue(
                measuredKey: "superheat",
                targetKey: "target_superheat",
                measuredLabel: "Superheat",
                targetLabel: "Target Superheat",
                tolerance: 5
            ),
            targetDeviationValidationIssue(
                measuredKey: "subcooling",
                targetKey: "target_subcooling",
                measuredLabel: "Subcooling",
                targetLabel: "Target Subcooling",
                tolerance: 3
            ),
            combustionSafetyValidationIssue()
        ].compactMap { $0 }
    }

    private func serviceReportCrossReadingValidationIssue(for key: String) -> String? {
        switch key {
        case "compressor_amps":
            return ampLoadValidationIssue(
                measuredKey: "compressor_amps",
                ratingKey: "compressor_rla",
                measuredLabel: "Compressor Amps",
                ratingLabel: "Compressor RLA",
                toleranceMultiplier: 1.15
            )
        case "outdoor_fan_amps":
            return ampLoadValidationIssue(
                measuredKey: "outdoor_fan_amps",
                ratingKey: "outdoor_fan_fla",
                measuredLabel: "Outdoor Fan Amps",
                ratingLabel: "Outdoor Fan FLA",
                toleranceMultiplier: 1.15
            )
        case "superheat":
            return targetDeviationValidationIssue(
                measuredKey: "superheat",
                targetKey: "target_superheat",
                measuredLabel: "Superheat",
                targetLabel: "Target Superheat",
                tolerance: 5
            )
        case "subcooling":
            return targetDeviationValidationIssue(
                measuredKey: "subcooling",
                targetKey: "target_subcooling",
                measuredLabel: "Subcooling",
                targetLabel: "Target Subcooling",
                tolerance: 3
            )
        case "co_ppm":
            return combustionSafetyValidationIssue()
        default:
            return nil
        }
    }

    private func ampLoadValidationIssue(
        measuredKey: String,
        ratingKey: String,
        measuredLabel: String,
        ratingLabel: String,
        toleranceMultiplier: Double
    ) -> String? {
        guard let measured = numericTechnicalReading(for: measuredKey),
              let rating = numericTechnicalReading(for: ratingKey),
              rating > 0,
              measured > rating * toleranceMultiplier else {
            return nil
        }
        return "\(measuredLabel) exceeds \(ratingLabel) by more than \(Int((toleranceMultiplier - 1) * 100))%"
    }

    private func targetDeviationValidationIssue(
        measuredKey: String,
        targetKey: String,
        measuredLabel: String,
        targetLabel: String,
        tolerance: Double
    ) -> String? {
        guard let measured = numericTechnicalReading(for: measuredKey),
              let target = numericTechnicalReading(for: targetKey),
              abs(measured - target) > tolerance else {
            return nil
        }
        return "\(measuredLabel) differs from \(targetLabel) by more than \(ServiceCall.formattedTechnicalReading(tolerance)) F"
    }

    private func combustionSafetyValidationIssue() -> String? {
        guard let coPPM = numericTechnicalReading(for: "co_ppm"),
              coPPM >= 100 else {
            return nil
        }
        return "CO Reading requires documented safety action at 100 ppm or higher"
    }

    var serviceReportMissingRequirementLabels: [String] {
        serviceReportMissingRequiredItemLabels + serviceReportReadingValidationIssueLabels
    }

    var serviceReportMissingRequiredItemLabels: [String] {
        var missing: [String] = []
        if equipmentName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            missing.append("Equipment Name")
        }
        if equipmentModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            missing.append("Model")
        }
        if equipmentSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            missing.append("Serial Number")
        }
        missing.append(contentsOf: missingRequiredTechnicalReadingDefinitions.map(\.displayLabel))
        if serviceReportSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            missing.append("Service Report Summary")
        }
        return missing
    }

    var serviceReportRequiredItemCount: Int {
        4 + requiredTechnicalReadingDefinitions.count
    }

    var serviceReportCompletedRequiredItemCount: Int {
        max(0, serviceReportRequiredItemCount - serviceReportMissingRequiredItemLabels.count)
    }

    var serviceReportReadinessSummary: String {
        let base = "\(serviceReportCompletedRequiredItemCount)/\(serviceReportRequiredItemCount) required items"
        let invalidCount = serviceReportReadingValidationIssueLabels.count
        guard invalidCount > 0 else { return base }
        return "\(base) • \(invalidCount) invalid"
    }

    var requiresTechnicalServiceReportCompletion: Bool {
        switch type {
        case .service, .install, .maintenance:
            return true
        case .estimate, .meeting, .reminder, .siteVisit, .other:
            return false
        }
    }

    var canCompleteDocumentation: Bool {
        !requiresTechnicalServiceReportCompletion || serviceReportMissingRequirementLabels.isEmpty
    }

    @discardableResult
    func markDocumentationCompleteIfReady(at date: Date = Date()) -> Bool {
        guard canCompleteDocumentation else {
            documentationCompletedAt = nil
            return false
        }
        documentationChecklist = true
        documentationCompletedAt = documentationCompletedAt ?? date
        return true
    }

    var documentationCompletionBlockedMessage: String? {
        guard !canCompleteDocumentation else { return nil }
        return "Documentation is not complete. Missing or invalid: \(serviceReportMissingRequirementLabels.joined(separator: ", "))."
    }

    func closeoutReadiness(
        invoice: Invoice?,
        payments: [Payment],
        attachments: [ServiceDocumentAttachment]
    ) -> JobCloseoutReadiness {
        var requiredItems = [
            "Work completed",
            "Technical report complete",
            "Onsite report generated"
        ]
        if type != .estimate {
            requiredItems.append("Invoice created")
        }
        if let invoice {
            requiredItems.append("Invoice finalized")
            requiredItems.append("Customer signed")
            requiredItems.append("Payment resolved")
            requiredItems.append("QuickBooks invoice synced")
            if invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                requiredItems.append("QuickBooks attachments synced")
            }
        }

        var missing: [String] = []
        if !workCompletedChecklist && status != .completed && status != .invoiced {
            missing.append("Work completed")
        }
        if !canCompleteDocumentation {
            missing.append("Technical report complete")
        }
        let hasGeneratedReport = attachments.contains {
            $0.serviceCallID == id &&
                $0.kind == .serviceReport &&
                (invoice == nil || $0.invoiceID == invoice?.id) &&
                $0.localFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        if !hasGeneratedReport {
            missing.append("Onsite report generated")
        }
        if type != .estimate && invoice == nil {
            missing.append("Invoice created")
        }
        if let invoice {
            if invoice.finalizedAt == nil {
                missing.append("Invoice finalized")
            }
            if invoice.customerSignedAt == nil {
                missing.append("Customer signed")
            }
            let invoicePayments = payments.filter { $0.invoice.id == invoice.id }
            let balanceDue = Invoice.outstandingBalance(for: invoice, payments: invoicePayments)
            let paymentResolved = paymentCollectedChecklist ||
                Invoice.isPaid(invoice, payments: invoicePayments) ||
                balanceDue <= 0.009
            if !paymentResolved {
                missing.append("Payment resolved")
            }
            if invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                missing.append("QuickBooks invoice synced")
            } else {
                let pendingQBAttachments = attachments.contains {
                    $0.serviceCallID == id &&
                        $0.canBePendingQuickBooksInvoiceAttachment(for: invoice)
                }
                if pendingQBAttachments {
                    missing.append("QuickBooks attachments synced")
                }
            }
        }

        return JobCloseoutReadiness(requiredItems: requiredItems, missingItems: missing)
    }

    func refreshAttachmentProgress(from attachments: [ServiceDocumentAttachment]) {
        let jobAttachments = attachments.filter { $0.serviceCallID == id }
        beforePhotoCount = jobAttachments.filter { $0.kind == .beforePhoto }.count
        afterPhotoCount = jobAttachments.filter { $0.kind == .afterPhoto }.count
        if !jobAttachments.isEmpty {
            documentationStartedAt = documentationStartedAt ?? Date()
        } else if documentationCompletedAt == nil {
            documentationChecklist = false
        }
    }

    var workflowChecklistCompletedCount: Int {
        workflowChecklistValues.filter { $0 }.count
    }

    var workflowChecklistTotalCount: Int {
        workflowChecklistValues.count
    }

    private var workflowChecklistValues: [Bool] {
        switch type {
        case .service:
            return [diagnosticsCaptured, recommendedWorkSummary != nil, safetyChecklistComplete]
        case .estimate:
            return [quoteReviewedWithCustomer, recommendedWorkSummary != nil, followUpRequired]
        case .install:
            return [equipmentVerifiedChecklist, startupChecklistComplete, safetyChecklistComplete]
        case .maintenance:
            return [maintenanceChecklistComplete, safetyChecklistComplete, customerNotified]
        case .meeting, .reminder, .siteVisit, .other:
            return [arrivalConfirmed, workCompletedChecklist, documentationChecklist]
        }
    }
}
