import Foundation

/// Aggregated signal statistics for a node over a time period.
struct SignalStats {
    var daySnrMedian: Double = 0
    var nightSnrMedian: Double = 0
    var dayRssiMedian: Double = 0
    var nightRssiMedian: Double = 0
    var snrMin: Double = 0
    var snrMax: Double = 0
    var rssiMin: Double = 0
    var rssiMax: Double = 0
    var snrVariance: Double = 0
    var packetCount: Int = 0
}

/// Aggregated power statistics for a node.
struct PowerStats {
    var dayBatteryAvg: Double = 0
    var nightBatteryAvg: Double = 0
    var dayVoltageAvg: Double = 0
    var nightVoltageAvg: Double = 0
    var nightBatteryDrop: Double = 0
    var voltageMin: Double = 0
    var voltageMax: Double = 0
    var lastUptime: Int = 0
}

/// Aggregated airtime/channel utilization statistics.
struct AirtimeStats {
    var dayChannelUtilAvg: Double = 0
    var nightChannelUtilAvg: Double = 0
    var dayAirTxUtilAvg: Double = 0
    var nightAirTxUtilAvg: Double = 0
    var channelUtilMax: Double = 0
    var airTxUtilMax: Double = 0
}

/// Aggregated routing statistics.
struct RoutingStats {
    var avgHops: Double = 0
    var minHops: Int = 0
    var maxHops: Int = 0
    var ackSuccessRate: Double = 0
    var ackRequested: Int = 0
    var ackReceived: Int = 0
    var hopDistribution: [Int: Int] = [:]  // hop_count → occurrences
    var uniqueNeighbors: Int = 0
}

/// A single data point for time-series charts.
struct TimeSeriesPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let value: Double
    let isDay: Bool
}

/// Available telemetry metrics for charting.
enum TelemetryMetric: String, CaseIterable, Identifiable {
    case snr = "SNR (dB)"
    case rssi = "RSSI (dBm)"
    case battery = "Battery (%)"
    case voltage = "Voltage (V)"
    case temperature = "Temperature (°C)"
    case humidity = "Humidity (%)"
    case channelUtil = "Channel Util (%)"
    case airTxUtil = "Air TX Util (%)"

    var id: String { rawValue }
}
