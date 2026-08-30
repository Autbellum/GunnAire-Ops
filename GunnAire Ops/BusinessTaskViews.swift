import SwiftData
import SwiftUI

struct BusinessTaskCompactRow: View {
    let task: BusinessTask
    var now = Date()

    private var tint: Color {
        if task.status == .completed { return .green }
        if task.status == .cancelled { return .secondary }
        if task.isOverdue(now: now) || task.priority == .urgent { return .red }
        if task.priority == .high { return .orange }
        return Color.brandGold
    }

    private var statusLabel: String {
        switch task.status {
        case .open:
            task.isOverdue(now: now) ? "Overdue" : task.dueAt.formatted(date: .abbreviated, time: .shortened)
        case .completed:
            task.completedAt.map { "Completed \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Completed"
        case .cancelled:
            "Cancelled"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: task.status == .completed ? "checkmark.circle.fill" : task.priority.systemImage)
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.subheadline.weight(.semibold))
                    if task.isOpen && task.priority != .normal {
                        Text(task.priority.displayName.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(tint)
                    }
                }
                Text("\(statusLabel) • \(AppAccess.inferredDisplayName(fromEmail: task.assignedToEmail))")
                    .font(.caption)
                    .foregroundStyle(task.isOverdue(now: now) ? .red : .secondary)
                if let linkedRecordSummary = task.linkedRecordSummary {
                    Text(linkedRecordSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct BusinessTaskInlineSummary: View {
    let tasks: [BusinessTask]
    let accessibilityIdentifier: String
    let onOpen: () -> Void

    private var openTasks: [BusinessTask] {
        BusinessTaskPolicy.ordered(tasks.filter(\.isOpen))
    }

    var body: some View {
        if !openTasks.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(openTasks.prefix(3)) { task in
                        BusinessTaskCompactRow(task: task)
                    }
                    Button(openTasks.count > 3 ? "Open all \(openTasks.count) tasks" : "Open Team Tasks") {
                        onOpen()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("OpenBusinessTasks")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Team Tasks", systemImage: "checklist")
                    .foregroundStyle(openTasks.contains(where: { $0.isOverdue() }) ? .red : Color.brandGold)
            }
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}

struct BusinessTaskWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BusinessTask.dueAt, order: .forward) private var tasks: [BusinessTask]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]

    let initialCustomerID: UUID?
    let initialServiceCallID: UUID?

    @State private var showingCreate = false
    @State private var selectedTask: BusinessTask?
    @State private var showingCompleted = false

    init(initialCustomerID: UUID? = nil, initialServiceCallID: UUID? = nil) {
        self.initialCustomerID = initialCustomerID
        self.initialServiceCallID = initialServiceCallID
    }

    private var currentEmail: String? { AppIdentity.currentEmail }

    private var visibleServiceCallIDs: Set<UUID> {
        AppAccess.visibleServiceCallIDs(
            email: currentEmail,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
    }

    private var visibleTasks: [BusinessTask] {
        let scoped = BusinessTaskPolicy.visibleTasks(
            from: tasks,
            email: currentEmail,
            users: users,
            visibleServiceCallIDs: visibleServiceCallIDs
        )
        if let initialServiceCallID {
            return scoped.filter { $0.serviceCallID == initialServiceCallID }
        }
        if let initialCustomerID {
            return scoped.filter { $0.customerID == initialCustomerID }
        }
        return scoped
    }

    private var openTasks: [BusinessTask] { visibleTasks.filter(\.isOpen) }
    private var completedTasks: [BusinessTask] { visibleTasks.filter { $0.status == .completed } }
    private var cancelledTasks: [BusinessTask] { visibleTasks.filter { $0.status == .cancelled } }

    private var canCreate: Bool {
        guard let currentEmail else { return false }
        let role = AppAccess.activeRole(email: currentEmail, users: users)
        if role == .admin || role == .dispatcher { return true }
        if role == .accounting || role == .standard {
            return AppAccess.canCreateBusinessTask(
                assignedToEmail: currentEmail,
                serviceCallID: initialServiceCallID,
                email: currentEmail,
                users: users,
                visibleServiceCallIDs: visibleServiceCallIDs
            )
        }
        guard role == .fieldTechnician, let initialServiceCallID else { return false }
        return AppAccess.canCreateBusinessTask(
            assignedToEmail: currentEmail,
            serviceCallID: initialServiceCallID,
            email: currentEmail,
            users: users,
            visibleServiceCallIDs: visibleServiceCallIDs
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Open") {
                    if openTasks.isEmpty {
                        ContentUnavailableView(
                            "No Open Tasks",
                            systemImage: "checkmark.circle",
                            description: Text("Assigned follow-ups and internal work will appear here after CloudKit sync.")
                        )
                    } else {
                        ForEach(openTasks) { task in
                            Button {
                                selectedTask = task
                            } label: {
                                BusinessTaskCompactRow(task: task)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("BusinessTask-\(task.id.uuidString)")
                        }
                    }
                }

                if !completedTasks.isEmpty || !cancelledTasks.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showingCompleted) {
                            ForEach(completedTasks + cancelledTasks) { task in
                                Button {
                                    selectedTask = task
                                } label: {
                                    BusinessTaskCompactRow(task: task)
                                }
                                .buttonStyle(.plain)
                            }
                        } label: {
                            Text("\(completedTasks.count) completed • \(cancelledTasks.count) cancelled")
                        }
                    } header: {
                        Text("History")
                    }
                }

                Section {
                    Text("Tasks are internal. They never notify a customer, change a job status, or create a QuickBooks transaction. Every create, edit, completion, reopen, and cancellation keeps separate audit evidence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Team Tasks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if canCreate {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingCreate = true
                        } label: {
                            Label("Add Task", systemImage: "plus")
                        }
                        .accessibilityIdentifier("AddBusinessTask")
                    }
                }
            }
            .sheet(isPresented: $showingCreate) {
                BusinessTaskEditorView(
                    task: nil,
                    fixedCustomerID: initialCustomerID,
                    fixedServiceCallID: initialServiceCallID
                )
            }
            .sheet(item: $selectedTask) { task in
                BusinessTaskDetailView(task: task)
            }
        }
    }
}

private struct BusinessTaskDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \BusinessTaskEvent.occurredAt, order: .reverse) private var allEvents: [BusinessTaskEvent]

    let task: BusinessTask

    @State private var showingEdit = false
    @State private var completionNote = ""
    @State private var cancellationReason = ""
    @State private var reopenReason = ""
    @State private var message: String?

    private var currentEmail: String? { AppIdentity.currentEmail }
    private var canEdit: Bool { AppAccess.canUpdateBusinessTask(task, email: currentEmail, users: users) }
    private var canComplete: Bool { AppAccess.canCompleteBusinessTask(task, email: currentEmail, users: users) }
    private var canCancel: Bool { AppAccess.canCancelBusinessTask(task, email: currentEmail, users: users) }
    private var canReopen: Bool { AppAccess.canReopenBusinessTask(task, email: currentEmail, users: users) }
    private var events: [BusinessTaskEvent] { BusinessTaskPolicy.events(for: task.id, in: allEvents) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    BusinessTaskCompactRow(task: task)
                    if let taskDescription = task.taskDescription {
                        Text(taskDescription)
                    }
                    if let completionNote = task.completionNote {
                        LabeledContent("Completion", value: completionNote)
                    }
                    if let cancellationReason = task.cancellationReason {
                        LabeledContent("Cancellation", value: cancellationReason)
                    }
                }

                if canComplete {
                    Section("Complete") {
                        TextField("Required completion result", text: $completionNote, axis: .vertical)
                            .lineLimit(2...5)
                            .accessibilityIdentifier("BusinessTaskCompletionNote")
                        Button("Mark Complete") { completeTask() }
                            .buttonStyle(.borderedProminent)
                            .disabled(completionNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("CompleteBusinessTask")
                    }
                }

                if canCancel {
                    Section("Cancel") {
                        TextField("Required cancellation reason", text: $cancellationReason, axis: .vertical)
                            .lineLimit(2...4)
                        Button("Cancel Task", role: .destructive) { cancelTask() }
                            .disabled(cancellationReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if canReopen {
                    Section("Reopen") {
                        TextField("Reason or next step (optional)", text: $reopenReason, axis: .vertical)
                            .lineLimit(2...4)
                        Button("Reopen Task") { reopenTask() }
                    }
                }

                Section("History") {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(event.kind.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(event.detail)
                                .font(.caption)
                            Text(AppAccess.inferredDisplayName(fromEmail: event.actorEmail))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                if let message {
                    Section { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Task Details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if canEdit {
                    ToolbarItem(placement: .primaryAction) { Button("Edit") { showingEdit = true } }
                }
            }
            .sheet(isPresented: $showingEdit) {
                BusinessTaskEditorView(task: task, fixedCustomerID: task.customerID, fixedServiceCallID: task.serviceCallID)
            }
        }
    }

    private func completeTask() {
        mutate { try BusinessTaskPolicy.complete(task, actorEmail: currentEmail, note: completionNote) }
    }

    private func cancelTask() {
        mutate { try BusinessTaskPolicy.cancel(task, actorEmail: currentEmail, reason: cancellationReason) }
    }

    private func reopenTask() {
        mutate { try BusinessTaskPolicy.reopen(task, actorEmail: currentEmail, reason: reopenReason) }
    }

    private func mutate(_ operation: () throws -> BusinessTaskEvent) {
        let priorCompletedAt = task.completedAt
        let priorCompletedByEmail = task.completedByEmail
        let priorCompletionNote = task.completionNote
        let priorCompletionOperationID = task.completionOperationID
        let priorCancelledAt = task.cancelledAt
        let priorCancelledByEmail = task.cancelledByEmail
        let priorCancellationReason = task.cancellationReason
        let priorCancellationOperationID = task.cancellationOperationID
        let priorUpdatedAt = task.updatedAt
        var insertedEvent: BusinessTaskEvent?
        do {
            let event = try operation()
            insertedEvent = event
            modelContext.insert(event)
            try modelContext.save()
            message = "Task updated. CloudKit will carry the result and separate audit event to other approved devices."
        } catch {
            if let insertedEvent { modelContext.delete(insertedEvent) }
            task.completedAt = priorCompletedAt
            task.completedByEmail = priorCompletedByEmail
            task.completionNote = priorCompletionNote
            task.completionOperationID = priorCompletionOperationID
            task.cancelledAt = priorCancelledAt
            task.cancelledByEmail = priorCancelledByEmail
            task.cancellationReason = priorCancellationReason
            task.cancellationOperationID = priorCancellationOperationID
            task.updatedAt = priorUpdatedAt
            message = error.localizedDescription
        }
    }
}

private struct BusinessTaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \Customer.name, order: .forward) private var customers: [Customer]
    @Query(sort: \CustomerServiceLocation.name, order: .forward) private var serviceLocations: [CustomerServiceLocation]
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]

    let task: BusinessTask?
    let fixedCustomerID: UUID?
    let fixedServiceCallID: UUID?

    @State private var title: String
    @State private var taskDescription: String
    @State private var priority: BusinessTaskPriority
    @State private var assignedToEmail: String
    @State private var dueAt: Date
    @State private var selectedCustomerID: UUID?
    @State private var selectedServiceCallID: UUID?
    @State private var message: String?

    init(task: BusinessTask?, fixedCustomerID: UUID?, fixedServiceCallID: UUID?) {
        self.task = task
        self.fixedCustomerID = fixedCustomerID
        self.fixedServiceCallID = fixedServiceCallID
        _title = State(initialValue: task?.title ?? "")
        _taskDescription = State(initialValue: task?.taskDescription ?? "")
        _priority = State(initialValue: task?.priority ?? .normal)
        _assignedToEmail = State(initialValue: task?.assignedToEmail ?? AppAccess.normalizedEmail(AppIdentity.currentEmail))
        _dueAt = State(initialValue: task?.dueAt ?? Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        _selectedCustomerID = State(initialValue: fixedCustomerID ?? task?.customerID)
        _selectedServiceCallID = State(initialValue: fixedServiceCallID ?? task?.serviceCallID)
    }

    private var currentEmail: String? { AppIdentity.currentEmail }
    private var currentRole: AppUserRole? { AppAccess.activeRole(email: currentEmail, users: users) }
    private var visibleServiceCallIDs: Set<UUID> {
        AppAccess.visibleServiceCallIDs(email: currentEmail, users: users, serviceCalls: serviceCalls, technicians: technicians)
    }
    private var availableAssignees: [String] {
        if currentRole == .admin || currentRole == .dispatcher {
            return AppAccess.businessTaskAssigneeEmails(users: users)
        }
        return [AppAccess.normalizedEmail(currentEmail)].filter { !$0.isEmpty }
    }
    private var selectableCalls: [ServiceCall] {
        serviceCalls.filter { call in
            visibleServiceCallIDs.contains(call.id) &&
                (selectedCustomerID == nil || call.customer?.id == selectedCustomerID)
        }
    }
    private var selectedCall: ServiceCall? {
        selectedServiceCallID.flatMap { id in selectableCalls.first { $0.id == id } }
    }
    private var selectedCustomer: Customer? {
        selectedCustomerID.flatMap { id in customers.first { $0.id == id } } ?? selectedCall?.customer
    }
    private var linksAreResolved: Bool {
        (selectedServiceCallID == nil || selectedCall != nil) &&
            (selectedCustomerID == nil || selectedCustomer != nil)
    }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !assignedToEmail.isEmpty &&
            linksAreResolved &&
            AppAccess.canCreateBusinessTask(
                assignedToEmail: assignedToEmail,
                serviceCallID: selectedServiceCallID,
                email: currentEmail,
                users: users,
                visibleServiceCallIDs: visibleServiceCallIDs
            )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("BusinessTaskTitle")
                    TextField("Instructions or follow-up detail", text: $taskDescription, axis: .vertical)
                        .lineLimit(2...6)
                    Picker("Priority", selection: $priority) {
                        ForEach(BusinessTaskPriority.allCases) { priority in
                            Label(priority.displayName, systemImage: priority.systemImage).tag(priority)
                        }
                    }
                    DatePicker("Due", selection: $dueAt)
                    Picker("Assigned To", selection: $assignedToEmail) {
                        ForEach(availableAssignees, id: \.self) { email in
                            Text(AppAccess.inferredDisplayName(fromEmail: email)).tag(email)
                        }
                    }
                }

                if task == nil {
                    Section("Link") {
                        Picker("Customer", selection: $selectedCustomerID) {
                            Text("No customer").tag(UUID?.none)
                            ForEach(customers) { customer in
                                Text(customer.name).tag(UUID?.some(customer.id))
                            }
                        }
                        .disabled(fixedCustomerID != nil)
                        .onChange(of: selectedCustomerID) { _, _ in
                            if fixedServiceCallID == nil,
                               let selectedServiceCallID,
                               !selectableCalls.contains(where: { $0.id == selectedServiceCallID }) {
                                self.selectedServiceCallID = nil
                            }
                        }

                        Picker("Job", selection: $selectedServiceCallID) {
                            Text("No job").tag(UUID?.none)
                            ForEach(selectableCalls) { call in
                                Text("\(call.type.displayName) • \(call.scheduledDate.formatted(date: .abbreviated, time: .omitted))")
                                    .tag(UUID?.some(call.id))
                            }
                        }
                        .disabled(fixedServiceCallID != nil)
                        .onChange(of: selectedServiceCallID) { _, newValue in
                            guard fixedCustomerID == nil,
                                  let newValue,
                                  let call = serviceCalls.first(where: { $0.id == newValue }) else { return }
                            selectedCustomerID = call.customer.id
                        }
                    }
                }

                if let message {
                    Section { Text(message).font(.caption).foregroundStyle(.red) }
                } else if !linksAreResolved {
                    Section {
                        Label("CloudKit is still resolving the selected customer or job. Wait for it to finish syncing, then save.", systemImage: "icloud.and.arrow.down")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(task == nil ? "New Team Task" : "Edit Team Task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(task == nil ? !canSave : !canEditExistingTask)
                        .accessibilityIdentifier("SaveBusinessTask")
                }
            }
        }
    }

    private var canEditExistingTask: Bool {
        guard let task else { return false }
        return AppAccess.canUpdateBusinessTask(task, email: currentEmail, users: users) &&
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !assignedToEmail.isEmpty &&
            (currentRole == .admin || currentRole == .dispatcher || assignedToEmail == AppAccess.normalizedEmail(currentEmail))
    }

    private func save() {
        if let task { update(task) } else { create() }
    }

    private func create() {
        guard canSave else {
            message = "This account cannot create that assignment. Field tasks must stay self-assigned and linked to an accessible job."
            return
        }
        let call = selectedCall
        let customer = selectedCustomer
        let location = call?.serviceLocationID.flatMap { id in serviceLocations.first { $0.id == id } }
        var insertedTask: BusinessTask?
        var insertedEvent: BusinessTaskEvent?
        do {
            let created = try BusinessTaskPolicy.makeTask(
                title: title,
                taskDescription: taskDescription,
                priority: priority,
                assignedToEmail: assignedToEmail,
                dueAt: dueAt,
                customerID: customer?.id,
                customerName: customer?.name,
                serviceLocationID: call?.serviceLocationID,
                serviceLocationName: location?.displayName,
                serviceCallID: call?.id,
                serviceCallSummary: call.map { "\($0.type.displayName) • \($0.scheduledDate.formatted(date: .abbreviated, time: .omitted))" },
                actorEmail: currentEmail
            )
            insertedTask = created.task
            insertedEvent = created.event
            modelContext.insert(created.task)
            modelContext.insert(created.event)
            try modelContext.save()
            dismiss()
        } catch {
            if let insertedEvent { modelContext.delete(insertedEvent) }
            if let insertedTask { modelContext.delete(insertedTask) }
            message = error.localizedDescription
        }
    }

    private func update(_ task: BusinessTask) {
        guard canEditExistingTask else {
            message = "This account can update only its own assigned task."
            return
        }
        let priorTitle = task.title
        let priorDescription = task.taskDescription
        let priorPriority = task.priority
        let priorAssignee = task.assignedToEmail
        let priorDueAt = task.dueAt
        let priorUpdatedAt = task.updatedAt
        var insertedEvent: BusinessTaskEvent?
        do {
            let event = try BusinessTaskPolicy.update(
                task,
                title: title,
                taskDescription: taskDescription,
                priority: priority,
                assignedToEmail: assignedToEmail,
                dueAt: dueAt,
                actorEmail: currentEmail
            )
            insertedEvent = event
            modelContext.insert(event)
            try modelContext.save()
            dismiss()
        } catch {
            if let insertedEvent { modelContext.delete(insertedEvent) }
            task.title = priorTitle
            task.taskDescription = priorDescription
            task.priority = priorPriority
            task.assignedToEmail = priorAssignee
            task.dueAt = priorDueAt
            task.updatedAt = priorUpdatedAt
            message = error.localizedDescription
        }
    }
}
