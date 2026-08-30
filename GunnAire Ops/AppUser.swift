import Foundation
import SwiftData

enum AppUserRole: String, Codable, CaseIterable, Identifiable {
    case standard = "Standard"
    case fieldTechnician = "Field Technician"
    case dispatcher = "Dispatcher"
    case accounting = "Accounting"
    case admin = "Admin"

    var id: String { rawValue }
}

@Model
final class AppUser {
    var id: UUID = UUID()
    var email: String = ""
    var roleRawValue: String = AppUserRole.standard.rawValue
    var isActive: Bool = true
    var createdAt: Date = Date()

    init(id: UUID = UUID(), email: String, role: AppUserRole = .standard, isActive: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.email = email.lowercased()
        self.roleRawValue = role.rawValue
        self.isActive = isActive
        self.createdAt = createdAt
    }

    var role: AppUserRole {
        get { AppUserRole(rawValue: roleRawValue) ?? .standard }
        set { roleRawValue = newValue.rawValue }
    }
}

enum AppAccess {
    static let primaryAdminEmail = "eric.gunn@gunnaire.com"

    static func normalizedEmail(_ email: String?) -> String {
        email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    static func inferredDisplayName(fromEmail email: String) -> String {
        normalizedEmail(email)
            .components(separatedBy: "@")
            .first?
            .replacingOccurrences(of: ".", with: " ")
            .capitalized ?? email
    }

    static func isPrimaryAdmin(_ email: String?) -> Bool {
        normalizedEmail(email) == primaryAdminEmail
    }

    static func isAdmin(email: String?, users: [AppUser]) -> Bool {
        activeRole(email: email, users: users) == .admin
    }

    static func activeRole(email: String?, users: [AppUser]) -> AppUserRole? {
        let email = normalizedEmail(email)
        if email == primaryAdminEmail {
            return .admin
        }
        let matchingUsers = users.filter { $0.email == email }
        guard !matchingUsers.isEmpty,
              matchingUsers.allSatisfy(\.isActive) else {
            return nil
        }
        let roles = Set(matchingUsers.map(\.role))
        // CloudKit does not enforce uniqueness constraints. Until the approved
        // backend refreshes a conflict, fail closed instead of selecting an
        // arbitrary record that could grant dispatch or financial access.
        return roles.count == 1 ? roles.first : .standard
    }

    static func isAuthorized(email: String?, users: [AppUser]) -> Bool {
        activeRole(email: email, users: users) != nil
    }

    static func canAccessSidebarItem(_ item: SidebarItem, email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        switch item {
        case .commandCenter:
            return true
        case .customers:
            return role != .fieldTechnician
        case .timeClock:
            return true
        case .scheduleAndJobs, .onsiteDocumentation:
            return role != .accounting
        case .mail, .estimates:
            return role == .dispatcher || role == .admin
        case .invoices, .payments, .receiptsBills:
            return role == .fieldTechnician || role == .accounting || role == .admin
        case .reports:
            return role == .accounting || role == .admin
        case .syncIntegrations, .quickBooksManagement:
            return role == .admin
        }
    }

    static func canViewFinancialManagement(email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        return role == .admin || role == .accounting
    }

    /// Team time approval is an office control between field capture and QBO.
    /// Accounting may review time without receiving dispatch or QBO-admin
    /// privileges; administrators retain the same authority across the suite.
    static func canReviewTeamTime(email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        return role == .accounting || role == .admin
    }

    /// Field scorecards expose only the signed-in technician's own operational
    /// results. Office-wide financial reporting remains Accounting/Admin-only.
    static func ownPerformanceTechnicianID(
        email: String?,
        users: [AppUser],
        technicians: [Technician]
    ) -> UUID? {
        guard activeRole(email: email, users: users) == .fieldTechnician else { return nil }
        let normalized = normalizedEmail(email)
        let matches = technicians.filter {
            normalizedEmail($0.contactInfo) == normalized
        }
        // Duplicate technician identities are an authorization ambiguity, not
        // a reason to merge another person's results into this account.
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }

    static func canViewBillingFinancialDetails(email: String?, users: [AppUser]) -> Bool {
        canViewFinancialManagement(email: email, users: users)
    }

    static func canCollectFieldPayments(email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        return role == .fieldTechnician || role == .admin
    }

    /// Physical stock use is a field custody mutation. Assigned technicians and
    /// administrators may record it; office review roles keep the ledger read-only.
    static func canRecordJobMaterials(email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        return role == .fieldTechnician || role == .admin
    }

    /// A field user may report a shortage from an assigned job, but only an
    /// administrator can approve, place, or receive the resulting supplier order.
    static func canRequestJobMaterialReplenishment(email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        return role == .fieldTechnician || role == .admin
    }

    /// Field staff may create a job-specific line when the pricebook is
    /// incomplete. Only an administrator can promote that draft into the
    /// reusable company catalog and publish it to QuickBooks.
    static func canApprovePricebookItems(email: String?, users: [AppUser]) -> Bool {
        activeRole(email: email, users: users) == .admin
    }

    /// A job-specific price may change customer revenue without changing the
    /// shared catalog. Keep that exception Admin-only and preserve its evidence
    /// on the estimate or invoice line snapshot.
    static func canAuthorizePriceAdjustments(email: String?, users: [AppUser]) -> Bool {
        activeRole(email: email, users: users) == .admin
    }

    /// Creating a job from an incoming customer request changes the committed
    /// dispatch board, so it is limited to dispatch and administrative staff.
    static func canManageDispatch(email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        return role == .dispatcher || role == .admin
    }

    /// Enumerates every Schedule mutation so a new control cannot silently
    /// inherit broader read access. Standard and field accounts may review the
    /// jobs already visible to them, but only Dispatch/Admin may commit company
    /// capacity, assignments, follow-up visits, or destructive schedule edits.
    enum ScheduleMutationAction: CaseIterable, Sendable {
        case createServiceCall
        case editServiceCall
        case deleteServiceCall
        case assignTechnician
        case scheduleFollowUp
        case scheduleMaintenance
        case scheduleApprovedWork
        case manageServiceRequest
        case syncGoogleCalendar
        case manageAvailability
    }

    static func canPerformScheduleMutation(
        _ action: ScheduleMutationAction,
        email: String?,
        users: [AppUser]
    ) -> Bool {
        switch action {
        case .createServiceCall,
             .editServiceCall,
             .deleteServiceCall,
             .assignTechnician,
             .scheduleFollowUp,
             .scheduleMaintenance,
             .scheduleApprovedWork,
             .manageServiceRequest,
             .syncGoogleCalendar,
             .manageAvailability:
            return canManageDispatch(email: email, users: users)
        }
    }

    /// Unassigned work must pass through the same job-visibility boundary as
    /// every other Schedule query. This keeps it available to authorized office
    /// reviewers while preventing a field account from discovering or claiming
    /// work that has not been explicitly assigned to that technician.
    static func visibleUnassignedServiceCalls(
        email: String?,
        users: [AppUser],
        serviceCalls: [ServiceCall],
        technicians: [Technician] = []
    ) -> [ServiceCall] {
        let visibleIDs = visibleServiceCallIDs(
            email: email,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
        return serviceCalls.filter { call in
            visibleIDs.contains(call.id) && call.assignedTechnician == nil
        }
    }

    /// A staged billing plan changes when revenue becomes billable against an
    /// approved contract. Keep plan creation and allocation Admin-only; field
    /// staff update work evidence and Accounting reviews resulting invoices.
    static func canManageProjectBillingPlans(email: String?, users: [AppUser]) -> Bool {
        activeRole(email: email, users: users) == .admin
    }

    /// Assigned field technicians may complete operational milestones without
    /// gaining company-wide project or financial access. The job-level access
    /// check remains mandatory at the mutation call site.
    static func canCompleteProjectMilestones(email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        return role == .fieldTechnician || role == .admin
    }

    /// Issuing a progress invoice is an accounting mutation. It is narrower
    /// than field collection and does not grant QBO administration privileges.
    static func canIssueProjectProgressInvoices(email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        return role == .accounting || role == .admin
    }

    /// Warranty requests begin in the field, move through an office submission
    /// and manufacturer decision, and end only after replacement/credit recovery.
    /// Keeping each mutation explicit prevents access to a job or customer from
    /// silently granting authority over vendor credits or claim cancellation.
    enum WarrantyClaimAction: CaseIterable, Sendable {
        case request
        case submit
        case recordDecision
        case receiveReplacement
        case recordCredit
        case close
        case cancel
    }

    static func canPerformWarrantyClaimAction(
        _ action: WarrantyClaimAction,
        email: String?,
        users: [AppUser]
    ) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        switch action {
        case .request:
            return role == .fieldTechnician || role == .dispatcher || role == .admin
        case .submit, .recordDecision, .receiveReplacement:
            return role == .dispatcher || role == .admin
        case .recordCredit:
            return role == .accounting || role == .admin
        case .close, .cancel:
            return role == .admin
        }
    }

    /// Customer contact, consent, installed-system, file, and agreement changes
    /// alter the durable operational record. Dispatch and Admin own that work;
    /// Standard and Accounting accounts receive a review-only customer record.
    static func canManageCustomerRecords(email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        return role == .dispatcher || role == .admin
    }

    /// Assigned technicians can present or capture a customer-approved service
    /// agreement from the job screen. Dispatch and Admin can do the same from
    /// office workflows; every field mutation still requires job-level access.
    static func canOfferMaintenanceAgreements(email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        return role == .fieldTechnician || role == .dispatcher || role == .admin
    }

    /// Billing-template selection changes how an approved agreement reaches
    /// the accounting catalog. Keep that mapping Admin-only; it never changes
    /// the customer-approved price or interval.
    static func canConfigureMaintenanceAgreementBilling(email: String?, users: [AppUser]) -> Bool {
        activeRole(email: email, users: users) == .admin
    }

    /// Issuing an invoice from an already approved agreement is an accounting
    /// mutation. Accounting and Admin can perform it; Dispatch and field roles
    /// may create/serve agreements without gaining company-wide billing access.
    static func canIssueMaintenanceAgreementInvoices(email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        return role == .accounting || role == .admin
    }

    /// Removing a customer cascades through local operational and financial
    /// records, so it remains an administrator-only destructive action.
    static func canDeleteCustomerRecords(email: String?, users: [AppUser]) -> Bool {
        activeRole(email: email, users: users) == .admin
    }

    /// Customer synchronization is an accounting-integration mutation, not
    /// ordinary account review. Keep it aligned with the Admin-only QBO console.
    static func canSyncCustomerRecordsWithAccounting(email: String?, users: [AppUser]) -> Bool {
        activeRole(email: email, users: users) == .admin
    }

    /// Job-level scope is enforced independently of whether a workspace is visible.
    /// Field technicians may only open jobs assigned to their signed-in account;
    /// office roles retain the workflow scope needed for dispatch and billing.
    static func visibleServiceCallIDs(
        email: String?,
        users: [AppUser],
        serviceCalls: [ServiceCall],
        technicians: [Technician] = []
    ) -> Set<UUID> {
        guard let role = activeRole(email: email, users: users) else { return [] }
        switch role {
        case .admin, .dispatcher, .accounting, .standard:
            return Set(serviceCalls.map(\.id))
        case .fieldTechnician:
            let normalized = normalizedEmail(email)
            let technicianIDs = Set(technicians.compactMap { technician in
                normalizedEmail(technician.contactInfo) == normalized ? technician.id : nil
            })
            return Set(serviceCalls.compactMap { call in
                let isLead = normalizedEmail(call.assignedTechnician?.contactInfo) == normalized
                let isCrew = !technicianIDs.isDisjoint(with: call.assignedCrewTechnicianIDs)
                return isLead || isCrew ? call.id : nil
            })
        }
    }

    static func canAccessServiceCall(
        _ serviceCall: ServiceCall,
        email: String?,
        users: [AppUser],
        serviceCalls: [ServiceCall],
        technicians: [Technician] = []
    ) -> Bool {
        visibleServiceCallIDs(email: email, users: users, serviceCalls: serviceCalls, technicians: technicians).contains(serviceCall.id)
    }

    static func visibleBillingServiceCallIDs(
        email: String?,
        users: [AppUser],
        serviceCalls: [ServiceCall],
        activeServiceCall: ServiceCall?,
        technicians: [Technician] = []
    ) -> Set<UUID> {
        guard !canViewBillingFinancialDetails(email: email, users: users) else {
            return Set(serviceCalls.map(\.id))
        }

        guard canCollectFieldPayments(email: email, users: users) else {
            return []
        }

        let authorizedIDs = visibleServiceCallIDs(email: email, users: users, serviceCalls: serviceCalls, technicians: technicians)
        guard let activeServiceCall, authorizedIDs.contains(activeServiceCall.id) else {
            return authorizedIDs
        }
        return authorizedIDs.union([activeServiceCall.id])
    }

    /// Resolves the invoices a signed-in account may see in the collection
    /// workspace. Financial-management roles review the complete ledger, while
    /// field technicians receive only invoices for jobs where they are the lead
    /// or an explicitly assigned crew member. Keeping this rule beside job
    /// authorization prevents a payment handoff from silently narrowing a
    /// two-person crew to the lead technician's email.
    static func visibleFieldPaymentInvoiceIDs(
        email: String?,
        users: [AppUser],
        serviceCalls: [ServiceCall],
        invoices: [Invoice],
        technicians: [Technician] = []
    ) -> Set<UUID> {
        if canViewFinancialManagement(email: email, users: users) {
            return Set(invoices.map(\.id))
        }

        guard canCollectFieldPayments(email: email, users: users) else {
            return []
        }

        let authorizedCallIDs = visibleServiceCallIDs(
            email: email,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
        return Set(invoices.compactMap { invoice in
            guard let serviceCallID = invoice.serviceCallID,
                  authorizedCallIDs.contains(serviceCallID) else { return nil }
            return invoice.id
        })
    }

    @discardableResult
    static func ensureTechnicianRecord(
        for email: String,
        technicians: [Technician],
        modelContext: ModelContext
    ) -> Technician {
        let normalized = normalizedEmail(email)
        if let existing = technicians.first(where: { normalizedEmail($0.contactInfo) == normalized }) {
            return existing
        }

        let technician = Technician(
            name: inferredDisplayName(fromEmail: normalized),
            contactInfo: normalized
        )
        modelContext.insert(technician)
        return technician
    }

    static func ensureTechnicianRecords(
        for users: [AppUser],
        technicians: [Technician],
        modelContext: ModelContext
    ) {
        for user in users where user.isActive && shouldProvisionTechnicianRecord(for: user.role) {
            ensureTechnicianRecord(for: user.email, technicians: technicians, modelContext: modelContext)
        }
    }

    static func shouldProvisionTechnicianRecord(for role: AppUserRole) -> Bool {
        role == .fieldTechnician || role == .admin
    }

    static func schedulableTechnicians(_ technicians: [Technician], users: [AppUser]) -> [Technician] {
        let activeUserEmails = Set(users.filter(\.isActive).map(\.email))
        let allUserEmails = Set(users.map(\.email))

        return technicians
            .filter { technician in
                let email = normalizedEmail(technician.contactInfo)
                guard !email.isEmpty, allUserEmails.contains(email) else {
                    return true
                }
                return activeUserEmails.contains(email)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func scheduleLabel(for technician: Technician) -> String {
        let email = normalizedEmail(technician.contactInfo)
        guard !email.isEmpty, email != technician.name.lowercased() else {
            return technician.name
        }
        return "\(technician.name) (\(email))"
    }
}

enum AppUserDataMaintenance {
    /// Collapses duplicate email records that can be created independently on
    /// two devices before CloudKit converges. Conflicting roles or activation
    /// state are reduced to a safe, standard inactive/limited state until the
    /// approved server role sync supplies one authoritative record.
    @discardableResult
    static func collapseCloudKitDuplicates(
        _ users: [AppUser],
        modelContext: ModelContext
    ) -> Int {
        let grouped = Dictionary(grouping: users) { AppAccess.normalizedEmail($0.email) }
        var removedCount = 0

        for (email, matches) in grouped where !email.isEmpty && matches.count > 1 {
            let ordered = matches.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            guard let canonical = ordered.first else { continue }
            let roles = Set(ordered.map(\.role))
            canonical.email = email
            canonical.isActive = ordered.allSatisfy(\.isActive)
            canonical.role = roles.count == 1 ? (roles.first ?? .standard) : .standard

            for duplicate in ordered.dropFirst() {
                modelContext.delete(duplicate)
                removedCount += 1
            }
        }

        guard removedCount > 0 else { return 0 }
        try? modelContext.save()
        return removedCount
    }
}
