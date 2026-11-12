import Foundation
import Testing

@testable import MeshHessen

@Suite("Channel Clone")
struct ChannelCloneTests {
    @Test("Removing a channel keeps every device field of the survivors")
    func reindexKeepsDeviceFields() {
        let raw = [
            channel(index: 0, role: .primary, name: "", psk: Data([0x01]), id: 100),
            channel(index: 1, role: .secondary, name: "Hessen", psk: Data(repeating: 0xAA, count: 16), id: 101),
            channel(index: 2, role: .secondary, name: "Team", psk: Data(repeating: 0xBB, count: 32), id: 102),
        ]

        let result = MeshtasticProtocolService.reindexedChannels(raw, removing: 1)

        #expect(result.map(\.index) == [0, 1])
        #expect(result.map(\.role) == [.primary, .secondary])
        #expect(result[0].settings.name == "")
        #expect(result[0].settings.id == 100)
        #expect(result[0].settings.psk == Data([0x01]))
        #expect(result[1].settings.name == "Team")
        #expect(result[1].settings.id == 102)
        #expect(result[1].settings.psk == Data(repeating: 0xBB, count: 32))
        #expect(result.allSatisfy { $0.settings.moduleSettings.positionPrecision == 13 })
        #expect(result.allSatisfy { $0.settings.uplinkEnabled && !$0.settings.downlinkEnabled })
        #expect(result[1].settings.moduleSettings.isMuted)
    }

    @Test("Removing the primary promotes the next channel without touching its settings")
    func removingPrimaryPromotesNext() {
        let raw = [
            channel(index: 0, role: .primary, name: "", psk: Data([0x01]), id: 100),
            channel(index: 2, role: .secondary, name: "Team", psk: Data([0x02]), id: 102),
        ]

        let result = MeshtasticProtocolService.reindexedChannels(raw, removing: 0)

        #expect(result.count == 1)
        #expect(result[0].index == 0)
        #expect(result[0].role == .primary)
        #expect(result[0].settings == raw[1].settings)
    }

    @Test("Deduplication keeps slot 0 and drops only later same-name and same-PSK duplicates")
    func deduplication() {
        let psk = Data(repeating: 0xAA, count: 16)
        let raw = [
            channel(index: 0, role: .primary, name: "", psk: Data([0x01]), id: 100),
            channel(index: 1, role: .secondary, name: "Hessen", psk: psk, id: 101),
            channel(index: 2, role: .secondary, name: "hessen", psk: psk, id: 102),
            channel(index: 3, role: .secondary, name: "Hessen", psk: Data(repeating: 0xCC, count: 16), id: 103),
            channel(index: 4, role: .secondary, name: "", psk: Data([0x01]), id: 104),
        ]

        let result = MeshtasticProtocolService.deduplicatedChannels(raw)

        #expect(result.map(\.settings.id) == [100, 101, 103])
        #expect(result.map(\.index) == [0, 1, 2])
        #expect(result.map(\.role) == [.primary, .secondary, .secondary])
        #expect(result[0].settings.name == "")
        #expect(result.allSatisfy { $0.settings.moduleSettings.positionPrecision == 13 })
    }

    @Test("Deduplication is a no-op without duplicates")
    func deduplicationNoOp() {
        let raw = [
            channel(index: 0, role: .primary, name: "", psk: Data([0x01]), id: 100),
            channel(index: 1, role: .secondary, name: "Default", psk: Data([0x01]), id: 101),
        ]

        let result = MeshtasticProtocolService.deduplicatedChannels(raw)

        #expect(result == raw)
    }

    @Test("Owner writes keep every field of the device's own user")
    func ownerPreservesBase() {
        var base = Meshtastic_User()
        base.id = "!1234abcd"
        base.shortName = "OLD"
        base.longName = "Old Name"
        base.isLicensed = true
        base.publicKey = Data(repeating: 0x42, count: 32)
        base.role = .router

        let owner = MeshtasticProtocolService.ownerForWrite(
            base: base,
            shortName: "NEW",
            longName: "New Name",
            nodeId: 0x1234abcd
        )

        #expect(owner.shortName == "NEW")
        #expect(owner.longName == "New Name")
        #expect(owner.id == "!1234abcd")
        #expect(owner.isLicensed)
        #expect(owner.publicKey == Data(repeating: 0x42, count: 32))
        #expect(owner.role == .router)
    }

    @Test("Owner writes without a known user fall back to the node id")
    func ownerWithoutBase() {
        let owner = MeshtasticProtocolService.ownerForWrite(
            base: nil,
            shortName: "AB",
            longName: "Alpha",
            nodeId: 0xbeef
        )

        #expect(owner.id == "!0000beef")
        #expect(owner.shortName == "AB")
        #expect(owner.longName == "Alpha")
        #expect(!owner.isLicensed)
    }

    private func channel(
        index: Int32,
        role: Meshtastic_Channel.Role,
        name: String,
        psk: Data,
        id: UInt32
    ) -> Meshtastic_Channel {
        var channel = Meshtastic_Channel()
        channel.index = index
        channel.role = role
        channel.settings.name = name
        channel.settings.psk = psk
        channel.settings.id = id
        channel.settings.uplinkEnabled = true
        channel.settings.moduleSettings.positionPrecision = 13
        channel.settings.moduleSettings.isMuted = index == 2
        return channel
    }
}
