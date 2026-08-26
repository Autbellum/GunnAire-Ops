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
        let email = normalizedEmail(email)
        if email == primaryAdminEmail {
            return true
        }
        return users.contains { $0.isActive && $0.email == email && $0.role == .admin }
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
        let email = normalizedEmail(email)
        if email == primaryAdminEmail {
            return true
        }
        return users.contains { $0.isActive && $0.email == email }
    }

    static func canAccessSidebarItem(_ item: SidebarItem, email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        switch item {
        case .commandCenter, .customers:
            return true
        case .timeClock:
            return role != .accounting
        case .scheduleAndJobs, .onsiteDocumentation:
            return role != .accounting
        case .mail, .estimates:
            return role == .dispatcher || role == .admin
        case .invoices, .payments, .receiptsBills:
            return role == .fieldTechnician || role == .accounting || role == .admin
        case .syncIntegrations, .quickBooksManagement:
            return role == .admin
        }
    }

    static func canViewFinancialManagement(email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        return role == .admin || role == .accounting
    }

    static func canViewBillingFinancialDetails(email: String?, users: [AppUser]) -> Bool {
        canViewFinancialManagement(email: email, users: users)
    }

    static func canCollectFieldPayments(email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        return role == .fieldTechnician || role == .admin
    }

    /// Creating a job from an incoming customer request changes the committed
    /// dispatch board, so it is limited to dispatch and administrative staff.
    static func canManageDispatch(email: String?, users: [AppUser]) -> Bool {
        guard let role = activeRole(email: email, users: users) else { return false }
        return role == .dispatcher || role == .admin
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
