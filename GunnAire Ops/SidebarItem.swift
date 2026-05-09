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
    case receiptsBills = "Receipts & Bills"
    case quickBooksManagement = "QuickBooks Management"
    case syncIntegrations = "Sync & Integrations"
    case onsiteDocumentation = "Onsite Documentation"
    
    var id: String { rawValue }
}
