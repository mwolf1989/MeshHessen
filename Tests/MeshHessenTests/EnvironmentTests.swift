import Foundation
import Testing

@testable import MeshHessen

// Port of the Windows `MeshhessenClient.Tests/EnvironmentTests.cs`.

@Suite("Environment Metric Info")
struct EnvironmentMetricInfoTests {
    @Test("Registry has core and extended metrics")
    func registryHasCoreAndExtendedMetrics() {
        #expect(EnvironmentMetricInfo.metric(forKey: "temperature") != nil)
        #expect(EnvironmentMetricInfo.metric(forKey: "iaq") != nil)
        #expect(EnvironmentMetricInfo.metric(forKey: "gas") != nil)
        #expect(EnvironmentMetricInfo.metric(forKey: "wind_speed") != nil)
        #expect(EnvironmentMetricInfo.metric(forKey: "does_not_exist") == nil)
        #expect(EnvironmentMetricInfo.defaultMetric.key == "temperature")
    }

    @Test("Plan 013 sensors are selectable")
    func newSensorsAreSelectable() {
        let series = Set(EnvironmentMetricInfo.environmentOnly.map(\.series))
        for metric in SoilWaterTelemetrySample.metrics {
            #expect(series.contains(metric), "Missing \(metric.rawValue)")
        }
        #expect(series.contains(.lightningStrikeCount1Hour))
        #expect(series.contains(.lightningDistance))
    }

    @Test("Columns match the non-virtual registry one to one")
    func columnsMatchRegistry() {
        #expect(EnvironmentMetricInfo.environmentOnly.count == EnvironmentMetricInfo.columns.count)
        #expect(EnvironmentMetricInfo.all.count > EnvironmentMetricInfo.environmentOnly.count)
        #expect(EnvironmentMetricInfo.columns.contains("gas_resistance"))
        #expect(!EnvironmentMetricInfo.columns.contains("snr"))
        #expect(EnvironmentMetricInfo.isKnownColumn("relative_humidity"))
        #expect(!EnvironmentMetricInfo.isKnownColumn("node_id"))
        #expect(!EnvironmentMetricInfo.isKnownColumn("snr"))
        #expect(EnvironmentMetricInfo.metric(forKey: "snr")?.isVirtual == true)
        #expect(EnvironmentMetricInfo.metric(forKey: "noise_floor")?.isVirtual == true)
        let keys = EnvironmentMetricInfo.all.map(\.key)
        #expect(Set(keys).count == keys.count)
    }

    @Test("Format appends the unit")
    func formatAppendsUnit() {
        let locale = Locale(identifier: "en_US")
        let temperature = EnvironmentMetricInfo.metric(forKey: "temperature")!
        let text = EnvironmentMetricInfo.format(temperature, storedValue: 21.4, locale: locale)
        #expect(text == "21.4 °C")
        let iaq = EnvironmentMetricInfo.metric(forKey: "iaq")!
        #expect(!EnvironmentMetricInfo.format(iaq, storedValue: 42, locale: locale).contains("°"))
    }

    @Test("Radiation can be shown in µSv/h")
    func radiationInSievert() {
        let radiation = EnvironmentMetricInfo.metric(forKey: "radiation")!
        let locale = Locale(identifier: "en_US")
        #expect(EnvironmentMetricInfo.format(radiation, storedValue: 25, locale: locale) == "25.0 µR/h")
        #expect(
            EnvironmentMetricInfo.format(radiation, storedValue: 25, radiationInSievert: true, locale: locale)
                == "0.25 µSv/h"
        )
        let scale = radiation.displayScale(radiationInSievert: true)
        #expect(scale.max == 1)
        #expect(abs(scale.step - 0.2) < 1e-9)
        #expect(scale.bandCount == 5)
    }

    @Test("Bands cover the range at the step")
    func bandsCoverRange() {
        let temperature = EnvironmentMetricInfo.metric(forKey: "temperature")!   // -10…40 step 5
        let bands = EnvironmentMetricInfo.bands(for: temperature)
        #expect(bands.count == 10)
        #expect(bands.first?.lo == -10)
        #expect(bands.last?.hi == 40)
        #expect(temperature.displayScale(radiationInSievert: false).interiorLevels.count == 9)
    }

    @Test("Gradient ends match the gradient table")
    func rgbEndsMatchGradient() {
        #expect(EnvironmentMetricInfo.rgb(at: 0) == EnvironmentMetricInfo.gradient[0].rgb)
        #expect(EnvironmentMetricInfo.rgb(at: 1) == EnvironmentMetricInfo.gradient.last!.rgb)
        #expect(EnvironmentMetricInfo.rgb(at: -5) == EnvironmentMetricInfo.gradient[0].rgb)
        #expect(EnvironmentMetricInfo.rgb(at: 0.14) == EnvironmentMetricInfo.gradient[1].rgb)
    }
}

@Suite("Environment Heatmap Builder")
struct EnvironmentHeatmapBuilderTests {
    @Test("No samples returns nil")
    func noSamples() {
        #expect(EnvironmentHeatmapBuilder.representative([]) == nil)
    }

    @Test("A fresh reading has full recency and the real value")
    func freshReading() throws {
        let reading = try #require(EnvironmentHeatmapBuilder.representative([(0, 25)]))
        #expect(abs(reading.value - 25) < 1e-3)
        #expect(reading.recency > 0.99)
    }

    @Test("Recent readings dominate the value")
    func recentReadingsDominate() throws {
        let reading = try #require(EnvironmentHeatmapBuilder.representative([(0, 30), (24, 10)]))
        #expect(reading.value > 20, "value was \(reading.value)")
    }

    @Test("A stale node loses recency")
    func staleNodeLosesRecency() throws {
        let fresh = try #require(EnvironmentHeatmapBuilder.representative([(0, 25)])).recency
        let stale = try #require(EnvironmentHeatmapBuilder.representative([(48, 25)])).recency
        #expect(stale < fresh)
        #expect(stale < 0.5, "stale recency was \(stale)")
    }
}

@Suite("Environment Zones")
struct EnvironmentZonesTests {
    @Test("Single band: every cell gets the zone average")
    func singleBand() {
        let grid = EnvironmentField.Grid(
            lon0: 8, lat0: 50, dLon: 0.1, dLat: 0.1, nx: 4, ny: 2,
            values: Array(repeating: 12, count: 8), alpha: Array(repeating: 1, count: 8)
        )
        let averages = EnvironmentZones.zoneAverages(grid, min: -10, step: 5, bandCount: 10)
        for average in averages { #expect(abs(average - 12) < 1e-3) }
    }

    @Test("Two bands: each cell gets its own zone average")
    func twoBands() {
        var values = [Double](repeating: 0, count: 8)
        for j in 0..<2 {
            for i in 0..<4 { values[j * 4 + i] = i < 2 ? 12 : 22 }
        }
        let grid = EnvironmentField.Grid(
            lon0: 8, lat0: 50, dLon: 0.1, dLat: 0.1, nx: 4, ny: 2,
            values: values, alpha: Array(repeating: 1, count: 8)
        )
        let averages = EnvironmentZones.zoneAverages(grid, min: -10, step: 5, bandCount: 10)
        #expect(abs(averages[0] - 12) < 1e-3)
        #expect(abs(averages[3] - 22) < 1e-3)
    }
}

@Suite("Environment Field")
struct EnvironmentFieldTests {
    private static let twoSensors = [
        EnvironmentField.Sensor(longitude: 8.0, latitude: 50.0, value: 30, confidence: 1),   // hot
        EnvironmentField.Sensor(longitude: 8.3, latitude: 50.0, value: 10, confidence: 1),   // cold, ~21 km east
    ]

    private func nearest(_ grid: EnvironmentField.Grid, longitude: Double, latitude: Double) -> (Double, Double) {
        var best = Double.greatestFiniteMagnitude
        var bestIndex = 0
        for j in 0..<grid.ny {
            for i in 0..<grid.nx {
                let center = grid.cellCenter(i: i, j: j)
                let distance = pow(center.longitude - longitude, 2) + pow(center.latitude - latitude, 2)
                if distance < best { best = distance; bestIndex = j * grid.nx + i }
            }
        }
        return (grid.values[bestIndex], grid.alpha[bestIndex])
    }

    @Test("No sensors returns nil")
    func noSensors() {
        #expect(EnvironmentField.build([], influenceKm: 30) == nil)
    }

    @Test("Interpolated values stay within the sensor range")
    func valuesStayInRange() throws {
        let grid = try #require(EnvironmentField.build(Self.twoSensors, influenceKm: 30))
        for value in grid.values where !value.isNaN {
            #expect(value >= 10 - 1e-6 && value <= 30 + 1e-6, "value out of range: \(value)")
        }
    }

    @Test("Grid respects the cell bounds")
    func gridBounds() throws {
        let grid = try #require(EnvironmentField.build(Self.twoSensors, influenceKm: 30))
        #expect((8...80).contains(grid.nx))
        #expect((8...80).contains(grid.ny))
        #expect(grid.nx * grid.ny <= 2_800)
        #expect(grid.values.count == grid.nx * grid.ny)
        // Corners lie outside the influence radius of both sensors → transparent.
        #expect(grid.alpha[0] == 0)
        #expect(grid.values[0].isNaN)
    }

    @Test("Contours emit a segment where the level is crossed")
    func contoursEmitSegment() {
        let grid = EnvironmentField.Grid(
            lon0: 8, lat0: 50, dLon: 0.1, dLat: 0.1, nx: 2, ny: 2,
            values: [0, 0, 0, 20], alpha: [1, 1, 1, 1]   // only NE above the level
        )
        let segments = EnvironmentContours.build(grid, levels: [10])
        #expect(segments.count == 1)
        #expect(segments.first?.asArray.count == 4)
        let anchors = EnvironmentContours.lineLabelAnchors(grid, levels: [10])
        #expect(anchors.count == 1)
        #expect(anchors.first?.warmerCell == 3)
    }

    @Test("The cell at a sensor takes that sensor's value")
    func cellAtSensor() throws {
        let grid = try #require(EnvironmentField.build(Self.twoSensors, influenceKm: 30))
        let (value, alpha) = nearest(grid, longitude: 8.0, latitude: 50.0)
        #expect(value > 29, "value at hot sensor was \(value)")
        #expect(alpha > 0)
    }
}

@Suite("Environment Database and Overlay")
struct EnvironmentDatabaseTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDatabase() -> (TelemetryDatabaseService, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-EnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        let database = TelemetryDatabaseService(
            databaseURL: directory.appendingPathComponent("telemetry.sqlite"),
            retentionDays: 0,
            clock: { Self.now }
        )
        return (database, directory)
    }

    @Test("Insert and read back the latest values and the selected metric's samples")
    func roundTrip() async throws {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        database.insertEnvironmentTelemetrySample(
            nodeId: 123,
            timestamp: Self.now.addingTimeInterval(-7_200),
            sample: EnvironmentTelemetrySample(temperature: 18, relativeHumidity: 55)
        )
        database.insertEnvironmentTelemetrySample(
            nodeId: 123,
            timestamp: Self.now.addingTimeInterval(-600),
            sample: EnvironmentTelemetrySample(temperature: 21.5, gasResistance: 12.3, windSpeed: 3.2)
        )
        database.insertSoilWaterTelemetry(
            nodeId: 456,
            timestamp: Self.now.addingTimeInterval(-60),
            sample: SoilWaterTelemetrySample(values: [.soilPH: 6.5])
        )
        // Too old for the 48 h window.
        database.insertEnvironmentTelemetrySample(
            nodeId: 789,
            timestamp: Self.now.addingTimeInterval(-72 * 3_600),
            sample: EnvironmentTelemetrySample(temperature: 5)
        )
        database.waitForPendingWrites()

        let readings = await database.latestEnvironmentPerNode(metricColumn: "temperature", maxAgeHours: 48)
        #expect(readings.map(\.nodeId) == [123, 456])
        let node = try #require(readings.first)
        #expect(node.latestValues["temperature"] == 21.5)
        #expect(node.latestValues["humidity"] == 55)
        #expect(abs((node.latestValues["gas"] ?? 0) - 12.3) < 1e-6)
        #expect(node.latestValues["wind_speed"] != nil)
        #expect(node.latestValues["pressure"] == nil)
        #expect(node.latestTimestamp == Self.now.addingTimeInterval(-600))
        #expect(node.samples.map(\.value) == [18, 21.5])
        #expect(readings[1].latestValues["soil_ph"] == 6.5)
        #expect(readings[1].samples.isEmpty)

        let unknown = await database.latestEnvironmentPerNode(metricColumn: "node_id; DROP", maxAgeHours: 48)
        #expect(unknown.allSatisfy { $0.samples.isEmpty })
    }

    @Test("Overlay builds boxes and a surface, honouring exclusions")
    func overlayBuild() {
        let nodes = [
            EnvironmentNodePosition(nodeId: 1, latitude: 50.0, longitude: 8.0, title: "HOT"),
            EnvironmentNodePosition(nodeId: 2, latitude: 50.0, longitude: 8.3, title: "COLD"),
        ]
        let readings = [
            EnvironmentNodeSamples(
                nodeId: 1, latestTimestamp: Self.now, latestValues: ["temperature": 30, "snr": 5],
                samples: [.init(timestamp: Self.now, value: 30)]
            ),
            EnvironmentNodeSamples(
                nodeId: 2, latestTimestamp: Self.now, latestValues: ["temperature": 10],
                samples: [.init(timestamp: Self.now, value: 10)]
            ),
            EnvironmentNodeSamples(nodeId: 3, latestValues: ["temperature": 99]),   // no position
        ]
        var options = EnvironmentOverlayBuilder.Options(
            metric: EnvironmentMetricInfo.defaultMetric,
            boxMode: .always,
            showHeatmap: true,
            excludedNodeIds: [],
            radiationInSievert: false,
            now: Self.now
        )
        let overlay = EnvironmentOverlayBuilder.build(revision: 1, nodes: nodes, readings: readings, options: options)
        #expect(overlay.boxes.count == 2)
        #expect(overlay.boxes.first { $0.nodeId == 1 }?.lines.count == 1)   // virtual SNR not in boxes
        #expect(overlay.sensorNodes.map(\.title) == ["COLD", "HOT"])
        #expect(overlay.availableMetricKeys == ["temperature", "snr"])
        let surface = overlay.surface
        #expect(surface?.sensorCount == 2)
        #expect(surface?.contours.isEmpty == false)
        #expect(surface?.border.isEmpty == false)
        #expect(surface?.legend.bands.count == 10)
        #expect(surface?.pngDataURI.hasPrefix("data:image/png;base64,") == true)

        options.excludedNodeIds = [1]
        options.boxMode = .off
        let excluded = EnvironmentOverlayBuilder.build(revision: 2, nodes: nodes, readings: readings, options: options)
        #expect(excluded.boxes.isEmpty)
        #expect(excluded.surface?.sensorCount == 1)
        #expect(excluded.sensorNodes.count == 2)

        options.showHeatmap = false
        #expect(EnvironmentOverlayBuilder.build(revision: 3, nodes: nodes, readings: readings, options: options)
            .surface == nil)
    }
}

@Suite("Environment Settings")
struct EnvironmentSettingsTests {
    @Test("Defaults, persistence and metric fallback")
    func settingsPersist() throws {
        let suiteName = "MeshHessen-EnvironmentSettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsService(defaults: defaults)
        #expect(settings.showEnvironmentData == false)
        #expect(settings.environmentBoxMode == .always)
        #expect(settings.environmentShowHeatmap == false)
        #expect(settings.environmentMetricKey == "temperature")
        #expect(settings.environmentExcludedNodeIds.isEmpty)

        settings.showEnvironmentData = true
        settings.environmentBoxMode = .hover
        settings.environmentShowHeatmap = true
        settings.environmentMetricKey = "soil_ph"
        settings.environmentExcludedNodeIds = [0xFFFF_FFFE, 42]

        let reloaded = SettingsService(defaults: defaults)
        #expect(reloaded.showEnvironmentData)
        #expect(reloaded.environmentBoxMode == .hover)
        #expect(reloaded.environmentShowHeatmap)
        #expect(reloaded.environmentMetric.series == .soilPH)
        #expect(reloaded.environmentExcludedNodeIds == [0xFFFF_FFFE, 42])

        reloaded.environmentMetricKey = "bogus"
        #expect(reloaded.environmentMetricKey == "temperature")
    }
}

@Suite("Environment Raster")
struct EnvironmentRasterTests {
    @Test("Raster is transparent outside coverage and coloured near a sensor")
    func rasterColoursCoverage() throws {
        let sensors = [EnvironmentField.Sensor(longitude: 8.5, latitude: 50.5, value: 40, confidence: 1)]
        let grid = try #require(EnvironmentField.build(sensors, influenceKm: 30))
        let image = try #require(EnvironmentRaster.render(grid, min: -10, max: 40, maxOpacity: 0.6, bandCount: 10))
        #expect(image.width >= 128 && image.width <= 640)
        #expect(image.pixels.count == image.width * image.height * 4)
        #expect(image.pixel(x: 0, y: 0).a == 0)

        let center = image.pixel(x: image.width / 2, y: image.height / 2)
        #expect(center.a > 100)
        let hottest = EnvironmentMetricInfo.rgb(at: 0.95)
        #expect(center.r == hottest.r && center.g == hottest.g && center.b == hottest.b)
        #expect(image.minLongitude < 8.5 && image.maxLongitude > 8.5)
        #expect(EnvironmentRaster.pngData(image)?.isEmpty == false)
    }
}
