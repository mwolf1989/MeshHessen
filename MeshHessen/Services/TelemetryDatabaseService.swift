import Foundation
import SQLite3

/// Persistent SQLite telemetry storage.
///
/// SQLite access is confined to a private serial queue. The type is marked
/// `@unchecked Sendable` only because SQLite's C pointer cannot express that
/// confinement to the compiler; callers never receive the pointer.
final class TelemetryDatabaseService: @unchecked Sendable {
    static let shared = TelemetryDatabaseService(
        databaseURL: TelemetryDatabaseService.defaultDatabaseURL(),
        retentionDays: SettingsService.shared.telemetryRetentionDays
    )

    private enum SQLiteBinding {
        case integer(Int64)
        case double(Double)
        case text(String)
        case null

        static func optionalDouble(_ value: Double?) -> Self {
            value.map(Self.double) ?? .null
        }
    }

    private struct StoredPayload: Codable {
        let values: [String: Double]
        let text: [String: String]
    }

    private static let timestampTables = [
        "packet_rx",
        "device_telemetry",
        "environment_telemetry",
        "air_quality_telemetry",
        "power_telemetry",
        "local_stats_telemetry",
        "host_telemetry",
        "health_telemetry",
        "traffic_telemetry",
        "pax_telemetry",
        "telemetry_samples",
        "traceroute_hops",
    ]

    private var db: OpaquePointer?
    private let queue: DispatchQueue
    private let clock: @Sendable () -> Date
    private let databasePath: String

    init(
        databaseURL: URL,
        retentionDays: Int = 0,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.databasePath = databaseURL.path
        self.queue = DispatchQueue(
            label: "MeshHessen.telemetryDB.\(UUID().uuidString)",
            qos: .utility
        )
        self.clock = clock

        let directory = databaseURL.deletingLastPathComponent()
        if !directory.path.isEmpty {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                AppLogger.shared.log("[TelemetryDB] Cannot create database directory: \(error)")
            }
        }

        openDatabase()
        createTables()
        migrateLegacyRows()
        if retentionDays > 0 {
            runRetentionCleanup(retentionDays: retentionDays, now: clock())
            waitForPendingWrites()
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Database Setup

    private static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MeshHessen", isDirectory: true)
            .appendingPathComponent("telemetry.db")
    }

    private func openDatabase() {
        guard sqlite3_open_v2(
            databasePath,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            AppLogger.shared.log("[TelemetryDB] Failed to open database: \(message)")
            if let db { sqlite3_close_v2(db) }
            db = nil
            return
        }

        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA synchronous=NORMAL")
        execute("PRAGMA foreign_keys=ON")
        execute("PRAGMA busy_timeout=5000")
        AppLogger.shared.log("[TelemetryDB] Database opened at \(databasePath)", debug: true)
    }

    private func createTables() {
        guard let db else { return }
        let schema = """
            CREATE TABLE IF NOT EXISTS packet_rx (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL,
                packet_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                rx_snr REAL,
                rx_rssi INTEGER,
                hop_count INTEGER,
                via_mqtt INTEGER DEFAULT 0,
                want_ack INTEGER DEFAULT 0,
                ack_received INTEGER DEFAULT 0,
                is_day INTEGER DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_pkt_node_time ON packet_rx (node_id, timestamp);
            CREATE INDEX IF NOT EXISTS idx_pkt_id ON packet_rx (packet_id);

            CREATE TABLE IF NOT EXISTS device_telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                battery_percent REAL,
                voltage REAL,
                channel_utilization REAL,
                air_util_tx REAL,
                uptime_seconds INTEGER,
                is_day INTEGER DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_devtel_node_time
                ON device_telemetry (node_id, timestamp);

            CREATE TABLE IF NOT EXISTS environment_telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                temperature REAL,
                relative_humidity REAL,
                barometric_pressure REAL,
                gas_resistance REAL,
                voltage REAL,
                current REAL,
                iaq REAL,
                distance REAL,
                lux REAL,
                white_lux REAL,
                ir_lux REAL,
                uv_lux REAL,
                wind_direction REAL,
                wind_speed REAL,
                weight REAL,
                wind_gust REAL,
                wind_lull REAL,
                radiation REAL,
                rainfall_1h REAL,
                rainfall_24h REAL,
                soil_moisture REAL,
                soil_temperature REAL,
                is_day INTEGER DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_envtel_node_time
                ON environment_telemetry (node_id, timestamp);

            CREATE TABLE IF NOT EXISTS air_quality_telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                payload_json TEXT NOT NULL,
                is_day INTEGER DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_airtel_node_time
                ON air_quality_telemetry (node_id, timestamp);

            CREATE TABLE IF NOT EXISTS power_telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                payload_json TEXT NOT NULL,
                is_day INTEGER DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_powertel_node_time
                ON power_telemetry (node_id, timestamp);

            CREATE TABLE IF NOT EXISTS local_stats_telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                payload_json TEXT NOT NULL,
                is_day INTEGER DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_localtel_node_time
                ON local_stats_telemetry (node_id, timestamp);

            CREATE TABLE IF NOT EXISTS host_telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                payload_json TEXT NOT NULL,
                is_day INTEGER DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_hosttel_node_time
                ON host_telemetry (node_id, timestamp);

            CREATE TABLE IF NOT EXISTS health_telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                payload_json TEXT NOT NULL,
                is_day INTEGER DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_healthtel_node_time
                ON health_telemetry (node_id, timestamp);

            CREATE TABLE IF NOT EXISTS traffic_telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                payload_json TEXT NOT NULL,
                is_day INTEGER DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_traffictel_node_time
                ON traffic_telemetry (node_id, timestamp);

            CREATE TABLE IF NOT EXISTS pax_telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                payload_json TEXT NOT NULL,
                is_day INTEGER DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_paxtel_node_time
                ON pax_telemetry (node_id, timestamp);

            CREATE TABLE IF NOT EXISTS telemetry_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                variant TEXT NOT NULL,
                metric TEXT NOT NULL,
                value REAL NOT NULL,
                is_day INTEGER DEFAULT 1
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_telsample_unique
                ON telemetry_samples (node_id, timestamp, variant, metric);
            CREATE INDEX IF NOT EXISTS idx_telsample_metric_node_time
                ON telemetry_samples (metric, node_id, timestamp);

            CREATE TABLE IF NOT EXISTS traceroute_hops (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                request_id INTEGER NOT NULL,
                source_node_id INTEGER NOT NULL,
                dest_node_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                hop_index INTEGER NOT NULL,
                node_id INTEGER NOT NULL,
                snr_towards REAL,
                snr_back REAL
            );
            CREATE INDEX IF NOT EXISTS idx_trace_src_ts
                ON traceroute_hops (source_node_id, timestamp);
            CREATE INDEX IF NOT EXISTS idx_trace_dest_ts
                ON traceroute_hops (dest_node_id, timestamp);
            """
        execute(schema, on: db)

        ensureColumns(
            table: "packet_rx",
            columns: ["via_mqtt": "INTEGER DEFAULT 0"],
            on: db
        )

        // Existing installations may have the original compact environment table.
        ensureColumns(
            table: "environment_telemetry",
            columns: [
                "gas_resistance": "REAL", "voltage": "REAL", "current": "REAL",
                "distance": "REAL", "lux": "REAL", "white_lux": "REAL",
                "ir_lux": "REAL", "uv_lux": "REAL", "wind_direction": "REAL",
                "wind_speed": "REAL", "weight": "REAL", "wind_gust": "REAL",
                "wind_lull": "REAL", "radiation": "REAL", "rainfall_1h": "REAL",
                "rainfall_24h": "REAL", "soil_moisture": "REAL",
                "soil_temperature": "REAL",
            ],
            on: db
        )
    }

    private func ensureColumns(
        table: String,
        columns: [String: String],
        on db: OpaquePointer
    ) {
        let existing = Set(tableColumns(table, on: db))
        for (name, type) in columns where !existing.contains(name) {
            execute("ALTER TABLE \(table) ADD COLUMN \(name) \(type)", on: db)
        }
    }

    private func migrateLegacyRows() {
        guard let db else { return }
        let migrations = [
            """
            INSERT OR IGNORE INTO telemetry_samples
                (node_id, timestamp, variant, metric, value, is_day)
            SELECT node_id, timestamp, 'packet', 'snr', rx_snr, is_day
            FROM packet_rx WHERE rx_snr IS NOT NULL
            """,
            """
            INSERT OR IGNORE INTO telemetry_samples
                (node_id, timestamp, variant, metric, value, is_day)
            SELECT node_id, timestamp, 'packet', 'rssi', rx_rssi, is_day
            FROM packet_rx WHERE rx_rssi IS NOT NULL
            """,
            """
            INSERT OR IGNORE INTO telemetry_samples
                (node_id, timestamp, variant, metric, value, is_day)
            SELECT node_id, timestamp, 'device', 'battery', battery_percent, is_day
            FROM device_telemetry WHERE battery_percent IS NOT NULL
            """,
            """
            INSERT OR IGNORE INTO telemetry_samples
                (node_id, timestamp, variant, metric, value, is_day)
            SELECT node_id, timestamp, 'device', 'voltage', voltage, is_day
            FROM device_telemetry WHERE voltage IS NOT NULL
            """,
            """
            INSERT OR IGNORE INTO telemetry_samples
                (node_id, timestamp, variant, metric, value, is_day)
            SELECT node_id, timestamp, 'device', 'channel_utilization', channel_utilization, is_day
            FROM device_telemetry WHERE channel_utilization IS NOT NULL
            """,
            """
            INSERT OR IGNORE INTO telemetry_samples
                (node_id, timestamp, variant, metric, value, is_day)
            SELECT node_id, timestamp, 'device', 'air_util_tx', air_util_tx, is_day
            FROM device_telemetry WHERE air_util_tx IS NOT NULL
            """,
            """
            INSERT OR IGNORE INTO telemetry_samples
                (node_id, timestamp, variant, metric, value, is_day)
            SELECT node_id, timestamp, 'device', 'uptime_seconds', uptime_seconds, is_day
            FROM device_telemetry WHERE uptime_seconds IS NOT NULL
            """,
            """
            INSERT OR IGNORE INTO telemetry_samples
                (node_id, timestamp, variant, metric, value, is_day)
            SELECT node_id, timestamp, 'environment', 'temperature', temperature, is_day
            FROM environment_telemetry WHERE temperature IS NOT NULL
            """,
            """
            INSERT OR IGNORE INTO telemetry_samples
                (node_id, timestamp, variant, metric, value, is_day)
            SELECT node_id, timestamp, 'environment', 'relative_humidity', relative_humidity, is_day
            FROM environment_telemetry WHERE relative_humidity IS NOT NULL
            """,
            """
            INSERT OR IGNORE INTO telemetry_samples
                (node_id, timestamp, variant, metric, value, is_day)
            SELECT node_id, timestamp, 'environment', 'barometric_pressure', barometric_pressure, is_day
            FROM environment_telemetry WHERE barometric_pressure IS NOT NULL
            """,
            """
            INSERT OR IGNORE INTO telemetry_samples
                (node_id, timestamp, variant, metric, value, is_day)
            SELECT node_id, timestamp, 'environment', 'iaq', iaq, is_day
            FROM environment_telemetry WHERE iaq IS NOT NULL
            """,
        ]
        execute("BEGIN IMMEDIATE", on: db)
        var succeeded = true
        for sql in migrations where !execute(sql, on: db) { succeeded = false }
        execute(succeeded ? "COMMIT" : "ROLLBACK", on: db)
    }

    // MARK: - Packet and Device Inserts

    func insertPacketRx(
        nodeId: UInt32,
        packetId: UInt32,
        snr: Float,
        rssi: Int32,
        hopCount: Int,
        viaMqtt: Bool = false,
        wantAck: Bool,
        latitude: Double = 0,
        longitude: Double = 0
    ) {
        insertPacketRx(
            nodeId: nodeId,
            packetId: packetId,
            timestamp: clock(),
            snr: snr,
            rssi: rssi,
            hopCount: hopCount,
            viaMqtt: viaMqtt,
            wantAck: wantAck,
            latitude: latitude,
            longitude: longitude
        )
    }

    func insertPacketRx(
        nodeId: UInt32,
        packetId: UInt32,
        timestamp: Date,
        snr: Float,
        rssi: Int32,
        hopCount: Int,
        viaMqtt: Bool = false,
        wantAck: Bool,
        latitude: Double = 0,
        longitude: Double = 0
    ) {
        enqueueWrite { service, db in
            let isDay = service.dayFlag(timestamp, latitude: latitude, longitude: longitude)
            let ts = timestamp.timeIntervalSince1970
            service.inTransaction(on: db) {
                let inserted = service.run(
                    """
                    INSERT INTO packet_rx
                        (node_id, packet_id, timestamp, rx_snr, rx_rssi, hop_count, via_mqtt, want_ack, is_day)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .integer(Int64(nodeId)), .integer(Int64(packetId)), .double(ts),
                        .double(Double(snr)), .integer(Int64(rssi)), .integer(Int64(hopCount)),
                        .integer(viaMqtt ? 1 : 0), .integer(wantAck ? 1 : 0),
                        .integer(Int64(isDay)),
                    ],
                    on: db
                )
                let samples: [TelemetrySeriesMetric: Double] = [
                    .snr: Double(snr), .rssi: Double(rssi),
                ]
                return inserted && service.insertSamples(
                    nodeId: nodeId,
                    timestamp: ts,
                    variant: "packet",
                    values: samples,
                    isDay: isDay,
                    on: db
                )
            }
        }
    }

    /// Restores the latest true 0-hop RF contact per node for the permanent
    /// neighbor overlay. MQTT packets are excluded even when their hop count is
    /// reported as zero.
    func getDirectNeighborContacts(since cutoff: Date? = nil) -> [DirectNeighborContact] {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return [] }
            let sql = """
                SELECT p.node_id, p.timestamp, p.rx_snr, p.rx_rssi
                FROM packet_rx p
                INNER JOIN (
                    SELECT node_id, MAX(timestamp) AS latest
                    FROM packet_rx
                    WHERE hop_count = 0 AND COALESCE(via_mqtt, 0) = 0 AND timestamp >= ?
                    GROUP BY node_id
                ) latest
                ON latest.node_id = p.node_id AND latest.latest = p.timestamp
                WHERE p.hop_count = 0 AND COALESCE(p.via_mqtt, 0) = 0
                ORDER BY p.timestamp DESC
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, cutoff?.timeIntervalSince1970 ?? 0)

            var contacts: [DirectNeighborContact] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let nodeID = UInt32(clamping: sqlite3_column_int64(statement, 0))
                let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                let snr = sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : Float(sqlite3_column_double(statement, 2))
                let rssi = sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : Int32(clamping: sqlite3_column_int64(statement, 3))
                contacts.append(
                    DirectNeighborContact(
                        nodeId: nodeID,
                        timestamp: timestamp,
                        snr: snr,
                        rssi: rssi,
                        latitude: nil,
                        longitude: nil
                    )
                )
            }
            return contacts
        }
    }

    func markAckReceived(packetId: UInt32) {
        enqueueWrite { service, db in
            _ = service.run(
                "UPDATE packet_rx SET ack_received = 1 WHERE packet_id = ?",
                bindings: [.integer(Int64(packetId))],
                on: db
            )
        }
    }

    func insertDeviceTelemetry(
        nodeId: UInt32,
        batteryPercent: UInt32,
        voltage: Float,
        channelUtilization: Float,
        airUtilTx: Float,
        uptimeSeconds: UInt32,
        latitude: Double = 0,
        longitude: Double = 0
    ) {
        insertDeviceTelemetrySample(
            nodeId: nodeId,
            timestamp: clock(),
            batteryPercent: Double(batteryPercent),
            voltage: Double(voltage),
            channelUtilization: Double(channelUtilization),
            airUtilTx: Double(airUtilTx),
            uptimeSeconds: Double(uptimeSeconds),
            latitude: latitude,
            longitude: longitude
        )
    }

    func insertDeviceTelemetrySample(
        nodeId: UInt32,
        timestamp: Date = Date(),
        batteryPercent: Double? = nil,
        voltage: Double? = nil,
        channelUtilization: Double? = nil,
        airUtilTx: Double? = nil,
        uptimeSeconds: Double? = nil,
        latitude: Double = 0,
        longitude: Double = 0
    ) {
        enqueueWrite { service, db in
            let ts = timestamp.timeIntervalSince1970
            let isDay = service.dayFlag(timestamp, latitude: latitude, longitude: longitude)
            let values: [TelemetrySeriesMetric: Double?] = [
                .battery: batteryPercent,
                .voltage: voltage,
                .channelUtilization: channelUtilization,
                .airUtilTx: airUtilTx,
                .uptimeSeconds: uptimeSeconds,
            ]
            service.inTransaction(on: db) {
                let inserted = service.run(
                    """
                    INSERT INTO device_telemetry
                        (node_id, timestamp, battery_percent, voltage, channel_utilization,
                         air_util_tx, uptime_seconds, is_day)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .integer(Int64(nodeId)), .double(ts), .optionalDouble(batteryPercent),
                        .optionalDouble(voltage), .optionalDouble(channelUtilization),
                        .optionalDouble(airUtilTx), .optionalDouble(uptimeSeconds),
                        .integer(Int64(isDay)),
                    ],
                    on: db
                )
                return inserted && service.insertSamples(
                    nodeId: nodeId,
                    timestamp: ts,
                    variant: "device",
                    values: values.compactMapValues { $0 },
                    isDay: isDay,
                    on: db
                )
            }
        }
    }

    // MARK: - Telemetry Variant Inserts

    func insertEnvironmentTelemetry(
        nodeId: UInt32,
        temperature: Float,
        relativeHumidity: Float,
        barometricPressure: Float,
        iaq: UInt32,
        latitude: Double = 0,
        longitude: Double = 0
    ) {
        insertEnvironmentTelemetrySample(
            nodeId: nodeId,
            timestamp: clock(),
            sample: EnvironmentTelemetrySample(
                temperature: Double(temperature),
                relativeHumidity: Double(relativeHumidity),
                barometricPressure: Double(barometricPressure),
                iaq: Double(iaq)
            ),
            latitude: latitude,
            longitude: longitude
        )
    }

    func insertEnvironmentTelemetrySample(
        nodeId: UInt32,
        timestamp: Date = Date(),
        sample: EnvironmentTelemetrySample,
        latitude: Double = 0,
        longitude: Double = 0
    ) {
        enqueueWrite { service, db in
            let ts = timestamp.timeIntervalSince1970
            let isDay = service.dayFlag(timestamp, latitude: latitude, longitude: longitude)
            let values = service.environmentValues(sample)
            service.inTransaction(on: db) {
                let inserted = service.run(
                    """
                    INSERT INTO environment_telemetry
                        (node_id, timestamp, temperature, relative_humidity, barometric_pressure,
                         gas_resistance, voltage, current, iaq, distance, lux, white_lux, ir_lux,
                         uv_lux, wind_direction, wind_speed, weight, wind_gust, wind_lull,
                         radiation, rainfall_1h, rainfall_24h, soil_moisture, soil_temperature,
                         is_day)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .integer(Int64(nodeId)), .double(ts), .optionalDouble(sample.temperature),
                        .optionalDouble(sample.relativeHumidity), .optionalDouble(sample.barometricPressure),
                        .optionalDouble(sample.gasResistance), .optionalDouble(sample.voltage),
                        .optionalDouble(sample.current), .optionalDouble(sample.iaq),
                        .optionalDouble(sample.distance), .optionalDouble(sample.lux),
                        .optionalDouble(sample.whiteLux), .optionalDouble(sample.irLux),
                        .optionalDouble(sample.uvLux), .optionalDouble(sample.windDirection),
                        .optionalDouble(sample.windSpeed), .optionalDouble(sample.weight),
                        .optionalDouble(sample.windGust), .optionalDouble(sample.windLull),
                        .optionalDouble(sample.radiation), .optionalDouble(sample.rainfall1Hour),
                        .optionalDouble(sample.rainfall24Hours), .optionalDouble(sample.soilMoisture),
                        .optionalDouble(sample.soilTemperature), .integer(Int64(isDay)),
                    ],
                    on: db
                )
                return inserted && service.insertSamples(
                    nodeId: nodeId,
                    timestamp: ts,
                    variant: "environment",
                    values: values,
                    isDay: isDay,
                    on: db
                )
            }
        }
    }

    func insertAirQualityTelemetry(
        nodeId: UInt32,
        timestamp: Date = Date(),
        sample: AirQualityTelemetrySample,
        latitude: Double = 0,
        longitude: Double = 0
    ) {
        insertVariant(
            table: "air_quality_telemetry",
            variant: "air_quality",
            nodeId: nodeId,
            timestamp: timestamp,
            values: sample.values,
            latitude: latitude,
            longitude: longitude
        )
    }

    func insertPowerTelemetry(
        nodeId: UInt32,
        timestamp: Date = Date(),
        channels: [PowerChannelTelemetrySample],
        latitude: Double = 0,
        longitude: Double = 0
    ) {
        var values: [TelemetrySeriesMetric: Double] = [:]
        for channel in channels {
            if let voltage = channel.voltage,
               let metric = Self.powerMetric(channel: channel.channel, voltage: true) {
                values[metric] = voltage
            }
            if let current = channel.current,
               let metric = Self.powerMetric(channel: channel.channel, voltage: false) {
                values[metric] = current
            }
        }
        insertVariant(
            table: "power_telemetry",
            variant: "power",
            nodeId: nodeId,
            timestamp: timestamp,
            values: values,
            latitude: latitude,
            longitude: longitude
        )
    }

    func insertLocalStatsTelemetry(
        nodeId: UInt32,
        timestamp: Date = Date(),
        sample: LocalTelemetrySample,
        latitude: Double = 0,
        longitude: Double = 0
    ) {
        let values: [TelemetrySeriesMetric: Double?] = [
            .uptimeSeconds: sample.uptimeSeconds,
            .channelUtilization: sample.channelUtilization,
            .airUtilTx: sample.airUtilTx,
            .localPacketsTx: sample.packetsTx,
            .localPacketsRx: sample.packetsRx,
            .localPacketsRxBad: sample.packetsRxBad,
            .localOnlineNodes: sample.onlineNodes,
            .localTotalNodes: sample.totalNodes,
            .localRxDuplicates: sample.rxDuplicates,
            .localTxRelays: sample.txRelays,
            .localCanceledRelays: sample.canceledRelays,
            .localHeapTotalBytes: sample.heapTotalBytes,
            .localHeapFreeBytes: sample.heapFreeBytes,
            .localTxDropped: sample.txDropped,
            .localNoiseFloor: sample.noiseFloor,
        ]
        insertVariant(
            table: "local_stats_telemetry",
            variant: "local",
            nodeId: nodeId,
            timestamp: timestamp,
            values: values.compactMapValues { $0 },
            latitude: latitude,
            longitude: longitude
        )
    }

    func insertHostTelemetry(
        nodeId: UInt32,
        timestamp: Date = Date(),
        sample: HostTelemetrySample,
        latitude: Double = 0,
        longitude: Double = 0
    ) {
        let values: [TelemetrySeriesMetric: Double?] = [
            .hostUptimeSeconds: sample.uptimeSeconds,
            .hostFreeMemoryBytes: sample.freeMemoryBytes,
            .hostDisk1FreeBytes: sample.disk1FreeBytes,
            .hostDisk2FreeBytes: sample.disk2FreeBytes,
            .hostDisk3FreeBytes: sample.disk3FreeBytes,
            .hostLoad1: sample.load1,
            .hostLoad5: sample.load5,
            .hostLoad15: sample.load15,
        ]
        let text = sample.userString.map { ["user_string": $0] } ?? [:]
        insertVariant(
            table: "host_telemetry",
            variant: "host",
            nodeId: nodeId,
            timestamp: timestamp,
            values: values.compactMapValues { $0 },
            text: text,
            latitude: latitude,
            longitude: longitude
        )
    }

    func insertHealthTelemetry(
        nodeId: UInt32,
        timestamp: Date = Date(),
        sample: HealthTelemetrySample,
        latitude: Double = 0,
        longitude: Double = 0
    ) {
        let values: [TelemetrySeriesMetric: Double?] = [
            .healthHeartRate: sample.heartRate,
            .healthSpO2: sample.spO2,
            .healthTemperature: sample.temperature,
        ]
        insertVariant(
            table: "health_telemetry",
            variant: "health",
            nodeId: nodeId,
            timestamp: timestamp,
            values: values.compactMapValues { $0 },
            latitude: latitude,
            longitude: longitude
        )
    }

    func insertTrafficTelemetry(
        nodeId: UInt32,
        timestamp: Date = Date(),
        sample: TrafficTelemetrySample,
        latitude: Double = 0,
        longitude: Double = 0
    ) {
        let values: [TelemetrySeriesMetric: Double?] = [
            .trafficPacketsInspected: sample.packetsInspected,
            .trafficPositionDedupDrops: sample.positionDedupDrops,
            .trafficNodeInfoCacheHits: sample.nodeInfoCacheHits,
            .trafficRateLimitDrops: sample.rateLimitDrops,
            .trafficUnknownPacketDrops: sample.unknownPacketDrops,
            .trafficHopExhaustedPackets: sample.hopExhaustedPackets,
            .trafficRouterHopsPreserved: sample.routerHopsPreserved,
        ]
        insertVariant(
            table: "traffic_telemetry",
            variant: "traffic",
            nodeId: nodeId,
            timestamp: timestamp,
            values: values.compactMapValues { $0 },
            latitude: latitude,
            longitude: longitude
        )
    }

    func insertPaxTelemetry(
        nodeId: UInt32,
        timestamp: Date = Date(),
        sample: PaxTelemetrySample,
        latitude: Double = 0,
        longitude: Double = 0
    ) {
        let values: [TelemetrySeriesMetric: Double?] = [
            .paxWifiCount: sample.wifiCount,
            .paxBLECount: sample.bleCount,
            .paxUptimeSeconds: sample.uptimeSeconds,
        ]
        insertVariant(
            table: "pax_telemetry",
            variant: "pax",
            nodeId: nodeId,
            timestamp: timestamp,
            values: values.compactMapValues { $0 },
            latitude: latitude,
            longitude: longitude
        )
    }

    private func insertVariant(
        table: String,
        variant: String,
        nodeId: UInt32,
        timestamp: Date,
        values: [TelemetrySeriesMetric: Double],
        text: [String: String] = [:],
        latitude: Double,
        longitude: Double
    ) {
        guard Self.timestampTables.contains(table) else { return }
        let payload = encodePayload(values: values, text: text)
        enqueueWrite { service, db in
            let ts = timestamp.timeIntervalSince1970
            let isDay = service.dayFlag(timestamp, latitude: latitude, longitude: longitude)
            service.inTransaction(on: db) {
                let inserted = service.run(
                    "INSERT INTO \(table) (node_id, timestamp, payload_json, is_day) VALUES (?, ?, ?, ?)",
                    bindings: [
                        .integer(Int64(nodeId)), .double(ts), .text(payload), .integer(Int64(isDay)),
                    ],
                    on: db
                )
                return inserted && service.insertSamples(
                    nodeId: nodeId,
                    timestamp: ts,
                    variant: variant,
                    values: values,
                    isDay: isDay,
                    on: db
                )
            }
        }
    }

    // MARK: - Traceroute

    func insertTracerouteHops(
        requestId: UInt32,
        sourceNodeId: UInt32,
        destNodeId: UInt32,
        hops: [(nodeId: UInt32, snrTowards: Float?, snrBack: Float?)]
    ) {
        let timestamp = clock().timeIntervalSince1970
        let sendableHops = hops.map {
            (nodeId: $0.nodeId, towards: $0.snrTowards.map(Double.init), back: $0.snrBack.map(Double.init))
        }
        enqueueWrite { service, db in
            service.inTransaction(on: db) {
                if sendableHops.isEmpty {
                    return service.run(
                        """
                        INSERT INTO traceroute_hops
                            (request_id, source_node_id, dest_node_id, timestamp, hop_index,
                             node_id, snr_towards, snr_back)
                        VALUES (?, ?, ?, ?, -1, ?, NULL, NULL)
                        """,
                        bindings: [
                            .integer(Int64(requestId)), .integer(Int64(sourceNodeId)),
                            .integer(Int64(destNodeId)), .double(timestamp), .integer(Int64(destNodeId)),
                        ],
                        on: db
                    )
                }
                var succeeded = true
                for (index, hop) in sendableHops.enumerated() {
                    let bindings: [SQLiteBinding] = [
                        .integer(Int64(requestId)),
                        .integer(Int64(sourceNodeId)),
                        .integer(Int64(destNodeId)),
                        .double(timestamp),
                        .integer(Int64(index)),
                        .integer(Int64(hop.nodeId)),
                        .optionalDouble(hop.towards),
                        .optionalDouble(hop.back),
                    ]
                    let inserted = service.run(
                        """
                        INSERT INTO traceroute_hops
                            (request_id, source_node_id, dest_node_id, timestamp, hop_index,
                             node_id, snr_towards, snr_back)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        bindings: bindings,
                        on: db
                    )
                    succeeded = inserted && succeeded
                }
                return succeeded
            }
        }
    }

    // MARK: - Compatibility Statistics

    func getSignalStats(nodeId: UInt32, days: Int) -> SignalStats {
        let snr = getTimeSeries(nodeIds: [nodeId], metric: .snr, days: days)
        let rssi = getTimeSeries(nodeIds: [nodeId], metric: .rssi, days: days)
        let daySnr = snr.filter(\.isDay).map(\.value)
        let nightSnr = snr.filter { !$0.isDay }.map(\.value)
        let dayRssi = rssi.filter(\.isDay).map(\.value)
        let nightRssi = rssi.filter { !$0.isDay }.map(\.value)
        let mean = snr.isEmpty ? 0 : snr.map(\.value).reduce(0, +) / Double(snr.count)

        return SignalStats(
            daySnrMedian: Self.median(daySnr),
            nightSnrMedian: Self.median(nightSnr),
            dayRssiMedian: Self.median(dayRssi),
            nightRssiMedian: Self.median(nightRssi),
            snrMin: snr.map(\.value).min() ?? 0,
            snrMax: snr.map(\.value).max() ?? 0,
            rssiMin: rssi.map(\.value).min() ?? 0,
            rssiMax: rssi.map(\.value).max() ?? 0,
            snrVariance: snr.isEmpty ? 0 : snr.map(\.value).reduce(0) {
                $0 + ($1 - mean) * ($1 - mean)
            } / Double(snr.count),
            packetCount: snr.count
        )
    }

    func getPowerStats(nodeId: UInt32, days: Int) -> PowerStats {
        let battery = getTimeSeries(nodeIds: [nodeId], metric: .battery, days: days)
        let voltage = getTimeSeries(nodeIds: [nodeId], metric: .voltage, days: days)
        let uptime = getTimeSeries(nodeIds: [nodeId], metric: .uptimeSeconds, days: days)
        let dayBattery = battery.filter(\.isDay).map(\.value)
        let nightBattery = battery.filter { !$0.isDay }.map(\.value)
        let dayVoltage = voltage.filter(\.isDay).map(\.value)
        let nightVoltage = voltage.filter { !$0.isDay }.map(\.value)
        let dayBatteryAverage = Self.average(dayBattery)
        let nightBatteryAverage = Self.average(nightBattery)

        return PowerStats(
            dayBatteryAvg: dayBatteryAverage,
            nightBatteryAvg: nightBatteryAverage,
            dayVoltageAvg: Self.average(dayVoltage),
            nightVoltageAvg: Self.average(nightVoltage),
            nightBatteryDrop: dayBatteryAverage - nightBatteryAverage,
            voltageMin: voltage.map(\.value).min() ?? 0,
            voltageMax: voltage.map(\.value).max() ?? 0,
            lastUptime: Int(uptime.last?.value ?? 0)
        )
    }

    func getAirtimeStats(nodeId: UInt32, days: Int) -> AirtimeStats {
        let channel = getTimeSeries(nodeIds: [nodeId], metric: .channelUtilization, days: days)
        let air = getTimeSeries(nodeIds: [nodeId], metric: .airUtilTx, days: days)
        return AirtimeStats(
            dayChannelUtilAvg: Self.average(channel.filter(\.isDay).map(\.value)),
            nightChannelUtilAvg: Self.average(channel.filter { !$0.isDay }.map(\.value)),
            dayAirTxUtilAvg: Self.average(air.filter(\.isDay).map(\.value)),
            nightAirTxUtilAvg: Self.average(air.filter { !$0.isDay }.map(\.value)),
            channelUtilMax: channel.map(\.value).max() ?? 0,
            airTxUtilMax: air.map(\.value).max() ?? 0
        )
    }

    func getRoutingStats(nodeId: UInt32, days: Int) -> RoutingStats {
        var result = RoutingStats()
        let cutoff = cutoffTimestamp(days: days)
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            var statement: OpaquePointer?
            let sql = """
                SELECT hop_count, want_ack, ack_received
                FROM packet_rx
                WHERE node_id = ? AND timestamp >= ?
                """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(nodeId))
            sqlite3_bind_double(statement, 2, cutoff)
            var hops: [Int] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if sqlite3_column_type(statement, 0) != SQLITE_NULL {
                    hops.append(Int(sqlite3_column_int64(statement, 0)))
                }
                if sqlite3_column_int(statement, 1) == 1 { result.ackRequested += 1 }
                if sqlite3_column_int(statement, 2) == 1 { result.ackReceived += 1 }
            }
            result.avgHops = hops.isEmpty ? 0 : Double(hops.reduce(0, +)) / Double(hops.count)
            result.minHops = hops.min() ?? 0
            result.maxHops = hops.max() ?? 0
            result.ackSuccessRate = result.ackRequested > 0
                ? Double(result.ackReceived) / Double(result.ackRequested)
                : 0
            result.uniqueNeighbors = hops.isEmpty ? 0 : 1
            for hop in hops { result.hopDistribution[hop, default: 0] += 1 }
        }
        return result
    }

    func getTimeSeries(nodeId: UInt32, metric: TelemetryMetric, days: Int) -> [TimeSeriesPoint] {
        getTimeSeries(nodeIds: [nodeId], metric: metric.seriesMetric, days: days).map {
            TimeSeriesPoint(timestamp: $0.timestamp, value: $0.value, isDay: $0.isDay)
        }
    }

    // MARK: - Dashboard Queries

    func getTimeSeries(
        nodeIds: [UInt32],
        metric: TelemetrySeriesMetric,
        days: Int
    ) -> [TelemetrySeriesPoint] {
        let uniqueNodeIds = Array(Set(nodeIds)).sorted()
        guard !uniqueNodeIds.isEmpty else { return [] }
        let cutoff = cutoffTimestamp(days: days)
        return queue.sync { [weak self] in
            guard let self, let db = self.db else { return [] }
            let placeholders = Array(repeating: "?", count: uniqueNodeIds.count).joined(separator: ",")
            let isPacketCount = metric == .packetCount
            let sql: String
            if isPacketCount {
                sql = """
                    SELECT node_id, CAST(timestamp / 3600 AS INTEGER) * 3600 AS hour,
                           SUM(value), MAX(is_day)
                    FROM telemetry_samples
                    WHERE metric = 'packet_count' AND node_id IN (\(placeholders))
                          AND timestamp >= ?
                    GROUP BY node_id, hour
                    ORDER BY hour, node_id
                    """
            } else {
                sql = """
                    SELECT node_id, timestamp, value, is_day
                    FROM telemetry_samples
                    WHERE metric = ? AND node_id IN (\(placeholders)) AND timestamp >= ?
                    ORDER BY timestamp, node_id
                    """
            }

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                self.logPrepareError(sql: sql, on: db)
                return []
            }
            defer { sqlite3_finalize(statement) }
            var bindIndex: Int32 = 1
            if !isPacketCount {
                sqlite3_bind_text(statement, bindIndex, metric.rawValue, -1, Self.transientDestructor)
                bindIndex += 1
            }
            for nodeId in uniqueNodeIds {
                sqlite3_bind_int64(statement, bindIndex, Int64(nodeId))
                bindIndex += 1
            }
            sqlite3_bind_double(statement, bindIndex, cutoff)

            var result: [TelemetrySeriesPoint] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard sqlite3_column_type(statement, 2) != SQLITE_NULL else { continue }
                result.append(TelemetrySeriesPoint(
                    nodeId: UInt32(truncatingIfNeeded: sqlite3_column_int64(statement, 0)),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    value: sqlite3_column_double(statement, 2),
                    isDay: sqlite3_column_int(statement, 3) == 1
                ))
            }
            return result
        }
    }

    func getLatestValues(
        nodeIds: [UInt32],
        metric: TelemetrySeriesMetric,
        days: Int
    ) -> [UInt32: TelemetrySeriesPoint] {
        Dictionary(
            grouping: getTimeSeries(nodeIds: nodeIds, metric: metric, days: days),
            by: \.nodeId
        ).compactMapValues { $0.max(by: { $0.timestamp < $1.timestamp }) }
    }

    func getHeatmapData(
        nodeId: UInt32,
        metric: TelemetrySeriesMetric,
        days: Int
    ) -> [TelemetryHeatmapCell] {
        let effectiveDays = days > 0 ? days : 14
        let points = getTimeSeries(nodeIds: [nodeId], metric: metric, days: effectiveDays)
        guard !points.isEmpty else { return [] }
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(
            for: clock().addingTimeInterval(-Double(max(0, effectiveDays - 1)) * 86_400)
        )
        let grouped = Dictionary(grouping: points) { point -> String in
            let day = calendar.dateComponents([.day], from: start, to: point.timestamp).day ?? 0
            let hour = calendar.component(.hour, from: point.timestamp)
            return "\(day)-\(hour)"
        }
        return grouped.compactMap { key, values in
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            return TelemetryHeatmapCell(
                dayIndex: parts[0],
                hour: parts[1],
                value: Self.average(values.map(\.value))
            )
        }.sorted { ($0.dayIndex, $0.hour) < ($1.dayIndex, $1.hour) }
    }

    func getNodeActivityGrid(nodeId: UInt32, days: Int) -> [TelemetryHeatmapCell] {
        let effectiveDays = days > 0 ? days : 14
        let active = getHeatmapData(nodeId: nodeId, metric: .packetCount, days: effectiveDays)
        let activeKeys = Set(active.map { "\($0.dayIndex)-\($0.hour)" })
        return (0..<effectiveDays).flatMap { day in
            (0..<24).map { hour in
                TelemetryHeatmapCell(
                    dayIndex: day,
                    hour: hour,
                    value: activeKeys.contains("\(day)-\(hour)") ? 1 : 0
                )
            }
        }
    }

    func getCandlestickData(
        nodeId: UInt32,
        metric: TelemetrySeriesMetric,
        days: Int
    ) -> [TelemetryCandlePoint] {
        let calendar = Calendar(identifier: .gregorian)
        let points = getTimeSeries(nodeIds: [nodeId], metric: metric, days: days)
        return Dictionary(grouping: points) { calendar.startOfDay(for: $0.timestamp) }
            .map { date, dayPoints in
                let sorted = dayPoints.sorted { $0.timestamp < $1.timestamp }
                let values = sorted.map(\.value)
                return TelemetryCandlePoint(
                    date: date,
                    open: values.first ?? 0,
                    high: values.max() ?? 0,
                    low: values.min() ?? 0,
                    close: values.last ?? 0
                )
            }
            .sorted { $0.date < $1.date }
    }

    func getHistogram(
        nodeId: UInt32,
        metric: TelemetrySeriesMetric,
        days: Int,
        binCount requestedBinCount: Int = 12
    ) -> [TelemetryHistogramBin] {
        let values = getTimeSeries(nodeIds: [nodeId], metric: metric, days: days).map(\.value)
        guard let minimum = values.min(), let maximum = values.max() else { return [] }
        let binCount = max(1, min(50, requestedBinCount))
        if minimum == maximum {
            return [TelemetryHistogramBin(lowerBound: minimum, upperBound: maximum, count: values.count)]
        }
        let width = (maximum - minimum) / Double(binCount)
        var counts = Array(repeating: 0, count: binCount)
        for value in values {
            let rawIndex = Int((value - minimum) / width)
            counts[min(binCount - 1, max(0, rawIndex))] += 1
        }
        return counts.enumerated().map { index, count in
            let lower = minimum + Double(index) * width
            return TelemetryHistogramBin(lowerBound: lower, upperBound: lower + width, count: count)
        }
    }

    func getMeshHealthSummary(nodeIds: [UInt32], days: Int) -> TelemetryMeshHealthSummary {
        let ids = nodeIds.isEmpty ? getKnownNodeIds() : nodeIds
        guard !ids.isEmpty else {
            return TelemetryMeshHealthSummary(
                score: 0,
                state: .noData,
                averagePathCost: 0,
                receptionScore: 0,
                channelUtilization: 0,
                packetCount: 0
            )
        }
        let signal = getTimeSeries(nodeIds: ids, metric: .snr, days: days)
        let packets = getTimeSeries(nodeIds: ids, metric: .packetCount, days: days)
        let utilization = getTimeSeries(nodeIds: ids, metric: .channelUtilization, days: days)
        let routing = ids.map { getRoutingStats(nodeId: $0, days: days) }
        let packetCount = Int(packets.reduce(0) { $0 + $1.value })
        let averageSnr = Self.average(signal.map(\.value))
        let channelAverage = Self.average(utilization.map(\.value))
        let averageHops = Self.average(routing.filter { !$0.hopDistribution.isEmpty }.map(\.avgHops))
        let hasData = !signal.isEmpty || packetCount > 0 || !utilization.isEmpty
        guard hasData else {
            return TelemetryMeshHealthSummary(
                score: 0,
                state: .noData,
                averagePathCost: averageHops,
                receptionScore: 0,
                channelUtilization: channelAverage,
                packetCount: 0
            )
        }

        let snrScore = min(1, max(0, (averageSnr + 20) / 30))
        let expectedPackets = Double(max(1, ids.count * max(1, days) * 2))
        let receptionScore = min(1, Double(packetCount) / expectedPackets)
        let channelScore = 1 - min(1, max(0, channelAverage / 100))
        let pathScore = 1 - min(1, max(0, averageHops / 7))
        let score = (snrScore * 0.35 + receptionScore * 0.30
            + channelScore * 0.20 + pathScore * 0.15) * 100
        let state: TelemetryHealthState = if score >= 75 {
            .good
        } else if score >= 50 {
            .warning
        } else {
            .alert
        }
        return TelemetryMeshHealthSummary(
            score: score,
            state: state,
            averagePathCost: averageHops,
            receptionScore: receptionScore,
            channelUtilization: channelAverage,
            packetCount: packetCount
        )
    }

    func getKnownNodeIds() -> [UInt32] {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return [] }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT DISTINCT node_id FROM telemetry_samples ORDER BY node_id",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var result: [UInt32] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(UInt32(truncatingIfNeeded: sqlite3_column_int64(statement, 0)))
            }
            return result
        }
    }

    static func rollingAverage(
        _ points: [TelemetrySeriesPoint],
        window: TimeInterval
    ) -> [TelemetrySeriesPoint] {
        guard window > 0 else { return points }
        return Dictionary(grouping: points, by: \.nodeId).values.flatMap { nodePoints in
            let sorted = nodePoints.sorted { $0.timestamp < $1.timestamp }
            var start = 0
            var sum = 0.0
            return sorted.enumerated().map { index, point in
                sum += point.value
                while start < index,
                      point.timestamp.timeIntervalSince(sorted[start].timestamp) > window {
                    sum -= sorted[start].value
                    start += 1
                }
                return TelemetrySeriesPoint(
                    nodeId: point.nodeId,
                    timestamp: point.timestamp,
                    value: sum / Double(index - start + 1),
                    isDay: point.isDay
                )
            }
        }.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Retention and Diagnostics

    func runRetentionCleanup(retentionDays: Int, now: Date = Date()) {
        guard retentionDays > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400).timeIntervalSince1970
        enqueueWrite { service, db in
            service.inTransaction(on: db) {
                var succeeded = true
                for table in Self.timestampTables {
                    let deleted = service.run(
                        "DELETE FROM \(table) WHERE timestamp < ?",
                        bindings: [.double(cutoff)],
                        on: db
                    )
                    succeeded = deleted && succeeded
                }
                return succeeded
            }
        }
    }

    /// Blocks until all queued writes have completed. Intended for orderly shutdown and tests.
    func waitForPendingWrites() {
        queue.sync {}
    }

    func schemaTableNames() -> Set<String> {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return [] }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT name FROM sqlite_master WHERE type = 'table'",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var names = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0) {
                names.insert(String(cString: text))
            }
            return names
        }
    }

    func rowCount(in table: String) -> Int {
        guard Self.timestampTables.contains(table) else { return 0 }
        return queue.sync { [weak self] in
            guard let self, let db = self.db else { return 0 }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil)
                    == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    // MARK: - SQLite Helpers

    private func enqueueWrite(
        _ operation: @escaping @Sendable (TelemetryDatabaseService, OpaquePointer) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            operation(self, db)
        }
    }

    @discardableResult
    private func inTransaction(on db: OpaquePointer, operation: () -> Bool) -> Bool {
        guard execute("BEGIN IMMEDIATE", on: db) else { return false }
        let succeeded = operation()
        _ = execute(succeeded ? "COMMIT" : "ROLLBACK", on: db)
        return succeeded
    }

    private func insertSamples(
        nodeId: UInt32,
        timestamp: Double,
        variant: String,
        values: [TelemetrySeriesMetric: Double],
        isDay: Int,
        on db: OpaquePointer
    ) -> Bool {
        var succeeded = true
        for (metric, value) in values where value.isFinite {
            let inserted = run(
                """
                INSERT OR REPLACE INTO telemetry_samples
                    (node_id, timestamp, variant, metric, value, is_day)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .integer(Int64(nodeId)), .double(timestamp), .text(variant),
                    .text(metric.rawValue), .double(value), .integer(Int64(isDay)),
                ],
                on: db
            )
            succeeded = inserted && succeeded
        }

        // Packet count is a derived series but persisted as a unit sample for fast grouping.
        if variant == "packet" {
            let inserted = run(
                """
                INSERT OR REPLACE INTO telemetry_samples
                    (node_id, timestamp, variant, metric, value, is_day)
                VALUES (?, ?, 'packet', 'packet_count', 1, ?)
                """,
                bindings: [.integer(Int64(nodeId)), .double(timestamp), .integer(Int64(isDay))],
                on: db
            )
            succeeded = inserted && succeeded
        }
        return succeeded
    }

    @discardableResult
    private func run(
        _ sql: String,
        bindings: [SQLiteBinding],
        on db: OpaquePointer
    ) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logPrepareError(sql: sql, on: db)
            return false
        }
        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .integer(let value): sqlite3_bind_int64(statement, index, value)
            case .double(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value):
                sqlite3_bind_text(statement, index, value, -1, Self.transientDestructor)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            AppLogger.shared.log("[TelemetryDB] SQL step failed: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        guard let db else { return false }
        return execute(sql, on: db)
    }

    @discardableResult
    private func execute(_ sql: String, on db: OpaquePointer) -> Bool {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            AppLogger.shared.log("[TelemetryDB] SQL error: \(message)")
            sqlite3_free(errorPointer)
            return false
        }
        return true
    }

    private func logPrepareError(sql: String, on db: OpaquePointer) {
        AppLogger.shared.log(
            "[TelemetryDB] SQL prepare failed (\(sql.prefix(80))): \(String(cString: sqlite3_errmsg(db)))"
        )
    }

    private func tableColumns(_ table: String, on db: OpaquePointer) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil)
                == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var columns: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 1) {
            columns.append(String(cString: text))
        }
        return columns
    }

    private func cutoffTimestamp(days: Int) -> Double {
        guard days > 0 else { return 0 }
        return clock().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
    }

    private func dayFlag(_ date: Date, latitude: Double, longitude: Double) -> Int {
        SunriseSunsetService.isDay(
            date: date,
            latitude: latitude,
            longitude: longitude
        ) ? 1 : 0
    }

    private func environmentValues(
        _ sample: EnvironmentTelemetrySample
    ) -> [TelemetrySeriesMetric: Double] {
        let values: [TelemetrySeriesMetric: Double?] = [
            .temperature: sample.temperature,
            .relativeHumidity: sample.relativeHumidity,
            .barometricPressure: sample.barometricPressure,
            .gasResistance: sample.gasResistance,
            .environmentVoltage: sample.voltage,
            .environmentCurrent: sample.current,
            .iaq: sample.iaq,
            .distance: sample.distance,
            .lux: sample.lux,
            .whiteLux: sample.whiteLux,
            .irLux: sample.irLux,
            .uvLux: sample.uvLux,
            .windDirection: sample.windDirection,
            .windSpeed: sample.windSpeed,
            .weight: sample.weight,
            .windGust: sample.windGust,
            .windLull: sample.windLull,
            .radiation: sample.radiation,
            .rainfall1Hour: sample.rainfall1Hour,
            .rainfall24Hours: sample.rainfall24Hours,
            .soilMoisture: sample.soilMoisture,
            .soilTemperature: sample.soilTemperature,
        ]
        return values.compactMapValues { $0 }
    }

    private func encodePayload(
        values: [TelemetrySeriesMetric: Double],
        text: [String: String]
    ) -> String {
        let payload = StoredPayload(
            values: Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }),
            text: text
        )
        guard let data = try? JSONEncoder().encode(payload),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static func powerMetric(channel: Int, voltage: Bool) -> TelemetrySeriesMetric? {
        switch (channel, voltage) {
        case (1, true): return .powerChannel1Voltage
        case (1, false): return .powerChannel1Current
        case (2, true): return .powerChannel2Voltage
        case (2, false): return .powerChannel2Current
        case (3, true): return .powerChannel3Voltage
        case (3, false): return .powerChannel3Current
        case (4, true): return .powerChannel4Voltage
        case (4, false): return .powerChannel4Current
        case (5, true): return .powerChannel5Voltage
        case (5, false): return .powerChannel5Current
        case (6, true): return .powerChannel6Voltage
        case (6, false): return .powerChannel6Current
        case (7, true): return .powerChannel7Voltage
        case (7, false): return .powerChannel7Current
        case (8, true): return .powerChannel8Voltage
        case (8, false): return .powerChannel8Current
        default: return nil
        }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static let transientDestructor = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )
}

private extension TelemetryMetric {
    var seriesMetric: TelemetrySeriesMetric {
        switch self {
        case .snr: return .snr
        case .rssi: return .rssi
        case .battery: return .battery
        case .voltage: return .voltage
        case .temperature: return .temperature
        case .humidity: return .relativeHumidity
        case .channelUtil: return .channelUtilization
        case .airTxUtil: return .airUtilTx
        }
    }
}
