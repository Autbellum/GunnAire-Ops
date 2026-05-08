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
}
