import Foundation

/// Transport-agnostic connection interface
enum ConnectionType: String, CaseIterable, Identifiable {
    case serial = "Serial / USB"
    case bluetooth = "Bluetooth"
    case tcp = "TCP / WiFi"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .serial: return String(localized: "Serial / USB")
        case .bluetooth: return String(localized: "Bluetooth")
        case .tcp: return String(localized: "TCP / WiFi")
        }
    }
}

/// Connection parameters union
enum ConnectionParameters {
    case serial(portName: String, baudRate: Int = 115200)
    /// deviceAddress: der UUID-String des CBPeripheral (.identifier.uuidString)
    case bluetooth(deviceAddress: String, deviceName: String)
    case tcp(hostname: String, port: Int = 4403)
}

/// A Bluetooth LE device discovered during a scan
struct DiscoveredBLEDevice: Identifiable, Sendable {
    let id: UUID
    let name: String
    var rssi: Int
}

/// Connection lifecycle state
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int, delaySeconds: Int)
    case error(String)

    var isConnected: Bool { self == .connected }
    var isConnecting: Bool {
        if case .connecting = self { return true }
        if case .reconnecting = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .disconnected: return String(localized: "Disconnected")
        case .connecting:   return String(localized: "Connecting…")
        case .connected:    return String(localized: "Connected")
        case .reconnecting(let attempt, let delay):
            return String(localized: "Reconnecting in \(delay)s… (attempt \(attempt))")
        case .error(let e): return String(localized: "Error: \(e)")
        }
    }
}

/// Transport-agnostic connection service protocol
protocol ConnectionService: AnyObject {
    var type: ConnectionType { get }
    var isConnected: Bool { get }
    var onDataReceived: ((Data) -> Void)? { get set }
    var onConnectionStateChanged: ((Bool) -> Void)? { get set }

    func connect(parameters: ConnectionParameters) async throws
    func disconnect()
    func write(_ data: Data) async throws
}
