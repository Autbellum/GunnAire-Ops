import Foundation
import LoadSightCore

public enum WorkLifecycle: String, Codable, CaseIterable, Sendable {
    case new = "New", remove = "Remove", reuse = "Reuse", relocate = "Relocate"
    case existing = "Existing to remain", protect = "Protect", rebalance = "Rebalance"
}

public struct TakeoffDescriptor: Codable, Equatable, Sendable {
    public var label: String
    public var lifecycle: WorkLifecycle
    public var system: String
    public var size: String
    public init(label: String, lifecycle: WorkLifecycle, system: String, size: String = "") {
        self.label = label; self.lifecycle = lifecycle; self.system = system; self.size = size
    }
    public func validate() throws {
        try require(!label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Name the measured or counted item.")
        try require(!system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Identify the mechanical system.")
    }
}

public struct DrawingAnchor: Codable, Equatable, Sendable {
    public var pageID: String
    public var point: PagePoint
    public var author: String
    public init(pageID: String, point: PagePoint, author: String) {
        self.pageID = pageID; self.point = point; self.author = author
    }
}

public struct CountedObject: Codable, Identifiable, Sendable {
    public var id: String
    public var descriptor: TakeoffDescriptor
    public var anchors: [DrawingAnchor]
    public var createdAt: Date
}

public struct CalibrationDimension: Codable, Equatable, Sendable {
    public var points: [PagePoint]
    public var feet: Double
    public var source: String
    public init(points: [PagePoint], feet: Double, source: String) {
        self.points = points; self.feet = feet; self.source = source
    }
}

public struct CalibratedView: Codable, Identifiable, Sendable {
    public var id: String
    public var pageID: String
    public var name: String
    public var min: PagePoint
    public var max: PagePoint
    public var dimension: CalibrationDimension
    public var check: CalibrationDimension?
    public var author: String
    public var createdAt: Date
    public init(id: String = UUID().uuidString, pageID: String, name: String, min: PagePoint, max: PagePoint,
                dimension: CalibrationDimension, check: CalibrationDimension? = nil, author: String) {
        self.id = id; self.pageID = pageID; self.name = name; self.min = min; self.max = max
        self.dimension = dimension; self.check = check; self.author = author; createdAt = Date()
    }
    public func scale() throws -> ScaleRegion {
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "View name and calibration author are required.")
        var scale = try ScaleRegion(id: id, sheet: pageID, revision: pageID, min: min, max: max,
            reference: dimension.points, knownFeet: dimension.feet,
            evidence: Evidence(origin: .userProvided, source: dimension.source, confidence: 1, reviewer: author))
        if let check {
            try require(!check.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Record the independent check's dimension source.")
            try require(check.points != dimension.points && check.points != Array(dimension.points.reversed()), "Use a different known dimension for the independent check.")
            try scale.validate(reference: check.points, knownFeet: check.feet)
        }
        return scale
    }
}

public struct MeasuredRoute: Codable, Identifiable, Sendable {
    public var id: String
    public var viewID: String
    public var descriptor: TakeoffDescriptor
    public var points: [PagePoint]
    public var author: String
    public var createdAt: Date
}

public struct MarkupAction: Codable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var targetID: String
    public var author: String
    public var at: Date
    public var undoes: String?
    public var evidence: JSONValue
}

/// Models store measured geometry, not cached quantities that can drift from the drawing.
public struct MarkupLedger: Codable, Sendable {
    public var schemaVersion = 1
    public private(set) var views: [CalibratedView] = []
    public private(set) var objects: [CountedObject] = []
    public private(set) var routes: [MeasuredRoute] = []
    public private(set) var history: [MarkupAction] = []
    public var lastUndoableAction: MarkupAction? {
        let undone = Set(history.compactMap(\.undoes))
        return history.last { $0.kind != "undo" && !undone.contains($0.id) }
    }
    public init() {}
    public init(json: JSONValue) throws {
        if json == .null { self.init(); return }
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(json))
        try validate()
    }
    public func json() throws -> JSONValue {
        try validate()
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
    }
    public mutating func addView(_ view: CalibratedView) throws {
        var copy = self; copy.views.append(view); try copy.validate()
        copy.history.append(try action("view", id: view.id, author: view.author, evidence: view)); self = copy
    }
    public mutating func checkView(id: String, dimension: CalibrationDimension, author: String) throws {
        try require(!author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Record who checked the calibration.")
        var copy = self
        guard let index = copy.views.firstIndex(where: { $0.id == id }) else { throw LoadSightError.invalid("Calibrated view not found.") }
        // Checks cannot be silently rewritten after routes depend on them.
        try require(copy.views[index].check == nil, "This view already has a check. Create a new calibration for a correction.")
        copy.views[index].check = dimension; try copy.validate()
        copy.history.append(try action("check", id: id, author: author, evidence: dimension)); self = copy
    }
    public mutating func count(id: String = UUID().uuidString, descriptor: TakeoffDescriptor, anchor: DrawingAnchor) throws {
        var copy = self
        if let index = copy.objects.firstIndex(where: { $0.id == id }) {
            try require(copy.objects[index].descriptor == descriptor, "Repeated views must identify the same item, system, size and lifecycle.")
            try require(!copy.objects[index].anchors.contains(where: { $0.pageID == anchor.pageID && $0.point == anchor.point }), "This evidence anchor is already recorded.")
            copy.objects[index].anchors.append(anchor)
        } else {
            copy.objects.append(.init(id: id, descriptor: descriptor, anchors: [anchor], createdAt: Date()))
        }
        try copy.validate()
        copy.history.append(try action("count", id: id, author: anchor.author, evidence: copy.objects.first { $0.id == id }!)); self = copy
    }
    public mutating func measure(id: String = UUID().uuidString, viewID: String, descriptor: TakeoffDescriptor, points: [PagePoint], author: String) throws {
        var copy = self
        copy.routes.append(.init(id: id, viewID: viewID, descriptor: descriptor, points: points, author: author, createdAt: Date()))
        try copy.validate()
        copy.history.append(try action("route", id: id, author: author, evidence: copy.routes.last!)); self = copy
    }
    public mutating func undoLast(author: String) throws {
        try require(!author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Record who is undoing the markup.")
        guard let event = lastUndoableAction else { throw LoadSightError.invalid("No saved markup to undo.") }
        var copy = self
        switch event.kind {
        case "view": copy.views.removeAll { $0.id == event.targetID }
        case "check":
            guard let i = copy.views.firstIndex(where: { $0.id == event.targetID }) else { throw LoadSightError.invalid("Calibration no longer exists.") }
            copy.views[i].check = nil
        case "count":
            guard let i = copy.objects.firstIndex(where: { $0.id == event.targetID }) else { throw LoadSightError.invalid("Count no longer exists.") }
            copy.objects[i].anchors.removeLast()
            if copy.objects[i].anchors.isEmpty { copy.objects.remove(at: i) }
        case "route": copy.routes.removeAll { $0.id == event.targetID }
        default: throw LoadSightError.invalid("Unsupported markup undo action.")
        }
        try copy.validate()
        copy.history.append(.init(id: UUID().uuidString, kind: "undo", targetID: event.targetID, author: author, at: Date(), undoes: event.id, evidence: event.evidence))
        self = copy
    }
    private func action<T: Encodable>(_ kind: String, id: String, author: String, evidence: T) throws -> MarkupAction {
        .init(id: UUID().uuidString, kind: kind, targetID: id, author: author, at: Date(), undoes: nil,
              evidence: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(evidence)))
    }
    public func length(of route: MeasuredRoute) throws -> Double {
        guard let view = views.first(where: { $0.id == route.viewID }) else { throw LoadSightError.invalid("Route calibration is missing.") }
        let scale = try view.scale()
        try require(scale.validationErrorFraction != nil, "Check the calibration against a second known dimension before measuring a route.")
        // Explicit geometric check tolerance; this is not a design or code tolerance.
        try require(scale.validationErrorFraction! <= 0.02, "Calibration check differs by more than the 2% geometric tolerance. Recalibrate this view.")
        let length = try scale.length(route.points)
        try require(length > 0, "A measured route must have positive length.")
        return length
    }
    public func validate() throws {
        try require(schemaVersion == 1, "Unsupported markup schema.")
        let ids = views.map(\.id) + objects.map(\.id) + routes.map(\.id)
        try require(ids.allSatisfy { !$0.isEmpty } && Set(ids).count == ids.count, "Duplicate or missing markup identity.")
        for view in views { _ = try view.scale() }
        for object in objects {
            try object.descriptor.validate()
            try require(!object.anchors.isEmpty, "A counted object needs drawing evidence.")
            for anchor in object.anchors {
                try require(!anchor.pageID.isEmpty && anchor.point.x.isFinite && anchor.point.y.isFinite && !anchor.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Invalid count anchor or missing author.")
            }
        }
        for route in routes {
            try route.descriptor.validate()
            try require(!route.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Record the route author.")
            _ = try length(of: route)
        }
    }
    public func takeoffRows() throws -> [[String: JSONValue]] {
        try validate()
        var rows = objects.map { object in
            row(id: object.id, descriptor: object.descriptor, quantity: 1, unit: "EA", status: "Plan-counted",
                source: object.anchors.map { "\($0.pageID) @ (\($0.point.x), \($0.point.y))" }.joined(separator: "; "),
                basis: "One physical object; \(object.anchors.count) drawing evidence anchors. Procurement and field verification remain open.")
        }
        rows += try routes.map { route in
            let view = views.first { $0.id == route.viewID }!
            return row(id: route.id, descriptor: route.descriptor, quantity: try length(of: route), unit: "LF", status: "Measured-draft",
                       source: "\(view.pageID); view \(view.name); calibration \(view.id)",
                       basis: "Centerline polyline / \(try view.scale().pointsPerFoot) points per foot. Plan length only; verticals, fittings and waste are separate. Measured by \(route.author).")
        }
        return rows
    }
    private func row(id: String, descriptor: TakeoffDescriptor, quantity: Double, unit: String, status: String, source: String, basis: String) -> [String: JSONValue] {
        ["id": .string("markup-" + id), "nativeMarkupID": .string(id), "category": .string(descriptor.system),
         "description": .string(descriptor.label + (descriptor.size.isEmpty ? "" : " · " + descriptor.size)),
         "lifecycle": .string(descriptor.lifecycle.rawValue), "quantity": .number(quantity), "unit": .string(unit),
         "scope": .string(descriptor.lifecycle == .existing ? "Excluded" : "Base"), "quantityStatus": .string(status),
         "source": .string(source), "basis": .string(basis), "priceSource": .string(""),
         "materialUnit": .null, "laborHoursUnit": .null, "subcontractUnit": .null, "otherUnit": .null, "wastePct": .number(0)]
    }
}
