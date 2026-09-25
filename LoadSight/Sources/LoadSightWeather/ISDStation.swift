import Foundation
import LoadSightCore

/// One weather station in NOAA's Integrated Surface Database history file.
///
/// `id` is the eleven-character USAF+WBAN key used to name the yearly observation
/// files under `/data/global-hourly/access/<year>/<id>.csv`.
public struct ISDStation: Codable, Sendable, Equatable, Identifiable {
    public let usaf: String
    public let wban: String
    public let name: String
    public let country: String
    public let state: String
    public let icao: String
    public let latitude: Double
    public let longitude: Double
    public let elevationM: Double?
    public let beginYear: Int
    public let endYear: Int

    public var id: String { usaf + wban }

    /// Station pressure from the ASHRAE standard atmosphere. Observation records carry
    /// sea-level pressure inconsistently, and design conditions need station pressure to
    /// convert dew point to wet bulb, so elevation is the dependable route.
    /// Stations with no published elevation fall back to sea level and are flagged.
    public var stationPressurePa: Double {
        let elevation = elevationM ?? 0
        return 101_325 * pow(1 - 2.25577e-5 * elevation, 5.2559)
    }

    public var hasPublishedElevation: Bool { elevationM != nil }

    public init(usaf: String, wban: String, name: String, country: String, state: String,
                icao: String, latitude: Double, longitude: Double, elevationM: Double?,
                beginYear: Int, endYear: Int) {
        self.usaf = usaf; self.wban = wban; self.name = name; self.country = country
        self.state = state; self.icao = icao; self.latitude = latitude
        self.longitude = longitude; self.elevationM = elevationM
        self.beginYear = beginYear; self.endYear = endYear
    }

    /// Great-circle distance on a spherical earth. Station spacing is far coarser than
    /// the ellipsoidal correction, so the sphere is not the limiting error here.
    public func distanceKM(toLatitude latitude: Double, longitude: Double) -> Double {
        let radius = 6_371.0088
        let toRadians = Double.pi / 180
        let dLat = (latitude - self.latitude) * toRadians
        let dLon = (longitude - self.longitude) * toRadians
        let a = pow(sin(dLat / 2), 2)
            + cos(self.latitude * toRadians) * cos(latitude * toRadians) * pow(sin(dLon / 2), 2)
        return 2 * radius * asin(min(1, sqrt(a)))
    }
}

/// The parsed station history, searchable by position.
public struct ISDStationIndex: Sendable {
    public static let sourceURL = "https://www.ncei.noaa.gov/pub/data/noaa/isd-history.csv"
    public let stations: [ISDStation]

    public init(stations: [ISDStation]) { self.stations = stations }

    public init(csv: String) throws {
        let lines = DelimitedText.lines(of: csv)
        guard let headerLine = lines.first else { throw LoadSightError.invalid("The station history file is empty.") }
        let header = try DelimitedText.Header(headerLine)
        let usaf = try header.index(of: "USAF")
        let wban = try header.index(of: "WBAN")
        let name = try header.index(of: "STATION NAME")
        let country = try header.index(of: "CTRY")
        let state = try header.index(of: "STATE")
        let icao = try header.index(of: "ICAO")
        let latitude = try header.index(of: "LAT")
        let longitude = try header.index(of: "LON")
        let elevation = try header.index(of: "ELEV(M)")
        let begin = try header.index(of: "BEGIN")
        let end = try header.index(of: "END")

        var parsed: [ISDStation] = []
        parsed.reserveCapacity(lines.count)
        for line in lines.dropFirst() {
            let row = DelimitedText.fields(in: line)
            guard let usafValue = row.value(at: usaf), let wbanValue = row.value(at: wban),
                  let latitudeText = row.value(at: latitude), let latitudeValue = Double(latitudeText),
                  let longitudeText = row.value(at: longitude), let longitudeValue = Double(longitudeText),
                  let beginText = row.value(at: begin), let beginValue = Int(beginText.prefix(4)),
                  let endText = row.value(at: end), let endValue = Int(endText.prefix(4))
            else { continue }
            // 0,0 is NOAA's placeholder for an unlocated station, not a station in the Gulf of Guinea.
            if latitudeValue == 0 && longitudeValue == 0 { continue }
            guard (-90...90).contains(latitudeValue), (-180...180).contains(longitudeValue) else { continue }
            let elevationValue = row.value(at: elevation).flatMap(Double.init)
            parsed.append(ISDStation(
                usaf: usafValue, wban: wbanValue,
                name: row.value(at: name) ?? "", country: row.value(at: country) ?? "",
                state: row.value(at: state) ?? "", icao: row.value(at: icao) ?? "",
                latitude: latitudeValue, longitude: longitudeValue,
                elevationM: elevationValue == -999.9 ? nil : elevationValue,
                beginYear: beginValue, endYear: endValue))
        }
        try require(!parsed.isEmpty, "No usable stations were parsed from the station history file.")
        self.stations = parsed
    }

    /// Stations near a point, nearest first.
    ///
    /// `covering` requires an unbroken published period of record spanning those years.
    /// A station that stopped reporting in 1994 is useless for present-day design
    /// conditions however close it sits, so the filter is applied before distance.
    public func nearest(latitude: Double, longitude: Double, covering years: ClosedRange<Int>? = nil,
                        limit: Int = 5) throws -> [ISDStation] {
        try require((-90...90).contains(latitude), "Latitude must be between −90 and 90 degrees.")
        try require((-180...180).contains(longitude), "Longitude must be between −180 and 180 degrees.")
        try require(limit > 0, "Ask for at least one station.")
        let eligible = stations.filter { station in
            guard let years else { return true }
            return station.beginYear <= years.lowerBound && station.endYear >= years.upperBound
        }
        return eligible
            .map { ($0, $0.distanceKM(toLatitude: latitude, longitude: longitude)) }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
