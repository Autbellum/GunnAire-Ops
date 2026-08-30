import Foundation

// Sidebar menu items for the main NavigationSplitView
enum SidebarItem: String, CaseIterable, Identifiable {
    case commandCenter = "Command Center"
    case timeClock = "Clock In/Out"
    case scheduleAndJobs = "Schedule & Jobs"
    case customers = "Customers"
    case mail = "Mail"
    case estimates = "Estimates"
    case invoices = "Invoices"
    case payments = "Payments"
    case reports = "Reports"
    case receiptsBills = "Receipts & Bills"
    case quickBooksManagement = "QuickBooks Management"
    case syncIntegrations = "Sync & Integrations"
    case onsiteDocumentation = "Onsite Documentation"
    
    var id: String { rawValue }
}

/// Keeps the split-view detail anchored to a workspace the current business
/// role can still open. Role records can change through CloudKit while the app
/// is active, so selection recovery cannot be limited to initial appearance.
enum SidebarNavigationPolicy {
    static func resolvedSelection(
        _ currentSelection: SidebarItem?,
        visibleItems: [SidebarItem]
    ) -> SidebarItem? {
        guard !visibleItems.isEmpty else { return nil }
        if let currentSelection, visibleItems.contains(currentSelection) {
            return currentSelection
        }
        if visibleItems.contains(.commandCenter) {
            return .commandCenter
        }
        return visibleItems.first
    }
}
