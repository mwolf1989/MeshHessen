import Foundation
import Testing

@testable import MeshHessen

@Suite("Complete Configuration and Remote Admin")
struct AdminConfigurationParityTests {
    @Test("Diff includes only categories that were actually loaded")
    func diffHonorsAvailability() {
        var original = MeshConfigurationSnapshot()
        original.loadedConfigCategories = [.device, .lora]
        original.loadedModuleCategories = [.mqtt]
        original.ownerLoaded = true
        original.channelsLoaded = true

        var updated = original
        updated.device.nodeInfoBroadcastSecs = 900
        updated.lora.hopLimit = 7
        updated.network.wifiEnabled = true // unavailable: must never be written
        updated.mqtt.enabled = true
        updated.telemetry.deviceTelemetryEnabled = true // unavailable
        updated.owner.longName = "Mesh Hessen"

        let diff = MeshConfigurationDiff.between(updated, and: original)

        #expect(Set(diff.changedConfigCategories) == [.device, .lora])
        #expect(diff.changedModuleCategories == [.mqtt])
        #expect(diff.ownerChanged)
        #expect(!diff.channelsChanged)
        #expect(!diff.labels.contains(String(localized: "Network")))
        #expect(!diff.labels.contains(String(localized: "Telemetry")))
    }

    @Test("An unavailable fixed-position section cannot retain a writable draft")
    func unavailableFixedPositionIsNotWritable() {
        var original = MeshConfigurationSnapshot()
        original.loadedConfigCategories = [.position]
        original.fixedPosition = Meshtastic_Position()
        original.fixedPosition?.latitudeI = 500_000_000

        var updated = original
        updated.fixedPosition?.latitudeI = 510_000_000
        #expect(MeshConfigurationDiff.between(updated, and: original).fixedPositionChanged)

        original.loadedConfigCategories.remove(.position)
        updated.loadedConfigCategories.remove(.position)

        let unavailableDiff = MeshConfigurationDiff.between(updated, and: original)
        #expect(!unavailableDiff.fixedPositionChanged)
        #expect(unavailableDiff.isEmpty)
    }

    @Test("Every generated config and module category round-trips through a snapshot")
    func everyCategoryRoundTrips() {
        let snapshot = MeshConfigurationSnapshot()

        for category in MeshConfigCategory.allCases {
            var decoded = MeshConfigurationSnapshot()
            decoded.apply(snapshot.config(for: category))
            #expect(decoded.config(for: category) == snapshot.config(for: category))
        }
        for category in MeshModuleConfigCategory.allCases {
            var decoded = MeshConfigurationSnapshot()
            decoded.apply(snapshot.moduleConfig(for: category))
            #expect(decoded.moduleConfig(for: category) == snapshot.moduleConfig(for: category))
        }
    }

    @Test("Remote admin packet uses PKI, reliable delivery and the explicit target")
    func pkiRequestTarget() {
        let payload = Data([0x08, 0x01])
        let publicKey = Data(repeating: 0xA5, count: 32)
        let packet = MeshtasticProtocolService.makeAdminMeshPacket(
            payload: payload,
            fromNodeID: 0x1122_3344,
            toNodeID: 0xAABB_CCDD,
            packetID: 42,
            wantResponse: true,
            targetPublicKey: publicKey,
            adminChannel: 6
        )

        #expect(packet.from == 0x1122_3344)
        #expect(packet.to == 0xAABB_CCDD)
        #expect(packet.id == 42)
        #expect(packet.decoded.portnum == .adminApp)
        #expect(packet.decoded.payload == payload)
        #expect(packet.decoded.wantResponse)
        #expect(packet.pkiEncrypted)
        #expect(packet.publicKey == publicKey)
        #expect(packet.channel == 0)
        #expect(packet.wantAck)
        #expect(packet.priority == .reliable)
    }

    @Test("Local admin remains unencrypted even when a target key is supplied")
    func localAdminPacket() {
        let packet = MeshtasticProtocolService.makeAdminMeshPacket(
            payload: Data([1]),
            fromNodeID: 7,
            toNodeID: 7,
            packetID: 9,
            wantResponse: false,
            targetPublicKey: Data(repeating: 0xCC, count: 32),
            adminChannel: 5
        )

        #expect(!packet.pkiEncrypted)
        #expect(packet.publicKey.isEmpty)
        #expect(packet.channel == 0)
        #expect(packet.wantAck)
        #expect(packet.priority == .reliable)
    }

    @Test("Remote admin without a valid key uses the configured admin channel or primary fallback")
    func legacyAdminChannelFallback() {
        let adminChannelPacket = MeshtasticProtocolService.makeAdminMeshPacket(
            payload: Data(),
            fromNodeID: 1,
            toNodeID: 2,
            packetID: 10,
            wantResponse: true,
            targetPublicKey: Data(repeating: 0, count: 31),
            adminChannel: 4
        )
        let primaryFallbackPacket = MeshtasticProtocolService.makeAdminMeshPacket(
            payload: Data(),
            fromNodeID: 1,
            toNodeID: 2,
            packetID: 11,
            wantResponse: true,
            targetPublicKey: nil,
            adminChannel: 0
        )

        #expect(!adminChannelPacket.pkiEncrypted)
        #expect(adminChannelPacket.channel == 4)
        #expect(adminChannelPacket.publicKey.isEmpty)
        #expect(!primaryFallbackPacket.pkiEncrypted)
        #expect(primaryFallbackPacket.channel == 0)
    }

    @Test("Routing NACKs correlate only with their pending admin packet ID")
    func routingNACKCorrelation() {
        var tracker = MeshtasticProtocolService.AdminRoutingFailureTracker()
        tracker.register(requestID: 42, destination: 0xAABB_CCDD)

        let unrelatedMatched = tracker.record(
            requestID: 41,
            sourceNodeID: 0xAABB_CCDD,
            error: .pkiFailed
        )
        let unrelatedFailure = tracker.takeFailure(for: 42)
        let pendingMatched = tracker.record(
            requestID: 42,
            sourceNodeID: 0x1122_3344,
            error: .adminPublicKeyUnauthorized
        )
        let correlatedFailure = tracker.takeFailure(for: 42)

        #expect(!unrelatedMatched)
        #expect(unrelatedFailure == nil)
        #expect(pendingMatched)
        #expect(correlatedFailure == .adminPublicKeyUnauthorized)

        tracker.finish(42)
        let finishedMatched = tracker.record(
            requestID: 42,
            sourceNodeID: 0xAABB_CCDD,
            error: .pkiFailed
        )
        #expect(!finishedMatched)
    }

    @Test("Local and remote target validation rejects broadcast and unknown IDs")
    func targetValidation() {
        #expect(AdminTarget.local.destination(localNodeID: 0x1234) == 0x1234)
        #expect(AdminTarget.local.destination(localNodeID: 0) == nil)
        #expect(AdminTarget.remote(0xABCD).destination(localNodeID: 0x1234) == 0xABCD)
        #expect(AdminTarget.remote(0).destination(localNodeID: 0x1234) == nil)
        #expect(AdminTarget.remote(UInt32.max).destination(localNodeID: 0x1234) == nil)
    }

    @Test("Administrative actions map to the exact protobuf oneof")
    func actionMessages() {
        #expect(AdminNodeAction.reboot(afterSeconds: 2).adminMessage().payloadVariant == .rebootSeconds(2))
        #expect(AdminNodeAction.shutdown(afterSeconds: 3).adminMessage().payloadVariant == .shutdownSeconds(3))
        #expect(
            AdminNodeAction.resetNodeDatabase(preserveFavorites: true).adminMessage().payloadVariant
                == .nodedbReset(true)
        )
        #expect(
            AdminNodeAction.resetConfiguration(afterSeconds: 4).adminMessage().payloadVariant
                == .factoryResetConfig(4)
        )
        #expect(
            AdminNodeAction.factoryResetDevice(afterSeconds: 5).adminMessage().payloadVariant
                == .factoryResetDevice(5)
        )
        #expect(
            AdminNodeAction.removeFixedPosition.adminMessage().payloadVariant
                == .removeFixedPosition(true)
        )
        #expect(AdminNodeAction.factoryResetDevice(afterSeconds: 2).requiresDestructiveConfirmation)
        #expect(!AdminNodeAction.reboot(afterSeconds: 2).requiresDestructiveConfirmation)
    }

    @Test("NodeDB reset is recognized as a rebooting local action")
    func nodeDatabaseResetLifecycle() {
        let action = AdminNodeAction.resetNodeDatabase(preserveFavorites: true)

        #expect(action.resetsNodeDatabase)
        #expect(action.expectsLocalDisconnect)
        #expect(!AdminNodeAction.synchronizeTime(.now).expectsLocalDisconnect)
    }

    @Test("Time synchronization uses Unix seconds")
    func timeSynchronization() {
        let date = Date(timeIntervalSince1970: 1_700_000_123)
        #expect(
            AdminNodeAction.synchronizeTime(date).adminMessage().payloadVariant
                == .setTimeOnly(1_700_000_123)
        )
    }
}
