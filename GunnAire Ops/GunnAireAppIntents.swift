import AppIntents
import Foundation

enum GunnAireAppRoute: String, CaseIterable {
    case schedule = "scheduleAndJobs"
    case payments = "payments"
    case documentation = "onsiteDocumentation"
    case sync = "syncIntegrations"
    case quickBooks = "quickBooksManagement"

    var sidebarItem: SidebarItem {
        switch self {
        case .schedule:
            return .scheduleAndJobs
        case .payments:
            return .payments
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
        case .schedule:
            return "Schedule"
        case .payments:
            return "Payments"
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
        case .schedule:
            return "calendar"
        case .payments:
            return "creditcard"
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

struct OpenPaymentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Payments"
    static let description = IntentDescription("Open GunnAire Ops to the payments workspace.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        GunnAireAppIntentRouter.store(.payments)
        return .result(dialog: "Opening payments.")
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
                intent: OpenScheduleIntent(),
                phrases: ["Open schedule in \(.applicationName)"],
                shortTitle: "Schedule",
                systemImageName: "calendar"
            ),
            AppShortcut(
                intent: OpenPaymentsIntent(),
                phrases: ["Open payments in \(.applicationName)"],
                shortTitle: "Payments",
                systemImageName: "creditcard"
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
