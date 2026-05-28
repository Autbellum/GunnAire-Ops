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
                let filteredCalendars = calendars.filter { !isExcludedCalendarID($0.id) }
                let availableCalendarIDs = Set(["primary"] + filteredCalendars.map(\.id))
                let writableCalendarIDs = Set(["primary"] + filteredCalendars.filter(\.isWritable).map(\.id))
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
        var callsByFingerprint = Dictionary(uniqueKeysWithValues: existingCalls.map { (eventFingerprint(for: $0), $0) })
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
            guard let customerCandidate = inferCustomer(
                from: event,
                signedInEmail: signedInEmail,
                technicianEmails: Set(techniciansByEmail.keys)
            ) else {
                continue
            }
            let nameKey = normalized(customerCandidate.name)
            let customer = customerCandidate.email.flatMap { customersByEmail[$0] }
                ?? customersByName[nameKey]
                ?? {
                    let newCustomer = Customer(
                        name: customerCandidate.name,
                        email: customerCandidate.email,
                        address: customerCandidate.address
                    )
                    modelContext.insert(newCustomer)
                    return newCustomer
                }()
            if !isGenericCustomerName(customerCandidate.name, matching: event.summary) {
                customer.name = customerCandidate.name
            }
            if customer.email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                customer.email = customerCandidate.email
            }
            if let address = customerCandidate.address, !address.isEmpty {
                customer.address = address
            }
            customersByName[normalized(customer.name)] = customer
            customersByName[nameKey] = customer
            if let email = customer.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !email.isEmpty {
                customersByEmail[email] = customer
            }

            let call = callsByGoogleEventID[event.id] ?? callsByFingerprint[fingerprint] ?? ServiceCall(
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
                remoteEventsByFingerprint: remoteEventsByFingerprint(from: calendarEvents, writableCalendarIDs: writableCalendarIDs),
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
        remoteEventsByFingerprint: [String: (calendarID: String, event: GoogleCalendarEvent)],
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
                remoteEventsByFingerprint: remoteEventsByFingerprint,
                availableCalendarIDs: availableCalendarIDs,
                writableCalendarIDs: writableCalendarIDs,
                completion: completion
            )
            return
        }

        let event = makeGoogleEvent(for: call)
        let finish: (String, Result<GoogleCalendarEvent, Error>) -> Void = { savedCalendarID, result in
            Task { @MainActor in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let saved):
                    call.googleCalendarID = savedCalendarID
                    call.googleEventID = saved.id
                    exportNext(
                        index: index + 1,
                        exportedCount: exportedCount + 1,
                        skippedCount: skippedCount,
                        calls: calls,
                        auth: auth,
                        modelContext: modelContext,
                        remoteEventsByFingerprint: remoteEventsByFingerprint,
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
            auth.updateCalendarEvent(calendarID: currentCalendarID, eventID: eventID, event: event) { result in
                finish(currentCalendarID, result)
            }
        } else if let remote = remoteEventsByFingerprint[eventFingerprint(for: call)],
                  contains(remote.calendarID, in: writableCalendarIDs) {
            call.googleCalendarID = remote.calendarID
            call.googleEventID = remote.event.id
            auth.updateCalendarEvent(calendarID: remote.calendarID, eventID: remote.event.id, event: event) { result in
                finish(remote.calendarID, result)
            }
        } else {
            if call.googleCalendarID != nil, normalized(call.googleCalendarID ?? "") != normalized(targetCalendarID) {
                call.googleEventID = nil
            }
            auth.createCalendarEvent(calendarID: targetCalendarID, event: event) { result in
                finish(targetCalendarID, result)
            }
        }
    }

    private static func makeGoogleEvent(for call: ServiceCall) -> GoogleWritableCalendarEvent {
        let timeZone = TimeZone.current.identifier
        let endDate = call.scheduledDate.addingTimeInterval(call.duration)
        let summary = calendarSummary(for: call.type)
        let customerEmail = call.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let attendees = customerEmail?.isEmpty == false
            ? [GoogleWritableCalendarAttendee(email: customerEmail!, displayName: call.customer.name)]
            : nil
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
            ),
            attendees: attendees
        )
    }

    private static func calendarSummary(for type: ServiceCallType) -> String {
        switch type {
        case .service:
            return "Service Call"
        case .estimate:
            return "Estimate"
        case .install:
            return "Install"
        case .maintenance:
            return "Maintenance"
        }
    }

    private static func remoteEventsByFingerprint(
        from calendarEvents: [(calendarID: String, event: GoogleCalendarEvent)],
        writableCalendarIDs: Set<String>
    ) -> [String: (calendarID: String, event: GoogleCalendarEvent)] {
        var indexed: [String: (calendarID: String, event: GoogleCalendarEvent)] = [:]
        for calendarEvent in calendarEvents {
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
            summary: "\(call.type.rawValue.capitalized): \(call.customer.name)",
            location: call.siteAddress ?? call.customer.address,
            startDate: call.scheduledDate,
            endDate: call.scheduledDate.addingTimeInterval(call.duration)
        )
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
