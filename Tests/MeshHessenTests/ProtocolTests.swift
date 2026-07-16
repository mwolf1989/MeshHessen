import Foundation
import SwiftProtobuf
import Testing

@testable import MeshHessen

@Suite("Traceroute Payload Decoding")
struct TraceroutePayloadDecodingTests {

    @Test("Packed routes preserve signed SNR values")
    func packedRouteAndSignedSnr() throws {
        var message = Meshtastic_RouteDiscovery()
        message.route = [0x01020304, 0xAABBCCDD]
        message.snrTowards = [-40, 12]

        let decoded = try MeshtasticProtocolService.decodeRouteDiscovery(message.serializedData())

        #expect(decoded.route == message.route)
        #expect(decoded.snrTowards == [-40, 12])
    }

    @Test("Missing SNR data decodes as an empty list")
    func missingSnr() throws {
        var message = Meshtastic_RouteDiscovery()
        message.route = [0x01020304]

        let decoded = try MeshtasticProtocolService.decodeRouteDiscovery(message.serializedData())

        #expect(decoded.route == message.route)
        #expect(decoded.snrTowards.isEmpty)
    }

    @Test("Truncated packed payload throws instead of trapping")
    func truncatedPayload() {
        let truncatedPackedFixed32 = Data([0x0A, 0x04, 0x01])

        do {
            _ = try MeshtasticProtocolService.decodeRouteDiscovery(truncatedPackedFixed32)
            Issue.record("Expected the truncated traceroute payload to fail decoding")
        } catch {
            // Expected: SwiftProtobuf rejects the malformed payload safely.
        }
    }
}
