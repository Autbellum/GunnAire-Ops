import Foundation
import LoadSightKit

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first, (["review", "csv", "validate", "ingest", "air-review", "envelope-review", "room-review", "change-review", "ops-review"].contains(command) && args.count == 2) || (["apply", "rfi-docx", "co-docx"].contains(command) && args.count == 4) || (["draft-pdf", "xlsx"].contains(command) && args.count == 3) else {
        throw LoadSightError.invalid("Usage: loadsight review|csv|validate|air-review|envelope-review|room-review|change-review|ops-review project.json; loadsight ingest drawing.pdf; loadsight xlsx|draft-pdf project.json new-output-file; loadsight rfi-docx|co-docx project.json record-id new-output.docx; loadsight apply project.json request.json new-project.json")
    }
    if command == "ingest" {
        let archive = try await DrawingIngestor().ingest(url: URL(fileURLWithPath: args[1]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(archive.records), as: UTF8.self))
        exit(0)
    }
    let project = try ProjectDocument(data: Data(contentsOf: URL(fileURLWithPath: args[1])))
    try project.validatePortableProject()
    switch command {
    case "co-docx":
        try ChangeOrderWordDocument.docx(project, changeOrderID: args[2]).write(to: URL(fileURLWithPath: args[3]), options: .withoutOverwriting)
        print("Change-order Word copy saved: \(args[3])")
    case "rfi-docx":
        try RFIWordDocument.docx(project, rfiID: args[2]).write(to: URL(fileURLWithPath: args[3]), options: .withoutOverwriting)
        print("RFI Word copy saved: \(args[3])")
    case "ops-review":
        let value = JSONValue.object(["context": project.root["opsContext"], "history": project.root["opsContextHistory"], "editFingerprint": .string(try project.opsContextEditFingerprint()), "authority": .string("Recorded local snapshot; not authenticated approval or billing publication")])
        print(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    case "change-review":
        let records = try project.changeOrders()
        let history = try project.changeOrderHistory()
        let result: JSONValue = .array(try records.map { record in
            .object(["editFingerprint": .string(try project.changeOrderEditFingerprint(id: record.id)), "history": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(history.filter { $0.changeOrderID == record.id })), "record": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(record)), "review": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(record.draft.review()))])
        })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    case "room-review":
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(project.roomTransmissionReview()), as: UTF8.self))
    case "envelope-review":
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(project.envelopeReview()), as: UTF8.self))
    case "air-review":
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(project.airProcessReview()), as: UTF8.self))
    case "xlsx":
        try TakeoffWorkbook.xlsx(project).write(to: URL(fileURLWithPath: args[2]), options: .withoutOverwriting)
        print("Workbook saved: \(args[2])")
    case "draft-pdf":
        try DraftProposal.pdf(project).write(to: URL(fileURLWithPath: args[2]), options: .withoutOverwriting)
        print("Draft PDF saved: \(args[2])")
    case "apply":
        let request = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let result = try ProjectEditing.apply(request, to: project)
        let output = URL(fileURLWithPath: args[3]).standardizedFileURL
        try ProjectEditing.writeNew(result.project, to: output)
        let summary: JSONValue = .object(["output": .string(output.path), "recordID": result.recordID.map(JSONValue.string) ?? .null, "operation": request["operation"], "status": .string("saved")])
        print(String(decoding: try JSONEncoder().encode(summary), as: UTF8.self))
    case "review":
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(EstimatePricing.review(project)), as: UTF8.self))
    case "csv": print(TakeoffExport.csv(project), terminator: "")
    default: print("Valid project: \(project.name); \(project.items.count) takeoff rows.")
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
