import Foundation
import LoadSightCore

/// One surface observation reduced to the fields design conditions are derived from.
///
/// Calendar fields are stored as integers rather than a `Date`. The derivation groups by
/// hour, day and month and never needs an instant, and parsing a quarter-million rows
/// through `DateFormatter` costs far more than the arithmetic it feeds.
public struct ISDObservation: Sendable, Equatable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let dryBulbC: Double
    public let dewPointC: Double?

    public var dayKey: Int { (year * 10_000) + (month * 100) + day }
    public var hourKey: Int { (dayKey * 100) + hour }

    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int,
                dryBulbC: Double, dewPointC: Double?) {
        self.year = year; self.month = month; self.day = day
        self.hour = hour; self.minute = minute
        self.dryBulbC = dryBulbC; self.dewPointC = dewPointC
    }
}

/// Outcome of reading one yearly station file, including what was thrown away.
///
/// Rejection counts are part of the record, not diagnostics. A station whose file is
/// half suspect readings produces a design condition that should not be trusted, and
/// the only way anyone can tell is if the reader reports it.
public struct ISDReadResult: Sendable {
    public let observations: [ISDObservation]
    public let rowsRead: Int
    public let rejectedQuality: Int
    public let rejectedMissing: Int
    public let rejectedMalformed: Int
    public let duplicateHoursDropped: Int
}

public enum ISDHourly {
    /// Quality codes that mark a reading as usable.
    ///
    /// Verified against NOAA's ISD format document, section for the air-temperature
    /// quality code: 0 and 4 passed gross limits, 1 and 5 passed all checks, 9 passed
    /// gross limits where present, and A, C, I, M, P, R and U are validator-accepted or
    /// validator-supplied values. Codes 2, 3, 6 and 7 are suspect or erroneous and are
    /// the only ones excluded.
    public static let acceptedQualityCodes: Set<String> = ["0", "1", "4", "5", "9", "A", "C", "I", "M", "P", "R", "U"]

    /// NOAA's missing sentinel for temperature and dew point, in tenths of a degree.
    public static let missingSentinel = 9999

    public static func accessURL(stationID: String, year: Int) -> String {
        "https://www.ncei.noaa.gov/data/global-hourly/access/\(year)/\(stationID).csv"
    }

    /// Parses a yearly `global-hourly` CSV.
    ///
    /// Stations report several times an hour under different report types (FM-12 synoptic,
    /// FM-15 METAR, and specials). Percentiles are defined over hours, so counting every
    /// record would weight busy stations and busy hours more heavily and bias the result.
    /// One observation is kept per clock hour: the one closest to the top of the hour,
    /// with the earlier minute winning a tie.
    public static func parse(csv: String) throws -> ISDReadResult {
        let lines = DelimitedText.lines(of: csv)
        guard let headerLine = lines.first else { throw LoadSightError.invalid("The observation file is empty.") }
        let header = try DelimitedText.Header(headerLine)
        let dateIndex = try header.index(of: "DATE")
        let temperatureIndex = try header.index(of: "TMP")
        let dewPointIndex = header.contains("DEW") ? try header.index(of: "DEW") : -1

        var best: [Int: ISDObservation] = [:]
        var rowsRead = 0, rejectedQuality = 0, rejectedMissing = 0, rejectedMalformed = 0, duplicates = 0

        for line in lines.dropFirst() {
            rowsRead += 1
            let row = DelimitedText.fields(in: line)
            guard let stamp = row.value(at: dateIndex), let moment = timestamp(stamp) else {
                rejectedMalformed += 1; continue
            }
            guard let temperatureField = row.value(at: temperatureIndex) else { rejectedMalformed += 1; continue }
            switch measurement(temperatureField) {
            case .malformed: rejectedMalformed += 1; continue
            case .missing: rejectedMissing += 1; continue
            case .rejected: rejectedQuality += 1; continue
            case .value(let dryBulb):
                var dewPoint: Double?
                if dewPointIndex >= 0, let field = row.value(at: dewPointIndex),
                   case .value(let measured) = measurement(field) {
                    // Supersaturated readings occur at the rounding boundary of whole-degree
                    // AWOS reports. Clamping rather than discarding keeps the dry bulb, which
                    // the heating and cooling percentiles depend on.
                    dewPoint = min(measured, dryBulb)
                }
                let candidate = ISDObservation(year: moment.year, month: moment.month, day: moment.day,
                                               hour: moment.hour, minute: moment.minute,
                                               dryBulbC: dryBulb, dewPointC: dewPoint)
                let key = candidate.hourKey
                if let existing = best[key] {
                    duplicates += 1
                    if candidate.minute < existing.minute { best[key] = candidate }
                } else {
                    best[key] = candidate
                }
            }
        }

        let ordered = best.values.sorted { $0.hourKey < $1.hourKey }
        return ISDReadResult(observations: ordered, rowsRead: rowsRead, rejectedQuality: rejectedQuality,
                             rejectedMissing: rejectedMissing, rejectedMalformed: rejectedMalformed,
                             duplicateHoursDropped: duplicates)
    }

    enum Measurement: Equatable { case value(Double), missing, rejected, malformed }

    /// Reads a `TMP`/`DEW` field of the form `+0117,1` — tenths of a degree Celsius,
    /// then the quality code.
    static func measurement(_ field: String) -> Measurement {
        let parts = field.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .malformed }
        guard let tenths = Int(parts[0]) else { return .malformed }
        if abs(tenths) == missingSentinel { return .missing }
        let quality = parts[1].trimmingCharacters(in: .whitespaces).uppercased()
        guard acceptedQualityCodes.contains(quality) else { return .rejected }
        let celsius = Double(tenths) / 10
        // Gross physical bound. The record contains transcription errors that carry a
        // clean quality code, and one -70 °C reading moves a 99.6% heating percentile.
        guard celsius > -95, celsius < 70 else { return .malformed }
        return .value(celsius)
    }

    /// Parses `yyyy-MM-ddTHH:mm:ss` positionally.
    static func timestamp(_ text: String) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int)? {
        let digits = Array(text.utf8)
        guard digits.count >= 16 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var total = 0
            for offset in range {
                let digit = Int(digits[offset]) - 48
                guard (0...9).contains(digit) else { return nil }
                total = total * 10 + digit
            }
            return total
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16),
              (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        return (year, month, day, hour, minute)
    }
}
