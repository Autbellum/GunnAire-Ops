import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct FleetWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FleetVehicle.unitNumber, order: .forward) private var vehicles: [FleetVehicle]
    @Query(sort: \FleetVehicleEvent.occurredAt, order: .reverse) private var events: [FleetVehicleEvent]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \ServiceDocumentAttachment.createdAt, order: .reverse) private var attachments: [ServiceDocumentAttachment]

    @State private var selectedVehicleID: UUID?
    @State private var showingAddVehicle = false
    @State private var message: String?

    private var currentEmail: String? { AppIdentity.currentEmail }
    private var currentRole: AppUserRole? { AppAccess.activeRole(email: currentEmail, users: users) }
    private var currentTechnicianID: UUID? {
        AppAccess.ownPerformanceTechnicianID(email: currentEmail, users: users, technicians: technicians)
    }

    private var visibleVehicles: [FleetVehicle] {
        switch currentRole {
        case .fieldTechnician:
            guard let currentTechnicianID else { return [] }
            return vehicles.filter { $0.assignedTechnicianID == currentTechnicianID }
        case .standard, nil:
            return []
        case .dispatcher, .accounting, .admin:
            return vehicles
        }
    }

    private var selectedVehicle: FleetVehicle? {
        let resolvedID = selectedVehicleID ?? visibleVehicles.first?.id
        return visibleVehicles.first { $0.id == resolvedID }
    }

    private var attentionCount: Int {
        visibleVehicles.filter { $0.readiness().needsAttention }.count
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedVehicleID) {
                Section {
                    HStack(spacing: 12) {
                        fleetMetric("\(visibleVehicles.filter { $0.readiness().isDispatchReady }.count)", label: "ready", tint: .green)
                        fleetMetric("\(attentionCount)", label: "attention", tint: attentionCount == 0 ? .secondary : .orange)
                        fleetMetric("\(visibleVehicles.filter { $0.administrativeStatus == .outOfService }.count)", label: "out", tint: .red)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Fleet readiness: \(visibleVehicles.filter { $0.readiness().isDispatchReady }.count) ready, \(attentionCount) need attention, \(visibleVehicles.filter { $0.administrativeStatus == .outOfService }.count) out of service")
                } header: {
                    Text("Readiness")
                }

                Section("Vehicles") {
                    if visibleVehicles.isEmpty {
                        ContentUnavailableView(
                            currentRole == .fieldTechnician ? "No Assigned Vehicle" : "No Fleet Vehicles",
                            systemImage: "car.2",
                            description: Text(currentRole == .fieldTechnician
                                ? "Dispatch can assign a vehicle to this technician account."
                                : "Add each service truck once, then connect its technician and stock location.")
                        )
                    } else {
                        ForEach(visibleVehicles) { vehicle in
                            fleetVehicleRow(vehicle)
                                .tag(vehicle.id)
                        }
                    }
                }
            }
            .navigationTitle("Fleet")
            .toolbar {
                if AppAccess.canAdministerFleet(email: currentEmail, users: users) {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAddVehicle = true
                        } label: {
                            Label("Add Vehicle", systemImage: "plus")
                        }
                        .accessibilityIdentifier("AddFleetVehicle")
                    }
                }
            }
        } detail: {
            if let selectedVehicle {
                FleetVehicleDetailView(
                    vehicle: selectedVehicle,
                    allVehicles: vehicles,
                    events: events.filter { $0.vehicleID == selectedVehicle.id },
                    technicians: technicians,
                    users: users,
                    attachments: attachments.filter { $0.fleetVehicleID == selectedVehicle.id },
                    currentEmail: currentEmail,
                    currentRole: currentRole,
                    currentTechnicianID: currentTechnicianID,
                    message: $message
                )
                .id(selectedVehicle.id)
            } else {
                ContentUnavailableView(
                    "Fleet Readiness",
                    systemImage: "car.2",
                    description: Text("Vehicle exceptions stay here instead of adding another dashboard.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showingAddVehicle) {
            FleetVehicleAddSheet(
                existingVehicles: vehicles,
                actorEmail: currentEmail,
                role: currentRole,
                onSaved: { vehicle in
                    selectedVehicleID = vehicle.id
                    message = "Added \(vehicle.unitNumber)."
                }
            )
        }
        .safeAreaInset(edge: .bottom) {
            if let message {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Button("Dismiss", systemImage: "xmark") {
                        self.message = nil
                    }
                    .labelStyle(.iconOnly)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .padding()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("FleetStatusMessage")
            }
        }
        .onAppear {
            if selectedVehicleID == nil {
                selectedVehicleID = visibleVehicles.first?.id
            }
        }
        .onChange(of: visibleVehicles.map(\.id)) { _, IDs in
            if let selectedVehicleID, !IDs.contains(selectedVehicleID) {
                self.selectedVehicleID = IDs.first
            } else if selectedVehicleID == nil {
                selectedVehicleID = IDs.first
            }
        }
    }

    private func fleetMetric(_ value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func fleetVehicleRow(_ vehicle: FleetVehicle) -> some View {
        let readiness = vehicle.readiness()
        return HStack(spacing: 10) {
            Image(systemName: readiness.isDispatchReady ? "car.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(readiness.isDispatchReady ? .green : .orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(vehicle.unitNumber)
                    .font(.subheadline.weight(.semibold))
                Text(vehicle.assignedTechnicianName ?? "Unassigned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(readiness.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(readiness.isDispatchReady ? .green : .orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(vehicle.unitNumber), \(vehicle.assignedTechnicianName ?? "unassigned"), \(readiness.title)")
    }
}

private struct FleetVehicleDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let vehicle: FleetVehicle
    let allVehicles: [FleetVehicle]
    let events: [FleetVehicleEvent]
    let technicians: [Technician]
    let users: [AppUser]
    let attachments: [ServiceDocumentAttachment]
    let currentEmail: String?
    let currentRole: AppUserRole?
    let currentTechnicianID: UUID?
    @Binding var message: String?

    @State private var activeSheet: FleetVehicleSheet?
    @State private var isHistoryExpanded = false
    @State private var isFilesExpanded = false
    @State private var previewFile: FleetPreviewFile?

    private var readiness: FleetVehicleReadiness { vehicle.readiness() }
    private var canInspect: Bool {
        AppAccess.canRecordFleetInspection(email: currentEmail, users: users) &&
            (currentRole != .fieldTechnician || vehicle.assignedTechnicianID == currentTechnicianID)
    }
    private var canService: Bool {
        AppAccess.canRecordFleetService(email: currentEmail, users: users) &&
            (currentRole != .fieldTechnician || vehicle.assignedTechnicianID == currentTechnicianID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actionBar
                readinessCard
                identityCard
                DisclosureGroup(isExpanded: $isHistoryExpanded) {
                    eventHistory
                        .padding(.top, 8)
                } label: {
                    Label("History (\(events.count))", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                DisclosureGroup(isExpanded: $isFilesExpanded) {
                    fleetFiles
                        .padding(.top, 8)
                } label: {
                    Label("Service Files (\(attachments.count))", systemImage: "paperclip")
                        .font(.headline)
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding()
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(vehicle.unitNumber)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .inspection:
                FleetInspectionSheet(
                    vehicle: vehicle,
                    actorEmail: currentEmail,
                    role: currentRole,
                    actorTechnicianID: currentTechnicianID,
                    onSaved: { message = $0 }
                )
            case .service:
                FleetServiceSheet(
                    vehicle: vehicle,
                    actorEmail: currentEmail,
                    role: currentRole,
                    actorTechnicianID: currentTechnicianID,
                    onSaved: { message = $0 }
                )
            case .assignment:
                FleetAssignmentSheet(
                    vehicle: vehicle,
                    technicians: technicians,
                    existingVehicles: allVehicles,
                    actorEmail: currentEmail,
                    role: currentRole,
                    onSaved: { message = $0 }
                )
            case .outOfService:
                FleetStatusChangeSheet(
                    title: "Take Out of Service",
                    prompt: "Explain the operating or safety reason.",
                    actionTitle: "Take Out of Service",
                    actionRole: .destructive
                ) { reason in
                    let event = try FleetVehiclePolicy.setOutOfService(
                        vehicle,
                        reason: reason,
                        actorEmail: currentEmail,
                        role: currentRole
                    )
                    modelContext.insert(event)
                    try modelContext.save()
                    message = "\(vehicle.unitNumber) is out of service."
                }
            case .returnToService:
                FleetStatusChangeSheet(
                    title: "Return to Service",
                    prompt: "Confirm the repair and passing follow-up inspection.",
                    actionTitle: "Return to Service"
                ) { reason in
                    let event = try FleetVehiclePolicy.returnToService(
                        vehicle,
                        events: events,
                        reason: reason,
                        actorEmail: currentEmail,
                        role: currentRole
                    )
                    modelContext.insert(event)
                    try modelContext.save()
                    message = "\(vehicle.unitNumber) returned to service."
                }
            case .retire:
                FleetStatusChangeSheet(
                    title: "Retire Vehicle",
                    prompt: "Retirement clears the technician assignment but preserves all history.",
                    actionTitle: "Retire Vehicle",
                    actionRole: .destructive
                ) { reason in
                    let event = try FleetVehiclePolicy.retire(
                        vehicle,
                        reason: reason,
                        actorEmail: currentEmail,
                        role: currentRole
                    )
                    modelContext.insert(event)
                    try modelContext.save()
                    message = "Retired \(vehicle.unitNumber)."
                }
            }
        }
        .sheet(item: $previewFile) { file in
            AttachmentPreviewScreen(url: file.url)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: readiness.isDispatchReady ? "car.fill" : "car.rear.and.tire.marks")
                .font(.largeTitle)
                .foregroundStyle(readiness.isDispatchReady ? .green : .orange)
                .frame(width: 54, height: 54)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(vehicle.displayName)
                    .font(.title2.weight(.bold))
                Text(vehicle.assignedTechnicianName ?? "No technician assigned")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label(readiness.title, systemImage: readiness.isDispatchReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(readiness.isDispatchReady ? .green : .orange)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actionButtons }
            VStack(alignment: .leading, spacing: 10) { actionButtons }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if canInspect && vehicle.administrativeStatus != .retired {
            Button { activeSheet = .inspection } label: {
                Label("Inspect", systemImage: "checklist")
            }
            .accessibilityIdentifier("RecordFleetInspection")
        }
        if canService && vehicle.administrativeStatus != .retired {
            Button { activeSheet = .service } label: {
                Label("Log Service", systemImage: "wrench.adjustable")
            }
            .accessibilityIdentifier("LogFleetService")
        }
        if AppAccess.canManageFleetOperations(email: currentEmail, users: users),
           vehicle.administrativeStatus != .retired {
            Button { activeSheet = .assignment } label: {
                Label("Assign", systemImage: "person.crop.circle.badge.checkmark")
            }
            Menu {
                if vehicle.administrativeStatus == .inService {
                    Button("Take Out of Service", role: .destructive) { activeSheet = .outOfService }
                }
                if AppAccess.canAdministerFleet(email: currentEmail, users: users),
                   vehicle.administrativeStatus == .outOfService {
                    Button("Return to Service") { activeSheet = .returnToService }
                }
                if AppAccess.canAdministerFleet(email: currentEmail, users: users) {
                    Button("Retire Vehicle", role: .destructive) { activeSheet = .retire }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Readiness", systemImage: "gauge.with.dots.needle.33percent")
                .font(.headline)
                .foregroundStyle(Color.brandGold)
            readinessRow("Inspection", value: inspectionDetail, attention: readiness.inspectionDue)
            Divider()
            readinessRow("Service", value: serviceDetail, attention: readiness.serviceDue)
            Divider()
            readinessRow("Inventory", value: vehicle.stockLocation, attention: vehicle.stockLocation.isEmpty)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Vehicle", systemImage: "car.side")
                .font(.headline)
                .foregroundStyle(Color.brandGold)
            detailRow("VIN", vehicle.vin ?? "Not recorded")
            detailRow("Plate", vehicle.licensePlate ?? "Not recorded")
            detailRow("Odometer", vehicle.odometer.map { "\($0.formatted(.number.precision(.fractionLength(0)))) mi" } ?? "Not recorded")
            if let notes = vehicle.notes, !notes.isEmpty {
                detailRow("Notes", notes)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var eventHistory: some View {
        if events.isEmpty {
            Text("No fleet events recorded.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            ForEach(events.prefix(50)) { event in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(event.kind.displayName)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(event.occurredAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(event.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(event.actorEmail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 5)
                if event.id != events.prefix(50).last?.id { Divider() }
            }
        }
    }

    @ViewBuilder
    private var fleetFiles: some View {
        if attachments.isEmpty {
            Text("Attach a receipt or service document while logging vehicle service.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            ForEach(attachments) { attachment in
                Button {
                    guard FileManager.default.fileExists(atPath: attachment.localFilePath) else {
                        message = "\(attachment.displayName) is not available on this device."
                        return
                    }
                    previewFile = FleetPreviewFile(url: attachment.localFileURL)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(Color.brandGold)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.displayName)
                                .font(.subheadline.weight(.semibold))
                            Text(attachment.createdAt, format: .dateTime.month(.abbreviated).day().year())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if attachment.googleDriveSyncState == .archived {
                            Image(systemName: "checkmark.icloud")
                                .foregroundStyle(.green)
                                .accessibilityLabel("Archived in Google Drive")
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                if attachment.id != attachments.last?.id { Divider() }
            }
        }
    }

    private var inspectionDetail: String {
        guard let date = vehicle.nextInspectionDueAt else { return "Not recorded" }
        return "Due \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private var serviceDetail: String {
        var values: [String] = []
        if let date = vehicle.nextServiceDueAt {
            values.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if let mileage = vehicle.nextServiceDueOdometer {
            values.append("\(mileage.formatted(.number.precision(.fractionLength(0)))) mi")
        }
        return values.isEmpty ? "No interval recorded" : "Due " + values.joined(separator: " or ")
    }

    private func readinessRow(_ title: String, value: String, attention: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(value).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: attention ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(attention ? .orange : .green)
        }
        .accessibilityElement(children: .combine)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 20)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private enum FleetVehicleSheet: String, Identifiable {
    case inspection
    case service
    case assignment
    case outOfService
    case returnToService
    case retire

    var id: String { rawValue }
}

private struct FleetVehicleAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let existingVehicles: [FleetVehicle]
    let actorEmail: String?
    let role: AppUserRole?
    let onSaved: (FleetVehicle) -> Void

    @State private var unitNumber = ""
    @State private var vin = ""
    @State private var licensePlate = ""
    @State private var year = ""
    @State private var make = ""
    @State private var model = ""
    @State private var stockLocation = ""
    @State private var odometer = ""
    @State private var nextInspectionDueAt = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var tracksServiceDate = true
    @State private var nextServiceDueAt = Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
    @State private var nextServiceMileage = ""
    @State private var notes = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Unit number (for example, Truck 4)", text: $unitNumber)
                        .accessibilityIdentifier("FleetUnitNumber")
                    TextField("VIN", text: $vin)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("License plate", text: $licensePlate)
                        .textInputAutocapitalization(.characters)
                    TextField("Year", text: $year)
                        .keyboardType(.numberPad)
                    TextField("Make", text: $make)
                    TextField("Model", text: $model)
                }
                Section("Operations") {
                    TextField("Matching inventory location", text: $stockLocation)
                        .accessibilityIdentifier("FleetStockLocation")
                    TextField("Current odometer", text: $odometer)
                        .keyboardType(.decimalPad)
                    DatePicker("Next inspection", selection: $nextInspectionDueAt, displayedComponents: .date)
                    Toggle("Track service by date", isOn: $tracksServiceDate)
                    if tracksServiceDate {
                        DatePicker("Next service", selection: $nextServiceDueAt, displayedComponents: .date)
                    }
                    TextField("Next service mileage", text: $nextServiceMileage)
                        .keyboardType(.decimalPad)
                }
                Section("Notes") {
                    TextField("Optional fleet note", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Fleet Vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                        .accessibilityIdentifier("SaveFleetVehicle")
                }
            }
        }
    }

    private func save() {
        do {
            let currentOdometer = try optionalFleetNumber(
                odometer,
                invalidError: .invalidOdometer
            )
            let serviceMileage = try optionalFleetNumber(
                nextServiceMileage,
                invalidError: .invalidServiceInterval
            )
            let outcome = try FleetVehiclePolicy.createVehicle(
                unitNumber: unitNumber,
                vin: vin,
                licensePlate: licensePlate,
                vehicleYear: try optionalFleetInteger(
                    year,
                    invalidError: .invalidYear
                ),
                make: make,
                model: model,
                stockLocation: stockLocation,
                odometer: currentOdometer,
                nextInspectionDueAt: nextInspectionDueAt,
                nextServiceDueAt: tracksServiceDate ? nextServiceDueAt : nil,
                nextServiceDueOdometer: serviceMileage,
                notes: notes,
                existingVehicles: existingVehicles,
                actorEmail: actorEmail,
                role: role
            )
            modelContext.insert(outcome.0)
            modelContext.insert(outcome.1)
            try modelContext.save()
            onSaved(outcome.0)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FleetInspectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let vehicle: FleetVehicle
    let actorEmail: String?
    let role: AppUserRole?
    let actorTechnicianID: UUID?
    let onSaved: (String) -> Void

    @State private var results: [FleetInspectionItem: Bool] = [:]
    @State private var odometer = ""
    @State private var notes = ""
    @State private var nextInspectionDueAt = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Record Pass or Fail for every item. Any failed item takes the vehicle out of service until a later passing inspection and administrator release.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Inspection") {
                    ForEach(FleetInspectionItem.allCases) { item in
                        Picker(item.displayName, selection: resultBinding(for: item)) {
                            Text("Not checked").tag(Bool?.none)
                            Text("Pass").tag(Bool?.some(true))
                            Text("Fail").tag(Bool?.some(false))
                        }
                        .accessibilityIdentifier("FleetInspection_\(item.rawValue)")
                    }
                }
                Section("Reading & Follow-up") {
                    TextField("Odometer", text: $odometer)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("FleetInspectionOdometer")
                    DatePicker("Next inspection", selection: $nextInspectionDueAt, displayedComponents: .date)
                    TextField("Notes or failed-item detail", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Inspect \(vehicle.unitNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record") { save() }
                        .accessibilityIdentifier("SaveFleetInspection")
                }
            }
            .onAppear {
                odometer = vehicle.odometer.map(fleetEditableNumber) ?? ""
            }
        }
    }

    private func resultBinding(for item: FleetInspectionItem) -> Binding<Bool?> {
        Binding(
            get: { results[item] },
            set: { value in
                if let value { results[item] = value }
                else { results.removeValue(forKey: item) }
            }
        )
    }

    private func save() {
        do {
            let event = try FleetVehiclePolicy.recordInspection(
                for: vehicle,
                results: results,
                odometer: Double(odometer) ?? -1,
                notes: notes,
                nextInspectionDueAt: nextInspectionDueAt,
                actorEmail: actorEmail,
                role: role,
                actorTechnicianID: actorTechnicianID
            )
            modelContext.insert(event)
            try modelContext.save()
            onSaved(event.failedInspectionItems.isEmpty
                ? "Recorded a passing inspection for \(vehicle.unitNumber)."
                : "\(vehicle.unitNumber) is out of service after a failed inspection.")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FleetServiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let vehicle: FleetVehicle
    let actorEmail: String?
    let role: AppUserRole?
    let actorTechnicianID: UUID?
    let onSaved: (String) -> Void

    @State private var category: FleetServiceCategory = .preventiveMaintenance
    @State private var detail = ""
    @State private var odometer = ""
    @State private var cost = ""
    @State private var serviceCenter = ""
    @State private var invoiceNumber = ""
    @State private var tracksNextDate = true
    @State private var nextServiceDueAt = Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
    @State private var nextServiceMileage = ""
    @State private var importedFileURL: URL?
    @State private var showingFileImporter = false
    @State private var errorMessage: String?

    private var canRecordCost: Bool { role == .accounting || role == .admin }

    var body: some View {
        NavigationStack {
            Form {
                Section("Service") {
                    Picker("Category", selection: $category) {
                        ForEach(FleetServiceCategory.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("Service performed", text: $detail, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("FleetServiceDetail")
                    TextField("Odometer", text: $odometer)
                        .keyboardType(.decimalPad)
                    TextField("Service center", text: $serviceCenter)
                    TextField("Invoice / receipt number", text: $invoiceNumber)
                    if canRecordCost {
                        TextField("Cost", text: $cost)
                            .keyboardType(.decimalPad)
                    }
                }
                Section("Next Service") {
                    Toggle("Track by date", isOn: $tracksNextDate)
                    if tracksNextDate {
                        DatePicker("Due date", selection: $nextServiceDueAt, displayedComponents: .date)
                    }
                    TextField("Due mileage", text: $nextServiceMileage)
                        .keyboardType(.decimalPad)
                }
                Section("Receipt or Service File") {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label(importedFileURL?.lastPathComponent ?? "Choose File", systemImage: "paperclip")
                    }
                    if importedFileURL != nil {
                        Button("Remove Selected File", role: .destructive) { importedFileURL = nil }
                    }
                    Text("The app keeps the file with this service event. An administrator can archive the app-owned copy through the existing Google Drive recovery lane.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Service \(vehicle.unitNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record") { save() }
                        .accessibilityIdentifier("SaveFleetService")
                }
            }
            .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): importedFileURL = urls.first
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .onAppear {
                odometer = vehicle.odometer.map(fleetEditableNumber) ?? ""
            }
        }
    }

    private func save() {
        do {
            let costValue = canRecordCost
                ? try optionalFleetNumber(cost, invalidError: .invalidServiceCost)
                : nil
            let serviceMileage = try optionalFleetNumber(
                nextServiceMileage,
                invalidError: .invalidServiceInterval
            )
            let event = try FleetVehiclePolicy.recordService(
                for: vehicle,
                category: category,
                detail: detail,
                odometer: Double(odometer) ?? -1,
                cost: costValue,
                serviceCenter: serviceCenter,
                invoiceNumber: invoiceNumber,
                nextServiceDueAt: tracksNextDate ? nextServiceDueAt : nil,
                nextServiceDueOdometer: serviceMileage,
                actorEmail: actorEmail,
                role: role,
                actorTechnicianID: actorTechnicianID
            )
            modelContext.insert(event)
            if let importedFileURL {
                let attachment = try FleetAttachmentStore.makeAttachment(
                    sourceURL: importedFileURL,
                    vehicle: vehicle,
                    event: event
                )
                modelContext.insert(attachment)
            }
            try modelContext.save()
            onSaved("Recorded \(category.displayName.lowercased()) for \(vehicle.unitNumber).")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FleetAssignmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let vehicle: FleetVehicle
    let technicians: [Technician]
    let existingVehicles: [FleetVehicle]
    let actorEmail: String?
    let role: AppUserRole?
    let onSaved: (String) -> Void

    @State private var selectedTechnicianID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Technician") {
                    Picker("Assignment", selection: $selectedTechnicianID) {
                        Text("Unassigned").tag(UUID?.none)
                        ForEach(technicians) { technician in
                            Text(technician.name).tag(UUID?.some(technician.id))
                        }
                    }
                    Text("The vehicle's stock location remains \(vehicle.stockLocation). Assignment does not silently transfer inventory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle("Assign \(vehicle.unitNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear { selectedTechnicianID = vehicle.assignedTechnicianID }
        }
    }

    private func save() {
        do {
            let technician = selectedTechnicianID.flatMap { id in technicians.first { $0.id == id } }
            let event = try FleetVehiclePolicy.assign(
                vehicle,
                to: technician,
                existingVehicles: existingVehicles,
                actorEmail: actorEmail,
                role: role
            )
            modelContext.insert(event)
            try modelContext.save()
            onSaved(technician.map { "Assigned \(vehicle.unitNumber) to \($0.name)." } ?? "Cleared the \(vehicle.unitNumber) assignment.")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FleetStatusChangeSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let prompt: String
    let actionTitle: String
    var actionRole: ButtonRole? = nil
    let action: (String) throws -> Void

    @State private var reason = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(prompt).font(.caption).foregroundStyle(.secondary)
                    TextField("Reason", text: $reason, axis: .vertical)
                        .lineLimit(2...5)
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle, role: actionRole) {
                        do {
                            try action(reason)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}

private enum FleetAttachmentStore {
    private static let maximumFileSize = 25 * 1_024 * 1_024

    static func makeAttachment(
        sourceURL: URL,
        vehicle: FleetVehicle,
        event: FleetVehicleEvent
    ) throws -> ServiceDocumentAttachment {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        let resourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resourceValues.isRegularFile != false else {
            throw FleetAttachmentStoreError.invalidFile
        }
        if let fileSize = resourceValues.fileSize, fileSize > maximumFileSize {
            throw FleetAttachmentStoreError.fileTooLarge
        }
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard data.count <= maximumFileSize else {
            throw FleetAttachmentStoreError.fileTooLarge
        }
        let documentsURL = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folderURL = documentsURL.appendingPathComponent("GunnAire Fleet Files", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let safeName = sanitizedFilename(sourceURL.lastPathComponent)
        let destination = folderURL.appendingPathComponent("\(event.id.uuidString)-\(safeName)")
        try data.write(to: destination, options: .atomic)
        let contentType = UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return ServiceDocumentAttachment(
            customer: nil,
            serviceCallID: nil,
            fleetVehicleID: vehicle.id,
            fleetVehicleEventID: event.id,
            kind: .fleetService,
            displayName: safeName,
            caption: "\(vehicle.unitNumber) • \(event.kind.displayName)",
            localFilePath: destination.path,
            contentType: contentType,
            fileSizeBytes: data.count
        )
    }

    private static func sanitizedFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- "))
        let value = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "fleet-service-file" : String(sanitized.prefix(160))
    }
}

private enum FleetAttachmentStoreError: LocalizedError {
    case invalidFile
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            "Choose a regular file for the fleet service record."
        case .fileTooLarge:
            "Choose a fleet service file no larger than 25 MB."
        }
    }
}

private struct FleetPreviewFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private func optionalFleetNumber(
    _ value: String,
    invalidError: FleetVehiclePolicyError
) throws -> Double? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    guard let number = Double(value), number.isFinite else { throw invalidError }
    return number
}

private func optionalFleetInteger(
    _ value: String,
    invalidError: FleetVehiclePolicyError
) throws -> Int? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    guard let number = Int(value) else { throw invalidError }
    return number
}

private func fleetEditableNumber(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(value)
}
