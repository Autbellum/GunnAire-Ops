import Foundation
import SwiftData

@MainActor
enum GoogleCalendarScheduleSync {
    static func sync(
        auth: GoogleAuthManager,
        modelContext: ModelContext,
        signedInEmail: String?,
        isAdminUser: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let now = Date()
        let horizon = Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now
        auth.fetchCalendars { calendarsResult in
            switch calendarsResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let calendars):
                let availableCalendarIDs = Set(["primary"] + calendars.map(\.id))
                let writableCalendarIDs = Set(["primary"] + calendars.filter(\.isWritable).map(\.id))
                fetchEvents(
                    auth: auth,
                    calendarIDs: Array(availableCalendarIDs),
                    timeMin: now,
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
                                    signedInEmail: signedInEmail,
                                    isAdminUser: isAdminUser,
                                    availableCalendarIDs: availableCalendarIDs
                                    ,
                                    writableCalendarIDs: writableCalendarIDs
                                ) { exportResult in
                                    switch exportResult {
                                    case .failure(let error):
                                        completion(.failure(error))
                                    case .success(let exportSummary):
                                        completion(.success("Imported \(importedCount) Google events. \(exportSummary)"))
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

    private static func importEvents(
        _ calendarEvents: [(calendarID: String, event: GoogleCalendarEvent)],
        into modelContext: ModelContext,
        signedInEmail: String?
    ) throws -> Int {
        let existingCalls = try modelContext.fetch(FetchDescriptor<ServiceCall>())
        let existingCustomers = try modelContext.fetch(FetchDescriptor<Customer>())
        let existingTechnicians = try modelContext.fetch(FetchDescriptor<Technician>())

        var callsByGoogleEventID = Dictionary(uniqueKeysWithValues: existingCalls.compactMap { call in
            call.googleEventID.map { ($0, call) }
        })
        var customersByName = Dictionary(uniqueKeysWithValues: existingCustomers.map { (normalized($0.name), $0) })
        var techniciansByEmail = Dictionary(uniqueKeysWithValues: existingTechnicians.compactMap { tech in
            tech.contactInfo.map { ($0.lowercased(), tech) }
        })

        let technician = resolveTechnician(signedInEmail: signedInEmail, techniciansByEmail: &techniciansByEmail, modelContext: modelContext)
        var imported = 0

        for calendarEvent in calendarEvents {
            let event = calendarEvent.event
            guard let startDate = parseEventDate(event.start), let endDate = parseEventDate(event.end) else {
                continue
            }
            let duration = max(endDate.timeIntervalSince(startDate), 1800)
            let customerName = inferCustomerName(from: event.summary)
            let customer = customersByName[normalized(customerName)] ?? {
                let newCustomer = Customer(name: customerName)
                modelContext.insert(newCustomer)
                customersByName[normalized(customerName)] = newCustomer
                return newCustomer
            }()
            if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
                customer.address = location
            }

            let call = callsByGoogleEventID[event.id] ?? ServiceCall(
                googleCalendarID: calendarEvent.calendarID,
                googleEventID: event.id,
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
                notes: event.description
            )
            if call.modelContext == nil {
                modelContext.insert(call)
            }
            call.googleCalendarID = calendarEvent.calendarID
            call.googleEventID = event.id
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
            call.siteAddress = event.location
            call.notes = event.description
            callsByGoogleEventID[event.id] = call
            imported += 1
        }

        try? modelContext.save()
        return imported
    }

    private static func exportCalls(
        auth: GoogleAuthManager,
        modelContext: ModelContext,
        signedInEmail: String?,
        isAdminUser: Bool,
        availableCalendarIDs: Set<String>,
        writableCalendarIDs: Set<String>,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        do {
            let calls = try modelContext.fetch(FetchDescriptor<ServiceCall>())
                .filter { call in
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
                availableCalendarIDs: availableCalendarIDs,
                writableCalendarIDs: writableCalendarIDs,
                completion: completion
            )
        } catch {
            completion(.failure(error))
        }
    }

    private static func exportNext(
        index: Int,
        exportedCount: Int,
        skippedCount: Int,
        calls: [ServiceCall],
        auth: GoogleAuthManager,
        modelContext: ModelContext,
        availableCalendarIDs: Set<String>,
        writableCalendarIDs: Set<String>,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard index < calls.count else {
            try? modelContext.save()
            let message: String
            if skippedCount > 0 {
                message = "Exported \(exportedCount) service calls and skipped \(skippedCount) calls on read-only Google calendars."
            } else {
                message = "Exported \(exportedCount) service calls."
            }
            completion(.success(message))
            return
        }

        let call = calls[index]
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
                availableCalendarIDs: availableCalendarIDs,
                writableCalendarIDs: writableCalendarIDs,
                completion: completion
            )
            return
        }

        let event = makeGoogleEvent(for: call)
        let finish: (Result<GoogleCalendarEvent, Error>) -> Void = { result in
            Task { @MainActor in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let saved):
                    call.googleCalendarID = targetCalendarID
                    call.googleEventID = saved.id
                    exportNext(
                        index: index + 1,
                        exportedCount: exportedCount + 1,
                        skippedCount: skippedCount,
                        calls: calls,
                        auth: auth,
                        modelContext: modelContext,
                        availableCalendarIDs: availableCalendarIDs,
                        writableCalendarIDs: writableCalendarIDs,
                        completion: completion
                    )
                }
            }
        }

        let currentCalendarID = call.googleCalendarID ?? targetCalendarID
        let canUpdateExistingEvent = contains(currentCalendarID, in: writableCalendarIDs) &&
            normalized(currentCalendarID) == normalized(targetCalendarID)

        if let eventID = call.googleEventID,
           !eventID.isEmpty,
           canUpdateExistingEvent {
            auth.updateCalendarEvent(calendarID: currentCalendarID, eventID: eventID, event: event, completion: finish)
        } else {
            if call.googleCalendarID != nil, normalized(call.googleCalendarID ?? "") != normalized(targetCalendarID) {
                call.googleEventID = nil
            }
            auth.createCalendarEvent(calendarID: targetCalendarID, event: event, completion: finish)
        }
    }

    private static func makeGoogleEvent(for call: ServiceCall) -> GoogleWritableCalendarEvent {
        let timeZone = TimeZone.current.identifier
        let endDate = call.scheduledDate.addingTimeInterval(call.duration)
        let summary = "\(call.type.rawValue.capitalized): \(call.customer.name)"
        return GoogleWritableCalendarEvent(
            summary: summary,
            description: call.notes,
            location: call.siteAddress ?? call.customer.address,
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

    private static func inferCustomerName(from summary: String?) -> String {
        guard let summary, !summary.isEmpty else { return "Google Calendar Customer" }
        if let separator = summary.firstIndex(of: ":") {
            let candidate = summary[summary.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? summary : candidate
        }
        return summary
    }

    private static func inferCallType(from summary: String?, description: String?) -> ServiceCallType {
        let haystack = [summary, description].compactMap { $0?.lowercased() }.joined(separator: " ")
        if haystack.contains("estimate") { return .estimate }
        if haystack.contains("install") { return .install }
        if haystack.contains("maintenance") { return .maintenance }
        return .service
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
