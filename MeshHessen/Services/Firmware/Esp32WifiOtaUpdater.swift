import CryptoKit
import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/Esp32OtaUpdater.cs, WifiOtaTransport.cs

/// ESP32 Unified OTA over Wi-Fi: SHA-256 → `ota_request(.otaWifi)` → wait for the firmware's answer →
/// release the mesh link → find the loader (UDP beacon, else the known TCP host) → TCP connect with
/// retries → `OTA <size> <sha>` → stream → final `OK`. The loader verifies the hash before it switches
/// partitions, so a failed or interrupted transfer leaves the old firmware in place.
enum Esp32WifiOtaUpdater {
    static let chunkSize = 1024
    static let interChunkDelay: Duration = .milliseconds(10)
    static let preflightTimeout: Duration = .seconds(6)
    static let releaseDelay: Duration = .seconds(1)
    static let discoveryWindow: Duration = .seconds(20)
    static let knownHostReadinessDelay: Duration = .seconds(8)
    static let connectAttempts = 10
    static let retryDelay: Duration = .seconds(2)
    static let erasingTimeout: Duration = .seconds(60)
    static let verificationTimeout: Duration = .seconds(10)

    /// What the updater needs from the app; closures so tests can script every side.
    struct Dependencies {
        /// `AdminMessage.ota_request(mode: .otaWifi, hash:)`; false when it could not be sent.
        var sendOtaRequest: @MainActor (Data) async -> Bool
        /// Installs (or with nil removes) the receiver of every ClientNotification text.
        var setNotificationHandler: @MainActor (((String) -> Void)?) -> Void
        /// Disconnects from the device without auto-reconnect.
        var releaseMeshLink: @MainActor () async -> Void
        var discoverLoader: (Duration) async -> String?
        var openStream: (String) async throws -> any OtaByteStream
        var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        /// How long to wait for the firmware's answer to `ota_request` (silence counts as consent).
        var answerTimeout: Duration = Esp32WifiOtaUpdater.preflightTimeout
    }

    // MARK: - Firmware answer to ota_request

    enum OtaRequestAnswer: Equatable {
        case confirmed(String)
        case refused(String)
    }

    /// nil for notifications unrelated to OTA; otherwise confirmation ("Rebooting to … WiFi …") or refusal.
    static func classifyNotification(_ message: String) -> OtaRequestAnswer? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"\bOTA\b"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        let confirmed = text.range(of: "Rebooting to", options: [.caseInsensitive, .anchored]) != nil
            && text.range(of: "WiFi", options: .caseInsensitive) != nil
        return confirmed ? .confirmed(text) : .refused(text)
    }

    // MARK: - Full sequence

    /// Steps 1–9. The caller has already put the coordinator into firmware-update mode.
    @MainActor
    static func perform(
        image: Data,
        knownHost: String?,
        dependencies: Dependencies,
        progress: @escaping @MainActor (FirmwareTransferPhase) -> Void,
        log: @escaping @MainActor (String) -> Void
    ) async throws {
        guard !image.isEmpty else { throw WifiOtaError.emptyImage }
        let sha256 = Data(SHA256.hash(data: image))

        // 1–3: ask the firmware to reboot into the loader and wait for its answer.
        progress(.requestingOta)
        final class AnswerBox { var value: OtaRequestAnswer? }
        let answer = AnswerBox()
        dependencies.setNotificationHandler { message in
            if answer.value == nil, let classified = classifyNotification(message) { answer.value = classified }
        }
        defer { dependencies.setNotificationHandler(nil) }
        guard await dependencies.sendOtaRequest(sha256) else { throw WifiOtaError.otaRequestNotSent }

        let deadline = ContinuousClock.now.advanced(by: dependencies.answerTimeout)
        while answer.value == nil, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await dependencies.sleep(.milliseconds(100))
        }
        switch answer.value {
        case .refused(let message):
            log(String(localized: "Firmware refused OTA: \(message)"))
            throw WifiOtaError.otaRefused(message)
        case .confirmed(let message):
            log(String(localized: "Firmware confirmed: \(message)"))
        case nil:
            log(String(localized: "No confirmation from the firmware — continuing (older firmware is silent)."))
        }

        // 4: release the mesh link.
        progress(.disconnecting)
        await dependencies.releaseMeshLink()
        try await dependencies.sleep(releaseDelay)

        // 5: locate the loader.
        progress(.searchingLoader)
        let host: String
        if let ip = await dependencies.discoverLoader(discoveryWindow) {
            log(String(localized: "OTA loader found at \(ip)."))
            host = ip
        } else if let knownHost, !knownHost.isEmpty {
            log(String(localized: "No loader beacon — using the known host \(knownHost)."))
            try await dependencies.sleep(knownHostReadinessDelay)
            host = knownHost
        } else {
            throw WifiOtaError.loaderNotFound
        }
        try Task.checkCancellation()

        // 6: connect with retries.
        var stream: (any OtaByteStream)?
        var lastError = ""
        for attempt in 1...connectAttempts {
            try Task.checkCancellation()
            progress(.connecting(attempt: attempt, of: connectAttempts))
            do {
                stream = try await dependencies.openStream(host)
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error.localizedDescription
                AppLogger.shared.log("[OTA/WiFi] Connect attempt \(attempt)/\(connectAttempts) failed: \(lastError)")
                if attempt < connectAttempts { try await dependencies.sleep(retryDelay) }
            }
        }
        guard let stream else {
            throw WifiOtaError.connectFailed(attempts: connectAttempts, reason: lastError)
        }

        // 7–9: handshake, stream, verification.
        do {
            try await run(stream: stream, image: image, sha256: sha256, sleep: dependencies.sleep) { phase in
                await progress(phase)
            }
            await stream.close()
        } catch {
            await stream.close()
            throw error
        }
    }

    // MARK: - Loader protocol (steps 7–9)

    /// Sends the start command, waits through `ERASING` for `OK`, streams the image in 1024-byte chunks
    /// and waits for the final `OK`. Late `ACK`s are ignored; `ERR Hash Mismatch` is a verification failure.
    static func run(
        stream: any OtaByteStream,
        image: Data,
        sha256: Data? = nil,
        chunkDelay: Duration = interChunkDelay,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        progress: (FirmwareTransferPhase) async -> Void
    ) async throws {
        guard !image.isEmpty else { throw WifiOtaError.emptyImage }
        let hash = sha256 ?? Data(SHA256.hash(data: image))

        await progress(.startingOta)
        let command = UnifiedOta.startCommand(size: image.count, sha256: hash)
        AppLogger.shared.log("[OTA/WiFi] > \(command.trimmingCharacters(in: .newlines))")
        try await stream.send(Data(command.utf8))

        handshake: while true {
            let line = try await stream.readLine(timeout: erasingTimeout)
            switch UnifiedOta.parse(line: line) {
            case .ok:
                break handshake
            case .erasing:
                await progress(.erasing)
            case .error(let message) where message.localizedCaseInsensitiveContains("Hash Rejected"):
                throw WifiOtaError.hashRejected
            case .error(let message):
                throw WifiOtaError.loaderError(message)
            case .ack, .unknown:
                AppLogger.shared.log("[OTA/WiFi] Unexpected handshake response: \(line)")
            }
        }

        await progress(.uploading(0))
        var offset = 0
        while offset < image.count {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, image.count)
            try await stream.send(image.subdata(in: offset..<end))
            offset = end
            await progress(.uploading(Double(offset) / Double(image.count)))
            if offset < image.count { try await sleep(chunkDelay) }
        }
        AppLogger.shared.log("[OTA/WiFi] Streamed \(offset) bytes, waiting for verification")

        await progress(.validating)
        while true {
            let line = try await stream.readLine(timeout: verificationTimeout)
            switch UnifiedOta.parse(line: line) {
            case .ok:
                return
            case .ack:
                continue
            case .error(let message) where message.localizedCaseInsensitiveContains("Hash Mismatch"):
                throw WifiOtaError.verificationFailed
            case .error(let message):
                throw WifiOtaError.loaderError(message)
            case .erasing, .unknown:
                throw WifiOtaError.unexpectedResponse(line)
            }
        }
    }
}
