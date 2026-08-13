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
