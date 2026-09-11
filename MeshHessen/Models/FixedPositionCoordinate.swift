import Foundation

/// Decimal-degree input for the fixed-position editor, independent of the system's grouping separator.
enum FixedPositionCoordinate: CaseIterable {
    case latitude
    case longitude

    var title: String {
        switch self {
        case .latitude: return String(localized: "Latitude")
        case .longitude: return String(localized: "Longitude")
        }
    }

    var validationMessage: String {
        switch self {
        case .latitude:
            return String(localized: "Enter a latitude from -90 to 90 using a decimal point or comma.")
        case .longitude:
            return String(localized: "Enter a longitude from -180 to 180 using a decimal point or comma.")
        }
    }

    private var range: ClosedRange<Double> {
        switch self {
        case .latitude: return -90...90
        case .longitude: return -180...180
        }
    }

    /// Accepts one decimal separator and rejects grouping, partial parses and out-of-range values
    /// before converting to the protocol's signed integer representation (degrees × 10⁷).
    func parse(_ text: String) -> Int32? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard normalized.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let degrees = Double(normalized),
              degrees.isFinite,
              range.contains(degrees) else { return nil }
        return Int32(exactly: (degrees * 1e7).rounded())
    }

    /// Keeps all seven protocol decimal places without introducing grouping separators.
    func format(_ value: Int32, locale: Locale = .current) -> String {
        (Double(value) / 1e7).formatted(
            .number.grouping(.never).precision(.fractionLength(0...7)).locale(locale)
        )
    }
}
