import Foundation

/// A persistable numeric telemetry metric. Raw values are stable storage keys and
/// intentionally mirror the Meshtastic field names where practical.
enum TelemetrySeriesMetric: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case snr
    case rssi
    case battery
    case voltage
    case channelUtilization = "channel_utilization"
    case airUtilTx = "air_util_tx"
    case uptimeSeconds = "uptime_seconds"
    case packetCount = "packet_count"

    case temperature
    case relativeHumidity = "relative_humidity"
    case barometricPressure = "barometric_pressure"
    case gasResistance = "gas_resistance"
    case environmentVoltage = "environment_voltage"
    case environmentCurrent = "environment_current"
    case iaq
    case distance
    case lux
    case whiteLux = "white_lux"
    case irLux = "ir_lux"
    case uvLux = "uv_lux"
    case windDirection = "wind_direction"
    case windSpeed = "wind_speed"
    case weight
    case windGust = "wind_gust"
    case windLull = "wind_lull"
    case radiation
    case rainfall1Hour = "rainfall_1h"
    case rainfall24Hours = "rainfall_24h"
    case soilMoisture = "soil_moisture"
    case soilTemperature = "soil_temperature"

    case pm10Standard = "pm10_standard"
    case pm25Standard = "pm25_standard"
    case pm100Standard = "pm100_standard"
    case pm40Standard = "pm40_standard"
    case pm10Environmental = "pm10_environmental"
    case pm25Environmental = "pm25_environmental"
    case pm100Environmental = "pm100_environmental"
    case particles03Um = "particles_03um"
    case particles05Um = "particles_05um"
    case particles10Um = "particles_10um"
    case particles25Um = "particles_25um"
    case particles40Um = "particles_40um"
    case particles50Um = "particles_50um"
    case particles100Um = "particles_100um"
    case particlesTypicalSize = "particles_tps"
    case co2
    case co2Temperature = "co2_temperature"
    case co2Humidity = "co2_humidity"
    case formaldehyde = "formaldehyde"
    case formaldehydeHumidity = "formaldehyde_humidity"
    case formaldehydeTemperature = "formaldehyde_temperature"
    case pmTemperature = "pm_temperature"
    case pmHumidity = "pm_humidity"
    case pmVocIndex = "pm_voc_index"
    case pmNoxIndex = "pm_nox_index"

    case powerChannel1Voltage = "power_ch1_voltage"
    case powerChannel1Current = "power_ch1_current"
    case powerChannel2Voltage = "power_ch2_voltage"
    case powerChannel2Current = "power_ch2_current"
    case powerChannel3Voltage = "power_ch3_voltage"
    case powerChannel3Current = "power_ch3_current"
    case powerChannel4Voltage = "power_ch4_voltage"
    case powerChannel4Current = "power_ch4_current"
    case powerChannel5Voltage = "power_ch5_voltage"
    case powerChannel5Current = "power_ch5_current"
    case powerChannel6Voltage = "power_ch6_voltage"
    case powerChannel6Current = "power_ch6_current"
    case powerChannel7Voltage = "power_ch7_voltage"
    case powerChannel7Current = "power_ch7_current"
    case powerChannel8Voltage = "power_ch8_voltage"
    case powerChannel8Current = "power_ch8_current"

    case localPacketsTx = "local_packets_tx"
    case localPacketsRx = "local_packets_rx"
    case localPacketsRxBad = "local_packets_rx_bad"
    case localOnlineNodes = "local_online_nodes"
    case localTotalNodes = "local_total_nodes"
    case localRxDuplicates = "local_rx_duplicates"
    case localTxRelays = "local_tx_relays"
    case localCanceledRelays = "local_canceled_relays"
    case localHeapTotalBytes = "local_heap_total_bytes"
    case localHeapFreeBytes = "local_heap_free_bytes"
    case localTxDropped = "local_tx_dropped"
    case localNoiseFloor = "local_noise_floor"

    case hostUptimeSeconds = "host_uptime_seconds"
    case hostFreeMemoryBytes = "host_free_memory_bytes"
    case hostDisk1FreeBytes = "host_disk1_free_bytes"
    case hostDisk2FreeBytes = "host_disk2_free_bytes"
    case hostDisk3FreeBytes = "host_disk3_free_bytes"
    case hostLoad1 = "host_load_1"
    case hostLoad5 = "host_load_5"
    case hostLoad15 = "host_load_15"

    case healthHeartRate = "health_heart_rate"
    case healthSpO2 = "health_spo2"
    case healthTemperature = "health_temperature"

    case trafficPacketsInspected = "traffic_packets_inspected"
    case trafficPositionDedupDrops = "traffic_position_dedup_drops"
    case trafficNodeInfoCacheHits = "traffic_nodeinfo_cache_hits"
    case trafficRateLimitDrops = "traffic_rate_limit_drops"
    case trafficUnknownPacketDrops = "traffic_unknown_packet_drops"
    case trafficHopExhaustedPackets = "traffic_hop_exhausted_packets"
    case trafficRouterHopsPreserved = "traffic_router_hops_preserved"

    case paxWifiCount = "pax_wifi_count"
    case paxBLECount = "pax_ble_count"
    case paxUptimeSeconds = "pax_uptime_seconds"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .snr: return String(localized: "SNR")
        case .rssi: return String(localized: "RSSI")
        case .battery: return String(localized: "Battery")
        case .voltage: return String(localized: "Voltage")
        case .channelUtilization: return String(localized: "Channel Utilization")
        case .airUtilTx: return String(localized: "TX Utilization")
        case .uptimeSeconds: return String(localized: "Uptime")
        case .packetCount: return String(localized: "Packets per Hour")
        case .temperature: return String(localized: "Temperature")
        case .relativeHumidity: return String(localized: "Relative Humidity")
        case .barometricPressure: return String(localized: "Barometric Pressure")
        case .gasResistance: return String(localized: "Gas Resistance")
        case .environmentVoltage: return String(localized: "Sensor Voltage")
        case .environmentCurrent: return String(localized: "Sensor Current")
        case .iaq: return String(localized: "Air Quality Index")
        case .distance: return String(localized: "Distance")
        case .lux: return String(localized: "Illuminance")
        case .whiteLux: return String(localized: "White Light")
        case .irLux: return String(localized: "Infrared Light")
        case .uvLux: return String(localized: "UV Light")
        case .windDirection: return String(localized: "Wind Direction")
        case .windSpeed: return String(localized: "Wind Speed")
        case .weight: return String(localized: "Weight")
        case .windGust: return String(localized: "Wind Gust")
        case .windLull: return String(localized: "Wind Lull")
        case .radiation: return String(localized: "Radiation")
        case .rainfall1Hour: return String(localized: "Rainfall (1 h)")
        case .rainfall24Hours: return String(localized: "Rainfall (24 h)")
        case .soilMoisture: return String(localized: "Soil Moisture")
        case .soilTemperature: return String(localized: "Soil Temperature")
        case .pm10Standard: return String(localized: "PM1.0 (Standard)")
        case .pm25Standard: return String(localized: "PM2.5 (Standard)")
        case .pm100Standard: return String(localized: "PM10 (Standard)")
        case .pm40Standard: return String(localized: "PM4.0 (Standard)")
        case .pm10Environmental: return String(localized: "PM1.0 (Environmental)")
        case .pm25Environmental: return String(localized: "PM2.5 (Environmental)")
        case .pm100Environmental: return String(localized: "PM10 (Environmental)")
        case .particles03Um: return String(localized: "Particles ≥ 0.3 µm")
        case .particles05Um: return String(localized: "Particles ≥ 0.5 µm")
        case .particles10Um: return String(localized: "Particles ≥ 1.0 µm")
        case .particles25Um: return String(localized: "Particles ≥ 2.5 µm")
        case .particles40Um: return String(localized: "Particles ≥ 4.0 µm")
        case .particles50Um: return String(localized: "Particles ≥ 5.0 µm")
        case .particles100Um: return String(localized: "Particles ≥ 10 µm")
        case .particlesTypicalSize: return String(localized: "Typical Particle Size")
        case .co2: return String(localized: "CO₂")
        case .co2Temperature: return String(localized: "CO₂ Sensor Temperature")
        case .co2Humidity: return String(localized: "CO₂ Sensor Humidity")
        case .formaldehyde: return String(localized: "Formaldehyde")
        case .formaldehydeHumidity: return String(localized: "Formaldehyde Sensor Humidity")
        case .formaldehydeTemperature: return String(localized: "Formaldehyde Sensor Temperature")
        case .pmTemperature: return String(localized: "PM Sensor Temperature")
        case .pmHumidity: return String(localized: "PM Sensor Humidity")
        case .pmVocIndex: return String(localized: "VOC Index")
        case .pmNoxIndex: return String(localized: "NOx Index")
        case .powerChannel1Voltage: return String(localized: "Power Channel 1 Voltage")
        case .powerChannel1Current: return String(localized: "Power Channel 1 Current")
        case .powerChannel2Voltage: return String(localized: "Power Channel 2 Voltage")
        case .powerChannel2Current: return String(localized: "Power Channel 2 Current")
        case .powerChannel3Voltage: return String(localized: "Power Channel 3 Voltage")
        case .powerChannel3Current: return String(localized: "Power Channel 3 Current")
        case .powerChannel4Voltage: return String(localized: "Power Channel 4 Voltage")
        case .powerChannel4Current: return String(localized: "Power Channel 4 Current")
        case .powerChannel5Voltage: return String(localized: "Power Channel 5 Voltage")
        case .powerChannel5Current: return String(localized: "Power Channel 5 Current")
        case .powerChannel6Voltage: return String(localized: "Power Channel 6 Voltage")
        case .powerChannel6Current: return String(localized: "Power Channel 6 Current")
        case .powerChannel7Voltage: return String(localized: "Power Channel 7 Voltage")
        case .powerChannel7Current: return String(localized: "Power Channel 7 Current")
        case .powerChannel8Voltage: return String(localized: "Power Channel 8 Voltage")
        case .powerChannel8Current: return String(localized: "Power Channel 8 Current")
        case .localPacketsTx: return String(localized: "Packets Sent")
        case .localPacketsRx: return String(localized: "Packets Received")
        case .localPacketsRxBad: return String(localized: "Bad Packets")
        case .localOnlineNodes: return String(localized: "Online Nodes")
        case .localTotalNodes: return String(localized: "Total Nodes")
        case .localRxDuplicates: return String(localized: "Duplicates")
        case .localTxRelays: return String(localized: "Relayed Packets")
        case .localCanceledRelays: return String(localized: "Canceled Relays")
        case .localHeapTotalBytes: return String(localized: "Total Heap")
        case .localHeapFreeBytes: return String(localized: "Free Heap")
        case .localTxDropped: return String(localized: "Dropped TX Packets")
        case .localNoiseFloor: return String(localized: "Noise Floor")
        case .hostUptimeSeconds: return String(localized: "Host Uptime")
        case .hostFreeMemoryBytes: return String(localized: "Free Host Memory")
        case .hostDisk1FreeBytes: return String(localized: "Free Host Disk 1")
        case .hostDisk2FreeBytes: return String(localized: "Free Host Disk 2")
        case .hostDisk3FreeBytes: return String(localized: "Free Host Disk 3")
        case .hostLoad1: return String(localized: "Host Load (1 min)")
        case .hostLoad5: return String(localized: "Host Load (5 min)")
        case .hostLoad15: return String(localized: "Host Load (15 min)")
        case .healthHeartRate: return String(localized: "Heart Rate")
        case .healthSpO2: return String(localized: "SpO₂")
        case .healthTemperature: return String(localized: "Body Temperature")
        case .trafficPacketsInspected: return String(localized: "Inspected Packets")
        case .trafficPositionDedupDrops: return String(localized: "Dropped Duplicate Positions")
        case .trafficNodeInfoCacheHits: return String(localized: "NodeInfo Cache Hits")
        case .trafficRateLimitDrops: return String(localized: "Rate-Limit Drops")
        case .trafficUnknownPacketDrops: return String(localized: "Dropped Unknown Packets")
        case .trafficHopExhaustedPackets: return String(localized: "Hop Limit Exhausted")
        case .trafficRouterHopsPreserved: return String(localized: "Preserved Router Hops")
        case .paxWifiCount: return String(localized: "PAX Wi-Fi")
        case .paxBLECount: return String(localized: "PAX Bluetooth")
        case .paxUptimeSeconds: return String(localized: "PAX Uptime")
        }
    }

    var unit: String {
        switch self {
        case .snr: return "dB"
        case .rssi, .localNoiseFloor: return "dBm"
        case .battery, .channelUtilization, .airUtilTx, .relativeHumidity,
             .soilMoisture, .co2Humidity, .formaldehydeHumidity, .pmHumidity,
             .healthSpO2: return "%"
        case .voltage, .environmentVoltage,
             .powerChannel1Voltage, .powerChannel2Voltage, .powerChannel3Voltage,
             .powerChannel4Voltage, .powerChannel5Voltage, .powerChannel6Voltage,
             .powerChannel7Voltage, .powerChannel8Voltage: return "V"
        case .environmentCurrent,
             .powerChannel1Current, .powerChannel2Current, .powerChannel3Current,
             .powerChannel4Current, .powerChannel5Current, .powerChannel6Current,
             .powerChannel7Current, .powerChannel8Current: return "A"
        case .temperature, .soilTemperature, .co2Temperature,
             .formaldehydeTemperature, .pmTemperature, .healthTemperature: return "°C"
        case .barometricPressure: return "hPa"
        case .gasResistance: return "MΩ"
        case .distance: return "mm"
        case .lux, .whiteLux, .irLux, .uvLux: return "lx"
        case .windDirection: return "°"
        case .windSpeed, .windGust, .windLull: return "m/s"
        case .weight: return "kg"
        case .radiation: return "µR/h"
        case .rainfall1Hour, .rainfall24Hours: return "mm"
        case .pm10Standard, .pm25Standard, .pm100Standard, .pm40Standard,
             .pm10Environmental, .pm25Environmental, .pm100Environmental: return "µg/m³"
        case .particles03Um, .particles05Um, .particles10Um, .particles25Um,
             .particles40Um, .particles50Um, .particles100Um: return String(localized: "#/0.1 L")
        case .particlesTypicalSize: return "µm"
        case .co2: return "ppm"
        case .formaldehyde: return "ppb"
        case .pmVocIndex, .pmNoxIndex, .iaq: return "Index"
        case .uptimeSeconds, .hostUptimeSeconds, .paxUptimeSeconds: return "s"
        case .hostFreeMemoryBytes, .hostDisk1FreeBytes, .hostDisk2FreeBytes,
             .hostDisk3FreeBytes, .localHeapTotalBytes, .localHeapFreeBytes: return "Byte"
        case .hostLoad1, .hostLoad5, .hostLoad15: return ""
        case .healthHeartRate: return "bpm"
        default: return ""
        }
    }

    var suggestedRange: ClosedRange<Double>? {
        switch self {
        case .snr: return -20...15
        case .rssi, .localNoiseFloor: return -130 ... -20
        case .battery, .channelUtilization, .airUtilTx, .relativeHumidity,
             .soilMoisture, .healthSpO2: return 0...100
        case .voltage: return 0...5
        case .temperature, .soilTemperature, .co2Temperature,
             .formaldehydeTemperature, .pmTemperature, .healthTemperature: return -40...80
        case .barometricPressure: return 850...1_100
        case .windDirection: return 0...360
        case .iaq: return 0...500
        case .co2: return 0...5_000
        case .healthHeartRate: return 30...220
        default: return nil
        }
    }

    static let windowsDashboardMetrics: [TelemetrySeriesMetric] = [
        .snr, .rssi, .battery, .voltage, .channelUtilization,
        .airUtilTx, .temperature, .relativeHumidity,
        .barometricPressure, .packetCount,
    ]
}

struct TelemetrySeriesPoint: Identifiable, Hashable, Sendable {
    let id: UUID
    let nodeId: UInt32
    let timestamp: Date
    let value: Double
    let isDay: Bool

    init(
        id: UUID = UUID(),
        nodeId: UInt32,
        timestamp: Date,
        value: Double,
        isDay: Bool
    ) {
        self.id = id
        self.nodeId = nodeId
        self.timestamp = timestamp
        self.value = value
        self.isDay = isDay
    }
}

struct EnvironmentTelemetrySample: Sendable {
    var temperature: Double?
    var relativeHumidity: Double?
    var barometricPressure: Double?
    var gasResistance: Double?
    var voltage: Double?
    var current: Double?
    var iaq: Double?
    var distance: Double?
    var lux: Double?
    var whiteLux: Double?
    var irLux: Double?
    var uvLux: Double?
    var windDirection: Double?
    var windSpeed: Double?
    var weight: Double?
    var windGust: Double?
    var windLull: Double?
    var radiation: Double?
    var rainfall1Hour: Double?
    var rainfall24Hours: Double?
    var soilMoisture: Double?
    var soilTemperature: Double?

    init(
        temperature: Double? = nil,
        relativeHumidity: Double? = nil,
        barometricPressure: Double? = nil,
        gasResistance: Double? = nil,
        voltage: Double? = nil,
        current: Double? = nil,
        iaq: Double? = nil,
        distance: Double? = nil,
        lux: Double? = nil,
        whiteLux: Double? = nil,
        irLux: Double? = nil,
        uvLux: Double? = nil,
        windDirection: Double? = nil,
        windSpeed: Double? = nil,
        weight: Double? = nil,
        windGust: Double? = nil,
        windLull: Double? = nil,
        radiation: Double? = nil,
        rainfall1Hour: Double? = nil,
        rainfall24Hours: Double? = nil,
        soilMoisture: Double? = nil,
        soilTemperature: Double? = nil
    ) {
        self.temperature = temperature
        self.relativeHumidity = relativeHumidity
        self.barometricPressure = barometricPressure
        self.gasResistance = gasResistance
        self.voltage = voltage
        self.current = current
        self.iaq = iaq
        self.distance = distance
        self.lux = lux
        self.whiteLux = whiteLux
        self.irLux = irLux
        self.uvLux = uvLux
        self.windDirection = windDirection
        self.windSpeed = windSpeed
        self.weight = weight
        self.windGust = windGust
        self.windLull = windLull
        self.radiation = radiation
        self.rainfall1Hour = rainfall1Hour
        self.rainfall24Hours = rainfall24Hours
        self.soilMoisture = soilMoisture
        self.soilTemperature = soilTemperature
    }
}

struct AirQualityTelemetrySample: Sendable {
    var values: [TelemetrySeriesMetric: Double]

    init(values: [TelemetrySeriesMetric: Double] = [:]) {
        let allowed = Set(TelemetrySeriesMetric.allCases.filter { $0.rawValue.hasPrefix("pm")
            || $0.rawValue.hasPrefix("particles")
            || $0.rawValue.hasPrefix("co2")
            || $0.rawValue.hasPrefix("formaldehyde")
        })
        self.values = values.filter { allowed.contains($0.key) }
    }
}

struct PowerChannelTelemetrySample: Hashable, Sendable {
    let channel: Int
    let voltage: Double?
    let current: Double?

    init(channel: Int, voltage: Double? = nil, current: Double? = nil) {
        self.channel = min(8, max(1, channel))
        self.voltage = voltage
        self.current = current
    }
}

struct LocalTelemetrySample: Sendable {
    var uptimeSeconds: Double?
    var channelUtilization: Double?
    var airUtilTx: Double?
    var packetsTx: Double?
    var packetsRx: Double?
    var packetsRxBad: Double?
    var onlineNodes: Double?
    var totalNodes: Double?
    var rxDuplicates: Double?
    var txRelays: Double?
    var canceledRelays: Double?
    var heapTotalBytes: Double?
    var heapFreeBytes: Double?
    var txDropped: Double?
    var noiseFloor: Double?

    init(
        uptimeSeconds: Double? = nil,
        channelUtilization: Double? = nil,
        airUtilTx: Double? = nil,
        packetsTx: Double? = nil,
        packetsRx: Double? = nil,
        packetsRxBad: Double? = nil,
        onlineNodes: Double? = nil,
        totalNodes: Double? = nil,
        rxDuplicates: Double? = nil,
        txRelays: Double? = nil,
        canceledRelays: Double? = nil,
        heapTotalBytes: Double? = nil,
        heapFreeBytes: Double? = nil,
        txDropped: Double? = nil,
        noiseFloor: Double? = nil
    ) {
        self.uptimeSeconds = uptimeSeconds
        self.channelUtilization = channelUtilization
        self.airUtilTx = airUtilTx
        self.packetsTx = packetsTx
        self.packetsRx = packetsRx
        self.packetsRxBad = packetsRxBad
        self.onlineNodes = onlineNodes
        self.totalNodes = totalNodes
        self.rxDuplicates = rxDuplicates
        self.txRelays = txRelays
        self.canceledRelays = canceledRelays
        self.heapTotalBytes = heapTotalBytes
        self.heapFreeBytes = heapFreeBytes
        self.txDropped = txDropped
        self.noiseFloor = noiseFloor
    }
}

struct HostTelemetrySample: Sendable {
    var uptimeSeconds: Double?
    var freeMemoryBytes: Double?
    var disk1FreeBytes: Double?
    var disk2FreeBytes: Double?
    var disk3FreeBytes: Double?
    var load1: Double?
    var load5: Double?
    var load15: Double?
    var userString: String?

    init(
        uptimeSeconds: Double? = nil,
        freeMemoryBytes: Double? = nil,
        disk1FreeBytes: Double? = nil,
        disk2FreeBytes: Double? = nil,
        disk3FreeBytes: Double? = nil,
        load1: Double? = nil,
        load5: Double? = nil,
        load15: Double? = nil,
        userString: String? = nil
    ) {
        self.uptimeSeconds = uptimeSeconds
        self.freeMemoryBytes = freeMemoryBytes
        self.disk1FreeBytes = disk1FreeBytes
        self.disk2FreeBytes = disk2FreeBytes
        self.disk3FreeBytes = disk3FreeBytes
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.userString = userString
    }
}

struct HealthTelemetrySample: Sendable {
    var heartRate: Double?
    var spO2: Double?
    var temperature: Double?

    init(heartRate: Double? = nil, spO2: Double? = nil, temperature: Double? = nil) {
        self.heartRate = heartRate
        self.spO2 = spO2
        self.temperature = temperature
    }
}

struct TrafficTelemetrySample: Sendable {
    var packetsInspected: Double?
    var positionDedupDrops: Double?
    var nodeInfoCacheHits: Double?
    var rateLimitDrops: Double?
    var unknownPacketDrops: Double?
    var hopExhaustedPackets: Double?
    var routerHopsPreserved: Double?

    init(
        packetsInspected: Double? = nil,
        positionDedupDrops: Double? = nil,
        nodeInfoCacheHits: Double? = nil,
        rateLimitDrops: Double? = nil,
        unknownPacketDrops: Double? = nil,
        hopExhaustedPackets: Double? = nil,
        routerHopsPreserved: Double? = nil
    ) {
        self.packetsInspected = packetsInspected
        self.positionDedupDrops = positionDedupDrops
        self.nodeInfoCacheHits = nodeInfoCacheHits
        self.rateLimitDrops = rateLimitDrops
        self.unknownPacketDrops = unknownPacketDrops
        self.hopExhaustedPackets = hopExhaustedPackets
        self.routerHopsPreserved = routerHopsPreserved
    }
}

struct PaxTelemetrySample: Sendable {
    var wifiCount: Double?
    var bleCount: Double?
    var uptimeSeconds: Double?

    init(
        wifiCount: Double? = nil,
        bleCount: Double? = nil,
        uptimeSeconds: Double? = nil
    ) {
        self.wifiCount = wifiCount
        self.bleCount = bleCount
        self.uptimeSeconds = uptimeSeconds
    }
}

enum TelemetryHealthState: Int, Codable, Comparable, Sendable {
    case noData
    case good
    case warning
    case alert

    static func < (lhs: TelemetryHealthState, rhs: TelemetryHealthState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TelemetryMeshHealthSummary: Hashable, Sendable {
    var score: Double
    var state: TelemetryHealthState
    var averagePathCost: Double
    var receptionScore: Double
    var channelUtilization: Double
    var packetCount: Int
}

struct TelemetryHeatmapCell: Identifiable, Hashable, Sendable {
    var id: String { "\(dayIndex)-\(hour)" }
    let dayIndex: Int
    let hour: Int
    let value: Double
}

struct TelemetryCandlePoint: Identifiable, Hashable, Sendable {
    var id: Date { date }
    let date: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
}

struct TelemetryHistogramBin: Identifiable, Hashable, Sendable {
    var id: Double { lowerBound }
    let lowerBound: Double
    let upperBound: Double
    let count: Int
}
