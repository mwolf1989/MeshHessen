import Foundation

@testable import MeshHessen

/// Scripted GATT link: every write is recorded and handed to `peer`, which plays the device and queues
/// notifications. `receive` returns the next queued notification or — instead of waiting — nil (a
/// timeout). No Bluetooth is involved.
final class FakeDfuLink: DfuGattLink {
    struct Write: Equatable {
        let characteristic: GattUUID
        let data: Data
        let withResponse: Bool
    }

    var maxWriteLength: Int
    var isDisconnected = false
    var services: [GattUUID: Set<GattUUID>]
    var readValues: [GattUUID: Data] = [:]
    private(set) var writes: [Write] = []
    private(set) var subscribed: [GattUUID] = []
    private(set) var queues: [GattUUID: [Data]] = [:]
    private(set) var disconnectCount = 0
    /// Plays the peer: called after each recorded write.
    var peer: ((FakeDfuLink, Write) throws -> Void)?

    init(maxWriteLength: Int = 20, services: [GattUUID: Set<GattUUID>] = [:]) {
        self.maxWriteLength = maxWriteLength
        self.services = services
    }

    func notify(_ characteristic: GattUUID, _ data: Data) {
        queues[characteristic, default: []].append(data)
    }

    func pending(_ characteristic: GattUUID) -> Int { queues[characteristic]?.count ?? 0 }

    func writes(to characteristic: GattUUID) -> [Write] {
        writes.filter { $0.characteristic == characteristic }
    }

    func discover(service: GattUUID, characteristics: [GattUUID], timeout: Duration) async throws -> Set<GattUUID>? {
        if isDisconnected { throw FirmwareBleError.disconnected }
        guard let available = services[service] else { return nil }
        return available.intersection(characteristics)
    }

    func listServices(timeout: Duration) async throws -> [GattUUID] {
        if isDisconnected { throw FirmwareBleError.disconnected }
        return Array(services.keys)
    }

    func subscribe(_ characteristic: GattUUID, indicate: Bool) async throws {
        if isDisconnected { throw FirmwareBleError.disconnected }
        subscribed.append(characteristic)
    }

    func write(_ data: Data, to characteristic: GattUUID, withResponse: Bool, timeout: Duration) async throws {
        if isDisconnected { throw FirmwareBleError.disconnected }
        let write = Write(characteristic: characteristic, data: data, withResponse: withResponse)
        writes.append(write)
        try peer?(self, write)
    }

    func receive(from characteristic: GattUUID, timeout: Duration) async throws -> Data? {
        try Task.checkCancellation()
        if var queue = queues[characteristic], !queue.isEmpty {
            let first = queue.removeFirst()
            queues[characteristic] = queue
            return first
        }
        if isDisconnected { throw FirmwareBleError.disconnected }
        return nil
    }

    func read(_ characteristic: GattUUID, timeout: Duration) async throws -> Data? {
        readValues[characteristic]
    }

    func disconnect() async {
        disconnectCount += 1
        isDisconnected = true
    }
}

// MARK: - Legacy bootloader

/// Plays an Adafruit/SDK 11 legacy bootloader on a `FakeDfuLink`.
final class LegacyBootloaderPeer {
    /// START answers in order; the last one repeats (`0x01` success, `0x02` INVALID_STATE).
    var startStatuses: [UInt8] = [LegacyDfuStatus.success]
    /// Added to every reported receipt (to provoke a mismatch).
    var receiptSkew = 0
    /// Drop the link (and fail the write) at this firmware packet number, once.
    var dropAtPacket: Int?
    /// Cancels the running task at this firmware packet number.
    var cancelAtPacket: Int?

    private(set) var controlWrites: [Data] = []
    private(set) var sizes: Data?
    private(set) var initPacket = Data()
    private(set) var image = Data()
    private(set) var prnRequests: [Int] = []
    private(set) var firmwarePacketSizes: [Int] = []
    private(set) var activated = false
    private(set) var resets = 0

    private var expectSizes = false
    private var inInit = false
    private var receiving = false
    private var total = 0
    private var prn = 0
    private var sincePrn = 0
    private var startIndex = 0

    func makeLink(maxWriteLength: Int = 182, version: Data? = Data([0x08, 0x00])) -> FakeDfuLink {
        let link = FakeDfuLink(
            maxWriteLength: maxWriteLength,
            services: [LegacyDfuUuids.service: [LegacyDfuUuids.controlPoint, LegacyDfuUuids.packet, LegacyDfuUuids.version]]
        )
        if let version { link.readValues[LegacyDfuUuids.version] = version }
        // A new connection starts a new bootloader session.
        expectSizes = false
        inInit = false
        receiving = false
        image = Data()
        firmwarePacketSizes = []
        link.peer = { [unowned self] link, write in try self.handle(link, write) }
        return link
    }

    private func handle(_ link: FakeDfuLink, _ write: FakeDfuLink.Write) throws {
        let bytes = [UInt8](write.data)
        if write.characteristic == LegacyDfuUuids.controlPoint {
            controlWrites.append(write.data)
            switch bytes.first {
            case LegacyDfuOpcode.startDfu:
                expectSizes = true
            case LegacyDfuOpcode.initDfuParams:
                if bytes.count > 1, bytes[1] == LegacyDfuOpcode.initParamsStart {
                    inInit = true
                    initPacket = Data()
                } else {
                    inInit = false
                    link.notify(LegacyDfuUuids.controlPoint, Data([0x10, LegacyDfuOpcode.initDfuParams, 0x01]))
                }
            case LegacyDfuOpcode.packetReceiptNotifReq:
                prn = Int(bytes[1]) | Int(bytes[2]) << 8
                prnRequests.append(prn)
            case LegacyDfuOpcode.receiveFirmwareImage:
                receiving = true
                sincePrn = 0
            case LegacyDfuOpcode.validate:
                link.notify(LegacyDfuUuids.controlPoint, Data([0x10, LegacyDfuOpcode.validate, 0x01]))
            case LegacyDfuOpcode.activateAndReset:
                activated = true
            case LegacyDfuOpcode.reset:
                resets += 1
            default:
                break
            }
            return
        }
        guard write.characteristic == LegacyDfuUuids.packet else { return }
        if expectSizes {
            expectSizes = false
            sizes = write.data
            total = Int(DfuBytes.uint32LE(bytes, 8))
            let status = startStatuses[min(startIndex, startStatuses.count - 1)]
            startIndex += 1
            link.notify(LegacyDfuUuids.controlPoint, Data([0x10, LegacyDfuOpcode.startDfu, status]))
        } else if inInit {
            initPacket.append(write.data)
        } else if receiving {
            firmwarePacketSizes.append(write.data.count)
            if let drop = dropAtPacket, firmwarePacketSizes.count == drop {
                dropAtPacket = nil
                link.isDisconnected = true
                throw FirmwareBleError.disconnected
            }
            if let cancel = cancelAtPacket, firmwarePacketSizes.count == cancel {
                cancelAtPacket = nil
                withUnsafeCurrentTask { $0?.cancel() }
            }
            image.append(write.data)
            sincePrn += 1
            if image.count >= total {
                receiving = false
                link.notify(LegacyDfuUuids.controlPoint, Data([0x10, LegacyDfuOpcode.receiveFirmwareImage, 0x01]))
            } else if prn > 0, sincePrn >= prn {
                sincePrn = 0
                link.notify(LegacyDfuUuids.controlPoint, Data([0x11]) + DfuBytes.uint32LE(UInt32(image.count + receiptSkew)))
            }
        }
    }
}

// MARK: - Secure bootloader

/// Plays a Nordic SDK 12+ secure bootloader (object store, CRC, PRN, execute) on a `FakeDfuLink`.
final class SecureBootloaderPeer {
    var maxObjectSize = 4096
    /// Firmware packet numbers (counted over the whole session) that get lost.
    var dropPackets: Set<Int> = []
    /// Report a wrong CRC for the n-th CALCULATE_CHECKSUM (1-based), once.
    var corruptChecksumNumber: Int?
    /// EXECUTE answers by execute number (1-based, data objects only); missing = success.
    var dataExecuteResults: [Int: UInt8] = [:]

    private(set) var received: [UInt8: Data] = [SecureDfuObjectType.command: Data(), SecureDfuObjectType.data: Data()]
    private(set) var executed: [UInt8: Int] = [:]
    private(set) var createdSizes: [UInt8: [Int]] = [:]
    private(set) var controlOpcodes: [UInt8] = []
    private(set) var aborts = 0
    private(set) var prnValues: [Int] = []
    private var currentType = SecureDfuObjectType.command
    private var prn = 0
    private var sincePrn = 0
    private var packetNumber = 0
    private var checksumNumber = 0
    private var dataExecuteNumber = 0

    /// Bytes the device already holds (resume).
    func preload(type: UInt8, data: Data, executed count: Int) {
        received[type] = data
        executed[type] = count
    }

    func makeLink(maxWriteLength: Int = 100) -> FakeDfuLink {
        let link = FakeDfuLink(
            maxWriteLength: maxWriteLength,
            services: [SecureDfuUuids.service: [SecureDfuUuids.controlPoint, SecureDfuUuids.packet]]
        )
        link.peer = { [unowned self] link, write in self.handle(link, write) }
        return link
    }

    private func answer(_ link: FakeDfuLink, _ opcode: UInt8, _ result: UInt8 = SecureDfuResult.success, _ payload: Data = Data()) {
        link.notify(SecureDfuUuids.controlPoint, Data([SecureDfuOpcode.responseCode, opcode, result]) + payload)
    }

    private func crcPayload(_ type: UInt8, corrupt: Bool = false) -> Data {
        let data = received[type] ?? Data()
        let crc = DfuCrc32.compute(data) ^ (corrupt ? 0xDEAD_BEEF : 0)
        return DfuBytes.uint32LE(UInt32(data.count)) + DfuBytes.uint32LE(crc)
    }

    private func handle(_ link: FakeDfuLink, _ write: FakeDfuLink.Write) {
        let bytes = [UInt8](write.data)
        if write.characteristic == SecureDfuUuids.packet {
            packetNumber += 1
            guard !dropPackets.contains(packetNumber) else { return }
            received[currentType, default: Data()].append(write.data)
            sincePrn += 1
            if prn > 0, sincePrn >= prn {
                sincePrn = 0
                answer(link, SecureDfuOpcode.calculateChecksum, SecureDfuResult.success, crcPayload(currentType))
            }
            return
        }
        guard let opcode = bytes.first else { return }
        controlOpcodes.append(opcode)
        switch opcode {
        case SecureDfuOpcode.setPrn:
            prn = Int(bytes[1]) | Int(bytes[2]) << 8
            sincePrn = 0
            prnValues.append(prn)
            answer(link, opcode)
        case SecureDfuOpcode.select:
            currentType = bytes[1]
            answer(link, opcode, SecureDfuResult.success, DfuBytes.uint32LE(UInt32(maxObjectSize)) + crcPayload(currentType))
        case SecureDfuOpcode.create:
            currentType = bytes[1]
            let size = Int(DfuBytes.uint32LE(bytes, 2))
            createdSizes[currentType, default: []].append(size)
            let keep = executed[currentType] ?? 0
            received[currentType] = (received[currentType] ?? Data()).prefix(keep)
            sincePrn = 0
            answer(link, opcode)
        case SecureDfuOpcode.calculateChecksum:
            checksumNumber += 1
            let corrupt = checksumNumber == corruptChecksumNumber
            answer(link, opcode, SecureDfuResult.success, crcPayload(currentType, corrupt: corrupt))
        case SecureDfuOpcode.execute:
            if currentType == SecureDfuObjectType.data {
                dataExecuteNumber += 1
                if let result = dataExecuteResults[dataExecuteNumber] {
                    answer(link, opcode, result)
                    return
                }
            }
            executed[currentType] = received[currentType]?.count ?? 0
            answer(link, opcode)
        case SecureDfuOpcode.abort:
            aborts += 1
        default:
            answer(link, opcode, SecureDfuResult.opCodeNotSupported)
        }
    }
}

// MARK: - ESP32 OTA loader

/// Plays the ESP32 Unified OTA loader's BLE service on a `FakeDfuLink`.
final class BleOtaLoaderPeer {
    enum Final { case ok, hashMismatch }

    /// Answer `OK` instead of `ACK` to this chunk number (1-based).
    var okAtChunk: Int?
    var final: Final = .ok
    /// Answer the last chunk with `ACK` and send the verdict only afterwards.
    var ackLastChunk = false
    var handshake: [String] = ["ERASING", "OK"]
    /// Set when a data chunk arrived while an earlier answer was still unread.
    private(set) var pacingViolation = false
    private(set) var command = ""
    private(set) var chunkSizes: [Int] = []
    private(set) var image = Data()
    private var expectedSize = 0

    func makeLink(maxWriteLength: Int = 244) -> FakeDfuLink {
        let link = FakeDfuLink(
            maxWriteLength: maxWriteLength,
            services: [BleOtaTransport.serviceUUID: [BleOtaTransport.writeUUID, BleOtaTransport.notifyUUID]]
        )
        link.peer = { [unowned self] link, write in self.handle(link, write) }
        return link
    }

    private func send(_ link: FakeDfuLink, _ text: String) {
        link.notify(BleOtaTransport.notifyUUID, Data(text.utf8))
    }

    private func handle(_ link: FakeDfuLink, _ write: FakeDfuLink.Write) {
        guard write.characteristic == BleOtaTransport.writeUUID else { return }
        if write.withResponse {
            command += String(decoding: write.data, as: UTF8.self)
            if command.hasSuffix("\n") {
                expectedSize = Int(command.split(separator: " ")[1]) ?? 0
                handshake.forEach { send(link, $0) }
            }
            return
        }
        if link.pending(BleOtaTransport.notifyUUID) > 0 { pacingViolation = true }
        chunkSizes.append(write.data.count)
        image.append(write.data)
        let isLast = image.count >= expectedSize
        if chunkSizes.count == okAtChunk {
            send(link, "OK")
        } else if isLast {
            if ackLastChunk { send(link, "ACK") }
            send(link, final == .ok ? "OK" : "ERR Hash Mismatch")
        } else {
            send(link, "ACK")
        }
    }
}

func dfuTestImage(_ size: Int, seed: UInt8 = 0) -> Data {
    Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}
