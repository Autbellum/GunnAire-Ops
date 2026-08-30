import Foundation
import SwiftUI
import UIKit

#if canImport(MessageUI) && !targetEnvironment(macCatalyst)
import MessageUI
#endif

nonisolated enum CustomerServiceTextOutcome: Equatable, Sendable {
    case sent(recipients: [String])
    case cancelled
    case failed
}

nonisolated struct CustomerServiceTextDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let customerID: UUID
    let serviceCallID: UUID
    let recipient: String
    let body: String
    let auditSubject: String
    let workflow: GunnAireMailWorkflow
    let templateVersion: String
    let consentSnapshot: CustomerCommunicationConsentSnapshot
    let approximateArrivalMinutes: Int?

    var actionTitle: String {
        switch workflow {
        case .appointmentConfirmation: "Text Confirmation"
        case .technicianEnRoute: "Text On My Way"
        case .technicianArrival: "Text Arrival"
        case .workInProgress: "Text Work Update"
        default: "Text Customer"
        }
    }
}

nonisolated enum EnRouteArrivalEstimate: Int, CaseIterable, Identifiable, Sendable {
    case five = 5
    case ten = 10
    case fifteen = 15
    case thirty = 30
    case fortyFive = 45
    case sixty = 60

    var id: Int { rawValue }
    var title: String { "Approximately \(rawValue) minutes" }

    func expectedArrival(from departure: Date) -> Date {
        departure.addingTimeInterval(TimeInterval(rawValue * 60))
    }
}

nonisolated enum EnRouteCustomerUpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case none
    case text
    case email

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "No customer draft"
        case .text: "Text message draft"
        case .email: "Email draft"
        }
    }

    var systemImage: String {
        switch self {
        case .none: "bell.slash"
        case .text: "message"
        case .email: "envelope"
        }
    }
}

nonisolated struct EnRouteHandoffSubmission: Equatable, Sendable {
    let arrivalEstimate: EnRouteArrivalEstimate
    let customerUpdateChannel: EnRouteCustomerUpdateChannel
}

enum EnRouteHandoffPolicy {
    @MainActor
    static func canMarkEnRoute(_ call: ServiceCall) -> Bool {
        call.status == .scheduled &&
        call.technicianEnRouteAt == nil &&
        call.technicianArrivedAt == nil &&
        !call.arrivalConfirmed
    }

    nonisolated static func activityDetail(
        estimate: EnRouteArrivalEstimate,
        markedAt: Date
    ) -> String {
        let expectedArrival = estimate.expectedArrival(from: markedAt)
            .formatted(date: .omitted, time: .shortened)
        return "Technician marked en route with a staff-selected approximate arrival estimate of \(estimate.rawValue) minutes (about \(expectedArrival)); job moved to in progress. This estimate does not use live traffic or GPS tracking."
    }
}

enum CustomerServiceTextPolicy {
    @MainActor
    static func draft(
        for call: ServiceCall,
        approximateArrivalMinutes: Int? = nil
    ) -> CustomerServiceTextDraft? {
        guard call.status == .scheduled || call.status == .inProgress,
              call.customer.allowsServiceText,
              let recipient = normalizedRecipient(call.customer.phone) else { return nil }

        let arrivalEstimate: EnRouteArrivalEstimate?
        if let approximateArrivalMinutes {
            guard let validEstimate = EnRouteArrivalEstimate(rawValue: approximateArrivalMinutes) else {
                return nil
            }
            arrivalEstimate = validEstimate
        } else {
            arrivalEstimate = nil
        }

        let workflow: GunnAireMailWorkflow
        let update: String
        switch call.technicianJobPresence {
        case .scheduled:
            guard arrivalEstimate == nil else { return nil }
            workflow = .appointmentConfirmation
            update = "Your service appointment is confirmed."
        case .enRoute:
            workflow = .technicianEnRoute
            if let arrivalEstimate {
                update = "Your GunnAire technician is on the way and expects to arrive in approximately \(arrivalEstimate.rawValue) minutes."
            } else {
                update = "Your GunnAire technician is on the way."
            }
        case .onSite:
            guard arrivalEstimate == nil else { return nil }
            workflow = .technicianArrival
            update = "Your GunnAire technician has arrived."
        case .working:
            guard arrivalEstimate == nil else { return nil }
            workflow = .workInProgress
            update = "Your GunnAire technician is working on your service visit."
        case .completed, .cancelled:
            return nil
        }

        let body = """
        GunnAire update: \(update)

        Appointment: \(call.customerAppointmentSummary)
        Service: \(call.type.displayName)

        Contact GunnAire if anything has changed.
        """
        return CustomerServiceTextDraft(
            id: UUID(),
            customerID: call.customer.id,
            serviceCallID: call.id,
            recipient: recipient,
            body: body,
            auditSubject: workflow.displayName,
            workflow: workflow,
            templateVersion: workflow == .technicianEnRoute && arrivalEstimate != nil
                ? "\(workflow.rawValue)-text-v2"
                : "\(workflow.rawValue)-text-v1",
            consentSnapshot: CustomerCommunicationConsentSnapshot(customer: call.customer),
            approximateArrivalMinutes: arrivalEstimate?.rawValue
        )
    }

    @MainActor
    static func contextIsValid(_ draft: CustomerServiceTextDraft, for call: ServiceCall) -> Bool {
        guard draft.customerID == call.customer.id,
              draft.serviceCallID == call.id,
              call.customer.allowsServiceText,
              normalizedRecipient(call.customer.phone) == draft.recipient,
              let current = self.draft(
                for: call,
                approximateArrivalMinutes: draft.approximateArrivalMinutes
              ) else { return false }
        return current.workflow == draft.workflow &&
        current.templateVersion == draft.templateVersion &&
        current.body == draft.body &&
        current.consentSnapshot == draft.consentSnapshot
    }

    nonisolated static func normalizedRecipient(_ value: String?) -> String? {
        let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        let digits = raw.filter(\.isNumber)
        guard (7...15).contains(digits.count) else { return nil }
        return raw.hasPrefix("+") ? "+\(digits)" : digits
    }
}

struct EnRouteHandoffSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var arrivalEstimate: EnRouteArrivalEstimate
    @State private var customerUpdateChannel: EnRouteCustomerUpdateChannel
    @State private var presentationDetent: PresentationDetent = .large

    let customerName: String
    let appointmentSummary: String
    let destinationAddress: String?
    let canDraftText: Bool
    let canDraftEmail: Bool
    let canOpenDirections: Bool
    let onOpenDirections: @MainActor () -> Void
    let onCommit: @MainActor (EnRouteHandoffSubmission) -> Void

    init(
        customerName: String,
        appointmentSummary: String,
        destinationAddress: String?,
        canDraftText: Bool,
        canDraftEmail: Bool,
        canOpenDirections: Bool,
        defaultArrivalEstimate: EnRouteArrivalEstimate = .thirty,
        defaultCustomerUpdateChannel: EnRouteCustomerUpdateChannel,
        onOpenDirections: @escaping @MainActor () -> Void,
        onCommit: @escaping @MainActor (EnRouteHandoffSubmission) -> Void
    ) {
        self.customerName = customerName
        self.appointmentSummary = appointmentSummary
        self.destinationAddress = destinationAddress
        self.canDraftText = canDraftText
        self.canDraftEmail = canDraftEmail
        self.canOpenDirections = canOpenDirections
        self.onOpenDirections = onOpenDirections
        self.onCommit = onCommit
        _arrivalEstimate = State(initialValue: defaultArrivalEstimate)
        _customerUpdateChannel = State(initialValue: defaultCustomerUpdateChannel)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    LabeledContent("Customer", value: customerName)
                    LabeledContent("Appointment", value: appointmentSummary)
                    if let destinationAddress {
                        Label(destinationAddress, systemImage: "mappin.and.ellipse")
                    } else {
                        Label("No job address is available.", systemImage: "mappin.slash")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        onOpenDirections()
                    } label: {
                        Label("Open Apple Maps", systemImage: "map")
                    }
                    .disabled(!canOpenDirections)
                    .accessibilityIdentifier("EnRouteOpenDirections")
                }

                Section("Approximate arrival") {
                    Picker("Staff estimate", selection: $arrivalEstimate) {
                        ForEach(EnRouteArrivalEstimate.allCases) { estimate in
                            Text(estimate.title).tag(estimate)
                        }
                    }
                    .accessibilityIdentifier("EnRouteArrivalEstimatePicker")

                    Text("This is a staff-selected estimate. It does not use live traffic or passive location tracking, and it does not change the promised appointment window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Customer update") {
                    Picker("After marking en route", selection: $customerUpdateChannel) {
                        ForEach(EnRouteCustomerUpdateChannel.allCases) { channel in
                            Label(channel.title, systemImage: channel.systemImage)
                                .tag(channel)
                                .disabled(!isAvailable(channel))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("EnRouteCustomerUpdatePicker")

                    if !canDraftText {
                        Text("Text requires service-message consent, a valid customer phone number, and Apple Messages on this device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !canDraftEmail {
                        Text("Email requires transactional-email consent and a customer email address.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Messages open as staff-reviewed drafts and are recorded as sent only after the provider confirms delivery.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }
            .navigationTitle("Start Travel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("CancelEnRouteHandoff")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Mark En Route") {
                        onCommit(EnRouteHandoffSubmission(
                            arrivalEstimate: arrivalEstimate,
                            customerUpdateChannel: customerUpdateChannel
                        ))
                        dismiss()
                    }
                    .accessibilityIdentifier("ConfirmEnRouteHandoff")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $presentationDetent)
        .presentationDragIndicator(.visible)
    }

    private func isAvailable(_ channel: EnRouteCustomerUpdateChannel) -> Bool {
        switch channel {
        case .none: true
        case .text: canDraftText
        case .email: canDraftEmail
        }
    }
}

enum CustomerServiceTextCapability {
    @MainActor
    static var canSendText: Bool {
        #if canImport(MessageUI) && !targetEnvironment(macCatalyst)
        MFMessageComposeViewController.canSendText()
        #else
        false
        #endif
    }
}

#if canImport(MessageUI) && !targetEnvironment(macCatalyst)
struct CustomerMessageComposer: UIViewControllerRepresentable {
    let draft: CustomerServiceTextDraft
    let onComplete: @MainActor (CustomerServiceTextOutcome) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.recipients = [draft.recipient]
        controller.body = draft.body
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onComplete: @MainActor (CustomerServiceTextOutcome) -> Void

        init(onComplete: @escaping @MainActor (CustomerServiceTextOutcome) -> Void) {
            self.onComplete = onComplete
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            let outcome: CustomerServiceTextOutcome
            switch result {
            case .sent:
                outcome = .sent(recipients: controller.recipients ?? [])
            case .cancelled:
                outcome = .cancelled
            case .failed:
                outcome = .failed
            @unknown default:
                outcome = .failed
            }
            controller.dismiss(animated: true) {
                Task { @MainActor in
                    self.onComplete(outcome)
                }
            }
        }
    }
}
#endif
