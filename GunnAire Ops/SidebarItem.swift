import Foundation

// Sidebar menu items for the main NavigationSplitView
enum SidebarItem: String, CaseIterable, Identifiable {
    case scheduleAndJobs = "Schedule & Jobs"
    case googleCalendar = "Google Calendar"
    case customers = "Customers"
    case invoicesEstimates = "Invoices & Estimates"
    case paymentsReceipts = "Payments & Receipts"
    case receiptsBills = "Receipts & Bills"
    case quickBooksManagement = "QuickBooks Management"
    case syncIntegrations = "Sync & Integrations"
    case onsiteDocumentation = "Onsite Documentation"
    
    var id: String { rawValue }
}
