import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/Dfu/LegacyDfuTransport.cs, IDfuTransport.cs

/// Upload-time surface shared by the Secure (FE59) and Legacy (1530) bootloader transports. Both work on
/// an already connected `DfuGattLink`; `prepare()` discovers and subscribes.
protocol DfuTransport: AnyObject {
    /// True once prepared if the bootloader only takes 20-byte packets (no larger MTU) — slow path.
    var isLowSpeedTransfer: Bool { get }
    /// Discovers the DFU service, subscribes to the control point. Throws `DfuError.connection` for
    /// link problems, other `DfuError`s for a bootloader that cannot be used.
    func prepare() async throws
    /// Uploads init packet + firmware; returns once the bootloader accepted/activated the image.
    func transfer(
        initPacket: Data,
        firmware: Data,
        phase: (FirmwareTransferPhase) async -> Void,
        progress: (Double) async -> Void
    ) async throws
    /// Best-effort ABORT/RESET so a fresh session can start without a power cycle. Never throws.
    func abort() async
}

/// Nordic Legacy DFU (SDK 11 / Adafruit bootloader) — what most nRF52 Meshtastic boards speak, including
/// RAK4631 with the stock or "OTAFIX" bootloader. START_DFU[app] + image sizes → INIT_PARAMS
/// start/bytes/complete → PRN request → RECEIVE_FIRMWARE_IMAGE → stream (receipt every N packets) →
/// VALIDATE → ACTIVATE_AND_RESET. Single-bank bootloaders erase the app region before answering START
/// (30–50 s of silence), hence the long START timeout.
final class LegacyDfuTransport: DfuTransport {
    static let commandTimeout: Duration = .seconds(30)
    static let startResponseTimeout: Duration = .seconds(90)
    static let validateTimeout: Duration = .seconds(60)
    static let packetWriteTimeout: Duration = .seconds(15)
    static let activateWriteTimeout: Duration = .seconds(3)
    static let resetWriteTimeout: Duration = .seconds(1)
    static let discoveryTimeout: Duration = .seconds(15)
    static let readTimeout: Duration = .seconds(5)
    static let subscribeSettle: Duration = .milliseconds(500)

    static let legacyPacketSize = 20
    static let maxHighMtuPacketSize = 244
    static let maxReasonableInitSize = 256
    static let minimumDfuVersion = 5

    let link: any DfuGattLink
    let prnInterval: Int
    private let sleep: (Duration) async throws -> Void
    private(set) var dfuVersion = -1
    private(set) var bootloaderRevision: String?

    /// - Parameter prnInterval: packets between receipt notifications; 10 is Nordic's safe ceiling for
    ///   SDK 11 bootloaders, 5 is used on a retry after a mid-stream drop.
    init(
        link: any DfuGattLink,
        prnInterval: Int = 10,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.link = link
        self.prnInterval = min(max(prnInterval, 1), 10)
        self.sleep = sleep
    }

    var isLowSpeedTransfer: Bool { streamPacketSize <= Self.legacyPacketSize }

    /// Negotiated payload clamped to 20…244, rounded down to a multiple of 4 (the Adafruit bootloader
    /// rejects writes that are not a multiple of 4).
    var streamPacketSize: Int {
        Self.streamPacketSize(maxWriteLength: link.maxWriteLength)
    }

    static func streamPacketSize(maxWriteLength: Int) -> Int {
        let sized = min(max(maxWriteLength, legacyPacketSize), maxHighMtuPacketSize)
        return sized - sized % 4
    }

    // MARK: Prepare

    func prepare() async throws {
        do {
            guard let found = try await link.discover(
                service: LegacyDfuUuids.service,
                characteristics: [LegacyDfuUuids.controlPoint, LegacyDfuUuids.packet, LegacyDfuUuids.version],
                timeout: Self.discoveryTimeout
            ) else {
                throw DfuError.connection("Legacy DFU service (1530) not exposed by the bootloader")
            }
            guard found.contains(LegacyDfuUuids.controlPoint), found.contains(LegacyDfuUuids.packet) else {
                throw DfuError.connection("Legacy DFU characteristics missing")
            }
            try await link.subscribe(LegacyDfuUuids.controlPoint, indicate: false)
            try await sleep(Self.subscribeSettle)

            if found.contains(LegacyDfuUuids.version),
               let value = try await link.read(LegacyDfuUuids.version, timeout: Self.readTimeout), value.count >= 2 {
                dfuVersion = Int(value[value.startIndex]) | Int(value[value.startIndex + 1]) << 8
            }
        } catch let error as FirmwareBleError {
            throw DfuError.connection(error.localizedDescription)
        }
        AppLogger.shared.log("[DFU/Legacy] DFU version characteristic = \(dfuVersion) (-1 = absent)")
        if dfuVersion >= 1, dfuVersion < Self.minimumDfuVersion {
            throw DfuError.failed(String(localized: "Legacy DFU bootloader version \(dfuVersion) is too old (need ≥ \(Self.minimumDfuVersion)) — update the bootloader first."))
        }

        // Bootloader revision from the Device Information service, purely for the log.
        if let found = try? await link.discover(
            service: LegacyDfuUuids.deviceInformationService,
            characteristics: [LegacyDfuUuids.firmwareRevision],
            timeout: Self.readTimeout
        ), found.contains(LegacyDfuUuids.firmwareRevision),
           let bytes = try? await link.read(LegacyDfuUuids.firmwareRevision, timeout: Self.readTimeout) {
            bootloaderRevision = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
        }
        AppLogger.shared.log("[DFU/Legacy] Prepared, bootloader '\(bootloaderRevision ?? "?")', payload \(link.maxWriteLength) bytes")
    }

    // MARK: Transfer

    func transfer(
        initPacket: Data,
        firmware: Data,
        phase: (FirmwareTransferPhase) async -> Void,
        progress: (Double) async -> Void
    ) async throws {
        if initPacket.count > Self.maxReasonableInitSize {
            throw DfuError.failed(String(localized: "The init packet is \(initPacket.count) bytes — this looks like a Secure DFU package; the Legacy bootloader would reject it."))
        }
        AppLogger.shared.log("[DFU/Legacy] Starting upload (init \(initPacket.count) B, firmware \(firmware.count) B, prn \(prnInterval))")

        // 1. START_DFU + image sizes; the bootloader erases the app bank before it answers.
        await phase(.preparingFlash)
        try await writeControl(Data([LegacyDfuOpcode.startDfu, LegacyDfuOpcode.imageTypeApplication]))
        try await writePacket(LegacyDfuPayloads.imageSizes(application: firmware.count))
        let start = try await awaitResponse(timeout: Self.startResponseTimeout)
        if case .failure(_, let status) = start, status == LegacyDfuStatus.invalidState {
            throw DfuError.staleSession
        }
        try Self.requireSuccess(LegacyDfuOpcode.startDfu, start)

        // 2. Init packet bracketed by INIT_PARAMS start/complete.
        await phase(.sendingInitPacket)
        try await writeControl(Data([LegacyDfuOpcode.initDfuParams, LegacyDfuOpcode.initParamsStart]))
        var position = 0
        while position < initPacket.count {
            let end = min(position + Self.legacyPacketSize, initPacket.count)
            try await writePacket(initPacket.subdata(in: (initPacket.startIndex + position)..<(initPacket.startIndex + end)))
            position = end
        }
        try await writeControl(Data([LegacyDfuOpcode.initDfuParams, LegacyDfuOpcode.initParamsComplete]))
        try Self.requireSuccess(LegacyDfuOpcode.initDfuParams, try await awaitResponse(timeout: Self.commandTimeout))

        // 3./4. PRN interval, then RECEIVE_FIRMWARE_IMAGE (neither is answered).
        try await writeControl(LegacyDfuPayloads.prnRequest(prnInterval))
        try await writeControl(Data([LegacyDfuOpcode.receiveFirmwareImage]))

        // 5. Stream.
        await phase(.uploading(0))
        try await stream(firmware, progress: progress)

        // 6.–8. Final receive response, VALIDATE, ACTIVATE_AND_RESET.
        try Self.requireSuccess(LegacyDfuOpcode.receiveFirmwareImage, try await awaitResponse(timeout: Self.validateTimeout))
        await phase(.validating)
        try await writeControl(Data([LegacyDfuOpcode.validate]))
        try Self.requireSuccess(LegacyDfuOpcode.validate, try await awaitResponse(timeout: Self.validateTimeout))
        do {
            try await link.write(
                Data([LegacyDfuOpcode.activateAndReset]),
                to: LegacyDfuUuids.controlPoint,
                withResponse: true,
                timeout: Self.activateWriteTimeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLogger.shared.log("[DFU/Legacy] ACTIVATE write did not ACK (expected — device resets): \(error.localizedDescription)")
        }
        await progress(1)
        AppLogger.shared.log("[DFU/Legacy] Upload complete, device reboots into the new firmware")
    }

    private func stream(_ firmware: Data, progress: (Double) async -> Void) async throws {
        let size = streamPacketSize
        var offset = 0
        var sincePrn = 0
        var lastConfirmed = -1
        AppLogger.shared.log("[DFU/Legacy] Streaming \(firmware.count) bytes with \(size)-byte packets (dfuVersion=\(dfuVersion))")

        while offset < firmware.count {
            try Task.checkCancellation()
            if link.isDisconnected { throw DfuError.midStreamDisconnect(sent: offset, total: firmware.count) }
            let end = min(offset + size, firmware.count)
            do {
                try await link.write(
                    firmware.subdata(in: (firmware.startIndex + offset)..<(firmware.startIndex + end)),
                    to: LegacyDfuUuids.packet,
                    withResponse: false,
                    timeout: Self.packetWriteTimeout
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if link.isDisconnected { throw DfuError.midStreamDisconnect(sent: end, total: firmware.count) }
                throw DfuError.failed("Packet write failed at \(offset)/\(firmware.count): \(error.localizedDescription)")
            }
            offset = end
            sincePrn += 1

            if sincePrn >= prnInterval, offset < firmware.count {
                let receipt = try await awaitPacketReceipt(offset: offset, total: firmware.count)
                guard receipt == UInt32(offset) else {
                    throw DfuError.failed("Packet receipt mismatch: sent \(offset) bytes, device reports \(receipt).")
                }
                lastConfirmed = offset
                sincePrn = 0
                await progress(Double(offset) / Double(firmware.count))
            }
        }
        AppLogger.shared.log("[DFU/Legacy] Streamed \(offset) bytes (last receipt \(lastConfirmed))")
    }

    // MARK: Abort

    func abort() async {
        guard !link.isDisconnected else { return }
        do {
            try await link.write(
                Data([LegacyDfuOpcode.reset]),
                to: LegacyDfuUuids.controlPoint,
                withResponse: true,
                timeout: Self.resetWriteTimeout
            )
            AppLogger.shared.log("[DFU/Legacy] RESET acknowledged")
        } catch {
            AppLogger.shared.log("[DFU/Legacy] RESET not acknowledged (\(error.localizedDescription)) — disconnecting anyway")
        }
    }

    // MARK: GATT helpers

    private func writeControl(_ payload: Data) async throws {
        do {
            try await link.write(payload, to: LegacyDfuUuids.controlPoint, withResponse: true, timeout: Self.commandTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if link.isDisconnected {
                throw DfuError.connection("Bluetooth link dropped during a Legacy DFU command")
            }
            throw DfuError.failed("Control point write failed: \(error.localizedDescription)")
        }
    }

    private func writePacket(_ payload: Data) async throws {
        do {
            try await link.write(payload, to: LegacyDfuUuids.packet, withResponse: false, timeout: Self.packetWriteTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if link.isDisconnected {
                throw DfuError.connection("Bluetooth link dropped during a Legacy DFU packet write")
            }
            throw DfuError.failed("Packet write failed: \(error.localizedDescription)")
        }
    }

    /// Next control-point response, skipping stray packet receipts. A link drop fails fast.
    private func awaitResponse(timeout: Duration) async throws -> LegacyDfuResponse {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw DfuError.timeout("Legacy DFU control point, \(timeout)") }
            let data: Data?
            do {
                data = try await link.receive(from: LegacyDfuUuids.controlPoint, timeout: remaining)
            } catch is FirmwareBleError {
                throw DfuError.connection("Bluetooth link dropped during the DFU handshake — some bootloaders drop the link instead of answering (stale bond?)")
            }
            guard let data else { throw DfuError.timeout("Legacy DFU control point, \(timeout)") }
            let response = LegacyDfuResponse.parse(data)
            AppLogger.shared.log("[DFU/Legacy] < \(response.logDescription)")
            if case .packetReceipt = response { continue }
            return response
        }
    }

    private func awaitPacketReceipt(offset: Int, total: Int) async throws -> UInt32 {
        let deadline = ContinuousClock.now.advanced(by: Self.commandTimeout)
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw DfuError.timeout("packet receipt at offset \(offset)")
            }
            let data: Data?
            do {
                data = try await link.receive(from: LegacyDfuUuids.controlPoint, timeout: remaining)
            } catch is FirmwareBleError {
                throw DfuError.midStreamDisconnect(sent: offset, total: total)
            }
            guard let data else { throw DfuError.timeout("packet receipt at offset \(offset)") }
            switch LegacyDfuResponse.parse(data) {
            case .packetReceipt(let received):
                return received
            case .failure(let opcode, let status):
                throw DfuError.protocolError(
                    opcode: opcode,
                    result: status,
                    detail: LegacyDfuResponse.failure(requestOpcode: opcode, status: status).logDescription
                )
            case .success, .unknown:
                continue
            }
        }
    }

    private static func requireSuccess(_ expected: UInt8, _ response: LegacyDfuResponse) throws {
        switch response {
        case .success(let opcode) where opcode == expected:
            return
        case .success(let opcode):
            throw DfuError.failed(String(format: "Legacy DFU response opcode mismatch: expected 0x%02X, got 0x%02X", expected, opcode))
        case .failure(let opcode, let status):
            throw DfuError.protocolError(opcode: opcode, result: status, detail: response.logDescription)
        case .packetReceipt, .unknown:
            throw DfuError.failed(String(format: "Unexpected Legacy DFU response for opcode 0x%02X: ", expected) + response.logDescription)
        }
    }
}
