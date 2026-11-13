import Foundation
import Network

// Windows reference: MeshhessenClient/Services/Firmware/WifiOtaTransport.cs

/// Line-oriented byte stream to the ESP32 OTA loader. Abstract so the Unified OTA sequence
/// (`Esp32WifiOtaUpdater.run(stream:image:progress:)`) can be tested with a scripted fake.
protocol OtaByteStream: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// Next `\n`-terminated line without the terminator; throws `WifiOtaError.timeout` or
    /// `.connectionClosed`.
    func readLine(timeout: Duration) async throws -> String
    func close() async
}

enum WifiOtaError: LocalizedError, Equatable {
    case emptyImage
    case otaRequestNotSent
    case otaRefused(String)
    case loaderNotFound
    case connectFailed(attempts: Int, reason: String)
    case timeout(String)
    case connectionClosed
    case hashRejected
    case verificationFailed
    case loaderError(String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .emptyImage:
            String(localized: "The firmware file is empty.")
        case .otaRequestNotSent:
            String(localized: "The OTA request could not be sent to the device.")
        case .otaRefused(let message):
            String(localized: "The device refused to enter OTA mode: \(message)")
        case .loaderNotFound:
            String(localized: "The OTA loader was not found on the network. Mac and device must be on the same Wi-Fi network.")
        case .connectFailed(let attempts, let reason):
            String(localized: "Could not connect to the OTA loader after \(attempts) attempts: \(reason)")
        case .timeout(let what):
            String(localized: "Timed out waiting for the OTA loader (\(what)).")
        case .connectionClosed:
            String(localized: "The OTA loader closed the connection.")
        case .hashRejected:
            String(localized: "The OTA loader rejected the firmware hash.")
        case .verificationFailed:
            String(localized: "The firmware hash did not match after the transfer. The device keeps its old firmware.")
        case .loaderError(let message):
            String(localized: "The OTA loader reported an error: \(message)")
        case .unexpectedResponse(let line):
            String(localized: "Unexpected answer from the OTA loader: \(line)")
        }
    }
}

/// `NWConnection` TCP stream to `<host>:3232` (no Nagle delay). A receive loop fills a line buffer;
/// `readLine` waits on that buffer with a deadline, so a timeout never strands a pending receive.
actor TcpOtaByteStream: OtaByteStream {
    static let defaultPort: UInt16 = 3232
    static let connectTimeout: Duration = .seconds(5)

    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private var buffer = Data()
    private var closedReason: String?

    init(host: String, port: UInt16 = TcpOtaByteStream.defaultPort) {
        self.host = host
        self.port = port
    }

    /// Opens the connection; throws `WifiOtaError.timeout` after 5 s or the transport's error.
    func connect() async throws {
        AppLogger.shared.log("[OTA/WiFi] Connecting to \(host):\(port)")
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw WifiOtaError.connectionClosed }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        connection = conn

        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }
        let once = Once()
        let description = "\(host):\(port)"

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error):
                    if once.claim() {
                        continuation.resume(throwing: WifiOtaError.loaderError(error.localizedDescription))
                    }
                case .waiting(let error):
                    // "Connection refused" while the loader is still booting: fail this attempt fast.
                    if once.claim() {
                        conn.cancel()
                        continuation.resume(throwing: WifiOtaError.loaderError(error.localizedDescription))
                    }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: WifiOtaError.connectionClosed) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(for: Self.connectTimeout)
                if once.claim() {
                    conn.cancel()
                    continuation.resume(throwing: WifiOtaError.timeout(String(localized: "connect to \(description)")))
                }
            }
        }
        AppLogger.shared.log("[OTA/WiFi] Connected")
        receiveNext(on: conn)
    }

    func send(_ data: Data) async throws {
        guard let conn = connection, closedReason == nil else { throw WifiOtaError.connectionClosed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: WifiOtaError.loaderError(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func readLine(timeout: Duration) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let line = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                AppLogger.shared.log("[OTA/WiFi] < \(line)")
                return line
            }
            if closedReason != nil { throw WifiOtaError.connectionClosed }
            guard ContinuousClock.now < deadline else { throw WifiOtaError.timeout("\(timeout)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func close() async {
        connection?.cancel()
        connection = nil
        if closedReason == nil { closedReason = "closed" }
    }

    // MARK: - Private

    private func receiveNext(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceive(conn: conn, data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(conn: NWConnection, data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty { buffer.append(data) }
        if let error {
            closedReason = error.localizedDescription
            return
        }
        if isComplete {
            closedReason = "closed by device"
            return
        }
        guard connection === conn else { return }
        receiveNext(on: conn)
    }
}
