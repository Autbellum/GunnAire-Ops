// Synthetic simulator acceptance host. Never compiled into the production application.
import SwiftUI
import LoadSightUI
import LoadSightKit

private let catalogID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
private func record(_ cost: Double, date: String) -> OpsMaterialCatalogSnapshot {
    .init(id: catalogID, source: "Synthetic comparison catalog", name: "Synthetic duct", sku: "CMP-5FT", supplier: "Synthetic supplier", purchaseCost: cost, updatedAt: date)
}
@main
struct CatalogComparisonApp: App {
    @State private var document: LoadSightDocument = {
        var doc = LoadSightDocument()
        try! doc.project.replace("name", with: .string("Synthetic comparison project"))
        try! doc.project.replace("items", with: .array([.object([
            "id": .string("CMP-1"), "description": .string("Synthetic duct"), "unit": .string("LF"), "quantity": .number(10),
            "scope": .string("Base"), "lifecycle": .string("NEW"), "materialUnit": .number(10), "laborHoursUnit": .null
        ])]))
        let mapping = CatalogMaterialMapping(catalog: record(50, date: "2026-09-09T12:00:00Z"), currency: "USD", purchaseUnit: "five-foot length", catalogUnitsPerTakeoffUnit: 0.2, takeoffUnit: "LF", itemDescription: "Synthetic duct", lifecycle: "NEW", basis: "Synthetic original conversion")
        try! doc.project.updateCatalogMaterialMapping(itemID: "CMP-1", mapping: mapping, expectedFingerprint: doc.project.catalogMaterialEditFingerprint(itemID: "CMP-1"), author: "Fixture", reason: "Initial synthetic state")
        return doc
    }()
    var body: some Scene {
        WindowGroup { LoadSightWorkspaceView(document: $document, catalogMaterials: [record(75, date: "2026-09-10T12:00:00Z")]) }
    }
}
