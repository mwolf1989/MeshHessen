import Foundation

/// Minimal MQTT 3.1.1 codec for the Meshtastic client proxy. It intentionally
/// supports QoS 0 only, matching the firmware proxy contract.
struct MQTT311Codec: Sendable {
    static let maximumRemainingLength = 268_435_455

    enum Packet: Equatable, Sendable {
        case connAck(sessionPresent: Bool, returnCode: UInt8)
        case publish(topic: String, payload: Data, retained: Bool)
        case subAck(packetID: UInt16, returnCodes: [UInt8])
        case pingResponse
        case disconnect
        case other(type: UInt8, flags: UInt8, payload: Data)
    }

    enum CodecError: LocalizedError, Equatable {
        case invalidRemainingLength
        case packetTooLarge(Int)
        case malformedPacket
        case malformedUTF8
        case stringTooLong
        case unsupportedQoS(UInt8)
        case invalidPacketID

        var errorDescription: String? {
            switch self {
            case .invalidRemainingLength:
                return String(localized: "The MQTT remaining length is invalid.")
            case .packetTooLarge(let length):
                return String(localized: "The MQTT packet is too large (\(length) bytes).")
            case .malformedPacket:
                return String(localized: "The MQTT packet is malformed.")
            case .malformedUTF8:
                return String(localized: "The MQTT packet contains malformed UTF-8.")
            case .stringTooLong:
                return String(localized: "An MQTT string exceeds 65535 bytes.")
            case .unsupportedQoS(let qos):
                return String(localized: "MQTT QoS \(qos) is not supported by the proxy.")
            case .invalidPacketID:
                return String(localized: "The MQTT packet identifier must not be zero.")
            }
        }
    }

    static func connect(
        clientID: String,
        username: String?,
        password: String?,
        keepAliveSeconds: UInt16 = 60
    ) throws -> Data {
        var variableHeader: [UInt8] = []
        try appendUTF8("MQTT", to: &variableHeader)
        variableHeader.append(4) // MQTT 3.1.1 protocol level

        let hasCredentials = !(username ?? "").isEmpty || !(password ?? "").isEmpty
        var connectFlags: UInt8 = 0x02 // clean session
        if hasCredentials {
            connectFlags |= 0x80 // username flag; required when password is present
            if password != nil { connectFlags |= 0x40 }
        }
        variableHeader.append(connectFlags)
        variableHeader.append(UInt8(keepAliveSeconds >> 8))
        variableHeader.append(UInt8(keepAliveSeconds & 0xFF))

        var payload: [UInt8] = []
        try appendUTF8(clientID, to: &payload)
        if hasCredentials {
            try appendUTF8(username ?? "", to: &payload)
            if let password {
                try appendUTF8(password, to: &payload)
            }
        }

        return try packet(header: 0x10, body: variableHeader + payload)
    }

    static func subscribe(topicFilter: String, packetID: UInt16) throws -> Data {
        guard packetID != 0 else { throw CodecError.invalidPacketID }
        var body = [UInt8(packetID >> 8), UInt8(packetID & 0xFF)]
        try appendUTF8(topicFilter, to: &body)
        body.append(0) // requested QoS 0
        return try packet(header: 0x82, body: body)
    }

    static func publish(topic: String, payload: Data, retained: Bool) throws -> Data {
        var body: [UInt8] = []
        try appendUTF8(topic, to: &body)
        body.append(contentsOf: payload)
        return try packet(header: retained ? 0x31 : 0x30, body: body)
    }

    static let pingRequest = Data([0xC0, 0x00])
    static let disconnect = Data([0xE0, 0x00])

    static func encodeRemainingLength(_ value: Int) throws -> [UInt8] {
        guard value >= 0, value <= maximumRemainingLength else {
            throw CodecError.invalidRemainingLength
        }

        var value = value
        var result: [UInt8] = []
        repeat {
            var digit = UInt8(value % 128)
            value /= 128
            if value > 0 { digit |= 0x80 }
            result.append(digit)
        } while value > 0
        return result
    }

    fileprivate static func decode(header: UInt8, body: [UInt8]) throws -> Packet {
        let type = header >> 4
        let flags = header & 0x0F

        switch type {
        case 2: // CONNACK
            guard flags == 0, body.count == 2, body[0] & 0xFE == 0 else {
                throw CodecError.malformedPacket
            }
            return .connAck(sessionPresent: body[0] & 0x01 != 0, returnCode: body[1])

        case 3: // PUBLISH
            let qos = (flags >> 1) & 0x03
            guard qos == 0 else { throw CodecError.unsupportedQoS(qos) }
            var offset = 0
            let topic = try readUTF8(from: body, offset: &offset)
            return .publish(
                topic: topic,
                payload: Data(body[offset...]),
                retained: flags & 0x01 != 0
            )

        case 9: // SUBACK
            guard flags == 0, body.count >= 3 else { throw CodecError.malformedPacket }
            let packetID = UInt16(body[0]) << 8 | UInt16(body[1])
            guard packetID != 0 else { throw CodecError.invalidPacketID }
            return .subAck(packetID: packetID, returnCodes: Array(body.dropFirst(2)))

        case 13: // PINGRESP
            guard flags == 0, body.isEmpty else { throw CodecError.malformedPacket }
            return .pingResponse

        case 14: // DISCONNECT
            guard flags == 0, body.isEmpty else { throw CodecError.malformedPacket }
            return .disconnect

        default:
            return .other(type: type, flags: flags, payload: Data(body))
        }
    }

    private static func packet(header: UInt8, body: [UInt8]) throws -> Data {
        guard body.count <= maximumRemainingLength else {
            throw CodecError.packetTooLarge(body.count)
        }
        var bytes = [header]
        bytes.append(contentsOf: try encodeRemainingLength(body.count))
        bytes.append(contentsOf: body)
        return Data(bytes)
    }

    private static func appendUTF8(_ string: String, to bytes: inout [UInt8]) throws {
        let encoded = Array(string.utf8)
        guard encoded.count <= Int(UInt16.max) else { throw CodecError.stringTooLong }
        let length = UInt16(encoded.count)
        bytes.append(UInt8(length >> 8))
        bytes.append(UInt8(length & 0xFF))
        bytes.append(contentsOf: encoded)
    }

    private static func readUTF8(from bytes: [UInt8], offset: inout Int) throws -> String {
        guard bytes.count - offset >= 2 else { throw CodecError.malformedPacket }
        let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        offset += 2
        guard length >= 0, bytes.count - offset >= length else {
            throw CodecError.malformedPacket
        }
        let value = Data(bytes[offset..<(offset + length)])
        offset += length
        guard let string = String(data: value, encoding: .utf8) else {
            throw CodecError.malformedUTF8
        }
        return string
    }
}

/// Incremental MQTT packet decoder for arbitrary NWConnection receive chunks.
struct MQTT311StreamDecoder: Sendable {
    let maximumPacketSize: Int
    private(set) var bufferedByteCount = 0
    private var buffer: [UInt8] = []

    init(maximumPacketSize: Int = 1_048_576) {
        self.maximumPacketSize = max(1, maximumPacketSize)
    }

    mutating func append(_ data: Data) throws -> [MQTT311Codec.Packet] {
        buffer.append(contentsOf: data)
        var packets: [MQTT311Codec.Packet] = []

        while buffer.count >= 2 {
            var multiplier = 1
            var remainingLength = 0
            var lengthByteCount = 0
            var completedLength = false

            for index in 1..<min(buffer.count, 5) {
                let digit = buffer[index]
                remainingLength += Int(digit & 0x7F) * multiplier
                lengthByteCount += 1
                if digit & 0x80 == 0 {
                    completedLength = true
                    break
                }
                multiplier *= 128
            }

            if !completedLength {
                if buffer.count >= 5 { throw MQTT311Codec.CodecError.invalidRemainingLength }
                break
            }
            guard remainingLength <= MQTT311Codec.maximumRemainingLength else {
                throw MQTT311Codec.CodecError.invalidRemainingLength
            }
            guard remainingLength <= maximumPacketSize else {
                throw MQTT311Codec.CodecError.packetTooLarge(remainingLength)
            }

            let packetLength = 1 + lengthByteCount + remainingLength
            guard buffer.count >= packetLength else { break }

            let bodyStart = 1 + lengthByteCount
            let body = Array(buffer[bodyStart..<packetLength])
            packets.append(try MQTT311Codec.decode(header: buffer[0], body: body))
            buffer.removeFirst(packetLength)
        }

        bufferedByteCount = buffer.count
        return packets
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        bufferedByteCount = 0
    }
}
