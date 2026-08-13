import Foundation
import SwiftData

@MainActor
enum GoogleCalendarScheduleSync {
    private static let deletedCalendarEventKeysStorageKey = "GunnAireDeletedGoogleCalendarEventKeys"
    private static let locallyEditedCalendarCallIDsStorageKey = "GunnAireLocallyEditedGoogleCalendarCallIDs"
    private static let managedCalendarEventProperties = GoogleCalendarExtendedProperties(
        privateProperties: [
            "gunnaireManaged": "true",
            "gunnaireManagedVersion": "3",
            "gunnaireOrigin": "ios-app"
        ]
    )

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
        "\(normalized(calendarID ?? "primary"))|\(normalized(eventID))"
    }

    static func sync(
        auth: GoogleAuthManager,
        modelContext: ModelContext,
        signedInEmail: String?,
        isAdminUser: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let now = Date()
        let calendar = Calendar.current
        let syncStart = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let horizon = calendar.date(byAdding: .day, value: 90, to: now) ?? now
        auth.fetchCalendars { calendarsResult in
            switch calendarsResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let calendars):
                let filteredCalendars = calendars.filter { !isExcludedCalendarID($0.id) }
                let availableCalendarIDs = Set(["primary"] + filteredCalendars.map(\.id))
                let writableCalendarIDs = Set(["primary"] + filteredCalendars.filter(\.isWritable).map(\.id))
                fetchEvents(
                    auth: auth,
                    calendarIDs: Array(availableCalendarIDs),
                    timeMin: syncStart,
                    timeMax: horizon
                ) { fetchResult in
                    switch fetchResult {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let calendarEvents):
                        Task { @MainActor in
                            do {
                                let importedCount = try importEvents(
                                    calendarEvents,
                                    into: modelContext,
                                    signedInEmail: signedInEmail
                                )
                                exportCalls(
                                    auth: auth,
                                    modelContext: modelContext,
                                    calendarEvents: calendarEvents,
                                    signedInEmail: signedInEmail,
                                    isAdminUser: isAdminUser,
                                    availableCalendarIDs: availableCalendarIDs,
                                    writableCalendarIDs: writableCalendarIDs
                                ) { exportResult in
                                    switch exportResult {
                                    case .failure(let error):
                                        completion(.failure(error))
                                    case .success(let exportSummary):
                                        fetchEvents(
                                            auth: auth,
                                            calendarIDs: Array(availableCalendarIDs),
                                            timeMin: syncStart,
                                            timeMax: horizon
                                        ) { refreshedFetchResult in
                                            switch refreshedFetchResult {
                                            case .failure(let error):
                                                completion(.failure(error))
                                            case .success(let refreshedCalendarEvents):
                                                Task { @MainActor in
                                                    do {
                                                        let refreshedImportCount = try importEvents(
                                                            refreshedCalendarEvents,
                                                            into: modelContext,
                                                            signedInEmail: signedInEmail
                                                        )
                                                        completion(.success("\(exportSummary) Imported \(importedCount) Google events before export and refreshed \(refreshedImportCount) events after export."))
                                                    } catch {
                                                        completion(.failure(error))
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            } catch {
                                completion(.failure(error))
                            }
                        }
                    }
            }
        }
    }
    }

    static func exportImmediately(
        call: ServiceCall,
        auth: GoogleAuthManager,
        modelContext: ModelContext,
        signedInEmail: String?,
        isAdminUser: Bool,
        completion: ((Result<String, Error>) -> Void)? = nil
    ) {
        guard shouldPublishAfterLocalSave(for: call) else {
            completion?(.success("Skipped externally managed Google event."))
            return
        }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -1, to: call.scheduledDate) ?? call.scheduledDate
        let end = calendar.date(byAdding: .day, value: 1, to: call.scheduledDate) ?? call.scheduledDate
        auth.fetchCalendars { calendarsResult in
            switch calendarsResult {
            case .failure(let error):
                completion?(.failure(error))
            case .success(let calendars):
                let filteredCalendars = calendars.filter { !isExcludedCalendarID($0.id) }
                let availableCalendarIDs = Set(["primary"] + filteredCalendars.map(\.id))
                let writableCalendarIDs = Set(["primary"] + filteredCalendars.filter(\.isWritable).map(\.id))
                fetchEvents(
                    auth: auth,
                    calendarIDs: Array(availableCalendarIDs),
                    timeMin: start,
                    timeMax: end
                ) { fetchResult in
                    switch fetchResult {
                    case .failure(let error):
                        completion?(.failure(error))
                    case .success(let calendarEvents):
                        Task { @MainActor in
                            do {
                                _ = try importEvents(
                                    calendarEvents,
                                    into: modelContext,
                                    signedInEmail: signedInEmail
                                )
                            } catch {
                                completion?(.failure(error))
                                return
                            }
                            guard shouldPublishAfterLocalSave(for: call) else {
                                completion?(.success("Skipped externally managed Google event."))
                                return
                            }
                            exportNext(
                                index: 0,
                                exportedCount: 0,
                                skippedCount: 0,
                                calls: [call],
                                auth: auth,
                                modelContext: modelContext,
                                remoteEventsByKey: remoteEventsByKey(from: calendarEvents),
                                remoteEventsByFingerprint: remoteEventsByFingerprint(from: calendarEvents, writableCalendarIDs: writableCalendarIDs),
                                availableCalendarIDs: availableCalendarIDs,
                                writableCalendarIDs: writableCalendarIDs,
                                completion: { result in
                                    completion?(result)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private static func importEvents(
        _ calendarEvents: [(calendarID: String, event: GoogleCalendarEvent)],
        into modelContext: ModelContext,
        signedInEmail: String?
    ) throws -> Int {
        let existingCalls = try modelContext.fetch(FetchDescriptor<ServiceCall>())
        let existingCustomers = try modelContext.fetch(FetchDescriptor<Customer>())
        let existingTechnicians = try modelContext.fetch(FetchDescriptor<Technician>())

        var callsByGoogleEventKey: [String: ServiceCall] = [:]
        var callsByGoogleEventID: [String: ServiceCall] = [:]
        var callsByFingerprint: [String: ServiceCall] = [:]
        for call in existingCalls {
            if let eventID = call.googleEventID, !eventID.isEmpty {
                let eventKey = calendarEventStorageKey(calendarID: call.googleCalendarID, eventID: eventID)
                callsByGoogleEventKey[eventKey] = callsByGoogleEventKey[eventKey] ?? call
                callsByGoogleEventID[eventID] = callsByGoogleEventID[eventID] ?? call
            }
            let fingerprint = eventFingerprint(for: call)
            callsByFingerprint[fingerprint] = callsByFingerprint[fingerprint] ?? call
        }
        var importedEventKeys: Set<String> = []
        var importedEventFingerprints: Set<String> = []
        var customersByName: [String: Customer] = [:]
        for customer in existingCustomers {
            let nameKey = normalized(customer.name)
            if !nameKey.isEmpty, customersByName[nameKey] == nil {
                customersByName[nameKey] = customer
            }
        }
        var customersByEmail: [String: Customer] = [:]
        for customer in existingCustomers {
            guard let email = customer.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !email.isEmpty,
                  customersByEmail[email] == nil else { continue }
            customersByEmail[email] = customer
        }
        var unassignedCalendarCustomer = existingCustomers.first(where: CustomerDataMaintenance.isSystemCalendarCustomer)
        var techniciansByEmail: [String: Technician] = [:]
        for technician in existingTechnicians {
            guard let email = technician.contactInfo?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !email.isEmpty,
                  techniciansByEmail[email] == nil else { continue }
            techniciansByEmail[email] = technician
        }

        let technician = resolveTechnician(signedInEmail: signedInEmail, techniciansByEmail: &techniciansByEmail, modelContext: modelContext)
        var imported = 0

        for calendarEvent in calendarEvents {
            let event = calendarEvent.event
            let eventKey = calendarEventStorageKey(calendarID: calendarEvent.calendarID, eventID: event.id)
            guard !isCalendarEventDeleted(calendarID: calendarEvent.calendarID, eventID: event.id),
                  importedEventKeys.insert(eventKey).inserted else {
                continue
            }
            guard let startDate = parseEventDate(event.start), let endDate = parseEventDate(event.end) else {
                continue
            }
            let fingerprint = eventFingerprint(
                summary: event.summary,
                location: event.location,
                startDate: startDate,
                endDate: endDate
            )
            guard importedEventFingerprints.insert(fingerprint).inserted else {
                continue
            }
            let duration = max(endDate.timeIntervalSince(startDate), 1800)
            let customerCandidate = inferCustomer(
                from: event,
                signedInEmail: signedInEmail,
                technicianEmails: Set(techniciansByEmail.keys)
            )
            let customer = resolveExistingCustomer(
                for: customerCandidate,
                customersByEmail: &customersByEmail,
                customersByName: &customersByName
            ) ?? resolveUnassignedCalendarCustomer(
                existing: &unassignedCalendarCustomer,
                modelContext: modelContext
            )
            if let customerCandidate,
               !CustomerDataMaintenance.isSystemCalendarCustomer(customer) {
                if customer.email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    customer.email = customerCandidate.email
                }
                if customer.address?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                   let address = customerCandidate.address,
                   !address.isEmpty {
                    customer.address = address
                }
                customersByName[normalized(customer.name)] = customer
                customersByName[normalized(customerCandidate.name)] = customer
                if let email = customer.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                   !email.isEmpty {
                    customersByEmail[email] = customer
                }
            }
            let eventNotes = calendarNotes(description: event.description)
            let isManagedByApp = isImportedEventManagedByApp(event)

            let call = callsByGoogleEventKey[eventKey] ?? callsByGoogleEventID[event.id] ?? callsByFingerprint[fingerprint] ?? ServiceCall(
                googleCalendarID: calendarEvent.calendarID,
                googleEventID: event.id,
                googleEventManagedByApp: isManagedByApp,
                eventTitle: normalizedOptional(event.summary),
                siteAddress: event.location,
                type: inferCallType(from: event.summary, description: event.description),
                scheduledDate: startDate,
                duration: duration,
                assignedTechnician: resolveTechnician(
                    calendarID: calendarEvent.calendarID,
                    signedInEmail: signedInEmail,
                    techniciansByEmail: &techniciansByEmail,
                    modelContext: modelContext
                ) ?? technician,
                customer: customer,
                status: .scheduled,
                notes: eventNotes
            )
            if call.modelContext == nil {
                modelContext.insert(call)
            }
            call.googleCalendarID = calendarEvent.calendarID
            call.googleEventID = event.id
            call.googleEventManagedByApp = isManagedByApp
            if !isManagedByApp {
                clearCalendarCallLocallyEdited(call)
            }
            call.eventTitle = mergedImportedCalendarText(
                remoteValue: event.summary,
                existingValue: call.eventTitle,
                isManagedByApp: isManagedByApp
            )
            call.type = inferCallType(from: event.summary, description: event.description)
            call.scheduledDate = startDate
            call.duration = duration
            call.assignedTechnician = resolveTechnician(
                calendarID: calendarEvent.calendarID,
                signedInEmail: signedInEmail,
                techniciansByEmail: &techniciansByEmail,
                modelContext: modelContext
            ) ?? technician
            call.customer = customer
            call.siteAddress = mergedImportedCalendarText(
                remoteValue: event.location,
                existingValue: call.siteAddress,
                isManagedByApp: isManagedByApp
            )
            call.notes = mergedImportedCalendarText(
                remoteValue: eventNotes,
                existingValue: call.notes,
                isManagedByApp: isManagedByApp
            )
            callsByGoogleEventKey[eventKey] = call
            callsByGoogleEventID[event.id] = call
            callsByFingerprint[fingerprint] = call
            imported += 1
        }

        try? modelContext.save()
        return imported
    }

    private static func exportCalls(
        auth: GoogleAuthManager,
        modelContext: ModelContext,
        calendarEvents: [(calendarID: String, event: GoogleCalendarEvent)],
        signedInEmail: String?,
        isAdminUser: Bool,
        availableCalendarIDs: Set<String>,
        writableCalendarIDs: Set<String>,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        do {
            let calls = try modelContext.fetch(FetchDescriptor<ServiceCall>())
                .filter { call in
                    guard shouldConsiderForGoogleCalendarExport(call) else {
                        return false
                    }
                    if CustomerDataMaintenance.isSystemCalendarCustomer(call.customer) {
                        return shouldExportSystemCalendarCall(call)
                    }
                    if isAdminUser {
                        return true
                    }
                    if let email = signedInEmail?.lowercased(),
                       let technicianEmail = call.assignedTechnician?.contactInfo?.lowercased(),
                       technicianEmail != email {
                        return false
                    }
                    return true
                }
                .sorted { $0.scheduledDate < $1.scheduledDate }

            exportNext(
                index: 0,
                exportedCount: 0,
                skippedCount: 0,
                calls: calls,
                auth: auth,
                modelContext: modelContext,
                remoteEventsByKey: remoteEventsByKey(from: calendarEvents),
                remoteEventsByFingerprint: remoteEventsByFingerprint(from: calendarEvents, writableCalendarIDs: writableCalendarIDs),
                availableCalendarIDs: availableCalendarIDs,
                writableCalendarIDs: writableCalendarIDs,
                completion: completion
            )
        } catch {
            completion(.failure(error))
        }
    }

    private static func shouldConsiderForGoogleCalendarExport(_ call: ServiceCall) -> Bool {
        if isExternalGoogleCalendarEvent(call) {
            return false
        }
        return shouldPublishAfterLocalSave(for: call)
    }

    private static func shouldExportSystemCalendarCall(_ call: ServiceCall) -> Bool {
        guard shouldConsiderForGoogleCalendarExport(call) else {
            return false
        }
        if call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        if call.eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        switch call.type {
        case .meeting, .reminder, .siteVisit, .other:
            return true
        case .service, .estimate, .install, .maintenance:
            return false
        }
    }

    private static func exportNext(
        index: Int,
        exportedCount: Int,
        skippedCount: Int,
        calls: [ServiceCall],
        auth: GoogleAuthManager,
        modelContext: ModelContext,
        remoteEventsByKey: [String: (calendarID: String, event: GoogleCalendarEvent)],
        remoteEventsByFingerprint: [String: (calendarID: String, event: GoogleCalendarEvent)],
        availableCalendarIDs: Set<String>,
        writableCalendarIDs: Set<String>,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard index < calls.count else {
            try? modelContext.save()
            let message: String
            if skippedCount > 0 {
                message = "Exported \(exportedCount) service calls and skipped \(skippedCount) read-only or externally managed Google events."
            } else {
                message = "Exported \(exportedCount) service calls."
            }
            completion(.success(message))
            return
        }

        let call = calls[index]
        if !shouldAllowGoogleCalendarWrite(for: call) {
            exportNext(
                index: index + 1,
                exportedCount: exportedCount,
                skippedCount: skippedCount + 1,
                calls: calls,
                auth: auth,
                modelContext: modelContext,
                remoteEventsByKey: remoteEventsByKey,
                remoteEventsByFingerprint: remoteEventsByFingerprint,
                availableCalendarIDs: availableCalendarIDs,
                writableCalendarIDs: writableCalendarIDs,
                completion: completion
            )
            return
        }

        if let eventID = call.googleEventID,
           !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let currentCalendarID = call.googleCalendarID,
           !contains(currentCalendarID, in: writableCalendarIDs) {
            exportNext(
                index: index + 1,
                exportedCount: exportedCount,
                skippedCount: skippedCount + 1,
                calls: calls,
                auth: auth,
                modelContext: modelContext,
                remoteEventsByKey: remoteEventsByKey,
                remoteEventsByFingerprint: remoteEventsByFingerprint,
                availableCalendarIDs: availableCalendarIDs,
                writableCalendarIDs: writableCalendarIDs,
                completion: completion
            )
            return
        }

        let targetCalendarID = preferredCalendarID(
            for: call,
            availableCalendarIDs: availableCalendarIDs,
            writableCalendarIDs: writableCalendarIDs
        )

        guard let targetCalendarID else {
            exportNext(
                index: index + 1,
                exportedCount: exportedCount,
                skippedCount: skippedCount + 1,
                calls: calls,
                auth: auth,
                modelContext: modelContext,
                remoteEventsByKey: remoteEventsByKey,
                remoteEventsByFingerprint: remoteEventsByFingerprint,
                availableCalendarIDs: availableCalendarIDs,
                writableCalendarIDs: writableCalendarIDs,
                completion: completion
            )
            return
        }

        let finish: (String, Result<GoogleCalendarEvent, Error>) -> Void = { savedCalendarID, result in
            Task { @MainActor in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let saved):
                    call.googleCalendarID = savedCalendarID
                    call.googleEventID = saved.id
                    clearCalendarCallLocallyEdited(call)
                    exportNext(
                        index: index + 1,
                        exportedCount: exportedCount + 1,
                        skippedCount: skippedCount,
                        calls: calls,
                        auth: auth,
                        modelContext: modelContext,
                        remoteEventsByKey: remoteEventsByKey,
                        remoteEventsByFingerprint: remoteEventsByFingerprint,
                        availableCalendarIDs: availableCalendarIDs,
                        writableCalendarIDs: writableCalendarIDs,
                        completion: completion
                    )
                }
            }
        }

        let currentCalendarID = call.googleCalendarID ?? targetCalendarID

        if let eventID = call.googleEventID,
           !eventID.isEmpty {
            guard contains(currentCalendarID, in: writableCalendarIDs) else {
                exportNext(
                    index: index + 1,
                    exportedCount: exportedCount,
                    skippedCount: skippedCount + 1,
                    calls: calls,
                    auth: auth,
                    modelContext: modelContext,
                    remoteEventsByKey: remoteEventsByKey,
                    remoteEventsByFingerprint: remoteEventsByFingerprint,
                    availableCalendarIDs: availableCalendarIDs,
                    writableCalendarIDs: writableCalendarIDs,
                    completion: completion
                )
                return
            }
            let eventKey = calendarEventStorageKey(calendarID: currentCalendarID, eventID: eventID)
            let remoteEvent = remoteEventsByKey[eventKey]?.event
            guard shouldPatchExistingGoogleCalendarEvent(
                for: call,
                remoteEvent: remoteEvent
            ) else {
                call.googleEventManagedByApp = false
                clearCalendarCallLocallyEdited(call)
                exportNext(
                    index: index + 1,
                    exportedCount: exportedCount,
                    skippedCount: skippedCount + 1,
                    calls: calls,
                    auth: auth,
                    modelContext: modelContext,
                    remoteEventsByKey: remoteEventsByKey,
                    remoteEventsByFingerprint: remoteEventsByFingerprint,
                    availableCalendarIDs: availableCalendarIDs,
                    writableCalendarIDs: writableCalendarIDs,
                    completion: completion
                )
                return
            }
            guard isCalendarCallLocallyEdited(call) else {
                exportNext(
                    index: index + 1,
                    exportedCount: exportedCount,
                    skippedCount: skippedCount,
                    calls: calls,
                    auth: auth,
                    modelContext: modelContext,
                    remoteEventsByKey: remoteEventsByKey,
                    remoteEventsByFingerprint: remoteEventsByFingerprint,
                    availableCalendarIDs: availableCalendarIDs,
                    writableCalendarIDs: writableCalendarIDs,
                    completion: completion
                )
                return
            }
            call.googleEventManagedByApp = true
            let patch = makeManagedEventPatch(for: call, remoteEvent: remoteEvent)
            auth.patchCalendarEvent(calendarID: currentCalendarID, eventID: eventID, patch: patch) { result in
                finish(currentCalendarID, result)
            }
        } else if let remote = remoteEventsByFingerprint[eventFingerprint(for: call)],
                  remote.event.isManagedByGunnAire,
                  contains(remote.calendarID, in: writableCalendarIDs) {
            call.googleCalendarID = remote.calendarID
            call.googleEventID = remote.event.id
            call.googleEventManagedByApp = remote.event.isManagedByGunnAire
            clearCalendarCallLocallyEdited(call)
            exportNext(
                index: index + 1,
                exportedCount: exportedCount,
                skippedCount: skippedCount,
                calls: calls,
                auth: auth,
                modelContext: modelContext,
                remoteEventsByKey: remoteEventsByKey,
                remoteEventsByFingerprint: remoteEventsByFingerprint,
                availableCalendarIDs: availableCalendarIDs,
                writableCalendarIDs: writableCalendarIDs,
                completion: completion
            )
        } else {
            let event = makeCalendarCreateEvent(for: call)
            auth.createCalendarEvent(calendarID: targetCalendarID, event: event) { result in
                if case .success = result {
                    call.googleEventManagedByApp = true
                }
                finish(targetCalendarID, result)
            }
        }
    }

    static func shouldAllowGoogleCalendarWrite(for call: ServiceCall) -> Bool {
        guard call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return true
        }
        return call.googleEventManagedByApp
    }

    static func isExternalGoogleCalendarEvent(_ call: ServiceCall) -> Bool {
        call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            !call.googleEventManagedByApp
    }

    static func shouldPreserveExternalGoogleCalendarDetails(for call: ServiceCall) -> Bool {
        isExternalGoogleCalendarEvent(call)
    }

    static func shouldPublishAfterLocalSave(for call: ServiceCall) -> Bool {
        shouldAllowGoogleCalendarWrite(for: call)
    }

    static func shouldPatchExistingGoogleCalendarEvent(for call: ServiceCall, remoteEvent: GoogleCalendarEvent?) -> Bool {
        shouldAllowGoogleCalendarWrite(for: call) && remoteEvent?.isManagedByGunnAire == true
    }

    static func isImportedEventManagedByApp(_ event: GoogleCalendarEvent) -> Bool {
        event.isManagedByGunnAire
    }

    static func shouldSelectGoogleCalendarBeforeCreate(for call: ServiceCall) -> Bool {
        call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
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
            ),
            extendedProperties: nil
        )
    }

    static func makeManagedEventPatch(for call: ServiceCall, remoteEvent: GoogleCalendarEvent?) -> GoogleCalendarEventPatch {
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
        let attendees = !preserveExternalDetails && customerEmail?.isEmpty == false
            ? [GoogleWritableCalendarAttendee(email: customerEmail!, displayName: call.customer.name)]
            : nil
        let eventDescription = preserveExternalDetails ? nil : normalizedOptional(call.notes)
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
            extendedProperties: preserveExternalDetails ? nil : managedCalendarEventProperties
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

    private static func remoteEventsByKey(
        from calendarEvents: [(calendarID: String, event: GoogleCalendarEvent)]
    ) -> [String: (calendarID: String, event: GoogleCalendarEvent)] {
        var indexed: [String: (calendarID: String, event: GoogleCalendarEvent)] = [:]
        for calendarEvent in calendarEvents {
            guard !isCalendarEventDeleted(calendarID: calendarEvent.calendarID, eventID: calendarEvent.event.id) else {
                continue
            }
            let eventKey = calendarEventStorageKey(calendarID: calendarEvent.calendarID, eventID: calendarEvent.event.id)
            indexed[eventKey] = indexed[eventKey] ?? calendarEvent
        }
        return indexed
    }

    private static func remoteEventsByFingerprint(
        from calendarEvents: [(calendarID: String, event: GoogleCalendarEvent)],
        writableCalendarIDs: Set<String>
    ) -> [String: (calendarID: String, event: GoogleCalendarEvent)] {
        var indexed: [String: (calendarID: String, event: GoogleCalendarEvent)] = [:]
        var indexedEventKeys: Set<String> = []
        for calendarEvent in calendarEvents {
            let eventKey = calendarEventStorageKey(calendarID: calendarEvent.calendarID, eventID: calendarEvent.event.id)
            guard !isCalendarEventDeleted(calendarID: calendarEvent.calendarID, eventID: calendarEvent.event.id),
                  indexedEventKeys.insert(eventKey).inserted,
                  calendarEvent.event.isManagedByGunnAire else {
                continue
            }
            guard let startDate = parseEventDate(calendarEvent.event.start),
                  let endDate = parseEventDate(calendarEvent.event.end) else {
                continue
            }
            let fingerprint = eventFingerprint(
                summary: calendarEvent.event.summary,
                location: calendarEvent.event.location,
                startDate: startDate,
                endDate: endDate
            )
            if let existing = indexed[fingerprint] {
                let existingWritable = contains(existing.calendarID, in: writableCalendarIDs)
                let newWritable = contains(calendarEvent.calendarID, in: writableCalendarIDs)
                // Prefer writable calendars over read-only; if equal, prefer primary as a stable tie-breaker.
                if (!existingWritable && newWritable) || (existingWritable == newWritable && calendarEvent.calendarID == "primary") {
                    indexed[fingerprint] = calendarEvent
                }
            } else {
                indexed[fingerprint] = calendarEvent
            }
        }
        return indexed
    }

    private static func eventFingerprint(for call: ServiceCall) -> String {
        eventFingerprint(
            summary: calendarEventTitle(for: call, existingSummary: nil),
            location: call.siteAddress ?? call.customer.address,
            startDate: call.scheduledDate,
            endDate: call.scheduledDate.addingTimeInterval(call.duration)
        )
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
        if isManagedByApp {
            return remote
        }
        return remote ?? normalizedOptional(existingValue)
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
        if let technicianCalendarID = call.assignedTechnician?.contactInfo?.trimmingCharacters(in: .whitespacesAndNewlines),
           !technicianCalendarID.isEmpty {
            if contains(technicianCalendarID, in: writableCalendarIDs) {
                return technicianCalendarID
            }
            if contains(technicianCalendarID.lowercased(), in: writableCalendarIDs) {
                return technicianCalendarID.lowercased()
            }
        }
        if let existingCalendarID = call.googleCalendarID,
           contains(existingCalendarID, in: writableCalendarIDs) {
            return existingCalendarID
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

    private static func fetchEvents(
        auth: GoogleAuthManager,
        calendarIDs: [String],
        timeMin: Date,
        timeMax: Date,
        completion: @escaping (Result<[(calendarID: String, event: GoogleCalendarEvent)], Error>) -> Void
    ) {
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "GoogleCalendarBatchFetch")
        var collected: [(calendarID: String, event: GoogleCalendarEvent)] = []
        var firstError: Error?

        for calendarID in calendarIDs {
            group.enter()
            auth.fetchCalendarEvents(calendarID: calendarID, timeMin: timeMin, timeMax: timeMax) { result in
                queue.async {
                    switch result {
                    case .success(let events):
                        collected.append(contentsOf: events.map { (calendarID: calendarID, event: $0) })
                    case .failure(let error):
                        if firstError == nil {
                            firstError = error
                        }
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            if let firstError {
                completion(.failure(firstError))
            } else {
                completion(.success(collected))
            }
        }
    }
}
