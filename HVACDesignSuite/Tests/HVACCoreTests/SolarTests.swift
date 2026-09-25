import XCTest
@testable import HVACCore

final class SolarTests: XCTestCase {

    /// Solar noon altitude is an identity: 90° − |latitude − declination|.
    /// It needs no model to check, which makes it the right anchor for the geometry.
    func testSolarNoonAltitudeMatchesTheIdentity() {
        for (latitude, month) in [(36.1, 6), (36.1, 12), (0.0, 3), (45.0, 9)] {
            let day = Solar.representativeDay(month: month)
            let declination = Solar.declination(dayOfYear: day)
            let sun = Solar.position(latitude: latitude, dayOfYear: day, solarHour: 12)
            XCTAssertEqual(sun.altitude, 90 - abs(latitude - declination), accuracy: 0.6,
                           "lat \(latitude) month \(month)")
        }
    }

    /// At solar noon in the northern hemisphere, with the sun south of the site,
    /// azimuth is due south.
    func testSolarNoonAzimuthIsDueSouth() {
        let sun = Solar.position(latitude: 36.1, dayOfYear: Solar.representativeDay(month: 7), solarHour: 12)
        XCTAssertEqual(sun.azimuth, 180, accuracy: 0.5)
    }

    func testSunRisesInTheEastAndSetsInTheWest() {
        let day = Solar.representativeDay(month: 7)
        let morning = Solar.position(latitude: 36.1, dayOfYear: day, solarHour: 7)
        let evening = Solar.position(latitude: 36.1, dayOfYear: day, solarHour: 17)
        XCTAssertLessThan(morning.azimuth, 180)     // east of south
        XCTAssertGreaterThan(evening.azimuth, 180)  // west of south
        XCTAssertTrue(morning.isUp)
        XCTAssertTrue(evening.isUp)
        XCTAssertFalse(Solar.position(latitude: 36.1, dayOfYear: day, solarHour: 1).isUp)
    }

    func testDeclinationSwingsBetweenTheTropics() {
        let june = Solar.declination(dayOfYear: Solar.representativeDay(month: 6))
        let december = Solar.declination(dayOfYear: Solar.representativeDay(month: 12))
        XCTAssertEqual(june, 23.4, accuracy: 0.6)
        XCTAssertEqual(december, -23.4, accuracy: 0.6)
    }

    /// Clear-sky direct normal at high sun should land in the physically sensible band.
    /// The Bird model is stated to agree with rigorous radiative transfer within ~10%.
    func testClearSkyDirectNormalIsPhysical() {
        let day = Solar.representativeDay(month: 7)
        let sun = Solar.position(latitude: 36.1, dayOfYear: day, solarHour: 12)
        let sky = Solar.clearSky(position: sun, dayOfYear: day, altitudeFeet: 902,
                                 atmosphere: .humidSummer)
        // 1367 W/m² is 433 Btu/h·ft² at the top of the atmosphere; a clear humid day at
        // the surface passes roughly 60–80% of it as beam.
        XCTAssertGreaterThan(sky.directNormal, 200)
        XCTAssertLessThan(sky.directNormal, 330)
        XCTAssertGreaterThan(sky.diffuseHorizontal, 10)
        XCTAssertGreaterThan(sky.globalHorizontal, sky.diffuseHorizontal)
    }

    func testNightProducesNoIrradiance() {
        let day = Solar.representativeDay(month: 7)
        let sun = Solar.position(latitude: 36.1, dayOfYear: day, solarHour: 2)
        let sky = Solar.clearSky(position: sun, dayOfYear: day, altitudeFeet: 902)
        XCTAssertEqual(sky.directNormal, 0)
        XCTAssertEqual(sky.globalHorizontal, 0)
    }

    /// The finding the provisional table could never express: a west wall peaks in the
    /// late afternoon and an east wall in the morning.
    func testEastAndWestPeakAtOppositeEndsOfTheDay() {
        let east = Solar.peakIrradiance(surfaceAzimuth: 90, tilt: 90, latitude: 36.1,
                                        month: 7, altitudeFeet: 902)
        let west = Solar.peakIrradiance(surfaceAzimuth: 270, tilt: 90, latitude: 36.1,
                                        month: 7, altitudeFeet: 902)
        XCTAssertLessThan(east.solarHour, 11)
        XCTAssertGreaterThan(west.solarHour, 13)
        // Symmetric geometry, so the peaks themselves match closely.
        XCTAssertEqual(east.irradiance, west.irradiance, accuracy: 6)
    }

    /// In July at 36° N the sun is high at noon, so a south wall sees a glancing beam and
    /// takes less than an east or west wall. This is the single most important thing the
    /// provisional table had backwards in spirit — it is also why summer overhangs work.
    func testSouthWallTakesLessThanWestInMidsummer() {
        let south = Solar.peakIrradiance(surfaceAzimuth: 180, tilt: 90, latitude: 36.1,
                                         month: 7, altitudeFeet: 902).irradiance
        let west = Solar.peakIrradiance(surfaceAzimuth: 270, tilt: 90, latitude: 36.1,
                                        month: 7, altitudeFeet: 902).irradiance
        let north = Solar.peakIrradiance(surfaceAzimuth: 0, tilt: 90, latitude: 36.1,
                                         month: 7, altitudeFeet: 902).irradiance
        XCTAssertLessThan(south, west)
        XCTAssertLessThan(north, south)
    }

    /// And the reverse in winter, when the low sun strikes a south wall squarely.
    func testSouthWallBeatsWestInWinter() {
        let south = Solar.peakIrradiance(surfaceAzimuth: 180, tilt: 90, latitude: 36.1,
                                         month: 12, altitudeFeet: 902).irradiance
        let west = Solar.peakIrradiance(surfaceAzimuth: 270, tilt: 90, latitude: 36.1,
                                        month: 12, altitudeFeet: 902).irradiance
        XCTAssertGreaterThan(south, west)
    }

    func testHorizontalTakesTheMostInSummer() {
        let horizontal = Solar.peakIrradiance(surfaceAzimuth: 180, tilt: 0, latitude: 36.1,
                                              month: 7, altitudeFeet: 902).irradiance
        for azimuth in stride(from: 0.0, to: 360.0, by: 45) {
            let vertical = Solar.peakIrradiance(surfaceAzimuth: azimuth, tilt: 90,
                                                latitude: 36.1, month: 7, altitudeFeet: 902).irradiance
            XCTAssertGreaterThan(horizontal, vertical, "azimuth \(azimuth)")
        }
    }

    /// Latitude is a real input, not a label.
    func testLatitudeChangesThePeak() {
        let triad = Solar.peakIrradiance(surfaceAzimuth: 180, tilt: 90, latitude: 36.1,
                                         month: 12, altitudeFeet: 902).irradiance
        let maine = Solar.peakIrradiance(surfaceAzimuth: 180, tilt: 90, latitude: 45.0,
                                         month: 12, altitudeFeet: 902).irradiance
        XCTAssertNotEqual(triad, maine, accuracy: 0.5)
    }
}

final class GlazingTests: XCTestCase {

    func testLibraryIsPhysicallyOrdered() {
        XCTAssertGreaterThan(GlazingType.singlePaneAluminum.uFactor, GlazingType.doublePaneVinyl.uFactor)
        XCTAssertGreaterThan(GlazingType.doublePaneVinyl.uFactor, GlazingType.doublePaneLowEArgon.uFactor)
        XCTAssertGreaterThan(GlazingType.doublePaneLowEArgon.uFactor, GlazingType.triplePaneLowEArgon.uFactor)
        // Low-E cuts solar transmission, which is the whole point of the coating.
        XCTAssertLessThan(GlazingType.doublePaneLowE.solarHeatGainCoefficient,
                          GlazingType.doublePaneVinyl.solarHeatGainCoefficient)
    }

    func testEveryGlazingEntryIsPlausible() {
        for glazing in GlazingType.library {
            XCTAssertGreaterThan(glazing.uFactor, 0.1, glazing.name)
            XCTAssertLessThan(glazing.uFactor, 1.3, glazing.name)
            XCTAssertGreaterThan(glazing.solarHeatGainCoefficient, 0.1, glazing.name)
            XCTAssertLessThan(glazing.solarHeatGainCoefficient, 0.9, glazing.name)
            XCTAssertEqual(glazing.rValue, 1 / glazing.uFactor, accuracy: 1e-9)
        }
    }

    func testShadingReducesAdmittedSolar() {
        let window = GlazingType.doublePaneLowEArgon
        XCTAssertEqual(window.effectiveSHGC(shading: .none),
                       window.solarHeatGainCoefficient, accuracy: 1e-9)
        XCTAssertLessThan(window.effectiveSHGC(shading: .exteriorAwning),
                          window.effectiveSHGC(shading: .interiorBlindsLight))
    }

    func testCertifiedValuesAreMarked() {
        let window = GlazingType.certified(name: "Model X", uFactor: 0.28, shgc: 0.22)
        XCTAssertTrue(window.isCertified)
        XCTAssertFalse(GlazingType.doublePaneLowE.isCertified)
    }
}

final class FittingTests: XCTestCase {

    /// The advantage over a fixed table: the same elbow is worth more equivalent length
    /// in a big trunk than in a small branch, because it is replacing lossier duct.
    func testEquivalentLengthScalesWithDuctSize() {
        let elbow = FittingType.elbow90Smooth
        let roughness = DuctMaterial.galvanizedSteel.roughnessFeet
        let small = elbow.equivalentLength(diameterInches: 6, cfm: 100, roughnessFeet: roughness)
        let large = elbow.equivalentLength(diameterInches: 16, cfm: 1200, roughnessFeet: roughness)
        XCTAssertGreaterThan(large, small)
        // A 6 in. smooth elbow lands in single-digit feet, as Manual D's tables do.
        XCTAssertGreaterThan(small, 2)
        XCTAssertLessThan(small, 15)
    }

    func testMiteredElbowCostsFarMoreThanSmooth() {
        let roughness = DuctMaterial.galvanizedSteel.roughnessFeet
        let smooth = FittingType.elbow90Smooth.equivalentLength(diameterInches: 8, cfm: 300, roughnessFeet: roughness)
        let mitered = FittingType.elbow90Mitered.equivalentLength(diameterInches: 8, cfm: 300, roughnessFeet: roughness)
        XCTAssertGreaterThan(mitered, smooth * 4)
    }

    /// A fitting in rough flexible duct is worth less equivalent length, because the duct
    /// it stands in for is already lossy.
    func testRoughDuctShortensEquivalentLength() {
        let elbow = FittingType.elbow90Smooth
        let metal = elbow.equivalentLength(diameterInches: 8, cfm: 300,
                                           roughnessFeet: DuctMaterial.galvanizedSteel.roughnessFeet)
        let flex = elbow.equivalentLength(diameterInches: 8, cfm: 300,
                                          roughnessFeet: DuctMaterial.flexibleDuctFullyExtended.roughnessFeet)
        XCTAssertLessThan(flex, metal)
    }

    func testComputedFittingBuildsAUsableRun() {
        let fitting = Fitting.computed(.boot90, count: 1, diameterInches: 6, cfm: 100)
        XCTAssertGreaterThan(fitting.totalEquivalentLength, 5)
        XCTAssertEqual(fitting.name, FittingType.boot90.name)
    }

    func testZeroAirflowIsSafe() {
        XCTAssertEqual(FittingType.elbow90Smooth.equivalentLength(diameterInches: 8, cfm: 0,
                                                                  roughnessFeet: 0.0003), 0)
    }
}
