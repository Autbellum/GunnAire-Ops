import Foundation
import SwiftData

/// A synchronous form transaction restores only fields and child changes it
/// owns. It never rolls back another window's unrelated SwiftData work.
enum ServiceCallEditRollback {
    static func capture(_ call: ServiceCall, context: ModelContext) throws -> () -> Void {
        _ = try JobBillingTarget.capture(call, context: context)
        let activityIDs = Set(try context.fetch(FetchDescriptor<ServiceCallActivity>()).map(\.id))
        let agreements = try context.fetch(FetchDescriptor<RecurringMaintenanceContract>()).filter { $0.id == call.maintenanceAgreementID }
        let dates = agreements.map { ($0, $0.nextDate) }
        return { [type = call.type, dispatchUrgency = call.dispatchUrgency, eventTitle = call.eventTitle, customer = call.customer,
            assignedTechnician = call.assignedTechnician, additionalTechnicianIDs = call.additionalTechnicianIDs, status = call.status, cancelledAt = call.cancelledAt,
            cancellationReason = call.cancellationReason, googleCalendarID = call.googleCalendarID, siteAddress = call.siteAddress, serviceLocationID = call.serviceLocationID,
            equipmentName = call.equipmentName, equipmentManufacturer = call.equipmentManufacturer, equipmentModel = call.equipmentModel, equipmentSerialNumber = call.equipmentSerialNumber,
            equipmentLocation = call.equipmentLocation, equipmentType = call.equipmentType, equipmentNotes = call.equipmentNotes, filterSize = call.filterSize,
            equipmentInstallDate = call.equipmentInstallDate, equipmentWarrantyExpiration = call.equipmentWarrantyExpiration, customerEquipmentID = call.customerEquipmentID, scheduledDate = call.scheduledDate,
            duration = call.duration, promisedArrivalWindowStart = call.promisedArrivalWindowStart, promisedArrivalWindowEnd = call.promisedArrivalWindowEnd, notes = call.notes,
            findingsSummary = call.findingsSummary, recommendedWorkSummary = call.recommendedWorkSummary, visitDisposition = call.visitDisposition, visitDispositionNotes = call.visitDispositionNotes,
            correctiveWorkReason = call.correctiveWorkReason, followUpRequired = call.followUpRequired, followUpAction = call.followUpAction, followUpDueDate = call.followUpDueDate,
            documentationStartedAt = call.documentationStartedAt, documentationCompletedAt = call.documentationCompletedAt, documentationChecklist = call.documentationChecklist, serviceReportReadingsJSON = call.serviceReportReadingsJSON
        ] in
            call.type = type
            call.dispatchUrgency = dispatchUrgency
            call.eventTitle = eventTitle
            call.customer = customer
            call.assignedTechnician = assignedTechnician
            call.additionalTechnicianIDs = additionalTechnicianIDs
            call.status = status
            call.cancelledAt = cancelledAt
            call.cancellationReason = cancellationReason
            call.googleCalendarID = googleCalendarID
            call.siteAddress = siteAddress
            call.serviceLocationID = serviceLocationID
            call.equipmentName = equipmentName
            call.equipmentManufacturer = equipmentManufacturer
            call.equipmentModel = equipmentModel
            call.equipmentSerialNumber = equipmentSerialNumber
            call.equipmentLocation = equipmentLocation
            call.equipmentType = equipmentType
            call.equipmentNotes = equipmentNotes
            call.filterSize = filterSize
            call.equipmentInstallDate = equipmentInstallDate
            call.equipmentWarrantyExpiration = equipmentWarrantyExpiration
            call.customerEquipmentID = customerEquipmentID
            call.scheduledDate = scheduledDate
            call.duration = duration
            call.promisedArrivalWindowStart = promisedArrivalWindowStart
            call.promisedArrivalWindowEnd = promisedArrivalWindowEnd
            call.notes = notes
            call.findingsSummary = findingsSummary
            call.recommendedWorkSummary = recommendedWorkSummary
            call.visitDisposition = visitDisposition
            call.visitDispositionNotes = visitDispositionNotes
            call.correctiveWorkReason = correctiveWorkReason
            call.followUpRequired = followUpRequired
            call.followUpAction = followUpAction
            call.followUpDueDate = followUpDueDate
            call.documentationStartedAt = documentationStartedAt
            call.documentationCompletedAt = documentationCompletedAt
            call.documentationChecklist = documentationChecklist
            call.serviceReportReadingsJSON = serviceReportReadingsJSON
            for (agreement, date) in dates { agreement.nextDate = date }
            if let activities = try? context.fetch(FetchDescriptor<ServiceCallActivity>()) {
                for activity in activities where activity.serviceCallID == call.id && !activityIDs.contains(activity.id) {
                    context.delete(activity)
                }
            }
        }
    }
}
