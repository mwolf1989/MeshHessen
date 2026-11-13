import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/BleOtaTransport.cs

enum BleOtaError: LocalizedError, Equatable {
    case loaderNotFound
    case connectFailed(attempts: Int, reason: String)
    case serviceMissing
    case notConnected
    case okBeforeLastChunk
    case timeout(String)
    case connectionLost(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .loaderNotFound:
            String(localized: "The OTA loader was not found over Bluetooth. Make sure the device restarted into OTA mode and is close to the Mac.")
        case .connectFailed(let attempts, let reason):
            String(localized: "The device confirmed OTA mode, but the Bluetooth OTA service was unreachable after \(attempts) attempts (\(reason)). The device stays in OTA mode until it is restarted (reset button or a short power cycle) — then try again.")
        case .serviceMissing:
            String(localized: "Connected, but the device offers no OTA service (still in mesh mode, or a stale Bluetooth pairing).")
        case .notConnected:
            String(localized: "Not connected to the OTA loader.")
        case .okBeforeLastChunk:
            String(localized: "The OTA loader reported OK before the last chunk (size accounting mismatch).")
        case .timeout(let what):
            String(localized: "Timed out waiting for the OTA loader (\(what)).")
        case .connectionLost(let detail):
            String(localized: "The Bluetooth connection to the OTA loader was lost (\(detail)).")
        case .writeFailed(let reason):
            String(localized: "Bluetooth write to the OTA loader failed: \(reason)")
        }
    }
}

/// Unified OTA over the ESP32 loader's GATT service. The loader is an ACK-paced byte stream: one write
/// → exactly one notification (`ACK` while more data is expected, terminal `OK` after the last byte
/// verified). Each chunk is therefore a **single** write no larger than the negotiated payload — a chunk
/// fragmented into two writes would be coalesced into one `ACK` and desynchronise the accounting.
final class BleOtaTransport {
    static let serviceUUID = GattUUID("4FAFC201-1FB5-459E-8FCC-C5C9C331914B")
    static let writeUUID = GattUUID("62EC0272-3EC5-11EB-B378-0242AC130005")
    static let notifyUUID = GattUUID("62EC0272-3EC5-11EB-B378-0242AC130003")

    static let recommendedChunkSize = 512
    static let discoveryTimeout: Duration = .seconds(15)
    static let subscribeSettle: Duration = .milliseconds(500)
    static let erasingTimeout: Duration = .seconds(60)
    static let ackTimeout: Duration = .seconds(10)
    static let verificationTimeout: Duration = .seconds(10)
    static let writeTimeout: Duration = .seconds(15)

    let link: any DfuGattLink
    private let sleep: (Duration) async throws -> Void

    init(link: any DfuGattLink, sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.link = link
        self.sleep = sleep
    }

    /// `min(512, maxWriteLength)`, at least 1.
    var chunkSize: Int { Self.chunkSize(maxWriteLength: link.maxWriteLength) }

    static func chunkSize(maxWriteLength: Int) -> Int {
        max(1, min(recommendedChunkSize, maxWriteLength))
    }

    /// Discovers the loader service, subscribes to its notify characteristic and waits 0.5 s.
    func prepare() async throws {
        do {
            guard let found = try await link.discover(
                service: Self.serviceUUID,
                characteristics: [Self.writeUUID, Self.notifyUUID],
                timeout: Self.discoveryTimeout
            ), found.contains(Self.writeUUID), found.contains(Self.notifyUUID) else {
                throw BleOtaError.serviceMissing
            }
            try await link.subscribe(Self.notifyUUID, indicate: false)
        } catch let error as FirmwareBleError {
            throw BleOtaError.connectionLost(error.localizedDescription)
        }
        try await sleep(Self.subscribeSettle)
        AppLogger.shared.log("[OTA/BLE] Service ready, write payload \(link.maxWriteLength) bytes")
    }

    /// Sends `OTA <size> <sha256>\n` as with-response writes split to the write length, then waits up to
    /// 60 s through `ERASING` for `OK`.
    func start(size: Int, sha256: Data, onErasing: () async -> Void) async throws {
        let command = Data(UnifiedOta.startCommand(size: size, sha256: sha256).utf8)
        AppLogger.shared.log("[OTA/BLE] > \(String(decoding: command, as: UTF8.self).trimmingCharacters(in: .newlines))")
        let maximum = max(1, link.maxWriteLength)
        var offset = 0
        while offset < command.count {
            let end = min(offset + maximum, command.count)
            try await write(command.subdata(in: offset..<end), withResponse: true)
            offset = end
        }

        while true {
            let line = try await receiveLine(timeout: Self.erasingTimeout)
            switch UnifiedOta.parse(line: line) {
            case .ok:
                return
            case .erasing:
                await onErasing()
            case .error(let message) where message.localizedCaseInsensitiveContains("Hash Rejected"):
                throw WifiOtaError.hashRejected
            case .error(let message):
                throw WifiOtaError.loaderError(message)
            case .ack, .unknown:
                AppLogger.shared.log("[OTA/BLE] Unexpected handshake response: \(line)")
            }
        }
    }

    /// Streams the image: per chunk exactly one write without response, then exactly one notification —
    /// `ACK`, or `OK` for the last chunk. An `OK` earlier is an error; without a terminal `OK` after the
    /// last `ACK` the loader's verdict is awaited for 10 s.
    func stream(_ firmware: Data, progress: (Double) async -> Void) async throws {
        guard !firmware.isEmpty else { throw WifiOtaError.emptyImage }
        let chunk = chunkSize
        AppLogger.shared.log("[OTA/BLE] Streaming \(firmware.count) bytes in \(chunk)-byte writes")
        var sent = 0
        while sent < firmware.count {
            try Task.checkCancellation()
            if link.isDisconnected {
                throw BleOtaError.connectionLost("\(sent)/\(firmware.count)")
            }
            let count = min(chunk, firmware.count - sent)
            let isLast = sent + count >= firmware.count
            try await write(
                firmware.subdata(in: (firmware.startIndex + sent)..<(firmware.startIndex + sent + count)),
                withResponse: false
            )

            let line = try await receiveLine(timeout: Self.ackTimeout)
            switch UnifiedOta.parse(line: line) {
            case .ack:
                break
            case .ok:
                guard isLast else { throw BleOtaError.okBeforeLastChunk }
                await progress(1)
                return
            case .error(let message):
                throw Self.transferError(message)
            case .erasing, .unknown:
                throw WifiOtaError.unexpectedResponse(line)
            }
            sent += count
            await progress(Double(sent) / Double(firmware.count))
        }

        // Every chunk was ACKed but no terminal OK yet — wait for the loader's verification verdict.
        let line = try await receiveLine(timeout: Self.verificationTimeout)
        switch UnifiedOta.parse(line: line) {
        case .ok:
            return
        case .error(let message):
            throw Self.transferError(message)
        case .ack, .erasing, .unknown:
            throw WifiOtaError.unexpectedResponse(line)
        }
    }

    private static func transferError(_ message: String) -> WifiOtaError {
        message.localizedCaseInsensitiveContains("Hash Mismatch") ? .verificationFailed : .loaderError(message)
    }

    private func write(_ data: Data, withResponse: Bool) async throws {
        do {
            try await link.write(data, to: Self.writeUUID, withResponse: withResponse, timeout: Self.writeTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BleOtaError.writeFailed(error.localizedDescription)
        }
    }

    private func receiveLine(timeout: Duration) async throws -> String {
        let data: Data?
        do {
            data = try await link.receive(from: Self.notifyUUID, timeout: timeout)
        } catch is FirmwareBleError {
            throw BleOtaError.connectionLost("waiting for a response")
        }
        guard let data else { throw BleOtaError.timeout("\(timeout)") }
        let text = String(decoding: data, as: UTF8.self)
        AppLogger.shared.log("[OTA/BLE] < \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        return text
    }
}
