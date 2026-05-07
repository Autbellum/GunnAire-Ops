//
//  GunnAire_OpsTests.swift
//  GunnAire OpsTests
//
//  Created by Eric Gunn on 2/23/26.
//

import Testing
@testable import GunnAire_Ops
import Foundation

struct GunnAire_OpsTests {

    @Test func serviceCallIsUpcomingThisWeekForFutureDate() async throws {
        let customer = Customer(name: "Test Customer")
        let call = ServiceCall(
            type: .service,
            scheduledDate: Date().addingTimeInterval(60 * 60 * 24),
            customer: customer
        )

        #expect(call.isUpcomingThisWeek == true)
    }

    @Test func serviceCallIsNotUpcomingThisWeekForPastDate() async throws {
        let customer = Customer(name: "Test Customer")
        let call = ServiceCall(
            type: .service,
            scheduledDate: Date().addingTimeInterval(-60 * 60 * 24),
            customer: customer
        )

        #expect(call.isUpcomingThisWeek == false)
    }

    @Test func serviceCallIsNotUpcomingThisWeekForFarFutureDate() async throws {
        let customer = Customer(name: "Test Customer")
        let call = ServiceCall(
            type: .service,
            scheduledDate: Date().addingTimeInterval(60 * 60 * 24 * 14),
            customer: customer
        )

        #expect(call.isUpcomingThisWeek == false)
    }

    @Test func quickBooksMimeTypeDetection() async throws {
        #expect(QuickBooksDataAPI.mimeType(for: URL(fileURLWithPath: "/tmp/file.jpg")) == "image/jpeg")
        #expect(QuickBooksDataAPI.mimeType(for: URL(fileURLWithPath: "/tmp/file.pdf")) == "application/pdf")
        #expect(QuickBooksDataAPI.mimeType(for: URL(fileURLWithPath: "/tmp/file.unknown")) == "application/octet-stream")
    }

    @Test func quickBooksUploadBodyContainsExpectedParts() async throws {
        let boundary = "Boundary-Test"
        let filename = "receipt.jpg"
        let contentType = "image/jpeg"
        let fileData = Data([0x01, 0x02, 0x03])
        let metadataJSON = #"{"FileName":"receipt.jpg","ContentType":"image/jpeg","Note":"Uploaded from test"}"#

        let body = QuickBooksDataAPI.buildUploadBody(
            boundary: boundary,
            filename: filename,
            contentType: contentType,
            fileData: fileData,
            metadataJSON: metadataJSON
        )
        let bodyString = String(data: body, encoding: .utf8) ?? ""

        #expect(bodyString.contains("name=\"file_metadata_01\""))
        #expect(bodyString.contains(metadataJSON))
        #expect(bodyString.contains("name=\"file_content_01\"; filename=\"\(filename)\""))
        #expect(bodyString.contains("Content-Type: \(contentType)"))
        #expect(bodyString.contains("--\(boundary)--"))
    }

    @Test func splashVideoLocatorPrefersStoredVideoOverBundledVideo() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let storedURL = tempDirectory.appendingPathComponent("Loading.mp4")
        try Data([0x00, 0x01, 0x02]).write(to: storedURL)

        let bundledURL = URL(fileURLWithPath: "/tmp/bundled/Loading.mp4")
        let resolved = SplashVideoLocator.preferredURL(
            bundledURL: bundledURL,
            storedCandidates: [storedURL],
            fileManager: .default
        )

        #expect(resolved == storedURL)
    }

    @Test func splashVideoLocatorFallsBackToBundledVideoWhenStoredVideoMissing() async throws {
        let missingStoredURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Loading.mp4")
        let bundledURL = URL(fileURLWithPath: "/tmp/bundled/Loading.mp4")

        let resolved = SplashVideoLocator.preferredURL(
            bundledURL: bundledURL,
            storedCandidates: [missingStoredURL],
            fileManager: .default
        )

        #expect(resolved == bundledURL)
    }

    @Test func splashVideoPreferredDelayUsesFallbackForInvalidDuration() async throws {
        #expect(SplashVideoLocator.preferredFinishDelay(durationSeconds: 0) == 3.0)
        #expect(SplashVideoLocator.preferredFinishDelay(durationSeconds: .infinity) == 3.0)
    }

    @Test func splashVideoPreferredDelayCapsLongVideos() async throws {
        #expect(SplashVideoLocator.preferredFinishDelay(durationSeconds: 2.5) == 2.7)
        #expect(SplashVideoLocator.preferredFinishDelay(durationSeconds: 12) == 6.0)
    }

}
