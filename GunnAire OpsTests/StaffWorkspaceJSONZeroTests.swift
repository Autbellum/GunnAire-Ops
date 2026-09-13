import Foundation
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffWorkspaceJSONZeroTests: XCTestCase {
    struct Values: Codable, Equatable { let numbers: [Double]; let text: String; let flag: Bool }
    func testPythonSignedZeroSpellingsRoundTripWithoutChangingStringsOrFlags() throws {
        let bytes = Data(#"{"numbers":[-0.0,-0,-0.000e+20,-0e-4,0,2.5],"text":"-0.0","flag":false}"#.utf8)
        let value = try StaffWorkspacePublicationContract.decode(Values.self, from: bytes)
        XCTAssertEqual(value, Values(numbers: [0, 0, 0, 0, 0, 2.5], text: "-0.0", flag: false))
        XCTAssertEqual(value.numbers[0].sign, .minus)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), #"{"numbers":[-0.0,-0,-0.000e+20,-0e-4,0,2.5],"text":"-0.0","flag":false}"#)
    }
    func testZeroNormalizationDoesNotRelaxDuplicateUnknownOrBooleanTypes() {
        for json in [
            #"{"numbers":[-0.0],"text":"x","flag":false,"extra":0}"#,
            #"{"numbers":[-0.0],"text":"x","flag":false,"flag":true}"#,
            #"{"numbers":[false],"text":"x","flag":false}"#,
            #"{"numbers":[-0.0],"text":"x","flag":0}"#,
            #"{"numbers":[-00.0],"text":"x","flag":false}"#
        ] { XCTAssertThrowsError(try StaffWorkspacePublicationContract.decode(Values.self, from: Data(json.utf8))) }
    }
    struct Reinterpreted: Codable {
        let amount: Double
        enum CodingKeys: String, CodingKey { case amount }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            _ = try c.decode(Double.self, forKey: .amount); amount = 0
        }
    }
    func testNonzeroValuesCannotBeReinterpretedAsZero() {
        for json in [#"{"amount":-0.00001}"#, #"{"amount":0.00001}"#, #"{"amount":1}"#] {
            XCTAssertThrowsError(try StaffWorkspacePublicationContract.decode(Reinterpreted.self, from: Data(json.utf8)))
        }
    }
}
