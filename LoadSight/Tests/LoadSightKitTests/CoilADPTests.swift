import XCTest
import LoadSightKit

final class CoilADPTests: XCTestCase {
    private func saturatedW(_ t: Double, _ p: Double) throws -> Double {
        try Psychrometrics.state(dryBulbC:t,relativeHumidity:1,pressurePa:p).humidityRatio
    }
    func testConstructedADPAndBypassGrid() throws {
        // Construct a process line through a known saturation point, below the saturation curve.
        // The input ADP and bypass factors are the expected answers, not outputs from the solver.
        var count = 0
        for p in [85000.0,101325.0,120000.0] {
            for t in [-10.0,0,5,10,20] {
                let w = try saturatedW(t,p)
                let derivative = try (saturatedW(t+0.0001,p)-saturatedW(t-0.0001,p))/0.0002
                let inletT = t+20, inletW = w+derivative*10
                let inlet = try AirProcesses.state(dryBulbC:inletT,humidityRatio:inletW,pressurePa:p)
                for bf in [0.0,0.1,0.5,0.9] {
                    let outlet = try AirProcesses.state(dryBulbC:t+bf*20,humidityRatio:w+bf*(inletW-w),pressurePa:p)
                    let analysis = try CoilApparatusDewPoint.analyze(inlet:inlet,outlet:outlet)
                    let match = try XCTUnwrap(analysis.candidates.min(by: { abs($0.temperatureC-t) < abs($1.temperatureC-t) }))
                    XCTAssertEqual(match.temperatureC,t,accuracy:1e-5,"pressure \(p), ADP \(t), BF \(bf)")
                    XCTAssertEqual(match.bypassFactorTemperature,bf,accuracy:1e-6)
                    XCTAssertEqual(match.bypassFactorHumidity,bf,accuracy:1e-6)
                    XCTAssertLessThanOrEqual(abs(match.humidityResidual),1e-10)
                    XCTAssertTrue((0...1).contains(match.bypassFactorEnthalpy))
                    count += 1
                }
            }
        }
        XCTAssertEqual(count,60)
    }
    func testDryZeroAndUnresolvedProcessesDoNotInventADP() throws {
        let a = try AirProcesses.state(dryBulbC:30,humidityRatio:0.01,pressurePa:101325)
        let b = try AirProcesses.state(dryBulbC:20,humidityRatio:0.01,pressurePa:101325)
        XCTAssertEqual(try CoilApparatusDewPoint.analyze(inlet:a,outlet:b).status,.notApplicable)
        XCTAssertEqual(try CoilApparatusDewPoint.analyze(inlet:a,outlet:a).status,.notApplicable)
        let low = try AirProcesses.state(dryBulbC:20,humidityRatio:0.001,pressurePa:101325)
        let noRoot = try CoilApparatusDewPoint.analyze(inlet:a,outlet:low)
        XCTAssertEqual(noRoot.status,.unresolved); XCTAssertTrue(noRoot.candidates.isEmpty)
        XCTAssertThrowsError(try CoilApparatusDewPoint.analyze(inlet:b,outlet:a))
    }
    func testTangencyAndMultipleRootsAreReported() throws {
        let p = 101325.0, t = 10.0
        let w = try saturatedW(t,p)
        let slope = try (saturatedW(t+0.00001,p)-saturatedW(t-0.00001,p))/0.00002
        let a = try AirProcesses.state(dryBulbC:30,humidityRatio:w+slope*20,pressurePa:p)
        let b = try AirProcesses.state(dryBulbC:20,humidityRatio:w+slope*10,pressurePa:p)
        let tangent = try CoilApparatusDewPoint.analyze(inlet:a,outlet:b)
        XCTAssertTrue(tangent.candidates.contains(where: { $0.nearTangent && abs($0.temperatureC-t)<0.001 }))
        let normal = try AirProcesses.state(dryBulbC:30,humidityRatio:0.014,pressurePa:p)
        let leaving = try AirProcesses.state(dryBulbC:13,humidityRatio:w+0.15*(normal.humidityRatio-w),pressurePa:p)
        let multiple = try CoilApparatusDewPoint.analyze(inlet:normal,outlet:leaving)
        XCTAssertEqual(multiple.status,.ambiguous)
        XCTAssertGreaterThan(multiple.candidates.count,1)
        XCTAssertEqual(try XCTUnwrap(multiple.candidates.first).temperatureC,10,accuracy:1e-5)
    }
    func testSupplementalAnalysisAppearsInProcessJSONWithoutChangingLoads() throws {
        let a = try AirProcesses.state(dryBulbC:30,humidityRatio:0.014,pressurePa:101325)
        let b = try AirProcesses.state(dryBulbC:15,humidityRatio:0.009,pressurePa:101325)
        let result = try AirProcesses.coolingCoil(inlet:a,outlet:b,inletActualCFM:a.volumeM3PerKgDryAir/AirProcesses.cfmToM3PerSecond)
        XCTAssertEqual(result.totalKW,28.1251,accuracy:1e-8)
        let adp = try XCTUnwrap(result.apparatusDewPoint)
        XCTAssertFalse(adp.method.isEmpty)
        let json = try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(result))
        XCTAssertEqual(json["apparatusDewPoint"]["method"].string,CoilApparatusDewPoint.method)
        XCTAssertEqual(result.traces.count,5)
        var legacy = json.object!; legacy.removeValue(forKey: "apparatusDewPoint")
        let decoded = try JSONDecoder().decode(CoolingCoilResult.self,from:JSONEncoder().encode(JSONValue.object(legacy)))
        XCTAssertNil(decoded.apparatusDewPoint)
        XCTAssertEqual(decoded.totalKW,result.totalKW)
    }
}
