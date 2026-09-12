import Foundation
import CryptoKit
import SwiftData

enum BillingMilestoneIdentity {
    static func reference(in note: String?) throws -> UUID? {
        var found: UUID?, kinds = Set<String>()
        for raw in (note ?? "").components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let kindsToMatch = ["gunnaire milestone id:", "gunnaire project billing:"]
            guard let kind = kindsToMatch.first(where: { line.lowercased().hasPrefix($0) }) else { continue }
            let pattern = kind == kindsToMatch[0] ? "^GunnAire Milestone ID: [0-9a-fA-F-]{36}$"
                : "^GunnAire project billing: .+; milestone ID [0-9a-fA-F-]{36}$"
            guard kinds.insert(kind).inserted, line.range(of: pattern, options: .regularExpression) != nil,
                  let value = UUID(uuidString: String(line.suffix(36))), found == nil || found == value else {
                throw BillingPublicationError.invalidResponse
            }
            found = value
        }
        return found
    }

    /// A new stage always derives the same invoice UUID on every device. Existing
    /// random UUIDs are retained; shared history owns their recovery, not rekeying.
    static func invoiceID(for milestoneID: UUID) -> UUID {
        let input = "gunnaire-milestone-invoice-v1\n" + milestoneID.uuidString.lowercased()
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // application-defined UUID version 8
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func privateNote(notes: String?, milestoneID: UUID?, summary: String?) -> String? {
        // User-entered notes cannot impersonate an app-owned milestone marker.
        let user = notes?.components(separatedBy: .newlines).filter {
            let line = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return !line.hasPrefix("gunnaire milestone id:") && !line.hasPrefix("gunnaire project billing:")
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var entries: [String] = []
        if let milestoneID {
            entries.append("GunnAire Milestone ID: " + milestoneID.uuidString)
            if let summary, !summary.isEmpty { entries.append("Project billing: " + summary) }
        }
        if let user, !user.isEmpty { entries.append(user) }
        // Reserve room for the server's invoice/publication lineage (QBO 4,000).
        return entries.isEmpty ? nil : String(entries.joined(separator: "\n").prefix(3_800))
    }
}

struct BillingMilestoneOriginal: Decodable, Equatable {
    let projectMilestoneID: UUID
    let localDocumentID: UUID
    let localCustomerID: UUID
    let publicationID: UUID
    let state: BillingPublicationState

    @MainActor
    func localInvoice(in context: ModelContext, for document: QuickBooksBillingDocument) throws -> Invoice? {
        let matches = try context.fetch(FetchDescriptor<Invoice>()).filter { $0.id == localDocumentID }
        guard matches.count <= 1 else { throw BillingPublicationError.invalidResponse }
        guard let original = matches.first else { return nil }
        guard original.customer?.id == localCustomerID, original.customer === document.customer,
              original.serviceCallID == document.serviceCallID, original.projectMilestoneID == projectMilestoneID else {
            throw BillingPublicationError.invalidResponse
        }
        return original
    }
}
