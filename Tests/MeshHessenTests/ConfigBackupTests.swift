import Foundation
import Testing
@testable import MeshHessen

@Suite("ConfigBackup file model")
struct ConfigBackupTests {

    // MARK: - Fixtures

    private static let nodeA: UInt32 = 0x1234_abcd
    private static let nodeB: UInt32 = 0x0bad_f00d

    private static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private static func channel(index: Int32, name: String, role: Meshtastic_Channel.Role) -> Meshtastic_Channel {
        var channel = Meshtastic_Channel()
        channel.index = index
        channel.role = role
        channel.settings.name = name
        channel.settings.psk = randomBytes(32)
        return channel
    }

    /// Snapshot with a LoRa preset, a module setting, security keys and two channels.
    private static func snapshot(privateKeySeed: Int = 32) -> MeshConfigurationSnapshot {
        var snapshot = MeshConfigurationSnapshot()
        snapshot.owner.id = "!1234abcd"
        snapshot.owner.longName = "Backup Node"
        snapshot.owner.shortName = "BKP"
        snapshot.owner.publicKey = randomBytes(32)
        snapshot.ownerLoaded = true

        snapshot.lora.usePreset = true
        snapshot.lora.modemPreset = .shortSlow
        snapshot.lora.region = .eu868
        snapshot.lora.hopLimit = 5
        // Floats must survive the JSONSerialization pass unchanged.
        snapshot.lora.overrideFrequency = 869.525
        snapshot.lora.frequencyOffset = 0.1
        snapshot.device.role = .clientMute
        snapshot.security.privateKey = randomBytes(privateKeySeed)
        snapshot.security.publicKey = randomBytes(32)
        snapshot.session = Meshtastic_Config.SessionkeyConfig()
        snapshot.loadedConfigCategories = [.lora, .device, .security, .session]

        snapshot.mqtt.enabled = true
        snapshot.mqtt.address = "mqtt.example.invalid"
        snapshot.loadedModuleCategories = [.mqtt]

        snapshot.channels = [
            channel(index: 0, name: "Primary", role: .primary),
            channel(index: 1, name: "Hessen", role: .secondary),
        ]
        snapshot.channelsLoaded = true
        return snapshot
    }

    private static func roundTrip(_ file: ConfigBackupFile) throws -> ConfigBackupFile {
        try ConfigBackupFile(jsonData: try file.jsonData())
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Round trip

    @Test("Round trip preserves owner, configs, modules and channels")
    func roundTripPreservesProtos() throws {
        let source = Self.snapshot()
        let file = ConfigBackupFile(snapshot: source, nodeId: Self.nodeA, firmwareVersion: "2.8.1.abc", now: Self.now)
        let decoded = try Self.roundTrip(file)

        #expect(decoded.nodeId == Self.nodeA)
        #expect(decoded.firmwareVersion == "2.8.1.abc")
        #expect(decoded.exportedAt == Self.now)
        #expect(decoded.owner == source.owner)
        #expect(decoded.configs == file.configs)
        #expect(decoded.moduleConfigs == file.moduleConfigs)
        #expect(decoded.channels == file.channels)

        var restored = MeshConfigurationSnapshot()
        for config in decoded.configs { restored.apply(config) }
        for module in decoded.moduleConfigs { restored.apply(module) }
        #expect(restored.lora == source.lora)
        #expect(restored.security == source.security)
        #expect(restored.mqtt == source.mqtt)
        #expect(decoded.channels.filter { $0.role != .disabled } == source.channels)
    }

    @Test("Export skips the session config and unloaded sections; pads channels to eight slots")
    func exportSelection() {
        var source = Self.snapshot()
        source.ownerLoaded = false
        let file = ConfigBackupFile(snapshot: source, nodeId: Self.nodeA, firmwareVersion: "", now: Self.now)

        let categories = Set(file.configs.compactMap(MeshConfigCategory.init(config:)))
        #expect(categories == [.lora, .device, .security])
        #expect(file.moduleConfigs.compactMap(MeshModuleConfigCategory.init(moduleConfig:)) == [.mqtt])
        #expect(file.owner == nil)
        #expect(file.channels.map(\.index) == Array(0..<8))
        #expect(file.channels.filter { $0.role == .disabled }.count == 6)
    }

    // MARK: - Layout

    @Test("Top-level keys match the Windows layout and nodeId is !%08x")
    func windowsLayout() throws {
        let file = ConfigBackupFile(snapshot: Self.snapshot(), nodeId: 0x00ab_cdef, firmwareVersion: "2.7.15", now: Self.now)
        let root = try #require(try JSONSerialization.jsonObject(with: file.jsonData()) as? [String: Any])

        #expect(Set(root.keys) == ConfigBackupFile.topLevelKeys)
        #expect(Set(root.keys) == [
            "exportedAt", "nodeId", "firmwareVersion", "myInfo", "metadata",
            "owner", "config", "moduleConfig", "channels",
        ])
        #expect(root["nodeId"] as? String == "!00abcdef")
        #expect(root["myInfo"] is NSNull)
        #expect((root["config"] as? [Any])?.count == 3)
    }

    @Test("Default file name is node-<hex>-<timestamp>")
    func defaultFileName() {
        let file = ConfigBackupFile(exportedAt: Self.now, nodeId: 0x00ab_cdef, firmwareVersion: "")
        let name = file.defaultFileBaseName(timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "node-00abcdef-20270115-080000")
    }

    @Test("A hand-written Windows-style JSON with snake_case field names parses")
    func windowsSnakeCaseParses() throws {
        let psk = Self.randomBytes(16).base64EncodedString()
        let json = """
        {
          "exportedAt": "2026-11-12T18:04:05.1234567Z",
          "nodeId": "!0badf00d",
          "firmwareVersion": "2.7.15.567b8ea",
          "myInfo": { "my_node_num": 195948557, "reboot_count": 3 },
          "metadata": null,
          "owner": { "id": "!0badf00d", "long_name": "Windows Node", "short_name": "WIN" },
          "config": [
            { "lora": { "use_preset": true, "modem_preset": "SHORT_SLOW", "region": "EU_868", "hop_limit": 7 } },
            { "device": { "role": "CLIENT", "node_info_broadcast_secs": 10800 } },
            { "sessionkey": {} }
          ],
          "moduleConfig": [
            { "mqtt": { "enabled": true, "proxy_to_client_enabled": true } }
          ],
          "channels": [
            { "index": 0, "role": "PRIMARY", "settings": { "name": "MeshHessen", "psk": "\(psk)" } },
            { "index": 1, "role": "DISABLED", "settings": {} }
          ]
        }
        """
        let file = try ConfigBackupFile(jsonData: Data(json.utf8))

        #expect(file.nodeId == Self.nodeB)
        #expect(file.firmwareVersion == "2.7.15.567b8ea")
        #expect(file.exportedAt != nil)
        #expect(file.myInfo?.myNodeNum == 195_948_557)
        #expect(file.metadata == nil)
        #expect(file.owner?.longName == "Windows Node")
        #expect(file.configs.count == 3)
        var probe = MeshConfigurationSnapshot()
        for config in file.configs { probe.apply(config) }
        #expect(probe.lora.modemPreset == .shortSlow)
        #expect(probe.lora.region == .eu868)
        #expect(probe.lora.hopLimit == 7)
        #expect(probe.device.nodeInfoBroadcastSecs == 10_800)
        #expect(file.moduleConfigs.first?.mqtt.proxyToClientEnabled == true)
        #expect(file.channels.first?.settings.psk.base64EncodedString() == psk)

        let summary = file.summary(connectedNodeId: Self.nodeA, connectedFirmware: "2.8.1")
        #expect(summary.sourceNodeIdText == "!0badf00d")
        #expect(summary.isSameNode == false)
        #expect(summary.containsSecurity == false)
        #expect(summary.configTitles.count == 2)
        #expect(summary.channelNames == ["0: MeshHessen"])
    }

    @Test("lowerCamelCase field names (SwiftProtobuf / Windows JsonFormatter default) parse")
    func camelCaseParses() throws {
        let json = """
        { "config": [ { "lora": { "usePreset": true, "hopLimit": 4 } } ], "channels": [] }
        """
        let file = try ConfigBackupFile(jsonData: Data(json.utf8))
        #expect(file.configs.first?.lora.hopLimit == 4)
        #expect(file.nodeId == 0)
        #expect(file.exportedAt == nil)
    }

    // MARK: - Errors / tolerance

    @Test("Missing config section throws")
    func missingConfigThrows() {
        let json = #"{ "nodeId": "!1234abcd", "channels": [] }"#
        #expect(throws: ConfigBackupError.missingConfigSection) {
            try ConfigBackupFile(jsonData: Data(json.utf8))
        }
        #expect(throws: ConfigBackupError.invalidFile) {
            try ConfigBackupFile(jsonData: Data("not json".utf8))
        }
    }

    @Test("Unknown top-level keys and unknown proto fields are ignored")
    func unknownKeysIgnored() throws {
        let json = """
        { "config": [ { "lora": { "hop_limit": 3, "future_field": 42 } } ],
          "somethingNew": { "a": 1 }, "nodeId": "!1234abcd" }
        """
        let file = try ConfigBackupFile(jsonData: Data(json.utf8))
        #expect(file.configs.first?.lora.hopLimit == 3)
        #expect(file.nodeId == Self.nodeA)
    }

    // MARK: - Apply

    @Test("apply from a different node keeps the current security config")
    func applyDifferentNodeKeepsSecurity() throws {
        let backup = try Self.roundTrip(
            ConfigBackupFile(snapshot: Self.snapshot(), nodeId: Self.nodeB, firmwareVersion: "", now: Self.now)
        )
        let current = Self.snapshot()
        let updated = backup.apply(to: current, connectedNodeId: Self.nodeA)

        #expect(updated.security == current.security)
        #expect(updated.lora == Self.snapshot().lora)
        #expect(backup.summary(connectedNodeId: Self.nodeA, connectedFirmware: "").securitySkipped)
    }

    @Test("apply onto the same node replaces the security config")
    func applySameNodeReplacesSecurity() throws {
        let source = Self.snapshot()
        let backup = try Self.roundTrip(
            ConfigBackupFile(snapshot: source, nodeId: Self.nodeA, firmwareVersion: "", now: Self.now)
        )
        let current = Self.snapshot()
        #expect(current.security != source.security)
        let updated = backup.apply(to: current, connectedNodeId: Self.nodeA)

        #expect(updated.security == source.security)
        #expect(updated.channels == source.channels)
        #expect(!backup.summary(connectedNodeId: Self.nodeA, connectedFirmware: "").securitySkipped)
    }

    @Test("apply keeps the device's owner identity and writes only changed sections")
    func applyOwnerAndDiff() throws {
        let source = Self.snapshot()
        let backup = ConfigBackupFile(snapshot: source, nodeId: Self.nodeB, firmwareVersion: "", now: Self.now)
        var current = source
        current.owner.id = "!0badf00d"
        current.owner.longName = "Other"
        current.owner.publicKey = Self.randomBytes(32)

        let updated = backup.apply(to: current, connectedNodeId: Self.nodeA)
        #expect(updated.owner.id == "!0badf00d")
        #expect(updated.owner.publicKey == current.owner.publicKey)
        #expect(updated.owner.longName == "Backup Node")

        let diff = MeshConfigurationDiff.between(updated, and: current)
        #expect(diff.ownerChanged)
        #expect(diff.changedConfigCategories.isEmpty)
        #expect(diff.changedModuleCategories.isEmpty)
        #expect(!diff.channelsChanged)
    }

    @Test("Identical backup produces an empty diff")
    func identicalBackupIsNoOp() throws {
        let source = Self.snapshot()
        let backup = try Self.roundTrip(
            ConfigBackupFile(snapshot: source, nodeId: Self.nodeA, firmwareVersion: "", now: Self.now)
        )
        let updated = backup.apply(to: source, connectedNodeId: Self.nodeA)
        #expect(MeshConfigurationDiff.between(updated, and: source).isEmpty)
    }

    @Test("Channels active on the device but unused in the backup are disabled")
    func surplusChannelsDisabled() {
        var current = Self.snapshot()
        current.channels.append(Self.channel(index: 3, name: "Extra", role: .secondary))
        let backup = ConfigBackupFile(snapshot: Self.snapshot(), nodeId: Self.nodeA, firmwareVersion: "", now: Self.now)

        let updated = backup.apply(to: current, connectedNodeId: Self.nodeA)
        #expect(updated.channels.map(\.index) == [0, 1, 3])
        #expect(updated.channels.last?.role == .disabled)
        #expect(MeshConfigurationDiff.between(updated, and: current).channelsChanged)
    }

    @Test("Channel names longer than 11 UTF-8 bytes are clamped")
    func channelNameClamped() {
        var source = Self.snapshot()
        source.channels[1].settings.name = "Mittelhessen-Ost"
        let backup = ConfigBackupFile(snapshot: source, nodeId: Self.nodeA, firmwareVersion: "", now: Self.now)

        let updated = backup.apply(to: Self.snapshot(), connectedNodeId: Self.nodeA)
        let name = updated.channels[1].settings.name
        #expect(name == "Mittelhesse")
        #expect(name.utf8.count <= UTF8Limits.channelNameBytes)
    }

    @Test("Owner names are clamped to the connected firmware's limits")
    func ownerNamesClamped() {
        var source = Self.snapshot()
        source.owner.longName = String(repeating: "x", count: 39)
        source.owner.shortName = "TOOLONG"
        let backup = ConfigBackupFile(snapshot: source, nodeId: Self.nodeA, firmwareVersion: "", now: Self.now)

        let updated = backup.apply(to: Self.snapshot(), connectedNodeId: Self.nodeA, connectedFirmware: "2.8.0")
        #expect(updated.owner.longName.utf8.count == UTF8Limits.longNameBytesV28)
        #expect(updated.owner.shortName == "TOOL")
    }
}
