import SwiftData

enum GunnAireModelSchema {
    /// Built once: store identity checks and the publication loop read it on
    /// every pass, and constructing a 32-model schema is not free.
    static let schema: Schema = Schema([
            Item.self,
            ServiceCall.self,
            Customer.self,
            CustomerServiceLocation.self,
            Technician.self,
            TechnicianAvailabilityBlock.self,
            TechnicianWorkShift.self,
            TechnicianTimeOffRequest.self,
            TechnicianAvailabilityEvent.self,
            RecurringMaintenanceContract.self,
            Invoice.self,
            Estimate.self,
            Payment.self,
            TimeEntry.self,
            Vendor.self,
            AppUser.self,
            ServiceDocumentAttachment.self,
            CustomerEquipment.self,
            CustomerCommunication.self,
            PurchaseOrder.self,
            InventoryMovement.self,
            ServiceRequest.self,
            ServiceCallActivity.self,
            ProjectMilestone.self,
            FieldFormTemplate.self,
            FieldFormResponse.self,
            FleetVehicle.self,
            FleetVehicleEvent.self,
            FieldExpenseClaim.self,
            CustomerOperationalAlert.self,
            BusinessTask.self,
            BusinessTaskEvent.self,
        ])
}
