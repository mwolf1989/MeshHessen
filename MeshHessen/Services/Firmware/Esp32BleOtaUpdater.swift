import CryptoKit
import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/Esp32OtaUpdater.cs (RunBleAsync)

/// ESP32 Unified OTA over Bluetooth: SHA-256 → `ota_request(.otaBle)` → wait for the firmware's answer
/// (must say "BLE") → release the mesh link → wait 5 s for the reboot → find and connect the loader
/// (up to 5 attempts) → `OTA <size> <sha>` → stream with one ACK per chunk → final `OK`. The loader
/// verifies the hash before it switches partitions, so an interrupted transfer keeps the old firmware.
enum Esp32BleOtaUpdater {
    static let answerTimeout: Duration = .seconds(6)
    static let releaseDelay: Duration = .seconds(1)
    static let rebootDelay: Duration = .seconds(5)
    static let connectAttempts = 5
    static let retryDelay: Duration = .seconds(2)
    /// Loader scan: 2 × 10 s, 1 s apart.
    static let scanAttempts = 2
    static let scanTimeout: Duration = .seconds(10)
    static let scanRetryDelay: Duration = .seconds(1)

    /// What the updater needs from the app; closures so tests can script every side.
    struct Dependencies {
        /// `AdminMessage.ota_request(mode: .otaBle, hash:)`; false when it could not be sent.
        var sendOtaRequest: @MainActor (Data) async -> Bool
        /// Installs (or with nil removes) the receiver of every ClientNotification text.
        var setNotificationHandler: @MainActor (((String) -> Void)?) -> Void
        /// The device was (possibly) told to reboot into its loader: from here on a cancel must not end
        /// update mode early (no auto-reconnect against a rebooting device).
        var markRebootRequested: @MainActor () -> Void
        /// Disconnects from the device without auto-reconnect.
        var releaseMeshLink: @MainActor () async -> Void
        /// Scans for the loader (service UUID / known peripheral) and connects; one attempt.
        var connectLoader: () async throws -> any DfuGattLink
        var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var answerTimeout: Duration = Esp32BleOtaUpdater.answerTimeout
    }

    @MainActor
    static func perform(
        image: Data,
        dependencies: Dependencies,
        progress: @escaping @MainActor (FirmwareTransferPhase) -> Void,
        log: @escaping @MainActor (String) -> Void
    ) async throws {
        guard !image.isEmpty else { throw WifiOtaError.emptyImage }
        let sha256 = Data(SHA256.hash(data: image))

        // 1. Ask the firmware to reboot into the loader and wait for its answer.
        progress(.requestingOta)
        final class AnswerBox { var value: Esp32WifiOtaUpdater.OtaRequestAnswer? }
        let answer = AnswerBox()
        dependencies.setNotificationHandler { message in
            if answer.value == nil, let classified = Esp32WifiOtaUpdater.classifyNotification(message, mode: .ble) {
                answer.value = classified
            }
        }
        defer { dependencies.setNotificationHandler(nil) }
        guard await dependencies.sendOtaRequest(sha256) else { throw WifiOtaError.otaRequestNotSent }

        do {
            let deadline = ContinuousClock.now.advanced(by: dependencies.answerTimeout)
            while answer.value == nil, ContinuousClock.now < deadline {
                try Task.checkCancellation()
                try await dependencies.sleep(.milliseconds(100))
            }
        } catch {
            // Cancelled while the answer was pending: the device may already be rebooting.
            dependencies.markRebootRequested()
            throw error
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
        dependencies.markRebootRequested()

        // 2. Release the mesh connection so the loader's GATT service is reachable.
        progress(.disconnecting)
        await dependencies.releaseMeshLink()
        try await dependencies.sleep(releaseDelay)

        // 3. Wait for the reboot into the loader.
        progress(.waitingForReboot)
        try await dependencies.sleep(rebootDelay)

        // 4. Find and connect the loader, with retries.
        var transport: BleOtaTransport?
        var lastError = ""
        for attempt in 1...connectAttempts {
            try Task.checkCancellation()
            progress(.connecting(attempt: attempt, of: connectAttempts))
            var link: (any DfuGattLink)?
            do {
                let opened = try await dependencies.connectLoader()
                link = opened
                let candidate = BleOtaTransport(link: opened, sleep: dependencies.sleep)
                try await candidate.prepare()
                transport = candidate
                break
            } catch is CancellationError {
                if let link { await closeDetached(link) }
                throw CancellationError()
            } catch {
                if let link { await closeDetached(link) }
                lastError = error.localizedDescription
                AppLogger.shared.log("[OTA/BLE] Connect attempt \(attempt)/\(connectAttempts) failed: \(lastError)")
                if attempt < connectAttempts { try await dependencies.sleep(retryDelay) }
            }
        }
        guard let transport else {
            throw BleOtaError.connectFailed(attempts: connectAttempts, reason: lastError)
        }

        // 5. Handshake, stream, verification.
        do {
            progress(.startingOta)
            try await transport.start(size: image.count, sha256: sha256) { progress(.erasing) }
            progress(.uploading(0))
            try await transport.stream(image) { progress(.uploading($0)) }
            progress(.validating)
            log(String(localized: "Firmware transferred and verified by the OTA loader."))
            await closeDetached(transport.link)
        } catch {
            await closeDetached(transport.link)
            throw error
        }
    }

    /// Closes a link even when the calling task is cancelled.
    static func closeDetached(_ link: any DfuGattLink) async {
        let box = UncheckedLink(link: link)
        await Task { await box.link.disconnect() }.value
    }
}

/// Carries a non-Sendable link into a cleanup task; the link itself serialises its work.
struct UncheckedLink: @unchecked Sendable {
    let link: any DfuGattLink
}
