import AppIntents
import Foundation
import SwiftData

enum GunnAireAppRoute: String, CaseIterable {
    case commandCenter = "commandCenter"
    case timeClock = "timeClock"
    case schedule = "scheduleAndJobs"
    case customers = "customers"
    case mail = "mail"
    case estimates = "estimates"
    case invoices = "invoices"
    case invoicesEstimates = "invoicesEstimates"
    case payments = "payments"
    case reports = "reports"
    case receiptsBills = "receiptsBills"
    case documentation = "onsiteDocumentation"
    case sync = "syncIntegrations"
    case quickBooks = "quickBooksManagement"

    var sidebarItem: SidebarItem {
        switch self {
        case .commandCenter:
            return .commandCenter
        case .timeClock:
            return .timeClock
        case .schedule:
            return .scheduleAndJobs
        case .customers:
            return .customers
        case .mail:
            return .mail
        case .estimates:
            return .estimates
        case .invoices:
            return .invoices
        case .invoicesEstimates:
            return .invoices
        case .payments:
            return .payments
        case .reports:
            return .reports
        case .receiptsBills:
            return .receiptsBills
        case .documentation:
            return .onsiteDocumentation
        case .sync:
            return .syncIntegrations
        case .quickBooks:
            return .quickBooksManagement
        }
    }

    var shortTitle: LocalizedStringResource {
        switch self {
        case .commandCenter:
            return "Command Center"
        case .timeClock:
            return "Clock In/Out"
        case .schedule:
            return "Schedule"
        case .customers:
            return "Customers"
        case .mail:
            return "Mail"
        case .estimates:
            return "Estimates"
        case .invoices:
            return "Invoices"
        case .invoicesEstimates:
            return "Invoices"
        case .payments:
            return "Payments"
        case .reports:
            return "Reports"
        case .receiptsBills:
            return "Receipts"
        case .documentation:
            return "Documentation"
        case .sync:
            return "Sync"
        case .quickBooks:
            return "QuickBooks"
        }
    }

    var systemImageName: String {
        switch self {
        case .commandCenter:
            return "rectangle.3.group"
        case .timeClock:
            return "clock"
        case .schedule:
            return "calendar"
        case .customers:
            return "person.3"
        case .mail:
            return "envelope"
        case .estimates:
            return "doc.text.magnifyingglass"
        case .invoices:
            return "doc.text"
        case .invoicesEstimates:
            return "doc.text"
        case .payments:
            return "creditcard"
        case .reports:
            return "chart.bar.xaxis"
        case .receiptsBills:
            return "tray.and.arrow.up"
        case .documentation:
            return "book"
        case .sync:
            return "arrow.triangle.2.circlepath"
        case .quickBooks:
            return "banknote"
        }
    }
}

/// App Intents can resolve entities before GunnAire Ops presents its normal
/// sidebar. Keep Siri, Shortcuts, Spotlight, and saved shortcut parameters on
/// the same authenticated role and record boundary as the visible app UI.
/// A provider session is required in addition to a local role row so stale
/// shared-device defaults cannot enumerate company records after sign-out.
enum GunnAireAppIntentAccessPolicy {
    static func canOpen(
        _ route: GunnAireAppRoute,
        email: String?,
        users: [AppUser],
        hasAuthenticatedProvider: Bool
    ) -> Bool {
        guard hasAuthenticatedProvider else { return false }
        return AppAccess.canAccessSidebarItem(
            route.sidebarItem,
            email: email,
            users: users
        )
    }

    static func visibleCustomerIDs(
        email: String?,
        users: [AppUser],
        customers: [Customer],
        hasAuthenticatedProvider: Bool
    ) -> Set<UUID> {
        guard canOpen(
            .customers,
            email: email,
            users: users,
            hasAuthenticatedProvider: hasAuthenticatedProvider
        ) else { return [] }
        return Set(customers.map(\.id))
    }

    static func visibleServiceCallIDs(
        email: String?,
        users: [AppUser],
        serviceCalls: [ServiceCall],
        technicians: [Technician],
        hasAuthenticatedProvider: Bool
    ) -> Set<UUID> {
        guard hasAuthenticatedProvider else { return [] }
        let canOpenJobs = canOpen(
            .schedule,
            email: email,
            users: users,
            hasAuthenticatedProvider: true
        ) || canOpen(
            .documentation,
            email: email,
            users: users,
            hasAuthenticatedProvider: true
        )
        guard canOpenJobs else { return [] }
        return AppAccess.visibleServiceCallIDs(
            email: email,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
    }

    static func visibleInvoiceIDs(
        email: String?,
        users: [AppUser],
        serviceCalls: [ServiceCall],
        invoices: [Invoice],
        technicians: [Technician],
        hasAuthenticatedProvider: Bool
    ) -> Set<UUID> {
        guard hasAuthenticatedProvider else { return [] }
        let canOpenBilling = canOpen(
            .invoices,
            email: email,
            users: users,
            hasAuthenticatedProvider: true
        ) || canOpen(
            .payments,
            email: email,
            users: users,
            hasAuthenticatedProvider: true
        )
        guard canOpenBilling else { return [] }
        return AppAccess.visibleFieldPaymentInvoiceIDs(
            email: email,
            users: users,
            serviceCalls: serviceCalls,
            invoices: invoices,
            technicians: technicians
        )
    }
}

enum GunnAireMailWorkflow: String, Codable, Sendable {
    case general
    case estimateFollowUp
    case paymentReminder
    case appointmentConfirmation
    case technicianEnRoute
    case technicianArrival
    case workInProgress
    case serviceFollowUp
    case maintenanceVisitReminder
    case maintenanceRenewal
    case postJobReview
    case receipt
    case customerDocument
    case accountStatement

    var displayName: String {
        switch self {
        case .general: "General email"
        case .estimateFollowUp: "Estimate follow-up"
        case .paymentReminder: "Payment reminder"
        case .appointmentConfirmation: "Appointment confirmation"
        case .technicianEnRoute: "On-my-way update"
        case .technicianArrival: "Arrival update"
        case .workInProgress: "Work-in-progress update"
        case .serviceFollowUp: "Service follow-up"
        case .maintenanceVisitReminder: "Maintenance reminder"
        case .maintenanceRenewal: "Agreement renewal"
        case .postJobReview: "Review request"
        case .receipt: "Payment receipt"
        case .customerDocument: "Customer document"
        case .accountStatement: "Account statement"
        }
    }

    var templateVersion: String {
        "\(rawValue)-v1"
    }

    var requiresMarketingConsent: Bool {
        self == .postJobReview
    }
}

enum GunnAireAppIntentRouter {
    struct PaymentCollectionRoute: Equatable {
        let invoiceID: UUID
        let prefersContactlessGuide: Bool
        let expiresAt: Date?
    }

    nonisolated static func store(_ route: GunnAireAppRoute) {
        UserDefaults.standard.set(route.rawValue, forKey: "GunnAirePendingAppRoute")
        NotificationCenter.default.post(name: Notification.Name("GunnAireRouteDidChange"), object: nil)
    }

    nonisolated static func consumePendingRoute() -> GunnAireAppRoute? {
        guard let rawValue = UserDefaults.standard.string(forKey: "GunnAirePendingAppRoute"),
              let route = GunnAireAppRoute(rawValue: rawValue) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingAppRoute")
        return route
    }

    /// Removes context queued for a route that the current account cannot open.
    /// This is intentionally separate from route consumption: a shared iPad must
    /// never retain a customer, job, invoice, or email draft for a later user.
    nonisolated static func discardPendingPayload(for route: GunnAireAppRoute) {
        switch route {
        case .customers:
            UserDefaults.standard.removeObject(forKey: "GunnAirePendingCustomerID")
        case .schedule:
            UserDefaults.standard.removeObject(forKey: "GunnAirePendingScheduleServiceCallID")
        case .documentation, .invoices:
            UserDefaults.standard.removeObject(forKey: "GunnAirePendingServiceCallID")
        case .payments:
            clearPendingPaymentCollectionRoute()
            clearDeferredPaymentCollectionRoute()
        case .mail:
            UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailTo")
            UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailSubject")
            UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailBody")
            UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailAttachmentPaths")
            UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailCustomerID")
            UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailServiceCallID")
            UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailInvoiceID")
            UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailEstimateID")
            UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailMaintenanceContractID")
            UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailWorkflow")
        case .quickBooks:
            UserDefaults.standard.removeObject(forKey: "GunnAirePendingQuickBooksWorkspace")
        case .commandCenter, .timeClock, .estimates, .invoicesEstimates, .reports, .receiptsBills, .sync:
            break
        }
    }

    /// A sign-out on a shared iPad or Mac must not leave customer, billing, or
    /// message context for the next person who authenticates.
    nonisolated static func discardAllPendingPayloads() {
        let keys = [
            "GunnAirePendingAppRoute",
            "GunnAirePendingCustomerID",
            "GunnAirePendingScheduleServiceCallID",
            "GunnAirePendingServiceCallID",
            "GunnAirePendingInvoiceID",
            "GunnAirePendingOpenPaymentCollection",
            "GunnAirePendingContactlessPaymentGuide",
            "GunnAirePendingPaymentCollectionExpiresAt",
            "GunnAireDeferredFieldCollectionInvoiceID",
            "GunnAireDeferredFieldCollectionOwner",
            "GunnAireDeferredContactlessPaymentGuide",
            "GunnAireDeferredPaymentCollectionExpiresAt",
            "GunnAirePendingMailTo",
            "GunnAirePendingMailSubject",
            "GunnAirePendingMailBody",
            "GunnAirePendingMailAttachmentPaths",
            "GunnAirePendingMailCustomerID",
            "GunnAirePendingMailServiceCallID",
            "GunnAirePendingMailInvoiceID",
            "GunnAirePendingMailEstimateID",
            "GunnAirePendingMailMaintenanceContractID",
            "GunnAirePendingMailWorkflow",
            "GunnAirePendingQuickBooksWorkspace"
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    nonisolated static func storeQuickBooksRoute(workspace: QuickBooksManagementWorkspace) {
        UserDefaults.standard.set(workspace.rawValue, forKey: "GunnAirePendingQuickBooksWorkspace")
        store(.quickBooks)
    }

    nonisolated static func consumePendingQuickBooksWorkspace() -> QuickBooksManagementWorkspace? {
        let key = "GunnAirePendingQuickBooksWorkspace"
        guard let rawValue = UserDefaults.standard.string(forKey: key) else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return QuickBooksManagementWorkspace(rawValue: rawValue)
    }

    nonisolated static func storeCustomerRoute(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: "GunnAirePendingCustomerID")
        store(.customers)
    }

    nonisolated static func consumePendingCustomerID() -> UUID? {
        guard let rawValue = UserDefaults.standard.string(forKey: "GunnAirePendingCustomerID"),
              let id = UUID(uuidString: rawValue) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingCustomerID")
        return id
    }

    nonisolated static func storeDocumentationRoute(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: "GunnAirePendingServiceCallID")
        store(.documentation)
    }

    nonisolated static func storeInvoiceBuilderRoute(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: "GunnAirePendingServiceCallID")
        store(.invoices)
    }

    nonisolated static func consumePendingServiceCallID() -> UUID? {
        guard let rawValue = UserDefaults.standard.string(forKey: "GunnAirePendingServiceCallID"),
              let id = UUID(uuidString: rawValue) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingServiceCallID")
        return id
    }

    nonisolated static func storeScheduleCallRoute(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: "GunnAirePendingScheduleServiceCallID")
        store(.schedule)
    }

    nonisolated static func consumePendingScheduleCallID() -> UUID? {
        guard let rawValue = UserDefaults.standard.string(forKey: "GunnAirePendingScheduleServiceCallID"),
              let id = UUID(uuidString: rawValue) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingScheduleServiceCallID")
        return id
    }

    nonisolated static func storePaymentCollectionRoute(
        _ id: UUID,
        prefersContactlessGuide: Bool = false,
        expiresAt: Date? = nil
    ) {
        UserDefaults.standard.set(id.uuidString, forKey: "GunnAirePendingInvoiceID")
        UserDefaults.standard.set(true, forKey: "GunnAirePendingOpenPaymentCollection")
        UserDefaults.standard.set(prefersContactlessGuide, forKey: "GunnAirePendingContactlessPaymentGuide")
        if let expiresAt {
            UserDefaults.standard.set(expiresAt, forKey: "GunnAirePendingPaymentCollectionExpiresAt")
        } else {
            UserDefaults.standard.removeObject(forKey: "GunnAirePendingPaymentCollectionExpiresAt")
        }
        store(.payments)
    }

    nonisolated static func consumePendingPaymentCollectionRoute(
        now: Date = Date()
    ) -> PaymentCollectionRoute? {
        guard UserDefaults.standard.bool(forKey: "GunnAirePendingOpenPaymentCollection"),
              let rawValue = UserDefaults.standard.string(forKey: "GunnAirePendingInvoiceID"),
              let id = UUID(uuidString: rawValue) else {
            clearPendingPaymentCollectionRoute()
            return nil
        }
        let prefersContactlessGuide = UserDefaults.standard.bool(forKey: "GunnAirePendingContactlessPaymentGuide")
        let expiresAt = paymentCollectionExpirationDate(
            forKey: "GunnAirePendingPaymentCollectionExpiresAt"
        )
        clearPendingPaymentCollectionRoute()
        guard expiresAt.map({ $0 > now }) ?? true else { return nil }
        return PaymentCollectionRoute(
            invoiceID: id,
            prefersContactlessGuide: prefersContactlessGuide,
            expiresAt: expiresAt
        )
    }

    /// Retains a collection handoff while CloudKit delivers the authorized
    /// invoice graph. The owner binding prevents a shared device from exposing
    /// the deferred invoice identifier after an account change.
    nonisolated static func storeDeferredPaymentCollectionRoute(
        _ id: UUID,
        ownerEmail: String?,
        prefersContactlessGuide: Bool = false,
        expiresAt: Date? = nil
    ) {
        let owner = normalizedRouteOwner(ownerEmail)
        guard !owner.isEmpty else {
            clearDeferredPaymentCollectionRoute()
            return
        }
        UserDefaults.standard.set(id.uuidString, forKey: "GunnAireDeferredFieldCollectionInvoiceID")
        UserDefaults.standard.set(owner, forKey: "GunnAireDeferredFieldCollectionOwner")
        UserDefaults.standard.set(prefersContactlessGuide, forKey: "GunnAireDeferredContactlessPaymentGuide")
        if let expiresAt {
            UserDefaults.standard.set(expiresAt, forKey: "GunnAireDeferredPaymentCollectionExpiresAt")
        } else {
            UserDefaults.standard.removeObject(forKey: "GunnAireDeferredPaymentCollectionExpiresAt")
        }
    }

    nonisolated static func deferredPaymentCollectionRoute(
        ownerEmail: String?,
        now: Date = Date()
    ) -> PaymentCollectionRoute? {
        let requestedOwner = normalizedRouteOwner(ownerEmail)
        guard !requestedOwner.isEmpty,
              let storedOwner = UserDefaults.standard.string(forKey: "GunnAireDeferredFieldCollectionOwner"),
              storedOwner == requestedOwner,
              let rawValue = UserDefaults.standard.string(forKey: "GunnAireDeferredFieldCollectionInvoiceID"),
              let id = UUID(uuidString: rawValue) else {
            clearDeferredPaymentCollectionRoute()
            return nil
        }
        let expiresAt = paymentCollectionExpirationDate(
            forKey: "GunnAireDeferredPaymentCollectionExpiresAt"
        )
        guard expiresAt.map({ $0 > now }) ?? true else {
            clearDeferredPaymentCollectionRoute()
            return nil
        }
        return PaymentCollectionRoute(
            invoiceID: id,
            prefersContactlessGuide: UserDefaults.standard.bool(
                forKey: "GunnAireDeferredContactlessPaymentGuide"
            ),
            expiresAt: expiresAt
        )
    }

    nonisolated static func clearPendingPaymentCollectionRoute() {
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingInvoiceID")
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingOpenPaymentCollection")
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingContactlessPaymentGuide")
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingPaymentCollectionExpiresAt")
    }

    nonisolated static func clearDeferredPaymentCollectionRoute() {
        UserDefaults.standard.removeObject(forKey: "GunnAireDeferredFieldCollectionInvoiceID")
        UserDefaults.standard.removeObject(forKey: "GunnAireDeferredFieldCollectionOwner")
        UserDefaults.standard.removeObject(forKey: "GunnAireDeferredContactlessPaymentGuide")
        UserDefaults.standard.removeObject(forKey: "GunnAireDeferredPaymentCollectionExpiresAt")
    }

    nonisolated private static func paymentCollectionExpirationDate(forKey key: String) -> Date? {
        if let date = UserDefaults.standard.object(forKey: key) as? Date {
            return date
        }
        if let number = UserDefaults.standard.object(forKey: key) as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let rawValue = UserDefaults.standard.string(forKey: key),
           let interval = TimeInterval(rawValue) {
            return Date(timeIntervalSince1970: interval)
        }
        return nil
    }

    nonisolated private static func normalizedRouteOwner(_ email: String?) -> String {
        email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    nonisolated static func storeMailDraftRoute(
        to: String,
        subject: String,
        body: String,
        attachmentPaths: [String] = [],
        customerID: UUID? = nil,
        serviceCallID: UUID? = nil,
        invoiceID: UUID? = nil,
        estimateID: UUID? = nil,
        maintenanceContractID: UUID? = nil,
        workflow: GunnAireMailWorkflow = .general
    ) {
        UserDefaults.standard.set(to, forKey: "GunnAirePendingMailTo")
        UserDefaults.standard.set(subject, forKey: "GunnAirePendingMailSubject")
        UserDefaults.standard.set(body, forKey: "GunnAirePendingMailBody")
        UserDefaults.standard.set(attachmentPaths, forKey: "GunnAirePendingMailAttachmentPaths")
        UserDefaults.standard.set(customerID?.uuidString, forKey: "GunnAirePendingMailCustomerID")
        UserDefaults.standard.set(serviceCallID?.uuidString, forKey: "GunnAirePendingMailServiceCallID")
        UserDefaults.standard.set(invoiceID?.uuidString, forKey: "GunnAirePendingMailInvoiceID")
        UserDefaults.standard.set(estimateID?.uuidString, forKey: "GunnAirePendingMailEstimateID")
        UserDefaults.standard.set(maintenanceContractID?.uuidString, forKey: "GunnAirePendingMailMaintenanceContractID")
        UserDefaults.standard.set(workflow.rawValue, forKey: "GunnAirePendingMailWorkflow")
        store(.mail)
    }

    nonisolated static func consumePendingMailDraft() -> (to: String, subject: String, body: String, attachmentPaths: [String], customerID: UUID?, serviceCallID: UUID?, invoiceID: UUID?, estimateID: UUID?, maintenanceContractID: UUID?, workflow: GunnAireMailWorkflow)? {
        guard let to = UserDefaults.standard.string(forKey: "GunnAirePendingMailTo"),
              let subject = UserDefaults.standard.string(forKey: "GunnAirePendingMailSubject"),
              let body = UserDefaults.standard.string(forKey: "GunnAirePendingMailBody") else {
            return nil
        }
        let attachmentPaths = UserDefaults.standard.stringArray(forKey: "GunnAirePendingMailAttachmentPaths") ?? []
        let customerID = UserDefaults.standard.string(forKey: "GunnAirePendingMailCustomerID").flatMap(UUID.init(uuidString:))
        let serviceCallID = UserDefaults.standard.string(forKey: "GunnAirePendingMailServiceCallID").flatMap(UUID.init(uuidString:))
        let invoiceID = UserDefaults.standard.string(forKey: "GunnAirePendingMailInvoiceID").flatMap(UUID.init(uuidString:))
        let estimateID = UserDefaults.standard.string(forKey: "GunnAirePendingMailEstimateID").flatMap(UUID.init(uuidString:))
        let maintenanceContractID = UserDefaults.standard.string(forKey: "GunnAirePendingMailMaintenanceContractID").flatMap(UUID.init(uuidString:))
        let workflow = UserDefaults.standard.string(forKey: "GunnAirePendingMailWorkflow")
            .flatMap(GunnAireMailWorkflow.init(rawValue:)) ?? .general
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailTo")
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailSubject")
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailBody")
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailAttachmentPaths")
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailCustomerID")
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailServiceCallID")
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailInvoiceID")
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailEstimateID")
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailMaintenanceContractID")
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingMailWorkflow")
        return (to, subject, body, attachmentPaths, customerID, serviceCallID, invoiceID, estimateID, maintenanceContractID, workflow)
    }
}

private enum GunnAireIntentStore {
    static let schema = GunnAireModelSchema.schema

    static let container: ModelContainer? = try? ModelContainer(
        for: schema,
        configurations: [GunnAireCloudKit.modelConfiguration(for: schema)]
    )

    private struct AccessSnapshot {
        let email: String?
        let users: [AppUser]
        let technicians: [Technician]
        let hasAuthenticatedProvider: Bool
    }

    @MainActor
    private static func accessSnapshot() throws -> AccessSnapshot {
        guard let container else {
            return AccessSnapshot(
                email: nil,
                users: [],
                technicians: [],
                hasAuthenticatedProvider: false
            )
        }
        let context = ModelContext(container)
        let users = try context.fetch(
            FetchDescriptor<AppUser>(sortBy: [SortDescriptor(\.email, order: .forward)])
        )
        let technicians = try context.fetch(
            FetchDescriptor<Technician>(sortBy: [SortDescriptor(\.name, order: .forward)])
        )
        return AccessSnapshot(
            email: AppIdentity.currentEmail,
            users: users,
            technicians: technicians,
            hasAuthenticatedProvider: AppIdentity.hasAuthenticatedProvider
        )
    }

    @MainActor
    static func canOpen(_ route: GunnAireAppRoute) throws -> Bool {
        let access = try accessSnapshot()
        return GunnAireAppIntentAccessPolicy.canOpen(
            route,
            email: access.email,
            users: access.users,
            hasAuthenticatedProvider: access.hasAuthenticatedProvider
        )
    }

    @MainActor
    static func customers() throws -> [Customer] {
        guard let container else { return [] }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Customer>(sortBy: [SortDescriptor(\.name, order: .forward)])
        let customers = try context.fetch(descriptor)
        let access = try accessSnapshot()
        let visibleIDs = GunnAireAppIntentAccessPolicy.visibleCustomerIDs(
            email: access.email,
            users: access.users,
            customers: customers,
            hasAuthenticatedProvider: access.hasAuthenticatedProvider
        )
        return customers.filter { visibleIDs.contains($0.id) }
    }

    @MainActor
    static func serviceCalls() throws -> [ServiceCall] {
        guard let container else { return [] }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ServiceCall>(sortBy: [SortDescriptor(\.scheduledDate, order: .forward)])
        let calls = try context.fetch(descriptor)
        let access = try accessSnapshot()
        let visibleIDs = GunnAireAppIntentAccessPolicy.visibleServiceCallIDs(
            email: access.email,
            users: access.users,
            serviceCalls: calls,
            technicians: access.technicians,
            hasAuthenticatedProvider: access.hasAuthenticatedProvider
        )
        return calls.filter { visibleIDs.contains($0.id) }
    }

    @MainActor
    static func invoices() throws -> [Invoice] {
        guard let container else { return [] }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Invoice>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let invoices = try context.fetch(descriptor)
        let calls = try context.fetch(FetchDescriptor<ServiceCall>())
        let access = try accessSnapshot()
        let visibleIDs = GunnAireAppIntentAccessPolicy.visibleInvoiceIDs(
            email: access.email,
            users: access.users,
            serviceCalls: calls,
            invoices: invoices,
            technicians: access.technicians,
            hasAuthenticatedProvider: access.hasAuthenticatedProvider
        )
        return invoices.filter { visibleIDs.contains($0.id) }
    }

    @MainActor
    static func payments() throws -> [Payment] {
        guard let container else { return [] }
        let access = try accessSnapshot()
        let canReviewBilling = GunnAireAppIntentAccessPolicy.canOpen(
            .payments,
            email: access.email,
            users: access.users,
            hasAuthenticatedProvider: access.hasAuthenticatedProvider
        ) || GunnAireAppIntentAccessPolicy.canOpen(
            .invoices,
            email: access.email,
            users: access.users,
            hasAuthenticatedProvider: access.hasAuthenticatedProvider
        )
        guard canReviewBilling else { return [] }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Payment>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        return try context.fetch(descriptor)
    }

    @MainActor
    static func canOpenCustomerRecord(_ id: UUID) throws -> Bool {
        try customers().contains { $0.id == id }
    }

    @MainActor
    static func canOpenServiceCall(_ id: UUID) throws -> Bool {
        try serviceCalls().contains { $0.id == id }
    }

    @MainActor
    static func canOpenInvoice(_ id: UUID) throws -> Bool {
        try invoices().contains { $0.id == id }
    }

    @MainActor
    static func nextActionableServiceCall() throws -> ServiceCall? {
        let calls = try serviceCalls()
        let now = Date()
        return calls
            .filter { $0.status != .completed && $0.status != .cancelled }
            .sorted { lhs, rhs in
                let lhsUpcoming = lhs.scheduledDate >= now
                let rhsUpcoming = rhs.scheduledDate >= now
                if lhsUpcoming != rhsUpcoming { return lhsUpcoming }

                let lhsStarted = lhs.documentationStartedAt != nil
                let rhsStarted = rhs.documentationStartedAt != nil
                if lhsStarted != rhsStarted { return lhsStarted }

                let lhsDistance = abs(lhs.scheduledDate.timeIntervalSince(now))
                let rhsDistance = abs(rhs.scheduledDate.timeIntervalSince(now))
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return lhs.customer.name.localizedCaseInsensitiveCompare(rhs.customer.name) == .orderedAscending
            }
            .first
    }

    @MainActor
    static func nextScheduledServiceCall() throws -> ServiceCall? {
        let now = Date()
        return try serviceCalls()
            .filter { $0.status != .cancelled && $0.scheduledDate >= now }
            .sorted { lhs, rhs in
                if lhs.scheduledDate != rhs.scheduledDate { return lhs.scheduledDate < rhs.scheduledDate }
                return lhs.customer.name.localizedCaseInsensitiveCompare(rhs.customer.name) == .orderedAscending
            }
            .first
    }

    @MainActor
    static func nextCollectibleInvoice() throws -> Invoice? {
        let invoices = try invoices()
        let payments = try payments()
        return invoices
            .sorted { lhs, rhs in
                let lhsBalance = outstandingBalance(for: lhs, payments: payments)
                let rhsBalance = outstandingBalance(for: rhs, payments: payments)
                let lhsCollectible = lhsBalance > 0
                let rhsCollectible = rhsBalance > 0
                if lhsCollectible != rhsCollectible { return lhsCollectible }
                if lhsBalance != rhsBalance { return lhsBalance > rhsBalance }
                return lhs.createdAt < rhs.createdAt
            }
            .first(where: { outstandingBalance(for: $0, payments: payments) > 0 })
    }

    @MainActor
    static func nextOverdueInvoice() throws -> Invoice? {
        let now = Date()
        let invoices = try invoices()
        let payments = try payments()
        return invoices
            .filter { Invoice.isOverdue($0, payments: payments, now: now) }
            .sorted { lhs, rhs in
                let lhsBalance = outstandingBalance(for: lhs, payments: payments)
                let rhsBalance = outstandingBalance(for: rhs, payments: payments)
                let lhsDueDate = lhs.effectiveDueDate()
                let rhsDueDate = rhs.effectiveDueDate()
                if lhsDueDate != rhsDueDate { return lhsDueDate < rhsDueDate }
                return lhsBalance > rhsBalance
            }
            .first
    }

    @MainActor
    static func nextCustomerNeedingAttention() throws -> Customer? {
        if let nextJobCustomer = try nextActionableServiceCall()?.customer {
            return nextJobCustomer
        }
        if let collectionsCustomer = try nextCollectibleInvoice()?.customer {
            return collectionsCustomer
        }
        return try customers().first
    }

    nonisolated static func outstandingBalance(for invoice: Invoice, payments: [Payment]) -> Double {
        Invoice.outstandingBalance(for: invoice, payments: payments)
    }
}

struct GunnAireCustomerEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Customer")
    static let defaultQuery = GunnAireCustomerQuery()

    let id: UUID
    let name: String
    let email: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: email.flatMap { !$0.isEmpty ? "\($0)" : nil }
        )
    }
}

struct GunnAireCustomerQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [GunnAireCustomerEntity] {
        let matches = try await GunnAireIntentStore.customers().filter { identifiers.contains($0.id) }
        return matches.map { GunnAireCustomerEntity(id: $0.id, name: $0.name, email: $0.email) }
    }

    func entities(matching string: String) async throws -> [GunnAireCustomerEntity] {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = try await GunnAireIntentStore.customers().filter {
            normalized.isEmpty ||
            $0.name.localizedCaseInsensitiveContains(normalized) ||
            ($0.email?.localizedCaseInsensitiveContains(normalized) ?? false)
        }
        let ranked = matches.sorted { lhs, rhs in
            let lhsExact = lhs.name.caseInsensitiveCompare(normalized) == .orderedSame
            let rhsExact = rhs.name.caseInsensitiveCompare(normalized) == .orderedSame
            if lhsExact != rhsExact { return lhsExact }
            let lhsEmailMatch = lhs.email?.localizedCaseInsensitiveContains(normalized) == true
            let rhsEmailMatch = rhs.email?.localizedCaseInsensitiveContains(normalized) == true
            if lhsEmailMatch != rhsEmailMatch { return lhsEmailMatch }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return ranked.prefix(20).map { GunnAireCustomerEntity(id: $0.id, name: $0.name, email: $0.email) }
    }

    func suggestedEntities() async throws -> [GunnAireCustomerEntity] {
        try await GunnAireIntentStore.customers()
            .prefix(20)
            .map { GunnAireCustomerEntity(id: $0.id, name: $0.name, email: $0.email) }
    }
}

struct GunnAireServiceCallEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Service Call")
    static let defaultQuery = GunnAireServiceCallQuery()

    let id: UUID
    let customerName: String
    let scheduledDate: Date
    let jobType: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(customerName)",
            subtitle: "\(jobType.capitalized) • \(scheduledDate.formatted(date: .abbreviated, time: .shortened))"
        )
    }
}

struct GunnAireServiceCallQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [GunnAireServiceCallEntity] {
        let matches = try await GunnAireIntentStore.serviceCalls().filter { identifiers.contains($0.id) }
        return matches.map {
            GunnAireServiceCallEntity(id: $0.id, customerName: $0.customer.name, scheduledDate: $0.scheduledDate, jobType: $0.type.rawValue)
        }
    }

    func entities(matching string: String) async throws -> [GunnAireServiceCallEntity] {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = try await GunnAireIntentStore.serviceCalls().filter {
            normalized.isEmpty ||
            $0.customer.name.localizedCaseInsensitiveContains(normalized) ||
            ($0.siteAddress?.localizedCaseInsensitiveContains(normalized) ?? false) ||
            ($0.notes?.localizedCaseInsensitiveContains(normalized) ?? false)
        }
        let ranked = rankServiceCalls(matches, search: normalized)
        return ranked.prefix(20).map {
            GunnAireServiceCallEntity(id: $0.id, customerName: $0.customer.name, scheduledDate: $0.scheduledDate, jobType: $0.type.rawValue)
        }
    }

    func suggestedEntities() async throws -> [GunnAireServiceCallEntity] {
        let ranked = rankServiceCalls(try await GunnAireIntentStore.serviceCalls(), search: "")
        return ranked
            .prefix(20)
            .map { GunnAireServiceCallEntity(id: $0.id, customerName: $0.customer.name, scheduledDate: $0.scheduledDate, jobType: $0.type.rawValue) }
    }

    private func rankServiceCalls(_ calls: [ServiceCall], search: String) -> [ServiceCall] {
        let now = Date()
        return calls.sorted { lhs, rhs in
            let lhsUpcoming = lhs.scheduledDate >= now
            let rhsUpcoming = rhs.scheduledDate >= now
            if lhsUpcoming != rhsUpcoming { return lhsUpcoming }

            let lhsActionable = lhs.status != .completed && lhs.status != .cancelled
            let rhsActionable = rhs.status != .completed && rhs.status != .cancelled
            if lhsActionable != rhsActionable { return lhsActionable }

            if !search.isEmpty {
                let lhsExact = lhs.customer.name.caseInsensitiveCompare(search) == .orderedSame
                let rhsExact = rhs.customer.name.caseInsensitiveCompare(search) == .orderedSame
                if lhsExact != rhsExact { return lhsExact }
            }

            let lhsDistance = abs(lhs.scheduledDate.timeIntervalSince(now))
            let rhsDistance = abs(rhs.scheduledDate.timeIntervalSince(now))
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.customer.name.localizedCaseInsensitiveCompare(rhs.customer.name) == .orderedAscending
        }
    }
}

struct GunnAireInvoiceEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Invoice")
    static let defaultQuery = GunnAireInvoiceQuery()

    let id: UUID
    let customerName: String
    let amount: Double
    let status: String
    let createdAt: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(customerName) • \(amount.formatted(.currency(code: "USD")))",
            subtitle: "\(status.capitalized) • \(createdAt.formatted(date: .abbreviated, time: .omitted))"
        )
    }
}

struct GunnAireInvoiceQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [GunnAireInvoiceEntity] {
        let matches = try await GunnAireIntentStore.invoices().filter { identifiers.contains($0.id) }
        return matches.map {
            GunnAireInvoiceEntity(id: $0.id, customerName: $0.customer.name, amount: $0.amount, status: $0.status, createdAt: $0.createdAt)
        }
    }

    func entities(matching string: String) async throws -> [GunnAireInvoiceEntity] {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let invoices = try await GunnAireIntentStore.invoices()
        let payments = try await GunnAireIntentStore.payments()
        let matches = invoices.filter {
            normalized.isEmpty ||
            $0.customer.name.localizedCaseInsensitiveContains(normalized) ||
            $0.lineItemSummary.localizedCaseInsensitiveContains(normalized)
        }
        let ranked = rankInvoices(matches, payments: payments, search: normalized)
        return ranked.prefix(20).map {
            GunnAireInvoiceEntity(id: $0.id, customerName: $0.customer.name, amount: $0.amount, status: $0.status, createdAt: $0.createdAt)
        }
    }

    func suggestedEntities() async throws -> [GunnAireInvoiceEntity] {
        let invoices = try await GunnAireIntentStore.invoices()
        let payments = try await GunnAireIntentStore.payments()
        return rankInvoices(invoices, payments: payments, search: "")
            .prefix(20)
            .map { GunnAireInvoiceEntity(id: $0.id, customerName: $0.customer.name, amount: $0.amount, status: $0.status, createdAt: $0.createdAt) }
    }

    private func rankInvoices(_ invoices: [Invoice], payments: [Payment], search: String) -> [Invoice] {
        invoices.sorted { lhs, rhs in
            let lhsBalance = GunnAireIntentStore.outstandingBalance(for: lhs, payments: payments)
            let rhsBalance = GunnAireIntentStore.outstandingBalance(for: rhs, payments: payments)
            let lhsCollectible = lhsBalance > 0
            let rhsCollectible = rhsBalance > 0
            if lhsCollectible != rhsCollectible { return lhsCollectible }
            if lhsBalance != rhsBalance { return lhsBalance > rhsBalance }

            if !search.isEmpty {
                let lhsExact = lhs.customer.name.caseInsensitiveCompare(search) == .orderedSame
                let rhsExact = rhs.customer.name.caseInsensitiveCompare(search) == .orderedSame
                if lhsExact != rhsExact { return lhsExact }
            }

            return lhs.createdAt > rhs.createdAt
        }
    }
}

struct OpenScheduleIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Schedule"
    static let description = IntentDescription("Open GunnAire Ops to the schedule and jobs dashboard.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.schedule) else {
            return .result(dialog: "Schedule is not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.store(.schedule)
        return .result(dialog: "Opening the schedule dashboard.")
    }
}

struct OpenCommandCenterIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Command Center"
    static let description = IntentDescription("Open GunnAire Ops to the command center.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.commandCenter) else {
            return .result(dialog: "Sign in with an authorized GunnAire business account to open Command Center.")
        }
        GunnAireAppIntentRouter.store(.commandCenter)
        return .result(dialog: "Opening the command center.")
    }
}

struct OpenTimeClockIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Time Clock"
    static let description = IntentDescription("Open GunnAire Ops to the time clock.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.timeClock) else {
            return .result(dialog: "Time Clock is not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.store(.timeClock)
        return .result(dialog: "Opening the time clock.")
    }
}

struct OpenCustomersIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Customers"
    static let description = IntentDescription("Open GunnAire Ops to customers.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.customers) else {
            return .result(dialog: "Customer records are not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.store(.customers)
        return .result(dialog: "Opening customers.")
    }
}

struct OpenMailIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Mail"
    static let description = IntentDescription("Open GunnAire Ops to mail.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.mail) else {
            return .result(dialog: "Mail is not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.store(.mail)
        return .result(dialog: "Opening mail.")
    }
}

struct OpenInvoicesEstimatesIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Invoices and Estimates"
    static let description = IntentDescription("Open GunnAire Ops to invoices and estimates.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.invoicesEstimates) else {
            return .result(dialog: "Invoices are not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.store(.invoicesEstimates)
        return .result(dialog: "Opening invoices and estimates.")
    }
}

struct OpenEstimatesIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Estimates"
    static let description = IntentDescription("Open GunnAire Ops to the estimates workspace.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.estimates) else {
            return .result(dialog: "Estimates are not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.store(.estimates)
        return .result(dialog: "Opening estimates.")
    }
}

struct OpenInvoicesIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Invoices"
    static let description = IntentDescription("Open GunnAire Ops to the invoices workspace.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.invoices) else {
            return .result(dialog: "Invoices are not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.store(.invoices)
        return .result(dialog: "Opening invoices.")
    }
}

struct OpenPaymentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Payments"
    static let description = IntentDescription("Open GunnAire Ops to the payments workspace.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.payments) else {
            return .result(dialog: "Payments are not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.store(.payments)
        return .result(dialog: "Opening payments.")
    }
}

struct OpenBusinessReportsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Business Reports"
    static let description = IntentDescription("Open GunnAire Ops to business reports.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.reports) else {
            return .result(dialog: "Business Reports are not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.store(.reports)
        return .result(dialog: "Opening business reports.")
    }
}

struct OpenReceiptsBillsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Receipts and Bills"
    static let description = IntentDescription("Open GunnAire Ops to receipts and bills.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.receiptsBills) else {
            return .result(dialog: "Receipts and Bills are not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.store(.receiptsBills)
        return .result(dialog: "Opening receipts and bills.")
    }
}

struct OpenDocumentationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Documentation"
    static let description = IntentDescription("Open GunnAire Ops to onsite documentation.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.documentation) else {
            return .result(dialog: "Documentation is not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.store(.documentation)
        return .result(dialog: "Opening documentation.")
    }
}

struct OpenSyncIntegrationsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Sync Integrations"
    static let description = IntentDescription("Open GunnAire Ops to sync and integrations.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.sync) else {
            return .result(dialog: "Sync and Integrations is not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.store(.sync)
        return .result(dialog: "Opening sync and integrations.")
    }
}

struct OpenQuickBooksManagementIntent: AppIntent {
    static let title: LocalizedStringResource = "Open QuickBooks Management"
    static let description = IntentDescription("Open GunnAire Ops to QuickBooks management.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.quickBooks) else {
            return .result(dialog: "QuickBooks Management is not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.store(.quickBooks)
        return .result(dialog: "Opening QuickBooks management.")
    }
}

struct OpenCustomerRecordIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Customer Record"
    static let description = IntentDescription("Open GunnAire Ops to a specific customer.")
    static let openAppWhenRun = true
    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$customer)")
    }

    @Parameter(title: "Customer")
    var customer: GunnAireCustomerEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpenCustomerRecord(customer.id) else {
            return .result(dialog: "That customer record is not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.storeCustomerRoute(customer.id)
        return .result(dialog: "Opening \(customer.name).")
    }
}

struct OpenJobDocumentationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Job Documentation"
    static let description = IntentDescription("Open GunnAire Ops to documentation for a specific job.")
    static let openAppWhenRun = true
    static var parameterSummary: some ParameterSummary {
        Summary("Open documentation for \(\.$serviceCall)")
    }

    @Parameter(title: "Service Call")
    var serviceCall: GunnAireServiceCallEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpenServiceCall(serviceCall.id) else {
            return .result(dialog: "That job is not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.storeDocumentationRoute(serviceCall.id)
        return .result(dialog: "Opening documentation for \(serviceCall.customerName).")
    }
}

struct OpenScheduleJobIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Schedule Job"
    static let description = IntentDescription("Open GunnAire Ops to a specific job in the schedule.")
    static let openAppWhenRun = true
    static var parameterSummary: some ParameterSummary {
        Summary("Open schedule job \(\.$serviceCall)")
    }

    @Parameter(title: "Service Call")
    var serviceCall: GunnAireServiceCallEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpenServiceCall(serviceCall.id) else {
            return .result(dialog: "That job is not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.storeScheduleCallRoute(serviceCall.id)
        return .result(dialog: "Opening the schedule for \(serviceCall.customerName).")
    }
}

struct OpenNextScheduledJobIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Next Scheduled Job"
    static let description = IntentDescription("Open GunnAire Ops to the next scheduled job in the schedule.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.schedule) else {
            return .result(dialog: "Schedule is not available to the signed-in business account.")
        }
        guard let call = try await GunnAireIntentStore.nextScheduledServiceCall() else {
            return .result(dialog: "There are no upcoming scheduled jobs right now.")
        }
        GunnAireAppIntentRouter.storeScheduleCallRoute(call.id)
        return .result(dialog: "Opening the next scheduled job for \(call.customer.name).")
    }
}

struct CollectInvoicePaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Collect Invoice Payment"
    static let description = IntentDescription("Open GunnAire Ops to collect payment for a specific invoice.")
    static let openAppWhenRun = true
    static var parameterSummary: some ParameterSummary {
        Summary("Collect payment for \(\.$invoice)")
    }

    @Parameter(title: "Invoice")
    var invoice: GunnAireInvoiceEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpenInvoice(invoice.id) else {
            return .result(dialog: "That invoice is not available to the signed-in business account.")
        }
        GunnAireAppIntentRouter.storePaymentCollectionRoute(invoice.id)
        return .result(dialog: "Opening payment collection for \(invoice.customerName).")
    }
}

struct OpenNextJobDocumentationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Next Job Documentation"
    static let description = IntentDescription("Open GunnAire Ops to the next actionable job documentation flow.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.documentation) else {
            return .result(dialog: "Documentation is not available to the signed-in business account.")
        }
        guard let call = try await GunnAireIntentStore.nextActionableServiceCall() else {
            return .result(dialog: "There are no actionable jobs right now.")
        }
        GunnAireAppIntentRouter.storeDocumentationRoute(call.id)
        return .result(dialog: "Opening documentation for \(call.customer.name).")
    }
}

struct CollectNextOutstandingInvoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Collect Next Outstanding Invoice"
    static let description = IntentDescription("Open GunnAire Ops to collect the next outstanding invoice balance.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.payments) else {
            return .result(dialog: "Payments are not available to the signed-in business account.")
        }
        guard let invoice = try await GunnAireIntentStore.nextCollectibleInvoice() else {
            return .result(dialog: "There are no collectible invoices right now.")
        }
        GunnAireAppIntentRouter.storePaymentCollectionRoute(invoice.id)
        return .result(dialog: "Opening payment collection for \(invoice.customer.name).")
    }
}

struct CollectNextOverdueInvoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Collect Next Overdue Invoice"
    static let description = IntentDescription("Open GunnAire Ops to collect the next overdue invoice balance.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.payments) else {
            return .result(dialog: "Payments are not available to the signed-in business account.")
        }
        guard let invoice = try await GunnAireIntentStore.nextOverdueInvoice() else {
            return .result(dialog: "There are no overdue invoices right now.")
        }
        GunnAireAppIntentRouter.storePaymentCollectionRoute(invoice.id)
        return .result(dialog: "Opening overdue collection for \(invoice.customer.name).")
    }
}

struct OpenNextCustomerRecordIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Next Customer Record"
    static let description = IntentDescription("Open GunnAire Ops to the next customer needing attention.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await GunnAireIntentStore.canOpen(.customers) else {
            return .result(dialog: "Customer records are not available to the signed-in business account.")
        }
        guard let customer = try await GunnAireIntentStore.nextCustomerNeedingAttention() else {
            return .result(dialog: "There are no customers available right now.")
        }
        GunnAireAppIntentRouter.storeCustomerRoute(customer.id)
        return .result(dialog: "Opening \(customer.name).")
    }
}

struct GunnAireAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        return [
            AppShortcut(
                intent: OpenTimeClockIntent(),
                phrases: ["Open time clock in \(.applicationName)", "Clock in with \(.applicationName)"],
                shortTitle: "Time Clock",
                systemImageName: "clock"
            ),
            AppShortcut(
                intent: OpenScheduleIntent(),
                phrases: ["Open schedule in \(.applicationName)", "Open jobs in \(.applicationName)"],
                shortTitle: "Schedule",
                systemImageName: "calendar"
            ),
            AppShortcut(
                intent: OpenCustomerRecordIntent(),
                phrases: ["Open customer in \(.applicationName)"],
                shortTitle: "Customer Record",
                systemImageName: "person.crop.circle"
            ),
            AppShortcut(
                intent: OpenEstimatesIntent(),
                phrases: ["Open estimates in \(.applicationName)"],
                shortTitle: "Estimates",
                systemImageName: "doc.text.magnifyingglass"
            ),
            AppShortcut(
                intent: OpenInvoicesIntent(),
                phrases: ["Open invoices in \(.applicationName)"],
                shortTitle: "Invoices",
                systemImageName: "doc.text"
            ),
            AppShortcut(
                intent: CollectInvoicePaymentIntent(),
                phrases: ["Collect invoice payment in \(.applicationName)"],
                shortTitle: "Collect Payment",
                systemImageName: "dollarsign.circle"
            ),
            AppShortcut(
                intent: OpenReceiptsBillsIntent(),
                phrases: ["Open receipts in \(.applicationName)", "Open bills in \(.applicationName)"],
                shortTitle: "Receipts",
                systemImageName: "tray.and.arrow.up"
            ),
            AppShortcut(
                intent: OpenJobDocumentationIntent(),
                phrases: ["Open job documentation in \(.applicationName)"],
                shortTitle: "Job Docs",
                systemImageName: "doc.text.magnifyingglass"
            ),
            AppShortcut(
                intent: OpenSyncIntegrationsIntent(),
                phrases: ["Open sync integrations in \(.applicationName)"],
                shortTitle: "Sync",
                systemImageName: "arrow.triangle.2.circlepath"
            ),
            AppShortcut(
                intent: OpenQuickBooksManagementIntent(),
                phrases: ["Open QuickBooks management in \(.applicationName)"],
                shortTitle: "QuickBooks",
                systemImageName: "banknote"
            )
        ]
    }
}
