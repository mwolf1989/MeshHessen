import Foundation
import SQLite3
import Testing

@testable import MeshHessen

@Suite("New Sensor Telemetry")
struct NewSensorTelemetryTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let newMetrics: [TelemetrySeriesMetric] = [
        .lightningStrikeCount1Hour, .lightningDistance,
        .soilPH, .waterPH, .electricalConductivity, .salinity, .nitrogen,
        .phosphorus, .potassium, .dissolvedOxygen, .orp, .chemicalOxygenDemand,
        .biochemicalOxygenDemand, .turbidity, .nitrate, .ammonium, .solarIrradiance,
    ]

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-NewSensorTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeDatabase(in directory: URL) -> TelemetryDatabaseService {
        TelemetryDatabaseService(
            databaseURL: directory.appendingPathComponent("telemetry.sqlite"),
            retentionDays: 0,
            clock: { Self.now }
        )
    }

    // MARK: - Metrics

    @Test("Metric raw values are unique and new metrics have titles")
    func metricMetadata() {
        let rawValues = TelemetrySeriesMetric.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == rawValues.count)
        for metric in Self.newMetrics {
            #expect(!metric.displayName.isEmpty, "Missing title for \(metric.rawValue)")
        }
        #expect(TelemetrySeriesMetric.lightningStrikeCount1Hour.rawValue == "lightning_strike_count_1h")
        #expect(TelemetrySeriesMetric.lightningDistance.suggestedRange == 0...40)
        #expect(TelemetrySeriesMetric.soilPH.suggestedRange == 0...14)
        #expect(TelemetrySeriesMetric.windowsDashboardMetrics.contains(.radiation))
        #expect(TelemetrySeriesMetric.windowsDashboardMetrics.contains(.soilPH))
    }

    // MARK: - Extraction

    @Test("Lightning: zero strikes are kept, zero distance is dropped")
    func lightningExtraction() {
        var env = Meshtastic_EnvironmentMetrics()
        #expect(MeshtasticProtocolService.lightningStrikeCount(env) == nil)
        #expect(MeshtasticProtocolService.lightningDistance(env) == nil)

        env.lightningStrikeCount1H = 0
        env.lightningDistanceKm = 0
        #expect(MeshtasticProtocolService.lightningStrikeCount(env) == 0)
        #expect(MeshtasticProtocolService.lightningDistance(env) == nil)

        env.lightningStrikeCount1H = 7
        env.lightningDistanceKm = 12
        #expect(MeshtasticProtocolService.lightningStrikeCount(env) == 7)
        #expect(MeshtasticProtocolService.lightningDistance(env) == 12)
    }

    @Test("Soil/water extraction keeps only present fields")
    func soilWaterExtraction() {
        var metrics = Meshtastic_SoilWaterMetrics()
        metrics.soilPh = 6.5
        metrics.ph = 0
        metrics.orp = -120
        let sample = MeshtasticProtocolService.soilWaterSample(metrics)
        #expect(sample.values == [.soilPH: 6.5, .waterPH: 0, .orp: -120])
    }

    // MARK: - Storage

    @Test("Lightning values round-trip through environment telemetry")
    func lightningRoundTrip() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = makeDatabase(in: directory)
        let timestamp = Self.now.addingTimeInterval(-60)

        database.insertEnvironmentTelemetrySample(
            nodeId: 0x42,
            timestamp: timestamp,
            sample: EnvironmentTelemetrySample(
                temperature: 18,
                lightningStrikeCount1Hour: 0,
                lightningDistance: 9.5
            )
        )
        database.waitForPendingWrites()

        let strikes = database.getTimeSeries(nodeIds: [0x42], metric: .lightningStrikeCount1Hour, days: 1)
        let distance = database.getTimeSeries(nodeIds: [0x42], metric: .lightningDistance, days: 1)
        #expect(strikes.map(\.value) == [0])
        #expect(distance.map(\.value) == [9.5])
        #expect(database.rowCount(in: "environment_telemetry") == 1)
    }

    @Test("Soil/water samples are stored in their own table and in telemetry_samples")
    func soilWaterRoundTrip() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = makeDatabase(in: directory)

        database.insertSoilWaterTelemetry(
            nodeId: 0x43,
            timestamp: Self.now.addingTimeInterval(-60),
            sample: SoilWaterTelemetrySample(values: [.soilPH: 6.8, .nitrate: 12.5])
        )
        database.waitForPendingWrites()

        #expect(database.rowCount(in: "soil_water_telemetry") == 1)
        #expect(database.rowCount(in: "telemetry_samples") == 2)
        #expect(database.getTimeSeries(nodeIds: [0x43], metric: .soilPH, days: 1).map(\.value) == [6.8])
        #expect(database.getKnownNodeIds().contains(0x43))
    }

    @Test("Opening an old database adds the lightning columns without data loss")
    func legacyEnvironmentTableMigration() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("telemetry.sqlite").path

        var legacy: OpaquePointer?
        #expect(sqlite3_open(path, &legacy) == SQLITE_OK)
        let legacySchema = """
            CREATE TABLE environment_telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                temperature REAL,
                relative_humidity REAL,
                barometric_pressure REAL,
                iaq REAL,
                is_day INTEGER DEFAULT 1
            );
            INSERT INTO environment_telemetry (node_id, timestamp, temperature, is_day)
                VALUES (7, 1799999000, 21.5, 1);
            """
        #expect(sqlite3_exec(legacy, legacySchema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(legacy)

        let database = makeDatabase(in: directory)
        database.waitForPendingWrites()
        #expect(database.rowCount(in: "environment_telemetry") == 1)

        var reopened: OpaquePointer?
        #expect(sqlite3_open(path, &reopened) == SQLITE_OK)
        defer { sqlite3_close(reopened) }
        var columns = Set<String>()
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(reopened, "PRAGMA table_info(environment_telemetry)", -1, &statement, nil)
            == SQLITE_OK)
        while sqlite3_step(statement) == SQLITE_ROW, let name = sqlite3_column_text(statement, 1) {
            columns.insert(String(cString: name))
        }
        sqlite3_finalize(statement)
        #expect(columns.contains("lightning_strike_count_1h"))
        #expect(columns.contains("lightning_distance_km"))

        var temperature: Double?
        #expect(sqlite3_prepare_v2(reopened, "SELECT temperature FROM environment_telemetry", -1, &statement, nil)
            == SQLITE_OK)
        if sqlite3_step(statement) == SQLITE_ROW {
            temperature = sqlite3_column_double(statement, 0)
        }
        sqlite3_finalize(statement)
        #expect(temperature == 21.5)
    }

    // MARK: - Radiation Unit

    @Test("Radiation converts from µR/h to µSv/h only when requested")
    func radiationUnit() {
        #expect(RadiationUnit.display(250, inSievert: true) == 2.5)
        #expect(RadiationUnit.display(250, inSievert: false) == 250)
        #expect(TelemetrySeriesMetric.radiation.displayUnit(radiationInSievert: true) == "µSv/h")
        #expect(TelemetrySeriesMetric.radiation.displayUnit(radiationInSievert: false) == "µR/h")
        #expect(TelemetrySeriesMetric.radiation.displaySuggestedRange(radiationInSievert: true) == 0...1)
        #expect(TelemetrySeriesMetric.temperature.displayValue(250, radiationInSievert: true) == 250)
    }

    @Test("Dashboard snapshots convert radiation series for display")
    func snapshotConversion() {
        var snapshot = TelemetryDashboardSnapshot()
        snapshot.series = [TelemetrySeriesPoint(nodeId: 1, timestamp: Self.now, value: 150, isDay: true)]
        snapshot.convertForDisplay(metric: .radiation, radiationInSievert: true)
        #expect(snapshot.series.map(\.value) == [1.5])
        #expect(snapshot.radiationInSievert)

        var other = TelemetryDashboardSnapshot()
        other.series = [TelemetrySeriesPoint(nodeId: 1, timestamp: Self.now, value: 150, isDay: true)]
        other.convertForDisplay(metric: .temperature, radiationInSievert: true)
        #expect(other.series.map(\.value) == [150])
    }

    @Test("Radiation setting defaults to off and persists")
    func radiationSetting() {
        let suite = "NewSensorTelemetryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsService(defaults: defaults)
        #expect(settings.radiationInSievert == false)
        settings.radiationInSievert = true
        #expect(defaults.bool(forKey: "radiationInSievert"))
    }
}
