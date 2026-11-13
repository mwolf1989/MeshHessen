import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/Dfu/DfuProtocol.cs, IDfuTransport.cs, BleGattLink.cs
// Nordic DFU wire facts shared by the Secure and Legacy transports. Byte values are the protocol's own.

// MARK: - GATT identifiers

/// A GATT service or characteristic UUID, normalised so that the 128-bit form of a Bluetooth-SIG 16-bit
/// UUID (`0000FE59-0000-1000-8000-00805F9B34FB`) equals its short form (`FE59`) — CoreBluetooth reports
/// SIG UUIDs in the short form.
struct GattUUID: Hashable, Sendable, CustomStringConvertible {
    let value: String

    init(_ string: String) {
        let upper = string.uppercased()
        let baseSuffix = "-0000-1000-8000-00805F9B34FB"
        if upper.count == 36, upper.hasPrefix("0000"), upper.hasSuffix(baseSuffix) {
            value = String(upper.dropFirst(4).prefix(4))
        } else {
            value = upper
        }
    }

    var description: String { value }
}

/// Nordic Secure DFU (SDK 12+) — service FE59.
enum SecureDfuUuids {
    static let service = GattUUID("0000FE59-0000-1000-8000-00805F9B34FB")
    /// Control point: opcodes written with response, answers as notifications.
    static let controlPoint = GattUUID("8EC90001-F315-4F60-9FB8-838830DAEA50")
    /// Packet: init data / firmware bytes written without response.
    static let packet = GattUUID("8EC90002-F315-4F60-9FB8-838830DAEA50")
    /// Buttonless DFU without bonds (indicate + write 0x01) in app firmware built with BLE_DFU_SECURE.
    static let buttonlessNoBonds = GattUUID("8EC90003-F315-4F60-9FB8-838830DAEA50")
}

/// Nordic Legacy DFU (SDK 11 / Adafruit BLEDfu) — service 1530. The stock Meshtastic nRF52 firmware
/// exposes it as buttonless trigger and most Adafruit bootloaders speak it.
enum LegacyDfuUuids {
    static let service = GattUUID("00001530-1212-EFDE-1523-785FEABCD123")
    /// Control point: notify + write. Notifications must be enabled before writing.
    static let controlPoint = GattUUID("00001531-1212-EFDE-1523-785FEABCD123")
    /// Packet: write without response for image sizes, init packet and firmware bytes.
    static let packet = GattUUID("00001532-1212-EFDE-1523-785FEABCD123")
    /// Optional uint16 LE DFU version; ≥ 5 required for the extended init-packet flow.
    static let version = GattUUID("00001534-1212-EFDE-1523-785FEABCD123")
    static let deviceInformationService = GattUUID("0000180A-0000-1000-8000-00805F9B34FB")
    static let firmwareRevision = GattUUID("00002A26-0000-1000-8000-00805F9B34FB")
}

// MARK: - Link abstraction

/// The GATT operations the OTA/DFU transports need. `BleGattLink` implements it with CoreBluetooth;
/// tests use a scripted fake that plays the peer's role. Characteristics are addressed by UUID only
/// (the UUIDs used here are unique across the services involved).
protocol DfuGattLink: AnyObject {
    /// Largest payload of a single write without response.
    var maxWriteLength: Int { get }
    /// True once the peer dropped the link (or it was closed).
    var isDisconnected: Bool { get }
    /// Discovers `service` and the given characteristics; nil when the device does not expose the
    /// service, else the characteristics that were found. Throws when the link fails.
    func discover(service: GattUUID, characteristics: [GattUUID], timeout: Duration) async throws -> Set<GattUUID>?
    /// UUIDs of every primary service (protocol detection by GATT enumeration).
    func listServices(timeout: Duration) async throws -> [GattUUID]
    /// Enables notifications (or indications — CoreBluetooth picks by the characteristic's properties).
    func subscribe(_ characteristic: GattUUID, indicate: Bool) async throws
    /// One write. Without response it waits for transmit credit (pacing); the timeout bounds that wait,
    /// or the acknowledgement of a with-response write.
    func write(_ data: Data, to characteristic: GattUUID, withResponse: Bool, timeout: Duration) async throws
    /// Next notification of `characteristic` in arrival order; nil when `timeout` elapsed. Throws
    /// `FirmwareBleError.disconnected` when the link dropped.
    func receive(from characteristic: GattUUID, timeout: Duration) async throws -> Data?
    /// Reads a characteristic; nil when it cannot be read.
    func read(_ characteristic: GattUUID, timeout: Duration) async throws -> Data?
    /// Closes the link. Never throws.
    func disconnect() async
}

/// FIFO of characteristic notifications with a timed, cancellable receive. Closing it (link dropped)
/// fails the waiting and every later receive once the buffered values are consumed.
final class GattNotificationQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Data] = []
    private var closed = false
    private var waiter: (id: UUID, continuation: CheckedContinuation<Data?, Error>)?

    func push(_ data: Data) {
        let resume: CheckedContinuation<Data?, Error>? = lock.withLock {
            guard !closed else { return nil }
            if let waiter {
                self.waiter = nil
                return waiter.continuation
            }
            buffer.append(data)
            return nil
        }
        resume?.resume(returning: data)
    }

    func close() {
        let resume: CheckedContinuation<Data?, Error>? = lock.withLock {
            closed = true
            let pending = waiter?.continuation
            waiter = nil
            return pending
        }
        resume?.resume(throwing: FirmwareBleError.disconnected)
    }

    /// Drops buffered notifications (e.g. a stale answer from an earlier attempt).
    func drain() {
        lock.withLock { buffer.removeAll() }
    }

    func next(timeout: Duration) async throws -> Data? {
        let id = UUID()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let timer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            self?.expire(id)
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                enum Immediate { case value(Data), disconnected, cancelled, timedOut, wait }
                let immediate: Immediate = lock.withLock {
                    if !buffer.isEmpty { return .value(buffer.removeFirst()) }
                    if closed { return .disconnected }
                    if Task.isCancelled { return .cancelled }
                    // Registered under the lock before the deadline, so `expire` (after it) always finds us.
                    if ContinuousClock.now >= deadline { return .timedOut }
                    waiter = (id, continuation)
                    return .wait
                }
                switch immediate {
                case .value(let data): continuation.resume(returning: data)
                case .disconnected: continuation.resume(throwing: FirmwareBleError.disconnected)
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .timedOut: continuation.resume(returning: nil)
                case .wait: break
                }
            }
        } onCancel: {
            let pending: CheckedContinuation<Data?, Error>? = lock.withLock {
                guard waiter?.id == id else { return nil }
                let continuation = waiter?.continuation
                waiter = nil
                return continuation
            }
            pending?.resume(throwing: CancellationError())
        }
    }

    private func expire(_ id: UUID) {
        let pending: CheckedContinuation<Data?, Error>? = lock.withLock {
            guard waiter?.id == id else { return nil }
            let continuation = waiter?.continuation
            waiter = nil
            return continuation
        }
        pending?.resume(returning: nil)
    }
}

/// Typed errors of the Bluetooth firmware link (CoreBluetooth side).
enum FirmwareBleError: LocalizedError, Equatable {
    case bluetoothUnavailable(String)
    case peripheralNotFound
    case connectFailed(String)
    case disconnected
    case timeout(String)
    case serviceMissing(String)
    case characteristicMissing(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let state):
            String(localized: "Bluetooth is not available (\(state)).")
        case .peripheralNotFound:
            String(localized: "The Bluetooth device was not found.")
        case .connectFailed(let reason):
            String(localized: "The Bluetooth connection failed: \(reason)")
        case .disconnected:
            String(localized: "The Bluetooth connection was lost.")
        case .timeout(let what):
            String(localized: "Bluetooth operation timed out (\(what)).")
        case .serviceMissing(let uuid):
            String(localized: "The device does not offer the Bluetooth service \(uuid).")
        case .characteristicMissing(let uuid):
            String(localized: "The device does not offer the Bluetooth characteristic \(uuid).")
        case .operationFailed(let reason):
            String(localized: "Bluetooth operation failed: \(reason)")
        }
    }
}

// MARK: - Secure DFU

enum SecureDfuOpcode {
    static let create: UInt8 = 0x01
    static let setPrn: UInt8 = 0x02
    static let calculateChecksum: UInt8 = 0x03
    static let execute: UInt8 = 0x04
    static let select: UInt8 = 0x06
    static let abort: UInt8 = 0x0C
    static let responseCode: UInt8 = 0x60
}

enum SecureDfuObjectType {
    /// Init packet (`.dat`).
    static let command: UInt8 = 0x01
    /// Firmware (`.bin`).
    static let data: UInt8 = 0x02
}

enum SecureDfuResult {
    static let success: UInt8 = 0x01
    static let opCodeNotSupported: UInt8 = 0x02
    static let invalidParameter: UInt8 = 0x03
    static let insufficientResources: UInt8 = 0x04
    static let invalidObject: UInt8 = 0x05
    static let unsupportedType: UInt8 = 0x07
    static let operationNotPermitted: UInt8 = 0x08
    static let operationFailed: UInt8 = 0x0A
    static let extError: UInt8 = 0x0B

    static func describe(_ code: UInt8) -> String {
        switch code {
        case success: "SUCCESS"
        case opCodeNotSupported: "OP_CODE_NOT_SUPPORTED"
        case invalidParameter: "INVALID_PARAMETER"
        case insufficientResources: "INSUFFICIENT_RESOURCES"
        case invalidObject: "INVALID_OBJECT"
        case unsupportedType: "UNSUPPORTED_TYPE"
        case operationNotPermitted: "OPERATION_NOT_PERMITTED"
        case operationFailed: "OPERATION_FAILED"
        case extError: "EXT_ERROR"
        default: String(format: "0x%02X", code)
        }
    }

    static func describeExtended(_ code: UInt8) -> String {
        switch code {
        case 0x02: "Wrong command format"
        case 0x03: "Unknown command"
        case 0x04: "Init command invalid"
        case 0x05: "FW version failure"
        case 0x06: "HW version failure"
        case 0x07: "SD version failure"
        case 0x08: "Signature missing"
        case 0x09: "Wrong hash type"
        case 0x0A: "Hash failed"
        case 0x0B: "Wrong signature type"
        case 0x0C: "Verification failed"
        case 0x0D: "Insufficient space"
        default: String(format: "Unknown extended error 0x%02X", code)
        }
    }
}

/// Parsed Secure DFU control-point notification.
enum SecureDfuResponse: Equatable, Sendable {
    case success(opcode: UInt8)
    case select(maxSize: Int, offset: Int, crc32: UInt32)
    case checksum(offset: Int, crc32: UInt32)
    case failure(opcode: UInt8, result: UInt8, extended: UInt8?)
    case unknown(Data)

    static func parse(_ data: Data) -> SecureDfuResponse {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == SecureDfuOpcode.responseCode else { return .unknown(data) }
        let opcode = bytes[1]
        let result = bytes[2]
        if result != SecureDfuResult.success {
            let extended = result == SecureDfuResult.extError && bytes.count >= 4 ? bytes[3] : nil
            return .failure(opcode: opcode, result: result, extended: extended)
        }
        switch opcode {
        case SecureDfuOpcode.select:
            guard bytes.count >= 15 else {
                return .failure(opcode: opcode, result: SecureDfuResult.invalidParameter, extended: nil)
            }
            return .select(
                maxSize: Int(Int32(bitPattern: DfuBytes.uint32LE(bytes, 3))),
                offset: Int(Int32(bitPattern: DfuBytes.uint32LE(bytes, 7))),
                crc32: DfuBytes.uint32LE(bytes, 11)
            )
        case SecureDfuOpcode.calculateChecksum:
            guard bytes.count >= 11 else {
                return .failure(opcode: opcode, result: SecureDfuResult.invalidParameter, extended: nil)
            }
            return .checksum(
                offset: Int(Int32(bitPattern: DfuBytes.uint32LE(bytes, 3))),
                crc32: DfuBytes.uint32LE(bytes, 7)
            )
        default:
            return .success(opcode: opcode)
        }
    }

    /// Request opcode this answer belongs to; nil for unparseable data.
    var opcode: UInt8? {
        switch self {
        case .success(let opcode), .failure(let opcode, _, _): opcode
        case .select: SecureDfuOpcode.select
        case .checksum: SecureDfuOpcode.calculateChecksum
        case .unknown: nil
        }
    }

    var logDescription: String {
        switch self {
        case .success(let opcode): String(format: "success opcode=0x%02X", opcode)
        case .select(let maxSize, let offset, let crc): String(format: "select max=%d offset=%d crc=0x%08X", maxSize, offset, crc)
        case .checksum(let offset, let crc): String(format: "checksum offset=%d crc=0x%08X", offset, crc)
        case .failure(let opcode, let result, let extended):
            String(format: "opcode=0x%02X result=", opcode) + SecureDfuResult.describe(result)
                + (extended.map { " ext=" + SecureDfuResult.describeExtended($0) } ?? "")
        case .unknown(let raw): "unknown " + raw.map { String(format: "%02X", $0) }.joined()
        }
    }
}

// MARK: - Legacy DFU

enum LegacyDfuOpcode {
    static let startDfu: UInt8 = 0x01
    static let initDfuParams: UInt8 = 0x02
    static let receiveFirmwareImage: UInt8 = 0x03
    static let validate: UInt8 = 0x04
    static let activateAndReset: UInt8 = 0x05
    static let reset: UInt8 = 0x06
    static let packetReceiptNotifReq: UInt8 = 0x08
    static let responseCode: UInt8 = 0x10
    static let packetReceipt: UInt8 = 0x11
    static let initParamsStart: UInt8 = 0x00
    static let initParamsComplete: UInt8 = 0x01
    /// START_DFU image type: application only (Meshtastic never ships SoftDevice/bootloader over OTA).
    static let imageTypeApplication: UInt8 = 0x04
}

enum LegacyDfuStatus {
    static let success: UInt8 = 0x01
    static let invalidState: UInt8 = 0x02
    static let notSupported: UInt8 = 0x03
    static let dataSizeExceedsLimit: UInt8 = 0x04
    static let crcError: UInt8 = 0x05
    static let operationFailed: UInt8 = 0x06

    static func describe(_ status: UInt8) -> String {
        switch status {
        case success: "SUCCESS"
        case invalidState: "INVALID_STATE"
        case notSupported: "NOT_SUPPORTED"
        case dataSizeExceedsLimit: "DATA_SIZE_EXCEEDS_LIMIT"
        case crcError: "CRC_ERROR"
        case operationFailed: "OPERATION_FAILED"
        default: String(format: "UNKNOWN(0x%02X)", status)
        }
    }
}

/// Parsed Legacy DFU control-point notification.
enum LegacyDfuResponse: Equatable, Sendable {
    case success(requestOpcode: UInt8)
    case failure(requestOpcode: UInt8, status: UInt8)
    case packetReceipt(bytesReceived: UInt32)
    case unknown(Data)

    static func parse(_ data: Data) -> LegacyDfuResponse {
        let bytes = [UInt8](data)
        guard let first = bytes.first else { return .unknown(data) }
        switch first {
        case LegacyDfuOpcode.responseCode:
            guard bytes.count >= 3 else { return .unknown(data) }
            return bytes[2] == LegacyDfuStatus.success
                ? .success(requestOpcode: bytes[1])
                : .failure(requestOpcode: bytes[1], status: bytes[2])
        case LegacyDfuOpcode.packetReceipt:
            guard bytes.count >= 5 else { return .unknown(data) }
            return .packetReceipt(bytesReceived: DfuBytes.uint32LE(bytes, 1))
        default:
            return .unknown(data)
        }
    }

    var logDescription: String {
        switch self {
        case .success(let opcode): String(format: "success opcode=0x%02X", opcode)
        case .failure(let opcode, let status): String(format: "opcode=0x%02X status=", opcode) + LegacyDfuStatus.describe(status)
        case .packetReceipt(let received): "receipt \(received)"
        case .unknown(let raw): "unknown " + raw.map { String(format: "%02X", $0) }.joined()
        }
    }
}

enum LegacyDfuPayloads {
    /// 12 bytes written to the packet characteristic right after START_DFU:
    /// `[softdevice u32][bootloader u32][application u32]`, little-endian.
    static func imageSizes(application: Int, softDevice: Int = 0, bootloader: Int = 0) -> Data {
        DfuBytes.uint32LE(UInt32(softDevice)) + DfuBytes.uint32LE(UInt32(bootloader)) + DfuBytes.uint32LE(UInt32(application))
    }

    /// PACKET_RECEIPT_NOTIF_REQ with a uint16 LE packet interval.
    static func prnRequest(_ packets: Int) -> Data {
        Data([LegacyDfuOpcode.packetReceiptNotifReq, UInt8(packets & 0xFF), UInt8((packets >> 8) & 0xFF)])
    }
}

// MARK: - Bytes and CRC

enum DfuBytes {
    static func uint32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    static func uint32LE(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}

/// CRC-32 (IEEE 802.3) as used by Secure DFU CALCULATE_CHECKSUM.
enum DfuCrc32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func compute<D: DataProtocol>(_ data: D) -> UInt32 {
        finish(update(start, data))
    }

    /// Incremental form: `finish(update(update(start, a), b)) == compute(a + b)`.
    static let start: UInt32 = 0xFFFF_FFFF

    static func update<D: DataProtocol>(_ state: UInt32, _ data: D) -> UInt32 {
        var crc = state
        for region in data.regions {
            region.withUnsafeBytes { raw in
                for byte in raw {
                    crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
                }
            }
        }
        return crc
    }

    static func finish(_ state: UInt32) -> UInt32 { ~state }
}

/// CRC-32 of growing prefixes of one image without re-hashing from zero each time.
struct DfuPrefixCrc {
    let data: Data
    private var position = 0
    private var state = DfuCrc32.start

    init(_ data: Data) {
        self.data = data
    }

    /// CRC-32 of `data[0..<length]`.
    mutating func crc(upTo length: Int) -> UInt32 {
        if length < position {
            position = 0
            state = DfuCrc32.start
        }
        if length > position {
            state = DfuCrc32.update(state, data[(data.startIndex + position)..<(data.startIndex + length)])
            position = length
        }
        return DfuCrc32.finish(state)
    }
}

// MARK: - Errors

/// Errors of a Nordic DFU session; `NordicDfuUpdater` turns them into the user-facing `DfuUpdateError`.
enum DfuError: LocalizedError, Equatable {
    /// Link-level failure (connect, discovery, dropped while a command was pending).
    case connection(String)
    case protocolError(opcode: UInt8, result: UInt8, detail: String)
    case checksum(expected: UInt32, actual: UInt32)
    case timeout(String)
    /// Legacy START answered with INVALID_STATE — a half-finished earlier session is wedged.
    case staleSession
    /// Link dropped while firmware bytes were in flight.
    case midStreamDisconnect(sent: Int, total: Int)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .connection(let reason):
            String(localized: "Bluetooth connection to the bootloader failed: \(reason)")
        case .protocolError(_, _, let detail):
            String(localized: "DFU protocol error: \(detail)")
        case .checksum(let expected, let actual):
            String(localized: "CRC-32 mismatch: expected \(String(format: "0x%08X", expected)), got \(String(format: "0x%08X", actual)).")
        case .timeout(let what):
            String(localized: "The bootloader did not answer in time (\(what)).")
        case .staleSession:
            String(localized: "The bootloader rejected the start (interrupted earlier session).")
        case .midStreamDisconnect(let sent, let total):
            String(localized: "The Bluetooth link dropped during the upload at \(sent) of \(total) bytes.")
        case .failed(let reason):
            reason
        }
    }

    var isConnectionError: Bool {
        if case .connection = self { return true }
        return false
    }
}
