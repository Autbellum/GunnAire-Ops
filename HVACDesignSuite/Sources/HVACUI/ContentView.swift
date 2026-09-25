import SwiftUI
import HVACCore

/// Carries the front window's report to the menu bar, so Export Report acts on the
/// document the user is looking at rather than on a guess about which one is frontmost.
public struct DesignReportKey: FocusedValueKey {
    public typealias Value = () -> DesignReport
}

public extension FocusedValues {
    var designReport: DesignReportKey.Value? {
        get { self[DesignReportKey.self] }
        set { self[DesignReportKey.self] = newValue }
    }
}

/// The File ▸ Export Report… command.
public struct ReportExportCommands: Commands {
    @FocusedValue(\.designReport) private var report

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Export Report as PDF…") {
                guard let report = report?() else { return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = report.projectName
                    .replacingOccurrences(of: "/", with: "-") + " — Load Calculation.pdf"
                panel.allowedContentTypes = [.pdf]
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try ReportPDF.write(report, to: url)
                    NSWorkspace.shared.open(url)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(report == nil)
        }
    }
}

/// The three-panel workspace.
///
/// Left holds the things that govern the whole job — procedure, weather, indoor targets.
/// Centre holds what is being described — zones, surfaces, equipment, ducts.
/// Right holds what the description produces, recomputed on every keystroke.
///
/// The arrangement is deliberate: a designer changes one number on the left and watches
/// the consequence on the right without losing their place in the middle.
public struct ContentView: View {
    /// The document's project. The engine works on its own copy and publishes back, so a
    /// recalculation never writes through a binding mid-edit.
    @Binding private var project: Project
    @State private var engine: DesignEngine
    @State private var centreSelection: CentrePanel = .spaces

    public init(project: Binding<Project>) {
        self._project = project
        self._engine = State(initialValue: DesignEngine(project: project.wrappedValue))
    }

    /// Convenience for a window with no backing file.
    public init() {
        self.init(project: .constant(.sample))
    }

    /// Builds the printable report from whatever the engine currently holds.
    public func currentReport() -> DesignReport {
        ReportBuilder.build(project: engine.project,
                            load: engine.load ?? ProjectLoad(zoneLoads: [],
                                                             designConditions: engine.project.designConditions,
                                                             procedure: engine.project.procedure),
                            systems: engine.systems,
                            profile: engine.coolingProfile)
    }

    public var body: some View {
        NavigationSplitView {
            DesignConditionsSidebar(engine: engine)
                .navigationSplitViewColumnWidth(min: 340, ideal: 380, max: 460)
        } content: {
            SpaceConfigurationPanel(engine: engine, selection: $centreSelection)
                .navigationSplitViewColumnWidth(min: 420, ideal: 620)
        } detail: {
            ResultsDashboard(engine: engine)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
        }
        .navigationTitle(engine.project.name)
        .frame(minWidth: 1120, minHeight: 700)
        .focusedSceneValue(\.designReport, currentReport)
        // Push edits back to the document so Save, autosave, versions and the dirty dot
        // all work without the engine knowing a file exists.
        .onChange(of: engine.project) { _, updated in
            if project != updated { project = updated }
        }
        // And pick up a change that arrived from outside the engine — a revert, or an
        // undo through the document's own stack.
        .onChange(of: project) { _, updated in
            if engine.project != updated { engine.project = updated }
        }
    }
}

public enum CentrePanel: String, CaseIterable, Identifiable {
    case spaces = "Spaces"
    case systems = "Systems"
    case materials = "Materials"
    case detail = "Load Detail"
    case library = "Library"
    public var id: String { rawValue }

    var symbol: String {
        switch self {
        case .spaces: "square.split.bottomrightquarter"
        case .systems: "square.stack.3d.up"
        case .materials: "cube.box"
        case .detail: "list.bullet.rectangle"
        case .library: "books.vertical"
        }
    }
}

// MARK: - Left sidebar

struct DesignConditionsSidebar: View {
    @Bindable var engine: DesignEngine

    var body: some View {
        Form {
            Section("Customer") {
                TextField("Customer name", text: $engine.project.customer.customerName)
                TextField("Job number", text: $engine.project.customer.jobNumber)
                TextField("Street address", text: $engine.project.customer.streetAddress)
                TextField("City", text: $engine.project.customer.city)
                // Laid out as rows rather than a cramped HStack: a Form renders each
                // field's placeholder as its label, and "State" wrapped to "Sta te" in
                // a 56-point column.
                HStack(spacing: 8) {
                    LabeledContent("State") {
                        TextField("", text: $engine.project.customer.state)
                            .labelsHidden().frame(width: 60)
                    }
                    LabeledContent("ZIP") {
                        TextField("", text: $engine.project.customer.postalCode)
                            .labelsHidden().frame(width: 90)
                    }
                }
                TextField("Phone", text: $engine.project.customer.phone)
                TextField("Email", text: $engine.project.customer.email)
                TextField("Prepared by", text: $engine.project.customer.preparedBy)
                TextField("Licence", text: $engine.project.customer.contractorLicense)
                TextField("Notes", text: $engine.project.customer.notes, axis: .vertical)
                    .lineLimit(2...5)
            }

            Section("Project") {
                TextField("Name", text: $engine.project.name)
                Picker("Procedure", selection: $engine.project.procedure) {
                    ForEach(LoadProcedure.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(engine.project.procedure.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Site") {
                TextField("Location", text: $engine.project.designConditions.siteName)
                LabeledNumberField("Altitude", value: $engine.project.designConditions.altitudeFeet, unit: "ft")
                Text(String(format: "Air density is %.1f%% of sea level here, and the airflow coefficients are corrected for it.",
                            100 * pow(1 - 6.8754e-6 * engine.project.designConditions.altitudeFeet, 5.2559)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Outdoor Design") {
                LabeledNumberField("Winter 99.6%", value: $engine.project.designConditions.winterOutdoorDryBulbF, unit: "°F")
                LabeledNumberField("Summer 0.4% DB", value: $engine.project.designConditions.summerOutdoorDryBulbF, unit: "°F")
                LabeledNumberField("Summer MCWB", value: $engine.project.designConditions.summerOutdoorWetBulbF, unit: "°F")
                LabeledNumberField("Daily Range", value: $engine.project.designConditions.summerDailyRangeF, unit: "°F")
                LabeledContent("Range Class", value: engine.project.designConditions.dailyRangeClass)
            }

            Section("Indoor Targets") {
                LabeledNumberField("Winter", value: $engine.project.designConditions.indoorWinterDryBulbF, unit: "°F")
                LabeledNumberField("Summer", value: $engine.project.designConditions.indoorSummerDryBulbF, unit: "°F")
                LabeledNumberField("Summer RH", value: $engine.project.designConditions.indoorSummerRelativeHumidityPercent, unit: "%")
                Divider()
                LabeledContent("Heating ΔT", value: String(format: "%.1f °F", engine.project.designConditions.heatingDeltaT))
                LabeledContent("Cooling ΔT", value: String(format: "%.1f °F", engine.project.designConditions.coolingDeltaT))
            }

            Section("Weather Provenance") {
                Text(engine.project.designConditions.weatherSource)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared controls

/// A numeric field that keeps its unit visible.
///
/// Unit confusion is the most expensive kind of error in this domain — a duct sized from
/// an R-value entered as a U-value is wrong in a way that still looks plausible — so the
/// unit is never more than a glance away from the number.
struct LabeledNumberField: View {
    let label: String
    @Binding var value: Double
    let unit: String

    init(_ label: String, value: Binding<Double>, unit: String) {
        self.label = label; self._value = value; self.unit = unit
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .labelsHidden()
                    .frame(width: 84)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading)
            }
        }
    }
}

/// A headline figure for the dashboard.
struct MetricRow: View {
    let label: String
    let value: String
    var emphasis: Bool = false
    var tint: Color? = nil

    var body: some View {
        HStack {
            Text(label)
                .font(emphasis ? .callout.weight(.medium) : .callout)
                .foregroundStyle(emphasis ? .primary : .secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(emphasis ? .callout.weight(.semibold).monospacedDigit() : .callout.monospacedDigit())
                .foregroundStyle(tint ?? .primary)
        }
    }
}

extension SelectionStatus {
    var tint: Color {
        switch self {
        case .pass: .green
        case .caution: .orange
        case .fail: .red
        }
    }
    var symbol: String {
        switch self {
        case .pass: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        }
    }
}
