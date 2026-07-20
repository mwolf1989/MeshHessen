import Foundation
import Testing

@testable import MeshHessen

@Suite("Telemetry Database Parity")
struct TelemetryDatabaseParityTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDatabase() -> (TelemetryDatabaseService, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-TelemetryTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("telemetry.sqlite")
        return (
            TelemetryDatabaseService(databaseURL: url, retentionDays: 0, clock: { Self.now }),
            directory
        )
    }

    @Test("Schema contains a durable table for every Meshtastic telemetry variant")
    func schemaCoversAllVariants() {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expected: Set<String> = [
            "packet_rx", "device_telemetry", "environment_telemetry",
            "air_quality_telemetry", "power_telemetry", "local_stats_telemetry",
            "host_telemetry", "health_telemetry", "traffic_telemetry",
            "pax_telemetry", "telemetry_samples", "traceroute_hops",
        ]

        #expect(expected.isSubset(of: database.schemaTableNames()))
    }

    @Test("All telemetry variants round-trip through normalized metric queries")
    func allVariantsRoundTrip() throws {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = Self.now.addingTimeInterval(-60)
        let nodeId: UInt32 = 0x1234

        database.insertDeviceTelemetrySample(
            nodeId: nodeId,
            timestamp: timestamp,
            batteryPercent: 87,
            voltage: 4.12,
            channelUtilization: 7.5,
            airUtilTx: 2.25,
            uptimeSeconds: 3_600
        )
        database.insertEnvironmentTelemetrySample(
            nodeId: nodeId,
            timestamp: timestamp,
            sample: EnvironmentTelemetrySample(
                temperature: 21.5,
                relativeHumidity: 48,
                barometricPressure: 1_013.2,
                gasResistance: 4.2,
                windSpeed: 6.5,
                rainfall24Hours: 12.4,
                soilMoisture: 55
            )
        )
        database.insertAirQualityTelemetry(
            nodeId: nodeId,
            timestamp: timestamp,
            sample: AirQualityTelemetrySample(values: [
                .pm25Standard: 13,
                .co2: 720,
                .particlesTypicalSize: 1.2,
            ])
        )
        database.insertPowerTelemetry(
            nodeId: nodeId,
            timestamp: timestamp,
            channels: [
                PowerChannelTelemetrySample(channel: 1, voltage: 12.4, current: 0.8),
                PowerChannelTelemetrySample(channel: 8, voltage: 5.1, current: 1.7),
            ]
        )
        database.insertLocalStatsTelemetry(
            nodeId: nodeId,
            timestamp: timestamp,
            sample: LocalTelemetrySample(
                packetsTx: 22,
                packetsRx: 44,
                onlineNodes: 9,
                heapFreeBytes: 8_192,
                noiseFloor: -112
            )
        )
        database.insertHostTelemetry(
            nodeId: nodeId,
            timestamp: timestamp,
            sample: HostTelemetrySample(
                uptimeSeconds: 90_000,
                freeMemoryBytes: 1_024,
                load1: 0.42,
                userString: "gateway"
            )
        )
        database.insertHealthTelemetry(
            nodeId: nodeId,
            timestamp: timestamp,
            sample: HealthTelemetrySample(heartRate: 72, temperature: 36.7)
        )
        database.insertTrafficTelemetry(
            nodeId: nodeId,
            timestamp: timestamp,
            sample: TrafficTelemetrySample(
                packetsInspected: 500,
                rateLimitDrops: 3,
                routerHopsPreserved: 18
            )
        )
        database.insertPaxTelemetry(
            nodeId: nodeId,
            timestamp: timestamp,
            sample: PaxTelemetrySample(wifiCount: 31, bleCount: 14, uptimeSeconds: 7_200)
        )
        database.waitForPendingWrites()

        let expectations: [TelemetrySeriesMetric: Double] = [
            .battery: 87,
            .windSpeed: 6.5,
            .pm25Standard: 13,
            .powerChannel8Current: 1.7,
            .localPacketsRx: 44,
            .hostLoad1: 0.42,
            .healthHeartRate: 72,
            .trafficRouterHopsPreserved: 18,
            .paxBLECount: 14,
            .paxUptimeSeconds: 7_200,
        ]
        for (metric, expected) in expectations {
            let point = try #require(
                database.getTimeSeries(nodeIds: [nodeId], metric: metric, days: 30).last
            )
            #expect(abs(point.value - expected) < 0.000_1)
        }
        #expect(
            database.getTimeSeries(nodeIds: [nodeId], metric: .healthSpO2, days: 30).isEmpty
        )
    }

    @Test("Packet-count series aggregates packets into hourly buckets")
    func packetCountAggregation() throws {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nodeId: UInt32 = 7

        database.insertPacketRx(
            nodeId: nodeId,
            packetId: 1,
            timestamp: Self.now.addingTimeInterval(-120),
            snr: 4,
            rssi: -90,
            hopCount: 1,
            wantAck: false
        )
        database.insertPacketRx(
            nodeId: nodeId,
            packetId: 2,
            timestamp: Self.now.addingTimeInterval(-60),
            snr: 5,
            rssi: -88,
            hopCount: 0,
            wantAck: true
        )
        database.waitForPendingWrites()

        let points = database.getTimeSeries(nodeIds: [nodeId], metric: .packetCount, days: 1)
        #expect(points.count == 1)
        #expect(try #require(points.first).value == 2)
    }

    @Test("Retention removes expired rows from source and normalized tables")
    func retentionCleansAllTables() {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nodeId: UInt32 = 9

        database.insertHealthTelemetry(
            nodeId: nodeId,
            timestamp: Self.now.addingTimeInterval(-40 * 86_400),
            sample: HealthTelemetrySample(heartRate: 60)
        )
        database.insertHealthTelemetry(
            nodeId: nodeId,
            timestamp: Self.now.addingTimeInterval(-86_400),
            sample: HealthTelemetrySample(heartRate: 70)
        )
        database.waitForPendingWrites()
        database.runRetentionCleanup(retentionDays: 30, now: Self.now)
        database.waitForPendingWrites()

        #expect(database.rowCount(in: "health_telemetry") == 1)
        let values = database.getTimeSeries(nodeIds: [nodeId], metric: .healthHeartRate, days: 0)
        #expect(values.map(\.value) == [70])
    }

    @Test("Candlesticks, histograms and activity timelines are derived safely")
    func derivedQueries() {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nodeId: UInt32 = 11
        for (index, value) in [1.0, 3.0, 2.0, 4.0].enumerated() {
            database.insertDeviceTelemetrySample(
                nodeId: nodeId,
                timestamp: Self.now.addingTimeInterval(Double(index - 4) * 60),
                voltage: value
            )
        }
        database.waitForPendingWrites()

        let candle = database.getCandlestickData(nodeId: nodeId, metric: .voltage, days: 1)
        #expect(candle.count == 1)
        #expect(candle.first?.open == 1)
        #expect(candle.first?.high == 4)
        #expect(candle.first?.low == 1)
        #expect(candle.first?.close == 4)
        #expect(!database.getHistogram(nodeId: nodeId, metric: .voltage, days: 1).isEmpty)
    }
}

@Suite("Telemetry Dashboard Models")
struct TelemetryDashboardModelTests {
    @Test("Windows parity exposes exactly all fourteen widget types")
    func allWidgetTypes() {
        #expect(TelemetryDashboardWidgetType.allCases.count == 14)
        #expect(Set(TelemetryDashboardWidgetType.allCases.map(\.rawValue)) == [
            "line", "area", "bar", "scatter", "gauge", "stat", "heatmap",
            "histogram", "candlestick", "stateline", "ranking", "multistat",
            "meshhealth", "clock",
        ])
    }

    @Test("Widget normalization clamps dimensions, removes duplicates and validates options")
    func widgetNormalization() {
        var widget = TelemetryDashboardWidget(type: .gauge, nodeIds: [3, 2, 3])
        widget.width = 10
        widget.height = .nan
        widget.days = 999
        widget.threshold = .infinity
        widget.showMovingAverage = true
        widget.normalize()

        #expect(widget.nodeIds == [2])
        #expect(widget.width == TelemetryDashboardWidget.minimumWidth)
        #expect(widget.height == 300)
        #expect(widget.days == 7)
        #expect(widget.threshold == nil)
        #expect(!widget.showMovingAverage)
    }

    @Test("Layout engine packs cards into stable width-aware rows")
    func layoutRows() {
        let first = TelemetryDashboardWidget(width: 300)
        let second = TelemetryDashboardWidget(width: 300)
        let third = TelemetryDashboardWidget(width: 300)

        let rows = TelemetryDashboardLayoutEngine.rows(
            widgets: [first, second, third],
            availableWidth: 620,
            spacing: 12
        )

        #expect(rows == [[first.id, second.id], [third.id]])
    }

    @Test("Moving average keeps node series separate")
    func movingAverage() {
        let start = Date(timeIntervalSince1970: 1_000)
        let points = [
            TelemetrySeriesPoint(nodeId: 1, timestamp: start, value: 1, isDay: true),
            TelemetrySeriesPoint(nodeId: 2, timestamp: start, value: 100, isDay: true),
            TelemetrySeriesPoint(nodeId: 1, timestamp: start.addingTimeInterval(10), value: 3, isDay: true),
        ]

        let average = TelemetryDatabaseService.rollingAverage(points, window: 60)
        #expect(average.first(where: { $0.nodeId == 1 && $0.timestamp > start })?.value == 2)
        #expect(average.first(where: { $0.nodeId == 2 })?.value == 100)
    }
}

@Suite("Telemetry Dashboard Store")
@MainActor
struct TelemetryDashboardStoreTests {
    private func makeDefaults() throws -> (String, UserDefaults) {
        let suite = "TelemetryDashboardStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (suite, defaults)
    }

    @Test("Dashboard and widget layout persist across store instances")
    func persistence() throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "dashboard-test"
        let store = TelemetryDashboardStore(defaults: defaults, storageKey: key)
        let dashboardID = store.addDashboard(named: "Field Ops")
        let widget = TelemetryDashboardWidget(
            type: .meshhealth,
            nodeIds: [1, 2],
            days: 30,
            width: 640,
            height: 420
        )
        store.addWidget(widget, to: dashboardID)

        let restored = TelemetryDashboardStore(defaults: defaults, storageKey: key)
        #expect(restored.selectedDashboardID == dashboardID)
        #expect(restored.currentDashboard?.name == "Field Ops")
        #expect(restored.currentDashboard?.widgets == [widget])
    }

    @Test("Widget reorder, update and removal are ID based")
    func widgetMutations() throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TelemetryDashboardStore(defaults: defaults, storageKey: "mutations")
        let first = TelemetryDashboardWidget(title: "First")
        var second = TelemetryDashboardWidget(title: "Second")
        store.addWidget(first)
        store.addWidget(second)

        store.reorderWidget(sourceID: second.id, before: first.id)
        #expect(store.currentDashboard?.widgets.map(\.id) == [second.id, first.id])

        second.title = "Updated"
        store.updateWidget(second)
        #expect(store.currentDashboard?.widgets.first?.title == "Updated")

        store.removeWidget(id: second.id)
        #expect(store.currentDashboard?.widgets.map(\.id) == [first.id])
    }
}
