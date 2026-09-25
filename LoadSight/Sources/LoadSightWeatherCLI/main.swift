import Foundation
import LoadSightWeather

// Derives design conditions for a site from NOAA observations and prints them with the
// provenance that has to accompany them on a report.
//
//   loadsight-weather --lat 42.36 --lon -71.01 --from 2014 --to 2023 [--station 72509014739]
//
// Files are cached under ~/Library/Caches/LoadSight/ISD so a second run costs nothing.

struct Arguments {
    var latitude: Double?
    var longitude: Double?
    var stationID: String?
    var firstYear = Calendar(identifier: .gregorian).component(.year, from: Date()) - 11
    var lastYear = Calendar(identifier: .gregorian).component(.year, from: Date()) - 2
    var listStations = false
}

func parseArguments() -> Arguments {
    var arguments = Arguments()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let flag = iterator.next() {
        switch flag {
        case "--lat": arguments.latitude = iterator.next().flatMap(Double.init)
        case "--lon": arguments.longitude = iterator.next().flatMap(Double.init)
        case "--station": arguments.stationID = iterator.next()
        case "--from": arguments.firstYear = iterator.next().flatMap(Int.init) ?? arguments.firstYear
        case "--to": arguments.lastYear = iterator.next().flatMap(Int.init) ?? arguments.lastYear
        case "--list": arguments.listStations = true
        default: FileHandle.standardError.write(Data("Ignoring unknown flag \(flag)\n".utf8))
        }
    }
    return arguments
}

func fahrenheit(_ celsius: Double?) -> String {
    guard let celsius else { return "  —  " }
    return String(format: "%6.1f", celsius * 9 / 5 + 32)
}

func run() async throws {
    let arguments = parseArguments()
    guard let latitude = arguments.latitude, let longitude = arguments.longitude else {
        print("Usage: loadsight-weather --lat <degrees> --lon <degrees> [--from <year>] [--to <year>] [--station <id>] [--list]")
        return
    }
    let years = arguments.firstYear...arguments.lastYear
    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("LoadSight/ISD")
    let client = ISDClient(configuration: .init(cacheDirectory: cache))

    let candidates = try await client.nearestStations(latitude: latitude, longitude: longitude,
                                                      covering: years, limit: 8)
    if arguments.listStations {
        print("Stations reporting across \(years.lowerBound)–\(years.upperBound):\n")
        for station in candidates {
            let distance = station.distanceKM(toLatitude: latitude, longitude: longitude)
            let elevation = station.elevationM.map { String(format: "%5.0f m", $0) } ?? "      ?"
            print(String(format: "  %@  %6.1f km  %@  %@", station.id, distance, elevation, station.name))
        }
        return
    }

    let started = Date()
    let conditions: DesignConditions
    if let requested = arguments.stationID {
        guard let match = try await client.stations().stations.first(where: { $0.id == requested }) else {
            print("No station with id \(requested).")
            return
        }
        FileHandle.standardError.write(Data("Reading \(match.name) (\(match.id)), \(years.lowerBound)–\(years.upperBound)…\n".utf8))
        conditions = try await client.designConditions(
            station: match, years: years,
            distanceFromSiteKM: match.distanceKM(toLatitude: latitude, longitude: longitude))
    } else {
        // Let the client probe candidates and reject stations that do not report what
        // design work needs, rather than taking the nearest pin on the map.
        FileHandle.standardError.write(Data("Selecting a station near \(latitude), \(longitude)…\n".utf8))
        conditions = try await client.designConditions(latitude: latitude, longitude: longitude, years: years)
    }
    let elapsed = Date().timeIntervalSince(started)
    let provenance = conditions.provenance

    print("")
    print("DESIGN CONDITIONS — \(provenance.stationName)")
    print(String(repeating: "=", count: 64))
    print(String(format: "Station %@   %.1f km from site   elevation %@",
                 provenance.stationID, provenance.distanceFromSiteKM ?? 0,
                 provenance.elevationM.map { String(format: "%.0f m", $0) } ?? "unpublished"))
    print(String(format: "Record  %d–%d   %d hourly observations   derived in %.1f s",
                 provenance.firstYear, provenance.lastYear,
                 provenance.hoursUsed, elapsed))
    print("")
    print("HEATING            °F      °C")
    for condition in conditions.heating {
        print(String(format: "  %5.1f%%        %@  %6.1f", condition.exceedancePercent,
                     fahrenheit(condition.dryBulbC), condition.dryBulbC))
    }
    print("")
    print("COOLING          DB °F  MCWB °F    DB °C  MCWB °C   n")
    for condition in conditions.cooling {
        print(String(format: "  %5.1f%%        %@   %@   %6.1f   %6.1f  %5d",
                     condition.exceedancePercent,
                     fahrenheit(condition.dryBulbC), fahrenheit(condition.meanCoincidentWetBulbC),
                     condition.dryBulbC, condition.meanCoincidentWetBulbC ?? .nan,
                     condition.coincidentSampleCount))
    }
    if !conditions.dehumidification.isEmpty {
        print("")
        print("DEHUMIDIFICATION  DP °F  MCDB °F   grains/lb")
        for condition in conditions.dehumidification {
            let grains = condition.grainsPerPound.map { String(format: "%8.1f", $0) } ?? "       —"
            print(String(format: "  %5.1f%%        %@   %@  %@", condition.exceedancePercent,
                         fahrenheit(condition.dewPointC), fahrenheit(condition.meanCoincidentDryBulbC), grains))
        }
    }
    print("")
    if let range = conditions.coolingDailyRangeF, let month = conditions.warmestMonth {
        print(String(format: "Cooling daily range  %.1f °F  (warmest month: %d)", range, month))
    }
    if let low = conditions.extremeAnnualMinimumC, let high = conditions.extremeAnnualMaximumC {
        print(String(format: "Mean annual extremes  %@ °F to %@ °F", fahrenheit(low), fahrenheit(high)))
    }
    print("")
    print("PROVENANCE")
    print("  " + conditions.provenance.citation)
    print(String(format: "  Rejected: %d suspect, %d missing, %d malformed",
                 conditions.provenance.hoursRejectedQuality,
                 conditions.provenance.hoursRejectedMissing,
                 conditions.provenance.hoursRejectedMalformed))
    for warning in conditions.provenance.warnings {
        print("  ! " + warning)
    }
}

try await run()
