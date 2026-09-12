import Testing
import Foundation
import CloudKit
@testable import GunnAire_Ops

// Boundary cases drafted by the pinned local Ollama helper, then reviewed and
// simplified here. Only the real production classifier is exercised.
@MainActor struct StaffSyncNetworkFailureTests {
    @Test func nestedUnderlyingErrorDepthBoundary() {
        var error = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        for _ in 0..<3 {
            error = NSError(domain: NSURLErrorDomain, code: URLError.networkConnectionLost.rawValue,
                userInfo: [NSUnderlyingErrorKey: error])
        }
        #expect(StaffSyncNetworkFailure.isTransient(error))
        let tooDeep = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
            userInfo: [NSUnderlyingErrorKey: error])
        #expect(!StaffSyncNetworkFailure.isTransient(tooDeep))
    }

    @Test func recognizedNetworkErrorWrappingPermissionError() {
        let error = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue,
            userInfo: [NSUnderlyingErrorKey: CKError(.permissionFailure)])
        #expect(!StaffSyncNetworkFailure.isTransient(error))
    }

    @Test func malformedNonErrorUnderlyingMetadata() {
        let error = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue,
            userInfo: [NSUnderlyingErrorKey: "not an error"])
        #expect(!StaffSyncNetworkFailure.isTransient(error))
    }
}
