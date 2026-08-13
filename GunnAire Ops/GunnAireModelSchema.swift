import SwiftData

enum GunnAireModelSchema {
    static var schema: Schema {
        Schema([
            Item.self,
            ServiceCall.self,
            Customer.self,
            Technician.self,
            RecurringMaintenanceContract.self,
            Invoice.self,
            Estimate.self,
            Payment.self,
            TimeEntry.self,
            Vendor.self,
            AppUser.self,
            ServiceDocumentAttachment.self,
        ])
    }
}
