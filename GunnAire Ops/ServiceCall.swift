// ServiceCall.swift
// Model for scheduled jobs and service calls
import Foundation
import SwiftData

enum ServiceCallType: String, Codable, CaseIterable {
    case service
    case estimate
    case install
    case maintenance
    case meeting
    case reminder
    case siteVisit = "site visit"
    case other

    var displayName: String {
        switch self {
        case .service:
            return "Service"
        case .estimate:
            return "Estimate"
        case .install:
            return "Install"
        case .maintenance:
            return "Maintenance"
        case .meeting:
            return "Meeting"
        case .reminder:
            return "Reminder"
        case .siteVisit:
            return "Site Visit"
        case .other:
            return "Other"
        }
    }
}

enum JobStatus: String, Codable, CaseIterable {
    case scheduled, inProgress, completed, invoiced, cancelled
}

@Model
final class ServiceCall {
    @Attribute(.unique) var id: UUID
    var googleCalendarID: String?
    var googleEventID: String?
    var eventTitle: String?
    var siteAddress: String?
    var equipmentName: String?
    var equipmentModel: String?
    var equipmentSerialNumber: String?
    var equipmentWarrantyExpiration: Date?
    var type: ServiceCallType
    var scheduledDate: Date
    var duration: TimeInterval
    var assignedTechnician: Technician?
    var customer: Customer
    var status: JobStatus
    var notes: String?
    var findingsSummary: String?
    var recommendedWorkSummary: String?
    var followUpRequired: Bool
    var followUpAction: String?
    var followUpDueDate: Date?
    var diagnosticsCaptured: Bool
    var quoteReviewedWithCustomer: Bool
    var equipmentVerifiedChecklist: Bool
    var startupChecklistComplete: Bool
    var maintenanceChecklistComplete: Bool
    var safetyChecklistComplete: Bool
    var customerNotified: Bool
    var arrivalConfirmed: Bool
    var workCompletedChecklist: Bool
    var documentationChecklist: Bool
    var paymentCollectedChecklist: Bool
    var beforePhotoCount: Int
    var afterPhotoCount: Int
    var documentationStartedAt: Date?
    var documentationCompletedAt: Date?
    var linkedEstimateID: UUID?
    var linkedInvoiceID: UUID?
    
    init(
        id: UUID = UUID(),
        googleCalendarID: String? = nil,
        googleEventID: String? = nil,
        eventTitle: String? = nil,
        siteAddress: String? = nil,
        equipmentName: String? = nil,
        equipmentModel: String? = nil,
        equipmentSerialNumber: String? = nil,
        equipmentWarrantyExpiration: Date? = nil,
        type: ServiceCallType,
        scheduledDate: Date,
        duration: TimeInterval = 3600,
        assignedTechnician: Technician? = nil,
        customer: Customer,
        status: JobStatus = .scheduled,
        notes: String? = nil,
        findingsSummary: String? = nil,
        recommendedWorkSummary: String? = nil,
        followUpRequired: Bool = false,
        followUpAction: String? = nil,
        followUpDueDate: Date? = nil,
        diagnosticsCaptured: Bool = false,
        quoteReviewedWithCustomer: Bool = false,
        equipmentVerifiedChecklist: Bool = false,
        startupChecklistComplete: Bool = false,
        maintenanceChecklistComplete: Bool = false,
        safetyChecklistComplete: Bool = false,
        customerNotified: Bool = false,
        arrivalConfirmed: Bool = false,
        workCompletedChecklist: Bool = false,
        documentationChecklist: Bool = false,
        paymentCollectedChecklist: Bool = false,
        beforePhotoCount: Int = 0,
        afterPhotoCount: Int = 0,
        documentationStartedAt: Date? = nil,
        documentationCompletedAt: Date? = nil,
        linkedEstimateID: UUID? = nil,
        linkedInvoiceID: UUID? = nil
    ) {
        self.id = id
        self.googleCalendarID = googleCalendarID
        self.googleEventID = googleEventID
        self.eventTitle = eventTitle
        self.siteAddress = siteAddress
        self.equipmentName = equipmentName
        self.equipmentModel = equipmentModel
        self.equipmentSerialNumber = equipmentSerialNumber
        self.equipmentWarrantyExpiration = equipmentWarrantyExpiration
        self.type = type
        self.scheduledDate = scheduledDate
        self.duration = duration
        self.assignedTechnician = assignedTechnician
        self.customer = customer
        self.status = status
        self.notes = notes
        self.findingsSummary = findingsSummary
        self.recommendedWorkSummary = recommendedWorkSummary
        self.followUpRequired = followUpRequired
        self.followUpAction = followUpAction
        self.followUpDueDate = followUpDueDate
        self.diagnosticsCaptured = diagnosticsCaptured
        self.quoteReviewedWithCustomer = quoteReviewedWithCustomer
        self.equipmentVerifiedChecklist = equipmentVerifiedChecklist
        self.startupChecklistComplete = startupChecklistComplete
        self.maintenanceChecklistComplete = maintenanceChecklistComplete
        self.safetyChecklistComplete = safetyChecklistComplete
        self.customerNotified = customerNotified
        self.arrivalConfirmed = arrivalConfirmed
        self.workCompletedChecklist = workCompletedChecklist
        self.documentationChecklist = documentationChecklist
        self.paymentCollectedChecklist = paymentCollectedChecklist
        self.beforePhotoCount = beforePhotoCount
        self.afterPhotoCount = afterPhotoCount
        self.documentationStartedAt = documentationStartedAt
        self.documentationCompletedAt = documentationCompletedAt
        self.linkedEstimateID = linkedEstimateID
        self.linkedInvoiceID = linkedInvoiceID
    }
    
    var isUpcomingThisWeek: Bool {
        let now = Date()
        let oneWeekLater = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        return scheduledDate >= now && scheduledDate <= oneWeekLater
    }

    var checklistCompletedCount: Int {
        [customerNotified, arrivalConfirmed, workCompletedChecklist, documentationChecklist, paymentCollectedChecklist]
            .filter { $0 }
            .count
    }

    var checklistTotalCount: Int { 5 }

    var isExternallyLinked: Bool {
        googleEventID != nil || googleCalendarID != nil || linkedEstimateID != nil || linkedInvoiceID != nil
    }

    var equipmentSummary: String? {
        let rawParts: [String?] = [
            equipmentName?.trimmingCharacters(in: .whitespacesAndNewlines),
            equipmentModel?.trimmingCharacters(in: .whitespacesAndNewlines),
            equipmentSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        let parts = rawParts.compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        let decoratedParts = parts.enumerated().map { index, value in
            index == 2 ? "S/N \(value)" : value
        }

        guard !decoratedParts.isEmpty else { return nil }
        return decoratedParts.joined(separator: " • ")
    }

    var workflowChecklistCompletedCount: Int {
        workflowChecklistValues.filter { $0 }.count
    }

    var workflowChecklistTotalCount: Int {
        workflowChecklistValues.count
    }

    private var workflowChecklistValues: [Bool] {
        switch type {
        case .service:
            return [diagnosticsCaptured, recommendedWorkSummary != nil, safetyChecklistComplete]
        case .estimate:
            return [quoteReviewedWithCustomer, recommendedWorkSummary != nil, followUpRequired]
        case .install:
            return [equipmentVerifiedChecklist, startupChecklistComplete, safetyChecklistComplete]
        case .maintenance:
            return [maintenanceChecklistComplete, safetyChecklistComplete, customerNotified]
        case .meeting, .reminder, .siteVisit, .other:
            return [arrivalConfirmed, workCompletedChecklist, documentationChecklist]
        }
    }
}
