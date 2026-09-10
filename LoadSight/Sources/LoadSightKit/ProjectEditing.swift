import Foundation

public extension ProjectDocument {
    func validateDrawingEvidence(in drawings: DrawingArchive) throws {
        try validate(); _ = try airNetwork(); _ = try envelopeAssemblies(); _ = try roomTransmissions(); try drawings.validate(); try validateMarkupQuantities()
        try validateScheduleMaps(in: drawings)
        let ledger = try markupLedger()
        let pages = Dictionary(uniqueKeysWithValues: drawings.records.flatMap(\.pages).map { ($0.id, $0) })
        func check(_ point: PagePoint, pageID: String) throws {
            guard let page = pages[pageID] else { throw LoadSightError.invalid("Markup references a missing drawing page.") }
            let b = page.bounds
            try require(point.x.isFinite && point.y.isFinite && point.x >= b.x && point.x <= b.x + b.width && point.y >= b.y && point.y <= b.y + b.height, "Markup point is outside its source page.")
        }
        for object in ledger.objects { for anchor in object.anchors { try check(anchor.point, pageID: anchor.pageID) } }
        for view in ledger.views { try check(view.min, pageID: view.pageID); try check(view.max, pageID: view.pageID) }
    }
    func validatePortableProject() throws {
        try validateDrawingEvidence(in: DrawingArchive(projectJSON: root["nativeDrawings"]))
    }
}

public struct ProjectEditResult: Sendable {
    public let project: ProjectDocument
    public let recordID: String?
}

/// Structured local commands use the same lifecycle methods as the native app.
public enum ProjectEditing {
    public static func apply(_ request: JSONValue, to project: ProjectDocument) throws -> ProjectEditResult {
        try project.validatePortableProject()
        guard let fields = request.object else { throw LoadSightError.invalid("Edit request must be a JSON object.") }
        func text(_ key: String) throws -> String {
            guard let value = fields[key]?.string else { throw LoadSightError.invalid("Edit request requires text field: \(key).") }
            return value
        }
        func number(_ key: String) throws -> Double {
            guard let value = fields[key]?.number, value.isFinite else { throw LoadSightError.invalid("Edit request requires numeric field: \(key).") }
            return value
        }
        func classification(_ key: String) throws -> AirInputClassification {
            guard let value = AirInputClassification(rawValue: try text(key)) else { throw LoadSightError.invalid("Unknown air-input classification: \(key).") }
            return value
        }
        let operation = try text("operation"), author = try text("author")
        let payloadKeys: [String]
        switch operation {
        case "schedule.map.save": payloadKeys = ["id", "name", "request", "expectedFingerprint", "reason"]
        case "schedule.map.remove": payloadKeys = ["id", "expectedFingerprint", "reason"]
        case "schedule.rfi.create": payloadKeys = ["request", "rowID", "findingID", "question", "impact"]
        case "text.rfi.create": payloadKeys = ["candidateID", "question", "impact"]
        case "catalog.material.update": payloadKeys = ["id", "mapping", "expectedFingerprint", "reason"]
        case "ops.context.update": payloadKeys = ["context", "expectedFingerprint", "reason"]
        case "changeorder.create": payloadKeys = ["draft"]
        case "changeorder.revise": payloadKeys = ["id", "expectedFingerprint", "reason", "draft"]
        case "room.transmission.revise": payloadKeys = ["id", "expectedFingerprint", "reason", "name", "source", "indoorDesignF", "surfaces"]
        case "room.transmission.create": payloadKeys = ["name", "source", "indoorDesignF", "surfaces"]
        case "assembly.create": payloadKeys = ["name", "source", "construction", "filmBasis", "paths"]
        case "aircondition.derive": payloadKeys = ["processID", "name", "source"]
        case "aircondition.create": payloadKeys = ["name", "source", "dryBulbC", "relativeHumidity", "humidityInput", "pressurePa", "dryBulbClassification", "humidityClassification", "pressureClassification"]
        case "airprocess.create": payloadKeys = ["name", "source", "kind", "firstConditionID", "secondConditionID", "firstActualCFM", "secondActualCFM", "flowClassification"]
        case "rfi.create": payloadKeys = ["title", "question", "source", "impact", "priority", "itemIDs", "communication"]
        case "rfi.edit": payloadKeys = ["id", "title", "question", "source", "impact", "priority", "itemIDs", "communication"]
        case "rfi.resolve": payloadKeys = ["id", "response", "responseSource", "respondent"]
        case "rfi.reopen": payloadKeys = ["id", "reason"]
        case "commercial.update": payloadKeys = ["name", "estimator", "fields", "basis"]
        case "proposal.update": payloadKeys = ["fields", "source"]
        case "item.review": payloadKeys = ["id", "scope", "status", "allowanceNote", "evidence"]
        case "qa.review": payloadKeys = ["id", "complete", "evidence"]
        case "attachment.add": payloadKeys = ["filename", "dataBase64", "source", "rfiID"]
        default: throw LoadSightError.invalid("Unsupported edit operation: \(operation).")
        }
        try require(Set(fields.keys).isSubset(of: Set(payloadKeys + ["operation", "author"])), "Unexpected edit fields; check the request for misspelled keys.")
        var copy = project
        var recordID: String?
        switch operation {
        case "schedule.map.save":
            guard let rawID = fields["id"], rawID == .null || rawID.string.flatMap(UUID.init(uuidString:)) != nil else { throw LoadSightError.invalid("Supply id as null for a new map, or an existing map UUID.") }
            guard let raw = fields["request"] else { throw LoadSightError.invalid("Supply the complete schedule request.") }
            let map = try EquipmentScheduleRequest.decode(JSONEncoder().encode(raw))
            let archive = try DrawingArchive(projectJSON: copy.root["nativeDrawings"])
            recordID = try copy.saveScheduleMap(id: rawID.string.flatMap(UUID.init(uuidString:)), name: text("name"), request: map, drawings: archive, expectedFingerprint: text("expectedFingerprint"), author: author, reason: text("reason")).uuidString
        case "schedule.map.remove":
            guard let id = UUID(uuidString: try text("id")) else { throw LoadSightError.invalid("Supply a saved map UUID.") }
            let archive = try DrawingArchive(projectJSON: copy.root["nativeDrawings"])
            try copy.removeScheduleMap(id: id, drawings: archive, expectedFingerprint: text("expectedFingerprint"), author: author, reason: text("reason"))
            recordID = id.uuidString
        case "schedule.rfi.create":
            guard let raw = fields["request"] else { throw LoadSightError.invalid("Supply the complete schedule column request.") }
            let map = try EquipmentScheduleRequest.decode(JSONEncoder().encode(raw))
            let archive = try DrawingArchive(projectJSON: copy.root["nativeDrawings"]), rowID = try text("rowID")
            guard let row = try EquipmentScheduleExtractor.extract(archive, request: map).rows.first(where: { $0.id == rowID }) else {
                throw LoadSightError.invalid("Schedule row is missing or changed. Read the current schedule again.")
            }
            recordID = try copy.createRFI(from: row, findingID: text("findingID"), drawings: archive,
                                        question: text("question"), impact: text("impact"), author: author)
        case "text.rfi.create":
            let archive = try DrawingArchive(projectJSON: copy.root["nativeDrawings"])
            let candidateID = try text("candidateID")
            guard let candidate = try MechanicalTextExtractor.extract(archive).candidates.first(where: { $0.id == candidateID }) else {
                throw LoadSightError.invalid("Text candidate is missing or changed. Review the project's current drawing extraction again.")
            }
            recordID = try copy.createRFI(from: candidate, drawings: archive, question: text("question"), impact: text("impact"), author: author)
        case "catalog.material.update":
            guard let raw = fields["mapping"] else { throw LoadSightError.invalid("Supply mapping explicitly, or null to remove a catalog link.") }
            var mapping: CatalogMaterialMapping?
            if raw != .null {
                func exact(_ value: JSONValue, _ keys: [String]) throws {
                    try require(value.object.map { Set($0.keys) == Set(keys) } == true, "Catalog mapping objects must contain exactly their documented fields.")
                }
                try exact(raw, ["version", "catalog", "currency", "purchaseUnit", "catalogUnitsPerTakeoffUnit", "takeoffUnit", "itemDescription", "lifecycle", "basis"] + (raw.object?["quote"] != nil ? ["quote"] : []))
                if raw["quote"] != .null { try exact(raw["quote"], ["supplier", "reference", "source", "issuedAt", "validUntil", "conditions"]) }
                try exact(raw["catalog"], ["id", "source", "name", "sku", "supplier", "supplierPartNumber", "purchaseCost", "updatedAt"])
                mapping = try JSONDecoder().decode(CatalogMaterialMapping.self, from: JSONEncoder().encode(raw))
            }
            let id = try text("id")
            try copy.updateCatalogMaterialMapping(itemID: id, mapping: mapping, expectedFingerprint: text("expectedFingerprint"), author: author, reason: text("reason"))
            recordID = id
        case "ops.context.update":
            guard let raw = fields["context"] else { throw LoadSightError.invalid("Supply context explicitly, or null to remove a link.") }
            var context: OpsProjectContext?
            if raw != .null {
                func exact(_ value: JSONValue, _ keys: [String]) throws {
                    try require(value.object.map { Set($0.keys) == Set(keys) } == true, "Ops context objects must contain exactly their documented fields.")
                }
                try exact(raw, ["version", "customer", "job"])
                try exact(raw["customer"], ["id", "name", "address"])
                if raw["job"] != .null { try exact(raw["job"], ["id", "customerID", "title", "siteAddress", "serviceLocationID"]) }
                context = try JSONDecoder().decode(OpsProjectContext.self, from: JSONEncoder().encode(raw))
            }
            try copy.updateOpsContext(context, expectedFingerprint: text("expectedFingerprint"), author: author, reason: text("reason"))
        case "changeorder.create", "changeorder.revise":
            let draft = fields["draft"] ?? .null
            func exact(_ value: JSONValue, _ keys: [String]) throws {
                try require(value.object.map { Set($0.keys) == Set(keys) } == true, "Change draft objects must contain exactly their documented fields.")
            }
            try exact(draft, ["number", "date", "customer", "entitlement", "entitlementBasis", "originalScope", "proposedScope", "drawingRevision", "rfiIDs", "auditReference", "quantities", "costs", "markupPercent", "markupBasis", "tax", "bond", "timeImpact", "exclusions", "approvalLanguage"])
            func amount(_ value: JSONValue) throws { try exact(value, ["amount", "source"]) }
            guard let quantities = draft["quantities"].array, let costs = draft["costs"].array else { throw LoadSightError.invalid("Change quantities and costs must be arrays.") }
            for row in quantities {
                try exact(row, ["name", "unit", "original", "proposed"])
                try amount(row["original"]); try amount(row["proposed"])
            }
            for row in costs { try exact(row, ["category", "delta"]); try amount(row["delta"]) }
            for key in ["markupPercent", "tax", "bond"] { try amount(draft[key]) }
            let decoded = try JSONDecoder().decode(ChangeOrderDraft.self, from: JSONEncoder().encode(draft))
            if operation == "changeorder.revise" { recordID = try copy.reviseChangeOrder(id: text("id"), expectedFingerprint: text("expectedFingerprint"), draft: decoded, author: author, reason: text("reason")) }
            else { recordID = try copy.createChangeOrder(decoded, author: author) }
        case "room.transmission.create", "room.transmission.revise":
            func scalar(_ value: JSONValue?) throws {
                try require(value?.object.map { Set($0.keys) == Set(["value","source","classification"]) } == true, "Sourced values require value, source and classification only.")
            }
            try scalar(fields["indoorDesignF"])
            guard let surfaces = fields["surfaces"]?.array else { throw LoadSightError.invalid("Room surfaces must be an array.") }
            for surface in surfaces {
                guard let row = surface.object, Set(row.keys) == Set(["name","assemblyID","grossAreaSF","openings","adjacentDesignF"]), let openings = row["openings"]?.array else { throw LoadSightError.invalid("Each surface requires name, assemblyID, grossAreaSF, openings and adjacentDesignF only.") }
                try scalar(row["grossAreaSF"]); try scalar(row["adjacentDesignF"])
                for opening in openings {
                    try require(opening.object.map { Set(["name","areaSF"]).isSubset(of:Set($0.keys)) && Set($0.keys).isSubset(of:Set(["name","areaSF","wholeProductU"])) } == true, "Each opening requires name and areaSF, with optional wholeProductU only.")
                    if let rating = opening.object?["wholeProductU"], rating != .null { try scalar(rating) }
                    try scalar(opening.object?["areaSF"])
                }
            }
            let indoor = try JSONDecoder().decode(SourcedEngineeringValue.self, from:JSONEncoder().encode(fields["indoorDesignF"]!))
            let decoded = try JSONDecoder().decode([RoomEnvelopeSurface].self, from:JSONEncoder().encode(JSONValue.array(surfaces)))
            if operation == "room.transmission.revise" {
                recordID = try copy.reviseRoomTransmission(id:text("id"),expectedFingerprint:text("expectedFingerprint"),reason:text("reason"),name:text("name"),author:author,source:text("source"),indoorDesignF:indoor,surfaces:decoded)
            } else { recordID = try copy.saveRoomTransmission(name:text("name"),author:author,source:text("source"),indoorDesignF:indoor,surfaces:decoded) }
        case "assembly.create":
            guard let construction = EnvelopeConstruction(rawValue: try text("construction")), let paths = fields["paths"]?.array else { throw LoadSightError.invalid("Assembly requires a supported construction and paths array.") }
            for path in paths {
                guard let row = path.object, Set(row.keys) == Set(["name", "fraction", "fractionSource", "fractionClassification", "layers"]), let layers = row["layers"]?.array else { throw LoadSightError.invalid("Each path requires name, fraction, fractionSource, fractionClassification and layers only.") }
                for layer in layers {
                    try require(layer.object.map { Set($0.keys) == Set(["name", "resistance", "source", "classification"]) } == true, "Each layer requires name, resistance, source and classification only.")
                }
            }
            let decoded = try JSONDecoder().decode([EnvelopePath].self, from: JSONEncoder().encode(JSONValue.array(paths)))
            recordID = try copy.saveEnvelopeAssembly(name: text("name"), author: author, source: text("source"), construction: construction, filmBasis: text("filmBasis"), paths: decoded)
        case "aircondition.derive":
            recordID = try copy.saveMixedAirOutput(processID:text("processID"),name:text("name"),author:author,source:text("source"))
        case "aircondition.create":
            let humidity: HumidityInput
            if let input = fields["humidityInput"] {
                try require(fields["relativeHumidity"] == nil, "Supply either relativeHumidity or humidityInput, not both.")
                guard let object = input.object, Set(object.keys) == Set(["kind", "value"]),
                      let raw = object["kind"]?.string, let kind = HumidityInputKind(rawValue: raw),
                      let value = object["value"]?.number, value.isFinite else { throw LoadSightError.invalid("humidityInput requires a valid kind and numeric value.") }
                humidity = .init(kind:kind,value:value)
            } else { humidity = .init(kind:.relativeHumidity,value:try number("relativeHumidity")) }
            try copy.saveAirCondition(name: text("name"), author: author, source: text("source"), dryBulbC: number("dryBulbC"),
                humidity: humidity, pressurePa: number("pressurePa"), dryBulbClassification: classification("dryBulbClassification"),
                humidityClassification: classification("humidityClassification"), pressureClassification: classification("pressureClassification"))
            recordID = try copy.airConditions().last?.id
        case "airprocess.create":
            guard let kind = AirProcessKind(rawValue: try text("kind")) else { throw LoadSightError.invalid("Unknown air process kind.") }
            try require(fields["secondActualCFM"] == .null || fields["secondActualCFM"]?.number != nil, "secondActualCFM must be numeric for mixing or null for cooling.")
            try copy.saveAirProcess(name: text("name"), author: author, source: text("source"), kind: kind,
                firstConditionID: text("firstConditionID"), secondConditionID: text("secondConditionID"), firstActualCFM: number("firstActualCFM"),
                secondActualCFM: fields["secondActualCFM"]?.number, flowClassification: classification("flowClassification"))
            recordID = try copy.airProcesses().last?.id
        case "rfi.create", "rfi.edit":
            guard let links = fields["itemIDs"]?.array, links.allSatisfy({ $0.string != nil }) else { throw LoadSightError.invalid("itemIDs must be an array of takeoff IDs, or an empty array.") }
            var communication: RFICommunication?
            if let supplied = fields["communication"] {
                try require(supplied.object.map { Set($0.keys) == Set(RFICommunication.fields.map(\.id)) } == true, "RFI communication requires to, from, date, requiredResponseDate and suggestedResolution only; use blank strings for unknown values.")
                communication = try JSONDecoder().decode(RFICommunication.self, from: JSONEncoder().encode(supplied))
            }
            recordID = try copy.saveRFI(id: operation == "rfi.edit" ? text("id") : nil,
                draft: .init(title: text("title"), question: text("question"), source: text("source"), impact: text("impact"), priority: text("priority"), itemIDs: links.compactMap(\.string), communication: communication), author: author)
        case "rfi.resolve":
            recordID = try text("id")
            try copy.resolveRFI(id: recordID!, response: text("response"), responseSource: text("responseSource"), respondent: text("respondent"), author: author)
        case "rfi.reopen":
            recordID = try text("id")
            try copy.reopenRFI(id: recordID!, reason: text("reason"), author: author)
        case "proposal.update":
            guard let values = fields["fields"]?.object, values.values.allSatisfy({ $0.string != nil }) else { throw LoadSightError.invalid("Proposal fields must contain text values.") }
            try copy.updateProposalDetails(values.mapValues { $0.string! }, author: author, source: text("source"))
        case "item.review":
            guard let status = QuantityReviewStatus(rawValue: try text("status")) else { throw LoadSightError.invalid("Unknown quantity-review status.") }
            recordID = try text("id")
            try copy.reviewItem(id: recordID!, scope: text("scope"), status: status, allowanceNote: text("allowanceNote"), reviewer: author, evidence: text("evidence"))
        case "qa.review":
            guard case .bool(let complete) = fields["complete"] else { throw LoadSightError.invalid("QA complete must be true or false.") }
            recordID = try text("id")
            try copy.recordQACheck(id: recordID!, reviewer: author, evidence: text("evidence"), complete: complete)
        case "attachment.add":
            guard let data = Data(base64Encoded: try text("dataBase64")) else { throw LoadSightError.invalid("Attachment dataBase64 is invalid.") }
            try require(fields["rfiID"] == .null || fields["rfiID"]?.string != nil, "Attachment rfiID must be an existing identity or null.")
            recordID = try copy.addAttachment(data: data, filename: text("filename"), author: author, source: text("source"), rfiID: fields["rfiID"]?.string)
        default:
            guard let values = fields["fields"]?.object else { throw LoadSightError.invalid("Commercial fields must be an object.") }
            try copy.updateCommercialInputs(name: text("name"), estimator: text("estimator"), fields: values, basis: text("basis"), author: author)
        }
        try copy.validatePortableProject()
        return .init(project: copy, recordID: recordID)
    }

    /// Publish a complete new file without replacing any existing path, including symlinks.
    public static func writeNew(_ project: ProjectDocument, to output: URL) throws {
        try project.validatePortableProject()
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".loadsight-" + UUID().uuidString + ".tmp")
        let manager = FileManager.default
        defer { try? manager.removeItem(at: temporary) }
        try project.data().write(to: temporary, options: .withoutOverwriting)
        // A same-directory hard link publishes the finished file and fails if destination exists.
        try manager.linkItem(at: temporary, to: output)
    }
}
