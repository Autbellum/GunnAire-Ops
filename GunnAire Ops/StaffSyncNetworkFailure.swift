import Foundation
import CloudKit
import CFNetwork

/// Positive transport evidence only. Unknown, TLS, permission, cancellation,
/// HTTP and mixed CloudKit partial failures must never grant cached access.
enum StaffSyncNetworkFailure {
    static func isTransient(_ error: Error, depth: Int = 0) -> Bool {
        guard depth < 4 else { return false }
        let value = error as NSError
        let recognized: Bool
        if value.domain == NSURLErrorDomain {
            recognized = [URLError.Code.notConnectedToInternet, .networkConnectionLost,
                          .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
                .contains { $0.rawValue == value.code }
        } else if value.domain == kCFErrorDomainCFNetwork as String {
            // URLSession can include the same public CFURL error as its
            // underlying cause. Keep the allowlist just as narrow at this layer.
            recognized = [CFNetworkErrors.cfurlErrorNotConnectedToInternet, .cfurlErrorNetworkConnectionLost,
                          .cfurlErrorTimedOut, .cfurlErrorCannotConnectToHost, .cfurlErrorCannotFindHost, .cfurlErrorDNSLookupFailed]
                .contains { Int($0.rawValue) == value.code }
        } else if value.domain == CKErrorDomain {
            recognized = [CKError.Code.networkUnavailable, .networkFailure].contains { $0.rawValue == value.code }
        } else { return false }
        guard recognized, value.userInfo[CKPartialErrorsByItemIDKey] == nil else { return false }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] {
            guard let underlying = underlying as? Error else { return false }
            return isTransient(underlying, depth: depth + 1)
        }
        return true
    }
}
