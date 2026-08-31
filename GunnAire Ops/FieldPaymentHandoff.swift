import Foundation
import Combine
import UIKit

/// Hands a payment-collection context from the office iPad or Mac to a company
/// iPhone through Apple's Handoff. No card data, customer contact details, or
/// payment credentials leave the originating device in the activity payload.
@MainActor
final class FieldPaymentHandoff: ObservableObject {
    static let activityType = "com.gunnaire.businesssuite.field-payment-handoff"
    static let requirementsDetail = "Handoff requires the nearby iPad or Mac and iPhone to use the same approved business Apple Account, with Wi-Fi, Bluetooth, and Handoff enabled."
    static let quickBooksTapToPayDetail = "For contactless payment, open the matching QuickBooks invoice in QuickBooks Mobile or GoPayment on the field iPhone. Intuit currently provides Tap to Pay on iPhone there, rather than as an embedded custom-app capture flow."
    static let quickBooksTapToPaySteps = [
        "Open or install QuickBooks Mobile or GoPayment on this iPhone.",
        "Open Invoice payments from the app's Menu or Sales area.",
        "Find and select the invoice using the reference below.",
        "Choose Charge, then Tap to Pay on iPhone, and follow the on-screen prompts."
    ]
    static let quickBooksMobileAppStoreURL = URL(
        string: "https://apps.apple.com/us/app/intuit-quickbooks-for-business/id584606479"
    )!
    static let goPaymentAppStoreURL = URL(
        string: "https://apps.apple.com/us/app/quickbooks-gopayment-pos/id324389392"
    )!
    static let validityDuration: TimeInterval = 30 * 60
    static let shared = FieldPaymentHandoff()

    @Published private(set) var activeInvoiceID: UUID?
    private var currentActivity: NSUserActivity?
    private var expirationTask: Task<Void, Never>?

    private init() {}

    var canStartFromCurrentDevice: Bool {
        #if targetEnvironment(macCatalyst)
        Self.supportsOrigin(isMacCatalyst: true, isPad: false)
        #else
        Self.supportsOrigin(
            isMacCatalyst: false,
            isPad: UIDevice.current.userInterfaceIdiom == .pad
        )
        #endif
    }

    static func supportsOrigin(isMacCatalyst: Bool, isPad: Bool) -> Bool {
        isMacCatalyst || isPad
    }

    @discardableResult
    func begin(invoiceID: UUID, amount: Double) -> Bool {
        guard canStartFromCurrentDevice, amount > 0 else { return false }

        end()
        let activity = Self.makeActivity(invoiceID: invoiceID)
        activity.becomeCurrent()
        currentActivity = activity
        activeInvoiceID = invoiceID
        expirationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.validityDuration))
            guard !Task.isCancelled else { return }
            self?.end(invoiceID: invoiceID)
        }
        return true
    }

    func end(invoiceID: UUID? = nil) {
        guard invoiceID == nil || activeInvoiceID == invoiceID else { return }
        expirationTask?.cancel()
        expirationTask = nil
        currentActivity?.invalidate()
        currentActivity = nil
        activeInvoiceID = nil
    }

    static func makeActivity(invoiceID: UUID, now: Date = Date()) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        activity.title = "Collect field payment"
        // The destination resolves the current balance from its authorized local
        // invoice. Do not place customer or financial values in Handoff metadata.
        activity.userInfo = ["invoiceID": invoiceID.uuidString]
        activity.requiredUserInfoKeys = ["invoiceID"]
        activity.expirationDate = now.addingTimeInterval(validityDuration)
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.isEligibleForPrediction = false
        return activity
    }

    static func invoiceID(from activity: NSUserActivity, now: Date = Date()) -> UUID? {
        guard activity.activityType == activityType,
              let expirationDate = activity.expirationDate,
              expirationDate > now,
              let rawID = activity.userInfo?["invoiceID"] as? String else {
            return nil
        }
        return UUID(uuidString: rawID)
    }

    static func invoiceReference(quickBooksID: String?, localID: UUID) -> String {
        let normalizedQuickBooksID = quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalizedQuickBooksID.isEmpty
            ? String(localID.uuidString.prefix(8))
            : normalizedQuickBooksID
    }

    /// QuickBooks Mobile and GoPayment can collect against an invoice only
    /// after QBO has assigned its provider identifier. A local UUID remains a
    /// safe GunnAire handoff key, but it must never be presented as though it
    /// were a searchable QuickBooks invoice reference.
    static func quickBooksInvoiceReference(_ quickBooksID: String?) -> String? {
        let normalized = quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }
}
