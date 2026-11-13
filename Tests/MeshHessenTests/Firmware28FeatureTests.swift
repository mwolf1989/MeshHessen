import Foundation
import Testing

@testable import MeshHessen

@Suite("Firmware28 small features")
@MainActor
struct Firmware28FeatureTests {
    // MARK: - AEAD badge

    @Test("A channel with use_aead yields ChannelInfo.useAead")
    func channelInfoCarriesAead() {
        var channel = Meshtastic_Channel()
        channel.index = 1
        channel.role = .secondary
        channel.settings.name = "Secure"
        channel.settings.useAead = true

        let info = MeshtasticProtocolService.channelInfo(from: channel)
        #expect(info.useAead)
        #expect(info.name == "Secure")

        channel.settings.useAead = false
        #expect(!MeshtasticProtocolService.channelInfo(from: channel).useAead)
    }

    // MARK: - Signed ACKs

    @Test("AckProof raw values round-trip 0–3 and match the protobuf enum")
    func ackProofRoundTrip() {
        for raw in 0...3 {
            #expect(AckProof(rawValue: raw)?.rawValue == raw)
        }
        #expect(AckProof(rawValue: 4) == nil)
        #expect(MeshtasticProtocolService.ackProof(from: .ackProofAbsent) == .absent)
        #expect(MeshtasticProtocolService.ackProof(from: .ackProofValid) == .valid)
        #expect(MeshtasticProtocolService.ackProof(from: .ackProofInvalid) == .invalid)
        #expect(MeshtasticProtocolService.ackProof(from: .ackProofNoKey) == .noKey)
    }

    @Test("An acknowledgement records its proof without changing the delivery state")
    func ackProofIsStoredOnAcknowledgement() {
        let state = AppState()
        state.appendMessage(MessageItem(
            packetId: 77,
            time: "12:00",
            from: "Me",
            fromId: 1,
            toId: 0xFFFFFFFF,
            message: "Hello",
            channelIndex: 0,
            channelName: "Primary",
            deliveryState: .pending
        ))

        state.updateDeliveryState(requestId: 77, state: .acknowledged, context: .channel(0), ackProof: .invalid)
        #expect(state.channelMessages[0]?.first?.deliveryState == .acknowledged)
        #expect(state.channelMessages[0]?.first?.ackProof == .invalid)

        // A duplicate ACK without a verdict keeps the recorded one.
        state.updateDeliveryState(requestId: 77, state: .acknowledged, context: .channel(0))
        #expect(state.channelMessages[0]?.first?.ackProof == .invalid)
    }

    // MARK: - Labels

    @Test("Modem preset labels are readable and mark deprecated presets")
    func modemPresetLabels() {
        #expect(Meshtastic_Config.LoRaConfig.ModemPreset.longSlow.displayLabel.contains("deprecated"))
        #expect(Meshtastic_Config.LoRaConfig.ModemPreset.longFast.displayLabel == "Long Fast")
        for preset in Meshtastic_Config.LoRaConfig.ModemPreset.allCases {
            #expect(!preset.displayLabel.isEmpty)
        }
    }

    @Test("Serial mode and signature policy labels are non-empty")
    func serialModeAndPolicyLabels() {
        #expect(Meshtastic_ModuleConfig.SerialConfig.Serial_Mode.veDirect.displayLabel == "VE.Direct (Victron)")
        for mode in Meshtastic_ModuleConfig.SerialConfig.Serial_Mode.allCases {
            #expect(!mode.displayLabel.isEmpty)
        }
        for policy in Meshtastic_Config.SecurityConfig.PacketSignaturePolicy.allCases {
            #expect(!policy.displayLabel.isEmpty)
        }
    }

    // MARK: - Heard on current LoRa

    @Test("heardOnCurrentLora only changes through NodeDB snapshots")
    func heardOnCurrentLoraNeedsSnapshot() throws {
        let state = AppState()
        let snapshot = NodeInfo(id: 0x2001, nodeId: "!00002001", shortName: "A", longName: "Alpha")
        snapshot.heardOnCurrentLora = true
        state.upsertNode(snapshot, refreshNodeDatabaseFlags: true)

        let live = NodeInfo(id: 0x2001, nodeId: "!00002001", shortName: "A", longName: "Alpha")
        state.upsertNode(live)
        #expect(try #require(state.node(forId: 0x2001)).heardOnCurrentLora == true)

        let refreshed = NodeInfo(id: 0x2001, nodeId: "!00002001", shortName: "A", longName: "Alpha")
        refreshed.heardOnCurrentLora = false
        state.upsertNode(refreshed, refreshNodeDatabaseFlags: true)
        #expect(try #require(state.node(forId: 0x2001)).heardOnCurrentLora == false)
    }
}
