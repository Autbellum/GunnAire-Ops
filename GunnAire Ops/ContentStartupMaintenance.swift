import Foundation
import SwiftData

/// The data maintenance that runs when the signed-in workspace first appears,
/// on a background context instead of the main one.
///
/// `ContentView.onAppear` used to fetch every user, every customer, every
/// attachment and every communication on the main context before the first
/// screen could respond, then save the results there too. Each of those is
/// a full-table fetch on the owner's data. Everything here runs on this
/// actor's own context; the main context sees the saved results through the
/// shared store. Only the customer deletion pass, which walks every related
/// record, is left on the main context, and only after this actor has
/// confirmed there is something to delete.
@ModelActor
actor ContentStartupMaintenance {
    /// How many pending uploads one pass retries: the newest first, the same
    /// selection the former root query made.
    static let uploadRetryBatchSize = 10

    /// Collapses user records that two devices created for the same email
    /// before CloudKit converged. Returns how many duplicates were removed.
    @discardableResult
    func collapseCloudKitUserDuplicates() -> Int {
        let descriptor = FetchDescriptor<AppUser>(sortBy: [SortDescriptor(\AppUser.email, order: .forward)])
        let users = (try? modelContext.fetch(descriptor)) ?? []
        return AppUserDataMaintenance.collapseCloudKitDuplicates(users, modelContext: modelContext)
    }

    /// Whether a calendar import left generic placeholder customers behind.
    /// The cleanup itself deletes across every related table, so the caller
    /// runs it on the main context only when this says there is work.
    func hasCalendarCreatedCustomersToClean() -> Bool {
        let customers = (try? modelContext.fetch(FetchDescriptor<Customer>())) ?? []
        return customers.contains {
            CustomerDataMaintenance.isGenericCalendarCustomer($0) && !CustomerDataMaintenance.isSystemCalendarCustomer($0)
        }
    }

    /// The attachments the next upload pass will retry, newest first.
    func pendingSharedCompanyDocumentUploads() -> [ServiceDocumentAttachment] {
        let descriptor = FetchDescriptor<ServiceDocumentAttachment>(
            sortBy: [SortDescriptor(\ServiceDocumentAttachment.createdAt, order: .reverse)]
        )
        let attachments = (try? modelContext.fetch(descriptor)) ?? []
        return Array(attachments.filter(\.needsSharedCompanyStorageUpload).prefix(Self.uploadRetryBatchSize))
    }

    /// The communications the next sync pass will retry, newest first.
    func pendingCustomerCommunicationUploads() -> [CustomerCommunication] {
        let descriptor = FetchDescriptor<CustomerCommunication>(
            sortBy: [SortDescriptor(\CustomerCommunication.createdAt, order: .reverse)]
        )
        let communications = (try? modelContext.fetch(descriptor)) ?? []
        return Array(communications.filter(\.needsSharedCompanySync).prefix(Self.uploadRetryBatchSize))
    }

    /// Retries the pending shared-company document uploads. Each model is
    /// read and marked on this actor; only the request crosses to the network.
    /// Returns how many were stored and how many failed.
    @discardableResult
    func retryPendingSharedCompanyDocumentUploads() async -> (stored: Int, failed: Int) {
        var stored = 0
        var failed = 0
        for attachment in pendingSharedCompanyDocumentUploads() {
            do {
                let request = try GunnAireBackendService.sharedCompanyDocumentUploadRequest(for: attachment)
                let response = try await GunnAireBackendService.retrySharedCompanyDocumentUpload(request: request)
                attachment.markSharedCompanyStored(id: response.id)
                stored += 1
            } catch {
                attachment.markSharedCompanyUploadFailed(error.localizedDescription)
                failed += 1
            }
            try? modelContext.save()
        }
        return (stored, failed)
    }

    /// Retries the pending customer-communication syncs the same way.
    @discardableResult
    func retryPendingCustomerCommunicationUploads() async -> (synced: Int, failed: Int) {
        var synced = 0
        var failed = 0
        for communication in pendingCustomerCommunicationUploads() {
            let payload = GunnAireBackendService.communicationPayload(for: communication)
            do {
                let response = try await GunnAireBackendService.uploadCustomerCommunication(payload: payload)
                communication.markSharedCompanySynced(id: response.id)
                synced += 1
            } catch {
                communication.markSharedCompanySyncFailed(error.localizedDescription)
                failed += 1
            }
            try? modelContext.save()
        }
        return (synced, failed)
    }
}
