import Foundation
import LoadSightCore

/// Fetches NOAA Integrated Surface Database files, with an on-disk cache.
///
/// An actor because the station index is expensive to parse and is shared. Nothing here
/// touches the main actor: a station-year file runs to several megabytes and a multi-year
/// derivation reads tens of them, so all of it stays off the main thread by construction.
public actor ISDClient {
    public struct Configuration: Sendable {
        public var cacheDirectory: URL?
        /// Yearly files downloaded at once. NOAA is a public service; this is deliberately modest.
        public var maximumConcurrentDownloads: Int
        public var requestTimeout: TimeInterval
        public init(cacheDirectory: URL? = nil, maximumConcurrentDownloads: Int = 4,
                    requestTimeout: TimeInterval = 120) {
            self.cacheDirectory = cacheDirectory
            self.maximumConcurrentDownloads = max(1, maximumConcurrentDownloads)
            self.requestTimeout = requestTimeout
        }
    }

    private let configuration: Configuration
    private let session: URLSession
    private var stationIndex: ISDStationIndex?

    public init(configuration: Configuration = Configuration(), session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    // MARK: - Station index

    public func stations() async throws -> ISDStationIndex {
        if let stationIndex { return stationIndex }
        let text = try await text(at: ISDStationIndex.sourceURL, cacheKey: "isd-history.csv")
        let index = try ISDStationIndex(csv: text)
        stationIndex = index
        return index
    }

    /// Stations near a point that report across the whole requested span, nearest first.
    public func nearestStations(latitude: Double, longitude: Double,
                                covering years: ClosedRange<Int>, limit: Int = 5) async throws -> [ISDStation] {
        try await stations().nearest(latitude: latitude, longitude: longitude, covering: years, limit: limit)
    }

    // MARK: - Observations

    /// Reads one station across a span of years.
    ///
    /// A year that is absent upstream is skipped rather than failing the run — stations go
    /// offline for a year and the remaining record is still usable — but the span must
    /// yield at least one year or there is nothing to derive from.
    public func observations(stationID: String, years: ClosedRange<Int>)
    async throws -> (observations: [ISDObservation], totals: ISDReadTotals, missingYears: [Int]) {
        try require(years.lowerBound <= years.upperBound, "The year range is inverted.")
        var collected: [ISDObservation] = []
        var totals = ISDReadTotals()
        var missing: [Int] = []

        for batch in Array(years).chunked(into: configuration.maximumConcurrentDownloads) {
            let downloaded = try await withThrowingTaskGroup(of: (Int, String?).self) { group in
                for year in batch {
                    group.addTask { [weak self] in
                        guard let self else { return (year, nil) }
                        let url = ISDHourly.accessURL(stationID: stationID, year: year)
                        let key = "global-hourly/\(year)/\(stationID).csv"
                        return (year, try? await self.text(at: url, cacheKey: key))
                    }
                }
                var results: [(Int, String?)] = []
                for try await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }
            }
            for (year, csv) in downloaded {
                guard let csv else { missing.append(year); continue }
                let result = try ISDHourly.parse(csv: csv)
                totals.add(result)
                collected.append(contentsOf: result.observations)
            }
        }

        try require(!collected.isEmpty,
                    "No observations were retrieved for station \(stationID) across \(years.lowerBound)–\(years.upperBound).")
        collected.sort { $0.hourKey < $1.hourKey }
        return (collected, totals, missing.sorted())
    }

    /// How complete a station's reporting is for design-condition work.
    public struct StationSuitability: Sendable, Equatable {
        public let stationID: String
        public let hoursSampled: Int
        public let dewPointCoverage: Double
        /// Cooling design needs a mean coincident wet bulb, which needs dew point. A
        /// station reporting dry bulb alone — many marine and automated sites do —
        /// yields a heating condition and nothing else.
        public var reportsDewPoint: Bool { dewPointCoverage >= 0.5 }
        public var isUsable: Bool { hoursSampled >= 2_000 && reportsDewPoint }
    }

    /// Reads a single year to judge a station before committing to a decade of downloads.
    public func probe(stationID: String, year: Int) async -> StationSuitability {
        let url = ISDHourly.accessURL(stationID: stationID, year: year)
        guard let csv = try? await text(at: url, cacheKey: "global-hourly/\(year)/\(stationID).csv"),
              let result = try? ISDHourly.parse(csv: csv), !result.observations.isEmpty else {
            return StationSuitability(stationID: stationID, hoursSampled: 0, dewPointCoverage: 0)
        }
        let withDewPoint = result.observations.count { $0.dewPointC != nil }
        return StationSuitability(stationID: stationID, hoursSampled: result.observations.count,
                                  dewPointCoverage: Double(withDewPoint) / Double(result.observations.count))
    }

    /// Full path from a site position to derived design conditions.
    ///
    /// The nearest station is not automatically the right one. Harbour buoys, road-weather
    /// sites and some automated stations sit closer to a city centre than the airport does
    /// while reporting no dew point, which silently costs every cooling and
    /// dehumidification condition. Candidates are probed a year at a time and the nearest
    /// station that actually reports what design work needs is chosen; the rejected ones
    /// are recorded in the provenance so the choice is visible rather than mysterious.
    public func designConditions(latitude: Double, longitude: Double, years: ClosedRange<Int>)
    async throws -> DesignConditions {
        let candidates = try await nearestStations(latitude: latitude, longitude: longitude,
                                                   covering: years, limit: 10)
        guard !candidates.isEmpty else {
            throw LoadSightError.invalid("No station reports continuously across \(years.lowerBound)–\(years.upperBound) near that position.")
        }
        var rejected: [String] = []
        var fallback: ISDStation?
        for station in candidates {
            let suitability = await probe(stationID: station.id, year: years.upperBound)
            if suitability.isUsable {
                let distance = station.distanceKM(toLatitude: latitude, longitude: longitude)
                var conditions = try await designConditions(station: station, years: years,
                                                            distanceFromSiteKM: distance)
                for note in rejected {
                    conditions = conditions.appendingWarning("Skipped nearer station \(note).")
                }
                return conditions
            }
            if fallback == nil && suitability.hoursSampled > 0 { fallback = station }
            let reason = suitability.hoursSampled == 0
                ? "published no data for \(years.upperBound)"
                : String(format: "reported dew point in only %.0f%% of its observations", suitability.dewPointCoverage * 100)
            rejected.append("\(station.name) (\(station.id)), \(String(format: "%.1f", station.distanceKM(toLatitude: latitude, longitude: longitude))) km — \(reason)")
        }

        guard let fallback else {
            throw LoadSightError.invalid("No station near that position reports usable observations for \(years.lowerBound)–\(years.upperBound).")
        }
        let distance = fallback.distanceKM(toLatitude: latitude, longitude: longitude)
        var conditions = try await designConditions(station: fallback, years: years, distanceFromSiteKM: distance)
        conditions = conditions.appendingWarning(
            "No station within range reports dew point reliably, so cooling and dehumidification conditions are incomplete. Stations examined: \(rejected.joined(separator: "; ")).")
        return conditions
    }

    public func designConditions(station: ISDStation, years: ClosedRange<Int>,
                                 distanceFromSiteKM: Double? = nil) async throws -> DesignConditions {
        let reading = try await observations(stationID: station.id, years: years)
        var conditions = try DesignConditionDerivation.derive(
            observations: reading.observations, station: station,
            read: reading.totals, distanceFromSiteKM: distanceFromSiteKM)
        if !reading.missingYears.isEmpty {
            conditions = conditions.appendingWarning(
                "No data were published for \(reading.missingYears.map(String.init).joined(separator: ", ")); those years are absent from the percentiles.")
        }
        return conditions
    }

    // MARK: - Transport

    private func text(at urlString: String, cacheKey: String) async throws -> String {
        if let cached = cachedText(for: cacheKey) { return cached }
        guard let url = URL(string: urlString) else {
            throw LoadSightError.invalid("Malformed source URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = configuration.requestTimeout
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LoadSightError.invalid("NOAA returned HTTP \(http.statusCode) for \(urlString).")
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw LoadSightError.invalid("The file at \(urlString) is not readable text.")
        }
        store(text, for: cacheKey)
        return text
    }

    private func cacheURL(for key: String) -> URL? {
        configuration.cacheDirectory?.appendingPathComponent(key)
    }

    private func cachedText(for key: String) -> String? {
        guard let url = cacheURL(for: key) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func store(_ text: String, for key: String) {
        guard let url = cacheURL(for: key) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

extension DesignConditions {
    func appendingWarning(_ warning: String) -> DesignConditions {
        let provenance = DesignConditionProvenance(
            stationID: provenance.stationID, stationName: provenance.stationName,
            latitude: provenance.latitude, longitude: provenance.longitude,
            elevationM: provenance.elevationM, elevationAssumed: provenance.elevationAssumed,
            stationPressurePa: provenance.stationPressurePa,
            distanceFromSiteKM: provenance.distanceFromSiteKM,
            firstYear: provenance.firstYear, lastYear: provenance.lastYear,
            yearsUsed: provenance.yearsUsed, hoursUsed: provenance.hoursUsed,
            hoursRejectedQuality: provenance.hoursRejectedQuality,
            hoursRejectedMissing: provenance.hoursRejectedMissing,
            hoursRejectedMalformed: provenance.hoursRejectedMalformed,
            method: provenance.method, sourceURL: provenance.sourceURL,
            warnings: provenance.warnings + [warning])
        return DesignConditions(heating: heating, cooling: cooling, dehumidification: dehumidification,
                                coolingDailyRangeC: coolingDailyRangeC, warmestMonth: warmestMonth,
                                extremeAnnualMinimumC: extremeAnnualMinimumC,
                                extremeAnnualMaximumC: extremeAnnualMaximumC,
                                provenance: provenance)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
