import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/Dfu/SecureDfuTransport.cs

/// Nordic Secure DFU (SDK 12+): object-based transfer with CRC-32 checkpoints and resume.
/// SET_PRN 0 → init packet as COMMAND object → SET_PRN 10 → firmware as DATA objects
/// (SELECT → CREATE → packets → CALCULATE_CHECKSUM → EXECUTE per object).
final class SecureDfuTransport: DfuTransport {
    static let discoveryTimeout: Duration = .seconds(15)
    static let commandTimeout: Duration = .seconds(30)
    static let packetWriteTimeout: Duration = .seconds(15)
    static let abortWriteTimeout: Duration = .seconds(2)
    static let firstChunkDelay: Duration = .milliseconds(400)
    static let retryDelay: Duration = .seconds(2)
    static let subscribeSettle: Duration = .milliseconds(500)
    static let prnInterval = 10
    static let objectRetryCount = 3
    static let defaultMaxObjectSize = 4096

    let link: any DfuGattLink
    private let sleep: (Duration) async throws -> Void

    init(link: any DfuGattLink, sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.link = link
        self.sleep = sleep
    }

    var isLowSpeedTransfer: Bool { link.maxWriteLength <= 20 }

    // MARK: Prepare

    func prepare() async throws {
        do {
            guard let found = try await link.discover(
                service: SecureDfuUuids.service,
                characteristics: [SecureDfuUuids.controlPoint, SecureDfuUuids.packet],
                timeout: Self.discoveryTimeout
            ) else {
                throw DfuError.connection("Secure DFU service (FE59) not exposed by the bootloader")
            }
            guard found.contains(SecureDfuUuids.controlPoint), found.contains(SecureDfuUuids.packet) else {
                throw DfuError.connection("Secure DFU characteristics missing")
            }
            try await link.subscribe(SecureDfuUuids.controlPoint, indicate: false)
            try await sleep(Self.subscribeSettle)
        } catch let error as FirmwareBleError {
            throw DfuError.connection(error.localizedDescription)
        }
        AppLogger.shared.log("[DFU/Secure] Prepared, payload \(link.maxWriteLength) bytes")
    }

    // MARK: Transfer

    func transfer(
        initPacket: Data,
        firmware: Data,
        phase: (FirmwareTransferPhase) async -> Void,
        progress: (Double) async -> Void
    ) async throws {
        AppLogger.shared.log("[DFU/Secure] Init packet \(initPacket.count) B, firmware \(firmware.count) B")
        await phase(.sendingInitPacket)
        try await setPrn(0)
        try await transferObjectWithRetry(type: SecureDfuObjectType.command, data: initPacket, prn: 0, progress: { _ in })
        AppLogger.shared.log("[DFU/Secure] Init packet accepted")

        await phase(.uploading(0))
        try await setPrn(Self.prnInterval)
        try await transferObjectWithRetry(type: SecureDfuObjectType.data, data: firmware, prn: Self.prnInterval, progress: progress)
        AppLogger.shared.log("[DFU/Secure] Firmware transferred and executed; bootloader activates the image")
    }

    func abort() async {
        guard !link.isDisconnected else { return }
        do {
            try await link.write(
                Data([SecureDfuOpcode.abort]),
                to: SecureDfuUuids.controlPoint,
                withResponse: true,
                timeout: Self.abortWriteTimeout
            )
            AppLogger.shared.log("[DFU/Secure] ABORT sent")
        } catch {
            AppLogger.shared.log("[DFU/Secure] ABORT failed (device may be gone): \(error.localizedDescription)")
        }
    }

    // MARK: Object transfer

    private func transferObjectWithRetry(
        type: UInt8,
        data: Data,
        prn: Int,
        progress: (Double) async -> Void
    ) async throws {
        var last: Error?
        for attempt in 1...Self.objectRetryCount {
            do {
                try await transferObject(type: type, data: data, prn: prn, progress: progress)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DfuError where error.isConnectionError {
                throw error
            } catch {
                last = error
                AppLogger.shared.log("[DFU/Secure] Object transfer failed (attempt \(attempt)/\(Self.objectRetryCount)): \(error.localizedDescription)")
                if link.isDisconnected {
                    throw DfuError.connection("Bluetooth link dropped during object transfer: \(error.localizedDescription)")
                }
                if attempt < Self.objectRetryCount { try await sleep(Self.retryDelay) }
            }
        }
        throw last ?? DfuError.failed("Object transfer failed")
    }

    private func transferObject(
        type: UInt8,
        data: Data,
        prn: Int,
        progress: (Double) async -> Void
    ) async throws {
        var crcs = DfuPrefixCrc(data)
        let select = try await sendSelect(type: type)
        let maxObject = select.maxSize > 0 ? select.maxSize : Self.defaultMaxObjectSize
        let total = data.count
        var offset = 0
        var firstChunk = true
        var currentPrn = prn

        // Resume: the bootloader reports how much of this object type it already holds and the CRC up to there.
        if select.offset > 0, select.offset <= total {
            let expected = crcs.crc(upTo: select.offset)
            if expected == select.crc32 {
                let executed = maxObject * (select.offset / maxObject)
                let pending = select.offset - executed
                if select.offset == total {
                    AppLogger.shared.log("[DFU/Secure] Device already holds all \(total) bytes (CRC ok) — executing")
                    try await sendExecute()
                    await progress(1)
                    return
                }
                if pending == 0, executed > 0 {
                    AppLogger.shared.log("[DFU/Secure] Resuming at object boundary \(executed); executing last object")
                    do {
                        try await sendExecute()
                    } catch DfuError.protocolError(_, let result, _) where result == SecureDfuResult.operationNotPermitted {
                        // Already executed.
                    }
                    offset = executed
                    firstChunk = false
                } else if pending > 0 {
                    AppLogger.shared.log("[DFU/Secure] Resuming at \(executed) (partial object of \(pending) bytes is re-sent)")
                    offset = executed
                    firstChunk = false
                }
            } else {
                AppLogger.shared.log("[DFU/Secure] Offset \(select.offset) CRC mismatch — restarting object from 0")
            }
        }

        while offset < total {
            let size = min(maxObject, total - offset)
            try await sendCreate(type: type, size: size)
            if firstChunk {
                try await sleep(Self.firstChunkDelay)  // older bootloaders need time to prepare flash after CREATE
                firstChunk = false
            }
            let end = offset + size
            try await writePackets(data, from: offset, until: end, prn: currentPrn, crcs: &crcs)

            let checksum = try await sendCalculateChecksum()
            let expected = crcs.crc(upTo: end)
            if checksum.offset < end {
                // Packets were lost in the stack: verify what arrived, then resend the rest with PRN = 1.
                AppLogger.shared.log("[DFU/Secure] \(end - checksum.offset) bytes lost (device at \(checksum.offset), sent to \(end)); tightening PRN and resending")
                // Not in the Windows port: bytes of already executed objects must never be resent into this one.
                guard checksum.offset >= offset else {
                    throw DfuError.failed("Device offset \(checksum.offset) is before the current object")
                }
                let partial = crcs.crc(upTo: checksum.offset)
                guard checksum.crc32 == partial else { throw DfuError.checksum(expected: partial, actual: checksum.crc32) }
                // Not in the Windows port: the device is told about PRN 1 too. Otherwise the host waits for a
                // receipt after every packet while the device still answers every `prn` packets (stall).
                if currentPrn != 1 { try await setPrn(1) }
                currentPrn = 1
                try await writePackets(data, from: checksum.offset, until: end, prn: currentPrn, crcs: &crcs)
                let recheck = try await sendCalculateChecksum()
                let expectedAgain = crcs.crc(upTo: end)
                guard recheck.offset == end, recheck.crc32 == expectedAgain else {
                    throw DfuError.failed(String(
                        format: "Recovery after lost bytes failed: offset %d/%d crc 0x%08X/0x%08X",
                        recheck.offset, end, recheck.crc32, expectedAgain
                    ))
                }
            } else if checksum.offset != end {
                throw DfuError.failed("Offset mismatch after object: expected \(end), got \(checksum.offset)")
            } else if checksum.crc32 != expected {
                throw DfuError.checksum(expected: expected, actual: checksum.crc32)
            }

            do {
                try await sendExecute()
            } catch DfuError.protocolError(_, let result, _) where result == SecureDfuResult.invalidObject && end >= total {
                AppLogger.shared.log("[DFU/Secure] EXECUTE returned INVALID_OBJECT on the final object — retrying once")
                try await sleep(Self.retryDelay)
                try await sendExecute()
            }

            offset = end
            await progress(Double(offset) / Double(total))
        }
    }

    private func writePackets(_ data: Data, from start: Int, until end: Int, prn: Int, crcs: inout DfuPrefixCrc) async throws {
        let mtu = max(1, link.maxWriteLength)
        var position = start
        var sincePrn = 0
        while position < end {
            try Task.checkCancellation()
            if link.isDisconnected { throw DfuError.midStreamDisconnect(sent: position, total: end) }
            let chunkEnd = min(position + mtu, end)
            do {
                try await link.write(
                    data.subdata(in: (data.startIndex + position)..<(data.startIndex + chunkEnd)),
                    to: SecureDfuUuids.packet,
                    withResponse: false,
                    timeout: Self.packetWriteTimeout
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if link.isDisconnected { throw DfuError.midStreamDisconnect(sent: position, total: end) }
                throw DfuError.failed("Packet write failed at \(position): \(error.localizedDescription)")
            }
            position = chunkEnd
            sincePrn += 1
            if prn > 0, sincePrn >= prn, position < end {
                let response = try await awaitResponse(opcode: SecureDfuOpcode.calculateChecksum, timeout: Self.commandTimeout)
                if case .checksum(let offset, let crc) = response {
                    let expected = crcs.crc(upTo: position)
                    if offset != position || crc != expected { throw DfuError.checksum(expected: expected, actual: crc) }
                }
                sincePrn = 0
            }
        }
    }

    // MARK: Control point commands

    private func sendCommand(_ payload: Data) async throws -> SecureDfuResponse {
        do {
            try await link.write(payload, to: SecureDfuUuids.controlPoint, withResponse: true, timeout: Self.commandTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if link.isDisconnected { throw DfuError.connection("Bluetooth link dropped during a DFU command") }
            throw DfuError.failed("Control point write failed: \(error.localizedDescription)")
        }
        return try await awaitResponse(opcode: payload.first ?? 0, timeout: Self.commandTimeout)
    }

    /// Next control-point answer for `opcode`. Not in the Windows port: an answer carrying a different
    /// opcode is a stray (e.g. a packet-receipt checksum that arrived right at the end of an object,
    /// formatted exactly like a CALCULATE_CHECKSUM answer) and is skipped instead of being taken as the
    /// answer to the next command.
    private func awaitResponse(opcode: UInt8, timeout: Duration) async throws -> SecureDfuResponse {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw DfuError.timeout("DFU control point, \(timeout)") }
            let data: Data?
            do {
                data = try await link.receive(from: SecureDfuUuids.controlPoint, timeout: remaining)
            } catch is FirmwareBleError {
                throw DfuError.connection("Bluetooth link dropped while waiting for the control point")
            }
            guard let data else { throw DfuError.timeout("DFU control point, \(timeout)") }
            let response = SecureDfuResponse.parse(data)
            if case .unknown = response {
                AppLogger.shared.log("[DFU/Secure] Unknown notification \(response.logDescription)")
                return response
            }
            if let answered = response.opcode, answered != opcode {
                AppLogger.shared.log(String(format: "[DFU/Secure] Skipping stray answer while waiting for 0x%02X: ", opcode) + response.logDescription)
                continue
            }
            return response
        }
    }

    private func setPrn(_ value: Int) async throws {
        let response = try await sendCommand(Data([SecureDfuOpcode.setPrn, UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]))
        try Self.requireSuccess(response, expected: SecureDfuOpcode.setPrn)
    }

    private func sendSelect(type: UInt8) async throws -> (maxSize: Int, offset: Int, crc32: UInt32) {
        let response = try await sendCommand(Data([SecureDfuOpcode.select, type]))
        switch response {
        case .select(let maxSize, let offset, let crc32):
            return (maxSize, offset, crc32)
        case .failure(let opcode, let result, _):
            throw DfuError.protocolError(opcode: opcode, result: result, detail: response.logDescription)
        default:
            throw DfuError.failed("Unexpected response to SELECT: \(response.logDescription)")
        }
    }

    private func sendCreate(type: UInt8, size: Int) async throws {
        let payload = Data([SecureDfuOpcode.create, type]) + DfuBytes.uint32LE(UInt32(size))
        try Self.requireSuccess(try await sendCommand(payload), expected: SecureDfuOpcode.create)
    }

    private func sendCalculateChecksum() async throws -> (offset: Int, crc32: UInt32) {
        let response = try await sendCommand(Data([SecureDfuOpcode.calculateChecksum]))
        switch response {
        case .checksum(let offset, let crc32):
            return (offset, crc32)
        case .failure(let opcode, let result, _):
            throw DfuError.protocolError(opcode: opcode, result: result, detail: response.logDescription)
        default:
            throw DfuError.failed("Unexpected response to CALCULATE_CHECKSUM: \(response.logDescription)")
        }
    }

    private func sendExecute() async throws {
        try Self.requireSuccess(try await sendCommand(Data([SecureDfuOpcode.execute])), expected: SecureDfuOpcode.execute)
    }

    private static func requireSuccess(_ response: SecureDfuResponse, expected: UInt8) throws {
        switch response {
        case .success(let opcode) where opcode == expected:
            return
        case .success(let opcode):
            throw DfuError.failed(String(format: "Response opcode mismatch: expected 0x%02X, got 0x%02X", expected, opcode))
        case .failure(let opcode, let result, _):
            throw DfuError.protocolError(opcode: opcode, result: result, detail: response.logDescription)
        default:
            throw DfuError.failed(String(format: "Unexpected response for opcode 0x%02X: ", expected) + response.logDescription)
        }
    }
}
