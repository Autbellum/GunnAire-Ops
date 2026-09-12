import Foundation

public struct OpeningTransmissionResult: Codable, Sendable {
    public let surfaceName: String
    public let openingName: String
    public let areaSF: Double
    public let wholeProductU: Double?
    public let outwardBtuh: Double?
    public let trace: CalculationTrace?
}

public struct OpeningTransmissionSummary: Codable, Sendable {
    public let openings: [OpeningTransmissionResult]
    public let allListedOpeningsRated: Bool
    public let knownOpeningLossBtuh: Double
    public let knownOpeningGainBtuh: Double
    public let combinedEnvelopeLossBtuh: Double?
    public let combinedEnvelopeGainBtuh: Double?
    public let combinedEnvelopeNetOutwardBtuh: Double?
    public let traces: [CalculationTrace]
    public let assumptions: [String]

    static func calculate(surfaces: [RoomEnvelopeSurface], indoorDesignF: Double, opaqueLoss: Double, opaqueGain: Double) throws -> Self {
        let assumptions = [
            "Each rated opening uses its full product area and sourced whole-product U-factor; no center-of-glass, slab-only or nominal R conversion is inferred.",
            "Q = U × A × (Troom − Tadjacent), using the parent surface's coincident boundary temperatures. Positive is outward loss; negative is inward gain.",
            "U-factor source must identify the product/configuration and rating basis. Rating applicability at the design condition remains a review responsibility.",
            "Missing ratings have unknown transmission, not zero. Combined envelope subtotals are withheld until every listed opening is rated.",
            "This is conduction through the entered surface ledger only, not proof of complete room geometry or a complete heating/cooling load. No solar, leakage or rating-to-design film adjustment is added."
        ]
        let openings: [OpeningTransmissionResult] = try surfaces.flatMap { surface in
            try surface.openings.map { opening in
                guard let rating = opening.wholeProductU else {
                    return .init(surfaceName:surface.name,openingName:opening.name,areaSF:opening.areaSF.value,wholeProductU:nil,outwardBtuh:nil,trace:nil)
                }
                try rating.validate("\(surface.name) / \(opening.name) whole-product U-factor")
                try require(rating.value > 0, "Whole-product U-factor must be positive.")
                let q = try MechanicalMath.envelope(u:rating.value,areaSF:opening.areaSF.value,deltaF:indoorDesignF-surface.adjacentDesignF.value)
                let trace = try CalculationTrace(equation:q.equation,substitution:q.substitution,value:q.value,unit:q.unit,
                    assumptions:["Whole-product U basis (\(rating.classification.rawValue)): \(rating.source)","Full product area basis (\(opening.areaSF.classification.rawValue)): \(opening.areaSF.source)"])
                return .init(surfaceName:surface.name,openingName:opening.name,areaSF:opening.areaSF.value,wholeProductU:rating.value,outwardBtuh:q.value,trace:trace)
            }
        }
        let loss = openings.reduce(0) { $0 + max(0,$1.outwardBtuh ?? 0) }
        let gain = openings.reduce(0) { $0 + max(0,-($1.outwardBtuh ?? 0)) }
        let complete = openings.allSatisfy { $0.outwardBtuh != nil }
        let modeled = openings.compactMap(\.outwardBtuh)
        var traces = [
            try CalculationTrace(equation:"Known opening loss = Σmax(Qrated opening, 0)",substitution:modeled.isEmpty ? "0 rated opening terms" : modeled.map { String(max(0,$0)) }.joined(separator:" + "),value:loss,unit:"Btuh",assumptions:["Known terms only; missing ratings are not counted as zero-load openings."]),
            try CalculationTrace(equation:"Known opening gain = Σmax(−Qrated opening, 0)",substitution:modeled.isEmpty ? "0 rated opening terms" : modeled.map { String(max(0,-$0)) }.joined(separator:" + "),value:gain,unit:"Btuh")
        ]
        var combinedLoss: Double?, combinedGain: Double?, combinedNet: Double?
        if complete {
            combinedLoss = opaqueLoss + loss; combinedGain = opaqueGain + gain; combinedNet = combinedLoss! - combinedGain!
            traces.append(try .init(equation:"Envelope outward loss = opaque loss + opening loss",substitution:"\(opaqueLoss) + \(loss)",value:combinedLoss!,unit:"Btuh"))
            traces.append(try .init(equation:"Envelope inward gain = opaque gain + opening gain",substitution:"\(opaqueGain) + \(gain)",value:combinedGain!,unit:"Btuh"))
            traces.append(try .init(equation:"Envelope net outward = outward loss − inward gain",substitution:"\(combinedLoss!) − \(combinedGain!)",value:combinedNet!,unit:"Btuh",assumptions:assumptions))
        }
        return .init(openings:openings,allListedOpeningsRated:complete,knownOpeningLossBtuh:loss,knownOpeningGainBtuh:gain,
            combinedEnvelopeLossBtuh:combinedLoss,combinedEnvelopeGainBtuh:combinedGain,combinedEnvelopeNetOutwardBtuh:combinedNet,traces:traces,assumptions:assumptions)
    }
}
