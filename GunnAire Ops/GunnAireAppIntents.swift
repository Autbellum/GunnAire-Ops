import AppIntents
import Foundation
import SwiftData

enum GunnAireAppRoute: String, CaseIterable {
    case timeClock = "timeClock"
    case schedule = "scheduleAndJobs"
    case customers = "customers"
    case mail = "mail"
    case invoicesEstimates = "invoicesEstimates"
    case payments = "payments"
    case receiptsBills = "receiptsBills"
    case documentation = "onsiteDocumentation"
    case sync = "syncIntegrations"
    case quickBooks = "quickBooksManagement"

    var sidebarItem: SidebarItem {
        switch self {
        case .timeClock:
            return .timeClock
        case .schedule:
            return .scheduleAndJobs
        case .customers:
            return .customers
        case .mail:
            return .mail
        case .invoicesEstimates:
            return .invoicesEstimates
        case .payments:
            return .payments
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
        case .timeClock:
            return "Clock In/Out"
        case .schedule:
            return "Schedule"
        case .customers:
            return "Customers"
        case .mail:
            return "Mail"
        case .invoicesEstimates:
            return "Invoices"
        case .payments:
            return "Payments"
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
        case .timeClock:
            return "clock"
        case .schedule:
            return "calendar"
        case .customers:
            return "person.3"
        case .mail:
            return "envelope"
        case .invoicesEstimates:
            return "doc.text"
        case .payments:
            return "creditcard"
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

enum GunnAireAppIntentRouter {
    nonisolated static func store(_ route: GunnAireAppRoute) {
        UserDefaults.standard.set(route.rawValue, forKey: "GunnAirePendingAppRoute")
    }

    nonisolated static func consumePendingRoute() -> GunnAireAppRoute? {
        guard let rawValue = UserDefaults.standard.string(forKey: "GunnAirePendingAppRoute"),
              let route = GunnAireAppRoute(rawValue: rawValue) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingAppRoute")
        return route
    }

    nonisolated static func storeCustomerRoute(_ id: UUID) {
        store(.customers)
        UserDefaults.standard.set(id.uuidString, forKey: "GunnAirePendingCustomerID")
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
        store(.documentation)
        UserDefaults.standard.set(id.uuidString, forKey: "GunnAirePendingServiceCallID")
    }

    nonisolated static func consumePendingServiceCallID() -> UUID? {
        guard let rawValue = UserDefaults.standard.string(forKey: "GunnAirePendingServiceCallID"),
              let id = UUID(uuidString: rawValue) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingServiceCallID")
        return id
    }

    nonisolated static func storePaymentCollectionRoute(_ id: UUID) {
        store(.payments)
        UserDefaults.standard.set(id.uuidString, forKey: "GunnAirePendingInvoiceID")
        UserDefaults.standard.set(true, forKey: "GunnAirePendingOpenPaymentCollection")
    }

    nonisolated static func consumePendingInvoiceCollectionID() -> UUID? {
        guard UserDefaults.standard.bool(forKey: "GunnAirePendingOpenPaymentCollection"),
              let rawValue = UserDefaults.standard.string(forKey: "GunnAirePendingInvoiceID"),
              let id = UUID(uuidString: rawValue) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingInvoiceID")
        UserDefaults.standard.removeObject(forKey: "GunnAirePendingOpenPaymentCollection")
        return id
    }
}

private enum GunnAireIntentStore {
    static let schema = Schema([
        Item.self,
        ServiceCall.self,
        Customer.self,
        Technician.self,
        RecurringMaintenanceContract.self,
        Invoice.self,
        Estimate.self,
        Payment.self,
        TimeEntry.self,
        AppUser.self,
    ])

    static let container: ModelContainer? = try? ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)]
    )

    @MainActor
    static func customers() throws -> [Customer] {
        guard let container else { return [] }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Customer>(sortBy: [SortDescriptor(\.name, order: .forward)])
        return try context.fetch(descriptor)
    }

    @MainActor
    static func serviceCalls() throws -> [ServiceCall] {
        guard let container else { return [] }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ServiceCall>(sortBy: [SortDescriptor(\.scheduledDate, order: .forward)])
        return try context.fetch(descriptor)
    }

    @MainActor
    static func invoices() throws -> [Invoice] {
        guard let container else { return [] }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Invoice>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try context.fetch(descriptor)
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
        return matches.prefix(20).map { GunnAireCustomerEntity(id: $0.id, name: $0.name, email: $0.email) }
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
        return matches.prefix(20).map {
            GunnAireServiceCallEntity(id: $0.id, customerName: $0.customer.name, scheduledDate: $0.scheduledDate, jobType: $0.type.rawValue)
        }
    }

    func suggestedEntities() async throws -> [GunnAireServiceCallEntity] {
        try await GunnAireIntentStore.serviceCalls()
            .prefix(20)
            .map { GunnAireServiceCallEntity(id: $0.id, customerName: $0.customer.name, scheduledDate: $0.scheduledDate, jobType: $0.type.rawValue) }
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
        let matches = try await GunnAireIntentStore.invoices().filter {
            normalized.isEmpty ||
            $0.customer.name.localizedCaseInsensitiveContains(normalized) ||
            $0.lineItemSummary.localizedCaseInsensitiveContains(normalized)
        }
        return matches.prefix(20).map {
            GunnAireInvoiceEntity(id: $0.id, customerName: $0.customer.name, amount: $0.amount, status: $0.status, createdAt: $0.createdAt)
        }
    }

    func suggestedEntities() async throws -> [GunnAireInvoiceEntity] {
        try await GunnAireIntentStore.invoices()
            .prefix(20)
            .map { GunnAireInvoiceEntity(id: $0.id, customerName: $0.customer.name, amount: $0.amount, status: $0.status, createdAt: $0.createdAt) }
    }
}

struct OpenScheduleIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Schedule"
    static let description = IntentDescription("Open GunnAire Ops to the schedule and jobs dashboard.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        GunnAireAppIntentRouter.store(.schedule)
        return .result(dialog: "Opening the schedule dashboard.")
    }
}

struct OpenTimeClockIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Time Clock"
    static let description = IntentDescription("Open GunnAire Ops to the time clock.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        GunnAireAppIntentRouter.store(.timeClock)
        return .result(dialog: "Opening the time clock.")
    }
}

struct OpenCustomersIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Customers"
    static let description = IntentDescription("Open GunnAire Ops to customers.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        GunnAireAppIntentRouter.store(.customers)
        return .result(dialog: "Opening customers.")
    }
}

struct OpenMailIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Mail"
    static let description = IntentDescription("Open GunnAire Ops to mail.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        GunnAireAppIntentRouter.store(.mail)
        return .result(dialog: "Opening mail.")
    }
}

struct OpenInvoicesEstimatesIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Invoices and Estimates"
    static let description = IntentDescription("Open GunnAire Ops to invoices and estimates.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        GunnAireAppIntentRouter.store(.invoicesEstimates)
        return .result(dialog: "Opening invoices and estimates.")
    }
}

struct OpenPaymentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Payments"
    static let description = IntentDescription("Open GunnAire Ops to the payments workspace.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        GunnAireAppIntentRouter.store(.payments)
        return .result(dialog: "Opening payments.")
    }
}

struct OpenReceiptsBillsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Receipts and Bills"
    static let description = IntentDescription("Open GunnAire Ops to receipts and bills.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        GunnAireAppIntentRouter.store(.receiptsBills)
        return .result(dialog: "Opening receipts and bills.")
    }
}

struct OpenDocumentationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Documentation"
    static let description = IntentDescription("Open GunnAire Ops to onsite documentation.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        GunnAireAppIntentRouter.store(.documentation)
        return .result(dialog: "Opening documentation.")
    }
}

struct OpenSyncIntegrationsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Sync Integrations"
    static let description = IntentDescription("Open GunnAire Ops to sync and integrations.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        GunnAireAppIntentRouter.store(.sync)
        return .result(dialog: "Opening sync and integrations.")
    }
}

struct OpenQuickBooksManagementIntent: AppIntent {
    static let title: LocalizedStringResource = "Open QuickBooks Management"
    static let description = IntentDescription("Open GunnAire Ops to QuickBooks management.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
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
        GunnAireAppIntentRouter.storeDocumentationRoute(serviceCall.id)
        return .result(dialog: "Opening documentation for \(serviceCall.customerName).")
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
        GunnAireAppIntentRouter.storePaymentCollectionRoute(invoice.id)
        return .result(dialog: "Opening payment collection for \(invoice.customerName).")
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
                intent: OpenMailIntent(),
                phrases: ["Open mail in \(.applicationName)"],
                shortTitle: "Mail",
                systemImageName: "envelope"
            ),
            AppShortcut(
                intent: OpenInvoicesEstimatesIntent(),
                phrases: ["Open invoices in \(.applicationName)", "Open estimates in \(.applicationName)"],
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
