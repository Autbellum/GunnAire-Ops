import Foundation

enum CustomerPublicationError: LocalizedError, Equatable {
    case unavailable, needsReview, accessRequired, invalidResponse, invalidProposal, inactiveCustomer

    var errorDescription: String? {
        switch self {
        case .unavailable: "The shared customer service could not confirm the request. Your customer stays saved; no direct QuickBooks retry was sent."
        case .needsReview: "Open the customer's Overview → Customer sync review to recover the original attempt before trying again."
        case .accessRequired: "Ask an administrator to sync this customer before publishing its documents. Your saved field work is retained."
        case .invalidResponse: "The service did not confirm the original customer identity. Keep the saved customer for review."
        case .invalidProposal: "Review the customer's name, phone, email and billing address before syncing again."
        case .inactiveCustomer: "The original QuickBooks customer is inactive. Ask an administrator to review it in QuickBooks; no duplicate customer was created."
        }
    }
}

struct CustomerPublicationRequest: Encodable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let localCustomerID: UUID
    let customer: QuickBooksCustomerCreate
    var connectionRevision: String? = nil
}

struct CustomerPublicationRecord: Decodable, Identifiable {
    let id: UUID
    let companyID: UUID
    let realmID: String
    let environment: String
    let localCustomerID: UUID
    let state: String
    let providerID: String?
    let updatedAt: String

    func validate(companyID: UUID, realmID: String, environment: String, customerID: UUID) throws {
        guard self.companyID == companyID, self.realmID == realmID, self.environment == environment,
              localCustomerID == customerID,
              ["reserved", "sending", "unknown", "confirmed", "cancelled"].contains(state),
              state != "confirmed" || providerID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw CustomerPublicationError.invalidResponse
        }
    }

    var title: String {
        switch state {
        case "reserved": "Not sent"
        case "sending", "unknown": "Awaiting QuickBooks confirmation"
        case "confirmed": "Confirmed in QuickBooks"
        case "cancelled": "Cancelled before sending"
        default: "Needs review"
        }
    }
}

struct CustomerPublicationResponse: Decodable {
    let publication: CustomerPublicationRecord
    let customer: QuickBooksCustomer
    let created: Bool?

    func validate(companyID: UUID, realmID: String, environment: String, customerID: UUID) throws {
        try publication.validate(companyID: companyID, realmID: realmID, environment: environment, customerID: customerID)
        guard publication.state == "confirmed", publication.providerID == customer.Id,
              !customer.Id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CustomerPublicationError.invalidResponse
        }
        guard let active = customer.Active else { throw CustomerPublicationError.invalidResponse }
        guard active else { throw CustomerPublicationError.inactiveCustomer }
    }
}

@MainActor
enum CustomerPublicationBoundary {
    typealias Transport = (CustomerPublicationRequest) async throws -> CustomerPublicationResponse

    static func request(workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow,
                        draft: QuickBooksCustomerCreateDraft) throws -> CustomerPublicationRequest {
        try workflow.check()
        guard let companyID = workflow.companyID, let realmID = workflow.realmID, !realmID.isEmpty,
              ["sandbox", "production"].contains(workflow.environment) else { throw CustomerPublicationError.accessRequired }
        return .init(companyID: companyID, realmID: realmID, environment: workflow.environment,
                     localCustomerID: draft.localCustomerID, customer: QuickBooksCustomerCreateOperation.payload(for: draft),
                     connectionRevision: workflow.sharedBillingConnectionRevision)
    }
}
