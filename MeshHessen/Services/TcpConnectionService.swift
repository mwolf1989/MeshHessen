import Foundation
import Network

/// TCP/WiFi connection to a Meshtastic node
/// Uses Network.framework (NWConnection) for async TCP
@MainActor
final class TcpConnectionService: ConnectionService {
    let type: ConnectionType = .tcp
    var onDataReceived: ((Data) -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?

    private(set) var isConnected: Bool = false
    private var didNotifyDisconnected: Bool = false

    private var connection: NWConnection?
    private let writeQueue = DispatchQueue(label: "tcp.write")

    @MainActor
    func connect(parameters: ConnectionParameters) async throws {
        guard case .tcp(let hostname, let port) = parameters else {
            AppLogger.shared.log("[TCP] Invalid connection parameters", debug: true)
            throw ConnectionError.invalidParameters
        }

        AppLogger.shared.log("[TCP] Connecting to \(hostname):\(port)...", debug: true)
        let host = NWEndpoint.Host(hostname)
        let portNum = NWEndpoint.Port(integerLiteral: UInt16(port))
        let conn = NWConnection(host: host, port: portNum, using: .tcp)
        self.connection = conn

        // Use a reference-type box so the closure can safely mutate 'resumed'
        // across the Sendable boundary without data races.
        final class ResumedBox: @unchecked Sendable { var value = false }
        let resumedBox = ResumedBox()

        return try await withCheckedThrowingContinuation { continuation in
            conn.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let stateName = self.nwStateName(state)
                    AppLogger.shared.log("[TCP] Connection state: \(stateName)", debug: true)
                    switch state {
                    case .setup:
                        AppLogger.shared.log("[TCP] Setup", debug: true)
                    case .ready:
                        self.isConnected = true
                        self.didNotifyDisconnected = false
                        self.onConnectionStateChanged?(true)
                        AppLogger.shared.log("[TCP] Connected to \(hostname):\(port)", debug: true)
                        if !resumedBox.value {
                            resumedBox.value = true
                            continuation.resume()
                        }
                        self.startReceiving()
                    case .failed(let error):
                        self.isConnected = false
                        self.connection = nil
                        self.notifyDisconnectedOnce()
                        AppLogger.shared.log("[TCP] Connection failed: \(error.localizedDescription)", debug: true)
                        if !resumedBox.value {
                            resumedBox.value = true
                            continuation.resume(throwing: error)
                        }
                    case .cancelled:
                        self.isConnected = false
                        self.connection = nil
                        self.notifyDisconnectedOnce()
                        AppLogger.shared.log("[TCP] Connection cancelled", debug: true)
                        if !resumedBox.value {
                            resumedBox.value = true
                            continuation.resume(throwing: ConnectionError.cancelled)
                        }
                    case .waiting(let error):
                        AppLogger.shared.log("[TCP] Waiting: \(error.localizedDescription)", debug: true)
                    case .preparing:
                        AppLogger.shared.log("[TCP] Preparing connection...", debug: true)
                    @unknown default:
                        AppLogger.shared.log("[TCP] Unknown state: \(stateName)", debug: true)
                    }
                }
            }

            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    func disconnect() {
        if connection == nil, !isConnected { return }
        AppLogger.shared.log("[TCP] Disconnecting...", debug: true)
        isConnected = false
        connection?.cancel()
        connection = nil
        notifyDisconnectedOnce()
        AppLogger.shared.log("[TCP] Disconnected", debug: true)
    }

    @MainActor
    func write(_ data: Data) async throws {
        guard let conn = connection else {
            AppLogger.shared.log("[TCP] Write failed: not connected", debug: true)
            throw ConnectionError.notConnected
        }
        AppLogger.shared.log("[TCP] Writing \(data.count) bytes...", debug: true)
        return try await withCheckedThrowingContinuation { continuation in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    AppLogger.shared.log("[TCP] Write error: \(error.localizedDescription)", debug: true)
                    continuation.resume(throwing: error)
                } else {
                    AppLogger.shared.log("[TCP] Write completed (\(data.count) bytes)", debug: true)
                    continuation.resume()
                }
            })
        }
    }

    private func startReceiving() {
        guard let conn = connection else {
            AppLogger.shared.log("[TCP] Cannot start receiving: no connection", debug: true)
            return
        }
        AppLogger.shared.log("[TCP] Started receiving data...", debug: true)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty {
                    AppLogger.shared.log("[TCP] Received \(data.count) bytes", debug: true)
                    self.onDataReceived?(data)
                }
                if let error {
                    AppLogger.shared.log("[TCP] Receive error: \(error.localizedDescription)", debug: true)
                    self.disconnect()
                    return
                }
                if isComplete {
                    AppLogger.shared.log("[TCP] Connection closed by remote host", debug: true)
                    self.disconnect()
                    return
                }
                // Keep receiving
                guard self.isConnected, self.connection === conn else { return }
                self.startReceiving()
            }
        }
    }

    private func notifyDisconnectedOnce() {
        guard !didNotifyDisconnected else { return }
        didNotifyDisconnected = true
        onConnectionStateChanged?(false)
    }

    private func nwStateName(_ state: NWConnection.State) -> String {
        switch state {
        case .setup: return "setup"
        case .waiting(_): return "waiting"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .failed(_): return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown(\(state))"
        }
    }
}

enum ConnectionError: LocalizedError {
    case invalidParameters
    case notConnected
    case cancelled
    case timeout
    /// Permanent OS-level denial (e.g. sandbox EPERM on serial port). Retrying is pointless.
    case notPermitted

    var errorDescription: String? {
        switch self {
        case .invalidParameters: return String(localized: "Invalid connection parameters")
        case .notConnected:      return String(localized: "Not connected")
        case .cancelled:         return String(localized: "Connection cancelled")
        case .timeout:           return String(localized: "Connection timed out")
        case .notPermitted:      return String(localized: "Permission denied. For serial/USB ports, make sure the app is allowed to access the port. On macOS, re-plug the device and try again. If this persists, check that no other app holds the port open.")
        }
    }

    /// True for errors that are permanent and should not trigger auto-reconnect.
    var isPermanent: Bool {
        switch self {
        case .notPermitted, .invalidParameters: return true
        case .notConnected, .cancelled, .timeout: return false
        }
    }
}
