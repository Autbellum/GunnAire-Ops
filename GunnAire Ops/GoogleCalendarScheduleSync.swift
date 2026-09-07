import Foundation
import SwiftData

@MainActor
enum GoogleCalendarScheduleSync {
    struct ImportSummary {
        let importedCount: Int
        let restrictedReviewCount: Int
    }

    private static let deletedCalendarEventKeysStorageKey = "GunnAireDeletedGoogleCalendarEventKeys"
    private static let locallyEditedCalendarCallIDsStorageKey = "GunnAireLocallyEditedGoogleCalendarCallIDs"

    static func shouldQuarantineImportedCalendarEvent(
        existingCallFound: Bool,
        hasSchedulingBlocker: Bool
    ) -> Bool {
        !existingCallFound && hasSchedulingBlocker
    }

    static func operationalCustomerForCalendarImport(
        existingCall: ServiceCall?,
        matchedCustomer: Customer?
    ) -> Customer? {
        existingCall?.customer ?? matchedCustomer
    }

    static func markCalendarEventDeleted(calendarID: String?, eventID: String?) {
        guard let eventID, !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var deletedKeys = Set(UserDefaults.standard.stringArray(forKey: deletedCalendarEventKeysStorageKey) ?? [])
        deletedKeys.insert(calendarEventStorageKey(calendarID: calendarID, eventID: eventID))
        UserDefaults.standard.set(Array(deletedKeys), forKey: deletedCalendarEventKeysStorageKey)
    }

    static func isCalendarEventDeleted(calendarID: String?, eventID: String?) -> Bool {
        guard let eventID, !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let deletedKeys = Set(UserDefaults.standard.stringArray(forKey: deletedCalendarEventKeysStorageKey) ?? [])
        return deletedKeys.contains(calendarEventStorageKey(calendarID: calendarID, eventID: eventID))
    }

    static func markCalendarCallLocallyEdited(_ call: ServiceCall) {
        guard shouldAllowGoogleCalendarWrite(for: call) else { return }
        let hasCalendarLink = call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
            call.googleCalendarID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasCalendarLink else { return }
        var callIDs = Set(UserDefaults.standard.stringArray(forKey: locallyEditedCalendarCallIDsStorageKey) ?? [])
        callIDs.insert(call.id.uuidString)
        UserDefaults.standard.set(Array(callIDs), forKey: locallyEditedCalendarCallIDsStorageKey)
    }

    private static func isCalendarCallLocallyEdited(_ call: ServiceCall) -> Bool {
        let callIDs = Set(UserDefaults.standard.stringArray(forKey: locallyEditedCalendarCallIDsStorageKey) ?? [])
        return callIDs.contains(call.id.uuidString)
    }

    private static func clearCalendarCallLocallyEdited(_ call: ServiceCall) {
        var callIDs = Set(UserDefaults.standard.stringArray(forKey: locallyEditedCalendarCallIDsStorageKey) ?? [])
        guard callIDs.remove(call.id.uuidString) != nil else { return }
        UserDefaults.standard.set(Array(callIDs), forKey: locallyEditedCalendarCallIDsStorageKey)
    }

    private static func calendarEventStorageKey(calendarID: String?, eventID: String) -> String {
        "\((calendarID ?? "primary").trimmingCharacters(in: .whitespacesAndNewlines))|\(eventID)"
    }

    static func sync(
        auth: GoogleAuthManager, modelContext: ModelContext, signedInEmail: String?, isAdminUser: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        startWorkflow(auth: auth, context: modelContext, email: signedInEmail, completion: completion) {
            try await importSchedule(workflow: $0)
        }
    }

    static func exportImmediately(
        call: ServiceCall, auth: GoogleAuthManager, modelContext: ModelContext,
        signedInEmail: String?, isAdminUser: Bool,
        completion: ((Result<String, Error>) -> Void)? = nil
    ) {
        startWorkflow(auth: auth, context: modelContext, email: signedInEmail, completion: completion) {
            try await publish(call: call, workflow: $0)
        }
    }

    static func cancelManagedEventImmediately(
        for call: ServiceCall, auth: GoogleAuthManager, modelContext: ModelContext,
        completion: ((Result<String, Error>) -> Void)? = nil
    ) {
        startWorkflow(auth: auth, context: modelContext, email: AppIdentity.currentEmail, completion: completion) {
            try await cancel(call: call, workflow: $0)
        }
    }

    private static func startWorkflow(
        auth: GoogleAuthManager, context: ModelContext, email: String?,
        completion: ((Result<String, Error>) -> Void)?,
        action: @escaping (GoogleCalendarWorkflow) async throws -> String
    ) {
        do {
            // Capture before Task scheduling; a later callback cannot capture a
            // replacement provider for an old retained job.
            let workflow = try GoogleCalendarWorkflow(auth: auth, context: context, signedInEmail: email)
            Task { @MainActor in
                let result = await workflow.run(action)
                completion?(result)
            }
        } catch { completion?(.failure(error)) }
    }

    static func deleteImmediately(call: ServiceCall, auth: GoogleAuthManager, modelContext: ModelContext,
                                  completion: @escaping (Result<String, Error>) -> Void) {
        startWorkflow(auth: auth, context: modelContext, email: AppIdentity.currentEmail, completion: completion) {
            try await remove(call: call, workflow: $0)
        }
    }

    static func validateRemoval(_ call: ServiceCall, context: ModelContext) throws {
        let calls = try context.fetch(FetchDescriptor<ServiceCall>())
        guard calls.contains(where: { $0 === call }) else { throw GoogleCalendarWorkflowError.changed }
        let id = call.id
        guard call.status == .scheduled, call.linkedInvoiceID == nil, call.linkedEstimateID == nil,
              call.maintenanceAgreementID == nil, call.originatingServiceCallID == nil,
              call.scheduledFollowUpServiceCallID == nil,
              !calls.contains(where: { $0.originatingServiceCallID == id || $0.scheduledFollowUpServiceCallID == id }),
              try !context.fetch(FetchDescriptor<Invoice>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<Estimate>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<TimeEntry>()).contains(where: { $0.serviceCall?.id == id }),
              try !context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<InventoryMovement>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<PurchaseOrder>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<FieldFormResponse>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<FieldExpenseClaim>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<CustomerCommunication>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<BusinessTask>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<ServiceRequest>()).contains(where: { $0.convertedServiceCallID == id }),
              try !context.fetch(FetchDescriptor<RecurringMaintenanceContract>()).contains(where: { $0.lifecycle?.sourceServiceCallID == id }),
              try !context.fetch(FetchDescriptor<ServiceCallActivity>()).contains(where: { $0.serviceCallID == id }) else {
            throw GoogleCalendarWorkflowError.hasJobHistory
        }
    }

    static func removeLocalEntry(_ call: ServiceCall, context: ModelContext,
                                 save: (() throws -> Void)? = nil) throws {
        try validateRemoval(call, context: context)
        // The narrowly scoped rollback below is allowed only with no preexisting
        // unsaved work, and no await between this check, deletion and save.
        guard !context.hasChanges else { throw GoogleCalendarWorkflowError.changed }
        let calendarID = call.googleCalendarID, eventID = call.googleEventID
        context.delete(call)
        do {
            if let save { try save() } else { try context.save() }
        } catch {
            context.rollback()
            throw GoogleCalendarWorkflowError.saveFailed
        }
        markCalendarEventDeleted(calendarID: calendarID, eventID: eventID)
    }

    static func remove(call: ServiceCall, workflow: GoogleCalendarWorkflow) async throws -> String {
        try requireCall(call, workflow: workflow)
        try validateRemoval(call, context: workflow.context)
        guard !workflow.context.hasChanges else { throw GoogleCalendarWorkflowError.changed }
        workflow.setAdditionalValidation {
            try validateRemoval(call, context: workflow.context)
            guard !workflow.context.hasChanges else { throw GoogleCalendarWorkflowError.changed }
        }
        defer { workflow.setAdditionalValidation(nil) }
        guard shouldAttemptManagedCalendarDeletion(for: call), let id = normalizedOptional(call.googleEventID) else {
            throw GoogleCalendarWorkflowError.needsReview
        }
        let list = try await calendars(workflow: workflow)
        let calendar = try canonicalCalendar(call.googleCalendarID, in: list, email: workflow.signedInEmail)
        guard calendar.isWritable else { throw GoogleCalendarWorkflowError.readOnly }
        let remote: GoogleCalendarEvent?
        do {
            remote = try await workflow.receive {
                workflow.auth.fetchCalendarEvent(calendarID: calendar.id, eventID: id,
                    operation: workflow.operation, completion: $0)
            }
        } catch GoogleAuthError.http(statusCode: 404) { remote = nil }
        if let remote {
            try validateRemote(remote, id: id, call: call)
            let version = try etag(remote)
            let _: Void = try await workflow.receive {
                workflow.auth.deleteCalendarEvent(calendarID: calendar.id, eventID: id,
                    ifMatch: version, operation: workflow.operation, completion: $0)
            }
        }
        try requireCall(call, workflow: workflow)
        workflow.setAdditionalValidation(nil)
        try removeLocalEntry(call, context: workflow.context, save: { try workflow.saveChanges() })
        return remote == nil ? "Removed the local entry. The original calendar no longer returned this event." :
            "Deleted the event from the app and its original Google Calendar."
    }

    private static func calendars(workflow: GoogleCalendarWorkflow) async throws -> [GoogleCalendar] {
        let values: [GoogleCalendar] = try await workflow.receive {
            workflow.auth.fetchCalendars(operation: workflow.operation, completion: $0)
        }
        let filtered = values.filter { !isExcludedCalendarID($0.id) }
        guard filtered.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(filtered.map(\.id)).count == filtered.count,
              filtered.filter({ $0.primary == true }).count <= 1 else {
            throw GoogleCalendarWorkflowError.identity
        }
        return filtered
    }

    private static func canonicalCalendar(_ requested: String?, in calendars: [GoogleCalendar],
                                          email: String?) throws -> GoogleCalendar {
        let requested = normalizedOptional(requested) ?? "primary"
        let matches: [GoogleCalendar]
        if requested == "primary" {
            let primary = calendars.filter { $0.primary == true }
            matches = primary.isEmpty ? calendars.filter { $0.normalizedID == normalized(email ?? "") } : primary
        } else {
            matches = calendars.filter { $0.id == requested }
        }
        guard matches.count == 1, let calendar = matches.first else { throw GoogleCalendarWorkflowError.readOnly }
        return calendar
    }

    static func importSchedule(workflow: GoogleCalendarWorkflow) async throws -> String {
        let calendars = try await calendars(workflow: workflow)
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        let end = Calendar.current.date(byAdding: .day, value: 90, to: now) ?? now
        var events: [(calendarID: String, event: GoogleCalendarEvent)] = []
        // A single retained operation covers every calendar and every page.
        // Do not enumerate "primary" again as an alias of an actual calendar.
        for calendar in calendars.sorted(by: { $0.id < $1.id }) {
            let values: [GoogleCalendarEvent] = try await workflow.receive {
                workflow.auth.fetchCalendarEvents(calendarID: calendar.id, timeMin: start, timeMax: end,
                    operation: workflow.operation, completion: $0)
            }
            events += values.map { (calendar.id, $0) }
        }
        try workflow.check()
        let primaryID = try? canonicalCalendar("primary", in: calendars, email: workflow.signedInEmail).id
        let summary = try importEvents(events, into: workflow.context,
            signedInEmail: workflow.signedInEmail, primaryCalendarID: primaryID, save: { try workflow.saveChanges() })
        let review = summary.restrictedReviewCount == 0 ? "" :
            " \(summary.restrictedReviewCount) event(s) need office review; existing jobs and restricted customers were not reassigned."
        return "Imported \(summary.importedCount) Google Calendar events. Existing job details and local schedule edits were retained.\(review)"
    }

    private static func requireCall(_ call: ServiceCall, workflow: GoogleCalendarWorkflow) throws {
        try workflow.check()
        let calls = try workflow.context.fetch(FetchDescriptor<ServiceCall>())
        guard calls.contains(where: { $0 === call }) else { throw GoogleCalendarWorkflowError.changed }
        guard calls.filter({ $0.id == call.id }).count == 1,
              let customer = call.customer,
              try workflow.context.fetch(FetchDescriptor<Customer>()).contains(where: { $0 === customer }) else {
            throw GoogleCalendarWorkflowError.identity
        }
    }

    static func eventID(for callID: UUID) -> String {
        "ga" + callID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func validateRemote(_ event: GoogleCalendarEvent, id: String, call: ServiceCall) throws {
        guard event.id == id, event.status != "cancelled", event.isManagedByGunnAire else {
            throw GoogleCalendarWorkflowError.needsReview
        }
        if let marker = event.extendedProperties?.privateProperties?["gunnaireServiceCallID"] {
            guard marker == call.id.uuidString else { throw GoogleCalendarWorkflowError.identity }
        } else if id == eventID(for: call.id) {
            throw GoogleCalendarWorkflowError.identity
        }
    }

    private static func etag(_ event: GoogleCalendarEvent) throws -> String {
        guard let value = event.etag, !value.isEmpty, value != "*",
              !value.contains("\r"), !value.contains("\n") else { throw GoogleCalendarWorkflowError.needsReview }
        return value
    }

    static func publish(call: ServiceCall, workflow: GoogleCalendarWorkflow) async throws -> String {
        try requireCall(call, workflow: workflow)
        guard shouldAllowGoogleCalendarWrite(for: call) else { return "Skipped externally managed Google event." }
        guard call.status == .scheduled || call.status == .inProgress,
              call.scheduledDate.timeIntervalSince1970.isFinite, call.duration.isFinite, call.duration > 0,
              call.scheduledDate.addingTimeInterval(call.duration).timeIntervalSince1970.isFinite else {
            throw GoogleCalendarWorkflowError.invalidDates
        }
        let list = try await calendars(workflow: workflow)
        let calendar = try canonicalCalendar(call.googleCalendarID, in: list, email: workflow.signedInEmail)
        guard calendar.isWritable else { throw GoogleCalendarWorkflowError.readOnly }
        try requireCall(call, workflow: workflow)
        let originalID = normalizedOptional(call.googleEventID)
        let id = originalID ?? eventID(for: call.id)
        let remote: GoogleCalendarEvent?
        do {
            remote = try await workflow.receive {
                workflow.auth.fetchCalendarEvent(calendarID: calendar.id, eventID: id,
                    operation: workflow.operation, completion: $0)
            }
        } catch GoogleAuthError.http(statusCode: 404) {
            // Only a never-linked proposal may reserve a first create. A
            // reserved/previously linked missing event is NOT safe to resend.
            guard originalID == nil else { throw GoogleCalendarWorkflowError.needsReview }
            remote = nil
        }
        try requireCall(call, workflow: workflow)
        let saved: GoogleCalendarEvent
        if let remote {
            try validateRemote(remote, id: id, call: call)
            if remoteEventMatchesExactSchedule(call: call, remoteEvent: remote) {
                saved = remote
            } else {
                // Recovery of a previously reserved create must not reprice or
                // move an older uncertain proposal from changed local values.
                if originalID == nil { throw GoogleCalendarWorkflowError.needsReview }
                let version = try etag(remote)
                saved = try await workflow.receive {
                    workflow.auth.patchCalendarEvent(calendarID: calendar.id, eventID: id,
                        patch: makeManagedEventPatch(for: call, remoteEvent: remote), ifMatch: version,
                        operation: workflow.operation, completion: $0)
                }
            }
        } else {
            // Persist the exact route/identity before POST. Restart, a lost
            // response or local confirmation failure retains the original ID.
            let previousCalendar = call.googleCalendarID
            call.googleCalendarID = calendar.id
            call.googleEventID = id
            do { try workflow.saveChanges() }
            catch { call.googleCalendarID = previousCalendar; call.googleEventID = originalID; throw error }
            var proposal = makeCalendarCreateEvent(for: call)
            proposal.id = id
            saved = try await workflow.receive {
                workflow.auth.createCalendarEvent(calendarID: calendar.id, event: proposal,
                    operation: workflow.operation, completion: $0)
            }
        }
        try requireCall(call, workflow: workflow)
        try validateRemote(saved, id: id, call: call)
        guard remoteEventMatchesExactSchedule(call: call, remoteEvent: saved) else {
            throw GoogleCalendarWorkflowError.needsReview
        }
        let previousCalendar = call.googleCalendarID, previousID = call.googleEventID
        call.googleCalendarID = calendar.id
        call.googleEventID = id
        do { try workflow.saveChanges() }
        catch { call.googleCalendarID = previousCalendar; call.googleEventID = previousID; throw error }
        clearCalendarCallLocallyEdited(call)
        return "Saved the appointment in its original Google Calendar."
    }

    static func cancel(call: ServiceCall, workflow: GoogleCalendarWorkflow) async throws -> String {
        try requireCall(call, workflow: workflow)
        guard call.status == .cancelled else { throw GoogleCalendarWorkflowError.changed }
        guard shouldAttemptManagedCalendarDeletion(for: call), let id = normalizedOptional(call.googleEventID) else {
            return "No app-managed Google Calendar event to cancel."
        }
        let list = try await calendars(workflow: workflow)
        let calendar = try canonicalCalendar(call.googleCalendarID, in: list, email: workflow.signedInEmail)
        guard calendar.isWritable else { throw GoogleCalendarWorkflowError.readOnly }
        let remote: GoogleCalendarEvent = try await workflow.receive {
            workflow.auth.fetchCalendarEvent(calendarID: calendar.id, eventID: id,
                operation: workflow.operation, completion: $0)
        }
        try requireCall(call, workflow: workflow)
        try validateRemote(remote, id: id, call: call)
        let version = try etag(remote)
        let _: Void = try await workflow.receive {
            workflow.auth.deleteCalendarEvent(calendarID: calendar.id, eventID: id,
                ifMatch: version, operation: workflow.operation, completion: $0)
        }
        try requireCall(call, workflow: workflow)
        markCalendarEventDeleted(calendarID: calendar.id, eventID: id)
        return "Cancelled the app-managed Google Calendar event."
    }

    private static func remoteEventMatchesExactSchedule(call: ServiceCall, remoteEvent: GoogleCalendarEvent) -> Bool {
        guard let start = parseEventDate(remoteEvent.start), let end = parseEventDate(remoteEvent.end) else { return false }
        return abs(start.timeIntervalSince(call.scheduledDate)) < 0.001 &&
            abs(end.timeIntervalSince(call.scheduledDate.addingTimeInterval(call.duration))) < 0.001
    }

    private struct CalendarImportPlan {
        let calendarID: String
        let event: GoogleCalendarEvent
        let existing: ServiceCall?
        let customer: Customer?
        let technician: Technician?
        let start: Date
        let duration: TimeInterval
        let notes: String?
    }

    static func importEvents(
        _ calendarEvents: [(calendarID: String, event: GoogleCalendarEvent)],
        into modelContext: ModelContext,
        signedInEmail: String?,
        primaryCalendarID: String? = nil,
        save: (() throws -> Void)? = nil
    ) throws -> ImportSummary {
        let calls = try modelContext.fetch(FetchDescriptor<ServiceCall>())
        let customers = try modelContext.fetch(FetchDescriptor<Customer>())
        let technicians = try modelContext.fetch(FetchDescriptor<Technician>())
        let locations = try modelContext.fetch(FetchDescriptor<CustomerServiceLocation>())
        let alerts = try modelContext.fetch(FetchDescriptor<CustomerOperationalAlert>())
        let placeholders = customers.filter(CustomerDataMaintenance.isSystemCalendarCustomer)
        guard placeholders.count <= 1 else { throw GoogleCalendarWorkflowError.identity }
        var placeholder = placeholders.first
        func canonicalID(_ id: String?) -> String {
            let id = normalizedOptional(id) ?? "primary"
            return id == "primary" ? primaryCalendarID ?? id : id
        }
        let linkedCalls = Dictionary(grouping: calls.filter { normalizedOptional($0.googleEventID) != nil }) {
            calendarEventStorageKey(calendarID: canonicalID($0.googleCalendarID), eventID: $0.googleEventID!)
        }
        let customersByEmail = Dictionary(grouping: customers.filter { normalizedOptional($0.email) != nil }) {
            normalized($0.email!)
        }
        let techniciansByEmail = Dictionary(grouping: technicians.filter { normalizedOptional($0.contactInfo) != nil }) {
            normalized($0.contactInfo!)
        }
        var keys: Set<String> = []
        var plans: [CalendarImportPlan] = []
        var reviews = 0
        for entry in calendarEvents {
            let event = entry.event
            let calendarID = canonicalID(entry.calendarID)
            let key = calendarEventStorageKey(calendarID: calendarID, eventID: event.id)
            guard !event.id.isEmpty, keys.insert(key).inserted else { throw GoogleCalendarWorkflowError.identity }
            guard !isCalendarEventDeleted(calendarID: calendarID, eventID: event.id) else { continue }
            guard let start = parseEventDate(event.start), let end = parseEventDate(event.end),
                  start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
                  end > start, event.status != "cancelled" else { reviews += 1; continue }
            let matches = linkedCalls[key] ?? []
            guard matches.count <= 1 else { throw GoogleCalendarWorkflowError.identity }
            let existing = matches.first
            if existing == nil, event.isManagedByGunnAire,
               let marker = event.extendedProperties?.privateProperties?["gunnaireServiceCallID"],
               let callID = UUID(uuidString: marker), calls.contains(where: { $0.id == callID }) {
                throw GoogleCalendarWorkflowError.needsReview
            }
            if let existing {
                // A Google refresh must not move a committed HVAC job, replace
                // its customer/crew, or erase a pending dispatcher edit.
                let protected = existing.googleEventManagedByApp ||
                    isCalendarCallLocallyEdited(existing) || existing.status != .scheduled ||
                    !CustomerDataMaintenance.isSystemCalendarCustomer(existing.customer)
                if protected {
                    if !remoteEventMatchesExactSchedule(call: existing, remoteEvent: event) ||
                        normalizedOptional(existing.eventTitle) != normalizedOptional(event.summary) ||
                        normalizedOptional(existing.siteAddress) != normalizedOptional(event.location) {
                        reviews += 1
                    }
                    continue
                }
            }
            let candidate = inferCustomer(from: event, signedInEmail: signedInEmail,
                technicianEmails: Set(techniciansByEmail.keys))
            // Names, titles and appointment times are not customer identity.
            let customerMatches = candidate?.email.flatMap { customersByEmail[normalized($0)] } ?? []
            let matched = customerMatches.count == 1 ? customerMatches.first : nil
            let locationID = matched.flatMap {
                CustomerServiceLocationPolicy.matchingLocation(address: event.location, customerID: $0.id, in: locations)?.id
            }
            let hold = matched.flatMap {
                CustomerOperationalAlertPolicy.schedulingBlocker(customerID: $0.id, serviceLocationID: locationID, in: alerts)
            }
            let assignedMatches = techniciansByEmail[normalized(calendarID)] ?? []
            let assigned = assignedMatches.count == 1 ? assignedMatches.first : nil
            let review = hold != nil || matched == nil
            if review { reviews += 1 }
            var notes = calendarNotes(description: event.description)
            if let hold {
                notes = [notes, "Office review required. " + CustomerOperationalAlertPolicy.bookingRestrictionMessage(for: hold)]
                    .compactMap { $0 }.joined(separator: "\n\n")
            }
            plans.append(CalendarImportPlan(calendarID: calendarID, event: event, existing: existing,
                customer: hold == nil ? matched : nil, technician: hold == nil ? assigned : nil,
                start: start, duration: end.timeIntervalSince(start), notes: notes))
        }

        var restorations: [() -> Void] = []
        var insertedCalls: [ServiceCall] = []
        var insertedPlaceholder: Customer?
        do {
            for plan in plans {
                let customer: Customer
                if let matched = plan.customer {
                    customer = matched
                } else if let existing = placeholder {
                    customer = existing
                } else {
                    let created = Customer(quickBooksID: CustomerDataMaintenance.unassignedCalendarCustomerMarker,
                        name: CustomerDataMaintenance.unassignedCalendarCustomerName)
                    modelContext.insert(created)
                    placeholder = created
                    insertedPlaceholder = created
                    customer = created
                }
                let call: ServiceCall
                if let existing = plan.existing {
                    call = existing
                    restorations.append(importRestoration(for: existing))
                } else {
                    call = ServiceCall(type: .service, scheduledDate: plan.start, customer: customer)
                    modelContext.insert(call)
                    insertedCalls.append(call)
                }
                call.googleCalendarID = plan.calendarID
                call.googleEventID = plan.event.id
                call.googleEventManagedByApp = plan.event.isManagedByGunnAire
                call.eventTitle = mergedImportedCalendarTitle(remoteValue: plan.event.summary,
                    existingValue: call.eventTitle, isManagedByApp: call.googleEventManagedByApp)
                call.type = inferCallType(from: plan.event.summary, description: plan.event.description)
                call.scheduledDate = plan.start
                call.duration = plan.duration
                call.customer = customer
                call.assignedTechnician = plan.technician
                call.siteAddress = mergedImportedCalendarText(remoteValue: plan.event.location,
                    existingValue: call.siteAddress, isManagedByApp: call.googleEventManagedByApp)
                call.notes = mergedImportedCalendarBody(remoteValue: plan.notes,
                    existingValue: call.notes, isManagedByApp: call.googleEventManagedByApp)
            }
            if !plans.isEmpty {
                if let save { try save() } else { try modelContext.save() }
            }
        } catch {
            // Restore only this batch. Never roll back unrelated unsaved work.
            for restore in restorations.reversed() { restore() }
            for call in insertedCalls { modelContext.delete(call) }
            if let insertedPlaceholder { modelContext.delete(insertedPlaceholder) }
            throw GoogleCalendarWorkflowError.saveFailed
        }
        return ImportSummary(importedCount: plans.count, restrictedReviewCount: reviews)
    }

    private static func importRestoration(for call: ServiceCall) -> () -> Void {
        let calendar = call.googleCalendarID, event = call.googleEventID, managed = call.googleEventManagedByApp
        let title = call.eventTitle, type = call.type, start = call.scheduledDate, duration = call.duration
        let customer = call.customer, technician = call.assignedTechnician, site = call.siteAddress, notes = call.notes
        return {
            call.googleCalendarID = calendar; call.googleEventID = event; call.googleEventManagedByApp = managed
            call.eventTitle = title; call.type = type; call.scheduledDate = start; call.duration = duration
            call.customer = customer; call.assignedTechnician = technician; call.siteAddress = site; call.notes = notes
        }
    }

    static func shouldExportDuringCalendarSync(_ call: ServiceCall) -> Bool {
        call.status != .cancelled && shouldAllowGoogleCalendarWrite(for: call)
    }

    static func shouldAllowGoogleCalendarWrite(for call: ServiceCall) -> Bool {
        call.googleEventManagedByApp
    }

    static func isExternalGoogleCalendarEvent(_ call: ServiceCall) -> Bool {
        call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func shouldPreserveExternalGoogleCalendarDetails(for call: ServiceCall) -> Bool {
        isExternalGoogleCalendarEvent(call)
    }

    static func shouldPublishAfterLocalSave(for call: ServiceCall) -> Bool {
        shouldAllowGoogleCalendarWrite(for: call)
    }

    static func shouldCreateGoogleCalendarEvent(for call: ServiceCall) -> Bool {
        call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
            call.googleEventManagedByApp &&
            shouldAllowGoogleCalendarWrite(for: call)
    }

    static func shouldPatchExistingGoogleCalendarEvent(for call: ServiceCall, remoteEvent: GoogleCalendarEvent?) -> Bool {
        shouldDeleteExistingGoogleCalendarEvent(
            hasGoogleEventID: call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            isLocallyMarkedManagedByApp: call.googleEventManagedByApp,
            remoteEvent: remoteEvent
        )
    }

    static func shouldDeleteExistingGoogleCalendarEvent(for call: ServiceCall, remoteEvent: GoogleCalendarEvent?) -> Bool {
        shouldDeleteExistingGoogleCalendarEvent(
            hasGoogleEventID: call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            isLocallyMarkedManagedByApp: call.googleEventManagedByApp,
            remoteEvent: remoteEvent
        )
    }

    static func shouldDeleteExistingGoogleCalendarEvent(
        hasGoogleEventID: Bool,
        isLocallyMarkedManagedByApp: Bool,
        remoteEvent: GoogleCalendarEvent?
    ) -> Bool {
        hasGoogleEventID && isLocallyMarkedManagedByApp && remoteEvent?.isManagedByGunnAire == true
    }

    static func shouldAttemptManagedCalendarDeletion(for call: ServiceCall) -> Bool {
        call.googleEventManagedByApp &&
            call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func isImportedEventManagedByApp(_ event: GoogleCalendarEvent) -> Bool {
        event.isManagedByGunnAire
    }

    static func shouldSelectGoogleCalendarBeforeCreate(for call: ServiceCall) -> Bool {
        call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
            call.googleEventManagedByApp &&
            shouldAllowGoogleCalendarWrite(for: call)
    }

    static func makeScheduleOnlyPatch(for call: ServiceCall) -> GoogleCalendarEventPatch {
        let timeZone = TimeZone.current.identifier
        let endDate = call.scheduledDate.addingTimeInterval(call.duration)
        return GoogleCalendarEventPatch(
            start: GoogleWritableCalendarEventDate(
                dateTime: ISO8601DateFormatter().string(from: call.scheduledDate),
                timeZone: timeZone
            ),
            end: GoogleWritableCalendarEventDate(
                dateTime: ISO8601DateFormatter().string(from: endDate),
                timeZone: timeZone
            )
        )
    }

    static func makeManagedEventPatch(for call: ServiceCall, remoteEvent _: GoogleCalendarEvent?) -> GoogleCalendarEventPatch {
        makeScheduleOnlyPatch(for: call)
    }

    static func makeCalendarCreateEvent(for call: ServiceCall) -> GoogleWritableCalendarEvent {
        makeGoogleEvent(for: call, existingSummary: nil, preserveExternalDetails: false)
    }

    private static func makeGoogleEvent(
        for call: ServiceCall,
        existingSummary: String?,
        preserveExternalDetails: Bool
    ) -> GoogleWritableCalendarEvent {
        let timeZone = TimeZone.current.identifier
        let endDate = call.scheduledDate.addingTimeInterval(call.duration)
        let summary = calendarEventTitle(for: call, existingSummary: existingSummary)
        let customerEmail = call.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let attendees: [GoogleWritableCalendarAttendee]?
        if !preserveExternalDetails, let customerEmail, !customerEmail.isEmpty {
            attendees = [GoogleWritableCalendarAttendee(email: customerEmail, displayName: call.customer.name)]
        } else {
            attendees = nil
        }
        let eventDescription = preserveExternalDetails ? nil : calendarEventUserDescription(for: call)
        let eventLocation = preserveExternalDetails ? nil : calendarEventLocation(for: call)
        return GoogleWritableCalendarEvent(
            summary: summary,
            description: eventDescription,
            location: eventLocation,
            start: GoogleWritableCalendarEventDate(
                dateTime: ISO8601DateFormatter().string(from: call.scheduledDate),
                timeZone: timeZone
            ),
            end: GoogleWritableCalendarEventDate(
                dateTime: ISO8601DateFormatter().string(from: endDate),
                timeZone: timeZone
            ),
            attendees: attendees,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: [
                "gunnaireManaged": "true",
                "gunnaireManagedVersion": "4",
                "gunnaireServiceCallID": call.id.uuidString,
                "gunnaireOrigin": "ios-app"
            ])
        )
    }

    private static func calendarEventTitle(for call: ServiceCall, existingSummary: String?) -> String {
        let storedTitle = normalizedOptional(call.eventTitle)
        let remoteTitle = normalizedOptional(existingSummary)
        let recoveredTitle = calendarEventSummary(from: call.notes) ?? firstMeaningfulLine(from: call.notes)
        if let storedTitle,
           isGeneratedTypeTitle(storedTitle) {
            if let remoteTitle,
               normalized(storedTitle) != normalized(remoteTitle) {
                return remoteTitle
            }
            if let recoveredTitle,
               normalized(storedTitle) != normalized(recoveredTitle) {
                return recoveredTitle
            }
        }
        return storedTitle
            ?? remoteTitle
            ?? recoveredTitle
            ?? fallbackCalendarTitle(for: call)
    }

    private static func calendarEventLocation(for call: ServiceCall) -> String? {
        normalizedOptional(call.siteAddress) ?? normalizedOptional(call.customer.address)
    }

    private static func calendarEventUserDescription(for call: ServiceCall) -> String? {
        let arrivalWindow = call.promisedArrivalWindowSummary.map { "Customer arrival window: \($0)" }
        let parts = [normalizedOptional(call.notes), arrivalWindow]
            .compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    static func isGeneratedCalendarTitle(_ title: String) -> Bool {
        isGeneratedTypeTitle(title)
    }

    private static func isGeneratedTypeTitle(_ title: String) -> Bool {
        let value = normalized(title)
        let generatedTitles = Set(ServiceCallType.allCases.map { normalized($0.displayName) } + ["service call"])
        return generatedTitles.contains(value)
    }

    private static func fallbackCalendarTitle(for call: ServiceCall) -> String {
        if !CustomerDataMaintenance.isSystemCalendarCustomer(call.customer),
           call.type != .meeting,
           call.type != .reminder,
           call.type != .siteVisit,
           call.type != .other {
            return "\(call.type.displayName): \(call.customer.name)"
        }
        return call.type.displayName
    }

    static func remoteEventMatchesScheduleSlot(call: ServiceCall, remoteEvent: GoogleCalendarEvent) -> Bool {
        guard let remoteStart = parseEventDate(remoteEvent.start),
              let remoteEnd = parseEventDate(remoteEvent.end) else {
            return false
        }
        let callStartMinute = Int(call.scheduledDate.timeIntervalSince1970 / 60)
        let callEndMinute = Int(call.scheduledDate.addingTimeInterval(call.duration).timeIntervalSince1970 / 60)
        let remoteStartMinute = Int(remoteStart.timeIntervalSince1970 / 60)
        let remoteEndMinute = Int(remoteEnd.timeIntervalSince1970 / 60)
        return callStartMinute == remoteStartMinute && callEndMinute == remoteEndMinute
    }

    private static func resolveExistingCustomer(
        for candidate: CalendarCustomerCandidate?,
        customersByEmail: inout [String: Customer],
        customersByName: inout [String: Customer]
    ) -> Customer? {
        guard let candidate else { return nil }
        let nameKey = normalized(candidate.name)
        return candidate.email.flatMap { customersByEmail[$0] } ?? customersByName[nameKey]
    }

    private static func resolveUnassignedCalendarCustomer(
        existing: inout Customer?,
        modelContext: ModelContext
    ) -> Customer {
        if let existing {
            existing.name = CustomerDataMaintenance.unassignedCalendarCustomerName
            existing.quickBooksID = CustomerDataMaintenance.unassignedCalendarCustomerMarker
            return existing
        }
        let customer = Customer(
            quickBooksID: CustomerDataMaintenance.unassignedCalendarCustomerMarker,
            name: CustomerDataMaintenance.unassignedCalendarCustomerName
        )
        modelContext.insert(customer)
        existing = customer
        return customer
    }

    private static func calendarNotes(description: String?) -> String? {
        normalizedCalendarBody(description)
    }

    static func calendarEventSummary(from notes: String?) -> String? {
        guard let firstLine = notes?.components(separatedBy: .newlines).first,
              firstLine.localizedCaseInsensitiveCompare("Calendar event:") != .orderedSame,
              firstLine.localizedCaseInsensitiveContains("Calendar event:") else {
            return nil
        }
        let value = firstLine.replacingOccurrences(of: "Calendar event:", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func mergedImportedCalendarText(remoteValue: String?, existingValue: String?, isManagedByApp: Bool) -> String? {
        let remote = normalizedOptional(remoteValue)
        let existing = normalizedOptional(existingValue)
        if isManagedByApp {
            return remote ?? existing
        }
        return remote ?? existing
    }

    static func mergedImportedCalendarTitle(remoteValue: String?, existingValue: String?, isManagedByApp: Bool) -> String? {
        let remote = normalizedOptional(remoteValue)
        let existing = normalizedOptional(existingValue)
        if isManagedByApp {
            return remote
        }
        guard let remote else { return existing }
        if let existing,
           !isGeneratedTypeTitle(existing),
           isGeneratedTypeTitle(remote) {
            return existing
        }
        return remote
    }

    static func mergedImportedCalendarBody(remoteValue: String?, existingValue: String?, isManagedByApp: Bool) -> String? {
        let remote = normalizedOptional(remoteValue)
        let existing = normalizedOptional(existingValue)
        if isManagedByApp {
            return remote ?? existing
        }
        guard let remote else { return existing }
        if let existing,
           !isGeneratedGunnAireCalendarBody(existing),
           isGeneratedGunnAireCalendarBody(remote) {
            return existing
        }
        return remote
    }

    private static func isGeneratedGunnAireCalendarBody(_ value: String) -> Bool {
        let lines = value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let generatedPrefixes = [
            "customer:",
            "phone:",
            "email:",
            "service address:",
            "call type:",
            "technician:",
            "equipment:",
            "equipment location:"
        ]
        let generatedLineCount = lines.filter { line in
            generatedPrefixes.contains { line.hasPrefix($0) }
        }.count
        return generatedLineCount >= 2 || lines.first?.hasPrefix("call type:") == true
    }

    private static func firstMeaningfulLine(from notes: String?) -> String? {
        guard let notes else { return nil }
        let ignoredPrefixes = ["calendar event:", "scheduled from", "scheduled follow-up"]
        return notes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                guard !line.isEmpty else { return false }
                let lowercased = line.lowercased()
                return !ignoredPrefixes.contains { lowercased.hasPrefix($0) }
            }
    }

    private static func eventFingerprint(
        summary: String?,
        location: String?,
        startDate: Date,
        endDate: Date
    ) -> String {
        [
            normalized(summary ?? ""),
            normalized(location ?? ""),
            String(Int(startDate.timeIntervalSince1970 / 60)),
            String(Int(endDate.timeIntervalSince1970 / 60))
        ].joined(separator: "|")
    }

    private static func eventCollisionKey(for call: ServiceCall) -> String {
        eventCollisionKey(
            summary: calendarEventTitle(for: call, existingSummary: nil),
            startDate: call.scheduledDate,
            endDate: call.scheduledDate.addingTimeInterval(call.duration)
        )
    }

    private static func eventCollisionKey(
        summary: String?,
        startDate: Date,
        endDate: Date
    ) -> String {
        [
            normalized(summary ?? ""),
            String(Int(startDate.timeIntervalSince1970 / 60)),
            String(Int(endDate.timeIntervalSince1970 / 60))
        ].joined(separator: "|")
    }

    private static func parseEventDate(_ value: GoogleCalendarEventDate) -> Date? {
        if let dateTime = value.dateTime {
            return ISO8601DateFormatter().date(from: dateTime)
        }
        if let date = value.date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: date)
        }
        return nil
    }

    private struct CalendarCustomerCandidate {
        let name: String
        let email: String?
        let address: String?
    }

    private static func inferCustomer(
        from event: GoogleCalendarEvent,
        signedInEmail: String?,
        technicianEmails: Set<String>
    ) -> CalendarCustomerCandidate? {
        let normalizedSignedInEmail = signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let excludedEmails = technicianEmails.union([normalizedSignedInEmail].compactMap { $0 })
        if let attendee = event.attendees?.first(where: { attendee in
            guard attendee.selfAttendee != true,
                  attendee.resource != true,
                  let email = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !email.isEmpty,
                  !excludedEmails.contains(email),
                  !email.contains("calendar.google.com"),
                  !email.hasSuffix("@resource.calendar.google.com") else {
                return false
            }
            return true
        }) {
            let email = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let displayName = cleanCustomerName(attendee.displayName, eventSummary: event.summary)
            let fallbackName = email.map(nameFromEmail) ?? "Google Calendar Customer"
            return CalendarCustomerCandidate(
                name: displayName ?? fallbackName,
                email: email,
                address: normalizedOptional(event.location)
            )
        }

        return inferCustomerFromDescription(
            event.description,
            eventSummary: event.summary,
            address: normalizedOptional(event.location)
        )
    }

    private static func nameFromEmail(_ email: String) -> String {
        let localPart = email.components(separatedBy: "@").first ?? email
        let separators = CharacterSet(charactersIn: "._-+")
        let words = localPart
            .components(separatedBy: separators)
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
        return words.isEmpty ? email : words.joined(separator: " ").capitalized
    }

    private static func inferCustomerFromDescription(_ description: String?, eventSummary: String?, address: String?) -> CalendarCustomerCandidate? {
        guard let body = normalizedCalendarBody(description) else { return nil }
        let email = firstEmail(in: body)
        let labeledName = cleanCustomerName(firstLabeledValue(
            in: body,
            labels: ["customer", "customer name", "client", "client name", "name"]
        ), eventSummary: eventSummary)
        let name = labeledName ?? email.map(nameFromEmail)
        guard let name, !name.isEmpty else { return nil }
        return CalendarCustomerCandidate(
            name: name,
            email: email,
            address: address ?? firstLabeledValue(in: body, labels: ["address", "service address", "location"])
        )
    }

    private static func normalizedCalendarBody(_ value: String?) -> String? {
        guard let value else { return nil }
        let withoutBreaks = value
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
        let withoutTags = withoutBreaks.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let decoded = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cleanCustomerName(_ value: String?, eventSummary: String?) -> String? {
        guard let trimmed = normalizedOptional(value),
              !isGenericCustomerName(trimmed, matching: eventSummary) else {
            return nil
        }
        return trimmed
    }

    private static func isGenericCustomerName(_ value: String, matching eventSummary: String?) -> Bool {
        let name = normalized(value)
        guard !name.isEmpty else { return true }
        if let eventSummary, normalized(eventSummary) == name {
            return true
        }

        let genericTitles: Set<String> = [
            "service",
            "service call",
            "install",
            "installation",
            "maintenance",
            "maintenance call",
            "repair",
            "estimate",
            "quote",
            "job",
            "appointment",
            "site visit",
            "tune up",
            "no heat",
            "no cool",
            "ac call",
            "hvac service"
        ]
        return genericTitles.contains(name)
    }

    private static func firstLabeledValue(in body: String, labels: [String]) -> String? {
        let lines = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for line in lines {
            guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "-" }) else { continue }
            let label = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard labels.contains(label) else { continue }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func firstEmail(in body: String) -> String? {
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let range = body.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return String(body[range]).lowercased()
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func inferCallType(from summary: String?, description: String?) -> ServiceCallType {
        let haystack = [summary, description].compactMap { $0?.lowercased() }.joined(separator: " ")
        if haystack.contains("estimate") { return .estimate }
        if haystack.contains("meeting") { return .meeting }
        if haystack.contains("reminder") || haystack.contains("due date") || haystack.contains("deadline") || haystack.contains("holiday") { return .reminder }
        if haystack.contains("site visit") || haystack.contains("walkthrough") || haystack.contains("walk through") { return .siteVisit }
        if haystack.contains("install") { return .install }
        if haystack.contains("maintenance") { return .maintenance }
        if haystack.contains("service") || haystack.contains("repair") || haystack.contains("no heat") || haystack.contains("no cool") || haystack.contains("hvac") {
            return .service
        }
        return .other
    }

    private static func resolveTechnician(
        calendarID: String? = nil,
        signedInEmail: String?,
        techniciansByEmail: inout [String: Technician],
        modelContext: ModelContext
    ) -> Technician? {
        if let calendarID,
           calendarID != "primary",
           calendarID.contains("@") {
            let normalizedCalendarID = calendarID.lowercased()
            if let existing = techniciansByEmail[normalizedCalendarID] {
                return existing
            }
            let inferredName = normalizedCalendarID.components(separatedBy: "@").first?
                .replacingOccurrences(of: ".", with: " ")
                .capitalized ?? normalizedCalendarID
            let technician = Technician(name: inferredName, contactInfo: normalizedCalendarID)
            modelContext.insert(technician)
            techniciansByEmail[normalizedCalendarID] = technician
            return technician
        }
        guard let signedInEmail, !signedInEmail.isEmpty else { return nil }
        if let existing = techniciansByEmail[signedInEmail.lowercased()] {
            return existing
        }
        let inferredName = signedInEmail.components(separatedBy: "@").first?
            .replacingOccurrences(of: ".", with: " ")
            .capitalized ?? signedInEmail
        let technician = Technician(name: inferredName, contactInfo: signedInEmail)
        modelContext.insert(technician)
        techniciansByEmail[signedInEmail.lowercased()] = technician
        return technician
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func preferredCalendarID(
        for call: ServiceCall,
        availableCalendarIDs: Set<String>,
        writableCalendarIDs: Set<String>
    ) -> String? {
        if let existingCalendarID = normalizedOptional(call.googleCalendarID) {
            return contains(existingCalendarID, in: writableCalendarIDs) ? existingCalendarID : nil
        }
        if let technicianCalendarID = call.assignedTechnician?.contactInfo?.trimmingCharacters(in: .whitespacesAndNewlines),
           !technicianCalendarID.isEmpty {
            if contains(technicianCalendarID, in: writableCalendarIDs) {
                return technicianCalendarID
            }
            if contains(technicianCalendarID.lowercased(), in: writableCalendarIDs) {
                return technicianCalendarID.lowercased()
            }
        }
        if contains("primary", in: writableCalendarIDs) {
            return "primary"
        }
        return nil
    }

    private static func isExcludedCalendarID(_ id: String) -> Bool {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Common Google holiday calendars end with or contain "holiday@group.v.calendar.google.com".
        if normalizedID.contains("#holiday@group.v.calendar.google.com") { return true }
        if normalizedID.contains("holiday@group.v.calendar.google.com") { return true }
        // Exclude Contacts/Birthdays calendar as well.
        if normalizedID.contains("addressbook#contacts@group.v.calendar.google.com") { return true }
        return false
    }

    private static func contains(_ calendarID: String, in calendarIDs: Set<String>) -> Bool {
        calendarIDs.contains(calendarID) || calendarIDs.contains(calendarID.lowercased())
    }

}
