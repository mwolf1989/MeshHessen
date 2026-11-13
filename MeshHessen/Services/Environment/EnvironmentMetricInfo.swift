import Foundation

/// An RGB colour as 0…255 components (no UI types, so the math stays testable).
struct EnvironmentRGB: Equatable, Hashable, Sendable {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    /// "r,g,b" — the form the vector map's `rgb(...)` CSS expects.
    var cssComponents: String { "\(r),\(g),\(b)" }
}

/// One environmental metric the map overlay understands.
///
/// `key` is the app-wide metric id (settings, JS payloads), `series` the stored metric in
/// `telemetry_samples`. `heatMin`/`heatMax`/`step` (in the stored unit) define the colour
/// scale and its discrete legend bands. Virtual metrics (SNR, RSSI, noise floor) do not come
/// from environment telemetry: they are selectable for the heatmap but never shown in boxes.
struct EnvironmentMetric: Identifiable, Hashable, Sendable {
    let key: String
    let series: TelemetrySeriesMetric
    let decimals: Int
    let heatMin: Double
    let heatMax: Double
    let step: Double
    var isVirtual = false

    var id: String { key }

    /// The `telemetry_samples.metric` value this metric is read from.
    var column: String { series.rawValue }

    var displayName: String { series.displayName }

    func displayUnit(radiationInSievert: Bool) -> String {
        series.displayUnit(radiationInSievert: radiationInSievert)
    }

    func displayValue(_ storedValue: Double, radiationInSievert: Bool) -> Double {
        series.displayValue(storedValue, radiationInSievert: radiationInSievert)
    }

    /// Colour scale in the displayed unit (radiation may be shown in µSv/h).
    func displayScale(radiationInSievert: Bool) -> EnvironmentScale {
        let converted = series == .radiation && radiationInSievert
        return EnvironmentScale(
            min: displayValue(heatMin, radiationInSievert: radiationInSievert),
            max: displayValue(heatMax, radiationInSievert: radiationInSievert),
            step: displayValue(step, radiationInSievert: radiationInSievert),
            decimals: converted ? 2 : decimals
        )
    }
}

/// A metric's colour scale: value range, band step and number of decimals.
struct EnvironmentScale: Equatable, Sendable {
    let min: Double
    let max: Double
    let step: Double
    let decimals: Int

    var bandCount: Int { Swift.max(1, Int((span / step).rounded())) }
    var span: Double { max - min }

    /// Interior band boundaries (the contour levels).
    var interiorLevels: [Double] {
        guard bandCount > 1 else { return [] }
        return (1..<bandCount).map { min + Double($0) * step }
    }
}

/// One discrete legend band [lo, hi).
struct EnvironmentBand: Equatable, Sendable {
    let lo: Double
    let hi: Double
    let rgb: EnvironmentRGB
}

/// Single source of truth for the metrics the environment map overlay understands
/// (port of the Windows `EnvironmentMetricInfo`).
enum EnvironmentMetricInfo {
    /// Display order in the metric selector; temperature first (default heatmap metric).
    static let all: [EnvironmentMetric] = [
        .init(key: "temperature", series: .temperature, decimals: 1, heatMin: -10, heatMax: 40, step: 5),
        .init(key: "humidity", series: .relativeHumidity, decimals: 0, heatMin: 0, heatMax: 100, step: 10),
        .init(key: "pressure", series: .barometricPressure, decimals: 0, heatMin: 970, heatMax: 1_040, step: 10),
        .init(key: "iaq", series: .iaq, decimals: 0, heatMin: 0, heatMax: 500, step: 50),
        .init(key: "gas", series: .gasResistance, decimals: 2, heatMin: 0, heatMax: 50, step: 5),
        .init(key: "lux", series: .lux, decimals: 0, heatMin: 0, heatMax: 50_000, step: 10_000),
        .init(key: "white_lux", series: .whiteLux, decimals: 0, heatMin: 0, heatMax: 50_000, step: 10_000),
        .init(key: "uv_lux", series: .uvLux, decimals: 0, heatMin: 0, heatMax: 10_000, step: 2_000),
        .init(key: "wind_speed", series: .windSpeed, decimals: 1, heatMin: 0, heatMax: 30, step: 5),
        .init(key: "wind_direction", series: .windDirection, decimals: 0, heatMin: 0, heatMax: 360, step: 45),
        .init(key: "wind_gust", series: .windGust, decimals: 1, heatMin: 0, heatMax: 40, step: 5),
        .init(key: "rain_1h", series: .rainfall1Hour, decimals: 1, heatMin: 0, heatMax: 20, step: 4),
        .init(key: "rain_24h", series: .rainfall24Hours, decimals: 1, heatMin: 0, heatMax: 80, step: 10),
        .init(key: "soil_moisture", series: .soilMoisture, decimals: 0, heatMin: 0, heatMax: 100, step: 10),
        .init(key: "soil_temperature", series: .soilTemperature, decimals: 1, heatMin: -10, heatMax: 40, step: 5),
        .init(key: "radiation", series: .radiation, decimals: 1, heatMin: 0, heatMax: 100, step: 20),
        .init(key: "distance", series: .distance, decimals: 0, heatMin: 0, heatMax: 5_000, step: 1_000),
        .init(key: "weight", series: .weight, decimals: 2, heatMin: 0, heatMax: 200, step: 25),
        // AS3935 lightning sensor (protobufs 2.8)
        .init(key: "lightning_1h", series: .lightningStrikeCount1Hour, decimals: 0, heatMin: 0, heatMax: 30, step: 5),
        .init(key: "lightning_km", series: .lightningDistance, decimals: 1, heatMin: 0, heatMax: 40, step: 5),
        // Soil/water probes (protobufs 2.8, telemetry variant soil_water_metrics)
        .init(key: "soil_ph", series: .soilPH, decimals: 1, heatMin: 0, heatMax: 14, step: 2),
        .init(key: "water_ph", series: .waterPH, decimals: 1, heatMin: 0, heatMax: 14, step: 2),
        .init(key: "conductivity", series: .electricalConductivity, decimals: 2, heatMin: 0, heatMax: 10, step: 2),
        .init(key: "salinity", series: .salinity, decimals: 0, heatMin: 0, heatMax: 10_000, step: 2_000),
        .init(key: "nitrogen", series: .nitrogen, decimals: 0, heatMin: 0, heatMax: 500, step: 100),
        .init(key: "phosphorus", series: .phosphorus, decimals: 0, heatMin: 0, heatMax: 500, step: 100),
        .init(key: "potassium", series: .potassium, decimals: 0, heatMin: 0, heatMax: 500, step: 100),
        .init(key: "dissolved_oxygen", series: .dissolvedOxygen, decimals: 1, heatMin: 0, heatMax: 15, step: 3),
        .init(key: "orp", series: .orp, decimals: 0, heatMin: -500, heatMax: 500, step: 200),
        .init(key: "cod", series: .chemicalOxygenDemand, decimals: 0, heatMin: 0, heatMax: 200, step: 40),
        .init(key: "turbidity", series: .turbidity, decimals: 1, heatMin: 0, heatMax: 100, step: 20),
        .init(key: "nitrate", series: .nitrate, decimals: 1, heatMin: 0, heatMax: 100, step: 20),
        .init(key: "ammonium", series: .ammonium, decimals: 1, heatMin: 0, heatMax: 50, step: 10),
        .init(key: "bod", series: .biochemicalOxygenDemand, decimals: 0, heatMin: 0, heatMax: 100, step: 20),
        .init(key: "solar_irradiance", series: .solarIrradiance, decimals: 0, heatMin: 0, heatMax: 1_200, step: 200),
        // Radio-quality overlays (virtual: packet_rx / local stats samples, not environment telemetry)
        .init(key: "snr", series: .snr, decimals: 1, heatMin: -20, heatMax: 12, step: 4, isVirtual: true),
        .init(key: "rssi", series: .rssi, decimals: 0, heatMin: -130, heatMax: -60, step: 10, isVirtual: true),
        .init(key: "noise_floor", series: .localNoiseFloor, decimals: 0, heatMin: -130, heatMax: -80, step: 10,
              isVirtual: true),
    ]

    /// Real environment metrics (shown in value boxes), registry order.
    static let environmentOnly: [EnvironmentMetric] = all.filter { !$0.isVirtual }

    /// Stored metric names of the non-virtual metrics, registry order.
    static let columns: [String] = environmentOnly.map(\.column)

    static let defaultMetric = all[0]

    private static let byKey: [String: EnvironmentMetric] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.key.lowercased(), $0) }
    )

    static func metric(forKey key: String?) -> EnvironmentMetric? {
        guard let key else { return nil }
        return byKey[key.lowercased()]
    }

    static func metric(forColumn column: String) -> EnvironmentMetric? {
        all.first { $0.column == column }
    }

    static func isKnownColumn(_ column: String) -> Bool {
        environmentOnly.contains { $0.column.caseInsensitiveCompare(column) == .orderedSame }
    }

    // MARK: - Colours

    /// Calibrated gradient blue → cyan → green → yellow → orange → red, saturated across the
    /// whole range so mid values stay visible over the map. Normalised position t = 0…1.
    static let gradient: [(t: Double, rgb: EnvironmentRGB)] = [
        (0.00, .init(r: 63, g: 90, b: 204)), (0.14, .init(r: 58, g: 150, b: 232)),
        (0.28, .init(r: 62, g: 196, b: 220)), (0.42, .init(r: 96, g: 201, b: 128)),
        (0.54, .init(r: 175, g: 214, b: 78)), (0.66, .init(r: 244, g: 221, b: 74)),
        (0.78, .init(r: 245, g: 157, b: 52)), (0.90, .init(r: 230, g: 88, b: 42)),
        (1.00, .init(r: 176, g: 30, b: 30)),
    ]

    /// Interpolated gradient colour at normalised position t (clamped to 0…1).
    static func rgb(at position: Double) -> EnvironmentRGB {
        let t = min(1, max(0, position.isNaN ? 0 : position))
        for index in 1..<gradient.count where t <= gradient[index].t {
            let (t0, c0) = gradient[index - 1]
            let (t1, c1) = gradient[index]
            let f = t1 > t0 ? (t - t0) / (t1 - t0) : 0
            func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
                UInt8((Double(a) + f * (Double(b) - Double(a))).rounded())
            }
            return .init(r: mix(c0.r, c1.r), g: mix(c0.g, c1.g), b: mix(c0.b, c1.b))
        }
        return gradient[gradient.count - 1].rgb
    }

    /// Discrete colour bands [lo, hi) at the scale's step — the weather-service legend.
    static func bands(for scale: EnvironmentScale) -> [EnvironmentBand] {
        let count = scale.bandCount
        return (0..<count).map { index in
            EnvironmentBand(
                lo: rounded(scale.min + Double(index) * scale.step),
                hi: rounded(scale.min + Double(index + 1) * scale.step),
                rgb: rgb(at: (Double(index) + 0.5) / Double(count))
            )
        }
    }

    static func bands(for metric: EnvironmentMetric, radiationInSievert: Bool = false) -> [EnvironmentBand] {
        bands(for: metric.displayScale(radiationInSievert: radiationInSievert))
    }

    // MARK: - Formatting

    /// Formats a stored value for display, e.g. 21.4 → "21.4 °C" (unit omitted when empty).
    static func format(
        _ metric: EnvironmentMetric,
        storedValue: Double,
        radiationInSievert: Bool = false,
        locale: Locale = .current
    ) -> String {
        let scale = metric.displayScale(radiationInSievert: radiationInSievert)
        let value = metric.displayValue(storedValue, radiationInSievert: radiationInSievert)
        let number = value.formatted(
            .number.precision(.fractionLength(scale.decimals)).grouping(.never).locale(locale)
        )
        let unit = metric.displayUnit(radiationInSievert: radiationInSievert)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    static func format(_ key: String, storedValue: Double, radiationInSievert: Bool = false) -> String {
        guard let metric = metric(forKey: key) else {
            return storedValue.formatted(.number.precision(.fractionLength(0...1)))
        }
        return format(metric, storedValue: storedValue, radiationInSievert: radiationInSievert)
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }
}
