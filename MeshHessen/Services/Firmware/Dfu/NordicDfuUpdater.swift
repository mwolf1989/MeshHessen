import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/Dfu/NordicDfuUpdater.cs

/// One advertisement sighting of a device in its bootloader.
struct DfuScanHit: Equatable, Sendable {
    /// CoreBluetooth peripheral identifier (macOS exposes no MAC address).
    let id: UUID
    let name: String?
    let advertisedServices: Set<GattUUID>
    let rssi: Int
}

/// User-facing failures of the Nordic DFU flow (Windows `StrFwErr…` texts).
enum DfuUpdateError: LocalizedError, Equatable {
    case triggerFailed(String)
    case noDfuService
    case bootloaderNotFound
    case startTimedOut
    case staleSession
    case connectFailed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .triggerFailed(let reason):
            String(localized: "DFU mode could not be triggered: \(reason)")
        case .noDfuService:
            String(localized: "The device offers no DFU service (neither Legacy 1530 nor Secure FE59).")
        case .bootloaderNotFound:
            String(localized: "The bootloader was not found over Bluetooth. If the device never entered DFU mode, a stale pairing may block the trigger: remove the device under System Settings → Bluetooth, pair it again and retry.")
        case .startTimedOut:
            String(localized: "The bootloader did not accept the start within 5 minutes; it boots the old firmware by itself. Try again.")
        case .staleSession:
            String(localized: "The bootloader is stuck in an interrupted DFU session and could not be reset. Power-cycle the device and try again.")
        case .connectFailed(let reason):
            String(localized: "Connecting to the bootloader failed: \(reason)")
        case .failed(let reason):
            String(localized: "DFU failed: \(reason) — the device stays in its bootloader; the update can be repeated (recovery mode).")
        }
    }
}

/// Drives an nRF52 Bluetooth firmware update end to end: release the mesh link, trigger the buttonless
/// reboot into the bootloader (Secure FE59 or Legacy 1530 service of the app firmware), find the
/// bootloader, detect its DFU protocol and run the matching transport with bounded retries. Legacy has
/// no resume, so a failed Legacy session is retried whole; a bootloader wedged in a stale session
/// (START → INVALID_STATE) is reset over a fresh connection first.
enum NordicDfuUpdater {
    static let gattReleaseDelay: Duration = .milliseconds(1500)
    static let dfuRebootWait: Duration = .seconds(3)
    static let detectScanAttempts = 3
    static let detectScanTimeout: Duration = .seconds(8)
    static let scanRetryDelay: Duration = .seconds(2)
    static let sessionRetryDelay: Duration = .seconds(2)
    static let resetPrimeWait: Duration = .seconds(4)
    /// The bootloader boots the old application after ~6 minutes idle in DFU; stop retrying before that.
    static let preStartBudget: Duration = .seconds(5 * 60)
    static let connectAttempts = 4
    static let legacySessionAttempts = 3
    static let maxStaleResets = 2
    static let triggerDiscoveryTimeout: Duration = .seconds(15)
    static let triggerWriteTimeout: Duration = .seconds(5)
    static let triggerIndicationWait: Duration = .seconds(3)
    static let enumerationTimeout: Duration = .seconds(15)
    static let settleDelay: Duration = .milliseconds(500)

    enum DfuProtocolKind: Equatable, Sendable {
        case legacy
        case secure
    }

    struct Dependencies {
        /// Disconnects the mesh link without auto-reconnect (the link counts as released afterwards).
        var releaseMeshLink: @MainActor () async -> Void
        /// Connects to the running app firmware (the former mesh peripheral) for the buttonless trigger.
        var connectApp: () async throws -> any DfuGattLink
        /// One scan for a bootloader; nil when nothing matched within the timeout.
        var scanBootloader: (Duration) async throws -> DfuScanHit?
        /// Connects to the bootloader found by the scan.
        var connectBootloader: (DfuScanHit) async throws -> any DfuGattLink
        var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var now: () -> ContinuousClock.Instant = { ContinuousClock.now }
    }

    /// - Parameter alreadyInBootloader: recovery mode — the device already advertises its bootloader, so the
    ///   release and the buttonless trigger are skipped.
    @MainActor
    static func perform(
        initPacket: Data,
        firmware: Data,
        alreadyInBootloader: Bool,
        dependencies: Dependencies,
        progress: @escaping @MainActor (FirmwareTransferPhase) -> Void,
        log: @escaping @MainActor (String) -> Void
    ) async throws {
        guard !firmware.isEmpty else { throw WifiOtaError.emptyImage }

        if !alreadyInBootloader {
            progress(.disconnecting)
            await dependencies.releaseMeshLink()
            try await dependencies.sleep(gattReleaseDelay)

            progress(.triggeringBootloader)
            try await triggerButtonless(dependencies: dependencies)
            try await dependencies.sleep(dfuRebootWait)
        }

        let budgetStart = dependencies.now()
        var started = false

        progress(.searchingBootloader)
        var hit: DfuScanHit?
        for attempt in 1...detectScanAttempts {
            AppLogger.shared.log("[DFU] Scan attempt \(attempt)/\(detectScanAttempts)")
            if let found = try await dependencies.scanBootloader(detectScanTimeout) {
                hit = found
                break
            }
            if attempt < detectScanAttempts { try await dependencies.sleep(scanRetryDelay) }
        }
        guard let hit else { throw DfuUpdateError.bootloaderNotFound }
        log(String(localized: "Bootloader found: \(hit.name ?? hit.id.uuidString)"))

        let kind = try await detectProtocol(hit, dependencies: dependencies)
        AppLogger.shared.log("[DFU] Bootloader \(hit.id) speaks \(kind)")
        log(kind == .legacy ? String(localized: "Bootloader protocol: Legacy DFU") : String(localized: "Bootloader protocol: Secure DFU"))

        // Legacy: whole-session retries; Secure: one session (it resumes internally, object retries inside).
        let attempts = kind == .legacy ? legacySessionAttempts : 1
        var staleResets = 0
        var midStreamSeen = false
        var last: Error?
        var attempt = 1

        while attempt <= attempts {
            if !started, dependencies.now() - budgetStart > preStartBudget {
                throw DfuUpdateError.startTimedOut
            }
            if attempt > 1 { progress(.retryingUpload(attempt: attempt, of: attempts)) }

            var link: (any DfuGattLink)?
            var transport: (any DfuTransport)?
            var failure: Error?
            do {
                let connected = try await connectWithRetry(
                    hit: hit,
                    kind: kind,
                    prn: midStreamSeen ? 5 : 10,
                    dependencies: dependencies,
                    progress: progress
                )
                link = connected.link
                transport = connected.transport
                try await connected.transport.transfer(
                    initPacket: initPacket,
                    firmware: firmware,
                    phase: { phase in
                        if phase != .preparingFlash { started = true }
                        progress(phase)
                    },
                    progress: { fraction in
                        started = true
                        progress(.uploading(fraction))
                    }
                )
                progress(.validating)
                await Esp32BleOtaUpdater.closeDetached(connected.link)
                return
            } catch {
                failure = error
            }

            // No abort after a stale answer (some bootloaders wedge) or a dropped link (nothing to talk to).
            // A cancel sends ABORT/RESET too, so a fresh session can start without a power cycle.
            if let transport, !isStaleOrDrop(failure) {
                let box = UncheckedTransport(transport: transport)
                await Task { await box.transport.abort() }.value
            }
            if let link { await Esp32BleOtaUpdater.closeDetached(link) }

            switch failure {
            case is CancellationError:
                throw CancellationError()
            case let error as DfuError where error == .staleSession:
                staleResets += 1
                if staleResets > maxStaleResets { throw DfuUpdateError.staleSession }
                AppLogger.shared.log("[DFU] Stale session — reset-priming the bootloader (\(staleResets)/\(maxStaleResets))")
                log(String(localized: "The bootloader holds an interrupted session — resetting it."))
                try await resetStaleBootloader(hit: hit, kind: kind, dependencies: dependencies)
                continue  // a cleanup cycle never tried to upload: same attempt number again
            case let error as DfuError:
                last = error
                if case .midStreamDisconnect(let sent, let total) = error {
                    midStreamSeen = true
                    AppLogger.shared.log("[DFU] Mid-stream disconnect at \(sent)/\(total); next attempt uses the recovery profile")
                } else {
                    AppLogger.shared.log("[DFU] Upload attempt \(attempt)/\(attempts) failed: \(error.localizedDescription)")
                }
            default:
                last = failure
                AppLogger.shared.log("[DFU] Upload attempt \(attempt)/\(attempts) failed: \(failure?.localizedDescription ?? "?")")
            }
            if attempt < attempts { try await dependencies.sleep(sessionRetryDelay) }
            attempt += 1
        }

        switch last {
        case let error as DfuError where error.isConnectionError:
            throw DfuUpdateError.connectFailed(error.localizedDescription)
        case let error?:
            throw DfuUpdateError.failed(error.localizedDescription)
        case nil:
            throw DfuUpdateError.failed("no attempt ran")
        }
    }

    private static func isStaleOrDrop(_ error: Error?) -> Bool {
        guard let error = error as? DfuError else { return false }
        switch error {
        case .staleSession, .midStreamDisconnect: return true
        default: return false
        }
    }

    // MARK: Buttonless trigger

    /// Writes the buttonless trigger to the app firmware's DFU helper service (Secure FE59 first, then
    /// Legacy 1530 — Meshtastic's default build exposes the latter). The device reboots and drops the
    /// link, so a write that never completes is the normal success path; the bootloader scan is the real
    /// confirmation.
    static func triggerButtonless(dependencies: Dependencies) async throws {
        let link: any DfuGattLink
        do {
            link = try await dependencies.connectApp()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DfuUpdateError.triggerFailed(error.localizedDescription)
        }
        do {
            try await writeTrigger(link: link, dependencies: dependencies)
            await Esp32BleOtaUpdater.closeDetached(link)
        } catch {
            await Esp32BleOtaUpdater.closeDetached(link)
            throw error
        }
    }

    private static func writeTrigger(link: any DfuGattLink, dependencies: Dependencies) async throws {
        do {
            if let secure = try await link.discover(
                service: SecureDfuUuids.service,
                characteristics: [SecureDfuUuids.buttonlessNoBonds],
                timeout: triggerDiscoveryTimeout
            ) {
                guard secure.contains(SecureDfuUuids.buttonlessNoBonds) else {
                    throw DfuUpdateError.triggerFailed("Secure buttonless characteristic missing")
                }
                try await link.subscribe(SecureDfuUuids.buttonlessNoBonds, indicate: true)
                try await dependencies.sleep(settleDelay)
                AppLogger.shared.log("[DFU] Writing Secure buttonless trigger (0x01)")
                try await writeIgnoringReboot(link, Data([0x01]), to: SecureDfuUuids.buttonlessNoBonds)
                if let response = try? await link.receive(from: SecureDfuUuids.buttonlessNoBonds, timeout: triggerIndicationWait) {
                    AppLogger.shared.log("[DFU] Buttonless indication \(DfuBytes.hex(response))")
                }
                return
            }
            if let legacy = try await link.discover(
                service: LegacyDfuUuids.service,
                characteristics: [LegacyDfuUuids.controlPoint],
                timeout: triggerDiscoveryTimeout
            ) {
                guard legacy.contains(LegacyDfuUuids.controlPoint) else {
                    throw DfuUpdateError.triggerFailed("Legacy DFU control point missing")
                }
                try await link.subscribe(LegacyDfuUuids.controlPoint, indicate: false)
                try await dependencies.sleep(settleDelay)
                AppLogger.shared.log("[DFU] Writing Legacy buttonless trigger (0x01 0x04)")
                try await writeIgnoringReboot(
                    link,
                    Data([LegacyDfuOpcode.startDfu, LegacyDfuOpcode.imageTypeApplication]),
                    to: LegacyDfuUuids.controlPoint
                )
                try await dependencies.sleep(settleDelay)
                return
            }
        } catch let error as FirmwareBleError {
            throw DfuUpdateError.triggerFailed(error.localizedDescription)
        }
        throw DfuUpdateError.noDfuService
    }

    private static func writeIgnoringReboot(_ link: any DfuGattLink, _ payload: Data, to characteristic: GattUUID) async throws {
        do {
            try await link.write(payload, to: characteristic, withResponse: true, timeout: triggerWriteTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLogger.shared.log("[DFU] Buttonless write did not ACK (\(error.localizedDescription)) — expected when the device reboots")
        }
    }

    // MARK: Detection and connection

    static func detectProtocol(_ hit: DfuScanHit, dependencies: Dependencies) async throws -> DfuProtocolKind {
        if hit.advertisedServices.contains(LegacyDfuUuids.service) { return .legacy }
        if hit.advertisedServices.contains(SecureDfuUuids.service) { return .secure }

        // The advertisement carried no DFU UUID (or the scan response was missed) — ask the GATT table.
        AppLogger.shared.log("[DFU] No DFU UUID in advertisement — enumerating GATT services")
        let services: [GattUUID]
        do {
            let link = try await dependencies.connectBootloader(hit)
            do {
                services = try await link.listServices(timeout: enumerationTimeout)
                await Esp32BleOtaUpdater.closeDetached(link)
            } catch {
                await Esp32BleOtaUpdater.closeDetached(link)
                throw error
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLogger.shared.log("[DFU] Service enumeration failed: \(error.localizedDescription) — assuming Legacy")
            return .legacy
        }
        AppLogger.shared.log("[DFU] Services: \(services.map(\.value).joined(separator: ", "))")
        if services.contains(LegacyDfuUuids.service) { return .legacy }
        if services.contains(SecureDfuUuids.service) { return .secure }
        throw DfuUpdateError.noDfuService
    }

    static func makeTransport(
        kind: DfuProtocolKind,
        link: any DfuGattLink,
        prn: Int,
        sleep: @escaping (Duration) async throws -> Void
    ) -> any DfuTransport {
        switch kind {
        case .legacy: LegacyDfuTransport(link: link, prnInterval: prn, sleep: sleep)
        case .secure: SecureDfuTransport(link: link, sleep: sleep)
        }
    }

    /// Up to 4 connects; a `DfuError` that is not a connection error (e.g. bootloader too old) is final.
    @MainActor
    private static func connectWithRetry(
        hit: DfuScanHit,
        kind: DfuProtocolKind,
        prn: Int,
        dependencies: Dependencies,
        progress: @MainActor (FirmwareTransferPhase) -> Void
    ) async throws -> (link: any DfuGattLink, transport: any DfuTransport) {
        var last: Error?
        for attempt in 1...connectAttempts {
            progress(.connectingBootloader(attempt: attempt, of: connectAttempts))
            var link: (any DfuGattLink)?
            do {
                let opened = try await dependencies.connectBootloader(hit)
                link = opened
                let transport = makeTransport(kind: kind, link: opened, prn: prn, sleep: dependencies.sleep)
                try await transport.prepare()
                return (opened, transport)
            } catch is CancellationError {
                if let link { await Esp32BleOtaUpdater.closeDetached(link) }
                throw CancellationError()
            } catch let error as DfuError where !error.isConnectionError {
                if let link { await Esp32BleOtaUpdater.closeDetached(link) }
                throw error
            } catch {
                if let link { await Esp32BleOtaUpdater.closeDetached(link) }
                last = error
                AppLogger.shared.log("[DFU] Connect attempt \(attempt)/\(connectAttempts) failed: \(error.localizedDescription)")
                if attempt < connectAttempts { try await dependencies.sleep(sessionRetryDelay) }
            }
        }
        throw DfuError.connection("Failed to connect to the bootloader after \(connectAttempts) attempts: \(last?.localizedDescription ?? "?")")
    }

    private static func resetStaleBootloader(hit: DfuScanHit, kind: DfuProtocolKind, dependencies: Dependencies) async throws {
        do {
            let link = try await dependencies.connectBootloader(hit)
            let transport = makeTransport(kind: kind, link: link, prn: 10, sleep: dependencies.sleep)
            do {
                try await transport.prepare()
                await transport.abort()
            } catch is CancellationError {
                await Esp32BleOtaUpdater.closeDetached(link)
                throw CancellationError()
            } catch {
                AppLogger.shared.log("[DFU] Reset-prime prepare failed: \(error.localizedDescription)")
            }
            await Esp32BleOtaUpdater.closeDetached(link)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLogger.shared.log("[DFU] Reset-prime connect failed: \(error.localizedDescription)")
        }
        try await dependencies.sleep(resetPrimeWait)
    }
}

/// Carries a non-Sendable transport into a cleanup task that must run even after a cancel.
struct UncheckedTransport: @unchecked Sendable {
    let transport: any DfuTransport
}
