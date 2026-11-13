import Foundation

import SwiftProtobuf

// MARK: - Request Type

/// Kind of a directed request another station sent to our node ("Funk-Echo").
/// Raw values are stored in `request_echo.req_type`.
enum RequestEchoType: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case nodeInfo
    case position
    case telemetry
    case traceroute
    case admin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nodeInfo: return String(localized: "NodeInfo")
        case .position: return String(localized: "Position")
        case .telemetry: return String(localized: "Telemetry")
        case .traceroute: return String(localized: "Traceroute")
        case .admin: return String(localized: "Remote admin")
        }
    }

    var emoji: String {
        switch self {
        case .nodeInfo: return "👋"
        case .position: return "📍"
        case .telemetry: return "🔋"
        case .traceroute: return "🛰️"
        case .admin: return "🛠️"
        }
    }

    /// Accent colour as `#RRGGBB` (same palette as the Windows client).
    var colorHex: String {
        switch self {
        case .nodeInfo: return "#8B73D8"
        case .position: return "#DB9A44"
        case .telemetry: return "#20C997"
        case .traceroute: return "#428ECC"
        case .admin: return "#F04C4C"
        }
    }
}

// MARK: - Telemetry Detail

/// Telemetry variant a request asks for. Raw values are stored in `request_echo.detail`
/// and match the Windows client's codes.
enum RequestEchoTelemetryDetail: String, CaseIterable, Sendable {
    case device = "Device"
    case environment = "Environment"
    case airQuality = "AirQuality"
    case power = "Power"
    case localStats = "LocalStats"
    case host = "Host"
    case health = "Health"

    var displayName: String {
        switch self {
        case .device: return String(localized: "device metrics")
        case .environment: return String(localized: "environment data")
        case .airQuality: return String(localized: "air-quality data")
        case .power: return String(localized: "power metrics")
        case .localStats: return String(localized: "mesh statistics")
        case .host: return String(localized: "host metrics")
        case .health: return String(localized: "health data")
        }
    }

    /// Label for a stored detail code; empty or nil means a generic request.
    static func label(for code: String?) -> String {
        guard let code, !code.isEmpty else { return String(localized: "generic") }
        return Self(rawValue: code)?.displayName ?? code
    }
}

// MARK: - Event

/// A detected incoming request addressed to our node.
struct RequestEchoEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let fromId: UInt32
    let type: RequestEchoType
    let timestamp: Date
    /// nil = unknown hop count.
    let hops: Int?
    let viaMqtt: Bool
    let channel: UInt32
    let packetId: UInt32
    /// Traceroute only: relays the request travelled through on its way to us.
    let route: [UInt32]?
    /// Telemetry only: requested variant (`RequestEchoTelemetryDetail` raw value).
    let detail: String?

    init(
        id: UUID = UUID(),
        fromId: UInt32,
        type: RequestEchoType,
        timestamp: Date,
        hops: Int?,
        viaMqtt: Bool,
        channel: UInt32 = 0,
        packetId: UInt32 = 0,
        route: [UInt32]? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.fromId = fromId
        self.type = type
        self.timestamp = timestamp
        self.hops = hops
        self.viaMqtt = viaMqtt
        self.channel = channel
        self.packetId = packetId
        self.route = route
        self.detail = detail
    }

    /// Route as stored in the database: `!0000abcd,!0000beef`.
    var routeText: String? {
        guard let route, !route.isEmpty else { return nil }
        return route.map { String(format: "!%08x", $0) }.joined(separator: ",")
    }
}

// MARK: - Classifier

/// Pure classification of incoming packets into Funk-Echo events. The firmware forwards
/// every received packet to the client, so directed requests reach us — but its automatic
/// replies do not, hence there is no "answered" state.
enum RequestEchoClassifier {
    /// The request type of a decoded packet; nil = not a request aimed at us.
    static func type(myNodeId: UInt32, packet: Meshtastic_MeshPacket) -> RequestEchoType? {
        guard myNodeId != 0,
              packet.to == myNodeId,                          // broadcasts & overheard → out
              packet.from != 0, packet.from != myNodeId,      // own / injected packets → out
              case .decoded(let data) = packet.payloadVariant,
              data.requestID == 0                             // replies to our requests → out
        else { return nil }

        switch data.portnum {
        case .nodeinfoApp where data.wantResponse: return .nodeInfo
        case .positionApp where data.wantResponse: return .position
        case .telemetryApp where data.wantResponse: return .telemetry
        case .tracerouteApp where data.wantResponse: return .traceroute
        // Any foreign admin packet aimed at us is noteworthy, flag or not.
        case .adminApp: return .admin
        default: return nil
        }
    }

    /// Builds the full event for a request aimed at us; nil = not a request.
    static func classify(
        myNodeId: UInt32,
        packet: Meshtastic_MeshPacket,
        timestamp: Date = Date()
    ) -> RequestEchoEvent? {
        guard let type = type(myNodeId: myNodeId, packet: packet) else { return nil }
        return RequestEchoEvent(
            fromId: packet.from,
            type: type,
            timestamp: timestamp,
            hops: hops(of: packet),
            viaMqtt: packet.viaMqtt,
            channel: packet.channel,
            packetId: packet.id,
            route: type == .traceroute ? route(of: packet) : nil,
            detail: type == .telemetry ? telemetryVariant(of: packet) : nil
        )
    }

    /// Traceroute requests: relays the request came through (route towards us).
    static func route(of packet: Meshtastic_MeshPacket) -> [UInt32]? {
        guard case .decoded(let data) = packet.payloadVariant,
              data.portnum == .tracerouteApp,
              let discovery = try? Meshtastic_RouteDiscovery(serializedBytes: data.payload),
              !discovery.route.isEmpty
        else { return nil }
        return discovery.route
    }

    /// Telemetry requests: the set variant of the request payload names the wanted
    /// metric group. Soil/water counts as environment data. nil = unknown/empty payload.
    static func telemetryVariant(of packet: Meshtastic_MeshPacket) -> String? {
        guard case .decoded(let data) = packet.payloadVariant,
              data.portnum == .telemetryApp,
              let telemetry = try? Meshtastic_Telemetry(serializedBytes: data.payload)
        else { return nil }
        let detail: RequestEchoTelemetryDetail?
        switch telemetry.variant {
        case .deviceMetrics: detail = .device
        case .environmentMetrics, .soilWaterMetrics: detail = .environment
        case .airQualityMetrics: detail = .airQuality
        case .powerMetrics: detail = .power
        case .localStats: detail = .localStats
        case .hostMetrics: detail = .host
        case .healthMetrics: detail = .health
        case .trafficManagementStats, .none: detail = nil
        }
        return detail?.rawValue
    }

    /// Hop count from the packet header; nil = unknown.
    static func hops(of packet: Meshtastic_MeshPacket) -> Int? {
        guard packet.hopStart != 0, packet.hopLimit <= packet.hopStart else { return nil }
        return Int(packet.hopStart - packet.hopLimit)
    }
}

// MARK: - Expectation

/// "Will our node answer?" derived from LOCAL knowledge only. The firmware's actual reply
/// is invisible to the client, so this states what the configuration implies, never a
/// confirmed transmission.
///
/// Codes stored in `request_echo.expected`: `yes`, `prec:<bits>` (position coarsened to
/// the channel's precision), `no-pos` (no own position), `sensor` (depends on attached
/// sensors), `auth` (only with admin authorisation).
enum RequestEchoExpectation {
    static func compute(
        type: RequestEchoType,
        detail: String?,
        hasOwnPosition: Bool,
        channelPrecisionBits: UInt32
    ) -> String {
        switch type {
        case .nodeInfo, .traceroute:
            return "yes"
        case .position:
            guard hasOwnPosition else { return "no-pos" }
            return (1...31).contains(channelPrecisionBits) ? "prec:\(channelPrecisionBits)" : "yes"
        case .telemetry:
            return detail == RequestEchoTelemetryDetail.device.rawValue
                || detail == RequestEchoTelemetryDetail.localStats.rawValue ? "yes" : "sensor"
        case .admin:
            return "auth"
        }
    }

    /// Radius in km of a position coarsened to `bits` of precision (0 = full precision).
    static func precisionRadiusKm(bits: Int) -> Double {
        guard (1...31).contains(bits) else { return 0 }
        return pow(2, Double(32 - bits)) * 1e-7 * 111.32 / 2
    }

    /// Human text for a stored expectation code; nil when none is stored.
    static func text(for code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        if code.hasPrefix("prec:"), let bits = Int(code.dropFirst(5)) {
            let km = precisionRadiusKm(bits: bits)
            let distance = km >= 1
                ? String(format: "±%.1f km", km)
                : String(format: "±%.0f m", km * 1_000)
            return String(localized: "✓ reply expected (\(distance))")
        }
        switch code {
        case "yes": return String(localized: "✓ reply expected")
        case "no-pos": return String(localized: "✕ no reply (no position)")
        case "sensor": return String(localized: "? depends on sensors")
        case "auth": return String(localized: "🔐 only with admin authorisation")
        default: return nil
        }
    }
}

// MARK: - Message Texts

enum RequestEchoTone: String, CaseIterable, Identifiable, Sendable {
    case casual
    case factual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .casual: return String(localized: "Casual (“KELL is tracing the path to us!”)")
        case .factual: return String(localized: "Factual (“Traceroute request from KELL”)")
        }
    }
}

enum RequestEchoText {
    /// One-line message for the popover, notifications and the journal.
    static func message(
        type: RequestEchoType,
        from who: String,
        detail: String?,
        tone: RequestEchoTone
    ) -> String {
        if type == .telemetry, let detail, !detail.isEmpty {
            let what = RequestEchoTelemetryDetail.label(for: detail)
            switch tone {
            case .casual: return String(localized: "🔎 \(who) is asking for our \(what).")
            case .factual: return String(localized: "Telemetry request (\(what)) received from \(who)")
            }
        }
        switch (tone, type) {
        case (.casual, .nodeInfo): return String(localized: "👋 \(who) wants to get to know us.")
        case (.casual, .position): return String(localized: "📍 \(who) is asking where we are.")
        case (.casual, .telemetry): return String(localized: "🔋 \(who) is asking how our node is doing.")
        case (.casual, .traceroute): return String(localized: "🛰️ \(who) is tracing the radio path to us!")
        case (.casual, .admin): return String(localized: "🛠️ \(who) is knocking on our remote admin.")
        case (.factual, .nodeInfo): return String(localized: "NodeInfo request received from \(who)")
        case (.factual, .position): return String(localized: "Position request received from \(who)")
        case (.factual, .telemetry): return String(localized: "Telemetry request received from \(who)")
        case (.factual, .traceroute): return String(localized: "Traceroute request received from \(who)")
        case (.factual, .admin): return String(localized: "Admin packet received from \(who)")
        }
    }

    /// Source label: direct / n hops / MQTT; "–" when unknown.
    static func source(hops: Int?, viaMqtt: Bool) -> String {
        if viaMqtt { return String(localized: "☁ MQTT") }
        guard let hops else { return "–" }
        return hops == 0 ? String(localized: "direct") : String(localized: "\(hops) hops")
    }
}

// MARK: - Stored Rows

/// One journal row (a burst of identical requests).
struct RequestEchoRecord: Identifiable, Hashable, Sendable {
    let id: Int64
    let nodeId: UInt32
    /// `RequestEchoType` raw value; unknown values are kept for forward compatibility.
    let typeRaw: String
    let firstSeen: Date
    let lastSeen: Date
    let count: Int
    let hops: Int?
    let viaMqtt: Bool
    /// `!id,!id` route of a traceroute request.
    let route: String?
    let detail: String?
    let expected: String?

    var type: RequestEchoType? { RequestEchoType(rawValue: typeRaw) }

    var routeNodeIds: [UInt32] {
        guard let route, !route.isEmpty else { return [] }
        return route.split(separator: ",").compactMap {
            UInt32($0.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "!" }), radix: 16)
        }
    }
}

struct RequestEchoTopNode: Hashable, Sendable {
    let nodeId: UInt32
    let count: Int
}

/// Aggregated Funk-Echo statistics; counts are request counts, not rows.
struct RequestEchoStats: Equatable, Sendable {
    var totalRequests = 0
    var stations = 0
    var perType: [String: Int] = [:]
    /// Telemetry requests per detail code; "" = generic request.
    var telemetryDetails: [String: Int] = [:]
    var topNodes: [RequestEchoTopNode] = []

    var traceCount: Int { perType[RequestEchoType.traceroute.rawValue] ?? 0 }
}
