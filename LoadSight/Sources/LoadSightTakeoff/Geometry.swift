import Foundation
import LoadSightCore

public struct PagePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct ScaleRegion: Codable, Sendable {
    public var id: String
    public var sheet: String
    public var revision: String
    public var min: PagePoint
    public var max: PagePoint
    public var pointsPerFoot: Double
    public var evidence: Evidence
    public var validationErrorFraction: Double?
    public init(id: String, sheet: String, revision: String, min: PagePoint, max: PagePoint,
                reference: [PagePoint], knownFeet: Double, evidence: Evidence) throws {
        try require(!id.isEmpty && !sheet.isEmpty && !revision.isEmpty, "Scale ID, sheet and revision are required.")
        try require([min.x, min.y, max.x, max.y].allSatisfy(\.isFinite) && min.x < max.x && min.y < max.y, "Invalid scale region bounds.")
        try require(reference.count == 2 && knownFeet.isFinite && knownFeet > 0, "Calibrate with two points and a positive known length.")
        try require(reference.allSatisfy { $0.x >= min.x && $0.x <= max.x && $0.y >= min.y && $0.y <= max.y }, "Calibration points lie outside their view.")
        let distance = hypot(reference[1].x - reference[0].x, reference[1].y - reference[0].y)
        try require(distance.isFinite && distance > 0, "Calibration points must be distinct.")
        self.id = id; self.sheet = sheet; self.revision = revision; self.min = min; self.max = max
        self.pointsPerFoot = distance / knownFeet; self.evidence = evidence
        try require(pointsPerFoot.isFinite && pointsPerFoot > 0, "Invalid calibration factor.")
    }
    public mutating func validate(reference: [PagePoint], knownFeet: Double) throws {
        try require(reference.count == 2 && knownFeet.isFinite && knownFeet > 0, "A second positive known dimension is required.")
        validationErrorFraction = abs(try length(reference) / knownFeet - 1)
    }
    public func length(_ points: [PagePoint]) throws -> Double {
        try require(points.count >= 2 && pointsPerFoot.isFinite && pointsPerFoot > 0, "A route requires at least two points and a valid scale.")
        try require(points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x >= min.x && $0.x <= max.x && $0.y >= min.y && $0.y <= max.y }, "Route crosses the calibrated view boundary.")
        let result = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } / pointsPerFoot
        try require(result.isFinite, "Route length overflow.")
        return result
    }
}

public enum DuctGeometry {
    public static func rectangularSurface(widthIn: Double, heightIn: Double, lengthFt: Double) throws -> Double {
        try nonnegative(lengthFt); try require(widthIn.isFinite && heightIn.isFinite && widthIn > 0 && heightIn > 0, "Duct dimensions must be positive.")
        let result = 2 * (widthIn + heightIn) / 12 * lengthFt
        try require(result.isFinite, "Duct area overflow."); return result
    }
    public static func roundSurface(diameterIn: Double, lengthFt: Double) throws -> Double {
        try nonnegative(lengthFt); try require(diameterIn.isFinite && diameterIn > 0, "Diameter must be positive.")
        let result = .pi * diameterIn / 12 * lengthFt
        try require(result.isFinite, "Duct area overflow."); return result
    }
    public static func rectangularVelocity(cfm: Double, widthIn: Double, heightIn: Double) throws -> Double {
        try nonnegative(cfm); try require(widthIn.isFinite && heightIn.isFinite && widthIn > 0 && heightIn > 0, "Duct dimensions must be positive.")
        let result = cfm / (widthIn * heightIn / 144)
        try require(result.isFinite, "Duct velocity overflow."); return result
    }
}
