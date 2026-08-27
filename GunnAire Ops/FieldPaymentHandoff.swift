import Foundation
import UIKit

/// Hands a payment-collection context from the office iPad to a company iPhone
/// through Apple's Handoff. No card data, customer contact details, or payment
/// credentials leave the originating device in the activity payload.
@MainActor
final class FieldPaymentHandoff {
    static let activityType = "com.gunnaire.businesssuite.field-payment-handoff"
    static let requirementsDetail = "Handoff requires the nearby iPad and iPhone to use the same approved business Apple Account, with Wi-Fi, Bluetooth, and Handoff enabled."
    static let quickBooksTapToPayDetail = "For contactless payment, open the matching QuickBooks invoice in QuickBooks Mobile or GoPayment on the field iPhone. Intuit currently provides Tap to Pay there, rather than as an embedded custom-app capture flow."
    static let shared = FieldPaymentHandoff()

    private var currentActivity: NSUserActivity?

    private init() {}

    var canStartFromCurrentDevice: Bool {
        #if !targetEnvironment(macCatalyst)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    @discardableResult
    func begin(invoiceID: UUID, amount: Double) -> Bool {
        guard canStartFromCurrentDevice, amount > 0 else { return false }

        let activity = NSUserActivity(activityType: Self.activityType)
        activity.title = "Collect field payment"
        // The destination resolves the current balance from its authorized local
        // invoice. Do not place customer or financial values in Handoff metadata.
        activity.userInfo = ["invoiceID": invoiceID.uuidString]
        activity.requiredUserInfoKeys = ["invoiceID"]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.isEligibleForPrediction = false
        activity.becomeCurrent()
        currentActivity?.resignCurrent()
        currentActivity = activity
        return true
    }

    static func invoiceID(from activity: NSUserActivity) -> UUID? {
        guard activity.activityType == activityType,
              let rawID = activity.userInfo?["invoiceID"] as? String else {
            return nil
        }
        return UUID(uuidString: rawID)
    }
}
