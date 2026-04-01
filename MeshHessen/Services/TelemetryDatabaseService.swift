import Foundation
import SQLite3

/// Persistent SQLite telemetry database for packet and device metrics.
/// All write operations run on a serial background queue for thread safety.
final class TelemetryDatabaseService: @unchecked Sendable {
    static let shared = TelemetryDatabaseService()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "MeshHessen.telemetryDB", qos: .utility)

    private init() {
        openDatabase()
        createTables()
        cleanupOldEntries()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Database Setup

    private func openDatabase() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MeshHessen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("telemetry.db").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            AppLogger.shared.log("[TelemetryDB] Failed to open database: \(String(cString: sqlite3_errmsg(db!)))")
            return
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        AppLogger.shared.log("[TelemetryDB] Database opened at \(dbPath)", debug: true)
    }

    private func createTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS packet_rx (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL,
                packet_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                rx_snr REAL,
                rx_rssi INTEGER,
                hop_count INTEGER,
                want_ack INTEGER DEFAULT 0,
                ack_received INTEGER DEFAULT 0,
                is_day INTEGER DEFAULT 1
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_pkt_node_time ON packet_rx (node_id, timestamp)")
        exec("CREATE INDEX IF NOT EXISTS idx_pkt_id ON packet_rx (packet_id)")

        exec("""
            CREATE TABLE IF NOT EXISTS device_telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                battery_percent INTEGER,
                voltage REAL,
                channel_utilization REAL,
                air_util_tx REAL,
                uptime_seconds INTEGER,
                is_day INTEGER DEFAULT 1
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_devtel_node_time ON device_telemetry (node_id, timestamp)")

        exec("""
            CREATE TABLE IF NOT EXISTS environment_telemetry (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                temperature REAL,
                relative_humidity REAL,
                barometric_pressure REAL,
                iaq INTEGER,
                is_day INTEGER DEFAULT 1
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_envtel_node_time ON environment_telemetry (node_id, timestamp)")

        exec("""
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
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_trace_src_ts ON traceroute_hops (source_node_id, timestamp)")
    }

    // MARK: - Insert Methods

    func insertPacketRx(
        nodeId: UInt32, packetId: UInt32,
        snr: Float, rssi: Int32, hopCount: Int,
        wantAck: Bool,
        latitude: Double = 0, longitude: Double = 0
    ) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let ts = Date().timeIntervalSince1970
            let isDay = SunriseSunsetService.isDay(date: Date(), latitude: latitude, longitude: longitude) ? 1 : 0

            var stmt: OpaquePointer?
            let sql = "INSERT INTO packet_rx (node_id, packet_id, timestamp, rx_snr, rx_rssi, hop_count, want_ack, is_day) VALUES (?,?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, Int64(nodeId))
            sqlite3_bind_int64(stmt, 2, Int64(packetId))
            sqlite3_bind_double(stmt, 3, ts)
            sqlite3_bind_double(stmt, 4, Double(snr))
            sqlite3_bind_int(stmt, 5, Int32(rssi))
            sqlite3_bind_int(stmt, 6, Int32(hopCount))
            sqlite3_bind_int(stmt, 7, wantAck ? 1 : 0)
            sqlite3_bind_int(stmt, 8, Int32(isDay))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func markAckReceived(packetId: UInt32) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            self.exec("UPDATE packet_rx SET ack_received = 1 WHERE packet_id = \(packetId)", on: db)
        }
    }

    func insertDeviceTelemetry(
        nodeId: UInt32,
        batteryPercent: UInt32, voltage: Float,
        channelUtilization: Float, airUtilTx: Float,
        uptimeSeconds: UInt32,
        latitude: Double = 0, longitude: Double = 0
    ) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let ts = Date().timeIntervalSince1970
            let isDay = SunriseSunsetService.isDay(date: Date(), latitude: latitude, longitude: longitude) ? 1 : 0

            var stmt: OpaquePointer?
            let sql = "INSERT INTO device_telemetry (node_id, timestamp, battery_percent, voltage, channel_utilization, air_util_tx, uptime_seconds, is_day) VALUES (?,?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, Int64(nodeId))
            sqlite3_bind_double(stmt, 2, ts)
            sqlite3_bind_int(stmt, 3, Int32(batteryPercent))
            sqlite3_bind_double(stmt, 4, Double(voltage))
            sqlite3_bind_double(stmt, 5, Double(channelUtilization))
            sqlite3_bind_double(stmt, 6, Double(airUtilTx))
            sqlite3_bind_int64(stmt, 7, Int64(uptimeSeconds))
            sqlite3_bind_int(stmt, 8, Int32(isDay))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func insertEnvironmentTelemetry(
        nodeId: UInt32,
        temperature: Float, relativeHumidity: Float,
        barometricPressure: Float, iaq: UInt32,
        latitude: Double = 0, longitude: Double = 0
    ) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let ts = Date().timeIntervalSince1970
            let isDay = SunriseSunsetService.isDay(date: Date(), latitude: latitude, longitude: longitude) ? 1 : 0

            var stmt: OpaquePointer?
            let sql = "INSERT INTO environment_telemetry (node_id, timestamp, temperature, relative_humidity, barometric_pressure, iaq, is_day) VALUES (?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, Int64(nodeId))
            sqlite3_bind_double(stmt, 2, ts)
            sqlite3_bind_double(stmt, 3, Double(temperature))
            sqlite3_bind_double(stmt, 4, Double(relativeHumidity))
            sqlite3_bind_double(stmt, 5, Double(barometricPressure))
            sqlite3_bind_int(stmt, 6, Int32(iaq))
            sqlite3_bind_int(stmt, 7, Int32(isDay))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func insertTracerouteHops(
        requestId: UInt32, sourceNodeId: UInt32, destNodeId: UInt32,
        hops: [(nodeId: UInt32, snrTowards: Float?, snrBack: Float?)]
    ) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let ts = Date().timeIntervalSince1970

            for (index, hop) in hops.enumerated() {
                var stmt: OpaquePointer?
                let sql = "INSERT INTO traceroute_hops (request_id, source_node_id, dest_node_id, timestamp, hop_index, node_id, snr_towards, snr_back) VALUES (?,?,?,?,?,?,?,?)"
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
                sqlite3_bind_int64(stmt, 1, Int64(requestId))
                sqlite3_bind_int64(stmt, 2, Int64(sourceNodeId))
                sqlite3_bind_int64(stmt, 3, Int64(destNodeId))
                sqlite3_bind_double(stmt, 4, ts)
                sqlite3_bind_int(stmt, 5, Int32(index))
                sqlite3_bind_int64(stmt, 6, Int64(hop.nodeId))
                if let snr = hop.snrTowards { sqlite3_bind_double(stmt, 7, Double(snr)) }
                else { sqlite3_bind_null(stmt, 7) }
                if let snr = hop.snrBack { sqlite3_bind_double(stmt, 8, Double(snr)) }
                else { sqlite3_bind_null(stmt, 8) }
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    // MARK: - Query Methods

    func getSignalStats(nodeId: UInt32, days: Int) -> SignalStats {
        var stats = SignalStats()
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970

        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }

            // Day stats
            var daySnrs: [Double] = []
            var dayRssis: [Double] = []
            var nightSnrs: [Double] = []
            var nightRssis: [Double] = []
            var allSnrs: [Double] = []

            var stmt: OpaquePointer?
            let sql = "SELECT rx_snr, rx_rssi, is_day FROM packet_rx WHERE node_id = ? AND timestamp > ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, Int64(nodeId))
            sqlite3_bind_double(stmt, 2, cutoff)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let snr = sqlite3_column_double(stmt, 0)
                let rssi = sqlite3_column_double(stmt, 1)
                let isDay = sqlite3_column_int(stmt, 2) == 1
                allSnrs.append(snr)
                if isDay {
                    daySnrs.append(snr)
                    dayRssis.append(rssi)
                } else {
                    nightSnrs.append(snr)
                    nightRssis.append(rssi)
                }
            }
            sqlite3_finalize(stmt)

            stats.packetCount = allSnrs.count
            stats.daySnrMedian = median(daySnrs)
            stats.nightSnrMedian = median(nightSnrs)
            stats.dayRssiMedian = median(dayRssis)
            stats.nightRssiMedian = median(nightRssis)
            stats.snrMin = allSnrs.min() ?? 0
            stats.snrMax = allSnrs.max() ?? 0
            stats.rssiMin = (dayRssis + nightRssis).min() ?? 0
            stats.rssiMax = (dayRssis + nightRssis).max() ?? 0
            if !allSnrs.isEmpty {
                let mean = allSnrs.reduce(0, +) / Double(allSnrs.count)
                stats.snrVariance = allSnrs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(allSnrs.count)
            }
        }
        return stats
    }

    func getPowerStats(nodeId: UInt32, days: Int) -> PowerStats {
        var stats = PowerStats()
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970

        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }

            var dayBats: [Double] = []
            var nightBats: [Double] = []
            var dayVolts: [Double] = []
            var nightVolts: [Double] = []
            var allVolts: [Double] = []
            var lastUptime: Int = 0

            var stmt: OpaquePointer?
            let sql = "SELECT battery_percent, voltage, uptime_seconds, is_day FROM device_telemetry WHERE node_id = ? AND timestamp > ? ORDER BY timestamp"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, Int64(nodeId))
            sqlite3_bind_double(stmt, 2, cutoff)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let bat = sqlite3_column_double(stmt, 0)
                let volt = sqlite3_column_double(stmt, 1)
                let uptime = Int(sqlite3_column_int64(stmt, 2))
                let isDay = sqlite3_column_int(stmt, 3) == 1
                allVolts.append(volt)
                lastUptime = uptime
                if isDay {
                    dayBats.append(bat)
                    dayVolts.append(volt)
                } else {
                    nightBats.append(bat)
                    nightVolts.append(volt)
                }
            }
            sqlite3_finalize(stmt)

            stats.dayBatteryAvg = dayBats.isEmpty ? 0 : dayBats.reduce(0, +) / Double(dayBats.count)
            stats.nightBatteryAvg = nightBats.isEmpty ? 0 : nightBats.reduce(0, +) / Double(nightBats.count)
            stats.dayVoltageAvg = dayVolts.isEmpty ? 0 : dayVolts.reduce(0, +) / Double(dayVolts.count)
            stats.nightVoltageAvg = nightVolts.isEmpty ? 0 : nightVolts.reduce(0, +) / Double(nightVolts.count)
            stats.nightBatteryDrop = stats.dayBatteryAvg - stats.nightBatteryAvg
            stats.voltageMin = allVolts.min() ?? 0
            stats.voltageMax = allVolts.max() ?? 0
            stats.lastUptime = lastUptime
        }
        return stats
    }

    func getAirtimeStats(nodeId: UInt32, days: Int) -> AirtimeStats {
        var stats = AirtimeStats()
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970

        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }

            var dayCh: [Double] = []
            var nightCh: [Double] = []
            var dayAir: [Double] = []
            var nightAir: [Double] = []

            var stmt: OpaquePointer?
            let sql = "SELECT channel_utilization, air_util_tx, is_day FROM device_telemetry WHERE node_id = ? AND timestamp > ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, Int64(nodeId))
            sqlite3_bind_double(stmt, 2, cutoff)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let ch = sqlite3_column_double(stmt, 0)
                let air = sqlite3_column_double(stmt, 1)
                let isDay = sqlite3_column_int(stmt, 2) == 1
                if isDay {
                    dayCh.append(ch); dayAir.append(air)
                } else {
                    nightCh.append(ch); nightAir.append(air)
                }
            }
            sqlite3_finalize(stmt)

            let allCh = dayCh + nightCh
            let allAir = dayAir + nightAir
            stats.dayChannelUtilAvg = dayCh.isEmpty ? 0 : dayCh.reduce(0, +) / Double(dayCh.count)
            stats.nightChannelUtilAvg = nightCh.isEmpty ? 0 : nightCh.reduce(0, +) / Double(nightCh.count)
            stats.dayAirTxUtilAvg = dayAir.isEmpty ? 0 : dayAir.reduce(0, +) / Double(dayAir.count)
            stats.nightAirTxUtilAvg = nightAir.isEmpty ? 0 : nightAir.reduce(0, +) / Double(nightAir.count)
            stats.channelUtilMax = allCh.max() ?? 0
            stats.airTxUtilMax = allAir.max() ?? 0
        }
        return stats
    }

    func getRoutingStats(nodeId: UInt32, days: Int) -> RoutingStats {
        var stats = RoutingStats()
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970

        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }

            var hops: [Int] = []
            var ackRequested = 0
            var ackReceived = 0
            var senders = Set<Int64>()

            var stmt: OpaquePointer?
            let sql = "SELECT hop_count, want_ack, ack_received, node_id FROM packet_rx WHERE node_id = ? AND timestamp > ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, Int64(nodeId))
            sqlite3_bind_double(stmt, 2, cutoff)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let hop = Int(sqlite3_column_int(stmt, 0))
                let wAck = sqlite3_column_int(stmt, 1)
                let gotAck = sqlite3_column_int(stmt, 2)
                let sender = sqlite3_column_int64(stmt, 3)
                hops.append(hop)
                senders.insert(sender)
                if wAck == 1 { ackRequested += 1 }
                if gotAck == 1 { ackReceived += 1 }
            }
            sqlite3_finalize(stmt)

            stats.avgHops = hops.isEmpty ? 0 : Double(hops.reduce(0, +)) / Double(hops.count)
            stats.minHops = hops.min() ?? 0
            stats.maxHops = hops.max() ?? 0
            stats.ackRequested = ackRequested
            stats.ackReceived = ackReceived
            stats.ackSuccessRate = ackRequested > 0 ? Double(ackReceived) / Double(ackRequested) : 0
            stats.uniqueNeighbors = senders.count
            for hop in hops {
                stats.hopDistribution[hop, default: 0] += 1
            }
        }
        return stats
    }

    func getTimeSeries(nodeId: UInt32, metric: TelemetryMetric, days: Int) -> [TimeSeriesPoint] {
        var points: [TimeSeriesPoint] = []
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970

        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }

            let (table, column): (String, String)
            switch metric {
            case .snr: (table, column) = ("packet_rx", "rx_snr")
            case .rssi: (table, column) = ("packet_rx", "rx_rssi")
            case .battery: (table, column) = ("device_telemetry", "battery_percent")
            case .voltage: (table, column) = ("device_telemetry", "voltage")
            case .channelUtil: (table, column) = ("device_telemetry", "channel_utilization")
            case .airTxUtil: (table, column) = ("device_telemetry", "air_util_tx")
            case .temperature: (table, column) = ("environment_telemetry", "temperature")
            case .humidity: (table, column) = ("environment_telemetry", "relative_humidity")
            }

            var stmt: OpaquePointer?
            let sql = "SELECT timestamp, \(column), is_day FROM \(table) WHERE node_id = ? AND timestamp > ? ORDER BY timestamp"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, Int64(nodeId))
            sqlite3_bind_double(stmt, 2, cutoff)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = sqlite3_column_double(stmt, 0)
                let val = sqlite3_column_double(stmt, 1)
                let isDay = sqlite3_column_int(stmt, 2) == 1
                points.append(TimeSeriesPoint(
                    timestamp: Date(timeIntervalSince1970: ts),
                    value: val,
                    isDay: isDay
                ))
            }
            sqlite3_finalize(stmt)
        }
        return points
    }

    // MARK: - Retention Cleanup

    private func cleanupOldEntries() {
        let retentionDays = SettingsService.shared.telemetryRetentionDays
        guard retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400).timeIntervalSince1970

        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let tables = ["packet_rx", "device_telemetry", "environment_telemetry", "traceroute_hops"]
            for table in tables {
                self.exec("DELETE FROM \(table) WHERE timestamp < \(cutoff)", on: db)
            }
            AppLogger.shared.log("[TelemetryDB] Retention cleanup: removed entries older than \(retentionDays) days", debug: true)
        }
    }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        guard let db else { return }
        exec(sql, on: db)
    }

    private func exec(_ sql: String, on db: OpaquePointer) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            AppLogger.shared.log("[TelemetryDB] SQL error: \(msg)")
            sqlite3_free(err)
        }
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
