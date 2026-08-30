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

enum CustomerServiceTextPolicy {
    @MainActor
    static func draft(for call: ServiceCall) -> CustomerServiceTextDraft? {
        guard call.status == .scheduled || call.status == .inProgress,
              call.customer.allowsServiceText,
              let recipient = normalizedRecipient(call.customer.phone) else { return nil }

        let workflow: GunnAireMailWorkflow
        let update: String
        switch call.technicianJobPresence {
        case .scheduled:
            workflow = .appointmentConfirmation
            update = "Your service appointment is confirmed."
        case .enRoute:
            workflow = .technicianEnRoute
            update = "Your GunnAire technician is on the way."
        case .onSite:
            workflow = .technicianArrival
            update = "Your GunnAire technician has arrived."
        case .working:
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
            templateVersion: "\(workflow.rawValue)-text-v1",
            consentSnapshot: CustomerCommunicationConsentSnapshot(customer: call.customer)
        )
    }

    @MainActor
    static func contextIsValid(_ draft: CustomerServiceTextDraft, for call: ServiceCall) -> Bool {
        guard draft.customerID == call.customer.id,
              draft.serviceCallID == call.id,
              call.customer.allowsServiceText,
              normalizedRecipient(call.customer.phone) == draft.recipient,
              let current = self.draft(for: call) else { return false }
        return current.workflow == draft.workflow && current.templateVersion == draft.templateVersion
    }

    nonisolated static func normalizedRecipient(_ value: String?) -> String? {
        let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        let digits = raw.filter(\.isNumber)
        guard (7...15).contains(digits.count) else { return nil }
        return raw.hasPrefix("+") ? "+\(digits)" : digits
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
