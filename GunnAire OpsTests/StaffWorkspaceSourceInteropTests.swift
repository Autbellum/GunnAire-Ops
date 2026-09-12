import Foundation
import SwiftData
import XCTest
import CryptoKit
@testable import GunnAire_Ops

final class StaffWorkspaceSourceInteropTests: XCTestCase {
    struct Vector: Decodable {
        struct Remote: Decodable {
            let companyID: String
            let environment: String
            let replicaID: String
            let schema: String
            let schemaDigest: String
            let kind: String
            let id: String
            let revision: Int
            let deleted: Bool
            let fields: [String: StaffWorkspaceValue]
        }
        struct Page: Decodable {
            let schema: String
            let schemaDigest: String
            let companyID: String
            let environment: String
            let replicaID: String
            let sequence: Int
            let records: [Remote]
            let nextCursor: String?
        }
        let schema: [String: [String: StaffWorkspaceFieldSchema]]
        let original: [StaffWorkspaceModelRecord]
        let page: Page
    }

    private func vector() throws -> Vector {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "StaffWorkspaceSourceInterop", withExtension: "json"))
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    @MainActor func testPublicationDecoderAcceptsTheActualBackendPageWithoutDroppingAnyField() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "StaffWorkspaceSourceInterop", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(object["page"]))
        let page = try StaffWorkspacePublicationContract.decode(StaffWorkspacePublicationPage.self, from: data)
        let binding = CompanyCloudKitBinding(companyID: try XCTUnwrap(UUID(uuidString: page.companyID)),
            containerID: GunnAireCloudKit.containerIdentifier, environment: page.environment,
            replicaID: try XCTUnwrap(UUID(uuidString: page.replicaID)), cloudAccountHash: String(repeating: "a", count: 64),
            approvedAt: "2026-09-09T00:00:00Z")
        let scope = StaffReplicaSourceScope(backendOrigin: "https://fixture.example.invalid", actorEmail: "owner@example.invalid",
            binding: binding, storeUUID: UUID().uuidString)
        try StaffWorkspacePublicationContract.validateCatalog()
        try page.validate(scope, sequence: 1, after: nil)
        XCTAssertEqual(page.records.count, 32)
        XCTAssertEqual(page.records.reduce(0) { $0 + $1.fields.count }, 561)
        XCTAssertEqual(page.records.compactMap(\.live).sorted { $0.kind < $1.kind }, try vector().original.sorted { $0.kind < $1.kind })
    }

    @MainActor func testCurrentNativeFieldSchemaMatchesTheVersionedBackendDigest() throws {
        let vector = try vector()
        try StaffWorkspaceModelCatalog.validateSchema(GunnAireModelSchema.schema)
        let native = Dictionary(uniqueKeysWithValues: StaffWorkspaceModelCatalog.all.map { ($0.kind, $0.fieldSchema) })
        XCTAssertEqual(native, vector.schema)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(native)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, vector.page.schemaDigest)
        XCTAssertEqual(vector.page.schema, "owner-workspace-v1")
    }

    @MainActor func testActualBackendHTTPSourcePreservesAll32OriginalRecordsAndDetachedRelationships() throws {
        let vector = try vector()
        let page = vector.page
        XCTAssertEqual(page.sequence, 1)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.records.count, 32)
        XCTAssertEqual(page.records.reduce(0) { $0 + $1.fields.count }, 561)
        var records: [StaffWorkspaceModelRecord] = []
        for record in page.records {
            XCTAssertEqual(record.companyID, page.companyID)
            XCTAssertEqual(record.environment, page.environment)
            XCTAssertEqual(record.replicaID, page.replicaID)
            XCTAssertEqual(record.schema, page.schema)
            XCTAssertEqual(record.schemaDigest, page.schemaDigest)
            XCTAssertEqual(record.revision, 1)
            XCTAssertFalse(record.deleted)
            let id = try XCTUnwrap(UUID(uuidString: record.id))
            XCTAssertEqual(record.id, id.uuidString.lowercased())
            records.append(.init(version: 1, kind: record.kind, id: id, fields: record.fields))
        }
        XCTAssertEqual(records.sorted { $0.kind < $1.kind }, vector.original.sorted { $0.kind < $1.kind })
        _ = try StaffWorkspaceRelationshipGraph.validate(records)
        let models = try StaffWorkspaceModelCatalog.decodeDetached(records)
        let codecs = StaffWorkspaceModelCatalog.all
        for model in models {
            XCTAssertNil(model.modelContext)
            let codec = try XCTUnwrap(codecs.first { $0.modelName == String(describing: type(of: model)) })
            let encoded = try codec.encode(model)
            XCTAssertEqual(encoded, records.first { $0.kind == encoded.kind })
        }
    }

    @MainActor func testNativeFullCatalogExportsExactTypedBackendSchemaAndAll32OriginalRecords() throws {
        try StaffWorkspaceModelCatalog.validateSchema(GunnAireModelSchema.schema)
        let codecs = StaffWorkspaceModelCatalog.all
        XCTAssertEqual(codecs.count, 32)
        XCTAssertEqual(codecs.reduce(0) { $0 + $1.fieldSchema.count }, 561)
        let schema = Dictionary(uniqueKeysWithValues: codecs.map { ($0.kind, $0.fieldSchema) })
        let records = try StaffWorkspaceFullModelTests().encodedFixtures()
        _ = try StaffWorkspaceRelationshipGraph.validate(records)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        for (name, data) in [("Full owner typed schema", try encoder.encode(schema)),
                             ("Full owner original records", try encoder.encode(records))] {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
