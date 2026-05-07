import AppIntents
import Foundation

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
                intent: OpenCustomersIntent(),
                phrases: ["Open customers in \(.applicationName)"],
                shortTitle: "Customers",
                systemImageName: "person.3"
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
                intent: OpenPaymentsIntent(),
                phrases: ["Open payments in \(.applicationName)"],
                shortTitle: "Payments",
                systemImageName: "creditcard"
            ),
            AppShortcut(
                intent: OpenReceiptsBillsIntent(),
                phrases: ["Open receipts in \(.applicationName)", "Open bills in \(.applicationName)"],
                shortTitle: "Receipts",
                systemImageName: "tray.and.arrow.up"
            ),
            AppShortcut(
                intent: OpenDocumentationIntent(),
                phrases: ["Open documentation in \(.applicationName)"],
                shortTitle: "Documentation",
                systemImageName: "book"
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
