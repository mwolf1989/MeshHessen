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
        #expect(packet.hopLimit == 7)
        #expect(packet.hopStart == 7)
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
        #expect(packet.hopLimit == 0)
        #expect(packet.hopStart == 0)
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
        #expect(adminChannelPacket.hopLimit == 7)
        #expect(primaryFallbackPacket.hopStart == 7)
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

    @Test("Rejected remote-admin requests carry a remediation hint")
    func remoteAdminHints() {
        let hinted: [RoutingError] = [.adminPublicKeyUnauthorized, .pkiFailed, .pkiUnknownPubkey, .maxRetransmit, .noRoute]
        for error in hinted {
            #expect(error.adminHint != nil, "missing hint for \(error)")
        }
        #expect(RoutingError.adminPublicKeyUnauthorized.adminHint != RoutingError.pkiFailed.adminHint)
        #expect(RoutingError.pkiFailed.adminHint == RoutingError.pkiUnknownPubkey.adminHint)
        #expect(RoutingError.maxRetransmit.adminHint == RoutingError.noRoute.adminHint)
        #expect(RoutingError.tooLarge.adminHint == nil)
        #expect(RoutingError.none.adminHint == nil)

        let description = MeshtasticProtocolService.DeviceConfigError
            .routingFailed(.adminPublicKeyUnauthorized)
            .errorDescription ?? ""
        #expect(description.hasSuffix(RoutingError.adminPublicKeyUnauthorized.adminHint ?? "<missing>"))
        let plain = MeshtasticProtocolService.DeviceConfigError.routingFailed(.tooLarge).errorDescription ?? ""
        #expect(!plain.contains("\n"))
    }

    @Test("Mesh Hessen profile verification lists every unmet item")
    func meshHessenProfileVerification() throws {
        var compliant = MeshConfigurationSnapshot()
        compliant.loadedConfigCategories = [.lora]
        compliant.channelsLoaded = true
        compliant.lora.usePreset = true
        compliant.lora.modemPreset = .shortSlow
        compliant.lora.region = .eu868
        compliant.lora.hopLimit = 7
        compliant.lora.txEnabled = true
        compliant.lora.configOkToMqtt = true
        compliant.lora.ignoreMqtt = false
        var channel = Meshtastic_Channel()
        channel.index = 1
        channel.role = .secondary
        channel.settings.name = MeshtasticProtocolService.meshHessenChannelName
        channel.settings.psk = try #require(Data(base64Encoded: MeshtasticProtocolService.meshHessenPSK))
        compliant.channels = [channel]

        #expect(MeshtasticProtocolService.meshHessenProfileIssues(in: compliant).isEmpty)

        var nonCompliant = compliant
        nonCompliant.lora.modemPreset = .longFast
        nonCompliant.lora.region = .us
        nonCompliant.lora.hopLimit = 3
        nonCompliant.lora.configOkToMqtt = false
        nonCompliant.lora.ignoreMqtt = true
        nonCompliant.channels = []
        #expect(MeshtasticProtocolService.meshHessenProfileIssues(in: nonCompliant).count == 6)

        var customPreset = compliant
        customPreset.lora.usePreset = false
        #expect(MeshtasticProtocolService.meshHessenProfileIssues(in: customPreset).count == 1)

        let unread = MeshConfigurationSnapshot()
        #expect(MeshtasticProtocolService.meshHessenProfileIssues(in: unread).count == 2)
    }

    @Test("Local and remote target validation rejects broadcast and unknown IDs")
    func targetValidation() {
        #expect(AdminTarget.local.destination(localNodeID: 0x1234) == 0x1234)
        #expect(AdminTarget.local.destination(localNodeID: 0) == nil)
        #expect(AdminTarget.remote(0xABCD).destination(localNodeID: 0x1234) == 0xABCD)
        #expect(AdminTarget.remote(0).destination(localNodeID: 0x1234) == nil)
        #expect(AdminTarget.remote(UInt32.max).destination(localNodeID: 0x1234) == nil)
    }

    @Test("Complete administration load exposes bounded step progress")
    func completeLoadProgress() {
        let expectedRequestCount = 4
            + MeshConfigCategory.allCases.count
            + MeshModuleConfigCategory.allCases.count
            + 8
        #expect(MeshConfigurationRequestSelection.all.requestCount == expectedRequestCount)

        let progress = AdminConfigurationLoadProgress(
            completedSteps: 7,
            totalSteps: expectedRequestCount,
            currentStep: "LoRa"
        )
        #expect(progress.fractionCompleted == Double(7) / Double(expectedRequestCount))
        #expect(
            AdminConfigurationLoadProgress(
                completedSteps: expectedRequestCount + 1,
                totalSteps: expectedRequestCount,
                currentStep: "Ringtone"
            ).fractionCompleted == 1
        )
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

    // MARK: - Module forms and Mesh Beacon (plan 011)

    @Test("A changed Mesh Beacon config is part of the diff; an unchanged one is not")
    func meshBeaconDiff() {
        var original = MeshConfigurationSnapshot()
        original.loadedModuleCategories = [.meshBeacon, .tak]
        original.meshBeacon.broadcastIntervalSecs = 3_600

        #expect(MeshConfigurationDiff.between(original, and: original).isEmpty)

        var updated = original
        updated.meshBeacon.broadcastMessage = "Willkommen"
        let diff = MeshConfigurationDiff.between(updated, and: original)
        #expect(diff.changedModuleCategories == [.meshBeacon])
        #expect(diff.labels.contains(MeshModuleConfigCategory.meshBeacon.title))
    }

    @Test("Mesh Beacon round-trips through ModuleConfig and keeps broadcast targets")
    func meshBeaconRoundTrip() {
        var snapshot = MeshConfigurationSnapshot()
        snapshot.meshBeacon.flags = 3
        snapshot.meshBeacon.broadcastTargets = [Meshtastic_ModuleConfig.MeshBeaconConfig.BroadcastTarget()]
        let config = snapshot.moduleConfig(for: .meshBeacon)
        #expect(config.meshBeacon.flags == 3)

        var decoded = MeshConfigurationSnapshot()
        decoded.apply(config)
        #expect(decoded.meshBeacon == snapshot.meshBeacon)
        #expect(MeshModuleConfigCategory.meshBeacon.requestType == .meshbeaconConfig)
    }

    @Test("Every module category has a title; only TAK and Mesh Beacon need firmware 2.8")
    func moduleTitlesAndFirmwareGate() {
        for category in MeshModuleConfigCategory.allCases {
            #expect(!category.title.isEmpty)
        }
        #expect(MeshModuleConfigCategory.tak.requiresFirmwareV28)
        #expect(MeshModuleConfigCategory.meshBeacon.requiresFirmwareV28)
        #expect(!MeshModuleConfigCategory.serial.requiresFirmwareV28)
        #expect(
            Set(MeshModuleConfigCategory.allCases.filter(\.requiresFirmwareV28)) == [.tak, .meshBeacon]
        )
    }

    @Test("Requests skip 2.8 modules only when the firmware is known to be older")
    func firmwareGateSelection() {
        let old = MeshConfigurationRequestSelection.all.removingModules(unsupportedByFirmware: "2.7.15.abc")
        #expect(!old.moduleCategories.contains(.tak))
        #expect(!old.moduleCategories.contains(.meshBeacon))
        #expect(old.moduleCategories.contains(.serial))
        #expect(old.requestCount == MeshConfigurationRequestSelection.all.requestCount - 2)

        for firmware in [nil, "", "garbage", "2.8.0", "2.8.2.deadbee", "3.0.0"] as [String?] {
            let selection = MeshConfigurationRequestSelection.all.removingModules(unsupportedByFirmware: firmware)
            #expect(selection == .all)
        }

        #expect(MeshModuleConfigCategory.meshBeacon.isUnsupported(byFirmware: "2.7.0"))
        #expect(!MeshModuleConfigCategory.meshBeacon.isUnsupported(byFirmware: nil))
        #expect(!MeshModuleConfigCategory.serial.isUnsupported(byFirmware: "1.0.0"))
    }

    @Test("Mesh Beacon flags helper sets and clears single bits")
    func meshBeaconFlags() {
        var beacon = Meshtastic_ModuleConfig.MeshBeaconConfig()
        beacon.setFlag(.flagListenEnabled, true)
        beacon.setFlag(.flagBroadcastEnabled, true)
        #expect(beacon.flags == 3)
        #expect(beacon.hasFlag(.flagListenEnabled))
        #expect(!beacon.hasFlag(.flagLegacySplit))

        beacon.setFlag(.flagLegacySplit, true)
        beacon.setFlag(.flagListenEnabled, false)
        #expect(beacon.flags == 6)
        beacon.setFlag(.flagListenEnabled, false)
        #expect(beacon.flags == 6)
    }

    @Test("Mesh Beacon offer channel: none, unchanged and copy of a device channel")
    func meshBeaconOfferChannel() {
        var primary = Meshtastic_Channel()
        primary.index = 0
        primary.role = .primary
        primary.settings.name = "MeshHessen"
        primary.settings.psk = Data(repeating: 0x42, count: 32)
        primary.settings.uplinkEnabled = true
        var secondary = Meshtastic_Channel()
        secondary.index = 2
        secondary.role = .secondary
        secondary.settings.name = "Team"
        secondary.settings.psk = Data([0x01])
        let channels = [primary, secondary]

        var loaded = Meshtastic_ChannelSettings()
        loaded.name = "Old"
        loaded.psk = Data(repeating: 0x07, count: 16)

        var beacon = Meshtastic_ModuleConfig.MeshBeaconConfig()
        #expect(MeshBeaconOfferChannelChoice.current(in: beacon, channels: channels, loaded: nil) == .none)

        beacon.applyOfferChannel(.channel(0), channels: channels, loaded: loaded)
        #expect(beacon.hasBroadcastOfferChannel)
        #expect(beacon.broadcastOfferChannel.name == "MeshHessen")
        #expect(beacon.broadcastOfferChannel.psk == primary.settings.psk)
        #expect(!beacon.broadcastOfferChannel.uplinkEnabled) // only name + PSK are copied
        #expect(MeshBeaconOfferChannelChoice.current(in: beacon, channels: channels, loaded: loaded) == .channel(0))

        beacon.applyOfferChannel(.unchanged, channels: channels, loaded: loaded)
        #expect(beacon.broadcastOfferChannel == loaded)
        #expect(MeshBeaconOfferChannelChoice.current(in: beacon, channels: channels, loaded: loaded) == .unchanged)

        beacon.applyOfferChannel(.none, channels: channels, loaded: loaded)
        #expect(!beacon.hasBroadcastOfferChannel)

        #expect(ChannelPSKValidator.isCustomKey(primary.settings.psk))
        #expect(!ChannelPSKValidator.isCustomKey(secondary.settings.psk))
        #expect(!ChannelPSKValidator.isCustomKey(Data()))
    }

    @Test("Detection sensor name and beacon message limits are UTF-8 bytes")
    func moduleStringLimits() {
        #expect(Meshtastic_ModuleConfig.DetectionSensorConfig.nameMaxBytes == 19)
        #expect(Meshtastic_ModuleConfig.MeshBeaconConfig.broadcastMessageMaxBytes == 60)
        let clamped = UTF8Limits.clamp(String(repeating: "ä", count: 15), maxBytes: 19)
        #expect(clamped.utf8.count <= 19)
        #expect(clamped.count == 9)
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
