import Foundation
import Testing

@testable import MeshHessen

@Suite("Channel Administration")
struct ChannelAdministrationTests {
    @Test("Complete snapshots count disabled slots and publish only active slots")
    func completeSnapshotIncludesDisabledResponses() {
        var accumulator = ChannelSnapshotAccumulator()
        accumulator.begin(targetNodeID: 0x1234, requestedIndices: Set(0..<8))

        for index in 0..<8 {
            let role: Meshtastic_Channel.Role
            switch index {
            case 0: role = .primary
            case 5: role = .secondary
            default: role = .disabled
            }
            let recorded = accumulator.record(channel(index: index, role: role), from: 0x1234)
            #expect(recorded)
        }

        #expect(accumulator.isComplete)
        #expect(accumulator.receivedIndices == Set(0..<8))
        #expect(accumulator.activeChannels.map(\.index) == [0, 5])
    }

    @Test("Incomplete snapshots remain incomplete and expose the received active subset")
    func incompleteSnapshot() {
        var accumulator = ChannelSnapshotAccumulator()
        accumulator.begin(targetNodeID: 0x1234, requestedIndices: Set(0..<8))
        accumulator.record(channel(index: 0, role: .primary), from: 0x1234)
        accumulator.record(channel(index: 1, role: .disabled), from: 0x1234)

        #expect(!accumulator.isComplete)
        #expect(accumulator.receivedIndices == Set([0, 1]))
        #expect(accumulator.activeChannels.map(\.index) == [0])
    }

    @Test("Starting a snapshot for another node discards prior responses")
    func nodeSwitchResetsSnapshot() {
        var accumulator = ChannelSnapshotAccumulator()
        accumulator.begin(targetNodeID: 0x1111, requestedIndices: Set(0..<8))
        accumulator.record(channel(index: 0, role: .primary), from: 0x1111)

        accumulator.begin(targetNodeID: 0x2222, requestedIndices: Set(0..<8))

        #expect(accumulator.receivedIndices.isEmpty)
        let staleResponseAccepted = accumulator.record(
            channel(index: 1, role: .secondary),
            from: 0x1111
        )
        let currentResponseAccepted = accumulator.record(
            channel(index: 0, role: .primary),
            from: 0x2222
        )
        #expect(!staleResponseAccepted)
        #expect(currentResponseAccepted)
        #expect(accumulator.receivedIndices == Set([0]))
    }

    @Test("Successful responses keep a configuration read alive beyond 30 seconds total")
    func slidingInactivityWindow() {
        let clock = ContinuousClock()
        let start = clock.now
        var window = AdminInactivityWindow(timeout: .seconds(30), startingAt: start)

        window.recordActivity(at: start.advanced(by: .seconds(25)))
        #expect(!window.isExpired(at: start.advanced(by: .seconds(40))))

        window.recordActivity(at: start.advanced(by: .seconds(50)))
        #expect(!window.isExpired(at: start.advanced(by: .seconds(79))))
        #expect(window.isExpired(at: start.advanced(by: .seconds(80))))
    }

    @Test(
        "PSK validation accepts empty, one-byte, 16-byte, and 32-byte keys",
        arguments: [Data(), Data([1]), Data(repeating: 0xA5, count: 16), Data(repeating: 0x5A, count: 32)]
    )
    func acceptedPSKLengths(data: Data) throws {
        let encoded = data.base64EncodedString()
        let result = try ChannelPSKValidator.validate(encoded)

        #expect(result.base64 == encoded)
        #expect(result.data == data)
    }

    @Test("PSK validation removes copied ASCII whitespace")
    func copiedPSKWhitespace() throws {
        let result = try ChannelPSKValidator.validate(" A Q = =\r\n\t")

        #expect(result.base64 == "AQ==")
        #expect(result.data == Data([1]))
    }

    @Test("PSK validation rejects malformed Base64 and unsupported lengths")
    func invalidPSKs() {
        #expect(throws: ChannelPSKValidationError.invalidBase64) {
            try ChannelPSKValidator.validate("AQ=!")
        }
        #expect(throws: ChannelPSKValidationError.invalidBase64) {
            try ChannelPSKValidator.validate("AQ")
        }
        #expect(throws: ChannelPSKValidationError.invalidBase64) {
            try ChannelPSKValidator.validate("AQ==\u{00A0}")
        }
        #expect(throws: ChannelPSKValidationError.invalidKeyLength(2)) {
            try ChannelPSKValidator.validate(Data([1, 2]).base64EncodedString())
        }
    }

    @Test("New secondary channels use the first free slot")
    func firstFreeSecondarySlot() {
        #expect(ChannelSlotAllocator.firstFreeSecondarySlot(usedIndices: [0, 1, 3, 7]) == 2)
        #expect(ChannelSlotAllocator.firstFreeSecondarySlot(usedIndices: 1..<8) == nil)
    }

    private func channel(index: Int, role: Meshtastic_Channel.Role) -> Meshtastic_Channel {
        var channel = Meshtastic_Channel()
        channel.index = Int32(index)
        channel.role = role
        channel.settings.name = "Channel \(index)"
        return channel
    }
}
