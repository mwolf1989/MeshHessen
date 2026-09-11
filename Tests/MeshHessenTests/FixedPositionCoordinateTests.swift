import Foundation
import Testing

@testable import MeshHessen

@Suite("Fixed Position Coordinates")
struct FixedPositionCoordinateTests {
    @Test("Pasted decimal points and commas produce the same protocol coordinates")
    func decimalSeparators() {
        #expect(FixedPositionCoordinate.latitude.parse("50.1234567") == 501_234_567)
        #expect(FixedPositionCoordinate.latitude.parse("50,1234567") == 501_234_567)
        #expect(FixedPositionCoordinate.longitude.parse("8.1234567") == 81_234_567)
        #expect(FixedPositionCoordinate.longitude.parse("8,1234567") == 81_234_567)
        #expect(FixedPositionCoordinate.latitude.parse(" \n-50,1234567\t") == -501_234_567)
        #expect(FixedPositionCoordinate.longitude.parse("+8.1234567") == 81_234_567)
        #expect(FixedPositionCoordinate.latitude.parse(".5") == 5_000_000)
        #expect(FixedPositionCoordinate.longitude.parse("-,5") == -5_000_000)
    }

    @Test("Valid coordinate limits and seven-place rounding are preserved")
    func limitsAndPrecision() {
        #expect(FixedPositionCoordinate.latitude.parse("90") == 900_000_000)
        #expect(FixedPositionCoordinate.latitude.parse("-90,0") == -900_000_000)
        #expect(FixedPositionCoordinate.longitude.parse("180.0") == 1_800_000_000)
        #expect(FixedPositionCoordinate.longitude.parse("-180") == -1_800_000_000)
        #expect(FixedPositionCoordinate.latitude.parse("0") == 0)
        #expect(FixedPositionCoordinate.latitude.parse("50.12345678") == 501_234_568)
        #expect(FixedPositionCoordinate.latitude.parse("-50,12345678") == -501_234_568)
        #expect(FixedPositionCoordinate.latitude.parse("0.0000001") == 1)
    }

    @Test("Invalid input never reaches a trapping integer conversion", arguments: [
        "", " ", "-", ".", ",", "nan", "NaN", "inf", "-infinity", "1e309",
        "501234567", "999999999999999999999999999999999999999999", String(repeating: "9", count: 400),
        "50.123,456", "50,123.456", "50..1", "50,,1", "50 123", "50°", "50.1junk", "0x1p0"
    ])
    func invalidInput(text: String) {
        #expect(FixedPositionCoordinate.latitude.parse(text) == nil)
        #expect(FixedPositionCoordinate.longitude.parse(text) == nil)
    }

    @Test("Coordinates are checked against their geographic range before rounding")
    func invalidRanges() {
        for text in ["90.00000001", "-90,00000001", "180", "-180"] {
            #expect(FixedPositionCoordinate.latitude.parse(text) == nil)
        }
        for text in ["180.00000001", "-180,00000001", "214.7483648", "-214.7483649"] {
            #expect(FixedPositionCoordinate.longitude.parse(text) == nil)
        }
    }

    @Test("Loaded coordinates round-trip in German and English locales", arguments: ["de_DE", "en_US"])
    func localizedRoundTrip(localeID: String) {
        let locale = Locale(identifier: localeID)
        for coordinate in FixedPositionCoordinate.allCases {
            for value: Int32 in [0, 1, -1, 501_234_567, -501_234_567, 900_000_000, -900_000_000] {
                #expect(coordinate.parse(coordinate.format(value, locale: locale)) == value)
            }
        }
        for value: Int32 in [1_800_000_000, -1_800_000_000] {
            let coordinate = FixedPositionCoordinate.longitude
            #expect(coordinate.parse(coordinate.format(value, locale: locale)) == value)
        }
    }
}
