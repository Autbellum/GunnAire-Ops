import Foundation
import SwiftData
import CloudKit

/// The private database is the durable SwiftData replica for the company-owned
/// iPad and Mac signed in to the same approved business iCloud account.
/// Company-user authorization remains enforced by the GunnAire backend.
enum GunnAireCloudKit {
    static let containerIdentifier = "iCloud.com.gunnaire.businesssuite"

    enum AccountReadiness: Equatable, Sendable {
        case available
        case unavailable
        case restricted
        case couldNotDetermine

        var isReady: Bool {
            self == .available
        }

        var statusTitle: String {
            switch self {
            case .available:
                "Ready"
            case .unavailable:
                "Sign in required"
            case .restricted:
                "Restricted"
            case .couldNotDetermine:
                "Check required"
            }
        }

        var userFacingDetail: String {
            switch self {
            case .available:
                "This device is signed in to iCloud and can use the GunnAire CloudKit container."
            case .unavailable:
                "Sign in to the approved business iCloud account in Settings, then reopen GunnAire Ops before relying on cross-device continuity."
            case .restricted:
                "iCloud access is restricted on this device. Remove the restriction or use an approved company device before relying on cross-device continuity."
            case .couldNotDetermine:
                "GunnAire Ops could not verify iCloud on this device. Check the network and iCloud account, then refresh this screen."
            }
        }
    }

    static func accountReadiness() async -> AccountReadiness {
        do {
            switch try await CKContainer(identifier: containerIdentifier).accountStatus() {
            case .available:
                return .available
            case .noAccount:
                return .unavailable
            case .restricted:
                return .restricted
            case .couldNotDetermine, .temporarilyUnavailable:
                return .couldNotDetermine
            @unknown default:
                return .couldNotDetermine
            }
        } catch {
            return .couldNotDetermine
        }
    }

    private static var usesTestDatabase: Bool {
        #if DEBUG
        // UI tests run in an unsigned simulator process without the production
        // CloudKit entitlement. This switch is compiled out of release builds.
        let processInfo = ProcessInfo.processInfo
        if processInfo.arguments.contains("-disableCloudKitForTesting") ||
            processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        #endif
        return false
    }

    private static var database: ModelConfiguration.CloudKitDatabase {
        if usesTestDatabase {
            return .none
        }
        return .private(containerIdentifier)
    }

    /// Always uses the signed app's production private database. This is kept
    /// separate so automated tests can prove release configuration without
    /// attempting to attach an unsigned XCTest host to iCloud.
    static func productionModelConfiguration(for schema: Schema) -> ModelConfiguration {
        ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private(containerIdentifier)
        )
    }

    static func modelConfiguration(for schema: Schema) -> ModelConfiguration {
        guard usesTestDatabase else {
            return productionModelConfiguration(for: schema)
        }
        return ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
    }
}
