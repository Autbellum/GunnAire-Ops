import Foundation
import SwiftData

enum AppUserRole: String, Codable, CaseIterable, Identifiable {
    case standard = "Standard"
    case admin = "Admin"

    var id: String { rawValue }
}

@Model
final class AppUser {
    @Attribute(.unique) var id: UUID
    var email: String
    var roleRawValue: String
    var isActive: Bool
    var createdAt: Date

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

    static func isAuthorized(email: String?, users: [AppUser]) -> Bool {
        let email = normalizedEmail(email)
        if email == primaryAdminEmail {
            return true
        }
        return users.contains { $0.isActive && $0.email == email }
    }

    static func canAccessSidebarItem(_ item: SidebarItem, email: String?, users: [AppUser]) -> Bool {
        let admin = isAdmin(email: email, users: users)
        switch item {
        case .commandCenter, .timeClock, .scheduleAndJobs, .customers, .onsiteDocumentation, .invoices, .payments, .receiptsBills:
            return true
        case .mail, .estimates, .syncIntegrations, .quickBooksManagement:
            return admin
        }
    }

    static func canViewFinancialManagement(email: String?, users: [AppUser]) -> Bool {
        isAdmin(email: email, users: users)
    }

    static func canViewBillingFinancialDetails(email: String?, users: [AppUser]) -> Bool {
        canViewFinancialManagement(email: email, users: users)
    }

    static func canCollectFieldPayments(email: String?, users: [AppUser]) -> Bool {
        isAuthorized(email: email, users: users)
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
        for user in users where user.isActive {
            ensureTechnicianRecord(for: user.email, technicians: technicians, modelContext: modelContext)
        }
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
