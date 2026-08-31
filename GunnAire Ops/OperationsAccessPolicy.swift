import Foundation

/// One role-derived capability set drives Command Center visibility, Find
/// categories, quick actions, and handoffs. Keeping these decisions together
/// prevents a read-only workspace from accidentally inheriting a mutation or
/// a company-wide query simply because the Command Center itself is visible.
struct OperationsAccessCapabilities: Equatable {
    let canSearchCustomers: Bool
    let canSearchJobs: Bool
    let canSearchEstimates: Bool
    let canSearchInvoices: Bool
    let canShowRecentPayments: Bool
    let canOpenSchedule: Bool
    let canOpenDocumentation: Bool
    let canOpenInvoices: Bool
    let canOpenPayments: Bool
    let canOpenReports: Bool
    let canOpenSync: Bool
    let canManageQuickBooks: Bool
    let canManageDispatch: Bool
    let canCollectPayments: Bool
    let canViewFinancials: Bool
    let canShowBusinessOverview: Bool

    static let denied = OperationsAccessCapabilities(
        canSearchCustomers: false,
        canSearchJobs: false,
        canSearchEstimates: false,
        canSearchInvoices: false,
        canShowRecentPayments: false,
        canOpenSchedule: false,
        canOpenDocumentation: false,
        canOpenInvoices: false,
        canOpenPayments: false,
        canOpenReports: false,
        canOpenSync: false,
        canManageQuickBooks: false,
        canManageDispatch: false,
        canCollectPayments: false,
        canViewFinancials: false,
        canShowBusinessOverview: false
    )

    var findPrompt: String {
        var categories: [String] = []
        if canSearchCustomers { categories.append("customer") }
        if canSearchJobs { categories.append("job") }
        if canSearchInvoices { categories.append("invoice") }
        if canSearchEstimates { categories.append("estimate") }
        if canSearchCustomers || canSearchJobs { categories.append("address") }
        return categories.isEmpty ? "Find authorized work" : categories.map(\.capitalized).joined(separator: ", ")
    }
}

enum OperationsAccessPolicy {
    static func capabilities(
        email: String?,
        users: [AppUser]
    ) -> OperationsAccessCapabilities {
        guard AppAccess.activeRole(email: email, users: users) != nil else {
            return .denied
        }

        let canOpenSchedule = AppAccess.canAccessSidebarItem(.scheduleAndJobs, email: email, users: users)
        let canOpenDocumentation = AppAccess.canAccessSidebarItem(.onsiteDocumentation, email: email, users: users)
        let canOpenInvoices = AppAccess.canAccessSidebarItem(.invoices, email: email, users: users)
        let canOpenPayments = AppAccess.canAccessSidebarItem(.payments, email: email, users: users)
        let canViewFinancials = AppAccess.canViewFinancialManagement(email: email, users: users)

        return OperationsAccessCapabilities(
            canSearchCustomers: AppAccess.canAccessSidebarItem(.customers, email: email, users: users),
            canSearchJobs: canOpenSchedule || canOpenDocumentation,
            canSearchEstimates: AppAccess.canAccessSidebarItem(.estimates, email: email, users: users),
            canSearchInvoices: canOpenInvoices || canOpenPayments,
            canShowRecentPayments: canViewFinancials && canOpenPayments,
            canOpenSchedule: canOpenSchedule,
            canOpenDocumentation: canOpenDocumentation,
            canOpenInvoices: canOpenInvoices,
            canOpenPayments: canOpenPayments,
            canOpenReports: AppAccess.canAccessSidebarItem(.reports, email: email, users: users),
            canOpenSync: AppAccess.canAccessSidebarItem(.syncIntegrations, email: email, users: users),
            canManageQuickBooks: AppAccess.canAccessSidebarItem(.quickBooksManagement, email: email, users: users),
            canManageDispatch: AppAccess.canManageDispatch(email: email, users: users),
            canCollectPayments: AppAccess.canCollectFieldPayments(email: email, users: users) && canOpenPayments,
            canViewFinancials: canViewFinancials,
            canShowBusinessOverview: AppAccess.isAdmin(email: email, users: users)
        )
    }

    static func visibleServiceCallIDs(
        email: String?,
        users: [AppUser],
        serviceCalls: [ServiceCall],
        technicians: [Technician]
    ) -> Set<UUID> {
        let access = capabilities(email: email, users: users)
        guard access.canSearchJobs else { return [] }
        let hydratedIDs = Set(serviceCalls.compactMap { $0.customer == nil ? nil : $0.id })
        return AppAccess.visibleServiceCallIDs(
            email: email,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        ).intersection(hydratedIDs)
    }

    static func visibleInvoiceIDs(
        email: String?,
        users: [AppUser],
        serviceCalls: [ServiceCall],
        invoices: [Invoice],
        technicians: [Technician]
    ) -> Set<UUID> {
        let access = capabilities(email: email, users: users)
        guard access.canSearchInvoices else { return [] }
        let hydratedIDs = Set(invoices.compactMap { $0.customer == nil ? nil : $0.id })
        return AppAccess.visibleFieldPaymentInvoiceIDs(
            email: email,
            users: users,
            serviceCalls: serviceCalls,
            invoices: invoices,
            technicians: technicians
        ).intersection(hydratedIDs)
    }

    static func visibleEstimateIDs(
        email: String?,
        users: [AppUser],
        estimates: [Estimate]
    ) -> Set<UUID> {
        guard capabilities(email: email, users: users).canSearchEstimates else { return [] }
        return Set(estimates.compactMap { $0.customer == nil ? nil : $0.id })
    }

    static func visiblePaymentIDs(
        email: String?,
        users: [AppUser],
        serviceCalls: [ServiceCall],
        invoices: [Invoice],
        payments: [Payment],
        technicians: [Technician]
    ) -> Set<UUID> {
        let access = capabilities(email: email, users: users)
        guard access.canOpenPayments else { return [] }
        let invoiceIDs = visibleInvoiceIDs(
            email: email,
            users: users,
            serviceCalls: serviceCalls,
            invoices: invoices,
            technicians: technicians
        )
        return Set(payments.compactMap { payment -> UUID? in
            guard let invoice = payment.invoice,
                  invoice.customer != nil,
                  invoiceIDs.contains(invoice.id) else { return nil }
            return payment.id
        })
    }

    static func searchableCustomerIDs(
        email: String?,
        users: [AppUser],
        customers: [Customer]
    ) -> Set<UUID> {
        guard capabilities(email: email, users: users).canSearchCustomers else { return [] }
        return Set(customers.map(\.id))
    }

    /// Field accounts have no customer-directory capability. They still need
    /// the customer attached to an assigned job or collectible invoice so the
    /// authorized job cards, agreement state, and balances remain coherent.
    static func dashboardCustomerIDs(
        email: String?,
        users: [AppUser],
        customers: [Customer],
        serviceCalls: [ServiceCall],
        invoices: [Invoice],
        technicians: [Technician]
    ) -> Set<UUID> {
        let searchableIDs = searchableCustomerIDs(email: email, users: users, customers: customers)
        if !searchableIDs.isEmpty || capabilities(email: email, users: users).canSearchCustomers {
            return searchableIDs
        }

        let callIDs = visibleServiceCallIDs(
            email: email,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
        let invoiceIDs = visibleInvoiceIDs(
            email: email,
            users: users,
            serviceCalls: serviceCalls,
            invoices: invoices,
            technicians: technicians
        )
        var customerIDs = Set(serviceCalls.compactMap { call -> UUID? in
            guard callIDs.contains(call.id), let customer = call.customer else { return nil }
            return customer.id
        })
        customerIDs.formUnion(invoices.compactMap { invoice -> UUID? in
            guard invoiceIDs.contains(invoice.id), let customer = invoice.customer else { return nil }
            return customer.id
        })
        return customerIDs
    }

    static func visibleContractIDs(
        customerIDs: Set<UUID>,
        contracts: [RecurringMaintenanceContract]
    ) -> Set<UUID> {
        Set(contracts.compactMap { contract -> UUID? in
            guard let customer = contract.customer,
                  customerIDs.contains(customer.id) else { return nil }
            return contract.id
        })
    }

    static func visibleCommunicationIDs(
        customerIDs: Set<UUID>,
        communications: [CustomerCommunication]
    ) -> Set<UUID> {
        Set(communications.compactMap { communication -> UUID? in
            guard let customer = communication.customer,
                  customerIDs.contains(customer.id) else { return nil }
            return communication.id
        })
    }

    static func visibleTechnicianIDs(
        email: String?,
        users: [AppUser],
        technicians: [Technician]
    ) -> Set<UUID> {
        guard let role = AppAccess.activeRole(email: email, users: users) else { return [] }
        if role == .fieldTechnician {
            return AppAccess.ownPerformanceTechnicianID(
                email: email,
                users: users,
                technicians: technicians
            ).map { Set([$0]) } ?? []
        }
        return Set(technicians.map(\.id))
    }
}
