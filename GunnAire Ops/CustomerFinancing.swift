import Foundation

/// Read-only deployment readiness for a provider-hosted customer application.
/// Applicant, credit, underwriting, and decision data never cross this contract.
struct CustomerFinancingReadiness: Codable, Equatable {
    let contractVersion: Int
    let status: String
    let detail: String
    let providerName: String?
    let applicationURL: String?
    let minimumAmount: Double?
    let maximumAmount: Double?
    let providerHostedApplication: Bool
    let canSubmitApplication: Bool

    var validatedProviderName: String? {
        guard let providerName else { return nil }
        let normalized = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count <= 80,
              !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return normalized
    }

    var validatedApplicationURL: URL? {
        guard let applicationURL,
              !applicationURL.contains(where: \Character.isWhitespace),
              let components = URLComponents(string: applicationURL),
              components.scheme?.lowercased() == "https",
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            return nil
        }
        return components.url
    }

    var isReady: Bool {
        guard contractVersion == 1,
              status.caseInsensitiveCompare("ready") == .orderedSame,
              providerHostedApplication,
              !canSubmitApplication,
              validatedProviderName != nil,
              validatedApplicationURL != nil,
              minimumAmount.map({ $0.isFinite && $0 >= 0 }) ?? true,
              maximumAmount.map({ $0.isFinite && $0 > 0 }) ?? true else {
            return false
        }
        if let minimumAmount, let maximumAmount, minimumAmount > maximumAmount {
            return false
        }
        return true
    }

    var providerHost: String? {
        validatedApplicationURL?.host
    }

    var amountRangeDetail: String? {
        switch (minimumAmount, maximumAmount) {
        case let (minimum?, maximum?):
            return "Eligible estimates: \(minimum.formatted(.currency(code: "USD")))–\(maximum.formatted(.currency(code: "USD")))"
        case let (minimum?, nil):
            return "Eligible estimates: \(minimum.formatted(.currency(code: "USD"))) or more"
        case let (nil, maximum?):
            return "Eligible estimates: up to \(maximum.formatted(.currency(code: "USD")))"
        case (nil, nil):
            return nil
        }
    }

    #if DEBUG
    static let uiTestFixture = CustomerFinancingReadiness(
        contractVersion: 1,
        status: "ready",
        detail: "Provider-hosted application is ready for UI verification.",
        providerName: "Approved HVAC Finance",
        applicationURL: "https://finance.example.com/gunnaire/apply",
        minimumAmount: 100,
        maximumAmount: 50_000,
        providerHostedApplication: true,
        canSubmitApplication: false
    )
    #endif
}

struct CustomerFinancingEligibility: Equatable {
    let isEligible: Bool
    let reason: String?
}

enum CustomerFinancingPolicy {
    private static let eligibleEstimateStatuses = Set(["pending", "sent", "follow-up", "accepted"])

    static func eligibility(
        readiness: CustomerFinancingReadiness?,
        estimateAmount: Double,
        estimateStatus: String,
        isCurrentProposal: Bool,
        proposalSelectionIssue: String?
    ) -> CustomerFinancingEligibility {
        guard let readiness, readiness.isReady else {
            return CustomerFinancingEligibility(
                isEligible: false,
                reason: "Customer financing is not ready on the GunnAire backend."
            )
        }
        guard isCurrentProposal else {
            return CustomerFinancingEligibility(
                isEligible: false,
                reason: "Offer financing from the current estimate or change order."
            )
        }
        if let proposalSelectionIssue {
            return CustomerFinancingEligibility(isEligible: false, reason: proposalSelectionIssue)
        }
        let normalizedStatus = estimateStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard eligibleEstimateStatuses.contains(normalizedStatus) else {
            return CustomerFinancingEligibility(
                isEligible: false,
                reason: "Financing is available only while an estimate is open or accepted."
            )
        }
        guard estimateAmount.isFinite, estimateAmount > 0 else {
            return CustomerFinancingEligibility(
                isEligible: false,
                reason: "The estimate needs a positive total before financing can be offered."
            )
        }
        if let minimumAmount = readiness.minimumAmount, estimateAmount < minimumAmount {
            return CustomerFinancingEligibility(
                isEligible: false,
                reason: "This estimate is below the provider minimum of \(minimumAmount.formatted(.currency(code: "USD")))."
            )
        }
        if let maximumAmount = readiness.maximumAmount, estimateAmount > maximumAmount {
            return CustomerFinancingEligibility(
                isEligible: false,
                reason: "This estimate exceeds the provider maximum of \(maximumAmount.formatted(.currency(code: "USD")))."
            )
        }
        return CustomerFinancingEligibility(isEligible: true, reason: nil)
    }

    static func activityDetail(providerName: String, estimateID: UUID) -> String {
        let normalizedProvider = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Opened \(normalizedProvider) provider-hosted application for estimate \(String(estimateID.uuidString.prefix(8)).uppercased()). Applicant and credit data remain with the financing provider."
    }
}
