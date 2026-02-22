import Foundation
import Network

/// TCP/WiFi connection to a Meshtastic node
/// Uses Network.framework (NWConnection) for async TCP
final class TcpConnectionService: ConnectionService {
    let type: ConnectionType = .tcp
    var onDataReceived: ((Data) -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?

    private(set) var isConnected: Bool = false

    private var connection: NWConnection?
    private let writeQueue = DispatchQueue(label: "tcp.write")

    func connect(parameters: ConnectionParameters) async throws {
        guard case .tcp(let hostname, let port) = parameters else {
            throw ConnectionError.invalidParameters
        }

        let host = NWEndpoint.Host(hostname)
        let portNum = NWEndpoint.Port(integerLiteral: UInt16(port))
        let conn = NWConnection(host: host, port: portNum, using: .tcp)
        self.connection = conn

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isConnected = true
                    self.onConnectionStateChanged?(true)
                    if !resumed {
                        resumed = true
                        continuation.resume()
                    }
                    self.startReceiving()
                case .failed(let error):
                    self.isConnected = false
                    self.onConnectionStateChanged?(false)
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    self.isConnected = false
                    self.onConnectionStateChanged?(false)
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: ConnectionError.cancelled)
                    }
                default:
                    break
                }
            }

            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    func disconnect() {
        isConnected = false
        connection?.cancel()
        connection = nil
        onConnectionStateChanged?(false)
    }

    func write(_ data: Data) async throws {
        guard let conn = connection else { throw ConnectionError.notConnected }
        // Pad write with 100ms delay (matching Windows client behavior)
        return try await withCheckedThrowingContinuation { continuation in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func startReceiving() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.onDataReceived?(data)
            }
            if isComplete || error != nil {
                self.disconnect()
                return
            }
            // Keep receiving
            self.startReceiving()
        }
    }
}

enum ConnectionError: LocalizedError {
    case invalidParameters
    case notConnected
    case cancelled
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidParameters: return String(localized: "Invalid connection parameters")
        case .notConnected:      return String(localized: "Not connected")
        case .cancelled:         return String(localized: "Connection cancelled")
        case .timeout:           return String(localized: "Connection timed out")
        }
    }
}
