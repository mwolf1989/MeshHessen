import Foundation
import SwiftUI

// MARK: - Routing Error

/// Meshtastic routing error codes — matches official protobuf `Routing.Error` values.
enum RoutingError: Int, CaseIterable, Identifiable {
    case none = 0
    case noRoute = 1
    case gotNak = 2
    case timeout = 3
    case noInterface = 4
    case maxRetransmit = 5
    case noChannel = 6
    case tooLarge = 7
    case noResponse = 8
    case dutyCycleLimit = 9
    case badRequest = 32
    case notAuthorized = 33
    case pkiFailed = 34
    case pkiUnknownPubkey = 35
    case adminBadSessionKey = 36
    case adminPublicKeyUnauthorized = 37
    case rateLimitExceeded = 38

    var id: Int { rawValue }

    var display: String {
        switch self {
        case .none:                         return String(localized: "Delivered")
        case .noRoute:                      return String(localized: "No route")
        case .gotNak:                       return String(localized: "NAK received")
        case .timeout:                      return String(localized: "Timeout")
        case .noInterface:                  return String(localized: "No interface")
        case .maxRetransmit:                return String(localized: "Max retransmit exceeded")
        case .noChannel:                    return String(localized: "No channel")
        case .tooLarge:                     return String(localized: "Packet too large")
        case .noResponse:                   return String(localized: "No response")
        case .dutyCycleLimit:               return String(localized: "Duty cycle limit")
        case .badRequest:                   return String(localized: "Bad request")
        case .notAuthorized:                return String(localized: "Not authorized")
        case .pkiFailed:                    return String(localized: "PKI failed")
        case .pkiUnknownPubkey:             return String(localized: "Unknown public key")
        case .adminBadSessionKey:           return String(localized: "Bad admin session key")
        case .adminPublicKeyUnauthorized:   return String(localized: "Admin key unauthorized")
        case .rateLimitExceeded:            return String(localized: "Rate limit exceeded")
        }
    }

    var color: Color {
        switch self {
        case .none:                         return .green
        case .noRoute, .timeout, .noResponse, .dutyCycleLimit, .rateLimitExceeded:
            return .orange
        default:                            return .red
        }
    }

    var canRetry: Bool {
        switch self {
        case .none, .noChannel, .tooLarge, .notAuthorized, .pkiFailed,
             .pkiUnknownPubkey, .adminBadSessionKey, .adminPublicKeyUnauthorized:
            return false
        default:
            return true
        }
    }
}

// MARK: - Device Roles

/// Meshtastic device role — determines routing and power behavior.
enum DeviceRole: Int, CaseIterable, Identifiable {
    case client = 0
    case clientMute = 1
    case router = 2
    case routerClient = 3
    case repeater = 4
    case tracker = 5
    case sensor = 6
    case tak = 7
    case clientHidden = 8
    case lostAndFound = 9
    case takTracker = 10

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .client:       return String(localized: "Client")
        case .clientMute:   return String(localized: "Client Mute")
        case .router:       return String(localized: "Router")
        case .routerClient: return String(localized: "Router Client")
        case .repeater:     return String(localized: "Repeater")
        case .tracker:      return String(localized: "Tracker")
        case .sensor:       return String(localized: "Sensor")
        case .tak:          return String(localized: "TAK")
        case .clientHidden: return String(localized: "Client Hidden")
        case .lostAndFound: return String(localized: "Lost and Found")
        case .takTracker:   return String(localized: "TAK Tracker")
        }
    }

    var systemImage: String {
        switch self {
        case .client:       return "iphone"
        case .clientMute:   return "speaker.slash"
        case .router:       return "arrow.triangle.branch"
        case .routerClient: return "arrow.triangle.swap"
        case .repeater:     return "repeat"
        case .tracker:      return "location.circle"
        case .sensor:       return "sensor.fill"
        case .tak:          return "shield.checkered"
        case .clientHidden: return "eye.slash"
        case .lostAndFound: return "mappin.and.ellipse"
        case .takTracker:   return "shield.and.arrow.up"
        }
    }

    var description: String {
        switch self {
        case .client:       return String(localized: "Default behavior; messages are routed and displayed.")
        case .clientMute:   return String(localized: "Same as Client but does not contribute to routing.")
        case .router:       return String(localized: "Infrastructure node; screen off, high-power routing.")
        case .routerClient: return String(localized: "Combination of Router and Client roles.")
        case .repeater:     return String(localized: "Simply rebroadcasts all received packets.")
        case .tracker:      return String(localized: "Sends position reports regularly; minimal other behavior.")
        case .sensor:       return String(localized: "Sends environment telemetry; minimal other behavior.")
        case .tak:          return String(localized: "Optimized for ATAK/TAK interoperability.")
        case .clientHidden: return String(localized: "Client that does not advertise itself in node lists.")
        case .lostAndFound: return String(localized: "Sends position periodically for asset tracking.")
        case .takTracker:   return String(localized: "TAK + Tracker combined role.")
        }
    }
}

// MARK: - Rebroadcast Modes

enum RebroadcastMode: Int, CaseIterable, Identifiable {
    case all = 0
    case allSkipDecoding = 1
    case localOnly = 2
    case knownOnly = 3
    case none = 4
    case corePortnumsOnly = 5

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .all:              return String(localized: "All")
        case .allSkipDecoding:  return String(localized: "All (skip decoding)")
        case .localOnly:        return String(localized: "Local Only")
        case .knownOnly:        return String(localized: "Known Only")
        case .none:             return String(localized: "None")
        case .corePortnumsOnly: return String(localized: "Core Portnums Only")
        }
    }
}

// MARK: - Region Codes

enum RegionCode: Int, CaseIterable, Identifiable {
    case unset = 0
    case us = 1
    case eu433 = 2
    case eu868 = 3
    case cn = 4
    case jp = 5
    case anz = 6
    case kr = 7
    case tw = 8
    case ru = 9
    case `in` = 10
    case nz865 = 11
    case th = 12
    case ua433 = 14
    case ua868 = 15
    case my433 = 16
    case my919 = 17
    case sg923 = 18
    case lora24 = 13

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .unset:  return String(localized: "Unset")
        case .us:     return "US"
        case .eu433:  return "EU 433"
        case .eu868:  return "EU 868"
        case .cn:     return "CN"
        case .jp:     return "JP"
        case .anz:    return "ANZ"
        case .kr:     return "KR"
        case .tw:     return "TW"
        case .ru:     return "RU"
        case .in:     return "IN"
        case .nz865:  return "NZ 865"
        case .th:     return "TH"
        case .ua433:  return "UA 433"
        case .ua868:  return "UA 868"
        case .my433:  return "MY 433"
        case .my919:  return "MY 919"
        case .sg923:  return "SG 923"
        case .lora24: return "LoRa 2.4 GHz"
        }
    }

    var dutyCycle: Int {
        switch self {
        case .eu433, .eu868: return 10
        default: return 100
        }
    }
}

// MARK: - Modem Presets

enum ModemPreset: Int, CaseIterable, Identifiable {
    case longFast = 0
    case longSlow = 1
    case longModerate = 7
    case veryLongSlow = 2
    case mediumSlow = 3
    case mediumFast = 4
    case shortSlow = 5
    case shortFast = 6
    case shortTurbo = 8

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .longFast:      return "Long Fast"
        case .longSlow:      return "Long Slow"
        case .longModerate:  return "Long Moderate"
        case .veryLongSlow:  return "Very Long Slow"
        case .mediumSlow:    return "Medium Slow"
        case .mediumFast:    return "Medium Fast"
        case .shortSlow:     return "Short Slow"
        case .shortFast:     return "Short Fast"
        case .shortTurbo:    return "Short Turbo"
        }
    }
}

// MARK: - Channel Role

enum ChannelRole: Int, CaseIterable, Identifiable {
    case disabled = 0
    case primary = 1
    case secondary = 2

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .disabled:  return String(localized: "Disabled")
        case .primary:   return String(localized: "Primary")
        case .secondary: return String(localized: "Secondary")
        }
    }
}

// MARK: - Bluetooth Mode

enum BluetoothMode: Int, CaseIterable, Identifiable {
    case randomPin = 0
    case fixedPin = 1
    case noPin = 2

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .randomPin: return String(localized: "Random PIN")
        case .fixedPin:  return String(localized: "Fixed PIN")
        case .noPin:     return String(localized: "No PIN")
        }
    }
}

// MARK: - Tapback / Emoji Reactions

/// Extended emoji reaction set (32 emojis in 4×8 grid)
enum EmojiReaction {
    /// All available reaction emojis, arranged in a 4×8 grid
    static let allEmojis: [String] = [
        // Row 1
        "👍", "👎", "❤️", "😂", "😮", "😢", "😡", "🔥",
        // Row 2
        "👋", "🎉", "🤔", "👀", "💯", "🙏", "🤝", "💪",
        // Row 3
        "⚡", "✅", "❌", "⚠️", "📍", "🔔", "⭐", "💬",
        // Row 4
        "‼️", "❓", "💩", "🫡", "🤣", "😎", "🥳", "☠️",
    ]

    static let columns = 8
    static let rows = 4
}

/// Legacy Tapback enum for backward compatibility
enum Tapback: Int, CaseIterable, Identifiable {
    case wave = 0
    case heart = 1
    case thumbsUp = 2
    case thumbsDown = 3
    case haHa = 4
    case exclamation = 5
    case question = 6
    case poop = 7

    var id: Int { rawValue }

    var emojiString: String {
        switch self {
        case .wave:        return "👋"
        case .heart:       return "❤️"
        case .thumbsUp:    return "👍"
        case .thumbsDown:  return "👎"
        case .haHa:        return "😂"
        case .exclamation: return "‼️"
        case .question:    return "❓"
        case .poop:        return "💩"
        }
    }
}

// MARK: - Message Destination

enum MessageDestination {
    case channel(index: Int)
    case user(nodeId: UInt32)

    var isDirectMessage: Bool {
        if case .user = self { return true }
        return false
    }
}

// MARK: - Metrics Types

enum MetricsType: Int, CaseIterable, Identifiable {
    case device = 0
    case environment = 1
    case power = 2
    case airQuality = 3
    case stats = 4

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .device:      return String(localized: "Device")
        case .environment: return String(localized: "Environment")
        case .power:       return String(localized: "Power")
        case .airQuality:  return String(localized: "Air Quality")
        case .stats:       return String(localized: "Statistics")
        }
    }

    var systemImage: String {
        switch self {
        case .device:      return "cpu"
        case .environment: return "thermometer"
        case .power:       return "bolt.fill"
        case .airQuality:  return "aqi.medium"
        case .stats:       return "chart.bar"
        }
    }
}

// MARK: - Map Layer

enum MapLayer: String, CaseIterable, Identifiable {
    case standard
    case hybrid
    case satellite
    case offline

    var id: String { rawValue }

    var name: String {
        switch self {
        case .standard:  return String(localized: "Standard")
        case .hybrid:    return String(localized: "Hybrid")
        case .satellite: return String(localized: "Satellite")
        case .offline:   return String(localized: "Offline")
        }
    }

    var systemImage: String {
        switch self {
        case .standard:  return "map"
        case .hybrid:    return "map.fill"
        case .satellite: return "globe"
        case .offline:   return "internaldrive"
        }
    }
}

// MARK: - Map Tile Server

enum MapTileServer: String, CaseIterable, Identifiable {
    case openStreetMap
    case openTopoMap
    case cartoDark
    case cartoLight

    var id: String { rawValue }

    var name: String {
        switch self {
        case .openStreetMap: return "OpenStreetMap"
        case .openTopoMap:   return "OpenTopoMap"
        case .cartoDark:     return "Carto Dark"
        case .cartoLight:    return "Carto Light"
        }
    }

    var tileUrl: String {
        switch self {
        case .openStreetMap: return "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        case .openTopoMap:   return "https://tile.opentopomap.org/{z}/{x}/{y}.png"
        case .cartoDark:     return "https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png"
        case .cartoLight:    return "https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}@2x.png"
        }
    }

    var attribution: String {
        switch self {
        case .openStreetMap: return "© OpenStreetMap contributors"
        case .openTopoMap:   return "© OpenTopoMap contributors"
        case .cartoDark, .cartoLight: return "© CARTO © OpenStreetMap contributors"
        }
    }

    var maxZoom: Int {
        switch self {
        case .openStreetMap: return 19
        case .openTopoMap:   return 17
        case .cartoDark, .cartoLight: return 20
        }
    }
}

// MARK: - Bubble Position

enum BubblePosition {
    case left
    case right
}

// MARK: - Portnum

/// Meshtastic port numbers — determines how payloads are decoded.
enum PortNum: Int, CaseIterable, Identifiable {
    case unknownApp = 0
    case textMessageApp = 1
    case remoteHardwareApp = 2
    case positionApp = 3
    case nodeinfoApp = 4
    case routingApp = 5
    case adminApp = 6
    case textMessageCompressedApp = 7
    case waypointApp = 8
    case audioApp = 9
    case detectionSensorApp = 10
    case replyApp = 32
    case ipTunnelApp = 33
    case serialApp = 64
    case storeForwardApp = 65
    case rangeTestApp = 66
    case telemetryApp = 67
    case zpsApp = 68
    case simulatorApp = 69
    case tracerouteApp = 70
    case neighborinfoApp = 71
    case atakPlugin = 72
    case mapReportApp = 73
    case powerstressApp = 74
    case atakForwarder = 257
    case max = 511

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .unknownApp:                return "Unknown"
        case .textMessageApp:            return "Text Message"
        case .remoteHardwareApp:         return "Remote Hardware"
        case .positionApp:               return "Position"
        case .nodeinfoApp:               return "Node Info"
        case .routingApp:                return "Routing"
        case .adminApp:                  return "Admin"
        case .textMessageCompressedApp:  return "Compressed Text"
        case .waypointApp:               return "Waypoint"
        case .audioApp:                  return "Audio"
        case .detectionSensorApp:        return "Detection Sensor"
        case .replyApp:                  return "Reply"
        case .ipTunnelApp:               return "IP Tunnel"
        case .serialApp:                 return "Serial"
        case .storeForwardApp:           return "Store & Forward"
        case .rangeTestApp:              return "Range Test"
        case .telemetryApp:              return "Telemetry"
        case .zpsApp:                    return "ZPS"
        case .simulatorApp:              return "Simulator"
        case .tracerouteApp:             return "Traceroute"
        case .neighborinfoApp:           return "Neighbor Info"
        case .atakPlugin:                return "ATAK Plugin"
        case .mapReportApp:              return "Map Report"
        case .powerstressApp:            return "Power Stress"
        case .atakForwarder:             return "ATAK Forwarder"
        case .max:                       return "Max"
        }
    }
}
