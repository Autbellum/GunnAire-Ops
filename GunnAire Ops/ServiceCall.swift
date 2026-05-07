// ServiceCall.swift
// Model for scheduled jobs and service calls
import Foundation
import SwiftData

enum ServiceCallType: String, Codable, CaseIterable {
    case service, estimate, install, maintenance
}

enum JobStatus: String, Codable, CaseIterable {
    case scheduled, inProgress, completed, invoiced, cancelled
}

@Model
final class ServiceCall {
    @Attribute(.unique) var id: UUID
    var googleCalendarID: String?
    var googleEventID: String?
    var siteAddress: String?
    var type: ServiceCallType
    var scheduledDate: Date
    var duration: TimeInterval
    var assignedTechnician: Technician?
    var customer: Customer
    var status: JobStatus
    var notes: String?
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
        siteAddress: String? = nil,
        type: ServiceCallType,
        scheduledDate: Date,
        duration: TimeInterval = 3600,
        assignedTechnician: Technician? = nil,
        customer: Customer,
        status: JobStatus = .scheduled,
        notes: String? = nil,
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
        self.siteAddress = siteAddress
        self.type = type
        self.scheduledDate = scheduledDate
        self.duration = duration
        self.assignedTechnician = assignedTechnician
        self.customer = customer
        self.status = status
        self.notes = notes
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
}
