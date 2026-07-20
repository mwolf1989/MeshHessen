import Foundation
import SwiftProtobuf

/// Encodes and incrementally decodes the Meshtastic Stream API framing used by
/// serial and TCP transports.
struct MeshtasticStreamFrameCodec: Sendable {
    static let firstMagicByte: UInt8 = 0x94
    static let secondMagicByte: UInt8 = 0xC3
    static let maximumPayloadLength = 512

    enum FrameError: LocalizedError, Equatable {
        case emptyPayload
        case payloadTooLarge(Int)
        case malformedFrame

        var errorDescription: String? {
            switch self {
            case .emptyPayload:
                return String(localized: "The Meshtastic frame payload is empty.")
            case .payloadTooLarge(let length):
                return String(localized: "The Meshtastic frame payload is too large (\(length) bytes).")
            case .malformedFrame:
                return String(localized: "The Meshtastic frame is malformed.")
            }
        }
    }

    /// Wraps one protobuf payload in the Stream API header.
    static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw FrameError.emptyPayload }
        guard payload.count <= maximumPayloadLength else {
            throw FrameError.payloadTooLarge(payload.count)
        }

        let length = UInt16(payload.count)
        var result = Data(capacity: payload.count + 4)
        result.append(firstMagicByte)
        result.append(secondMagicByte)
        result.append(UInt8(length >> 8))
        result.append(UInt8(length & 0xFF))
        result.append(payload)
        return result
    }

    /// Extracts a payload when `frame` contains exactly one valid Stream API frame.
    static func payload(from frame: Data) throws -> Data {
        let bytes = Array(frame)
        guard bytes.count >= 5,
              bytes[0] == firstMagicByte,
              bytes[1] == secondMagicByte else {
            throw FrameError.malformedFrame
        }

        let length = Int(bytes[2]) << 8 | Int(bytes[3])
        guard length > 0,
              length <= maximumPayloadLength,
              bytes.count == length + 4 else {
            throw FrameError.malformedFrame
        }

        return Data(bytes[4...])
    }

    /// Returns true only for a decoded `ToRadio.packet` addressed to ADMIN_APP.
    /// Encrypted packets cannot be classified safely and therefore return false.
    static func containsAdminCommand(_ toRadioPayload: Data) -> Bool {
        guard let toRadio = try? Meshtastic_ToRadio(serializedBytes: toRadioPayload),
              case .packet(let packet)? = toRadio.payloadVariant,
              case .decoded(let decoded)? = packet.payloadVariant else {
            return false
        }
        return decoded.portnum == .adminApp
    }
}

/// Stateful decoder that tolerates split frames and ignores bytes preceding the
/// next valid Meshtastic Stream API header.
struct MeshtasticStreamFrameDecoder: Sendable {
    private(set) var bufferedByteCount = 0
    private var buffer: [UInt8] = []

    mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        buffer.append(contentsOf: data)

        var payloads: [Data] = []
        while true {
            guard let startIndex = frameStartIndex() else {
                preservePossiblePartialHeader()
                break
            }

            if startIndex > 0 {
                buffer.removeFirst(startIndex)
            }
            guard buffer.count >= 4 else { break }

            let length = Int(buffer[2]) << 8 | Int(buffer[3])
            guard length > 0, length <= MeshtasticStreamFrameCodec.maximumPayloadLength else {
                buffer.removeFirst(2)
                continue
            }

            let frameLength = length + 4
            guard buffer.count >= frameLength else { break }

            payloads.append(Data(buffer[4..<frameLength]))
            buffer.removeFirst(frameLength)
        }

        bufferedByteCount = buffer.count
        return payloads
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        bufferedByteCount = 0
    }

    private func frameStartIndex() -> Int? {
        guard buffer.count >= 2 else { return nil }
        for index in 0..<(buffer.count - 1) {
            if buffer[index] == MeshtasticStreamFrameCodec.firstMagicByte,
               buffer[index + 1] == MeshtasticStreamFrameCodec.secondMagicByte {
                return index
            }
        }
        return nil
    }

    private mutating func preservePossiblePartialHeader() {
        if buffer.last == MeshtasticStreamFrameCodec.firstMagicByte {
            buffer = [MeshtasticStreamFrameCodec.firstMagicByte]
        } else {
            buffer.removeAll(keepingCapacity: true)
        }
    }
}

/// Small value-type queue used by the Virtual Node forwarding path. Enqueuing
/// beyond the capacity removes the oldest element and returns it to the caller.
struct BoundedDropOldestQueue<Element: Sendable>: Sendable {
    let capacity: Int
    private(set) var elements: [Element] = []

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var count: Int { elements.count }
    var isEmpty: Bool { elements.isEmpty }

    @discardableResult
    mutating func enqueue(_ element: Element) -> Element? {
        let dropped = elements.count == capacity ? elements.removeFirst() : nil
        elements.append(element)
        return dropped
    }

    mutating func dequeue() -> Element? {
        guard !elements.isEmpty else { return nil }
        return elements.removeFirst()
    }

    mutating func removeAll() {
        elements.removeAll(keepingCapacity: true)
    }
}
