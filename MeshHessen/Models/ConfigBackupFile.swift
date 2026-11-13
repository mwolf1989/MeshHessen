import Foundation

import SwiftProtobuf

enum ConfigBackupError: LocalizedError, Equatable {
    case invalidFile
    case missingConfigSection
    case invalidSection(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return String(localized: "The file is not a valid configuration backup.")
        case .missingConfigSection:
            return String(localized: "The file is not a configuration backup (no \"config\" section).")
        case .invalidSection(let key):
            return String(localized: "The backup section \"\(key)\" could not be read.")
        }
    }
}

/// What the confirmation sheet shows before a restore.
struct ConfigBackupSummary: Equatable, Sendable {
    var sourceNodeId: UInt32
    var exportedAt: Date?
    var backupFirmware: String
    var deviceFirmware: String
    var ownerLongName: String?
    var ownerShortName: String?
    var configTitles: [String]
    var moduleTitles: [String]
    var channelNames: [String]
    var isSameNode: Bool
    var containsSecurity: Bool

    var sourceNodeIdText: String { ConfigBackupFile.formatNodeId(sourceNodeId) }

    /// Keys stay on the device when the backup belongs to another node.
    var securitySkipped: Bool { containsSecurity && !isSameNode }

    var sectionCount: Int {
        configTitles.count + moduleTitles.count + channelNames.count + (ownerLongName == nil ? 0 : 1)
    }
}

/// Device configuration backup in the Windows client's JSON layout, so files
/// are exchangeable between both clients:
///
/// `{ exportedAt, nodeId, firmwareVersion, myInfo, metadata, owner, config[], moduleConfig[], channels[] }`
///
/// Every entry is the protobuf JSON of the corresponding message. The file
/// contains channel keys and (for the same node) the private key; never log it.
struct ConfigBackupFile: Equatable, Sendable {
    var exportedAt: Date?
    var nodeId: UInt32
    var firmwareVersion: String
    var myInfo: Meshtastic_MyNodeInfo?
    var metadata: Meshtastic_DeviceMetadata?
    var owner: Meshtastic_User?
    var configs: [Meshtastic_Config]
    var moduleConfigs: [Meshtastic_ModuleConfig]
    var channels: [Meshtastic_Channel]

    static let topLevelKeys: Set<String> = [
        "exportedAt", "nodeId", "firmwareVersion", "myInfo", "metadata",
        "owner", "config", "moduleConfig", "channels",
    ]

    init(
        exportedAt: Date?,
        nodeId: UInt32,
        firmwareVersion: String,
        myInfo: Meshtastic_MyNodeInfo? = nil,
        metadata: Meshtastic_DeviceMetadata? = nil,
        owner: Meshtastic_User? = nil,
        configs: [Meshtastic_Config] = [],
        moduleConfigs: [Meshtastic_ModuleConfig] = [],
        channels: [Meshtastic_Channel] = []
    ) {
        self.exportedAt = exportedAt
        self.nodeId = nodeId
        self.firmwareVersion = firmwareVersion
        self.myInfo = myInfo
        self.metadata = metadata
        self.owner = owner
        self.configs = configs
        self.moduleConfigs = moduleConfigs
        self.channels = channels
    }

    /// Exports only sections the device actually answered; the session-key
    /// config is device-local and never exported. Unused channel slots are
    /// written as `DISABLED` entries (all eight slots, like Windows).
    init(
        snapshot: MeshConfigurationSnapshot,
        nodeId: UInt32,
        firmwareVersion: String,
        myInfo: Meshtastic_MyNodeInfo? = nil,
        now: Date
    ) {
        self.exportedAt = now
        self.nodeId = nodeId
        self.firmwareVersion = firmwareVersion
        self.myInfo = myInfo
        self.metadata = snapshot.metadataLoaded ? snapshot.metadata : nil
        self.owner = snapshot.ownerLoaded ? snapshot.owner : nil
        self.configs = MeshConfigCategory.allCases
            .filter { $0 != .session && snapshot.loadedConfigCategories.contains($0) }
            .map { snapshot.config(for: $0) }
        self.moduleConfigs = MeshModuleConfigCategory.allCases
            .filter { snapshot.loadedModuleCategories.contains($0) }
            .map { snapshot.moduleConfig(for: $0) }
        if snapshot.channelsLoaded {
            let byIndex = Dictionary(snapshot.channels.map { (Int($0.index), $0) }) { first, _ in first }
            self.channels = (0..<8).map { index in
                byIndex[index] ?? Self.disabledChannel(index: index)
            }
        } else {
            self.channels = []
        }
    }

    // MARK: - Encode

    func jsonData() throws -> Data {
        // SwiftProtobuf 1.35 cannot emit default values (Windows does); both
        // readers treat a missing field as its default, so files stay compatible.
        var options = JSONEncodingOptions()
        options.useDeterministicOrdering = true

        func object<M: SwiftProtobuf.Message>(_ message: M) throws -> Any {
            let text = try message.jsonString(options: options)
            return try JSONSerialization.jsonObject(with: Data(text.utf8))
        }

        var root: [String: Any] = [
            "exportedAt": exportedAt.map { Self.formatDate($0) as Any } ?? NSNull(),
            "nodeId": Self.formatNodeId(nodeId),
            "firmwareVersion": firmwareVersion,
        ]
        root["myInfo"] = try myInfo.map { try object($0) } ?? NSNull()
        root["metadata"] = try metadata.map { try object($0) } ?? NSNull()
        root["owner"] = try owner.map { try object($0) } ?? NSNull()
        root["config"] = try configs.map { try object($0) }
        root["moduleConfig"] = try moduleConfigs.map { try object($0) }
        root["channels"] = try channels.map { try object($0) }
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - Decode

    /// Tolerant reader: unknown top-level keys and unknown proto fields are
    /// ignored, `config` is required. Accepts lowerCamelCase and snake_case
    /// proto field names.
    init(jsonData: Data) throws {
        guard let parsed = try? JSONSerialization.jsonObject(with: jsonData),
              let root = parsed as? [String: Any]
        else { throw ConfigBackupError.invalidFile }
        guard root["config"] != nil else { throw ConfigBackupError.missingConfigSection }

        var options = JSONDecodingOptions()
        options.ignoreUnknownFields = true

        func message<M: SwiftProtobuf.Message>(_ value: Any, key: String, as _: M.Type) throws -> M {
            guard value is [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  let decoded = try? M(jsonString: String(decoding: data, as: UTF8.self), options: options)
            else { throw ConfigBackupError.invalidSection(key) }
            return decoded
        }

        func optionalMessage<M: SwiftProtobuf.Message>(_ key: String, as type: M.Type) throws -> M? {
            guard let value = root[key], !(value is NSNull) else { return nil }
            return try message(value, key: key, as: type)
        }

        func messages<M: SwiftProtobuf.Message>(_ key: String, as type: M.Type) throws -> [M] {
            guard let value = root[key], !(value is NSNull) else { return [] }
            guard let array = value as? [Any] else { throw ConfigBackupError.invalidSection(key) }
            return try array.compactMap { element in
                // Windows skips non-object entries; do the same.
                element is [String: Any] ? try message(element, key: key, as: type) : nil
            }
        }

        exportedAt = (root["exportedAt"] as? String).flatMap(Self.parseDate)
        nodeId = (root["nodeId"] as? String).flatMap(Self.parseNodeId) ?? 0
        firmwareVersion = root["firmwareVersion"] as? String ?? ""
        myInfo = try optionalMessage("myInfo", as: Meshtastic_MyNodeInfo.self)
        metadata = try optionalMessage("metadata", as: Meshtastic_DeviceMetadata.self)
        owner = try optionalMessage("owner", as: Meshtastic_User.self)
        guard root["config"] is [Any] else { throw ConfigBackupError.invalidSection("config") }
        configs = try messages("config", as: Meshtastic_Config.self)
        moduleConfigs = try messages("moduleConfig", as: Meshtastic_ModuleConfig.self)
        channels = try messages("channels", as: Meshtastic_Channel.self)
    }

    // MARK: - Summary

    func summary(connectedNodeId: UInt32, connectedFirmware: String) -> ConfigBackupSummary {
        let configCategories = configs.compactMap(MeshConfigCategory.init(config:)).filter { $0 != .session }
        return ConfigBackupSummary(
            sourceNodeId: nodeId,
            exportedAt: exportedAt,
            backupFirmware: firmwareVersion,
            deviceFirmware: connectedFirmware,
            ownerLongName: owner?.longName,
            ownerShortName: owner?.shortName,
            configTitles: configCategories.map(\.title),
            moduleTitles: moduleConfigs.compactMap(MeshModuleConfigCategory.init(moduleConfig:)).map(\.title),
            channelNames: channels
                .filter { $0.role != .disabled }
                .sorted { $0.index < $1.index }
                .map { channel in
                    let name = channel.settings.name
                    return "\(channel.index): \(name.isEmpty ? String(localized: "Default") : name)"
                },
            isSameNode: isSameNode(as: connectedNodeId),
            containsSecurity: configCategories.contains(.security)
        )
    }

    func isSameNode(as connectedNodeId: UInt32) -> Bool {
        nodeId != 0 && nodeId == connectedNodeId
    }

    // MARK: - Apply

    /// Returns `current` with the backup's sections laid over it. Only device
    /// identity fields are kept from `current.owner`; the security config is
    /// restored only onto the node the backup was taken from; channel and
    /// owner names are clamped to the firmware's UTF-8 byte limits.
    func apply(
        to current: MeshConfigurationSnapshot,
        connectedNodeId: UInt32,
        connectedFirmware: String? = nil
    ) -> MeshConfigurationSnapshot {
        var updated = current
        let sameNode = isSameNode(as: connectedNodeId)

        if let owner {
            // Clone-before-write: keep the device's id, MAC, hardware and key.
            var merged = current.owner
            merged.longName = UTF8Limits.clamp(
                owner.longName,
                maxBytes: UTF8Limits.longNameBytes(firmwareVersion: connectedFirmware)
            )
            merged.shortName = UTF8Limits.clamp(owner.shortName, maxBytes: UTF8Limits.shortNameBytes)
            merged.isLicensed = owner.isLicensed
            if owner.hasIsUnmessagable {
                merged.isUnmessagable = owner.isUnmessagable
            }
            updated.owner = merged
        }

        for config in configs {
            switch MeshConfigCategory(config: config) {
            case nil, .session?:
                continue
            case .security?:
                guard sameNode else { continue }
                updated.apply(config)
            default:
                updated.apply(config)
            }
        }

        for moduleConfig in moduleConfigs {
            updated.apply(moduleConfig)
        }

        if !channels.isEmpty {
            updated.channels = Self.restoredChannels(from: channels, current: current.channels)
        }
        return updated
    }

    /// Active backup slots replace the device's; device slots the backup has
    /// as unused are disabled. Slots unused on both sides are left out so an
    /// identical channel set produces no write.
    static func restoredChannels(
        from backup: [Meshtastic_Channel],
        current: [Meshtastic_Channel]
    ) -> [Meshtastic_Channel] {
        let backupByIndex = Dictionary(backup.map { (Int($0.index), $0) }) { _, last in last }
        let currentByIndex = Dictionary(
            current.filter { $0.role != .disabled }.map { (Int($0.index), $0) }
        ) { first, _ in first }
        var result: [Meshtastic_Channel] = []
        for index in 0..<8 {
            if var channel = backupByIndex[index], channel.role != .disabled {
                channel.settings.name = UTF8Limits.clamp(
                    channel.settings.name,
                    maxBytes: UTF8Limits.channelNameBytes
                )
                result.append(channel)
            } else if let existing = currentByIndex[index] {
                // The primary slot can never be disabled; keep the device's.
                result.append(index == 0 ? existing : disabledChannel(index: index))
            }
        }
        return result
    }

    // MARK: - Helpers

    static func disabledChannel(index: Int) -> Meshtastic_Channel {
        var channel = Meshtastic_Channel()
        channel.index = Int32(index)
        channel.role = .disabled
        return channel
    }

    /// `node-<8 hex id>-<yyyyMMdd-HHmmss>` (local time); `.json` is added by the exporter.
    func defaultFileBaseName(timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: exportedAt ?? Date())
        return "node-\(String(format: "%08x", nodeId))-\(stamp)"
    }

    static func formatNodeId(_ nodeId: UInt32) -> String {
        String(format: "!%08x", nodeId)
    }

    static func parseNodeId(_ text: String) -> UInt32? {
        let hex = text.hasPrefix("!") ? String(text.dropFirst()) : text
        return UInt32(hex, radix: 16)
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Accepts ISO 8601 with or without fractional seconds, including .NET's
    /// seven-digit round-trip format (`2026-11-13T10:00:00.1234567Z`).
    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        // Drop the fraction, keep the zone designator.
        guard let dot = text.firstIndex(of: ".") else { return nil }
        let rest = text[text.index(after: dot)...].drop { $0.isNumber }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: String(text[..<dot]) + rest)
    }
}
