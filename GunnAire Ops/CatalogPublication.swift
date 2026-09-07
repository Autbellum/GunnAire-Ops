import Foundation

enum CatalogPublicationError: LocalizedError, Equatable {
    case unavailable, needsReview, accessRequired, invalidResponse, invalidProposal

    var errorDescription: String? {
        switch self {
        case .unavailable: "The shared catalog service is unavailable. Your item is saved. No direct QuickBooks retry was sent."
        case .needsReview: "An earlier proposal needs review. Open Catalog publication review in QuickBooks before publishing again."
        case .accessRequired: "Current administrator access to the original business is required."
        case .invalidResponse: "The shared service did not confirm the original catalog identity. Keep the saved item for review."
        case .invalidProposal: "Check the item fields and accounting mappings, then review the saved publication before retrying."
        }
    }
}

struct CatalogPublicationRequest: Encodable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let localItemID: UUID
    let operation: String
    let item: Payload

    enum Payload: Encodable {
        case create(QuickBooksItemCreate), update(QuickBooksItemUpdate)
        func encode(to encoder: Encoder) throws {
            switch self {
            case .create(let value): try value.encode(to: encoder)
            case .update(let value): try value.encode(to: encoder)
            }
        }
    }
}

struct CatalogPublicationRecord: Decodable, Identifiable {
    let id: UUID
    let companyID: UUID
    let realmID: String
    let environment: String
    let localItemID: UUID
    let operation: String
    let state: String
    let providerID: String?
    let updatedAt: String

    func validate(companyID: UUID, realmID: String, environment: String, itemID: UUID) throws {
        guard self.companyID == companyID, self.realmID == realmID,
              self.environment == environment, localItemID == itemID,
              ["create", "update"].contains(operation),
              ["reserved", "sending", "unknown", "confirmed", "cancelled"].contains(state) else {
            throw CatalogPublicationError.invalidResponse
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

struct CatalogPublicationResponse: Decodable {
    let publication: CatalogPublicationRecord
    let item: QuickBooksItem
    let created: Bool?

    func validate(companyID: UUID, realmID: String, environment: String, itemID: UUID) throws {
        try publication.validate(companyID: companyID, realmID: realmID, environment: environment, itemID: itemID)
        guard publication.state == "confirmed", publication.providerID == item.Id,
              !item.Id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatalogPublicationError.invalidResponse
        }
    }
}

@MainActor
enum CatalogPublicationBoundary {
    typealias Transport = (CatalogPublicationRequest) async throws -> CatalogPublicationResponse

    static func request(workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow, itemID: UUID,
                        payload: CatalogPublicationRequest.Payload) throws -> CatalogPublicationRequest {
        try workflow.check()
        guard let companyID = workflow.companyID, let realmID = workflow.realmID, !realmID.isEmpty,
              ["sandbox", "production"].contains(workflow.environment) else {
            throw CatalogPublicationError.accessRequired
        }
        let operation: String
        switch payload { case .create: operation = "create"; case .update: operation = "update" }
        return .init(companyID: companyID, realmID: realmID, environment: workflow.environment,
                     localItemID: itemID, operation: operation, item: payload)
    }
}
