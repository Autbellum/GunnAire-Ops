import XCTest
@testable import LoadSightWeather
import LoadSightCore

final class DelimitedTextTests: XCTestCase {
    func testQuotedFieldKeepsEmbeddedComma() {
        let line = Substring("\"72509014739\",\"2023-01-01T00:00:00\",\"BOSTON LOGAN INTERNATIONAL AIRPORT, MA US\",\"FM-12\"")
        let fields = DelimitedText.fields(in: line)
        XCTAssertEqual(fields.count, 4)
        XCTAssertEqual(fields[2], "BOSTON LOGAN INTERNATIONAL AIRPORT, MA US")
        XCTAssertEqual(fields[3], "FM-12")
    }

    func testDoubledQuoteUnescapes() {
        XCTAssertEqual(DelimitedText.fields(in: Substring("\"a\"\"b\",c")), ["a\"b", "c"])
    }

    func testHeaderResolvesByNameNotPosition() throws {
        let header = try DelimitedText.Header(Substring("\"STATION\",\"DATE\",\"NEW_COLUMN\",\"TMP\""))
        XCTAssertEqual(try header.index(of: "TMP"), 3)
        XCTAssertTrue(header.contains("date"))
        XCTAssertThrowsError(try header.index(of: "DEW"))
    }

    func testShortRowDoesNotTrap() {
        XCTAssertNil(["a", "b"].value(at: 7))
        XCTAssertNil(["a", "  "].value(at: 1))
    }
}

final class ISDObservationParsingTests: XCTestCase {
    func testTemperatureFieldScalesFromTenths() {
        XCTAssertEqual(ISDHourly.measurement("+0117,1"), .value(11.7))
        XCTAssertEqual(ISDHourly.measurement("-0283,5"), .value(-28.3))
    }

    func testMissingSentinelIsNotATemperature() {
        XCTAssertEqual(ISDHourly.measurement("+9999,9"), .missing)
        XCTAssertEqual(ISDHourly.measurement("-9999,1"), .missing)
    }

    func testSuspectAndErroneousCodesAreRejected() {
        for code in ["2", "3", "6", "7"] {
            XCTAssertEqual(ISDHourly.measurement("+0150,\(code)"), .rejected, "code \(code) should be rejected")
        }
        for code in ["0", "1", "4", "5", "9", "A", "C", "I", "M", "P", "R", "U"] {
            XCTAssertEqual(ISDHourly.measurement("+0150,\(code)"), .value(15), "code \(code) should be accepted")
        }
    }

    func testGrossPhysicalBoundCatchesCleanlyFlaggedNonsense() {
        XCTAssertEqual(ISDHourly.measurement("-0990,1"), .malformed)
        XCTAssertEqual(ISDHourly.measurement("+0800,1"), .malformed)
    }

    func testMalformedFieldsDoNotParse() {
        XCTAssertEqual(ISDHourly.measurement("0117"), .malformed)
        XCTAssertEqual(ISDHourly.measurement("abc,1"), .malformed)
    }

    func testTimestampParsesPositionally() throws {
        let moment = try XCTUnwrap(ISDHourly.timestamp("2023-07-04T13:51:00"))
        XCTAssertEqual(moment.year, 2023)
        XCTAssertEqual(moment.month, 7)
        XCTAssertEqual(moment.day, 4)
        XCTAssertEqual(moment.hour, 13)
        XCTAssertEqual(moment.minute, 51)
        XCTAssertNil(ISDHourly.timestamp("2023-13-04T13:51:00"))
        XCTAssertNil(ISDHourly.timestamp("short"))
    }

    /// Two reports in one hour must collapse to the one nearest the top of the hour,
    /// or busy stations and busy hours are over-weighted in every percentile.
    func testOneObservationPerHourNearestTheHour() throws {
        let csv = """
        "STATION","DATE","REPORT_TYPE","TMP","DEW"
        "72509014739","2023-01-01T00:51:00","FM-15","+0100,1","+0050,1"
        "72509014739","2023-01-01T00:12:00","FM-12","+0200,1","+0060,1"
        "72509014739","2023-01-01T01:54:00","FM-15","+0300,1","+0070,1"
        """
        let result = try ISDHourly.parse(csv: csv)
        XCTAssertEqual(result.observations.count, 2)
        XCTAssertEqual(result.duplicateHoursDropped, 1)
        XCTAssertEqual(result.observations[0].dryBulbC, 20.0, accuracy: 1e-9)
        XCTAssertEqual(result.observations[0].minute, 12)
        XCTAssertEqual(result.observations[1].dryBulbC, 30.0, accuracy: 1e-9)
    }

    func testAttritionIsCounted() throws {
        let csv = """
        "STATION","DATE","REPORT_TYPE","TMP","DEW"
        "1","2023-01-01T00:00:00","FM-15","+0100,1","+0050,1"
        "1","2023-01-01T01:00:00","FM-15","+9999,9","+9999,9"
        "1","2023-01-01T02:00:00","FM-15","+0150,3","+0050,1"
        "1","2023-01-01T03:00:00","FM-15","garbage","+0050,1"
        """
        let result = try ISDHourly.parse(csv: csv)
        XCTAssertEqual(result.rowsRead, 4)
        XCTAssertEqual(result.observations.count, 1)
        XCTAssertEqual(result.rejectedMissing, 1)
        XCTAssertEqual(result.rejectedQuality, 1)
        XCTAssertEqual(result.rejectedMalformed, 1)
    }

    func testDewPointAboveDryBulbIsClampedNotDiscarded() throws {
        let csv = """
        "STATION","DATE","REPORT_TYPE","TMP","DEW"
        "1","2023-01-01T00:00:00","FM-15","+0100,C","+0110,C"
        """
        let result = try ISDHourly.parse(csv: csv)
        let observation = try XCTUnwrap(result.observations.first)
        XCTAssertEqual(observation.dryBulbC, 10, accuracy: 1e-9)
        XCTAssertEqual(observation.dewPointC ?? .nan, 10, accuracy: 1e-9)
    }
}

final class ISDStationIndexTests: XCTestCase {
    private let csv = """
    "USAF","WBAN","STATION NAME","CTRY","STATE","ICAO","LAT","LON","ELEV(M)","BEGIN","END"
    "725090","14739","BOSTON LOGAN INTERNATIONAL AIRPORT, MA US","US","MA","KBOS","+42.361","-071.010","+3.2","19730101","20260901"
    "726050","14745","CONCORD","US","NH","KCON","+43.195","-071.502","+105.0","19730101","20260901"
    "999999","99999","RETIRED STATION","US","MA","","+42.400","-071.100","+5.0","19730101","19940101"
    "007018","99999","UNLOCATED","","","","+00.000","+000.000","+7018.0","20110309","20130730"
    """

    func testUnlocatedPlaceholderIsDropped() throws {
        let index = try ISDStationIndex(csv: csv)
        XCTAssertEqual(index.stations.count, 3)
        XCTAssertFalse(index.stations.contains { $0.name == "UNLOCATED" })
    }

    func testEmbeddedCommaInStationNameSurvives() throws {
        let index = try ISDStationIndex(csv: csv)
        let boston = try XCTUnwrap(index.stations.first { $0.id == "72509014739" })
        XCTAssertEqual(boston.name, "BOSTON LOGAN INTERNATIONAL AIRPORT, MA US")
        XCTAssertEqual(boston.latitude, 42.361, accuracy: 1e-6)
        XCTAssertEqual(boston.elevationM ?? .nan, 3.2, accuracy: 1e-6)
    }

    /// A station that stopped reporting in 1994 is useless for present design conditions
    /// however close it is, so the period-of-record filter must beat distance.
    func testCoverageFilterOutranksDistance() throws {
        let index = try ISDStationIndex(csv: csv)
        let unfiltered = try index.nearest(latitude: 42.39, longitude: -71.09, limit: 1)
        XCTAssertEqual(unfiltered.first?.name, "RETIRED STATION")

        let filtered = try index.nearest(latitude: 42.39, longitude: -71.09, covering: 2000...2025, limit: 1)
        XCTAssertEqual(filtered.first?.id, "72509014739")
    }

    func testHaversineAgainstAKnownSeparation() throws {
        let index = try ISDStationIndex(csv: csv)
        let boston = try XCTUnwrap(index.stations.first { $0.id == "72509014739" })
        // Boston Logan to Concord NH is about 105 km.
        let distance = boston.distanceKM(toLatitude: 43.195, longitude: -71.502)
        XCTAssertEqual(distance, 105, accuracy: 6)
        XCTAssertEqual(boston.distanceKM(toLatitude: 42.361, longitude: -71.010), 0, accuracy: 0.05)
    }

    func testStationPressureFallsWithElevation() throws {
        let index = try ISDStationIndex(csv: csv)
        let boston = try XCTUnwrap(index.stations.first { $0.id == "72509014739" })
        let concord = try XCTUnwrap(index.stations.first { $0.id == "72605014745" })
        XCTAssertEqual(boston.stationPressurePa, 101_287, accuracy: 60)
        XCTAssertLessThan(concord.stationPressurePa, boston.stationPressurePa)
    }

    func testRejectsImpossibleQueryPosition() throws {
        let index = try ISDStationIndex(csv: csv)
        XCTAssertThrowsError(try index.nearest(latitude: 95, longitude: 0))
    }
}

final class DesignConditionDerivationTests: XCTestCase {

    /// The definition that everything else rests on: a value quoted at X% is the value
    /// *exceeded* X% of the hours. Getting this backwards silently swaps heating and
    /// cooling design temperatures, so it is pinned against a distribution with a
    /// known answer rather than a physical plausibility check.
    func testExceedanceIsTheValueExceededThatPercentOfHours() throws {
        let sample = (0..<1000).map(Double.init).sorted()
        // Exceeded 0.4% of the time: exactly four of the thousand values (996…999) are
        // above 995.004, which is 0.4%.
        let cooling = try DesignConditionDerivation.exceedanceValue(sample, percent: 0.4)
        XCTAssertEqual(cooling, 995.004, accuracy: 0.01)
        XCTAssertEqual(sample.filter { $0 > cooling }.count, 4)

        // Exceeded 99.6% of the time: 996 of the thousand values are above 3.996.
        let heating = try DesignConditionDerivation.exceedanceValue(sample, percent: 99.6)
        XCTAssertEqual(heating, 3.996, accuracy: 0.01)
        XCTAssertEqual(sample.filter { $0 > heating }.count, 996)

        XCTAssertEqual(try DesignConditionDerivation.exceedanceValue(sample, percent: 50), 499.5, accuracy: 0.01)
    }

    func testQuantileEndpointsAndInterpolation() throws {
        let sample = [0.0, 10.0, 20.0, 30.0]
        XCTAssertEqual(try DesignConditionDerivation.quantile(sample, fraction: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(try DesignConditionDerivation.quantile(sample, fraction: 1), 30, accuracy: 1e-9)
        XCTAssertEqual(try DesignConditionDerivation.quantile(sample, fraction: 0.5), 15, accuracy: 1e-9)
        XCTAssertEqual(try DesignConditionDerivation.quantile([42], fraction: 0.3), 42, accuracy: 1e-9)
        XCTAssertThrowsError(try DesignConditionDerivation.quantile([], fraction: 0.5))
        XCTAssertThrowsError(try DesignConditionDerivation.quantile(sample, fraction: 1.4))
    }

    func testWarmestMonthIsChosenByMeanTemperatureAndThinDaysExcluded() {
        var observations: [ISDObservation] = []
        // January: cold. July: warm, with a full 24-hour day and a thin 3-hour day.
        for hour in 0..<24 {
            observations.append(ISDObservation(year: 2023, month: 1, day: 1, hour: hour, minute: 0,
                                               dryBulbC: -5, dewPointC: -10))
            observations.append(ISDObservation(year: 2023, month: 7, day: 1, hour: hour, minute: 0,
                                               dryBulbC: 20 + Double(hour % 12), dewPointC: 15))
        }
        for hour in 0..<3 {
            observations.append(ISDObservation(year: 2023, month: 7, day: 2, hour: hour, minute: 0,
                                               dryBulbC: 25 + Double(hour) * 10, dewPointC: 15))
        }
        let (range, month) = DesignConditionDerivation.warmestMonthDailyRange(observations)
        XCTAssertEqual(month, 7)
        // Only 1 July qualifies; its range is 11 °C. The thin 2 July day would have
        // reported 20 °C and must not contribute.
        XCTAssertEqual(range ?? .nan, 11, accuracy: 1e-9)
    }

    func testAnnualExtremesAverageAcrossYears() {
        let observations = [
            ISDObservation(year: 2022, month: 1, day: 1, hour: 0, minute: 0, dryBulbC: -10, dewPointC: nil),
            ISDObservation(year: 2022, month: 7, day: 1, hour: 0, minute: 0, dryBulbC: 30, dewPointC: nil),
            ISDObservation(year: 2023, month: 1, day: 1, hour: 0, minute: 0, dryBulbC: -20, dewPointC: nil),
            ISDObservation(year: 2023, month: 7, day: 1, hour: 0, minute: 0, dryBulbC: 40, dewPointC: nil)
        ]
        let extremes = DesignConditionDerivation.annualExtremes(observations)
        XCTAssertEqual(extremes.minimum ?? .nan, -15, accuracy: 1e-9)
        XCTAssertEqual(extremes.maximum ?? .nan, 35, accuracy: 1e-9)
    }

    // MARK: - End to end

    private func syntheticYear(year: Int) -> [ISDObservation] {
        // A smooth annual swing with a daily swing on top, so the percentiles and the
        // daily range both have a value that can be reasoned about.
        var observations: [ISDObservation] = []
        let daysInMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        var dayOfYear = 0
        for month in 1...12 {
            for day in 1...daysInMonth[month - 1] {
                dayOfYear += 1
                let seasonal = 15 - 18 * cos(2 * .pi * Double(dayOfYear - 15) / 365)
                for hour in 0..<24 {
                    let daily = 5 * sin(2 * .pi * Double(hour - 9) / 24)
                    let dryBulb = seasonal + daily
                    observations.append(ISDObservation(year: year, month: month, day: day, hour: hour,
                                                       minute: 0, dryBulbC: dryBulb,
                                                       dewPointC: min(dryBulb - 3, 18)))
                }
            }
        }
        return observations
    }

    private var station: ISDStation {
        ISDStation(usaf: "725090", wban: "14739", name: "TEST FIELD", country: "US", state: "MA",
                   icao: "KTST", latitude: 42.36, longitude: -71.01, elevationM: 3.2,
                   beginYear: 2014, endYear: 2023)
    }

    func testDerivationProducesOrderedPhysicalConditions() throws {
        let observations = (2014...2023).flatMap(syntheticYear)
        let conditions = try DesignConditionDerivation.derive(
            observations: observations, station: station, read: ISDReadTotals())

        let heating996 = try XCTUnwrap(conditions.heating(at: 99.6))
        let heating99 = try XCTUnwrap(conditions.heating(at: 99))
        let cooling2 = try XCTUnwrap(conditions.cooling(at: 2))
        let cooling1 = try XCTUnwrap(conditions.cooling(at: 1))
        let cooling04 = try XCTUnwrap(conditions.cooling(at: 0.4))

        // Ordering is the invariant that catches a reversed percentile everywhere at once.
        XCTAssertLessThan(heating996.dryBulbC, heating99.dryBulbC)
        XCTAssertLessThan(heating99.dryBulbC, cooling2.dryBulbC)
        XCTAssertLessThan(cooling2.dryBulbC, cooling1.dryBulbC)
        XCTAssertLessThan(cooling1.dryBulbC, cooling04.dryBulbC)

        // The generator swings between roughly -8 and +38 °C.
        XCTAssertEqual(heating996.dryBulbC, -7, accuracy: 2.5)
        XCTAssertEqual(cooling04.dryBulbC, 37, accuracy: 2.5)

        // Daily swing is ±5 °C, so the mean daily range is about 10 °C.
        XCTAssertEqual(conditions.coolingDailyRangeC ?? .nan, 10, accuracy: 0.5)
        XCTAssertEqual(conditions.warmestMonth, 7)
    }

    func testMeanCoincidentWetBulbIsBetweenDewPointAndDryBulb() throws {
        let observations = (2014...2023).flatMap(syntheticYear)
        let conditions = try DesignConditionDerivation.derive(
            observations: observations, station: station, read: ISDReadTotals())
        let cooling = try XCTUnwrap(conditions.cooling(at: 1))
        let wetBulb = try XCTUnwrap(cooling.meanCoincidentWetBulbC)
        XCTAssertGreaterThan(cooling.coincidentSampleCount, DesignConditionDerivation.minimumCoincidentSamples)
        XCTAssertLessThan(wetBulb, cooling.dryBulbC)
        XCTAssertGreaterThan(wetBulb, 0)
    }

    func testFahrenheitAccessorsConvert() throws {
        let observations = syntheticYear(year: 2023)
        let conditions = try DesignConditionDerivation.derive(
            observations: observations, station: station, read: ISDReadTotals())
        let cooling = try XCTUnwrap(conditions.cooling(at: 1))
        XCTAssertEqual(cooling.dryBulbF, cooling.dryBulbC * 9 / 5 + 32, accuracy: 1e-9)
        let range = try XCTUnwrap(conditions.coolingDailyRangeF)
        XCTAssertEqual(range, (conditions.coolingDailyRangeC ?? 0) * 9 / 5, accuracy: 1e-9)
    }

    func testShortRecordIsFlaggedNotSilentlyAccepted() throws {
        let conditions = try DesignConditionDerivation.derive(
            observations: syntheticYear(year: 2023), station: station, read: ISDReadTotals())
        XCTAssertTrue(conditions.provenance.warnings.contains { $0.contains("year(s) of record") })
    }

    func testMissingElevationIsFlaggedAndAssumedSeaLevel() throws {
        let unlocated = ISDStation(usaf: "1", wban: "2", name: "NO ELEVATION", country: "US", state: "",
                                   icao: "", latitude: 42, longitude: -71, elevationM: nil,
                                   beginYear: 2014, endYear: 2023)
        let conditions = try DesignConditionDerivation.derive(
            observations: syntheticYear(year: 2023), station: unlocated, read: ISDReadTotals())
        XCTAssertTrue(conditions.provenance.elevationAssumed)
        XCTAssertEqual(conditions.provenance.stationPressurePa, 101_325, accuracy: 1)
        XCTAssertTrue(conditions.provenance.warnings.contains { $0.contains("no published elevation") })
    }

    func testEmptyObservationsAreRefused() {
        XCTAssertThrowsError(try DesignConditionDerivation.derive(
            observations: [], station: station, read: ISDReadTotals()))
    }

    /// The citation is what a reviewing engineer reads. It must never imply the numbers
    /// are ASHRAE's published table.
    func testCitationDisclaimsASHRAEProvenance() throws {
        let conditions = try DesignConditionDerivation.derive(
            observations: syntheticYear(year: 2023), station: station, read: ISDReadTotals())
        let citation = conditions.provenance.citation
        XCTAssertTrue(citation.contains("TEST FIELD"))
        XCTAssertTrue(citation.contains("NOAA Integrated"))
        XCTAssertTrue(citation.contains("not ASHRAE published design conditions"))
    }
}
