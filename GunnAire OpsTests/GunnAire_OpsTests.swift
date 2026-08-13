//
//  GunnAire_OpsTests.swift
//  GunnAire OpsTests
//
//  Created by Eric Gunn on 2/23/26.
//

import Testing
@testable import GunnAire_Ops
import Foundation
import SwiftData

@MainActor
struct GunnAire_OpsTests {

    @Test func serviceCallIsUpcomingThisWeekForFutureDate() async throws {
        let customer = Customer(name: "Test Customer")
        let call = ServiceCall(
            type: .service,
            scheduledDate: Date().addingTimeInterval(60 * 60 * 24),
            customer: customer
        )

        #expect(call.isUpcomingThisWeek == true)
    }

    @Test func serviceCallIsNotUpcomingThisWeekForPastDate() async throws {
        let customer = Customer(name: "Test Customer")
        let call = ServiceCall(
            type: .service,
            scheduledDate: Date().addingTimeInterval(-60 * 60 * 24),
            customer: customer
        )

        #expect(call.isUpcomingThisWeek == false)
    }

    @Test func serviceCallIsNotUpcomingThisWeekForFarFutureDate() async throws {
        let customer = Customer(name: "Test Customer")
        let call = ServiceCall(
            type: .service,
            scheduledDate: Date().addingTimeInterval(60 * 60 * 24 * 14),
            customer: customer
        )

        #expect(call.isUpcomingThisWeek == false)
    }

    @Test func standardUsersKeepFieldAccessButNotAdminScreens() async throws {
        let standard = AppUser(email: "tech@gunnaire.com", role: .standard)
        let admin = AppUser(email: "admin@gunnaire.com", role: .admin)
        let users = [standard, admin]

        #expect(AppAccess.canAccessSidebarItem(.scheduleAndJobs, email: standard.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.onsiteDocumentation, email: standard.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.invoices, email: standard.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.payments, email: standard.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.receiptsBills, email: standard.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.quickBooksManagement, email: standard.email, users: users) == false)
        #expect(AppAccess.canAccessSidebarItem(.syncIntegrations, email: standard.email, users: users) == false)
        #expect(AppAccess.canAccessSidebarItem(.estimates, email: standard.email, users: users) == false)
        #expect(AppAccess.canAccessSidebarItem(.mail, email: standard.email, users: users) == false)
        #expect(AppAccess.canViewFinancialManagement(email: standard.email, users: users) == false)
        #expect(AppAccess.canViewBillingFinancialDetails(email: standard.email, users: users) == false)
        #expect(AppAccess.canCollectFieldPayments(email: standard.email, users: users) == true)

        #expect(AppAccess.canAccessSidebarItem(.quickBooksManagement, email: admin.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.syncIntegrations, email: admin.email, users: users) == true)
        #expect(AppAccess.canViewFinancialManagement(email: admin.email, users: users) == true)
        #expect(AppAccess.canViewBillingFinancialDetails(email: admin.email, users: users) == true)
    }

    @Test func serviceCallEquipmentSummaryIncludesManufacturer() async throws {
        let customer = Customer(name: "Equipment Customer")
        let call = ServiceCall(
            equipmentName: "Upstairs System",
            equipmentManufacturer: "Carrier",
            equipmentModel: "25VNA4",
            equipmentSerialNumber: "ABC123",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        #expect(call.equipmentSummary?.contains("Carrier") == true)
        #expect(call.equipmentSummary?.contains("S/N ABC123") == true)
    }

    @Test func splitSystemServiceReportRequiresHeadPressureAndCompressorRLA() async throws {
        let requiredKeys = Set(HVACEquipmentType.splitSystemAC.requiredReadingKeysForCompleteServiceReport)
        let definitionKeys = Set(HVACEquipmentType.splitSystemAC.readingDefinitions.map(\.key))

        #expect(definitionKeys.contains("head_pressure"))
        #expect(definitionKeys.contains("compressor_rla"))
        #expect(definitionKeys.contains("outdoor_fan_fla"))
        #expect(requiredKeys.contains("head_pressure"))
        #expect(requiredKeys.contains("compressor_rla"))
    }

    @Test func technicalServiceReportFlagsCompressorAmpDrawAboveRLA() async throws {
        let customer = Customer(name: "Amp Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )

        call.setTechnicalReading("10", for: "compressor_rla")
        call.setTechnicalReading("12", for: "compressor_amps")
        call.setTechnicalReading("1.0", for: "outdoor_fan_fla")
        call.setTechnicalReading("1.2", for: "outdoor_fan_amps")

        #expect(call.serviceReportCrossReadingValidationIssueLabels.contains { $0.contains("Compressor Amps exceeds Compressor RLA") })
        #expect(call.serviceReportCrossReadingValidationIssueLabels.contains { $0.contains("Outdoor Fan Amps exceeds Outdoor Fan FLA") })
        #expect(call.serviceReportReadingValidationIssueLabels.contains { $0.contains("Compressor Amps exceeds Compressor RLA") })
        let compressorDefinition = try #require(call.technicalReadingDefinitions.first { $0.key == "compressor_amps" })
        let outdoorFanDefinition = try #require(call.technicalReadingDefinitions.first { $0.key == "outdoor_fan_amps" })
        #expect(call.technicalReadingValidationIssue(for: compressorDefinition)?.contains("Compressor RLA") == true)
        #expect(call.technicalReadingValidationIssue(for: outdoorFanDefinition)?.contains("Outdoor Fan FLA") == true)
    }

    @Test func technicalReportExporterIncludesHeadPressureAndAmpValidation() async throws {
        let customer = Customer(name: "Report Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )

        call.setTechnicalReading("325", for: "head_pressure")
        call.setTechnicalReading("10", for: "compressor_rla")
        call.setTechnicalReading("12", for: "compressor_amps")

        let sections = CustomerDocumentExporter.technicalReportSectionSummaries(for: call)
        let rows = sections.flatMap(\.rows)

        #expect(rows.contains { $0.label == "Head Pressure (psig)" && $0.value == "325" })
        #expect(rows.contains { $0.value.contains("Compressor Amps exceeds Compressor RLA") })
    }

    @Test func customerEquipmentProfileAppliesToServiceCall() async throws {
        let customer = Customer(name: "Equipment Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .heatPump,
            name: "Downstairs Heat Pump",
            manufacturer: "Trane",
            modelNumber: "XV20i",
            serialNumber: "HP123",
            location: "Downstairs closet",
            installDate: Date(timeIntervalSince1970: 1_700_000_000),
            warrantyExpiration: Date(timeIntervalSince1970: 1_900_000_000),
            filterSize: "20x25x1",
            notes: "Variable speed"
        )
        let call = ServiceCall(type: .maintenance, scheduledDate: Date(), customer: customer)

        equipment.apply(to: call)

        #expect(call.customerEquipmentID == equipment.id)
        #expect(call.equipmentType == .heatPump)
        #expect(call.equipmentName == "Downstairs Heat Pump")
        #expect(call.equipmentManufacturer == "Trane")
        #expect(call.equipmentModel == "XV20i")
        #expect(call.equipmentSerialNumber == "HP123")
        #expect(call.equipmentLocation == "Downstairs closet")
        #expect(call.equipmentInstallDate == equipment.installDate)
        #expect(call.equipmentWarrantyExpiration == equipment.warrantyExpiration)
        #expect(call.filterSize == "20x25x1")
        #expect(call.equipmentNotes == "Variable speed")
    }

    @Test func serviceCallAttachmentProgressRecalculatesPhotoCounts() async throws {
        let customer = Customer(name: "Attachment Customer")
        let call = ServiceCall(type: .maintenance, scheduledDate: Date(), customer: customer)
        let beforePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .beforePhoto,
            displayName: "before.jpg",
            localFilePath: "/tmp/before.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 100
        )
        let afterPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .afterPhoto,
            displayName: "after.jpg",
            localFilePath: "/tmp/after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 100
        )
        let document = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .customerDocument,
            displayName: "notes.pdf",
            localFilePath: "/tmp/notes.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 100
        )

        call.refreshAttachmentProgress(from: [beforePhoto, afterPhoto, document])

        #expect(call.beforePhotoCount == 1)
        #expect(call.afterPhotoCount == 1)
        #expect(call.documentationStartedAt != nil)

        call.refreshAttachmentProgress(from: [afterPhoto, document])

        #expect(call.beforePhotoCount == 0)
        #expect(call.afterPhotoCount == 1)
    }

    @Test func googleCalendarPatchDoesNotOverwriteEventDetails() async throws {
        let customer = Customer(name: "Calendar Customer", address: "123 Main St")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "google-event-1",
            googleEventManagedByApp: true,
            eventTitle: "Do not overwrite this title",
            siteAddress: "456 Field Rd",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer,
            notes: "Do not overwrite this body."
        )

        let patch = GoogleCalendarScheduleSync.makeScheduleOnlyPatch(for: call)
        let data = try JSONEncoder().encode(patch)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["start"] != nil)
        #expect(object["end"] != nil)
        #expect(object["summary"] == nil)
        #expect(object["description"] == nil)
        #expect(object["location"] == nil)
        #expect(object["attendees"] == nil)
        #expect(GoogleCalendarEventPatch.unsafeDetailKeys(in: data).isEmpty)
    }

    @Test func googleCalendarManagedPatchOmitsExistingGoogleDetails() async throws {
        let customer = Customer(name: "Calendar Customer", address: "123 Main St")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "google-event-1",
            googleEventManagedByApp: true,
            eventTitle: "Customer Follow-up",
            siteAddress: "",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer,
            notes: "Bring replacement capacitor."
        )

        let remoteEvent = GoogleCalendarEvent(
            id: "google-event-1",
            summary: "Google title stays",
            description: "Google body stays",
            location: "Google location stays",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: [
                "gunnaireManaged": "true",
                "gunnaireManagedVersion": "3",
                "gunnaireOrigin": "ios-app"
            ]),
            start: GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T13:00:00Z", timeZone: nil),
            end: GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T14:00:00Z", timeZone: nil)
        )

        let patch = GoogleCalendarScheduleSync.makeManagedEventPatch(for: call, remoteEvent: remoteEvent)
        let data = try JSONEncoder().encode(patch)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["start"] != nil)
        #expect(object["end"] != nil)
        #expect(object["summary"] == nil)
        #expect(object["description"] == nil)
        #expect(object["location"] == nil)
        #expect(object["extendedProperties"] == nil)
        #expect(Set(object.keys) == ["start", "end"])
        #expect(GoogleCalendarEventPatch.unsafeDetailKeys(in: data).isEmpty)
    }

    @Test func googleCalendarPatchGuardDetectsDetailScrubbingFields() async throws {
        let unsafePayload = Data("""
        {
          "start": { "dateTime": "2027-01-15T13:00:00Z", "timeZone": "America/New_York" },
          "end": { "dateTime": "2027-01-15T14:00:00Z", "timeZone": "America/New_York" },
          "summary": "",
          "description": "",
          "location": ""
        }
        """.utf8)

        #expect(GoogleCalendarEventPatch.unsafeDetailKeys(in: unsafePayload) == ["description", "location", "summary"])
        #expect(GoogleAuthError.unsafeCalendarPatch("description, location, summary").errorDescription?.contains("Blocked unsafe Google Calendar update") == true)
    }

    @Test func googleCalendarManagedPatchNeverWritesLocalDetailsOverGoogleFields() async throws {
        let customer = Customer(name: "Calendar Customer", address: "123 Main St")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "google-event-1",
            googleEventManagedByApp: true,
            eventTitle: "Repair title",
            siteAddress: "456 Field Rd",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer,
            notes: "Repair body"
        )
        let remoteEvent = GoogleCalendarEvent(
            id: "google-event-1",
            summary: nil,
            description: "",
            location: "Google location stays",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: [
                "gunnaireManaged": "true",
                "gunnaireManagedVersion": "3",
                "gunnaireOrigin": "ios-app"
            ]),
            start: GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T13:00:00Z", timeZone: nil),
            end: GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T14:00:00Z", timeZone: nil)
        )

        let patch = GoogleCalendarScheduleSync.makeManagedEventPatch(for: call, remoteEvent: remoteEvent)
        let data = try JSONEncoder().encode(patch)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["summary"] == nil)
        #expect(object["description"] == nil)
        #expect(object["location"] == nil)
        #expect(object["start"] != nil)
        #expect(object["end"] != nil)
        #expect(object["extendedProperties"] == nil)
        #expect(Set(object.keys) == ["start", "end"])
    }

    @Test func googleCalendarCreatePayloadIncludesStructuredVisibleDetails() async throws {
        let customer = Customer(name: "Calendar Customer", address: "")
        let call = ServiceCall(
            eventTitle: "Site reminder",
            siteAddress: "",
            type: .reminder,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer,
            notes: "   "
        )

        let event = GoogleCalendarScheduleSync.makeCalendarCreateEvent(for: call)
        let data = try JSONEncoder().encode(event)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["summary"] as? String == "Site reminder")
        #expect(object["description"] as? String == "Customer: Calendar Customer\nCall Type: Reminder")
        #expect(object["location"] == nil)
        #expect(object["start"] != nil)
        #expect(object["end"] != nil)
        #expect(object["extendedProperties"] == nil)
    }

    @Test func googleCalendarCreatePayloadKeepsUserEnteredLocationAndDetailsVisible() async throws {
        let customer = Customer(name: "Calendar Customer", address: "")
        let call = ServiceCall(
            eventTitle: "Bid due reminder",
            siteAddress: "789 Customer Site Rd",
            type: .reminder,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer,
            notes: "Submit bid package before noon."
        )

        let event = GoogleCalendarScheduleSync.makeCalendarCreateEvent(for: call)
        let data = try JSONEncoder().encode(event)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let description = try #require(object["description"] as? String)

        #expect(object["summary"] as? String == "Bid due reminder")
        #expect(object["location"] as? String == "789 Customer Site Rd")
        #expect(description.contains("Service Address: 789 Customer Site Rd"))
        #expect(description.contains("Call Type: Reminder"))
        #expect(description.contains("Submit bid package before noon."))
    }

    @Test func olderGoogleCalendarManagedMarkersAreTreatedAsExternal() async throws {
        let oldManagedEvent = GoogleCalendarEvent(
            id: "old-managed-event",
            summary: "Existing Google Event",
            description: "Keep this body",
            location: "Keep this location",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: ["gunnaireManaged": "true"]),
            start: GoogleCalendarEventDate(date: nil, dateTime: "2026-06-01T14:00:00Z", timeZone: nil),
            end: GoogleCalendarEventDate(date: nil, dateTime: "2026-06-01T15:00:00Z", timeZone: nil)
        )

        #expect(GoogleCalendarScheduleSync.isImportedEventManagedByApp(oldManagedEvent) == false)
    }

    @Test func externalGoogleCalendarImportDoesNotReplaceLocalDetailsWithBlankRemoteFields() async throws {
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarText(
            remoteValue: " ",
            existingValue: "Customer supplied title",
            isManagedByApp: false
        ) == "Customer supplied title")
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarText(
            remoteValue: nil,
            existingValue: "123 Existing Location",
            isManagedByApp: false
        ) == "123 Existing Location")
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarText(
            remoteValue: "\n",
            existingValue: "Existing calendar body",
            isManagedByApp: false
        ) == "Existing calendar body")
    }

    @Test func appManagedGoogleCalendarImportAllowsBlankRemoteFieldsToClearLocalMirror() async throws {
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarText(
            remoteValue: nil,
            existingValue: "Old local location",
            isManagedByApp: true
        ) == nil)
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarText(
            remoteValue: " Updated remote body ",
            existingValue: "Old local body",
            isManagedByApp: true
        ) == "Updated remote body")
    }

    @Test func customerEquipmentProfileCanBeUpdatedInPlace() async throws {
        let equipment = CustomerEquipment(
            equipmentType: .splitSystemAC,
            name: "Old System",
            manufacturer: "Old Brand",
            isActive: false
        )

        equipment.updateFrom(
            equipmentType: .gasFurnace,
            name: "Main Furnace",
            manufacturer: "Carrier",
            modelNumber: "59TN6",
            serialNumber: "FURN123",
            location: "Attic",
            installDate: Date(timeIntervalSince1970: 1_600_000_000),
            warrantyExpiration: nil,
            filterSize: "16x25x1",
            notes: "Updated during maintenance",
            isActive: true
        )

        #expect(equipment.equipmentType == .gasFurnace)
        #expect(equipment.name == "Main Furnace")
        #expect(equipment.manufacturer == "Carrier")
        #expect(equipment.modelNumber == "59TN6")
        #expect(equipment.serialNumber == "FURN123")
        #expect(equipment.location == "Attic")
        #expect(equipment.warrantyExpiration == nil)
        #expect(equipment.filterSize == "16x25x1")
        #expect(equipment.notes == "Updated during maintenance")
        #expect(equipment.isActive == true)
    }

    @Test func serviceReportCanAppendEquipmentProfileHistoryWithoutDuplicates() async throws {
        let customer = Customer(name: "Equipment Customer")
        let estimateID = UUID()
        let invoiceID = UUID()
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            filterCondition: "Replaced",
            indoorCoilCondition: "Clean",
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            findingsSummary: "No faults found.",
            recommendedWorkSummary: "Return in six months.",
            linkedEstimateID: estimateID,
            linkedInvoiceID: invoiceID
        )
        call.setServiceActionStatus(.completed, for: "burner_assembly_checked")
        call.setServiceActionStatus(.needsService, for: "heat_exchanger_checked")
        let note = try #require(call.equipmentProfileServiceHistoryNote)
        let merged = try #require(CustomerEquipment.mergedNotes(existing: "Existing equipment note.", currentProfileNote: "Updated equipment note.", serviceHistoryNote: note))
        let mergedAgain = CustomerEquipment.mergedNotes(existing: merged, serviceHistoryNote: note)

        #expect(merged.contains("Updated equipment note."))
        #expect(merged.contains("Existing equipment note.") == false)
        #expect(note.contains("Maintenance"))
        #expect(note.contains("Heating maintenance completed."))
        #expect(note.contains("Actions:"))
        #expect(note.contains("Heat exchanger inspected: Needs Service"))
        #expect(note.contains("Filter: Replaced"))
        #expect(note.contains("Estimate: \(String(estimateID.uuidString.prefix(8)).uppercased())"))
        #expect(note.contains("Invoice: \(String(invoiceID.uuidString.prefix(8)).uppercased())"))
        #expect(merged.contains("Return in six months.") == true)
        #expect(mergedAgain == merged)
    }

    @Test func equipmentServiceHistoryIncludesCapturedTechnicalReadings() async throws {
        let customer = Customer(name: "Technical History Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Cooling maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )
        call.setTechnicalReading("72", for: "return_air_temp")
        call.setTechnicalReading("54", for: "supply_air_temp")
        call.setTechnicalReading("10", for: "superheat")
        call.setTechnicalReading("8", for: "subcooling")
        call.setTechnicalReading("238", for: "line_voltage")
        call.setTechnicalReading("7.4", for: "compressor_amps")

        let summary = try #require(call.technicalReadingServiceHistorySummary)
        let note = try #require(call.equipmentProfileServiceHistoryNote)

        #expect(summary.contains("Return Air Temp"))
        #expect(summary.contains("Temperature Split"))
        #expect(summary.contains("Superheat"))
        #expect(summary.contains("Line Voltage"))
        #expect(note.contains("Readings:"))
        #expect(note.contains("Compressor Amps"))
    }

    @Test func equipmentUnresolvedServiceConcernsCarryForwardUntilCleared() async throws {
        let customer = Customer(name: "Concern Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .gasFurnace,
            name: "Main Furnace",
            serialNumber: "FURN-1"
        )
        let olderCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            status: .completed
        )
        olderCall.setServiceActionStatus(.needsService, for: "heat_exchanger_checked")
        olderCall.setServiceActionStatus(.monitor, for: "burner_assembly_checked")

        let newerCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_086_400),
            customer: customer,
            status: .completed
        )
        newerCall.setServiceActionStatus(.completed, for: "heat_exchanger_checked")

        let summary = try #require(equipment.unresolvedServiceConcernSummary(
            in: [olderCall, newerCall],
            now: Date(timeIntervalSince1970: 1_800_172_800)
        ))

        #expect(summary.contains("Burner assembly inspected: Monitor"))
        #expect(summary.contains("Heat exchanger inspected") == false)
    }

    @Test func equipmentUnresolvedServiceConcernsIgnoreCancelledFutureAndOtherEquipment() async throws {
        let customer = Customer(name: "Concern Customer")
        let equipment = CustomerEquipment(customer: customer, name: "Downstairs AC", serialNumber: "AC-1")
        let otherEquipment = CustomerEquipment(customer: customer, name: "Upstairs AC", serialNumber: "AC-2")
        let currentCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            status: .completed
        )
        currentCall.setServiceActionStatus(.needsService, for: "condenser_coil_serviced")
        let cancelledCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_086_400),
            customer: customer,
            status: .cancelled
        )
        cancelledCall.setServiceActionStatus(.needsService, for: "electrical_connections_checked")
        let futureCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_172_800),
            customer: customer,
            status: .scheduled
        )
        futureCall.setServiceActionStatus(.needsService, for: "evaporator_coil_checked")
        let otherCall = ServiceCall(
            customerEquipmentID: otherEquipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            status: .completed
        )
        otherCall.setServiceActionStatus(.needsService, for: "electrical_connections_checked")

        let summary = try #require(equipment.unresolvedServiceConcernSummary(
            in: [currentCall, cancelledCall, futureCall, otherCall],
            now: Date(timeIntervalSince1970: 1_800_100_000)
        ))

        #expect(summary.contains("Condenser coil inspected/washed: Needs Service"))
        #expect(summary.contains("Electrical connections checked") == false)
        #expect(summary.contains("Evaporator coil inspected") == false)
    }

    @Test func customerEquipmentProfileMatchesLinkedAndSerializedServiceCalls() async throws {
        let customer = Customer(name: "Equipment Customer")
        let otherCustomer = Customer(name: "Other Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .gasFurnace,
            name: "Main Furnace",
            manufacturer: "Carrier",
            modelNumber: "59TN6",
            serialNumber: "FURN123"
        )
        let linkedCall = ServiceCall(
            customerEquipmentID: equipment.id,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let serialMatchedCall = ServiceCall(
            equipmentName: "Different label",
            equipmentSerialNumber: " furn123 ",
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )
        let nameModelMatchedCall = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59tn6",
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )
        let otherCustomerCall = ServiceCall(
            equipmentSerialNumber: "FURN123",
            type: .service,
            scheduledDate: Date(),
            customer: otherCustomer
        )

        #expect(equipment.matches(linkedCall))
        #expect(equipment.matches(serialMatchedCall))
        #expect(equipment.matches(nameModelMatchedCall))
        #expect(equipment.matches(otherCustomerCall) == false)
    }

    @Test func customerEquipmentServiceHistorySummarizesLastAndNextJobs() async throws {
        let customer = Customer(name: "Equipment Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .heatPump,
            name: "Downstairs Heat Pump",
            serialNumber: "HP123"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pastCall = ServiceCall(
            equipmentSerialNumber: "HP123",
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 30),
            customer: customer,
            status: .completed
        )
        let futureCall = ServiceCall(
            equipmentSerialNumber: "HP123",
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(86_400 * 30),
            customer: customer,
            status: .scheduled
        )

        let summary = try #require(equipment.serviceHistorySummary(in: [pastCall, futureCall], now: now))

        #expect(summary.contains("Last:"))
        #expect(summary.contains("Next:"))
        #expect(summary.contains("2 jobs"))
    }

    @Test func customerEquipmentLatestTechnicalReadingsUseMostRecentCompletedMatchingJob() async throws {
        let customer = Customer(name: "Equipment Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            serialNumber: "AC123"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let olderCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 60),
            customer: customer,
            status: .completed
        )
        olderCall.setTechnicalReading("14", for: "superheat")
        let latestCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 3),
            customer: customer,
            status: .completed
        )
        latestCall.setTechnicalReading("9", for: "superheat")
        latestCall.setTechnicalReading("240", for: "line_voltage")
        let futureCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(86_400 * 3),
            customer: customer,
            status: .scheduled
        )
        futureCall.setTechnicalReading("999", for: "line_voltage")

        let summary = try #require(equipment.latestTechnicalReadingsSummary(in: [olderCall, latestCall, futureCall], now: now))

        #expect(summary.contains("Superheat"))
        #expect(summary.contains("9"))
        #expect(summary.contains("Line Voltage"))
        #expect(summary.contains("240"))
        #expect(summary.contains("999") == false)
        #expect(summary.contains("14") == false)
    }

    @Test func customerEquipmentLatestConcernSummaryShowsOnlyOpenServiceActions() async throws {
        let customer = Customer(name: "Equipment Concern Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            serialNumber: "AC123"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let olderCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 30),
            customer: customer,
            status: .completed
        )
        olderCall.setServiceActionStatus(.needsService, for: "condenser_coil_serviced")
        let latestCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 2),
            customer: customer,
            status: .completed
        )
        latestCall.setServiceActionStatus(.monitor, for: "condensate_drain_checked")
        latestCall.setServiceActionStatus(.needsService, for: "electrical_connections_checked")
        latestCall.setServiceActionStatus(.completed, for: "filter_checked")
        latestCall.setServiceActionStatus(.notApplicable, for: "thermostat_verified")

        let summary = try #require(equipment.latestServiceConcernSummary(in: [olderCall, latestCall], now: now))

        #expect(summary.contains("Electrical connections inspected: Needs Service"))
        #expect(summary.contains("Condensate drain checked/treated: Monitor"))
        #expect(summary.contains("Filter checked/replaced") == false)
        #expect(summary.contains("Thermostat operation verified") == false)
        #expect(summary.contains("Condenser coil inspected/washed") == false)
    }

    @Test func customerEquipmentLatestServiceContextSummarizesReportAndReadings() async throws {
        let customer = Customer(name: "Equipment Context Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            serialNumber: "AC123"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previousCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Cleaned condenser and verified charge.",
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 12),
            customer: customer,
            status: .completed
        )
        previousCall.setTechnicalReading("10", for: "superheat")
        previousCall.setTechnicalReading("8", for: "subcooling")
        previousCall.setServiceActionStatus(.completed, for: "condenser_coil_serviced")
        previousCall.setServiceActionStatus(.monitor, for: "condensate_drain_checked")
        let currentCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Current report should not be used.",
            type: .maintenance,
            scheduledDate: now,
            customer: customer,
            status: .completed
        )
        currentCall.setTechnicalReading("999", for: "superheat")

        let summary = try #require(equipment.latestServiceContextSummary(
            in: [previousCall],
            now: now
        ))
        let excludingCurrentSummary = try #require(equipment.latestServiceContextSummary(
            in: [previousCall, currentCall].filter { $0.id != currentCall.id },
            now: now
        ))

        #expect(summary.contains("Last service:"))
        #expect(summary.contains("Cleaned condenser"))
        #expect(summary.contains("Superheat"))
        #expect(summary.contains("10"))
        #expect(summary.contains("Subcooling"))
        #expect(summary.contains("8"))
        #expect(summary.contains("Actions:"))
        #expect(summary.contains("Condensate drain checked/treated: Monitor"))
        #expect(excludingCurrentSummary.contains("999") == false)
    }

    @Test func serviceCallCopiesCompatiblePreviousTechnicalReadingsWithoutOverwritingCurrentValues() async throws {
        let customer = Customer(name: "Reading Copy Customer")
        let previousCall = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_700_000_000),
            customer: customer
        )
        previousCall.setTechnicalReading("11", for: "superheat")
        previousCall.setTechnicalReading("242", for: "line_voltage")
        previousCall.setTechnicalReading("3.5", for: "gas_pressure_inlet")
        let currentCall = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )
        currentCall.setTechnicalReading("238", for: "line_voltage")

        let copied = currentCall.copyTechnicalReadings(from: previousCall)

        #expect(copied == 1)
        #expect(currentCall.technicalReading(for: "superheat") == "11")
        #expect(currentCall.technicalReading(for: "line_voltage") == "238")
        #expect(currentCall.technicalReading(for: "gas_pressure_inlet").isEmpty)
    }

    @Test func coolingEquipmentReadingDefinitionsIncludeStructuredRefrigerantOptions() async throws {
        let refrigerantDefinition = HVACEquipmentType.splitSystemAC.readingDefinitions.first {
            $0.key == "refrigerant_type"
        }
        let meteringDeviceDefinition = HVACEquipmentType.splitSystemAC.readingDefinitions.first {
            $0.key == "metering_device"
        }
        let superheatDefinition = HVACEquipmentType.splitSystemAC.readingDefinitions.first {
            $0.key == "superheat"
        }
        let suctionSaturationDefinition = HVACEquipmentType.splitSystemAC.readingDefinitions.first {
            $0.key == "suction_saturation_temp"
        }
        let liquidSaturationDefinition = HVACEquipmentType.splitSystemAC.readingDefinitions.first {
            $0.key == "liquid_saturation_temp"
        }

        #expect(refrigerantDefinition?.options.contains("R-410A") == true)
        #expect(refrigerantDefinition?.options.contains("R-454B") == true)
        #expect(meteringDeviceDefinition?.options.contains("TXV") == true)
        #expect(superheatDefinition?.options.isEmpty == true)
        #expect(suctionSaturationDefinition?.displayLabel == "Suction Saturation Temp (F)")
        #expect(liquidSaturationDefinition?.displayLabel == "Liquid Saturation Temp (F)")
    }

    @Test func technicalReadingDefinitionsIncludeFieldInputHints() async throws {
        let suctionPressure = try #require(HVACEquipmentType.splitSystemAC.readingDefinitions.first { $0.key == "suction_pressure" })
        let superheat = try #require(HVACEquipmentType.splitSystemAC.readingDefinitions.first { $0.key == "superheat" })
        let gasPressure = try #require(HVACEquipmentType.gasFurnace.readingDefinitions.first { $0.key == "gas_pressure_manifold" })
        let coReading = try #require(HVACEquipmentType.gasFurnace.readingDefinitions.first { $0.key == "co_ppm" })

        #expect(suctionPressure.inputHint?.contains("service ports") == true)
        #expect(superheat.inputHint?.contains("Calculate") == true)
        #expect(gasPressure.inputHint?.contains("manometer") == true)
        #expect(coReading.inputHint?.contains("carbon monoxide") == true)
    }

    @Test func calculatedTechnicalReadingDefinitionsExposeSourceGuidance() async throws {
        let split = try #require(HVACEquipmentType.splitSystemAC.readingDefinitions.first { $0.key == "temperature_split" })
        let superheat = try #require(HVACEquipmentType.splitSystemAC.readingDefinitions.first { $0.key == "superheat" })
        let subcooling = try #require(HVACEquipmentType.splitSystemAC.readingDefinitions.first { $0.key == "subcooling" })
        let totalStatic = try #require(HVACEquipmentType.airHandler.readingDefinitions.first { $0.key == "total_external_static" })
        let lineVoltage = try #require(HVACEquipmentType.splitSystemAC.readingDefinitions.first { $0.key == "line_voltage" })

        #expect(split.isCalculated)
        #expect(superheat.isCalculated)
        #expect(subcooling.isCalculated)
        #expect(totalStatic.isCalculated)
        #expect(lineVoltage.isCalculated == false)
        #expect(superheat.calculationSourceHint?.contains("Suction Line Temp") == true)
        #expect(subcooling.calculationSourceHint?.contains("Liquid Line Temp") == true)
        #expect(totalStatic.calculationSourceHint?.contains("Return Static") == true)
    }

    @Test func equipmentSpecificReportDefinitionsIncludeFieldServiceControls() async throws {
        let heatPumpKeys = Set(HVACEquipmentType.heatPump.readingDefinitions.map(\.key))
        let furnaceDefinitions = HVACEquipmentType.gasFurnace.readingDefinitions
        let waterHeaterDefinitions = HVACEquipmentType.waterHeater.readingDefinitions
        let airHandlerDefinitions = HVACEquipmentType.airHandler.readingDefinitions
        let packageUnitDefinitions = HVACEquipmentType.packageUnit.readingDefinitions
        let miniSplitDefinitions = HVACEquipmentType.miniSplit.readingDefinitions

        #expect(heatPumpKeys.contains("reversing_valve_operation"))
        #expect(heatPumpKeys.contains("defrost_control_status"))
        #expect(furnaceDefinitions.first { $0.key == "ignition_type" }?.options.contains("Hot Surface Ignition") == true)
        #expect(furnaceDefinitions.first { $0.key == "heat_exchanger_condition" }?.options.contains("Needs Repair") == true)
        #expect(waterHeaterDefinitions.first { $0.key == "tank_condition" }?.options.contains("Replacement Recommended") == true)
        #expect(airHandlerDefinitions.first { $0.key == "blower_type" }?.options.contains("ECM Variable Speed") == true)
        #expect(packageUnitDefinitions.first { $0.key == "package_heat_type" }?.options.contains("Dual Fuel") == true)
        #expect(packageUnitDefinitions.contains { $0.key == "economizer_operation" })
        #expect(packageUnitDefinitions.contains { $0.key == "flue_temp" })
        #expect(packageUnitDefinitions.contains { $0.key == "co_ppm" })
        #expect(miniSplitDefinitions.contains { $0.key == "communication_voltage" })
        #expect(miniSplitDefinitions.contains { $0.key == "indoor_filter_condition" })
    }

    @Test func packageUnitReportsRequireCombustionSafetyReading() async throws {
        let requiredKeys = Set(HVACEquipmentType.packageUnit.requiredReadingKeysForCompleteServiceReport)
        let definitionKeys = Set(HVACEquipmentType.packageUnit.readingDefinitions.map(\.key))

        #expect(definitionKeys.contains("co_ppm"))
        #expect(definitionKeys.contains("flue_temp"))
        #expect(requiredKeys.contains("co_ppm"))
        #expect(requiredKeys.isSubset(of: definitionKeys))
    }

    @Test func equipmentSpecificServiceActionsDriveMaintenanceCloseout() async throws {
        let splitActions = HVACEquipmentType.splitSystemAC.serviceActionDefinitions
        let furnaceActions = HVACEquipmentType.gasFurnace.serviceActionDefinitions

        #expect(splitActions.contains { $0.key == "condenser_coil_serviced" && $0.required })
        #expect(splitActions.contains { $0.key == "condensate_drain_checked" && $0.group == "Drainage" })
        #expect(furnaceActions.contains { $0.key == "heat_exchanger_checked" && $0.group == "Safety" && $0.required })
        #expect(furnaceActions.contains { $0.key == "flame_sensor_serviced" })
    }

    @Test func serviceCallStoresEquipmentServiceActionStatuses() async throws {
        let customer = Customer(name: "Action Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        call.setServiceActionStatus(.completed, for: "condenser_coil_serviced")
        call.setServiceActionStatus(.needsService, for: "condensate_drain_checked")

        #expect(call.serviceActionStatus(for: "condenser_coil_serviced") == .completed)
        #expect(call.serviceActionStatus(for: "condensate_drain_checked") == .needsService)
        #expect(call.populatedServiceActionRows.contains { $0.label == "Condenser coil inspected/washed" && $0.value == "Completed" })
        #expect(call.populatedServiceActionRows.contains { $0.label == "Condensate drain checked/treated" && $0.value == "Needs Service" })

        call.setServiceActionStatus(.notChecked, for: "condenser_coil_serviced")

        #expect(call.serviceActionStatus(for: "condenser_coil_serviced") == .notChecked)
        #expect(call.serviceActionStatus(for: "condensate_drain_checked") == .needsService)
    }

    @Test func maintenanceReportRequiresEquipmentServiceActions() async throws {
        let customer = Customer(name: "Maintenance Action Customer")
        let call = ServiceCall(
            equipmentName: "Main AC",
            equipmentModel: "24ABC",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Cooling maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }

        #expect(call.serviceReportMissingRequiredItemLabels.contains("Condenser coil inspected/washed"))

        for definition in call.requiredServiceActionDefinitions {
            call.setServiceActionStatus(.completed, for: definition.key)
        }

        #expect(call.serviceReportMissingRequiredItemLabels.contains("Condenser coil inspected/washed") == false)
    }

    @Test func hvacEquipmentReadingDefinitionKeysAreUniquePerEquipmentType() async throws {
        for equipmentType in HVACEquipmentType.allCases {
            let keys = equipmentType.readingDefinitions.map(\.key)
            #expect(Set(keys).count == keys.count, "\(equipmentType.displayName) has duplicate technical reading keys")
        }
    }

    @Test func groupedTechnicalReadingsPreserveAllEquipmentFields() async throws {
        for equipmentType in HVACEquipmentType.allCases {
            let definitions = equipmentType.readingDefinitions
            let groupedDefinitions = ServiceCall.groupedTechnicalReadingDefinitions(for: definitions)
                .flatMap(\.definitions)

            #expect(groupedDefinitions.count == definitions.count, "\(equipmentType.displayName) reading grouping dropped or duplicated fields")
            #expect(Set(groupedDefinitions.map(\.key)) == Set(definitions.map(\.key)), "\(equipmentType.displayName) reading grouping changed field coverage")
        }
    }

    @Test func groupedTechnicalReadingsUseFieldServiceCategories() async throws {
        let splitGroups = ServiceCall.groupedTechnicalReadingDefinitions(for: HVACEquipmentType.splitSystemAC.readingDefinitions)
        let furnaceGroups = ServiceCall.groupedTechnicalReadingDefinitions(for: HVACEquipmentType.gasFurnace.readingDefinitions)
        let boilerGroups = ServiceCall.groupedTechnicalReadingDefinitions(for: HVACEquipmentType.boiler.readingDefinitions)

        #expect(splitGroups.first { $0.title == "Refrigerant Circuit" }?.definitions.contains { $0.key == "superheat" } == true)
        #expect(splitGroups.first { $0.title == "Electrical" }?.definitions.contains { $0.key == "compressor_amps" } == true)
        #expect(furnaceGroups.first { $0.title == "Combustion" }?.definitions.contains { $0.key == "flue_temp" } == true)
        #expect(boilerGroups.first { $0.title == "Hydronics" }?.definitions.contains { $0.key == "water_temp_supply" } == true)
    }

    @Test func technicalReadingGroupProgressSummarizesCapturedRequiredAndInvalidFields() async throws {
        let customer = Customer(name: "Progress Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let electricalGroup = try #require(call.groupedTechnicalReadingDefinitions.first { $0.title == "Electrical" })

        call.setTechnicalReading("12", for: "line_voltage")
        call.setTechnicalReading("18", for: "compressor_rla")

        let progress = call.technicalReadingProgress(in: electricalGroup)

        #expect(progress.totalCount >= 4)
        #expect(progress.capturedCount == 2)
        #expect(progress.requiredCount == 3)
        #expect(progress.missingRequiredCount == 1)
        #expect(progress.validationIssueCount == 1)
        #expect(progress.needsAttention)
        #expect(progress.summary.contains("2/"))
        #expect(progress.summary.contains("invalid"))
    }

    @Test func prioritizedTechnicalReadingsPutMissingRequiredFieldsFirst() async throws {
        let customer = Customer(name: "Priority Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("12", for: "line_voltage")
        call.setTechnicalReading("18", for: "compressor_rla")
        let electricalGroup = try #require(call.groupedTechnicalReadingDefinitions.first { $0.title == "Electrical" })

        let prioritizedKeys = call.prioritizedTechnicalReadingDefinitions(in: electricalGroup).map(\.key)

        #expect(prioritizedKeys.first == "compressor_amps")
        #expect(prioritizedKeys.firstIndex(of: "compressor_amps")! < prioritizedKeys.firstIndex(of: "line_voltage")!)
        #expect(prioritizedKeys.firstIndex(of: "compressor_rla")! < prioritizedKeys.firstIndex(of: "control_voltage")!)
    }

    @Test func technicalReadingAttentionListIncludesMissingRequiredAndInvalidFields() async throws {
        let customer = Customer(name: "Attention Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("12", for: "line_voltage")
        call.setTechnicalReading("18", for: "compressor_rla")

        let attentionKeys = call.attentionTechnicalReadingDefinitions.map(\.key)

        #expect(attentionKeys.first == "compressor_amps")
        #expect(attentionKeys.contains("compressor_amps"))
        #expect(attentionKeys.contains("line_voltage"))
        #expect(attentionKeys.filter { $0 == "line_voltage" }.count == 1)
        #expect(attentionKeys.firstIndex(of: "compressor_amps")! < attentionKeys.firstIndex(of: "line_voltage")!)
        #expect(attentionKeys.contains("control_voltage") == false)
    }

    @Test func targetSuperheatAndSubcoolingDeviationBlocksReportCompletion() async throws {
        let customer = Customer(name: "Target Deviation Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        call.setTechnicalReading("10", for: "target_superheat")
        call.setTechnicalReading("18", for: "superheat")
        call.setTechnicalReading("9", for: "target_subcooling")
        call.setTechnicalReading("14", for: "subcooling")

        #expect(call.serviceReportMissingRequiredItemLabels.isEmpty)
        #expect(call.serviceReportReadingValidationIssueLabels.contains { $0.contains("Superheat differs from Target Superheat") })
        #expect(call.serviceReportReadingValidationIssueLabels.contains { $0.contains("Subcooling differs from Target Subcooling") })
        #expect(call.canCompleteDocumentation == false)

        let superheatDefinition = try #require(call.technicalReadingDefinitions.first { $0.key == "superheat" })
        let subcoolingDefinition = try #require(call.technicalReadingDefinitions.first { $0.key == "subcooling" })
        #expect(call.technicalReadingValidationIssue(for: superheatDefinition)?.contains("more than 5.0 F") == true)
        #expect(call.technicalReadingValidationIssue(for: subcoolingDefinition)?.contains("more than 3.0 F") == true)
    }

    @Test func clearingDerivedReadingSourceRemovesStaleCalculatedValues() async throws {
        let customer = Customer(name: "Derived Reading Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        call.setTechnicalReading("75", for: "return_air_temp")
        call.setTechnicalReading("55", for: "supply_air_temp")
        call.setTechnicalReading("52", for: "suction_saturation_temp")
        call.setTechnicalReading("62", for: "suction_line_temp")
        call.setTechnicalReading("95", for: "liquid_saturation_temp")
        call.setTechnicalReading("85", for: "liquid_line_temp")

        #expect(call.technicalReading(for: "temperature_split") == "20.0")
        #expect(call.technicalReading(for: "temperature_rise") == "-20.0")
        #expect(call.technicalReading(for: "superheat") == "10.0")
        #expect(call.technicalReading(for: "subcooling") == "10.0")

        call.setTechnicalReading("", for: "supply_air_temp")
        call.setTechnicalReading("", for: "suction_line_temp")
        call.setTechnicalReading("", for: "liquid_line_temp")

        #expect(call.technicalReading(for: "temperature_split").isEmpty)
        #expect(call.technicalReading(for: "temperature_rise").isEmpty)
        #expect(call.technicalReading(for: "superheat").isEmpty)
        #expect(call.technicalReading(for: "subcooling").isEmpty)
    }

    @Test func clearingStaticPressureSourceRemovesStaleTotalExternalStatic() async throws {
        let customer = Customer(name: "Static Reading Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.airHandler.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        call.setTechnicalReading("-0.35", for: "static_pressure_return")
        call.setTechnicalReading("0.42", for: "static_pressure_supply")

        #expect(call.technicalReading(for: "total_external_static") == "0.8")

        call.setTechnicalReading("", for: "static_pressure_supply")

        #expect(call.technicalReading(for: "total_external_static").isEmpty)
    }

    @Test func equipmentSpecificReportReadinessTracksMissingRequiredItems() async throws {
        let customer = Customer(name: "Readiness Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked and operating.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        #expect(call.serviceReportMissingRequirementLabels.contains("Refrigerant Type"))
        #expect(call.serviceReportMissingRequirementLabels.contains("Compressor Amps (A)"))
        #expect(call.serviceReportMissingRequirementLabels.contains("Equipment Name") == false)

        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }

        #expect(call.serviceReportMissingRequirementLabels.isEmpty)
        #expect(call.serviceReportReadinessSummary == "\(call.serviceReportRequiredItemCount)/\(call.serviceReportRequiredItemCount) required items")
    }

    @Test func changingEquipmentTypePrunesIncompatibleTechnicalReadings() async throws {
        let customer = Customer(name: "Equipment Type Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("R-410A", for: "refrigerant_type")
        call.setTechnicalReading("12", for: "superheat")
        call.setTechnicalReading("240", for: "line_voltage")

        call.equipmentType = .gasFurnace

        #expect(call.technicalReading(for: "refrigerant_type").isEmpty)
        #expect(call.technicalReading(for: "superheat").isEmpty)
        #expect(call.technicalReading(for: "line_voltage") == "240")
        #expect(call.technicalReadings.keys.contains("refrigerant_type") == false)
    }

    @Test func applyingEquipmentProfilePrunesPriorEquipmentTypeReadings() async throws {
        let customer = Customer(name: "Equipment Profile Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("R-410A", for: "refrigerant_type")
        call.setTechnicalReading("10", for: "subcooling")
        call.setTechnicalReading("240", for: "line_voltage")
        let furnace = CustomerEquipment(
            customer: customer,
            equipmentType: .gasFurnace,
            name: "Gas Furnace",
            modelNumber: "GM9C",
            serialNumber: "FURN123"
        )

        furnace.apply(to: call)

        #expect(call.equipmentType == .gasFurnace)
        #expect(call.technicalReading(for: "refrigerant_type").isEmpty)
        #expect(call.technicalReading(for: "subcooling").isEmpty)
        #expect(call.technicalReading(for: "line_voltage") == "240")
    }

    @Test func technicalReadingDefinitionsValidateExpectedFieldRanges() async throws {
        let voltage = HVACTechnicalReadingDefinition(key: "line_voltage", label: "Line Voltage", unit: "V")
        let superheat = HVACTechnicalReadingDefinition(key: "superheat", label: "Superheat", unit: "F")
        let condition = HVACTechnicalReadingDefinition(key: "condenser_condition", label: "Condenser Condition")

        #expect(voltage.expectedRangeLabel == "90-600 V")
        #expect(voltage.validationIssue(for: "240") == nil)
        #expect(voltage.validationIssue(for: "12")?.contains("outside expected range") == true)
        #expect(superheat.validationIssue(for: "not a number") == "Superheat (F) must be numeric")
        #expect(superheat.validationIssue(for: HVACTechnicalReadingDefinition.unableToTestValue) == nil)
        #expect(HVACTechnicalReadingDefinition.isNonNumericStatus("Not Applicable"))
        #expect(condition.validationIssue(for: "Needs Cleaning") == nil)
    }

    @Test func unableToTestReadingsCanSatisfyRequiredFieldCompletion() async throws {
        let customer = Customer(name: "Unable To Test Customer")
        let call = ServiceCall(
            equipmentName: "Main AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Unable to run cooling cycle during service.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(HVACTechnicalReadingDefinition.unableToTestValue, for: definition.key)
        }

        #expect(call.serviceReportMissingRequiredItemLabels.isEmpty)
        #expect(call.serviceReportReadingValidationIssueLabels.isEmpty)
        #expect(call.markDocumentationCompleteIfReady())
    }

    @Test func invalidTechnicalReadingsBlockReportCompletion() async throws {
        let customer = Customer(name: "Validation Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        call.setTechnicalReading("12", for: "line_voltage")

        #expect(call.serviceReportMissingRequiredItemLabels.isEmpty)
        #expect(call.serviceReportReadingValidationIssueLabels.contains { $0.contains("Line Voltage") })
        #expect(call.serviceReportReadinessSummary == "\(call.serviceReportRequiredItemCount)/\(call.serviceReportRequiredItemCount) required items • 1 invalid")
        #expect(call.canCompleteDocumentation == false)
        #expect(call.markDocumentationCompleteIfReady() == false)
        #expect(call.documentationCompletionBlockedMessage?.contains("Missing or invalid") == true)
        #expect(call.documentationCompletionBlockedMessage?.contains("Line Voltage") == true)
    }

    @Test func unsafeCarbonMonoxideReadingBlocksCombustionReportCompletion() async throws {
        let customer = Customer(name: "Combustion Safety Customer")
        let call = ServiceCall(
            equipmentName: "Gas Furnace",
            equipmentModel: "GM9C",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        call.setTechnicalReading("125", for: "co_ppm")

        #expect(call.serviceReportMissingRequiredItemLabels.isEmpty)
        #expect(call.serviceReportReadingValidationIssueLabels.contains { $0.contains("CO Reading") })
        #expect(call.serviceReportReadingValidationIssueLabels.contains { $0.contains("100 ppm") })
        let coDefinition = try #require(call.technicalReadingDefinitions.first { $0.key == "co_ppm" })
        #expect(call.technicalReadingValidationIssue(for: coDefinition)?.contains("100 ppm") == true)
        #expect(call.canCompleteDocumentation == false)
        #expect(call.markDocumentationCompleteIfReady() == false)
    }

    @Test func incompleteTechnicalServiceReportDoesNotMarkDocumentationComplete() async throws {
        let customer = Customer(name: "Incomplete Report Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("72", for: "return_air_temp")

        let markedComplete = call.markDocumentationCompleteIfReady(at: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(markedComplete == false)
        #expect(call.documentationCompletedAt == nil)
        #expect(call.documentationCompletionBlockedMessage?.contains("Supply Air Temp (F)") == true)
    }

    @Test func completeTechnicalServiceReportMarksDocumentationComplete() async throws {
        let customer = Customer(name: "Complete Report Customer")
        let completionDate = Date(timeIntervalSince1970: 1_800_000_000)
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }

        let markedComplete = call.markDocumentationCompleteIfReady(at: completionDate)

        #expect(markedComplete == true)
        #expect(call.documentationChecklist == true)
        #expect(call.documentationCompletedAt == completionDate)
        #expect(call.documentationCompletionBlockedMessage == nil)
    }

    @Test func incompleteTechnicalReportBlocksReadyToBillEvenWhenWorkIsComplete() async throws {
        let customer = Customer(name: "Incomplete Bill Ready Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )
        call.setTechnicalReading("72", for: "return_air_temp")

        #expect(call.canCompleteDocumentation == false)
        #expect(call.isReadyToCreateBillingDocument == false)
    }

    @Test func completeTechnicalReportAllowsReadyToBillBeforeInvoiceExists() async throws {
        let customer = Customer(name: "Bill Ready Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Cooling service completed.",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(HVACTechnicalReadingDefinition.unableToTestValue, for: definition.key)
        }

        #expect(call.canCompleteDocumentation)
        #expect(call.isReadyToCreateBillingDocument)

        call.linkedInvoiceID = UUID()
        #expect(call.isReadyToCreateBillingDocument == false)
    }

    @Test func incompleteTechnicalReportBlocksInvoiceCreation() async throws {
        let customer = Customer(name: "Blocked Invoice Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )
        call.setTechnicalReading("72", for: "return_air_temp")

        #expect(call.canCreateInvoiceDocument == false)
        #expect(call.invoiceCreationBlockedMessage?.contains("Missing or invalid") == true)
        #expect(call.invoiceCreationBlockedMessage?.contains("Supply Air Temp") == true)
    }

    @Test func estimateAppointmentCanCreateInvoiceWithoutTechnicalReport() async throws {
        let customer = Customer(name: "Accepted Estimate Customer")
        let call = ServiceCall(
            type: .estimate,
            scheduledDate: Date(),
            customer: customer,
            status: .completed
        )

        #expect(call.requiresTechnicalServiceReportCompletion == false)
        #expect(call.canCreateInvoiceDocument)
    }

    @Test func generalAppointmentCanBeReadyToBillWithoutTechnicalReport() async throws {
        let customer = Customer(name: "General Appointment Customer")
        let call = ServiceCall(
            type: .other,
            scheduledDate: Date(),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )

        #expect(call.requiresTechnicalServiceReportCompletion == false)
        #expect(call.isReadyToCreateBillingDocument)
    }

    @Test func jobCloseoutReadinessShowsMissingOperationalEvidence() async throws {
        let customer = Customer(name: "Closeout Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        let readiness = call.closeoutReadiness(invoice: nil, payments: [], attachments: [])

        #expect(readiness.isReady == false)
        #expect(readiness.missingItems.contains("Work completed"))
        #expect(readiness.missingItems.contains("Technical report complete"))
        #expect(readiness.missingItems.contains("Onsite report generated"))
        #expect(readiness.missingItems.contains("Before photo captured"))
        #expect(readiness.missingItems.contains("After photo captured"))
        #expect(readiness.missingItems.contains("Invoice created"))
    }

    @Test func jobCloseoutReadinessSummarizesPrimaryBlockersWithRemainderCount() async throws {
        let readiness = JobCloseoutReadiness(
            requiredItems: [
                "Work completed",
                "Technical report complete",
                "Onsite report generated",
                "Invoice created"
            ],
            missingItems: [
                "Work completed",
                "Technical report complete",
                "Onsite report generated",
                "Invoice created"
            ]
        )

        #expect(readiness.primaryMissingItem == "Work completed")
        #expect(readiness.missingSummary(limit: 2) == "Work completed, Technical report complete +2 more")
        #expect(readiness.missingSummary(limit: 10) == "Work completed, Technical report complete, Onsite report generated, Invoice created")
    }

    @Test func jobCloseoutReadinessMarksCompletedSyncedJobsReady() async throws {
        let customer = Customer(name: "Closeout Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .invoiced,
            workCompletedChecklist: true,
            documentationChecklist: true,
            paymentCollectedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let invoice = Invoice(
            serviceCallID: call.id,
            customer: customer,
            quickBooksID: "QB-100",
            amount: 500,
            status: "paid",
            customerSignatureName: "Customer",
            customerSignedAt: Date(),
            finalizedAt: Date()
        )
        call.linkedInvoiceID = invoice.id
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "ATTACH-1"
        )
        let beforePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .beforePhoto,
            displayName: "before.jpg",
            localFilePath: "/tmp/before.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512,
            quickBooksAttachableID: "ATTACH-2"
        )
        let afterPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .afterPhoto,
            displayName: "after.jpg",
            localFilePath: "/tmp/after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512,
            quickBooksAttachableID: "ATTACH-3"
        )

        let readiness = call.closeoutReadiness(invoice: invoice, payments: [], attachments: [report, beforePhoto, afterPhoto])

        #expect(readiness.isReady == true)
        #expect(readiness.statusLabel == "Ready for closeout")
        #expect(readiness.summary == "\(readiness.totalCount)/\(readiness.totalCount) complete")
    }

    @Test func serviceCloseoutRequiresBeforeAndAfterPhotoEvidence() async throws {
        let customer = Customer(name: "Photo Evidence Customer")
        let call = ServiceCall(
            equipmentName: "Main AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Cooling maintenance completed.",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let readiness = call.closeoutReadiness(invoice: nil, payments: [], attachments: [report])

        #expect(readiness.requiredItems.contains("Before photo captured"))
        #expect(readiness.requiredItems.contains("After photo captured"))
        #expect(readiness.missingItems.contains("Before photo captured"))
        #expect(readiness.missingItems.contains("After photo captured"))
        let photoStatus = call.photoEvidenceStatus(from: [report])
        #expect(photoStatus.isReady == false)
        #expect(photoStatus.statusLabel == "Before and after photos missing")
        #expect(photoStatus.summary == "0 before - 0 after")
    }

    @Test func serviceCloseoutAcceptsAttachedBeforeAndAfterPhotos() async throws {
        let customer = Customer(name: "Photo Evidence Customer")
        let call = ServiceCall(
            equipmentName: "Main AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Cooling maintenance completed.",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let beforePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .beforePhoto,
            displayName: "before.jpg",
            localFilePath: "/tmp/before.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512
        )
        let afterPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .afterPhoto,
            displayName: "after.jpg",
            localFilePath: "/tmp/after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512
        )

        let readiness = call.closeoutReadiness(invoice: nil, payments: [], attachments: [report, beforePhoto, afterPhoto])

        #expect(readiness.missingItems.contains("Before photo captured") == false)
        #expect(readiness.missingItems.contains("After photo captured") == false)
        let photoStatus = call.photoEvidenceStatus(from: [beforePhoto, afterPhoto])
        #expect(photoStatus.isReady)
        #expect(photoStatus.statusLabel == "Photo evidence complete")
        #expect(photoStatus.summary == "1 before - 1 after")
    }

    @Test func meetingCloseoutDoesNotRequireFieldPhotos() async throws {
        let customer = Customer(name: "Meeting Customer")
        let call = ServiceCall(
            type: .meeting,
            scheduledDate: Date(),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .serviceReport,
            displayName: "meeting-notes.pdf",
            localFilePath: "/tmp/meeting-notes.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let readiness = call.closeoutReadiness(invoice: nil, payments: [], attachments: [report])

        #expect(readiness.requiredItems.contains("Before photo captured") == false)
        #expect(readiness.requiredItems.contains("After photo captured") == false)
        #expect(readiness.missingItems.contains("Before photo captured") == false)
        #expect(readiness.missingItems.contains("After photo captured") == false)
    }

    @Test func jobCloseoutReadinessRequiresGeneratedReportLinkedToInvoice() async throws {
        let customer = Customer(name: "Closeout Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .invoiced,
            workCompletedChecklist: true,
            documentationChecklist: true,
            paymentCollectedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let invoice = Invoice(
            serviceCallID: call.id,
            customer: customer,
            quickBooksID: "QB-100",
            amount: 500,
            status: "paid",
            customerSignatureName: "Customer",
            customerSignedAt: Date(),
            finalizedAt: Date()
        )
        let unlinkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .serviceReport,
            displayName: "stale-report.pdf",
            localFilePath: "/tmp/stale-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "ATTACH-1"
        )

        let readiness = call.closeoutReadiness(invoice: invoice, payments: [], attachments: [unlinkedReport])

        #expect(readiness.isReady == false)
        #expect(readiness.missingItems.contains("Onsite report generated"))
    }

    @Test func jobCloseoutReadinessDetectsPendingQuickBooksAttachments() async throws {
        let customer = Customer(name: "Closeout Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .invoiced,
            workCompletedChecklist: true,
            documentationChecklist: true,
            paymentCollectedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let invoice = Invoice(
            serviceCallID: call.id,
            customer: customer,
            quickBooksID: "QB-100",
            amount: 500,
            status: "paid",
            customerSignatureName: "Customer",
            customerSignedAt: Date(),
            finalizedAt: Date()
        )
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let readiness = call.closeoutReadiness(invoice: invoice, payments: [], attachments: [report])

        #expect(readiness.isReady == false)
        #expect(readiness.missingItems.contains("QuickBooks attachments synced"))
    }

    @Test func invoiceDocumentationStatusTracksMissingPendingAndSyncedReports() async throws {
        let customer = Customer(name: "Invoice Documentation Customer")
        let call = ServiceCall(
            equipmentName: "Main AC",
            equipmentModel: "24ABC",
            equipmentSerialNumber: "AC123",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let invoice = Invoice(
            serviceCallID: call.id,
            customer: customer,
            quickBooksID: "QB-INV-1",
            amount: 500
        )

        let missing = call.invoiceDocumentationStatus(invoice: invoice, attachments: [])
        #expect(missing.isReady == false)
        #expect(missing.statusLabel == "Onsite report missing")

        let pendingReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let linkedPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .afterPhoto,
            displayName: "after-repair.jpg",
            localFilePath: "/tmp/after-repair.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )
        let linkedInvoicePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048
        )
        let pending = call.invoiceDocumentationStatus(invoice: invoice, attachments: [pendingReport, linkedPhoto, linkedInvoicePDF])
        #expect(pending.isReady == false)
        #expect(pending.statusLabel == "QuickBooks attachments pending")
        #expect(pending.linkedPhotoEvidenceCount == 1)
        #expect(pending.linkedBillingDocumentCount == 1)
        #expect(pending.pendingQuickBooksAttachmentCount == 3)
        #expect(pending.summary.contains("1 photo"))
        #expect(pending.summary.contains("1 billing PDF"))

        pendingReport.quickBooksAttachableID = "ATTACH-1"
        linkedPhoto.quickBooksAttachableID = "ATTACH-2"
        linkedInvoicePDF.quickBooksAttachableID = "ATTACH-3"
        let synced = call.invoiceDocumentationStatus(invoice: invoice, attachments: [pendingReport, linkedPhoto, linkedInvoicePDF])
        #expect(synced.isReady)
        #expect(synced.statusLabel == "Invoice documentation ready")
        #expect(synced.syncedQuickBooksAttachmentCount == 3)
    }

    @Test func estimateDocumentationStatusTracksMissingPendingAndSyncedReports() async throws {
        let customer = Customer(name: "Estimate Documentation Customer")
        let call = ServiceCall(
            equipmentName: "Main AC",
            equipmentModel: "24ABC",
            equipmentSerialNumber: "AC123",
            type: .estimate,
            scheduledDate: Date(),
            customer: customer
        )
        let estimate = Estimate(
            serviceCallID: call.id,
            customer: customer,
            quickBooksID: "QB-EST-1",
            amount: 500
        )

        let missing = call.estimateDocumentationStatus(estimate: estimate, attachments: [])
        #expect(missing.isReady == false)
        #expect(missing.statusLabel == "Onsite report missing")

        let pendingReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimate.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let linkedPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimate.id,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )
        let linkedEstimatePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimate.id,
            kind: .estimateSupport,
            displayName: "estimate.pdf",
            localFilePath: "/tmp/estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048
        )
        let pending = call.estimateDocumentationStatus(estimate: estimate, attachments: [pendingReport, linkedPhoto, linkedEstimatePDF])
        #expect(pending.isReady == false)
        #expect(pending.statusLabel == "QuickBooks attachments pending")
        #expect(pending.linkedPhotoEvidenceCount == 1)
        #expect(pending.linkedBillingDocumentCount == 1)
        #expect(pending.pendingQuickBooksAttachmentCount == 3)
        #expect(pending.summary.contains("1 photo"))
        #expect(pending.summary.contains("1 billing PDF"))

        pendingReport.quickBooksAttachableID = "ATTACH-EST-1"
        linkedPhoto.quickBooksAttachableID = "ATTACH-EST-2"
        linkedEstimatePDF.quickBooksAttachableID = "ATTACH-EST-3"
        let synced = call.estimateDocumentationStatus(estimate: estimate, attachments: [pendingReport, linkedPhoto, linkedEstimatePDF])
        #expect(synced.isReady)
        #expect(synced.statusLabel == "Estimate documentation ready")
        #expect(synced.syncedQuickBooksAttachmentCount == 3)
    }

    @Test func billingDocumentationPackageSummaryPrioritizesInvoicePackage() async throws {
        let customer = Customer(name: "Package Summary Customer")
        let call = ServiceCall(type: .maintenance, scheduledDate: Date(), customer: customer)
        let estimate = Estimate(serviceCallID: call.id, customer: customer, quickBooksID: "QB-EST", amount: 400)
        let invoice = Invoice(serviceCallID: call.id, customer: customer, quickBooksID: "QB-INV", amount: 400)
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            estimateID: estimate.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "ATTACH-1"
        )
        let photo = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            estimateID: estimate.id,
            kind: .afterPhoto,
            displayName: "after.jpg",
            localFilePath: "/tmp/after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "ATTACH-2"
        )

        let summary = try #require(call.billingDocumentationPackageSummary(
            invoice: invoice,
            estimate: estimate,
            attachments: [report, photo]
        ))

        #expect(summary.contains("Invoice documentation ready"))
        #expect(summary.contains("1 onsite report"))
        #expect(summary.contains("1 photo"))
        #expect(summary.contains("2 synced"))
    }

    @Test func billingDocumentationPackageSummaryFallsBackToEstimatePackage() async throws {
        let customer = Customer(name: "Estimate Package Summary Customer")
        let call = ServiceCall(type: .estimate, scheduledDate: Date(), customer: customer)
        let estimate = Estimate(serviceCallID: call.id, customer: customer, quickBooksID: "QB-EST", amount: 400)
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimate.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let summary = try #require(call.billingDocumentationPackageSummary(
            invoice: nil,
            estimate: estimate,
            attachments: [report]
        ))

        #expect(summary.contains("QuickBooks attachments pending"))
        #expect(summary.contains("1 onsite report"))
        #expect(summary.contains("1 pending"))
    }

    @Test func jobCloseoutReadinessRequiresQuickBooksInvoiceSync() async throws {
        let customer = Customer(name: "Closeout Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .invoiced,
            workCompletedChecklist: true,
            documentationChecklist: true,
            paymentCollectedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let invoice = Invoice(
            serviceCallID: call.id,
            customer: customer,
            amount: 500,
            status: "paid",
            customerSignatureName: "Customer",
            customerSignedAt: Date(),
            finalizedAt: Date()
        )
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let readiness = call.closeoutReadiness(invoice: invoice, payments: [], attachments: [report])

        #expect(readiness.isReady == false)
        #expect(readiness.requiredItems.contains("QuickBooks invoice synced"))
        #expect(readiness.missingItems.contains("QuickBooks invoice synced"))
        #expect(readiness.missingItems.contains("QuickBooks attachments synced") == false)
    }

    @Test func generalCalendarAppointmentsDoNotRequireTechnicalServiceReportForCompletion() async throws {
        let customer = Customer(name: "Calendar Customer")
        let completionDate = Date(timeIntervalSince1970: 1_800_000_000)
        let call = ServiceCall(
            type: .meeting,
            scheduledDate: Date(),
            customer: customer
        )

        let markedComplete = call.markDocumentationCompleteIfReady(at: completionDate)

        #expect(markedComplete == true)
        #expect(call.documentationCompletedAt == completionDate)
    }

    @Test func furnaceReportReadinessUsesCombustionSpecificRequirements() async throws {
        let customer = Customer(name: "Furnace Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        let requiredKeys = Set(call.requiredTechnicalReadingDefinitions.map { $0.key })

        #expect(requiredKeys.contains("gas_pressure_manifold"))
        #expect(requiredKeys.contains("heat_exchanger_condition"))
        #expect(requiredKeys.contains("co_ppm"))
        #expect(requiredKeys.contains("suction_pressure") == false)
    }

    @Test func packageUnitAndMiniSplitReadinessUseEquipmentSpecificRequirements() async throws {
        let customer = Customer(name: "Technical Customer")
        let packageCall = ServiceCall(
            equipmentName: "Roof Package Unit",
            equipmentModel: "48TC",
            equipmentSerialNumber: "RTU123",
            equipmentTypeRaw: HVACEquipmentType.packageUnit.rawValue,
            serviceReportSummary: "RTU maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let miniSplitCall = ServiceCall(
            equipmentName: "Office Mini Split",
            equipmentModel: "MSZ",
            equipmentSerialNumber: "MS123",
            equipmentTypeRaw: HVACEquipmentType.miniSplit.rawValue,
            serviceReportSummary: "Mini split maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        let packageRequiredKeys = Set(packageCall.requiredTechnicalReadingDefinitions.map(\.key))
        let miniSplitRequiredKeys = Set(miniSplitCall.requiredTechnicalReadingDefinitions.map(\.key))

        #expect(packageRequiredKeys.contains("package_heat_type"))
        #expect(packageRequiredKeys.contains("blower_amps"))
        #expect(packageRequiredKeys.contains("co_ppm"))
        #expect(packageRequiredKeys.contains("condenser_condition"))
        #expect(miniSplitRequiredKeys.contains("indoor_head_delta_t"))
        #expect(miniSplitRequiredKeys.contains("indoor_filter_condition"))
        #expect(miniSplitRequiredKeys.contains("remote_operation"))
    }

    @Test func coolingEquipmentRequiresSourceReadingsForSuperheatAndSubcooling() async throws {
        let requiredSourceKeys: Set<String> = [
            "suction_saturation_temp",
            "liquid_saturation_temp",
            "suction_line_temp",
            "liquid_line_temp",
            "superheat",
            "subcooling"
        ]

        for equipmentType in [HVACEquipmentType.splitSystemAC, .heatPump, .packageUnit, .miniSplit] {
            let requiredKeys = Set(equipmentType.requiredReadingKeysForCompleteServiceReport)
            #expect(requiredSourceKeys.isSubset(of: requiredKeys), "\(equipmentType.displayName) must require calculated refrigerant source readings")
        }
    }

    @Test func onsiteReportTechnicalSectionsUseGroupedCapturedReadings() async throws {
        let customer = Customer(name: "Report Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("12", for: "superheat")
        call.setTechnicalReading("6.2", for: "compressor_amps")
        call.setTechnicalReading("72", for: "return_air_temp")

        let sections = CustomerDocumentExporter.technicalReportSectionSummaries(for: call)

        #expect(sections.contains { section in
            section.title == "Technical Readings - Refrigerant Circuit" &&
                section.rows.contains { $0.label == "Superheat (F)" && $0.value == "12" }
        })
        #expect(sections.contains { section in
            section.title == "Technical Readings - Electrical" &&
                section.rows.contains { $0.label == "Compressor Amps (A)" && $0.value == "6.2" }
        })
        #expect(sections.contains { section in
            section.title == "Technical Readings - Air Temperatures" &&
                section.rows.contains { $0.label == "Return Air Temp (F)" && $0.value == "72" }
        })
        #expect(sections.flatMap(\.rows).contains {
            $0.label == "Subcooling (F)" && $0.value == "Missing Required Reading"
        })
    }

    @Test func onsiteReportTechnicalSectionsIncludePackageUnitCombustionReadings() async throws {
        let customer = Customer(name: "Package Report Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.packageUnit.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("325", for: "flue_temp")
        call.setTechnicalReading("18", for: "co_ppm")

        let rows = CustomerDocumentExporter.technicalReportSectionSummaries(for: call)
            .flatMap(\.rows)

        #expect(rows.contains { $0.label == "Flue Temp (F)" && $0.value == "325" })
        #expect(rows.contains { $0.label == "CO Reading (ppm)" && $0.value == "18" })
        #expect(rows.contains { $0.label == "CO Reading (ppm) Requirement" && $0.value == "Required" })
    }

    @Test func onsiteReportTechnicalSectionsMarkRequiredAndInvalidReadings() async throws {
        let customer = Customer(name: "Validation Report Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("12", for: "superheat")
        call.setTechnicalReading("12", for: "line_voltage")

        let rows = CustomerDocumentExporter.technicalReportSectionSummaries(for: call)
            .flatMap(\.rows)

        #expect(rows.contains { $0.label == "Superheat (F)" && $0.value == "12" })
        #expect(rows.contains { $0.label == "Superheat (F) Requirement" && $0.value == "Required" })
        #expect(rows.contains { $0.label == "Line Voltage (V)" && $0.value == "12" })
        #expect(rows.contains { $0.label == "Line Voltage (V) Requirement" && $0.value == "Required" })
        #expect(rows.contains { $0.label == "Line Voltage (V) Validation" && $0.value.contains("outside expected range") })
        #expect(rows.contains { $0.label == "Line Voltage (V) Validation" && $0.value.contains("90-600 V") })
    }

    @Test func onsiteReportReadinessRowsExposeMissingRequiredTechnicalItems() async throws {
        let customer = Customer(name: "Readiness Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked and operating.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("72", for: "return_air_temp")

        let rows = CustomerDocumentExporter.serviceReportReadinessRows(for: call)

        #expect(rows.contains { $0.label == "Completion" && $0.value == "Needs details" })
        #expect(rows.contains { $0.label == "Required Items" && $0.value == call.serviceReportReadinessSummary })
        #expect(rows.contains { $0.label == "Missing Required Items" && $0.value.contains("Supply Air Temp (F)") })
        #expect(rows.contains { $0.label == "Missing Required Items" && $0.value.contains("Compressor Amps (A)") })
    }

    @Test func onsiteReportReadinessRowsExposeInvalidTechnicalReadings() async throws {
        let customer = Customer(name: "Validation Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        call.setTechnicalReading("12", for: "line_voltage")

        let rows = CustomerDocumentExporter.serviceReportReadinessRows(for: call)

        #expect(rows.contains { $0.label == "Completion" && $0.value == "Needs details" })
        #expect(rows.contains { $0.label == "Required Items" && $0.value == call.serviceReportReadinessSummary })
        #expect(rows.contains { $0.label == "Required Items" && $0.value.contains("1 invalid") })
        #expect(rows.contains { $0.label == "Missing Required Items" } == false)
        #expect(rows.contains { $0.label == "Reading Validation" && $0.value.contains("Line Voltage") })
        #expect(rows.contains { $0.label == "Reading Validation" && $0.value.contains("90-600 V") })
    }

    @Test func onsiteReportReadinessRowsExposeUnsafeCarbonMonoxideReadings() async throws {
        let customer = Customer(name: "CO Report Customer")
        let call = ServiceCall(
            equipmentName: "Gas Furnace",
            equipmentModel: "GM9C",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        call.setTechnicalReading("125", for: "co_ppm")

        let rows = CustomerDocumentExporter.serviceReportReadinessRows(for: call)

        #expect(rows.contains { $0.label == "Completion" && $0.value == "Needs details" })
        #expect(rows.contains { $0.label == "Safety Alerts" && $0.value.contains("CO Reading") })
        #expect(rows.contains { $0.label == "Safety Alerts" && $0.value.contains("100 ppm") })
        #expect(rows.contains { $0.label == "Reading Validation" && $0.value.contains("CO Reading") })
        #expect(rows.contains { $0.label == "Reading Validation" && $0.value.contains("100 ppm") })
    }

    @Test func onsiteReportTechnicalRowsExposeCrossReadingValidation() async throws {
        let customer = Customer(name: "Technical Export Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("10", for: "target_superheat")
        call.setTechnicalReading("18", for: "superheat")

        let summaries = CustomerDocumentExporter.technicalReportSectionSummaries(for: call)
        let refrigerantRows = try #require(summaries.first { $0.title == "Technical Readings - Refrigerant Circuit" }?.rows)

        #expect(refrigerantRows.contains { $0.label == "Superheat (F) Validation" && $0.value.contains("Target Superheat") })
    }

    @Test func onsiteReportCloseoutRowsExposeIntegratedJobReadiness() async throws {
        let customer = Customer(name: "Closeout Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        let rows = CustomerDocumentExporter.closeoutReadinessRows(
            for: call,
            invoice: nil,
            payments: [],
            attachments: []
        )

        #expect(rows.contains { $0.label == "Status" && $0.value == "Needs closeout details" })
        #expect(rows.contains { $0.label == "Progress" && $0.value.contains("complete") })
        #expect(rows.contains { $0.label == "Missing Closeout Items" && $0.value.contains("Invoice created") })
        #expect(rows.contains { $0.label == "Missing Closeout Items" && $0.value.contains("Onsite report generated") })
    }

    @Test func closeoutReadinessFlagsUnlinkedSameJobQuickBooksAttachments() async throws {
        let customer = Customer(name: "Closeout Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            workCompletedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let invoice = Invoice(
            serviceCallID: call.id,
            customer: customer,
            quickBooksID: "INV-123",
            amount: 400,
            status: "paid",
            customerSignedAt: Date(),
            finalizedAt: Date()
        )
        let generatedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048,
            quickBooksAttachableID: "attach-report"
        )
        let unlinkedJobPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: nil,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )

        let readiness = call.closeoutReadiness(
            invoice: invoice,
            payments: [],
            attachments: [generatedReport, unlinkedJobPhoto]
        )

        #expect(readiness.missingItems.contains("QuickBooks attachments synced"))
    }

    @Test func onsiteReportReadinessRowsMarkCompleteReportsReady() async throws {
        let customer = Customer(name: "Ready Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }

        let rows = CustomerDocumentExporter.serviceReportReadinessRows(for: call)

        #expect(rows.contains { $0.label == "Completion" && $0.value == "Ready" })
        #expect(rows.contains { $0.label == "Required Items" && $0.value == call.serviceReportReadinessSummary })
        #expect(rows.contains { $0.label == "Missing Required Items" } == false)
    }

    @Test func billingDocumentJobContextIncludesEquipmentDetails() async throws {
        let customer = Customer(
            name: "Billing Customer",
            phone: "555-0200",
            email: "billing@example.com",
            address: "123 Service Rd"
        )
        let technician = Technician(name: "Lead Tech")
        let callID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let call = ServiceCall(
            id: callID,
            equipmentName: "Main Furnace",
            equipmentManufacturer: "Carrier",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentLocation: "Attic",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            equipmentNotes: "Requires low-profile filter access panel.",
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            assignedTechnician: technician,
            customer: customer
        )

        let rows = CustomerDocumentExporter.billingJobContextSummaries(for: call)

        #expect(rows.contains { $0.label == "Job ID" && $0.value == "AAAAAAAA" })
        #expect(rows.contains { $0.label == "Customer" && $0.value == "Billing Customer" })
        #expect(rows.contains { $0.label == "Customer Phone" && $0.value == "555-0200" })
        #expect(rows.contains { $0.label == "Customer Email" && $0.value == "billing@example.com" })
        #expect(rows.contains { $0.label == "Equipment" && $0.value.contains("Gas Furnace") })
        #expect(rows.contains { $0.label == "Equipment" && $0.value.contains("Carrier") })
        #expect(rows.contains { $0.label == "Equipment" && $0.value.contains("S/N FURN123") })
        #expect(rows.contains { $0.label == "Equipment Location" && $0.value == "Attic" })
        #expect(rows.contains { $0.label == "Equipment Notes" && $0.value == "Requires low-profile filter access panel." })
    }

    @Test func serviceCallCalculatesTechnicalReadingsFromFieldInputs() async throws {
        let customer = Customer(name: "Diagnostic Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("75", for: "return_air_temp")
        call.setTechnicalReading("56", for: "supply_air_temp")
        call.setTechnicalReading("52", for: "suction_line_temp")
        call.setTechnicalReading("40", for: "suction_saturation_temp")
        call.setTechnicalReading("90", for: "liquid_line_temp")
        call.setTechnicalReading("100", for: "liquid_saturation_temp")

        #expect(call.calculateTemperatureSplitReading() == 19)
        #expect(call.calculateTemperatureRiseReading() == -19)
        #expect(call.calculateSuperheatReading() == 12)
        #expect(call.calculateSubcoolingReading() == 10)
        #expect(call.technicalReading(for: "temperature_split") == "19.0")
        #expect(call.technicalReading(for: "temperature_rise") == "-19.0")
        #expect(call.technicalReading(for: "superheat") == "12.0")
        #expect(call.technicalReading(for: "subcooling") == "10.0")
    }

    @Test func serviceCallAutomaticallyCalculatesDerivedTechnicalReadingsFromSourceInputs() async throws {
        let customer = Customer(name: "Auto Diagnostic Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        call.setTechnicalReading("75", for: "return_air_temp")
        #expect(call.technicalReading(for: "temperature_split").isEmpty)
        #expect(call.technicalReading(for: "temperature_rise").isEmpty)
        call.setTechnicalReading("56", for: "supply_air_temp")
        #expect(call.technicalReading(for: "temperature_split") == "19.0")
        #expect(call.technicalReading(for: "temperature_rise") == "-19.0")

        call.setTechnicalReading("52", for: "suction_line_temp")
        call.setTechnicalReading("40", for: "suction_saturation_temp")
        #expect(call.technicalReading(for: "superheat") == "12.0")

        call.setTechnicalReading("90", for: "liquid_line_temp")
        call.setTechnicalReading("100", for: "liquid_saturation_temp")
        #expect(call.technicalReading(for: "subcooling") == "10.0")

        call.setTechnicalReading("-0.32", for: "static_pressure_return")
        call.setTechnicalReading("0.28", for: "static_pressure_supply")
        #expect(call.technicalReading(for: "total_external_static") == "0.6")
    }

    @Test func airHandlerCalculatesTotalExternalStaticFromReturnAndSupplyReadings() async throws {
        let customer = Customer(name: "Static Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.airHandler.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("-0.32", for: "static_pressure_return")
        call.setTechnicalReading("0.28", for: "static_pressure_supply")

        let totalStatic = try #require(call.calculateTotalExternalStaticReading())
        #expect(abs(totalStatic - 0.6) < 0.001)
        #expect(call.technicalReading(for: "total_external_static") == "0.6")
    }

    @Test func gasFurnaceCalculatesTemperatureRiseFromSupplyAndReturnReadings() async throws {
        let customer = Customer(name: "Furnace Diagnostic Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("68", for: "return_air_temp")
        call.setTechnicalReading("122", for: "supply_air_temp")

        let rise = try #require(call.calculateTemperatureRiseReading())
        #expect(rise == 54)
        #expect(call.technicalReading(for: "temperature_rise") == "54.0")
        #expect(call.requiredTechnicalReadingDefinitions.contains { $0.key == "temperature_rise" })
    }

    @Test func quickBooksMimeTypeDetection() async throws {
        #expect(QuickBooksDataAPI.mimeType(for: URL(fileURLWithPath: "/tmp/file.jpg")) == "image/jpeg")
        #expect(QuickBooksDataAPI.mimeType(for: URL(fileURLWithPath: "/tmp/file.pdf")) == "application/pdf")
        #expect(QuickBooksDataAPI.mimeType(for: URL(fileURLWithPath: "/tmp/file.unknown")) == "application/octet-stream")
    }

    @Test func quickBooksUploadBodyContainsExpectedParts() async throws {
        let boundary = "Boundary-Test"
        let filename = "receipt.jpg"
        let contentType = "image/jpeg"
        let fileData = Data([0x01, 0x02, 0x03])
        let metadataJSON = #"{"FileName":"receipt.jpg","ContentType":"image/jpeg","Note":"Uploaded from test"}"#

        let body = QuickBooksDataAPI.buildUploadBody(
            boundary: boundary,
            filename: filename,
            contentType: contentType,
            fileData: fileData,
            metadataJSON: metadataJSON
        )
        let bodyString = String(data: body, encoding: .utf8) ?? ""

        #expect(bodyString.contains("name=\"file_metadata_01\""))
        #expect(bodyString.contains(metadataJSON))
        #expect(bodyString.contains("name=\"file_content_01\"; filename=\"\(filename)\""))
        #expect(bodyString.contains("Content-Type: \(contentType)"))
        #expect(bodyString.contains("--\(boundary)--"))
    }

    @Test func serviceReportAttachmentKindIsDocument() async throws {
        #expect(ServiceDocumentAttachmentKind.serviceReport.label == "Service Report")
        #expect(ServiceDocumentAttachmentKind.serviceReport.isPhoto == false)
    }

    @Test func serviceReportAttachmentLinksToInvoiceWhenMissing() async throws {
        let customer = Customer(name: "Report Customer")
        let invoice = Invoice(customer: customer, amount: 250)
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let alreadyLinkedInvoiceID = UUID()
        let alreadyLinkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: alreadyLinkedInvoiceID,
            kind: .serviceReport,
            displayName: "existing-report.pdf",
            localFilePath: "/tmp/existing-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        report.linkToInvoiceIfNeeded(invoice)
        alreadyLinkedReport.linkToInvoiceIfNeeded(invoice)

        #expect(report.canLinkToInvoiceReport == true)
        #expect(report.invoiceID == invoice.id)
        #expect(alreadyLinkedReport.invoiceID == alreadyLinkedInvoiceID)
    }

    @Test func linkingAttachmentToNewBillingTargetClearsStaleQuickBooksAttachmentState() async throws {
        let customer = Customer(name: "Report Customer")
        let estimate = Estimate(customer: customer, quickBooksID: "QB-EST-1", amount: 250)
        let invoice = Invoice(customer: customer, quickBooksID: "QB-INV-1", amount: 250)
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            estimateID: estimate.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "estimate-attachable",
            quickBooksSyncError: "old estimate target"
        )

        report.linkToInvoiceIfNeeded(invoice)

        #expect(report.invoiceID == invoice.id)
        #expect(report.estimateID == estimate.id)
        #expect(report.quickBooksAttachableID == nil)
        #expect(report.quickBooksSyncError == nil)
        #expect(report.canBePendingQuickBooksInvoiceAttachment(for: invoice))
    }

    @Test func customerEmailAttachmentsIncludeLatestLinkedOnsiteReport() async throws {
        let customer = Customer(name: "Email Report Customer")
        let serviceCallID = UUID()
        let invoiceURL = URL(fileURLWithPath: "/tmp/gunnaire-invoice.pdf")
        let olderReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "older-report.pdf",
            localFilePath: "/tmp/older-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let latestReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "latest-report.pdf",
            localFilePath: "/tmp/latest-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let unrelatedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .serviceReport,
            displayName: "unrelated-report.pdf",
            localFilePath: "/tmp/unrelated-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 300)
        )

        let urls = CustomerDocumentExporter.customerEmailAttachmentURLs(
            primaryDocumentURL: invoiceURL,
            serviceCallID: serviceCallID,
            attachments: [olderReport, unrelatedReport, latestReport]
        )

        #expect(urls.map(\.lastPathComponent) == ["gunnaire-invoice.pdf", "latest-report.pdf"])
    }

    @Test func customerEmailAttachmentsDoNotDuplicatePrimaryOnsiteReport() async throws {
        let customer = Customer(name: "Email Report Customer")
        let serviceCallID = UUID()
        let reportURL = URL(fileURLWithPath: "/tmp/latest-report.pdf")
        let latestReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "latest-report.pdf",
            localFilePath: reportURL.path,
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let urls = CustomerDocumentExporter.customerEmailAttachmentURLs(
            primaryDocumentURL: reportURL,
            serviceCallID: serviceCallID,
            attachments: [latestReport]
        )

        #expect(urls.map(\.lastPathComponent) == ["latest-report.pdf"])
    }

    @Test func customerEmailAttachmentsPreferReportLinkedToInvoice() async throws {
        let customer = Customer(name: "Email Report Customer")
        let serviceCallID = UUID()
        let invoiceID = UUID()
        let otherInvoiceID = UUID()
        let invoiceURL = URL(fileURLWithPath: "/tmp/gunnaire-invoice.pdf")
        let newestWrongInvoiceReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            invoiceID: otherInvoiceID,
            kind: .serviceReport,
            displayName: "wrong-invoice-report.pdf",
            localFilePath: "/tmp/wrong-invoice-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let linkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            kind: .serviceReport,
            displayName: "linked-invoice-report.pdf",
            localFilePath: "/tmp/linked-invoice-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let urls = CustomerDocumentExporter.customerEmailAttachmentURLs(
            primaryDocumentURL: invoiceURL,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            attachments: [newestWrongInvoiceReport, linkedReport]
        )

        #expect(urls.map(\.lastPathComponent) == ["gunnaire-invoice.pdf", "linked-invoice-report.pdf"])
    }

    @Test func customerEmailAttachmentsDoNotFallbackToUnlinkedReportForInvoice() async throws {
        let customer = Customer(name: "Email Report Customer")
        let serviceCallID = UUID()
        let invoiceID = UUID()
        let invoiceURL = URL(fileURLWithPath: "/tmp/gunnaire-invoice.pdf")
        let unlinkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "unlinked-report.pdf",
            localFilePath: "/tmp/unlinked-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 300)
        )

        let urls = CustomerDocumentExporter.customerEmailAttachmentURLs(
            primaryDocumentURL: invoiceURL,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            attachments: [unlinkedReport]
        )

        #expect(urls.map(\.lastPathComponent) == ["gunnaire-invoice.pdf"])
    }

    @Test func customerEmailAttachmentsPreferReportLinkedToEstimate() async throws {
        let customer = Customer(name: "Email Estimate Customer")
        let serviceCallID = UUID()
        let estimateID = UUID()
        let otherEstimateID = UUID()
        let estimateURL = URL(fileURLWithPath: "/tmp/gunnaire-estimate.pdf")
        let newestWrongEstimateReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            estimateID: otherEstimateID,
            kind: .serviceReport,
            displayName: "wrong-estimate-report.pdf",
            localFilePath: "/tmp/wrong-estimate-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let linkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            estimateID: estimateID,
            kind: .serviceReport,
            displayName: "linked-estimate-report.pdf",
            localFilePath: "/tmp/linked-estimate-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let urls = CustomerDocumentExporter.customerEmailAttachmentURLs(
            primaryDocumentURL: estimateURL,
            serviceCallID: serviceCallID,
            estimateID: estimateID,
            attachments: [newestWrongEstimateReport, linkedReport]
        )

        #expect(urls.map(\.lastPathComponent) == ["gunnaire-estimate.pdf", "linked-estimate-report.pdf"])
    }

    @Test func serviceReportAttachmentLinksToEstimateWhenMissing() async throws {
        let customer = Customer(name: "Estimate Report Customer")
        let estimate = Estimate(customer: customer, amount: 250)
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let alreadyLinkedEstimateID = UUID()
        let alreadyLinkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            estimateID: alreadyLinkedEstimateID,
            kind: .serviceReport,
            displayName: "existing-estimate-report.pdf",
            localFilePath: "/tmp/existing-estimate-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        report.linkToEstimateIfNeeded(estimate)
        alreadyLinkedReport.linkToEstimateIfNeeded(estimate)

        #expect(report.estimateID == estimate.id)
        #expect(alreadyLinkedReport.estimateID == alreadyLinkedEstimateID)
    }

    @Test func invoiceAttachmentUploadEligibilityRequiresLinkedQuickBooksInvoice() async throws {
        let customer = Customer(name: "Report Customer")
        let otherCustomer = Customer(name: "Other Report Customer")
        let invoice = Invoice(customer: customer, quickBooksID: "123", amount: 250)
        let estimate = Estimate(customer: customer, quickBooksID: "789", amount: 250)
        let unSyncedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let uploadedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "uploaded-report.pdf",
            localFilePath: "/tmp/uploaded-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "attach-1"
        )
        let estimateSupport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            estimateID: estimate.id,
            kind: .estimateSupport,
            displayName: "estimate-support.pdf",
            localFilePath: "/tmp/estimate-support.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let photo = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let invoiceSupport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .invoiceSupport,
            displayName: "invoice-support.pdf",
            localFilePath: "/tmp/invoice-support.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let receipt = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .receipt,
            displayName: "receipt.jpg",
            localFilePath: "/tmp/receipt.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let wrongCustomerInvoiceAttachment = ServiceDocumentAttachment(
            customer: otherCustomer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .customerDocument,
            displayName: "wrong-customer-invoice.pdf",
            localFilePath: "/tmp/wrong-customer-invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let wrongCustomerEstimateAttachment = ServiceDocumentAttachment(
            customer: otherCustomer,
            serviceCallID: UUID(),
            estimateID: estimate.id,
            kind: .customerDocument,
            displayName: "wrong-customer-estimate.pdf",
            localFilePath: "/tmp/wrong-customer-estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let localOnlyInvoice = Invoice(customer: customer, amount: 250)
        let localOnlyEstimate = Estimate(customer: customer, amount: 250)

        #expect(unSyncedReport.canUploadToQuickBooksInvoice(invoice) == true)
        #expect(uploadedReport.canUploadToQuickBooksInvoice(invoice) == false)
        #expect(photo.canUploadToQuickBooksInvoice(invoice) == true)
        #expect(invoiceSupport.canUploadToQuickBooksInvoice(invoice) == true)
        #expect(invoiceSupport.canUploadToQuickBooksEstimate(estimate) == false)
        #expect(estimateSupport.canUploadToQuickBooksInvoice(invoice) == false)
        #expect(receipt.canUploadToQuickBooksInvoice(invoice) == false)
        #expect(wrongCustomerInvoiceAttachment.canUploadToQuickBooksInvoice(invoice) == false)
        #expect(unSyncedReport.canUploadToQuickBooksInvoice(localOnlyInvoice) == false)
        #expect(unSyncedReport.canBePendingQuickBooksInvoiceAttachment(for: invoice) == true)
        #expect(uploadedReport.canBePendingQuickBooksInvoiceAttachment(for: invoice) == false)
        #expect(receipt.canBePendingQuickBooksInvoiceAttachment(for: invoice) == false)
        #expect(wrongCustomerInvoiceAttachment.canBePendingQuickBooksInvoiceAttachment(for: invoice) == false)
        #expect(estimateSupport.canUploadToQuickBooksEstimate(estimate) == true)
        #expect(wrongCustomerEstimateAttachment.canUploadToQuickBooksEstimate(estimate) == false)
        #expect(estimateSupport.canUploadToQuickBooksEstimate(localOnlyEstimate) == false)
        #expect(receipt.canUploadToQuickBooksEstimate(estimate) == false)
    }

    @MainActor
    @Test func quickBooksInvoiceAttachmentSyncFindsPendingInvoiceAttachments() async throws {
        let customer = Customer(name: "Report Customer")
        let invoice = Invoice(customer: customer, quickBooksID: "123", amount: 250)
        let otherInvoice = Invoice(customer: customer, quickBooksID: "456", amount: 100)
        let pendingReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let uploadedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: otherInvoice.id,
            kind: .serviceReport,
            displayName: "uploaded-report.pdf",
            localFilePath: "/tmp/uploaded-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "attach-1"
        )
        let pendingPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let receipt = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .receipt,
            displayName: "receipt.jpg",
            localFilePath: "/tmp/receipt.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )

        let pending = QuickBooksInvoiceAttachmentSync.pendingInvoiceAttachments(
            invoices: [invoice, otherInvoice],
            attachments: [pendingReport, uploadedReport, pendingPhoto, receipt]
        )

        #expect(pending.count == 2)
        #expect(pending.contains { $0.attachment === pendingReport && $0.invoice === invoice })
        #expect(pending.contains { $0.attachment === pendingPhoto && $0.invoice === invoice })
        #expect(pending.contains { $0.attachment === receipt } == false)
    }

    @MainActor
    @Test func quickBooksAttachmentSyncLinksJobDocumentsToBillingDocumentsBeforeUpload() async throws {
        let customer = Customer(name: "Linked Customer")
        let otherCustomer = Customer(name: "Other Customer")
        let serviceCallID = UUID()
        let invoice = Invoice(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "INV-123",
            amount: 450
        )
        let estimate = Estimate(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "EST-123",
            amount: 450
        )
        let serviceReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let diagnosticPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let mismatchedCustomerDocument = ServiceDocumentAttachment(
            customer: otherCustomer,
            serviceCallID: serviceCallID,
            kind: .customerDocument,
            displayName: "wrong-customer.pdf",
            localFilePath: "/tmp/wrong-customer.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let changedCount = QuickBooksInvoiceAttachmentSync.linkServiceCallAttachmentsToBillingDocuments(
            estimates: [estimate],
            invoices: [invoice],
            attachments: [serviceReport, diagnosticPhoto, mismatchedCustomerDocument]
        )
        let pendingInvoices = QuickBooksInvoiceAttachmentSync.pendingInvoiceAttachments(
            invoices: [invoice],
            attachments: [serviceReport, diagnosticPhoto, mismatchedCustomerDocument]
        )
        let pendingEstimates = QuickBooksInvoiceAttachmentSync.pendingEstimateAttachments(
            estimates: [estimate],
            attachments: [serviceReport, diagnosticPhoto, mismatchedCustomerDocument]
        )
        let pendingUploads = QuickBooksInvoiceAttachmentSync.pendingQuickBooksAttachmentUploads(
            estimates: [estimate],
            invoices: [invoice],
            attachments: [serviceReport, diagnosticPhoto, mismatchedCustomerDocument]
        )
        let serviceReportRefs = QuickBooksInvoiceAttachmentSync.quickBooksAttachableReferences(
            for: serviceReport,
            estimates: [estimate],
            invoices: [invoice]
        )

        #expect(changedCount == 4)
        #expect(serviceReport.invoiceID == invoice.id)
        #expect(serviceReport.estimateID == estimate.id)
        #expect(diagnosticPhoto.invoiceID == invoice.id)
        #expect(diagnosticPhoto.estimateID == estimate.id)
        #expect(mismatchedCustomerDocument.invoiceID == nil)
        #expect(mismatchedCustomerDocument.estimateID == nil)
        #expect(pendingInvoices.contains { $0.attachment === serviceReport && $0.invoice === invoice })
        #expect(pendingInvoices.contains { $0.attachment === diagnosticPhoto && $0.invoice === invoice })
        #expect(pendingEstimates.contains { $0.attachment === serviceReport && $0.estimate === estimate })
        #expect(pendingEstimates.contains { $0.attachment === diagnosticPhoto && $0.estimate === estimate })
        #expect(pendingUploads.count == 2)
        #expect(pendingUploads.contains { $0 === serviceReport })
        #expect(pendingUploads.contains { $0 === diagnosticPhoto })
        #expect(serviceReportRefs.map(\.EntityRef.type) == ["Invoice", "Estimate"])
        #expect(serviceReportRefs.map(\.EntityRef.value) == ["INV-123", "EST-123"])
    }

    @MainActor
    @Test func quickBooksAttachmentSyncFindsPendingEstimateAttachments() async throws {
        let customer = Customer(name: "Estimate Attachment Customer")
        let estimate = Estimate(customer: customer, quickBooksID: "EST-123", amount: 250)
        let localOnlyEstimate = Estimate(customer: customer, amount: 100)
        let pendingEstimatePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            estimateID: estimate.id,
            kind: .estimateSupport,
            displayName: "estimate.pdf",
            localFilePath: "/tmp/estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let uploadedEstimatePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            estimateID: estimate.id,
            kind: .estimateSupport,
            displayName: "uploaded-estimate.pdf",
            localFilePath: "/tmp/uploaded-estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "attach-1"
        )
        let localOnlyAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            estimateID: localOnlyEstimate.id,
            kind: .estimateSupport,
            displayName: "local-estimate.pdf",
            localFilePath: "/tmp/local-estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let pending = QuickBooksInvoiceAttachmentSync.pendingEstimateAttachments(
            estimates: [estimate, localOnlyEstimate],
            attachments: [pendingEstimatePDF, uploadedEstimatePDF, localOnlyAttachment]
        )

        #expect(pending.count == 1)
        #expect(pending.contains { $0.attachment === pendingEstimatePDF && $0.estimate === estimate })
    }

    @MainActor
    @Test func quickBooksAttachmentSyncQueuesGeneratedBillingPDFsLinkedByServiceCall() async throws {
        let customer = Customer(name: "Generated Billing Customer")
        let serviceCallID = UUID()
        let invoice = Invoice(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "INV-123",
            amount: 450
        )
        let estimate = Estimate(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "EST-123",
            amount: 450
        )
        let generatedInvoicePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .invoiceSupport,
            displayName: "paid-invoice.pdf",
            localFilePath: "/tmp/paid-invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048
        )
        let generatedEstimatePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .estimateSupport,
            displayName: "estimate.pdf",
            localFilePath: "/tmp/estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048
        )

        let changed = QuickBooksInvoiceAttachmentSync.linkServiceCallAttachmentsToBillingDocuments(
            estimates: [estimate],
            invoices: [invoice],
            attachments: [generatedInvoicePDF, generatedEstimatePDF]
        )
        let pendingInvoices = QuickBooksInvoiceAttachmentSync.pendingInvoiceAttachments(
            invoices: [invoice],
            attachments: [generatedInvoicePDF, generatedEstimatePDF]
        )
        let pendingEstimates = QuickBooksInvoiceAttachmentSync.pendingEstimateAttachments(
            estimates: [estimate],
            attachments: [generatedInvoicePDF, generatedEstimatePDF]
        )

        #expect(changed == 2)
        #expect(generatedInvoicePDF.invoiceID == invoice.id)
        #expect(generatedInvoicePDF.estimateID == nil)
        #expect(generatedEstimatePDF.invoiceID == nil)
        #expect(generatedEstimatePDF.estimateID == estimate.id)
        #expect(pendingInvoices.contains { $0.attachment === generatedInvoicePDF && $0.invoice === invoice })
        #expect(pendingInvoices.contains { $0.attachment === generatedEstimatePDF } == false)
        #expect(pendingEstimates.contains { $0.attachment === generatedInvoicePDF } == false)
        #expect(pendingEstimates.contains { $0.attachment === generatedEstimatePDF && $0.estimate === estimate })
    }

    @Test func serviceDocumentAttachmentExposesLocalFileURLForOpening() async throws {
        let attachment = ServiceDocumentAttachment(
            customer: nil,
            serviceCallID: nil,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128
        )

        #expect(attachment.localFileURL.isFileURL)
        #expect(attachment.localFileURL.path == "/tmp/diagnostic.jpg")
        #expect(attachment.isImage == true)
    }

    @Test func customerPrimaryPhotoPrefersProfileCaptionedImage() async throws {
        let customer = Customer(name: "Photo Customer")
        let olderDiagnostic = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_300)
        )
        let profilePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .customerDocument,
            displayName: "customer.jpg",
            caption: "Profile photo",
            localFilePath: "/tmp/customer.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let generatedReportImage = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .serviceReport,
            displayName: "report-preview.png",
            localFilePath: "/tmp/report-preview.png",
            contentType: "image/png",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_400)
        )

        let selected = ServiceDocumentAttachment.primaryCustomerPhoto(
            for: customer,
            in: [olderDiagnostic, profilePhoto, generatedReportImage]
        )

        #expect(selected === profilePhoto)
    }

    @Test func customerPrimaryPhotoFallsBackToLatestUsableImageForThatCustomer() async throws {
        let customer = Customer(name: "Photo Customer")
        let otherCustomer = Customer(name: "Other Customer")
        let olderPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .beforePhoto,
            displayName: "older.jpg",
            localFilePath: "/tmp/older.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let newerPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .diagnosticPhoto,
            displayName: "newer.jpg",
            localFilePath: "/tmp/newer.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_200)
        )
        let unrelatedPhoto = ServiceDocumentAttachment(
            customer: otherCustomer,
            serviceCallID: nil,
            kind: .diagnosticPhoto,
            displayName: "other.jpg",
            localFilePath: "/tmp/other.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_300)
        )
        let nonImage = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .customerDocument,
            displayName: "manual.pdf",
            localFilePath: "/tmp/manual.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_400)
        )

        let selected = ServiceDocumentAttachment.primaryCustomerPhoto(
            for: customer,
            in: [olderPhoto, newerPhoto, unrelatedPhoto, nonImage]
        )

        #expect(selected === newerPhoto)
    }

    @Test func customerPrimaryPhotoPrefersCustomerLevelImageOverEquipmentPhoto() async throws {
        let customer = Customer(name: "Photo Customer")
        let equipmentPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            customerEquipmentID: UUID(),
            kind: .diagnosticPhoto,
            displayName: "profile-equipment.jpg",
            caption: "Profile photo from service visit",
            localFilePath: "/tmp/profile-equipment.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_300)
        )
        let customerLevelPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: nil,
            kind: .customerDocument,
            displayName: "customer-front.jpg",
            localFilePath: "/tmp/customer-front.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let selected = ServiceDocumentAttachment.primaryCustomerPhoto(
            for: customer,
            in: [equipmentPhoto, customerLevelPhoto]
        )

        #expect(selected === customerLevelPhoto)
    }

    @Test func customerPrimaryPhotoCanFallbackToLinkedFieldPhoto() async throws {
        let customer = Customer(name: "Photo Customer")
        let linkedFieldPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            customerEquipmentID: UUID(),
            kind: .diagnosticPhoto,
            displayName: "equipment-panel.jpg",
            localFilePath: "/tmp/equipment-panel.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let selected = ServiceDocumentAttachment.primaryCustomerPhoto(
            for: customer,
            in: [linkedFieldPhoto]
        )

        #expect(selected === linkedFieldPhoto)
    }

    @Test func customerPrimaryPhotoIgnoresBillingAndReceiptImages() async throws {
        let customer = Customer(name: "Photo Customer")
        let diagnosticPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .diagnosticPhoto,
            displayName: "equipment.jpg",
            localFilePath: "/tmp/equipment.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let receiptImage = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .receipt,
            displayName: "profile-receipt.jpg",
            caption: "Profile photo",
            localFilePath: "/tmp/profile-receipt.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_300)
        )
        let invoiceImage = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .invoiceSupport,
            displayName: "profile-invoice.jpg",
            caption: "Customer photo",
            localFilePath: "/tmp/profile-invoice.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_400)
        )

        let selected = ServiceDocumentAttachment.primaryCustomerPhoto(
            for: customer,
            in: [diagnosticPhoto, receiptImage, invoiceImage]
        )

        #expect(receiptImage.canUseAsCustomerProfilePhoto == false)
        #expect(invoiceImage.canUseAsCustomerProfilePhoto == false)
        #expect(diagnosticPhoto.canUseAsCustomerProfilePhoto == true)
        #expect(selected === diagnosticPhoto)
    }

    @Test func customerProfileAttachmentsHideFinancialFilesForStandardUsers() async throws {
        let customer = Customer(name: "Document Visibility Customer")
        let serviceReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .serviceReport,
            displayName: "service-report.pdf",
            localFilePath: "/tmp/service-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let diagnosticPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let invoiceSupport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let estimateSupport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .estimateSupport,
            displayName: "estimate.pdf",
            localFilePath: "/tmp/estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let receipt = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .receipt,
            displayName: "receipt.jpg",
            localFilePath: "/tmp/receipt.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let attachments: [ServiceDocumentAttachment] = [serviceReport, diagnosticPhoto, invoiceSupport, estimateSupport, receipt]

        let standardVisible = ServiceDocumentAttachment.visibleCustomerProfileAttachments(
            in: attachments,
            canViewFinancials: false
        )
        let adminVisible = ServiceDocumentAttachment.visibleCustomerProfileAttachments(
            in: attachments,
            canViewFinancials: true
        )

        #expect(standardVisible.map(\.kind) == [.serviceReport, .diagnosticPhoto])
        #expect(adminVisible.count == attachments.count)
        #expect(invoiceSupport.isFinancialCustomerProfileAttachment)
        #expect(estimateSupport.isFinancialCustomerProfileAttachment)
        #expect(receipt.isFinancialCustomerProfileAttachment)
    }

    @Test func customerProfileAttachmentKindsUseSeparateBusinessRecordGroups() async throws {
        #expect(ServiceDocumentAttachmentKind.serviceReport.customerProfileGroupTitle == "Service Reports")
        #expect(ServiceDocumentAttachmentKind.estimateSupport.customerProfileGroupTitle == "Estimate Documents")
        #expect(ServiceDocumentAttachmentKind.invoiceSupport.customerProfileGroupTitle == "Invoice Documents")
        #expect(ServiceDocumentAttachmentKind.receipt.customerProfileGroupTitle == "Receipts & Bills")
        #expect(ServiceDocumentAttachmentKind.diagnosticPhoto.customerProfileGroupTitle == "Photos")
        #expect(ServiceDocumentAttachmentKind.customerDocument.customerProfileGroupTitle == "Customer Files")
    }

    @Test func customerProfileAttachmentDetailLinksJobBillingAndStorageContext() async throws {
        let customer = Customer(name: "Report Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .completed
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let invoice = Invoice(customer: customer, quickBooksID: "123", amount: 250, status: "paid")
        let estimate = Estimate(customer: customer, quickBooksID: "456", amount: 250, status: "accepted")
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            estimateID: estimate.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            backendDocumentID: "backend-1",
            quickBooksAttachableID: "attach-1"
        )

        let lines = attachment.customerProfileDetailLines(
            serviceCalls: [call],
            invoices: [invoice],
            estimates: [estimate],
            equipmentProfiles: [],
            canViewFinancials: true
        )

        #expect(lines.contains("Job: Maintenance - Completed"))
        #expect(lines.contains("Report: Ready"))
        #expect(lines.contains("Invoice: Paid - QuickBooks synced"))
        #expect(lines.contains("Estimate: Accepted - QuickBooks synced"))
        #expect(lines.contains("Attached to QuickBooks invoice"))
        #expect(lines.contains("Synced to company storage"))
    }

    @Test func customerProfileAttachmentSearchMatchesReportEquipmentAndReadingContext() async throws {
        let customer = Customer(name: "Search Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            modelNumber: "24ABC6"
        )
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Replaced weak capacitor and verified cooling.",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            status: .completed
        )
        call.setTechnicalReading("72", for: "return_air_temp")
        call.setTechnicalReading("54", for: "supply_air_temp")
        call.setTechnicalReading("12", for: "superheat")
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            customerEquipmentID: equipment.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            caption: "Final cooling service report",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        #expect(attachment.matchesCustomerProfileSearch(
            "weak capacitor",
            serviceCalls: [call],
            invoices: [],
            estimates: [],
            equipmentProfiles: [equipment],
            canViewFinancials: false
        ))
        #expect(attachment.matchesCustomerProfileSearch(
            "Downstairs AC",
            serviceCalls: [call],
            invoices: [],
            estimates: [],
            equipmentProfiles: [equipment],
            canViewFinancials: false
        ))
        #expect(attachment.matchesCustomerProfileSearch(
            "superheat",
            serviceCalls: [call],
            invoices: [],
            estimates: [],
            equipmentProfiles: [equipment],
            canViewFinancials: false
        ))
    }

    @Test func customerProfileAttachmentSearchRespectsFinancialVisibility() async throws {
        let customer = Customer(name: "Private Billing Customer")
        let invoice = Invoice(customer: customer, quickBooksID: "INV-123", amount: 500, status: "unpaid")
        let invoiceAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            invoiceID: invoice.id,
            kind: .invoiceSupport,
            displayName: "invoice-500.pdf",
            localFilePath: "/tmp/invoice-500.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "attach-123"
        )

        #expect(invoiceAttachment.matchesCustomerProfileSearch(
            "QuickBooks",
            serviceCalls: [],
            invoices: [invoice],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: true
        ))
        #expect(invoiceAttachment.matchesCustomerProfileSearch(
            "invoice",
            serviceCalls: [],
            invoices: [invoice],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: false
        ) == false)
    }

    @Test func customerProfileAttachmentDetailShowsQueuedQuickBooksAttachmentStatus() async throws {
        let customer = Customer(name: "Queued Attachment Customer")
        let invoice = Invoice(customer: customer, quickBooksID: "qbo-invoice", amount: 250)
        let estimate = Estimate(customer: customer, quickBooksID: "qbo-estimate", amount: 250)
        let invoiceAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let estimateAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            estimateID: estimate.id,
            kind: .estimateSupport,
            displayName: "estimate.pdf",
            localFilePath: "/tmp/estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let invoiceLines = invoiceAttachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [invoice],
            estimates: [estimate],
            equipmentProfiles: [],
            canViewFinancials: true
        )
        let estimateLines = estimateAttachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [invoice],
            estimates: [estimate],
            equipmentProfiles: [],
            canViewFinancials: true
        )
        let standardUserLines = invoiceAttachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [invoice],
            estimates: [estimate],
            equipmentProfiles: [],
            canViewFinancials: false
        )

        #expect(invoiceLines.contains("Queued for QuickBooks invoice attachment"))
        #expect(estimateLines.contains("Queued for QuickBooks estimate attachment"))
        #expect(standardUserLines.contains("Queued for QuickBooks invoice attachment") == false)
    }

    @Test func customerProfileAttachmentDetailHidesQuickBooksAttachmentStatusForStandardUsers() async throws {
        let customer = Customer(name: "Attachment Privacy Customer")
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: UUID(),
            kind: .serviceReport,
            displayName: "service-report.pdf",
            localFilePath: "/tmp/service-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "qbo-attach-1"
        )

        let adminLines = attachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: true
        )
        let standardLines = attachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: false
        )

        #expect(adminLines.contains("Attached to QuickBooks invoice"))
        #expect(standardLines.contains { $0.contains("QuickBooks") } == false)
    }

    @Test func customerProfileAttachmentDetailUsesQuickBooksInvoiceBalanceStatus() async throws {
        let customer = Customer(name: "QBO Attachment Customer")
        let paidInQuickBooks = Invoice(
            customer: customer,
            quickBooksID: "paid-qbo",
            quickBooksBalanceDue: 0,
            amount: 400,
            status: "unpaid"
        )
        let openInQuickBooks = Invoice(
            customer: customer,
            quickBooksID: "open-qbo",
            quickBooksBalanceDue: 125,
            amount: 400,
            status: "paid"
        )
        let paidAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            invoiceID: paidInQuickBooks.id,
            kind: .serviceReport,
            displayName: "paid-report.pdf",
            localFilePath: "/tmp/paid-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let openAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            invoiceID: openInQuickBooks.id,
            kind: .serviceReport,
            displayName: "open-report.pdf",
            localFilePath: "/tmp/open-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let paidLines = paidAttachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [paidInQuickBooks],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: true
        )
        let openLines = openAttachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [openInQuickBooks],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: true
        )

        #expect(paidLines.contains("Invoice: Paid - QuickBooks synced"))
        #expect(paidLines.contains("Invoice Balance: $0.00"))
        #expect(openLines.contains("Invoice: Partial - QuickBooks synced"))
        #expect(openLines.contains("Invoice Balance: $125.00"))
    }

    @Test func customerProfileAttachmentDetailShowsLinkedEquipment() async throws {
        let customer = Customer(name: "Equipment Attachment Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            manufacturer: "Carrier",
            modelNumber: "24ABC6",
            serialNumber: "AC123"
        )
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipment.id,
            kind: .diagnosticPhoto,
            displayName: "compressor-plate.jpg",
            localFilePath: "/tmp/compressor-plate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )

        let lines = attachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [],
            estimates: [],
            equipmentProfiles: [equipment],
            canViewFinancials: false
        )

        #expect(lines.contains { $0.contains("Equipment: Downstairs AC") })
        #expect(lines.contains { $0.contains("Carrier") })
        #expect(lines.contains { $0.contains("AC123") })
    }

    @Test func customerProfileAttachmentDetailInfersEquipmentFromLinkedServiceCall() async throws {
        let customer = Customer(name: "Equipment Attachment Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            manufacturer: "Carrier",
            modelNumber: "24ABC6",
            serialNumber: "AC123"
        )
        let call = ServiceCall(
            customerEquipmentID: equipment.id,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            customerEquipmentID: nil,
            kind: .diagnosticPhoto,
            displayName: "legacy-job-photo.jpg",
            localFilePath: "/tmp/legacy-job-photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )

        let lines = attachment.customerProfileDetailLines(
            serviceCalls: [call],
            invoices: [],
            estimates: [],
            equipmentProfiles: [equipment],
            canViewFinancials: false
        )

        #expect(lines.contains { $0.contains("Equipment: Downstairs AC") })
        #expect(lines.contains { $0.contains("Carrier") })
        #expect(lines.contains { $0.contains("AC123") })
    }

    @Test func customerProfileAttachmentDetailShowsOperationalFileMetadata() async throws {
        let customer = Customer(name: "File Metadata Customer")
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .customerDocument,
            displayName: "manual.pdf",
            localFilePath: "/tmp/manual.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let lines = attachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: false
        )

        #expect(lines.contains { $0.hasPrefix("Added:") })
        #expect(lines.contains("Size: 2 KB"))
        #expect(lines.contains("Local File: Not downloaded on this device"))
    }

    @Test func customerProfileServiceReportDetailsIncludeSummaryAndTechnicalSnapshot() async throws {
        let customer = Customer(name: "Technical Report Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked and cooling normally.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .completed
        )
        call.setTechnicalReading("76", for: "return_air_temp")
        call.setTechnicalReading("56", for: "supply_air_temp")
        call.setTechnicalReading("12", for: "superheat")
        call.setServiceActionStatus(.completed, for: "condenser_coil_serviced")
        call.setServiceActionStatus(.needsService, for: "condensate_drain_checked")
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let lines = attachment.customerProfileDetailLines(
            serviceCalls: [call],
            invoices: [],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: false
        )

        #expect(lines.contains("Summary: System checked and cooling normally."))
        #expect(lines.contains { $0.hasPrefix("Readings:") && $0.contains("Return Air Temp") })
        #expect(lines.contains { $0.hasPrefix("Readings:") && $0.contains("Supply Air Temp") })
        #expect(lines.contains { $0.hasPrefix("Readings:") && $0.contains("Superheat") })
        #expect(lines.contains { $0.hasPrefix("Actions:") && $0.contains("Condensate drain checked/treated: Needs Service") })
        #expect(lines.contains { $0.hasPrefix("Actions:") && $0.contains("Condenser coil inspected/washed: Completed") })
        #expect(lines.contains { $0.contains("Invoice") } == false)
        #expect(lines.contains { $0.contains("QuickBooks") } == false)
    }

    @Test func equipmentHistoryAttachmentsExcludeCurrentJobAndUnrelatedEquipment() async throws {
        let customer = Customer(name: "Equipment History Customer")
        let linkedEquipmentID = UUID()
        let unrelatedEquipmentID = UUID()
        let currentCall = ServiceCall(
            customerEquipmentID: linkedEquipmentID,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let previousCall = ServiceCall(
            customerEquipmentID: linkedEquipmentID,
            type: .service,
            scheduledDate: Date().addingTimeInterval(-86_400),
            customer: customer
        )
        let priorEquipmentReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: previousCall.id,
            customerEquipmentID: linkedEquipmentID,
            kind: .serviceReport,
            displayName: "prior-report.pdf",
            localFilePath: "/tmp/prior-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date().addingTimeInterval(-100)
        )
        let priorEquipmentPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: linkedEquipmentID,
            kind: .diagnosticPhoto,
            displayName: "nameplate.jpg",
            localFilePath: "/tmp/nameplate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date()
        )
        let currentJobAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: currentCall.id,
            customerEquipmentID: linkedEquipmentID,
            kind: .diagnosticPhoto,
            displayName: "current-job.jpg",
            localFilePath: "/tmp/current-job.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )
        let unrelatedAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: unrelatedEquipmentID,
            kind: .customerDocument,
            displayName: "other-unit.pdf",
            localFilePath: "/tmp/other-unit.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let priorInvoicePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: previousCall.id,
            customerEquipmentID: linkedEquipmentID,
            kind: .invoiceSupport,
            displayName: "prior-invoice.pdf",
            localFilePath: "/tmp/prior-invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date().addingTimeInterval(100)
        )
        let priorReceipt = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: previousCall.id,
            customerEquipmentID: linkedEquipmentID,
            kind: .receipt,
            displayName: "receipt.jpg",
            localFilePath: "/tmp/receipt.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024,
            createdAt: Date().addingTimeInterval(200)
        )

        let history = ServiceDocumentAttachment.equipmentHistoryAttachments(
            for: currentCall,
            in: [
                priorEquipmentReport,
                priorEquipmentPhoto,
                currentJobAttachment,
                unrelatedAttachment,
                priorInvoicePDF,
                priorReceipt
            ]
        )

        #expect(priorEquipmentReport.canShowInActiveEquipmentHistory == true)
        #expect(priorInvoicePDF.canShowInActiveEquipmentHistory == false)
        #expect(priorReceipt.canShowInActiveEquipmentHistory == false)
        #expect(history.map(\.displayName) == ["nameplate.jpg", "prior-report.pdf"])
    }

    @Test func backfillsMissingEquipmentLinksForExistingJobAttachments() async throws {
        let customer = Customer(name: "Equipment Backfill Customer")
        let otherCustomer = Customer(name: "Other Customer")
        let equipmentID = UUID()
        let otherEquipmentID = UUID()
        let call = ServiceCall(
            customerEquipmentID: equipmentID,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let unlinkedPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .diagnosticPhoto,
            displayName: "unlinked-photo.jpg",
            localFilePath: "/tmp/unlinked-photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let explicitlyLinkedPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            customerEquipmentID: otherEquipmentID,
            kind: .diagnosticPhoto,
            displayName: "other-equipment-photo.jpg",
            localFilePath: "/tmp/other-equipment-photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let wrongCustomerPhoto = ServiceDocumentAttachment(
            customer: otherCustomer,
            serviceCallID: call.id,
            kind: .diagnosticPhoto,
            displayName: "wrong-customer-photo.jpg",
            localFilePath: "/tmp/wrong-customer-photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )

        let updated = ServiceDocumentAttachment.backfillMissingEquipmentLinks(
            for: call,
            in: [unlinkedPhoto, explicitlyLinkedPhoto, wrongCustomerPhoto]
        )

        #expect(updated == 1)
        #expect(unlinkedPhoto.customerEquipmentID == equipmentID)
        #expect(explicitlyLinkedPhoto.customerEquipmentID == otherEquipmentID)
        #expect(wrongCustomerPhoto.customerEquipmentID == nil)
    }

    @Test func equipmentHistoryAttachmentsInferPriorEquipmentFromLinkedServiceCall() async throws {
        let customer = Customer(name: "Equipment History Customer")
        let linkedEquipmentID = UUID()
        let currentCall = ServiceCall(
            customerEquipmentID: linkedEquipmentID,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let previousCall = ServiceCall(
            customerEquipmentID: linkedEquipmentID,
            type: .service,
            scheduledDate: Date().addingTimeInterval(-86_400),
            customer: customer
        )
        let legacyPriorReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: previousCall.id,
            customerEquipmentID: nil,
            kind: .serviceReport,
            displayName: "legacy-prior-report.pdf",
            localFilePath: "/tmp/legacy-prior-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date().addingTimeInterval(-100)
        )
        let currentJobAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: currentCall.id,
            customerEquipmentID: nil,
            kind: .diagnosticPhoto,
            displayName: "current-job.jpg",
            localFilePath: "/tmp/current-job.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date()
        )

        let history = ServiceDocumentAttachment.equipmentHistoryAttachments(
            for: currentCall,
            in: [legacyPriorReport, currentJobAttachment],
            serviceCalls: [previousCall, currentCall]
        )

        #expect(history.map(\.displayName) == ["legacy-prior-report.pdf"])
    }

    @Test func customerEquipmentAttachmentGroupsFilesByLinkedEquipment() async throws {
        let customer = Customer(name: "Equipment File Customer")
        let downstairs = CustomerEquipment(customer: customer, name: "Downstairs AC", modelNumber: "24ABC6")
        let upstairs = CustomerEquipment(customer: customer, name: "Upstairs Furnace", modelNumber: "59TN6")
        let downstairsCall = ServiceCall(
            customerEquipmentID: downstairs.id,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )
        let downstairsOlder = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: downstairs.id,
            kind: .customerDocument,
            displayName: "downstairs-manual.pdf",
            localFilePath: "/tmp/downstairs-manual.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let downstairsNewer = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: downstairs.id,
            kind: .diagnosticPhoto,
            displayName: "downstairs-nameplate.jpg",
            localFilePath: "/tmp/downstairs-nameplate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let legacyDownstairsJobPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: downstairsCall.id,
            customerEquipmentID: nil,
            kind: .diagnosticPhoto,
            displayName: "legacy-downstairs-photo.jpg",
            localFilePath: "/tmp/legacy-downstairs-photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 25)
        )
        let upstairsPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: upstairs.id,
            kind: .diagnosticPhoto,
            displayName: "upstairs-nameplate.jpg",
            localFilePath: "/tmp/upstairs-nameplate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let unlinked = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .customerDocument,
            displayName: "unlinked.pdf",
            localFilePath: "/tmp/unlinked.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let groups = ServiceDocumentAttachment.groupedEquipmentAttachments(
            equipmentProfiles: [upstairs, downstairs],
            attachments: [downstairsOlder, downstairsNewer, legacyDownstairsJobPhoto, upstairsPhoto, unlinked],
            serviceCalls: [downstairsCall]
        )

        #expect(groups.map { $0.equipment.name } == ["Downstairs AC", "Upstairs Furnace"])
        #expect(groups.first?.attachments.map(\.displayName) == ["legacy-downstairs-photo.jpg", "downstairs-nameplate.jpg", "downstairs-manual.pdf"])
        #expect(groups.last?.attachments.map(\.displayName) == ["upstairs-nameplate.jpg"])
    }

    @Test func customerLevelAttachmentsExcludeEquipmentHistoryFiles() async throws {
        let customer = Customer(name: "Equipment File Customer")
        let equipment = CustomerEquipment(customer: customer, name: "Downstairs AC", modelNumber: "24ABC6")
        let serviceCall = ServiceCall(
            customerEquipmentID: equipment.id,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )
        let directEquipmentPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipment.id,
            kind: .diagnosticPhoto,
            displayName: "equipment-nameplate.jpg",
            localFilePath: "/tmp/equipment-nameplate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )
        let legacyJobPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCall.id,
            customerEquipmentID: nil,
            kind: .diagnosticPhoto,
            displayName: "legacy-job-photo.jpg",
            localFilePath: "/tmp/legacy-job-photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )
        let unlinkedCustomerFile = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: nil,
            kind: .customerDocument,
            displayName: "gate-code.pdf",
            localFilePath: "/tmp/gate-code.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let customerLevel = ServiceDocumentAttachment.customerLevelAttachments(
            in: [directEquipmentPhoto, legacyJobPhoto, unlinkedCustomerFile],
            equipmentProfiles: [equipment],
            serviceCalls: [serviceCall]
        )

        #expect(customerLevel.map(\.displayName) == ["gate-code.pdf"])
        #expect(directEquipmentPhoto.isLinkedToEquipment(equipmentProfiles: [equipment], serviceCalls: [serviceCall]))
        #expect(legacyJobPhoto.isLinkedToEquipment(equipmentProfiles: [equipment], serviceCalls: [serviceCall]))
    }

    @Test func customerEquipmentAttachmentGroupSummarizesFileTypes() async throws {
        let customer = Customer(name: "Equipment Summary Customer")
        let equipment = CustomerEquipment(customer: customer, name: "Main System")
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            customerEquipmentID: equipment.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let photo = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            customerEquipmentID: equipment.id,
            kind: .diagnosticPhoto,
            displayName: "photo.jpg",
            localFilePath: "/tmp/photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let invoice = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            customerEquipmentID: equipment.id,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let manual = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipment.id,
            kind: .customerDocument,
            displayName: "manual.pdf",
            localFilePath: "/tmp/manual.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 40)
        )

        let group = EquipmentAttachmentGroup(equipment: equipment, attachments: [report, photo, invoice, manual])

        #expect(group.serviceReportCount == 1)
        #expect(group.photoCount == 1)
        #expect(group.billingDocumentCount == 1)
        #expect(group.otherDocumentCount == 1)
        #expect(group.latestAttachmentDate == manual.createdAt)
        #expect(group.summary == "1 report - 1 photo - 1 billing file - 1 file")
    }

    @Test func equipmentAttachmentsIncludeDirectAndLinkedJobFiles() async throws {
        let customer = Customer(name: "Equipment File Customer")
        let equipment = CustomerEquipment(customer: customer, name: "Main System")
        let otherEquipment = CustomerEquipment(customer: customer, name: "Other System")
        let linkedCall = ServiceCall(
            customerEquipmentID: equipment.id,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let directFile = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipment.id,
            kind: .customerDocument,
            displayName: "manual.pdf",
            localFilePath: "/tmp/manual.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let legacyJobFile = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: linkedCall.id,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let unrelatedFile = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: otherEquipment.id,
            kind: .customerDocument,
            displayName: "other-manual.pdf",
            localFilePath: "/tmp/other-manual.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 30)
        )

        let files = ServiceDocumentAttachment.equipmentAttachments(
            for: equipment,
            in: [directFile, unrelatedFile, legacyJobFile],
            serviceCalls: [linkedCall]
        )

        #expect(files.map(\.displayName) == ["invoice.pdf", "manual.pdf"])
        #expect(EquipmentAttachmentGroup(equipment: equipment, attachments: files).summary == "1 billing file - 1 file")
    }

    @Test func onsiteReportLinkedRecordRowsIncludeInvoiceEstimateAndQuickBooksReferences() async throws {
        let customer = Customer(name: "Linked Report Customer")
        let callID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let estimateID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let invoiceID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        let call = ServiceCall(
            id: callID,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.linkedEstimateID = estimateID
        call.linkedInvoiceID = invoiceID
        let estimate = Estimate(id: estimateID, customer: customer, quickBooksID: "QBO-EST-42", amount: 500, status: "accepted")
        let invoice = Invoice(id: invoiceID, customer: customer, quickBooksID: "QBO-INV-99", amount: 500, status: "paid")

        let rows = CustomerDocumentExporter.linkedRecordRows(serviceCall: call, estimate: estimate, invoice: invoice)
        let caption = CustomerDocumentExporter.onsiteReportAttachmentCaption(serviceCall: call, estimate: estimate, invoice: invoice)

        #expect(rows.contains { $0.label == "Job ID" && $0.value == "11111111" })
        #expect(rows.contains { $0.label == "Estimate ID" && $0.value == "22222222" })
        #expect(rows.contains { $0.label == "Estimate Amount" && $0.value == "$500.00" })
        #expect(rows.contains { $0.label == "QuickBooks Estimate ID" && $0.value == "QBO-EST-42" })
        #expect(rows.contains { $0.label == "Invoice ID" && $0.value == "33333333" })
        #expect(rows.contains { $0.label == "Invoice Total" && $0.value == "$500.00" })
        #expect(rows.contains { $0.label == "Invoice Balance Due" && $0.value == "$0.00" })
        #expect(rows.contains { $0.label == "QuickBooks Invoice ID" && $0.value == "QBO-INV-99" })
        #expect(caption.contains("Generated onsite maintenance report"))
        #expect(caption.contains("QuickBooks Invoice ID: QBO-INV-99"))
        #expect(caption.contains("QuickBooks Estimate ID: QBO-EST-42"))
    }

    @Test func invoiceDetailRowsUseQuickBooksBalanceWhenAvailable() async throws {
        let customer = Customer(name: "QBO Invoice Customer")
        let invoice = Invoice(
            customer: customer,
            quickBooksID: "QBO-INV-100",
            quickBooksBalanceDue: 125,
            amount: 500,
            status: "unpaid"
        )
        let localPayment = Payment(invoice: invoice, amount: 500, method: "card")

        let rows = CustomerDocumentExporter.invoiceDetailRows(for: invoice, payments: [localPayment])

        #expect(rows.contains { $0.label == "Status" && $0.value == "Partial" })
        #expect(rows.contains { $0.label == "Invoice Total" && $0.value == "$500.00" })
        #expect(rows.contains { $0.label == "Payments" && $0.value == "$500.00" })
        #expect(rows.contains { $0.label == "Balance Due" && $0.value == "$125.00" })
    }

    @Test func invoiceDetailRowsIncludeDocumentationReadinessWhenAvailable() async throws {
        let customer = Customer(name: "Documentation Invoice Customer")
        let invoice = Invoice(
            customer: customer,
            quickBooksID: "QBO-INV-101",
            amount: 750,
            status: "unpaid"
        )
        let documentationStatus = InvoiceDocumentationStatus(
            linkedReportCount: 1,
            linkedPhotoEvidenceCount: 0,
            linkedBillingDocumentCount: 0,
            pendingQuickBooksAttachmentCount: 1,
            syncedQuickBooksAttachmentCount: 0,
            requiresQuickBooksAttachmentSync: true
        )

        let rows = CustomerDocumentExporter.invoiceDetailRows(
            for: invoice,
            payments: [],
            documentationStatus: documentationStatus
        )

        #expect(rows.contains { $0.label == "Documentation Status" && $0.value == "QuickBooks attachments pending" })
        #expect(rows.contains { $0.label == "Documentation Summary" && $0.value.contains("1 onsite report") })
        #expect(rows.contains { $0.label == "Documentation Summary" && $0.value.contains("1 pending") })
    }

    @Test func billingDocumentsIncludeLinkedOnsiteDocumentationSummary() async throws {
        let customer = Customer(name: "Billing Documentation Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System operational after diagnostics.",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            findingsSummary: "Compressor capacitor weak.",
            recommendedWorkSummary: "Replace capacitor and wash condenser coil."
        )
        call.setTechnicalReading("76", for: "return_air_temp")
        call.setTechnicalReading("56", for: "supply_air_temp")
        call.setTechnicalReading("12", for: "superheat")
        call.setServiceActionStatus(.needsService, for: "condenser_coil_inspected_washed")
        call.setServiceActionStatus(.completed, for: "electrical_connections_checked")

        let summaries = CustomerDocumentExporter.billingDocumentationSummaries(for: call)
        let hasOnsiteDocumentation = summaries.contains { summary in
            summary.title == "Onsite Documentation"
        }
        let hasFindingsSummary = summaries.contains { summary in
            summary.title == "Service Summary" &&
                summary.rows.contains { row in
                    row.label == "Findings" && row.value.contains("capacitor weak")
                }
        }
        let hasTechnicalSnapshot = summaries.contains { summary in
            summary.title == "Technical Snapshot" &&
                summary.rows.contains { row in
                    row.label == "Superheat (F)" && row.value == "12"
                }
        }
        let hasServiceActions = summaries.contains { summary in
            summary.title == "Service Actions" &&
                summary.rows.contains { row in
                    row.label == "Condenser coil inspected/washed" && row.value == "Needs Service"
                } &&
                summary.rows.contains { row in
                    row.label == "Electrical connections checked" && row.value == "Completed"
                }
        }

        #expect(hasOnsiteDocumentation)
        #expect(hasFindingsSummary)
        #expect(hasTechnicalSnapshot)
        #expect(hasServiceActions)
    }

    @Test func onsiteReportJobRowsIncludeStructuredCustomerContactContext() async throws {
        let customer = Customer(
            name: "Standalone Report Customer",
            phone: "555-0100",
            email: "customer@example.com",
            address: "123 Customer Rd"
        )
        let technician = Technician(name: "Lead Tech")
        let call = ServiceCall(
            siteAddress: "456 Job Site Ave",
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            assignedTechnician: technician,
            customer: customer,
            status: .inProgress
        )

        let rows = CustomerDocumentExporter.onsiteReportJobRows(for: call)

        #expect(rows.contains { $0.label == "Customer" && $0.value == "Standalone Report Customer" })
        #expect(rows.contains { $0.label == "Customer Address" && $0.value == "123 Customer Rd" })
        #expect(rows.contains { $0.label == "Customer Phone" && $0.value == "555-0100" })
        #expect(rows.contains { $0.label == "Customer Email" && $0.value == "customer@example.com" })
        #expect(rows.contains { $0.label == "Site Address" && $0.value == "456 Job Site Ave" })
        #expect(rows.contains { $0.label == "Technician" && $0.value == "Lead Tech" })
    }

    @Test func onsiteReportJobRowsFallBackToCustomerAddressForSiteAddress() async throws {
        let customer = Customer(name: "Fallback Customer", address: "123 Customer Rd")
        let call = ServiceCall(
            siteAddress: nil,
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )

        let rows = CustomerDocumentExporter.onsiteReportJobRows(for: call)

        #expect(rows.contains { $0.label == "Site Address" && $0.value == "123 Customer Rd" })
        #expect(rows.contains { $0.label == "Customer Email" } == false)
        #expect(rows.contains { $0.label == "Customer Phone" } == false)
    }

    @Test func customerProfileAttachmentDetailHidesBillingContextForStandardUsers() async throws {
        let customer = Customer(name: "Report Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .completed
        )
        call.setTechnicalReading("72", for: "return_air_temp")
        let invoice = Invoice(customer: customer, quickBooksID: "123", amount: 250, status: "paid")
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksSyncError: "403"
        )

        let lines = attachment.customerProfileDetailLines(
            serviceCalls: [call],
            invoices: [invoice],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: false
        )

        #expect(lines.contains("Job: Maintenance - Completed"))
        #expect(lines.contains { $0.contains("Documentation is not complete") })
        #expect(lines.contains { $0.contains("Supply Air Temp (F)") })
        #expect(lines.contains { $0.contains("Invoice") } == false)
        #expect(lines.contains { $0.contains("QuickBooks") } == false)
        #expect(lines.contains { $0.contains("403") } == false)
    }

    @Test func onsiteReportAttachmentManifestIncludesSupportFilesAndExcludesGeneratedReports() async throws {
        let customer = Customer(name: "Report Customer")
        let serviceCallID = UUID()
        let diagnosticPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            caption: "Burner compartment",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )
        let customerDocument = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .customerDocument,
            displayName: "site-access.pdf",
            caption: "Gate instructions",
            localFilePath: "/tmp/site-access.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 4096
        )
        let generatedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "generated-report.pdf",
            localFilePath: "/tmp/generated-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 8192
        )

        let summaries = CustomerDocumentExporter.attachmentManifestSummaries(
            for: [diagnosticPhoto, customerDocument, generatedReport]
        )

        #expect(summaries.count == 2)
        #expect(summaries.contains { $0.label == "Diagnostic Photo" && $0.detail.contains("Burner compartment") })
        #expect(summaries.contains { $0.label == "Customer Document" && $0.detail.contains("site-access.pdf") })
        #expect(summaries.contains { $0.detail.contains("generated-report.pdf") } == false)
    }

    @Test func onsiteReportAttachmentManifestIncludesLinkedBillingTrace() async throws {
        let customer = Customer(name: "Report Customer")
        let call = ServiceCall(type: .service, scheduledDate: Date(), customer: customer)
        let estimate = Estimate(serviceCallID: call.id, customer: customer, amount: 250, status: "accepted")
        let invoice = Invoice(serviceCallID: call.id, customer: customer, amount: 250, status: "open")
        call.linkedEstimateID = estimate.id
        call.linkedInvoiceID = invoice.id
        let diagnosticPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            estimateID: estimate.id,
            kind: .diagnosticPhoto,
            displayName: "failed-capacitor.jpg",
            caption: "Failed capacitor",
            localFilePath: "/tmp/failed-capacitor.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            quickBooksAttachableID: "QBO-Attach-123"
        )

        let summaries = CustomerDocumentExporter.attachmentManifestSummaries(
            for: [diagnosticPhoto],
            serviceCall: call,
            estimate: estimate,
            invoice: invoice
        )

        let detail = try #require(summaries.first?.detail)
        #expect(detail.contains("Job ID:"))
        #expect(detail.contains("Estimate ID:"))
        #expect(detail.contains("Invoice ID:"))
        #expect(detail.contains("QuickBooks Attachment ID: QBO-Attach-123"))
    }

    @Test func onsiteReportPhotoCaptionIncludesTimestampForFieldEvidence() async throws {
        let customer = Customer(name: "Photo Evidence Customer")
        let photo = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .diagnosticPhoto,
            displayName: "before-repair.jpg",
            caption: "Before repair",
            localFilePath: "/tmp/before-repair.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let caption = CustomerDocumentExporter.photoAttachmentCaption(for: photo)

        #expect(caption.contains("Diagnostic Photo"))
        #expect(caption.contains("Before repair"))
        #expect(caption.contains("before-repair.jpg"))
        #expect(caption.contains("2027") || caption.contains("Jan"))
    }

    @Test func onsiteReportPhotoEvidenceIncludesJobImagesInStableOrder() async throws {
        let customer = Customer(name: "Report Customer")
        let serviceCallID = UUID()
        let beforePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .beforePhoto,
            displayName: "before.jpg",
            caption: "Before repair",
            localFilePath: "/tmp/before.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let diagnosticPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            caption: "Failed capacitor",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let customerImage = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .customerDocument,
            displayName: "panel-label.png",
            caption: "Equipment data plate",
            localFilePath: "/tmp/panel-label.png",
            contentType: "image/png",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 1_800_000_200)
        )
        let generatedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "generated-report.pdf",
            localFilePath: "/tmp/generated-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 8192,
            createdAt: Date(timeIntervalSince1970: 1_800_000_300)
        )

        let evidence = CustomerDocumentExporter.photoEvidenceSummaries(
            for: [generatedReport, customerImage, diagnosticPhoto, beforePhoto]
        )

        #expect(evidence.map(\.label) == ["Before Photo", "Diagnostic Photo", "Customer Document"])
        #expect(evidence[0].detail.contains("Before repair"))
        #expect(evidence[1].detail.contains("Failed capacitor"))
        #expect(evidence[2].detail.contains("Equipment data plate"))
        #expect(evidence.contains { $0.detail.contains("generated-report.pdf") } == false)
    }

    @Test func onsiteReportPhotoEvidenceIncludesLinkedBillingTrace() async throws {
        let customer = Customer(name: "Photo Evidence Customer")
        let call = ServiceCall(type: .maintenance, scheduledDate: Date(), customer: customer)
        let invoice = Invoice(serviceCallID: call.id, customer: customer, amount: 400, status: "open")
        let photo = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .afterPhoto,
            displayName: "after-repair.jpg",
            caption: "After repair",
            localFilePath: "/tmp/after-repair.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let evidence = CustomerDocumentExporter.photoEvidenceSummaries(
            for: [photo],
            serviceCall: call,
            invoice: invoice
        )

        let detail = try #require(evidence.first?.detail)
        #expect(detail.contains("After repair"))
        #expect(detail.contains("Job ID:"))
        #expect(detail.contains("Invoice ID:"))
    }

    @Test func billingPhotoAttachmentsAreScopedToInvoiceJobAndTarget() async throws {
        let customer = Customer(name: "Billing Photo Customer")
        let call = ServiceCall(type: .maintenance, scheduledDate: Date(), customer: customer)
        let invoiceID = UUID()
        let otherInvoiceID = UUID()
        let jobBeforePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .beforePhoto,
            displayName: "job-before.jpg",
            localFilePath: "/tmp/job-before.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let invoicePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoiceID,
            kind: .afterPhoto,
            displayName: "invoice-after.jpg",
            localFilePath: "/tmp/invoice-after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let estimateCarriedForwardPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoiceID,
            estimateID: UUID(),
            kind: .diagnosticPhoto,
            displayName: "estimate-carried-forward.jpg",
            localFilePath: "/tmp/estimate-carried-forward.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 250)
        )
        let wrongInvoicePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: otherInvoiceID,
            kind: .diagnosticPhoto,
            displayName: "wrong-invoice.jpg",
            localFilePath: "/tmp/wrong-invoice.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let unrelatedJobPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .beforePhoto,
            displayName: "unrelated-job.jpg",
            localFilePath: "/tmp/unrelated-job.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 400)
        )

        let selected = CustomerDocumentExporter.billingPhotoAttachments(
            for: [unrelatedJobPhoto, wrongInvoicePhoto, invoicePhoto, estimateCarriedForwardPhoto, jobBeforePhoto],
            serviceCall: call,
            invoiceID: invoiceID,
            estimateID: nil
        )

        #expect(selected.map(\.displayName) == ["job-before.jpg", "invoice-after.jpg", "estimate-carried-forward.jpg"])
    }

    @Test func billingPhotoAttachmentsAreScopedToEstimateJobAndTarget() async throws {
        let customer = Customer(name: "Estimate Photo Customer")
        let call = ServiceCall(type: .estimate, scheduledDate: Date(), customer: customer)
        let estimateID = UUID()
        let otherEstimateID = UUID()
        let jobPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .beforePhoto,
            displayName: "estimate-job.jpg",
            localFilePath: "/tmp/estimate-job.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let estimatePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimateID,
            kind: .diagnosticPhoto,
            displayName: "estimate-diagnostic.jpg",
            localFilePath: "/tmp/estimate-diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let wrongEstimatePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: otherEstimateID,
            kind: .afterPhoto,
            displayName: "wrong-estimate.jpg",
            localFilePath: "/tmp/wrong-estimate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let invoiceLinkedPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: UUID(),
            estimateID: estimateID,
            kind: .afterPhoto,
            displayName: "invoice-linked.jpg",
            localFilePath: "/tmp/invoice-linked.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 400)
        )

        let selected = CustomerDocumentExporter.billingPhotoAttachments(
            for: [invoiceLinkedPhoto, wrongEstimatePhoto, estimatePhoto, jobPhoto],
            serviceCall: call,
            invoiceID: nil,
            estimateID: estimateID
        )

        #expect(selected.map(\.displayName) == ["estimate-job.jpg", "estimate-diagnostic.jpg"])
    }

    @Test func onsiteReportAttachmentsAreScopedToJobAndLinkedBillingRecords() async throws {
        let customer = Customer(name: "Scoped Report Customer")
        let call = ServiceCall(type: .service, scheduledDate: Date(), customer: customer)
        let estimate = Estimate(serviceCallID: call.id, customer: customer, amount: 500, status: "accepted")
        let invoice = Invoice(serviceCallID: call.id, customer: customer, amount: 500, status: "open")
        call.linkedEstimateID = estimate.id
        call.linkedInvoiceID = invoice.id

        let jobPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .beforePhoto,
            displayName: "job-before.jpg",
            localFilePath: "/tmp/job-before.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let estimatePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimate.id,
            kind: .diagnosticPhoto,
            displayName: "estimate-diagnostic.jpg",
            localFilePath: "/tmp/estimate-diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let invoicePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .afterPhoto,
            displayName: "invoice-after.jpg",
            localFilePath: "/tmp/invoice-after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let wrongInvoicePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: UUID(),
            kind: .afterPhoto,
            displayName: "wrong-invoice.jpg",
            localFilePath: "/tmp/wrong-invoice.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 400)
        )
        let unrelatedJobPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .diagnosticPhoto,
            displayName: "unrelated-job.jpg",
            localFilePath: "/tmp/unrelated-job.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 500)
        )

        let selected = CustomerDocumentExporter.onsiteReportAttachments(
            for: [unrelatedJobPhoto, wrongInvoicePhoto, invoicePhoto, estimatePhoto, jobPhoto],
            serviceCall: call,
            estimate: estimate,
            invoice: invoice
        )

        #expect(selected.map(\.displayName) == ["invoice-after.jpg", "estimate-diagnostic.jpg", "job-before.jpg"])
    }

    @Test func onsiteReportChecklistCountsActualJobPhotoAttachments() async throws {
        let customer = Customer(name: "Photo Count Customer")
        let call = ServiceCall(
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            beforePhotoCount: 0,
            afterPhotoCount: 0
        )
        let beforePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .beforePhoto,
            displayName: "before.jpg",
            localFilePath: "/tmp/before.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512
        )
        let afterPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .afterPhoto,
            displayName: "after.jpg",
            localFilePath: "/tmp/after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512
        )

        let rows = CustomerDocumentExporter.checklistRows(for: call, attachments: [beforePhoto, afterPhoto])

        #expect(rows.contains { $0.label == "Photo Evidence" && $0.value == "Photo evidence complete - 1 before - 1 after" })
        #expect(rows.contains { $0.label == "Before Photos" && $0.value == "1" })
        #expect(rows.contains { $0.label == "After Photos" && $0.value == "1" })
    }

    @Test func onsiteReportChecklistIgnoresOtherJobPhotoAttachments() async throws {
        let customer = Customer(name: "Photo Count Customer")
        let call = ServiceCall(
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            beforePhotoCount: 1,
            afterPhotoCount: 0
        )
        let unrelatedAfterPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .afterPhoto,
            displayName: "unrelated-after.jpg",
            localFilePath: "/tmp/unrelated-after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512
        )

        let rows = CustomerDocumentExporter.checklistRows(for: call, attachments: [unrelatedAfterPhoto])

        #expect(rows.contains { $0.label == "Before Photos" && $0.value == "1" })
        #expect(rows.contains { $0.label == "After Photos" && $0.value == "0" })
    }

    @Test func generatedServiceReportAttachmentCanBeReusedForSameJobBillingLink() async throws {
        let customer = Customer(name: "Report Customer")
        let serviceCallID = UUID()
        let invoiceID = UUID()
        let olderReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            kind: .serviceReport,
            displayName: "older-report.pdf",
            localFilePath: "/tmp/older-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let latestReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            kind: .serviceReport,
            displayName: "latest-report.pdf",
            localFilePath: "/tmp/latest-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048,
            quickBooksAttachableID: "123",
            quickBooksSyncError: "Old error",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let unrelatedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoiceID,
            kind: .serviceReport,
            displayName: "other-job-report.pdf",
            localFilePath: "/tmp/other-job-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 30)
        )

        let reusable = try #require(ServiceDocumentAttachment.reusableGeneratedServiceReport(
            in: [olderReport, latestReport, unrelatedReport],
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            estimateID: nil
        ))

        #expect(reusable.id == latestReport.id)

        reusable.replaceGeneratedFile(
            displayName: "regenerated-report.pdf",
            localFilePath: "/tmp/regenerated-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 4096,
            caption: "Generated onsite service report"
        )

        #expect(reusable.displayName == "regenerated-report.pdf")
        #expect(reusable.fileSizeBytes == 4096)
        #expect(reusable.quickBooksAttachableID == nil)
        #expect(reusable.quickBooksSyncError == nil)
    }

    @Test func generatedServiceReportFallsBackToUnlinkedJobReportWhenInvoiceIsCreatedLater() async throws {
        let customer = Customer(name: "Report Customer")
        let serviceCallID = UUID()
        let invoiceID = UUID()
        let unlinkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "pre-invoice-report.pdf",
            localFilePath: "/tmp/pre-invoice-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let unrelatedUnlinkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .serviceReport,
            displayName: "other-job-report.pdf",
            localFilePath: "/tmp/other-job-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 20)
        )

        let reusable = try #require(ServiceDocumentAttachment.reusableGeneratedServiceReport(
            in: [unlinkedReport, unrelatedUnlinkedReport],
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            estimateID: nil
        ))
        reusable.linkToInvoiceIfNeeded(Invoice(
            id: invoiceID,
            serviceCallID: serviceCallID,
            customer: customer,
            amount: 250,
            status: "unpaid"
        ))

        #expect(reusable.id == unlinkedReport.id)
        #expect(reusable.invoiceID == invoiceID)
    }

    @Test func reusedGeneratedReportRefreshesBillingAndEquipmentContext() async throws {
        let oldCustomer = Customer(name: "Old Customer")
        let currentCustomer = Customer(name: "Current Customer")
        let serviceCallID = UUID()
        let equipmentID = UUID()
        let invoiceID = UUID()
        let estimateID = UUID()
        let reusable = ServiceDocumentAttachment(
            customer: oldCustomer,
            serviceCallID: serviceCallID,
            customerEquipmentID: nil,
            invoiceID: nil,
            estimateID: estimateID,
            kind: .serviceReport,
            displayName: "pre-invoice-report.pdf",
            localFilePath: "/tmp/pre-invoice-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "old-attachable",
            quickBooksSyncError: "Old target"
        )

        reusable.refreshGeneratedDocumentContext(
            customer: currentCustomer,
            serviceCallID: serviceCallID,
            customerEquipmentID: equipmentID,
            invoiceID: invoiceID,
            estimateID: estimateID
        )

        #expect(reusable.customer?.id == currentCustomer.id)
        #expect(reusable.serviceCallID == serviceCallID)
        #expect(reusable.customerEquipmentID == equipmentID)
        #expect(reusable.invoiceID == invoiceID)
        #expect(reusable.estimateID == estimateID)
        #expect(reusable.quickBooksAttachableID == nil)
        #expect(reusable.quickBooksSyncError == nil)
    }

    @Test func reusedGeneratedReportKeepsQuickBooksAttachmentWhenBillingTargetIsUnchanged() async throws {
        let customer = Customer(name: "Current Customer")
        let serviceCallID = UUID()
        let equipmentID = UUID()
        let invoiceID = UUID()
        let reusable = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            customerEquipmentID: equipmentID,
            invoiceID: invoiceID,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "attachable-123",
            quickBooksSyncError: nil
        )

        reusable.refreshGeneratedDocumentContext(
            customer: customer,
            serviceCallID: serviceCallID,
            customerEquipmentID: equipmentID,
            invoiceID: invoiceID,
            estimateID: nil
        )

        #expect(reusable.quickBooksAttachableID == "attachable-123")
        #expect(reusable.quickBooksSyncError == nil)
    }

    @Test func generatedBillingDocumentAttachmentCanBeReusedForSameBillingLink() async throws {
        let customer = Customer(name: "Billing Customer")
        let serviceCallID = UUID()
        let estimateID = UUID()
        let invoiceID = UUID()
        let olderEstimate = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            estimateID: estimateID,
            kind: .estimateSupport,
            displayName: "older-estimate.pdf",
            localFilePath: "/tmp/older-estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let latestEstimate = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            estimateID: estimateID,
            kind: .estimateSupport,
            displayName: "latest-estimate.pdf",
            localFilePath: "/tmp/latest-estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let invoiceDocument = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 30)
        )

        let reusableEstimate = try #require(ServiceDocumentAttachment.reusableGeneratedBillingDocument(
            in: [olderEstimate, latestEstimate, invoiceDocument],
            kind: .estimateSupport,
            serviceCallID: serviceCallID,
            invoiceID: nil,
            estimateID: estimateID
        ))
        let reusableInvoice = try #require(ServiceDocumentAttachment.reusableGeneratedBillingDocument(
            in: [olderEstimate, latestEstimate, invoiceDocument],
            kind: .invoiceSupport,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            estimateID: nil
        ))

        #expect(reusableEstimate.id == latestEstimate.id)
        #expect(reusableInvoice.id == invoiceDocument.id)
        #expect(ServiceDocumentAttachment.reusableGeneratedBillingDocument(
            in: [olderEstimate, latestEstimate, invoiceDocument],
            kind: .invoiceSupport,
            serviceCallID: serviceCallID,
            invoiceID: nil,
            estimateID: estimateID
        ) == nil)
    }

    @Test func quickBooksUploadMetadataCanReferenceInvoiceForSend() async throws {
        let metadata = QuickBooksUploadMetadata(
            FileName: "onsite-report.pdf",
            ContentType: "application/pdf",
            Note: "Generated onsite service report",
            AttachableRef: [
                QuickBooksAttachableReference(
                    EntityRef: QuickBooksAttachableEntityRef(type: QuickBooksAttachableEntityType.invoice.rawValue, value: "123"),
                    IncludeOnSend: true
                )
            ]
        )

        let data = try JSONEncoder().encode(metadata)
        let payload = String(data: data, encoding: .utf8) ?? ""

        #expect(payload.contains("\"FileName\":\"onsite-report.pdf\""))
        #expect(payload.contains("\"type\":\"Invoice\""))
        #expect(payload.contains("\"value\":\"123\""))
        #expect(payload.contains("\"IncludeOnSend\":true"))
    }

    @Test func quickBooksUploadMetadataCanReferenceEstimateAndInvoiceTogether() async throws {
        let metadata = QuickBooksUploadMetadata(
            FileName: "onsite-report.pdf",
            ContentType: "application/pdf",
            Note: "Generated onsite service report",
            AttachableRef: [
                QuickBooksAttachableReference(
                    EntityRef: QuickBooksAttachableEntityRef(type: QuickBooksAttachableEntityType.invoice.rawValue, value: "INV-123"),
                    IncludeOnSend: true
                ),
                QuickBooksAttachableReference(
                    EntityRef: QuickBooksAttachableEntityRef(type: QuickBooksAttachableEntityType.estimate.rawValue, value: "EST-123"),
                    IncludeOnSend: true
                )
            ]
        )

        let data = try JSONEncoder().encode(metadata)
        let payload = String(data: data, encoding: .utf8) ?? ""

        #expect(payload.contains("\"type\":\"Invoice\""))
        #expect(payload.contains("\"value\":\"INV-123\""))
        #expect(payload.contains("\"type\":\"Estimate\""))
        #expect(payload.contains("\"value\":\"EST-123\""))
    }

    @Test func quickBooksFaultDecoderHandlesLowercaseAuthorizationFaults() async throws {
        let data = Data(
            #"{"fault":{"error":[{"message":"message=ApplicationAuthorizationFailed; errorCode=003100; statusCode=403","detail":null,"code":"3100","element":null}],"type":"SERVICE"}}"#.utf8
        )

        let envelope = try JSONDecoder().decode(QuickBooksFaultEnvelope.self, from: data)

        #expect(envelope.Fault.Error.first?.code == "3100")
        #expect(envelope.Fault.Error.first?.Message.contains("ApplicationAuthorizationFailed") == true)
    }

    @Test func quickBooksAuthorizationFailureIsReconnectAction() async throws {
        let error = QuickBooksDataAPI.QBError.authorizationFailed(
            statusCode: 403,
            detail: "QuickBooks rejected this app session."
        )

        #expect(error.requiresReconnect == true)
        #expect(error.localizedDescription.contains("Reconnect QuickBooks") == true)
    }

    @MainActor
    @Test func appSchemaIncludesVendorForQuickBooksSync() async throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let vendor = Vendor(quickBooksID: "QB-VENDOR-1", name: "HVAC Supply")

        context.insert(vendor)
        try context.save()

        let vendors = try context.fetch(FetchDescriptor<Vendor>())
        #expect(vendors.count == 1)
        #expect(vendors.first?.quickBooksID == "QB-VENDOR-1")
    }

    @Test func technicianCalendarAssessmentDetectsWritableCalendar() async throws {
        let calendars = [
            GoogleCalendar(id: "tech@example.com", summary: "Tech Schedule", timeZone: "America/New_York", accessRole: "writer")
        ]

        let assessment = TechnicianCalendarAccessAssessment.evaluate(
            calendarID: "TECH@example.com ",
            availableCalendars: calendars
        )

        #expect(assessment.state == .writable)
        #expect(assessment.calendarLabel.contains("Tech Schedule"))
    }

    @Test func technicianCalendarAssessmentDetectsReadOnlyCalendar() async throws {
        let calendars = [
            GoogleCalendar(id: "tech@example.com", summary: "Tech Schedule", timeZone: "America/New_York", accessRole: "reader")
        ]

        let assessment = TechnicianCalendarAccessAssessment.evaluate(
            calendarID: "tech@example.com",
            availableCalendars: calendars
        )

        #expect(assessment.state == .readOnly)
        #expect(assessment.detail.contains("cannot write"))
    }

    @Test func technicianCalendarAssessmentUsesPrimaryAsWritableFallback() async throws {
        let assessment = TechnicianCalendarAccessAssessment.evaluate(
            calendarID: "primary",
            availableCalendars: []
        )

        #expect(assessment.state == .writable)
        #expect(assessment.calendarLabel == "Primary Calendar")
    }

    @Test func serviceCalendarRoutingOnlyOffersWritableCalendars() async throws {
        let calendars = [
            GoogleCalendar(id: "writer@example.com", summary: "Writer", timeZone: nil, accessRole: "writer"),
            GoogleCalendar(id: "reader@example.com", summary: "Reader", timeZone: nil, accessRole: "reader")
        ]

        let options = ServiceCalendarRouting.routeOptions(from: calendars)

        #expect(options.contains(ServiceCalendarRouteOption(id: "primary", label: "Primary Calendar")))
        #expect(options.contains(where: { $0.id == "writer@example.com" }))
        #expect(options.contains(where: { $0.id == "reader@example.com" }) == false)
    }

    @Test func serviceCalendarRoutingSanitizesReadOnlySelection() async throws {
        let technician = Technician(name: "Tech", contactInfo: "reader@example.com")
        let calendars = [
            GoogleCalendar(id: "reader@example.com", summary: "Reader", timeZone: nil, accessRole: "reader")
        ]

        let selected = ServiceCalendarRouting.validSelection(
            "reader@example.com",
            technician: technician,
            calendars: calendars
        )

        #expect(selected == "primary")
    }

    @Test func serviceCalendarRoutingUsesTechnicianAssignmentTarget() async throws {
        let technician = Technician(name: "Tech", contactInfo: " Tech.Calendar@example.com ")

        let selected = ServiceCalendarRouting.assignedCalendarID(for: technician)

        #expect(selected == "tech.calendar@example.com")
        #expect(ServiceCalendarRouting.assignedCalendarID(for: nil) == "primary")
    }

    @Test func serviceCalendarRoutingDetectsStaleAssignedRoute() async throws {
        let technician = Technician(name: "Tech", contactInfo: "tech.calendar@example.com")

        #expect(ServiceCalendarRouting.hasStaleAssignedCalendarRoute(calendarID: nil, technician: technician))
        #expect(ServiceCalendarRouting.hasStaleAssignedCalendarRoute(calendarID: "old@example.com", technician: technician))
        #expect(ServiceCalendarRouting.hasStaleAssignedCalendarRoute(calendarID: " TECH.CALENDAR@example.com ", technician: technician) == false)
        #expect(ServiceCalendarRouting.hasStaleAssignedCalendarRoute(calendarID: nil, technician: nil) == false)
    }

    @MainActor
    @Test func googleCalendarExportPrefersAssignedTechnicianCalendar() async throws {
        let customer = Customer(name: "Route Customer")
        let technician = Technician(name: "Route Tech", contactInfo: "route.tech@example.com")
        let call = ServiceCall(
            googleCalendarID: "previous.tech@example.com",
            googleEventID: "event-123",
            type: .service,
            scheduledDate: Date(),
            assignedTechnician: technician,
            customer: customer
        )

        let selected = GoogleCalendarScheduleSync.preferredCalendarID(
            for: call,
            availableCalendarIDs: ["previous.tech@example.com", "route.tech@example.com", "primary"],
            writableCalendarIDs: ["previous.tech@example.com", "route.tech@example.com", "primary"]
        )

        #expect(selected == "route.tech@example.com")
    }

    @MainActor
    @Test func googleCalendarExistingEventPatchDoesNotOverwriteExternalDetails() async throws {
        let customer = Customer(name: "Calendar Customer", email: "customer@example.com", address: "123 Local Address")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "event-123",
            googleEventManagedByApp: true,
            eventTitle: "App Title",
            siteAddress: "456 App Address",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3600,
            customer: customer,
            notes: "App notes"
        )

        let patch = GoogleCalendarScheduleSync.makeScheduleOnlyPatch(for: call)
        let encoded = try JSONEncoder().encode(patch)
        let payload = String(data: encoded, encoding: .utf8) ?? ""
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(payload.contains("\"start\""))
        #expect(payload.contains("\"end\""))
        #expect(payload.contains("summary") == false)
        #expect(payload.contains("description") == false)
        #expect(payload.contains("location") == false)
        #expect(payload.contains("attendees") == false)
        #expect(Set(object.keys) == ["start", "end"])
    }

    @MainActor
    @Test func googleCalendarImportedEventsAreReadOnlyForExternalWrites() async throws {
        let customer = Customer(name: "Calendar Customer")
        let importedCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "google-owned-event",
            googleEventManagedByApp: false,
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )
        let appOwnedCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "app-owned-event",
            googleEventManagedByApp: true,
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )
        let newAppCall = ServiceCall(
            googleCalendarID: "primary",
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )

        #expect(GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: importedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: appOwnedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: newAppCall) == true)
    }

    @MainActor
    @Test func googleCalendarImportedEventsDoNotPublishAfterLocalEdits() async throws {
        let customer = Customer(name: "Calendar Customer")
        let importedCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "google-owned-event",
            googleEventManagedByApp: false,
            eventTitle: "Imported title",
            siteAddress: "Imported address",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            notes: "Imported details"
        )
        let appOwnedCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "app-owned-event",
            googleEventManagedByApp: true,
            eventTitle: "App title",
            siteAddress: "App address",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            notes: "App details"
        )
        let newAppCall = ServiceCall(
            googleCalendarID: "primary",
            eventTitle: "New app event",
            siteAddress: "New address",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            notes: "New details"
        )

        #expect(GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: importedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: appOwnedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: newAppCall) == true)
        #expect(GoogleCalendarScheduleSync.shouldCreateGoogleCalendarEvent(for: importedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldCreateGoogleCalendarEvent(for: appOwnedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldCreateGoogleCalendarEvent(for: newAppCall) == true)
    }

    @MainActor
    @Test func googleCalendarSyncDoesNotPublishUnlinkedLocalJobsByDefault() async throws {
        let customer = Customer(name: "Calendar Customer")
        let localCall = ServiceCall(
            googleCalendarID: "primary",
            eventTitle: "Local service call",
            siteAddress: "123 App Address",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            notes: "Local app notes"
        )

        #expect(GoogleCalendarScheduleSync.shouldCreateGoogleCalendarEvent(for: localCall) == true)
        #expect(GoogleCalendarScheduleSync.shouldExportDuringCalendarSync(localCall) == false)
    }

    @MainActor
    @Test func googleCalendarSyncOnlyPublishesExplicitlyMarkedLocalCalendarEdits() async throws {
        let customer = Customer(name: "Calendar Customer")
        let localCall = ServiceCall(
            googleCalendarID: "primary",
            eventTitle: "Local service call",
            siteAddress: "123 App Address",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            notes: "Local app notes"
        )

        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(localCall)

        #expect(GoogleCalendarScheduleSync.shouldExportDuringCalendarSync(localCall))
    }

    @MainActor
    @Test func googleCalendarExternalEventsRemainReadOnlyAfterLocalFieldChanges() async throws {
        let customer = Customer(name: "Calendar Customer")
        let importedCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "google-owned-event",
            googleEventManagedByApp: false,
            eventTitle: "Edited local title",
            siteAddress: "",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3600,
            customer: customer,
            notes: ""
        )

        #expect(GoogleCalendarScheduleSync.isExternalGoogleCalendarEvent(importedCall) == true)
        #expect(GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: importedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: importedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldPreserveExternalGoogleCalendarDetails(for: importedCall) == true)
    }

    @Test func googleCalendarDeletedExternalEventsAreRememberedLocally() async throws {
        let calendarID = "shared-calendar@example.com"
        let eventID = "externally-owned-event-\(UUID().uuidString)"

        #expect(GoogleCalendarScheduleSync.isCalendarEventDeleted(calendarID: calendarID, eventID: eventID) == false)

        GoogleCalendarScheduleSync.markCalendarEventDeleted(calendarID: calendarID, eventID: eventID)

        #expect(GoogleCalendarScheduleSync.isCalendarEventDeleted(calendarID: calendarID, eventID: eventID))
    }

    @MainActor
    @Test func googleCalendarAppOwnedEventsAreReadOnlyAfterGoogleCreation() async throws {
        let customer = Customer(name: "Calendar Customer")
        let appOwnedCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "app-owned-event",
            googleEventManagedByApp: true,
            eventTitle: "App title",
            siteAddress: "App address",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3600,
            customer: customer,
            notes: "App details"
        )

        #expect(GoogleCalendarScheduleSync.isExternalGoogleCalendarEvent(appOwnedCall) == true)
        #expect(GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: appOwnedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: appOwnedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldPreserveExternalGoogleCalendarDetails(for: appOwnedCall) == true)
        #expect(GoogleCalendarScheduleSync.shouldCreateGoogleCalendarEvent(for: appOwnedCall) == false)
    }

    @MainActor
    @Test func googleCalendarExistingEventsAreNeverPatchedFromLocalEdits() async throws {
        let customer = Customer(name: "Calendar Customer")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "event-123",
            googleEventManagedByApp: true,
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )
        let start = GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T13:00:00Z", timeZone: nil)
        let end = GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T14:00:00Z", timeZone: nil)
        let unmarkedRemoteEvent = GoogleCalendarEvent(
            id: "event-123",
            summary: "Existing Google title",
            description: "Keep this body",
            location: "Keep this address",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: nil,
            start: start,
            end: end
        )
        let managedRemoteEvent = GoogleCalendarEvent(
            id: "event-123",
            summary: "Existing Google title",
            description: "Keep this body",
            location: "Keep this address",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: [
                "gunnaireManaged": "true",
                "gunnaireManagedVersion": "3",
                "gunnaireOrigin": "ios-app"
            ]),
            start: start,
            end: end
        )
        let legacyMarkedRemoteEvent = GoogleCalendarEvent(
            id: "event-123",
            summary: "Existing Google title",
            description: "Keep this body",
            location: "Keep this address",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: ["gunnaireManaged": "true"]),
            start: start,
            end: end
        )

        #expect(GoogleCalendarScheduleSync.shouldPatchExistingGoogleCalendarEvent(for: call, remoteEvent: nil) == false)
        #expect(GoogleCalendarScheduleSync.shouldPatchExistingGoogleCalendarEvent(for: call, remoteEvent: unmarkedRemoteEvent) == false)
        #expect(GoogleCalendarScheduleSync.shouldPatchExistingGoogleCalendarEvent(for: call, remoteEvent: legacyMarkedRemoteEvent) == false)
        #expect(GoogleCalendarScheduleSync.shouldPatchExistingGoogleCalendarEvent(for: call, remoteEvent: managedRemoteEvent) == false)
    }

    @Test func googleCalendarCreatePayloadDoesNotClaimExternalEventOwnership() async throws {
        let customer = Customer(name: "Calendar Customer", address: "123 Main St")
        let call = ServiceCall(
            eventTitle: "App-created service call",
            siteAddress: "456 Field Rd",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer,
            notes: "Visible job details."
        )
        let event = GoogleCalendarScheduleSync.makeCalendarCreateEvent(for: call)
        let encoded = try JSONEncoder().encode(event)
        let payload = String(data: encoded, encoding: .utf8) ?? ""

        #expect(payload.contains("\"summary\""))
        #expect(payload.contains("\"description\""))
        #expect(payload.contains("\"location\""))
        #expect(payload.contains("\"extendedProperties\"") == false)
        #expect(payload.contains("gunnaireManaged") == false)
    }

    @MainActor
    @Test func googleCalendarPatchPayloadCannotScrubExternalDetails() async throws {
        let customer = Customer(name: "Calendar Customer")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "event-123",
            googleEventManagedByApp: false,
            eventTitle: "Do not send this title",
            siteAddress: "",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3600,
            customer: customer,
            notes: ""
        )

        let patch = GoogleCalendarScheduleSync.makeManagedEventPatch(for: call, remoteEvent: nil)
        let payload = String(data: try JSONEncoder().encode(patch), encoding: .utf8) ?? ""

        #expect(payload.contains("\"start\""))
        #expect(payload.contains("\"end\""))
        #expect(!payload.contains("summary"))
        #expect(!payload.contains("location"))
        #expect(!payload.contains("description"))
        #expect(!payload.contains("extendedProperties"))
        #expect(!payload.contains("Do not send this title"))
    }

    @MainActor
    @Test func googleCalendarLinkedEventsCannotCreateOrPatchScrubPayloads() async throws {
        let customer = Customer(name: "Calendar Customer")
        let linkedCall = ServiceCall(
            googleCalendarID: "shared-calendar@example.com",
            googleEventID: "google-event-123",
            googleEventManagedByApp: false,
            eventTitle: "",
            siteAddress: "",
            type: .other,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3600,
            customer: customer,
            notes: ""
        )

        #expect(GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: linkedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: linkedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldCreateGoogleCalendarEvent(for: linkedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldPatchExistingGoogleCalendarEvent(for: linkedCall, remoteEvent: nil) == false)

        let payload = String(
            data: try JSONEncoder().encode(GoogleCalendarScheduleSync.makeScheduleOnlyPatch(for: linkedCall)),
            encoding: .utf8
        ) ?? ""

        #expect(payload.contains("summary") == false)
        #expect(payload.contains("location") == false)
        #expect(payload.contains("description") == false)
        #expect(payload.contains("attendees") == false)
    }

    @Test func googleCalendarImportTreatsManagedMarkersAsReadOnly() async throws {
        let start = GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T13:00:00Z", timeZone: nil)
        let end = GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T14:00:00Z", timeZone: nil)
        let externallyManagedEvent = GoogleCalendarEvent(
            id: "external-event",
            summary: "Customer reminder",
            description: "Do not overwrite",
            location: "Customer site",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: nil,
            start: start,
            end: end
        )
        let appManagedEvent = GoogleCalendarEvent(
            id: "app-event",
            summary: "GunnAire service",
            description: "App-created",
            location: "Customer site",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: [
                "gunnaireManaged": "true",
                "gunnaireManagedVersion": "3",
                "gunnaireOrigin": "ios-app"
            ]),
            start: start,
            end: end
        )
        let legacyMarkedEvent = GoogleCalendarEvent(
            id: "legacy-event",
            summary: "Older touched event",
            description: "Do not overwrite",
            location: "Customer site",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: ["gunnaireManaged": "true"]),
            start: start,
            end: end
        )

        #expect(GoogleCalendarScheduleSync.isImportedEventManagedByApp(externallyManagedEvent) == false)
        #expect(GoogleCalendarScheduleSync.isImportedEventManagedByApp(legacyMarkedEvent) == false)
        #expect(GoogleCalendarScheduleSync.isImportedEventManagedByApp(appManagedEvent) == false)
    }

    @Test func gmailRawMessageIncludesPdfAttachment() async throws {
        let attachment = GmailAttachment(
            fileName: "GunnAire-Estimate.pdf",
            mimeType: "application/pdf",
            data: Data("pdf-data".utf8)
        )

        let message = GoogleAuthManager.makeGmailRawMessage(
            to: "customer@example.com",
            subject: "Estimate",
            body: "Attached is your estimate.",
            attachments: [attachment]
        )

        #expect(message.contains("Content-Type: multipart/mixed"))
        #expect(message.contains("Content-Type: text/plain; charset=utf-8"))
        #expect(message.contains("Content-Type: application/pdf; name=\"GunnAire-Estimate.pdf\""))
        #expect(message.contains("Content-Disposition: attachment; filename=\"GunnAire-Estimate.pdf\""))
        #expect(message.contains(Data("pdf-data".utf8).base64EncodedString()))
    }

    @Test func generatedBillingDocumentEmailCanCarryPdfAttachment() async throws {
        let attachment = GmailAttachment(
            fileName: "GunnAire-Invoice.pdf",
            mimeType: "application/pdf",
            data: Data("%PDF generated invoice".utf8)
        )

        let message = GoogleAuthManager.makeGmailRawMessage(
            to: "customer@example.com",
            subject: "GunnAire Paid Invoice",
            body: "Attached is your GunnAire paid invoice.",
            attachments: [attachment]
        )

        #expect(message.contains("To: customer@example.com"))
        #expect(message.contains("Subject: GunnAire Paid Invoice"))
        #expect(message.contains("Content-Type: application/pdf; name=\"GunnAire-Invoice.pdf\""))
        #expect(message.contains("Content-Disposition: attachment; filename=\"GunnAire-Invoice.pdf\""))
    }

    @Test func invoiceDocumentLabelUsesOpenInvoiceUntilFullyPaid() async throws {
        let customer = Customer(name: "Invoice Customer")
        let invoice = Invoice(
            customer: customer,
            lineItemSummary: "Service labor",
            amount: 500,
            status: "sent"
        )
        let partialPayment = Payment(invoice: invoice, amount: 125, method: "card")

        #expect(CustomerDocumentExporter.invoiceDocumentLabel(for: invoice, payments: []) == "Invoice")
        #expect(CustomerDocumentExporter.invoiceDocumentCaption(for: invoice, payments: []) == "Generated invoice PDF")
        #expect(CustomerDocumentExporter.invoiceDocumentLabel(for: invoice, payments: [partialPayment]) == "Invoice")
    }

    @Test func invoiceDocumentLabelUsesPaidInvoiceWhenSettled() async throws {
        let customer = Customer(name: "Invoice Customer")
        let paidByStatus = Invoice(
            customer: customer,
            lineItemSummary: "Service labor",
            amount: 500,
            status: "paid"
        )
        let paidByBalance = Invoice(
            customer: customer,
            lineItemSummary: "Service labor",
            amount: 500,
            status: "sent"
        )
        let fullPayment = Payment(invoice: paidByBalance, amount: 500, method: "ach")

        #expect(CustomerDocumentExporter.invoiceDocumentLabel(for: paidByStatus, payments: []) == "Paid Invoice")
        #expect(CustomerDocumentExporter.invoiceDocumentLabel(for: paidByBalance, payments: [fullPayment]) == "Paid Invoice")
        #expect(CustomerDocumentExporter.invoiceDocumentCaption(for: paidByBalance, payments: [fullPayment]) == "Generated paid invoice PDF")
    }

    @Test func mailDraftRoutePersistsAttachmentPaths() async throws {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "GunnAirePendingMailTo")
        defaults.removeObject(forKey: "GunnAirePendingMailSubject")
        defaults.removeObject(forKey: "GunnAirePendingMailBody")
        defaults.removeObject(forKey: "GunnAirePendingMailAttachmentPaths")

        GunnAireAppIntentRouter.storeMailDraftRoute(
            to: "customer@example.com",
            subject: "Service Report",
            body: "Attached.",
            attachmentPaths: ["/tmp/report.pdf"]
        )
        let draft = GunnAireAppIntentRouter.consumePendingMailDraft()

        #expect(draft?.to == "customer@example.com")
        #expect(draft?.subject == "Service Report")
        #expect(draft?.body == "Attached.")
        #expect(draft?.attachmentPaths == ["/tmp/report.pdf"])
    }

    @MainActor
    @Test func googleCalendarRoutingOnlyChangesBeforeEventExists() async throws {
        let customer = Customer(name: "Calendar Customer")
        let linkedAppCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "google-event-123",
            googleEventManagedByApp: true,
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )
        let linkedExternalCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "external-event-123",
            googleEventManagedByApp: false,
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )
        let newCall = ServiceCall(
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )

        #expect(GoogleCalendarScheduleSync.shouldSelectGoogleCalendarBeforeCreate(for: linkedAppCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldSelectGoogleCalendarBeforeCreate(for: linkedExternalCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldSelectGoogleCalendarBeforeCreate(for: newCall) == true)
    }

    @Test func splashVideoLocatorPrefersStoredVideoOverBundledVideo() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let storedURL = tempDirectory.appendingPathComponent("Loading.mp4")
        try Data([0x00, 0x01, 0x02]).write(to: storedURL)

        let bundledURL = URL(fileURLWithPath: "/tmp/bundled/Loading.mp4")
        let resolved = SplashVideoLocator.preferredURL(
            bundledURL: bundledURL,
            storedCandidates: [storedURL],
            fileManager: .default
        )

        #expect(resolved == storedURL)
    }

    @Test func splashVideoLocatorFallsBackToBundledVideoWhenStoredVideoMissing() async throws {
        let missingStoredURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Loading.mp4")
        let bundledURL = URL(fileURLWithPath: "/tmp/bundled/Loading.mp4")

        let resolved = SplashVideoLocator.preferredURL(
            bundledURL: bundledURL,
            storedCandidates: [missingStoredURL],
            fileManager: .default
        )

        #expect(resolved == bundledURL)
    }

    @Test func splashVideoPreferredDelayUsesFallbackForInvalidDuration() async throws {
        #expect(SplashVideoLocator.preferredFinishDelay(durationSeconds: 0) == 3.0)
        #expect(SplashVideoLocator.preferredFinishDelay(durationSeconds: .infinity) == 3.0)
    }

    @Test func splashVideoPreferredDelayCapsLongVideos() async throws {
        #expect(SplashVideoLocator.preferredFinishDelay(durationSeconds: 2.5) == 2.7)
        #expect(SplashVideoLocator.preferredFinishDelay(durationSeconds: 12) == 6.0)
        #expect(SplashVideoLocator.preferredFinishDelay(durationSeconds: 12, maximumDuration: 4.5) == 4.5)
    }

    @Test func splashVideoSourceDescriptionMatchesExpectedCases() async throws {
        #expect(SplashVideoLocator.Source.custom.description == "Custom Loading.mp4")
        #expect(SplashVideoLocator.Source.bundled.description == "Bundled Loading.mp4")
        #expect(SplashVideoLocator.Source.fallback.description == "Logo Fallback")
    }

    @Test func customerIntelligenceBalanceAccountsForRefunds() async throws {
        let customer = Customer(name: "Balance Customer")
        let invoice = Invoice(customer: customer, amount: 1_000, status: "unpaid")
        let payment = Payment(invoice: invoice, amount: 400, method: "card")
        let refund = Payment(invoice: invoice, amount: 125, method: "card", isRefund: true, refundedPaymentID: payment.id)

        let balance = CustomerIntelligence.outstandingBalance(for: invoice, payments: [payment, refund])

        #expect(balance == 725)
    }

    @Test func invoiceBalanceUsesQuickBooksBalanceWhenPaymentRecordsAreMissing() async throws {
        let customer = Customer(name: "QBO Paid Customer")
        let paidInvoice = Invoice(
            customer: customer,
            quickBooksID: "INV-PAID",
            quickBooksBalanceDue: 0,
            amount: 500,
            status: "unpaid"
        )
        let openInvoice = Invoice(
            customer: customer,
            quickBooksID: "INV-OPEN",
            quickBooksBalanceDue: 125,
            amount: 500,
            status: "paid"
        )

        #expect(Invoice.outstandingBalance(for: paidInvoice, payments: []) == 0)
        #expect(Invoice.isPaid(paidInvoice, payments: []) == true)
        #expect(Invoice.resolvedStatus(for: paidInvoice, payments: []) == "paid")
        #expect(Invoice.outstandingBalance(for: openInvoice, payments: []) == 125)
        #expect(Invoice.isPaid(openInvoice, payments: []) == false)
        #expect(Invoice.resolvedStatus(for: openInvoice, payments: []) == "partial")
    }

    @Test func invoiceLocalPaymentAdjustsStoredQuickBooksBalance() async throws {
        let customer = Customer(name: "QBO Balance Customer")
        let invoice = Invoice(
            customer: customer,
            quickBooksID: "INV-BAL",
            quickBooksBalanceDue: 300,
            amount: 500,
            status: "partial"
        )

        invoice.applyLocalPaymentAmount(125)
        #expect(invoice.quickBooksBalanceDue == 175)
        #expect(Invoice.outstandingBalance(for: invoice, payments: []) == 175)

        invoice.applyLocalPaymentAmount(25, isRefund: true)
        #expect(invoice.quickBooksBalanceDue == 200)
        #expect(Invoice.outstandingBalance(for: invoice, payments: []) == 200)
    }

    @Test func invoiceStatusRankingPreservesPaidStateDuringDuplicateMerge() async throws {
        let paidInvoice = Invoice(customer: Customer(name: "Paid Customer"), amount: 500, status: " Paid ")

        #expect(paidInvoice.normalizedStatus == "paid")
        #expect(Invoice.mostResolvedStatus("unpaid", "paid") == "paid")
        #expect(Invoice.mostResolvedStatus("overdue", "partial") == "partial")
        #expect(Invoice.mostResolvedStatus("paid", "partial") == "paid")
        #expect(Invoice.mostResolvedStatus("", "unpaid") == "unpaid")
    }

    @Test func invoiceDisplayDeduplicationPrefersPaidQuickBooksRecord() async throws {
        let customer = Customer(name: "Display Customer")
        let serviceCallID = UUID()
        let localDuplicate = Invoice(
            serviceCallID: serviceCallID,
            customer: customer,
            amount: 500,
            status: "unpaid",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let quickBooksPaid = Invoice(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "INV-123",
            amount: 500,
            status: "paid",
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let displayed = Invoice.displayDeduplicated([localDuplicate, quickBooksPaid])

        #expect(displayed.count == 1)
        #expect(displayed.first === quickBooksPaid)
        #expect(displayed.first?.normalizedStatus == "paid")
    }

    @Test func estimateDisplayDeduplicationPrefersQuickBooksRecord() async throws {
        let customer = Customer(name: "Estimate Display Customer")
        let serviceCallID = UUID()
        let localDuplicate = Estimate(
            serviceCallID: serviceCallID,
            customer: customer,
            amount: 750,
            status: "pending",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let quickBooksEstimate = Estimate(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "EST-123",
            amount: 750,
            status: "accepted",
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let displayed = Estimate.displayDeduplicated([localDuplicate, quickBooksEstimate])

        #expect(displayed.count == 1)
        #expect(displayed.first === quickBooksEstimate)
        #expect(displayed.first?.status == "accepted")
    }

    @Test func invoicePaymentHistoryRowsLabelRefundsClearly() async throws {
        let customer = Customer(name: "Refund Customer")
        let invoice = Invoice(customer: customer, amount: 1_000, status: "partial")
        let payment = Payment(
            invoice: invoice,
            amount: 400,
            date: Date(timeIntervalSince1970: 20),
            method: "card"
        )
        let refund = Payment(
            invoice: invoice,
            amount: 125,
            date: Date(timeIntervalSince1970: 40),
            method: "card",
            isRefund: true,
            refundedPaymentID: payment.id
        )

        let rows = CustomerDocumentExporter.invoicePaymentHistoryRows(for: [refund, payment])

        #expect(rows.count == 2)
        #expect(rows[0].value.contains("Payment"))
        #expect(rows[0].value.contains("$400"))
        #expect(rows[1].value.contains("Refund"))
        #expect(rows[1].value.contains("-$125"))
    }

    @Test func paymentSharedCompanyQueueFailureDoesNotRequireQuickBooksRetry() async throws {
        let customer = Customer(name: "Queue Customer")
        let invoice = Invoice(customer: customer, amount: 250, status: "partial")
        let payment = Payment(
            invoice: invoice,
            processorSyncStatus: "needs_attention",
            processorSyncDetail: "Shared company payment queue upload failed: offline",
            amount: 250,
            method: "card"
        )

        #expect(payment.needsSharedCompanyQueueUpload)
        #expect(payment.needsQuickBooksAttention == false)
    }

    @Test func paymentProcessorFailureStillRequiresQuickBooksRetryWhenNotCompanyQueue() async throws {
        let customer = Customer(name: "Processor Customer")
        let invoice = Invoice(customer: customer, amount: 250, status: "partial")
        let payment = Payment(
            invoice: invoice,
            processorSyncStatus: "needs_attention",
            processorSyncDetail: "QuickBooks Payments authorization failed.",
            amount: 250,
            method: "card"
        )

        #expect(payment.needsSharedCompanyQueueUpload == false)
        #expect(payment.needsQuickBooksAttention)
    }

    @Test func backendPaymentCollectionsDecodeSharedFieldQueueResponse() async throws {
        let json = Data("""
        {
          "payments": [
            {
              "id": "queue-record-1",
              "paymentID": "payment-1",
              "invoiceID": "invoice-1",
              "invoiceQuickBooksID": "123",
              "customerName": "Shared Customer",
              "customerEmail": "customer@example.com",
              "amount": 275.5,
              "method": "card",
              "cardLast4": "4242",
              "authorizationReference": "auth-1",
              "processor": "quickbooks-payments",
              "notes": "Field collection",
              "collectedBy": "tech@gunnaire.com",
              "collectedAt": "2026-08-13T14:00:00Z",
              "createdAt": "2026-08-13T14:01:00Z"
            }
          ]
        }
        """.utf8)

        let records = try GunnAireBackendService.decodePaymentCollections(from: json)

        #expect(records.count == 1)
        #expect(records[0].paymentID == "payment-1")
        #expect(records[0].customerName == "Shared Customer")
        #expect(records[0].amount == 275.5)
        #expect(records[0].collectedBy == "tech@gunnaire.com")
    }

    @Test func backendDocumentsDecodeSharedDocumentInventoryResponse() async throws {
        let json = Data("""
        {
          "documents": [
            {
              "id": "document-1",
              "filename": "service-report.pdf",
              "contentType": "application/pdf",
              "kind": "service_report",
              "serviceCallID": "call-1",
              "customerName": "Shared Customer",
              "storedPath": "/storage/service-report.pdf",
              "createdAt": "2026-08-13T14:01:00Z"
            }
          ]
        }
        """.utf8)

        let records = try GunnAireBackendService.decodeDocuments(from: json)

        #expect(records.count == 1)
        #expect(records[0].id == "document-1")
        #expect(records[0].filename == "service-report.pdf")
        #expect(records[0].kind == "service_report")
        #expect(records[0].customerName == "Shared Customer")
    }

    @Test func customerIntelligencePrioritizesOverdueCollection() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let customer = Customer(
            name: "Priority Customer",
            phone: "555-0100",
            email: "ops@example.com",
            address: "100 Field Way"
        )
        let invoice = Invoice(
            customer: customer,
            amount: 500,
            status: "unpaid",
            createdAt: now.addingTimeInterval(-10 * 24 * 60 * 60)
        )

        let snapshot = CustomerIntelligence.snapshot(
            for: customer,
            serviceCalls: [],
            invoices: [invoice],
            estimates: [],
            payments: [],
            contracts: [],
            now: now
        )

        #expect(snapshot.openBalance == 500)
        #expect(snapshot.overdueInvoiceCount == 1)
        #expect(snapshot.healthScore < 70)
        #expect(snapshot.primaryAction == .collectPayment(invoice.id))
    }

    @Test func customerIntelligenceRanksRiskBeforeHealthyAccounts() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let healthy = Customer(
            name: "Healthy Account",
            phone: "555-0101",
            email: "healthy@example.com",
            address: "200 Maintenance Dr"
        )
        let risky = Customer(
            name: "Risky Account",
            phone: "555-0102",
            email: "risky@example.com",
            address: "300 Receivable Ave"
        )
        let riskyInvoice = Invoice(
            customer: risky,
            amount: 1_200,
            status: "unpaid",
            createdAt: now.addingTimeInterval(-14 * 24 * 60 * 60)
        )

        let snapshots = CustomerIntelligence.snapshots(
            customers: [healthy, risky],
            serviceCalls: [],
            invoices: [riskyInvoice],
            estimates: [],
            payments: [],
            contracts: [],
            now: now
        )

        #expect(snapshots.first?.customer.id == risky.id)
    }

    @Test func businessSuitePrioritizesOverdueCollectionsAcrossModules() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let customer = Customer(
            name: "Suite Customer",
            phone: "555-0110",
            email: "suite@example.com",
            address: "400 Command Center"
        )
        let invoice = Invoice(
            customer: customer,
            amount: 900,
            status: "unpaid",
            createdAt: now.addingTimeInterval(-11 * 24 * 60 * 60)
        )
        let readyCall = ServiceCall(
            type: .service,
            scheduledDate: now.addingTimeInterval(-2 * 60 * 60),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )

        let snapshot = BusinessSuiteIntelligence.snapshot(
            customers: [customer],
            serviceCalls: [readyCall],
            technicians: [],
            contracts: [],
            estimates: [],
            invoices: [invoice],
            payments: [],
            timeEntries: [],
            googleConnected: true,
            quickBooksConnected: true,
            onsitePaymentsReady: true,
            now: now
        )

        #expect(snapshot.openReceivablesTotal == 900)
        #expect(snapshot.readyToBillCount == 1)
        #expect(snapshot.actions.first?.destination == .collectPayment(invoice.id))
    }

    @Test func businessSuiteScoresIntegrationGaps() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let customer = Customer(
            name: "Sync Customer",
            phone: "555-0111",
            email: "sync@example.com",
            address: "500 Integration Ave"
        )
        let call = ServiceCall(
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(24 * 60 * 60),
            customer: customer
        )
        let estimate = Estimate(customer: customer, amount: 1_250, status: "pending")
        let invoice = Invoice(customer: customer, amount: 300, status: "unpaid")

        let snapshot = BusinessSuiteIntelligence.snapshot(
            customers: [customer],
            serviceCalls: [call],
            technicians: [],
            contracts: [],
            estimates: [estimate],
            invoices: [invoice],
            payments: [],
            timeEntries: [],
            googleConnected: true,
            quickBooksConnected: true,
            onsitePaymentsReady: false,
            now: now
        )

        let integrations = try #require(snapshot.workstreams.first { $0.id == .integrations })

        #expect(snapshot.syncAttentionCount == 3)
        #expect(integrations.score < 100)
        #expect(snapshot.actions.contains { $0.destination == .sync })
    }

    @Test func businessSuiteScoresStaleCalendarRoutesAsIntegrationGaps() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let customer = Customer(name: "Route Customer", address: "510 Integration Ave")
        let technician = Technician(name: "Route Tech", contactInfo: "route.tech@example.com")
        let call = ServiceCall(
            googleCalendarID: "previous.tech@example.com",
            googleEventID: "event-123",
            type: .service,
            scheduledDate: now.addingTimeInterval(2 * 60 * 60),
            assignedTechnician: technician,
            customer: customer
        )

        let snapshot = BusinessSuiteIntelligence.snapshot(
            customers: [customer],
            serviceCalls: [call],
            technicians: [technician],
            contracts: [],
            estimates: [],
            invoices: [],
            payments: [],
            timeEntries: [],
            googleConnected: true,
            quickBooksConnected: true,
            onsitePaymentsReady: true,
            now: now
        )

        let integrations = try #require(snapshot.workstreams.first { $0.id == .integrations })

        #expect(snapshot.syncAttentionCount == 1)
        #expect(integrations.detail.contains("1 calendar"))
        #expect(snapshot.actions.contains { $0.title == "Tighten sync coverage" })
    }

    @Test func businessSuiteFlagsPricebookMarginAndCostGaps() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let unpricedItem = Item(name: "Emergency Diagnostic", unitPrice: 0)
        let lowMarginItem = Item(name: "Compressor Changeout", unitPrice: 500, purchaseCost: 450)
        let missingCostItem = Item(name: "Maintenance Tune-Up", unitPrice: 189)
        let vendor = Vendor(name: "HVAC Supply")

        let snapshot = BusinessSuiteIntelligence.snapshot(
            customers: [],
            serviceCalls: [],
            technicians: [],
            contracts: [],
            estimates: [],
            invoices: [],
            payments: [],
            timeEntries: [],
            items: [unpricedItem, lowMarginItem, missingCostItem],
            vendors: [vendor],
            googleConnected: true,
            quickBooksConnected: true,
            onsitePaymentsReady: true,
            now: now
        )

        let pricebook = try #require(snapshot.workstreams.first { $0.id == .pricebook })

        #expect(snapshot.catalogItemCount == 3)
        #expect(snapshot.pricebookAttentionCount == 6)
        #expect(pricebook.score < 70)
        #expect(snapshot.actions.contains { $0.title == "Set catalog price" && $0.destination == .quickBooks })
    }

    @Test func businessSuiteKeepsHealthyPricebookStable() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let diagnostic = Item(
            quickBooksID: "QB-ITEM-1",
            name: "Diagnostic Visit",
            unitPrice: 189,
            purchaseCost: 42
        )
        let capacitor = Item(
            quickBooksID: "QB-ITEM-2",
            name: "Capacitor Replacement",
            unitPrice: 329,
            purchaseCost: 90
        )
        let vendor = Vendor(name: "HVAC Supply")

        let snapshot = BusinessSuiteIntelligence.snapshot(
            customers: [],
            serviceCalls: [],
            technicians: [],
            contracts: [],
            estimates: [],
            invoices: [],
            payments: [],
            timeEntries: [],
            items: [diagnostic, capacitor],
            vendors: [vendor],
            googleConnected: true,
            quickBooksConnected: true,
            onsitePaymentsReady: true,
            now: now
        )

        let pricebook = try #require(snapshot.workstreams.first { $0.id == .pricebook })

        #expect(snapshot.pricebookAttentionCount == 0)
        #expect(snapshot.averageGrossMargin > 0.70)
        #expect(pricebook.score == 100)
    }

}
