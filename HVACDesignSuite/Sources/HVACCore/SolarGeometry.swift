import Foundation

/// Solar position and clear-sky irradiance.
///
/// This replaces the provisional per-orientation irradiance the first build shipped with.
/// Nothing here is tabulated: the sun's position is astronomy, and the clear-sky
/// irradiance is the Bird & Hulstrom model, published by NREL and in the public domain.
/// Both are computed for the actual latitude, day and hour, so a west wall in Winston-Salem
/// in July gets the irradiance that actually falls on it rather than a book value for
/// "west".
///
/// Everything is a pure function. Angles are degrees at the boundary and radians inside.
public enum Solar {

    /// Solar constant, W/m².
    public static let solarConstant = 1367.0

    /// 1 W/m² expressed in Btu/h·ft².
    public static let wattsPerSquareMeterToBtuh = 0.316998

    // MARK: - Position

    public struct Position: Sendable, Equatable {
        /// Degrees above the horizon. Negative when the sun is down.
        public let altitude: Double
        /// Degrees clockwise from true north.
        public let azimuth: Double
        /// Degrees from vertical.
        public var zenith: Double { 90 - altitude }
        public var isUp: Bool { altitude > 0 }
    }

    /// Day of year, 1–365, for the middle of a month.
    /// Using a representative day keeps a design calculation to one day rather than 365.
    public static func representativeDay(month: Int) -> Int {
        let days = [17, 47, 75, 105, 135, 162, 198, 228, 258, 288, 318, 344]
        guard (1...12).contains(month) else { return 198 }
        return days[month - 1]
    }

    /// Solar declination, degrees. Cooper's approximation, within about 0.5° — far finer
    /// than the design calculation's other uncertainties.
    public static func declination(dayOfYear: Int) -> Double {
        23.45 * sin(radians(360 * Double(284 + dayOfYear) / 365))
    }

    /// Equation of time, minutes.
    public static func equationOfTime(dayOfYear: Int) -> Double {
        let b = radians(360 * Double(dayOfYear - 81) / 364)
        return 9.87 * sin(2 * b) - 7.53 * cos(b) - 1.5 * sin(b)
    }

    /// Sun position for a latitude and a solar hour.
    ///
    /// `solarHour` is apparent solar time, where 12.0 is solar noon. Design work is done
    /// in solar time because the peak on a west wall is a fact about the sun, not about
    /// which time zone the building is filed under.
    public static func position(latitude: Double, dayOfYear: Int, solarHour: Double) -> Position {
        let phi = radians(latitude)
        let delta = radians(declination(dayOfYear: dayOfYear))
        let omega = radians(15 * (solarHour - 12))

        let sinAltitude = sin(delta) * sin(phi) + cos(delta) * cos(phi) * cos(omega)
        let altitude = degrees(asin(max(-1, min(1, sinAltitude))))

        // Azimuth measured from south, positive toward west, then rotated to a
        // clockwise-from-north convention.
        let azimuthFromSouth = degrees(atan2(sin(omega),
                                             cos(omega) * sin(phi) - tan(delta) * cos(phi)))
        var azimuth = azimuthFromSouth + 180
        if azimuth < 0 { azimuth += 360 }
        if azimuth >= 360 { azimuth -= 360 }

        return Position(altitude: altitude, azimuth: azimuth)
    }

    // MARK: - Clear-sky irradiance

    /// Atmospheric inputs to the Bird model.
    ///
    /// The defaults are the model's own documented defaults — a clear continental
    /// atmosphere. They are conservative for design work; a hazier day admits less beam.
    public struct Atmosphere: Sendable, Equatable {
        public var ozoneCentimeters: Double
        public var waterVaporCentimeters: Double
        public var aerosolOpticalDepth380: Double
        public var aerosolOpticalDepth500: Double
        public var groundAlbedo: Double

        public static let clearContinental = Atmosphere(
            ozoneCentimeters: 0.3, waterVaporCentimeters: 1.5,
            aerosolOpticalDepth380: 0.1, aerosolOpticalDepth500: 0.15,
            groundAlbedo: 0.2)

        /// A humid summer atmosphere, which is what a Piedmont cooling design day is.
        /// More water vapour cuts the beam and lifts the diffuse fraction.
        public static let humidSummer = Atmosphere(
            ozoneCentimeters: 0.3, waterVaporCentimeters: 4.0,
            aerosolOpticalDepth380: 0.15, aerosolOpticalDepth500: 0.20,
            groundAlbedo: 0.2)
    }

    /// Clear-sky irradiance components on a horizontal surface, Btu/h·ft².
    public struct ClearSky: Sendable, Equatable {
        public let directNormal: Double
        public let diffuseHorizontal: Double
        public let globalHorizontal: Double
    }

    /// The Bird & Hulstrom clear-sky model.
    ///
    /// Direct beam, diffuse and global on a horizontal surface, from transmittances for
    /// Rayleigh scattering, ozone, uniformly mixed gases, water vapour and aerosols. NREL
    /// states agreement with rigorous radiative transfer codes within about 10%.
    public static func clearSky(position: Position, dayOfYear: Int,
                                altitudeFeet: Double,
                                atmosphere: Atmosphere = .clearContinental) -> ClearSky {
        guard position.isUp else { return ClearSky(directNormal: 0, diffuseHorizontal: 0, globalHorizontal: 0) }

        let zenith = position.zenith
        let cosZenith = cos(radians(zenith))

        // Kasten–Young relative air mass, which stays finite at the horizon.
        let airMass = 1 / (cosZenith + 0.50572 * pow(96.07995 - zenith, -1.6364))

        // Pressure-corrected air mass. Station pressure comes from the site elevation.
        let pressureMillibar = Psychrometrics.pressure(altitudeFeet: altitudeFeet) * 68.9476
        let correctedAirMass = airMass * pressureMillibar / 1013.25

        // Extraterrestrial normal irradiance, corrected for orbital eccentricity.
        let eccentricity = 1 + 0.033 * cos(radians(360 * Double(dayOfYear) / 365))
        let extraterrestrial = solarConstant * eccentricity

        // Rayleigh scattering.
        let tRayleigh = exp(-0.0903 * pow(correctedAirMass, 0.84)
                            * (1 + correctedAirMass - pow(correctedAirMass, 1.01)))

        // Ozone.
        let ozonePath = atmosphere.ozoneCentimeters * airMass
        let tOzone = 1
            - 0.1611 * ozonePath * pow(1 + 139.48 * ozonePath, -0.3035)
            - 0.002715 * ozonePath / (1 + 0.044 * ozonePath + 0.0003 * ozonePath * ozonePath)

        // Uniformly mixed gases.
        let tGases = exp(-0.0127 * pow(correctedAirMass, 0.26))

        // Water vapour.
        let waterPath = atmosphere.waterVaporCentimeters * airMass
        let tWater = 1 - 2.4959 * waterPath
            / (pow(1 + 79.034 * waterPath, 0.6828) + 6.385 * waterPath)

        // Aerosols. The broadband depth is the documented weighting of the 380 nm and
        // 500 nm depths.
        let tau = 0.2758 * atmosphere.aerosolOpticalDepth380 + 0.35 * atmosphere.aerosolOpticalDepth500
        let tAerosol = exp(-pow(tau, 0.873) * (1 + tau - pow(tau, 0.7088))
                           * pow(airMass, 0.9108))
        let tAerosolAbsorption = 1 - 0.1 * (1 - airMass + pow(airMass, 1.06)) * (1 - tAerosol)
        let tAerosolScattering = tAerosolAbsorption > 0 ? tAerosol / tAerosolAbsorption : 0

        // Direct normal.
        let directNormal = 0.9662 * extraterrestrial
            * tRayleigh * tOzone * tGases * tWater * tAerosol

        // Diffuse on the horizontal.
        let denominator = 1 - airMass + pow(airMass, 1.02)
        let diffuseRaw = 0.79 * extraterrestrial * cosZenith
            * tOzone * tGases * tWater * tAerosolAbsorption
            * (0.5 * (1 - tRayleigh) + 0.84 * (1 - tAerosolScattering))
            / max(denominator, 1e-9)

        // Multiple reflection between ground and sky.
        let skyAlbedo = 0.0685 + (1 - 0.84) * (1 - tAerosolScattering)
        let globalRaw = (directNormal * cosZenith + diffuseRaw)
            / max(1 - atmosphere.groundAlbedo * skyAlbedo, 1e-9)

        let toBtuh = wattsPerSquareMeterToBtuh
        return ClearSky(directNormal: max(0, directNormal) * toBtuh,
                        diffuseHorizontal: max(0, diffuseRaw) * toBtuh,
                        globalHorizontal: max(0, globalRaw) * toBtuh)
    }

    // MARK: - Irradiance on a surface

    /// Total irradiance on a tilted, oriented surface, Btu/h·ft².
    ///
    /// Beam by incidence angle, sky diffuse isotropic, plus ground reflection. The
    /// isotropic sky is the conservative choice: it understates a surface facing the sun's
    /// half of the sky and overstates one facing away, and it introduces no coefficients
    /// that need a licence.
    public static func irradiance(on surfaceAzimuth: Double, tilt: Double,
                                  position: Position, clearSky: ClearSky,
                                  groundAlbedo: Double = 0.2) -> Double {
        guard position.isUp else { return 0 }
        let tiltRadians = radians(tilt)

        // cos θ = cos α · cos(γₛ − γ) · sin β + sin α · cos β
        let altitude = radians(position.altitude)
        let azimuthDifference = radians(position.azimuth - surfaceAzimuth)
        let cosIncidence = cos(altitude) * cos(azimuthDifference) * sin(tiltRadians)
                         + sin(altitude) * cos(tiltRadians)

        let beam = clearSky.directNormal * max(0, cosIncidence)
        let skyDiffuse = clearSky.diffuseHorizontal * (1 + cos(tiltRadians)) / 2
        let groundReflected = clearSky.globalHorizontal * groundAlbedo * (1 - cos(tiltRadians)) / 2
        return beam + skyDiffuse + groundReflected
    }

    /// The peak irradiance a surface sees on the design day, and the hour it happens.
    ///
    /// Scanned rather than looked up. A west wall peaks in the late afternoon and a south
    /// wall near noon; in the Piedmont the two differ by hundreds of Btu/h·ft², which is
    /// why one book value for every orientation was the largest error in the first build.
    public static func peakIrradiance(surfaceAzimuth: Double, tilt: Double,
                                      latitude: Double, month: Int, altitudeFeet: Double,
                                      atmosphere: Atmosphere = .humidSummer)
    -> (irradiance: Double, solarHour: Double) {
        let day = representativeDay(month: month)
        var best = (irradiance: 0.0, solarHour: 12.0)
        for step in 0...(24 * 4) {
            let hour = Double(step) / 4
            let sun = position(latitude: latitude, dayOfYear: day, solarHour: hour)
            guard sun.isUp else { continue }
            let sky = clearSky(position: sun, dayOfYear: day,
                               altitudeFeet: altitudeFeet, atmosphere: atmosphere)
            let total = irradiance(on: surfaceAzimuth, tilt: tilt,
                                   position: sun, clearSky: sky,
                                   groundAlbedo: atmosphere.groundAlbedo)
            if total > best.irradiance { best = (total, hour) }
        }
        return best
    }

    // MARK: - Helpers

    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}

// MARK: - Orientation geometry

public extension Orientation {
    /// Degrees clockwise from true north.
    var azimuth: Double {
        switch self {
        case .north: 0
        case .northEast: 45
        case .east: 90
        case .southEast: 135
        case .south: 180
        case .southWest: 225
        case .west: 270
        case .northWest: 315
        case .horizontal: 180   // irrelevant at zero tilt
        }
    }

    /// Degrees from horizontal. Walls and windows are vertical; a roof is flat here.
    var tilt: Double { self == .horizontal ? 0 : 90 }
}
