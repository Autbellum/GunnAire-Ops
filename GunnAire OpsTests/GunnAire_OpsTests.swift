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

        #expect(refrigerantDefinition?.options.contains("R-410A") == true)
        #expect(refrigerantDefinition?.options.contains("R-454B") == true)
        #expect(meteringDeviceDefinition?.options.contains("TXV") == true)
        #expect(superheatDefinition?.options.isEmpty == true)
    }

    @Test func equipmentSpecificReportDefinitionsIncludeFieldServiceControls() async throws {
        let heatPumpKeys = Set(HVACEquipmentType.heatPump.readingDefinitions.map(\.key))
        let furnaceDefinitions = HVACEquipmentType.gasFurnace.readingDefinitions
        let waterHeaterDefinitions = HVACEquipmentType.waterHeater.readingDefinitions
        let airHandlerDefinitions = HVACEquipmentType.airHandler.readingDefinitions

        #expect(heatPumpKeys.contains("reversing_valve_operation"))
        #expect(heatPumpKeys.contains("defrost_control_status"))
        #expect(furnaceDefinitions.first { $0.key == "ignition_type" }?.options.contains("Hot Surface Ignition") == true)
        #expect(furnaceDefinitions.first { $0.key == "heat_exchanger_condition" }?.options.contains("Needs Repair") == true)
        #expect(waterHeaterDefinitions.first { $0.key == "tank_condition" }?.options.contains("Replacement Recommended") == true)
        #expect(airHandlerDefinitions.first { $0.key == "blower_type" }?.options.contains("ECM Variable Speed") == true)
    }

    @Test func hvacEquipmentReadingDefinitionKeysAreUniquePerEquipmentType() async throws {
        for equipmentType in HVACEquipmentType.allCases {
            let keys = equipmentType.readingDefinitions.map(\.key)
            #expect(Set(keys).count == keys.count, "\(equipmentType.displayName) has duplicate technical reading keys")
        }
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

    @Test func serviceReportAttachmentUploadEligibilityRequiresLinkedQuickBooksInvoice() async throws {
        let customer = Customer(name: "Report Customer")
        let invoice = Invoice(customer: customer, quickBooksID: "123", amount: 250)
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
        let localOnlyInvoice = Invoice(customer: customer, amount: 250)

        #expect(unSyncedReport.canUploadToQuickBooksInvoice(invoice) == true)
        #expect(uploadedReport.canUploadToQuickBooksInvoice(invoice) == false)
        #expect(photo.canUploadToQuickBooksInvoice(invoice) == false)
        #expect(unSyncedReport.canUploadToQuickBooksInvoice(localOnlyInvoice) == false)
    }

    @MainActor
    @Test func quickBooksInvoiceAttachmentSyncFindsPendingServiceReports() async throws {
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

        let pending = QuickBooksInvoiceAttachmentSync.pendingServiceReports(
            invoices: [invoice, otherInvoice],
            attachments: [pendingReport, uploadedReport]
        )

        #expect(pending.count == 1)
        #expect(pending.first?.attachment === pendingReport)
        #expect(pending.first?.invoice === invoice)
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

        #expect(payload.contains("\"start\""))
        #expect(payload.contains("\"end\""))
        #expect(payload.contains("summary") == false)
        #expect(payload.contains("description") == false)
        #expect(payload.contains("location") == false)
        #expect(payload.contains("attendees") == false)
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
        #expect(GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: appOwnedCall) == true)
        #expect(GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: newAppCall) == true)
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
