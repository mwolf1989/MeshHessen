import Foundation

/// Every core configuration block exposed by the Meshtastic admin protocol.
enum MeshConfigCategory: String, CaseIterable, Identifiable, Sendable {
    case device
    case position
    case power
    case network
    case display
    case lora
    case bluetooth
    case security
    case session
    case deviceUI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .device: return String(localized: "Device")
        case .position: return String(localized: "Position")
        case .power: return String(localized: "Power")
        case .network: return String(localized: "Network")
        case .display: return String(localized: "Display")
        case .lora: return String(localized: "LoRa")
        case .bluetooth: return String(localized: "Bluetooth")
        case .security: return String(localized: "Security")
        case .session: return String(localized: "Session")
        case .deviceUI: return String(localized: "Device UI")
        }
    }

    var systemImage: String {
        switch self {
        case .device: return "cpu"
        case .position: return "location"
        case .power: return "bolt"
        case .network: return "network"
        case .display: return "display"
        case .lora: return "antenna.radiowaves.left.and.right"
        case .bluetooth: return "wave.3.right"
        case .security: return "lock.shield"
        case .session: return "key"
        case .deviceUI: return "rectangle.3.group"
        }
    }

    var requestType: Meshtastic_AdminMessage.ConfigType {
        switch self {
        case .device: return .deviceConfig
        case .position: return .positionConfig
        case .power: return .powerConfig
        case .network: return .networkConfig
        case .display: return .displayConfig
        case .lora: return .loraConfig
        case .bluetooth: return .bluetoothConfig
        case .security: return .securityConfig
        case .session: return .sessionkeyConfig
        case .deviceUI: return .deviceuiConfig
        }
    }
}

/// Every module configuration block in the generated Meshtastic schema.
enum MeshModuleConfigCategory: String, CaseIterable, Identifiable, Sendable {
    case mqtt
    case serial
    case externalNotification
    case storeForward
    case rangeTest
    case telemetry
    case cannedMessage
    case audio
    case remoteHardware
    case neighborInfo
    case ambientLighting
    case detectionSensor
    case paxcounter
    case statusMessage
    case trafficManagement
    case tak

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mqtt: return "MQTT"
        case .serial: return String(localized: "Serial")
        case .externalNotification: return String(localized: "External Notification")
        case .storeForward: return String(localized: "Store & Forward")
        case .rangeTest: return String(localized: "Range Test")
        case .telemetry: return String(localized: "Telemetry")
        case .cannedMessage: return String(localized: "Canned Message")
        case .audio: return String(localized: "Audio")
        case .remoteHardware: return String(localized: "Remote Hardware")
        case .neighborInfo: return String(localized: "Neighbor Info")
        case .ambientLighting: return String(localized: "Ambient Lighting")
        case .detectionSensor: return String(localized: "Detection Sensor")
        case .paxcounter: return String(localized: "Pax Counter")
        case .statusMessage: return String(localized: "Status Message")
        case .trafficManagement: return String(localized: "Traffic Management")
        case .tak: return "TAK"
        }
    }

    var systemImage: String {
        switch self {
        case .mqtt: return "arrow.up.arrow.down"
        case .serial: return "cable.connector"
        case .externalNotification: return "bell.badge"
        case .storeForward: return "tray.full"
        case .rangeTest: return "ruler"
        case .telemetry: return "gauge.with.dots.needle.67percent"
        case .cannedMessage: return "text.bubble"
        case .audio: return "speaker.wave.2"
        case .remoteHardware: return "switch.2"
        case .neighborInfo: return "point.3.connected.trianglepath.dotted"
        case .ambientLighting: return "lightbulb"
        case .detectionSensor: return "sensor"
        case .paxcounter: return "person.2"
        case .statusMessage: return "quote.bubble"
        case .trafficManagement: return "arrow.triangle.branch"
        case .tak: return "shield.lefthalf.filled"
        }
    }

    var requestType: Meshtastic_AdminMessage.ModuleConfigType {
        switch self {
        case .mqtt: return .mqttConfig
        case .serial: return .serialConfig
        case .externalNotification: return .extnotifConfig
        case .storeForward: return .storeforwardConfig
        case .rangeTest: return .rangetestConfig
        case .telemetry: return .telemetryConfig
        case .cannedMessage: return .cannedmsgConfig
        case .audio: return .audioConfig
        case .remoteHardware: return .remotehardwareConfig
        case .neighborInfo: return .neighborinfoConfig
        case .ambientLighting: return .ambientlightingConfig
        case .detectionSensor: return .detectionsensorConfig
        case .paxcounter: return .paxcounterConfig
        case .statusMessage: return .statusmessageConfig
        case .trafficManagement: return .trafficmanagementConfig
        case .tak: return .takConfig
        }
    }
}

/// Selects a bounded subset of the admin schema. It is used by remote lazy
/// loading and also lets the protocol serialize requests instead of flooding
/// a radio with the entire schema at once.
struct MeshConfigurationRequestSelection: Equatable, Sendable {
    var includeOwner = false
    var configCategories: Set<MeshConfigCategory> = []
    var moduleCategories: Set<MeshModuleConfigCategory> = []
    var channelIndices: Set<Int> = []
    var includeMetadata = false
    var includeCannedMessages = false
    var includeRingtone = false

    static let all = MeshConfigurationRequestSelection(
        includeOwner: true,
        configCategories: Set(MeshConfigCategory.allCases),
        moduleCategories: Set(MeshModuleConfigCategory.allCases),
        channelIndices: Set(0..<8),
        includeMetadata: true,
        includeCannedMessages: true,
        includeRingtone: true
    )

    static let overview = MeshConfigurationRequestSelection(includeMetadata: true)
    static let owner = MeshConfigurationRequestSelection(includeOwner: true)
    static let channels = MeshConfigurationRequestSelection(channelIndices: Set(0..<8))

    static func config(_ category: MeshConfigCategory) -> Self {
        MeshConfigurationRequestSelection(configCategories: [category])
    }

    static func module(_ category: MeshModuleConfigCategory) -> Self {
        MeshConfigurationRequestSelection(
            moduleCategories: [category],
            includeCannedMessages: category == .cannedMessage,
            includeRingtone: category == .externalNotification
        )
    }

    var isEmpty: Bool {
        !includeOwner
            && configCategories.isEmpty
            && moduleCategories.isEmpty
            && channelIndices.isEmpty
            && !includeMetadata
            && !includeCannedMessages
            && !includeRingtone
    }

    /// Number of serial admin requests required for this selection.
    var requestCount: Int {
        (includeOwner ? 1 : 0)
            + configCategories.count
            + moduleCategories.count
            + channelIndices.filter { (0..<8).contains($0) }.count
            + (includeMetadata ? 1 : 0)
            + (includeCannedMessages ? 1 : 0)
            + (includeRingtone ? 1 : 0)
    }
}

/// Progress emitted while the radio processes a serialized configuration load.
struct AdminConfigurationLoadProgress: Equatable, Sendable {
    let completedSteps: Int
    let totalSteps: Int
    let currentStep: String

    var fractionCompleted: Double {
        guard totalSteps > 0 else { return 0 }
        return min(1, max(0, Double(completedSteps) / Double(totalSteps)))
    }
}

enum ChannelPSKValidationError: LocalizedError, Equatable, Sendable {
    case invalidBase64
    case invalidKeyLength(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBase64:
            return String(localized: "The PSK must be valid Base64.")
        case .invalidKeyLength(let byteCount):
            return String(
                localized: "The PSK must decode to 0, 1, 16, or 32 bytes (currently \(byteCount))."
            )
        }
    }
}

struct ValidatedChannelPSK: Equatable, Sendable {
    let base64: String
    let data: Data
}

enum ChannelPSKValidator {
    private static let allowedBase64Bytes = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf8
    )
    private static let validKeyLengths: Set<Int> = [0, 1, 16, 32]

    /// Removes only ASCII whitespace accepted in copied Base64 values. Other
    /// Unicode whitespace and non-Base64 characters remain visible and invalid.
    static func removingASCIIWhitespace(from value: String) -> String {
        var normalized = ""
        for scalar in value.unicodeScalars {
            guard scalar.value != 0x20,
                  !(0x09...0x0D).contains(scalar.value)
            else { continue }
            normalized.unicodeScalars.append(scalar)
        }
        return normalized
    }

    /// Strictly validates canonical Base64 and the key sizes supported by
    /// Meshtastic channel settings.
    static func validate(_ value: String) throws -> ValidatedChannelPSK {
        let normalized = removingASCIIWhitespace(from: value)
        guard normalized.utf8.allSatisfy(allowedBase64Bytes.contains),
              normalized.utf8.count.isMultiple(of: 4),
              let decoded = Data(base64Encoded: normalized),
              decoded.base64EncodedString() == normalized
        else {
            throw ChannelPSKValidationError.invalidBase64
        }
        guard validKeyLengths.contains(decoded.count) else {
            throw ChannelPSKValidationError.invalidKeyLength(decoded.count)
        }
        return ValidatedChannelPSK(base64: normalized, data: decoded)
    }
}

enum ChannelSlotAllocator {
    static func firstFreeSecondarySlot(usedIndices: some Sequence<Int>) -> Int? {
        let used = Set(usedIndices)
        return (1..<8).first { !used.contains($0) }
    }
}

enum ChannelManagementError: LocalizedError, Equatable, Sendable {
    case noFreeSecondarySlot

    var errorDescription: String? {
        switch self {
        case .noFreeSecondarySlot:
            return String(localized: "All seven secondary channel slots are already in use.")
        }
    }
}

/// Accumulates an explicit set of channel slot responses for one node. Disabled
/// slots count as terminal responses but are excluded from the active snapshot.
struct ChannelSnapshotAccumulator: Equatable, Sendable {
    private(set) var targetNodeID: UInt32 = 0
    private(set) var requestedIndices: Set<Int> = []
    private(set) var responses: [Int: Meshtastic_Channel] = [:]

    mutating func begin(targetNodeID: UInt32, requestedIndices: Set<Int>) {
        self.targetNodeID = targetNodeID
        self.requestedIndices = requestedIndices
        responses.removeAll(keepingCapacity: true)
    }

    /// The initial config stream can deliver channels before MyNodeInfo. Adopt
    /// that identity without losing those responses; a real node change resets.
    mutating func adoptTargetNodeID(_ nodeID: UInt32) {
        guard nodeID != targetNodeID else { return }
        if targetNodeID == 0 {
            targetNodeID = nodeID
        } else {
            begin(targetNodeID: nodeID, requestedIndices: requestedIndices)
        }
    }

    @discardableResult
    mutating func record(_ channel: Meshtastic_Channel, from sourceNodeID: UInt32) -> Bool {
        let index = Int(channel.index)
        guard sourceNodeID == targetNodeID,
              requestedIndices.contains(index)
        else { return false }
        responses[index] = channel
        return true
    }

    var receivedIndices: Set<Int> {
        Set(responses.keys)
    }

    var isComplete: Bool {
        requestedIndices.isSubset(of: receivedIndices)
    }

    var activeChannels: [Meshtastic_Channel] {
        responses.values
            .filter { $0.role != .disabled }
            .sorted { $0.index < $1.index }
    }
}

/// A successful response refreshes this window. It deliberately does not
/// represent the total duration of a multi-category administration read.
struct AdminInactivityWindow: Sendable {
    let timeout: Duration
    private(set) var lastActivity: ContinuousClock.Instant

    init(timeout: Duration, startingAt instant: ContinuousClock.Instant) {
        self.timeout = timeout
        lastActivity = instant
    }

    var deadline: ContinuousClock.Instant {
        lastActivity.advanced(by: timeout)
    }

    mutating func recordActivity(at instant: ContinuousClock.Instant) {
        lastActivity = instant
    }

    func isExpired(at instant: ContinuousClock.Instant) -> Bool {
        instant >= deadline
    }
}

/// Complete editable state for a local or remote Meshtastic node.
///
/// The fields deliberately use generated protobuf value types. This preserves
/// fields unknown to a particular editor pane and prevents a read/edit/write
/// cycle from replacing firmware settings with client-side defaults.
struct MeshConfigurationSnapshot: Equatable, Sendable {
    var owner = Meshtastic_User()
    var device = Meshtastic_Config.DeviceConfig()
    var position = Meshtastic_Config.PositionConfig()
    var power = Meshtastic_Config.PowerConfig()
    var network = Meshtastic_Config.NetworkConfig()
    var display = Meshtastic_Config.DisplayConfig()
    var lora = Meshtastic_Config.LoRaConfig()
    var bluetooth = Meshtastic_Config.BluetoothConfig()
    var security = Meshtastic_Config.SecurityConfig()
    var session = Meshtastic_Config.SessionkeyConfig()
    var deviceUI = Meshtastic_DeviceUIConfig()

    var mqtt = Meshtastic_ModuleConfig.MQTTConfig()
    var serial = Meshtastic_ModuleConfig.SerialConfig()
    var externalNotification = Meshtastic_ModuleConfig.ExternalNotificationConfig()
    var storeForward = Meshtastic_ModuleConfig.StoreForwardConfig()
    var rangeTest = Meshtastic_ModuleConfig.RangeTestConfig()
    var telemetry = Meshtastic_ModuleConfig.TelemetryConfig()
    var cannedMessage = Meshtastic_ModuleConfig.CannedMessageConfig()
    var audio = Meshtastic_ModuleConfig.AudioConfig()
    var remoteHardware = Meshtastic_ModuleConfig.RemoteHardwareConfig()
    var neighborInfo = Meshtastic_ModuleConfig.NeighborInfoConfig()
    var ambientLighting = Meshtastic_ModuleConfig.AmbientLightingConfig()
    var detectionSensor = Meshtastic_ModuleConfig.DetectionSensorConfig()
    var paxcounter = Meshtastic_ModuleConfig.PaxcounterConfig()
    var statusMessage = Meshtastic_ModuleConfig.StatusMessageConfig()
    var trafficManagement = Meshtastic_ModuleConfig.TrafficManagementConfig()
    var tak = Meshtastic_ModuleConfig.TAKConfig()

    var channels: [Meshtastic_Channel] = []
    var cannedMessageText = ""
    var ringtone = ""
    var metadata: Meshtastic_DeviceMetadata?
    var fixedPosition: Meshtastic_Position?

    /// Availability is tracked independently from the value. Older firmware can
    /// omit newer categories; an absent response must never be written back as a
    /// default protobuf message.
    var loadedConfigCategories: Set<MeshConfigCategory> = []
    var loadedModuleCategories: Set<MeshModuleConfigCategory> = []
    var ownerLoaded = false
    var channelsLoaded = false
    var cannedMessageTextLoaded = false
    var ringtoneLoaded = false
    var metadataLoaded = false

    func config(for category: MeshConfigCategory) -> Meshtastic_Config {
        var config = Meshtastic_Config()
        switch category {
        case .device: config.device = device
        case .position: config.position = position
        case .power: config.power = power
        case .network: config.network = network
        case .display: config.display = display
        case .lora: config.lora = lora
        case .bluetooth: config.bluetooth = bluetooth
        case .security: config.security = security
        case .session: config.sessionkey = session
        case .deviceUI: config.deviceUi = deviceUI
        }
        return config
    }

    mutating func apply(_ config: Meshtastic_Config) {
        switch config.payloadVariant {
        case .device(let value): device = value
        case .position(let value): position = value
        case .power(let value): power = value
        case .network(let value): network = value
        case .display(let value): display = value
        case .lora(let value): lora = value
        case .bluetooth(let value): bluetooth = value
        case .security(let value): security = value
        case .sessionkey(let value): session = value
        case .deviceUi(let value): deviceUI = value
        case nil: break
        }
    }

    func moduleConfig(for category: MeshModuleConfigCategory) -> Meshtastic_ModuleConfig {
        var config = Meshtastic_ModuleConfig()
        switch category {
        case .mqtt: config.mqtt = mqtt
        case .serial: config.serial = serial
        case .externalNotification: config.externalNotification = externalNotification
        case .storeForward: config.storeForward = storeForward
        case .rangeTest: config.rangeTest = rangeTest
        case .telemetry: config.telemetry = telemetry
        case .cannedMessage: config.cannedMessage = cannedMessage
        case .audio: config.audio = audio
        case .remoteHardware: config.remoteHardware = remoteHardware
        case .neighborInfo: config.neighborInfo = neighborInfo
        case .ambientLighting: config.ambientLighting = ambientLighting
        case .detectionSensor: config.detectionSensor = detectionSensor
        case .paxcounter: config.paxcounter = paxcounter
        case .statusMessage: config.statusmessage = statusMessage
        case .trafficManagement: config.trafficManagement = trafficManagement
        case .tak: config.tak = tak
        }
        return config
    }

    mutating func apply(_ config: Meshtastic_ModuleConfig) {
        switch config.payloadVariant {
        case .mqtt(let value): mqtt = value
        case .serial(let value): serial = value
        case .externalNotification(let value): externalNotification = value
        case .storeForward(let value): storeForward = value
        case .rangeTest(let value): rangeTest = value
        case .telemetry(let value): telemetry = value
        case .cannedMessage(let value): cannedMessage = value
        case .audio(let value): audio = value
        case .remoteHardware(let value): remoteHardware = value
        case .neighborInfo(let value): neighborInfo = value
        case .ambientLighting(let value): ambientLighting = value
        case .detectionSensor(let value): detectionSensor = value
        case .paxcounter(let value): paxcounter = value
        case .statusmessage(let value): statusMessage = value
        case .trafficManagement(let value): trafficManagement = value
        case .tak(let value): tak = value
        case nil: break
        }
    }

    /// Merges only fields for which `incoming` actually received a response.
    /// This preserves both unsaved edits and unknown firmware categories while
    /// lazily refreshing one administration section.
    mutating func mergeLoaded(from incoming: MeshConfigurationSnapshot) {
        if incoming.ownerLoaded {
            owner = incoming.owner
            ownerLoaded = true
        }
        for category in incoming.loadedConfigCategories {
            apply(incoming.config(for: category))
            loadedConfigCategories.insert(category)
        }
        for category in incoming.loadedModuleCategories {
            apply(incoming.moduleConfig(for: category))
            loadedModuleCategories.insert(category)
        }
        if incoming.channelsLoaded {
            channels = incoming.channels
            channelsLoaded = true
        }
        if incoming.cannedMessageTextLoaded {
            cannedMessageText = incoming.cannedMessageText
            cannedMessageTextLoaded = true
        }
        if incoming.ringtoneLoaded {
            ringtone = incoming.ringtone
            ringtoneLoaded = true
        }
        if incoming.metadataLoaded {
            metadata = incoming.metadata
            metadataLoaded = true
        }
        if incoming.fixedPosition != nil {
            fixedPosition = incoming.fixedPosition
        }
    }
}

struct MeshConfigurationDiff: Equatable, Sendable {
    var changedConfigCategories: [MeshConfigCategory]
    var changedModuleCategories: [MeshModuleConfigCategory]
    var ownerChanged: Bool
    var channelsChanged: Bool
    var cannedMessageTextChanged: Bool
    var ringtoneChanged: Bool
    var fixedPositionChanged: Bool

    var isEmpty: Bool {
        changedConfigCategories.isEmpty
            && changedModuleCategories.isEmpty
            && !ownerChanged
            && !channelsChanged
            && !cannedMessageTextChanged
            && !ringtoneChanged
            && !fixedPositionChanged
    }

    var labels: [String] {
        var result = changedConfigCategories.map(\.title)
        result.append(contentsOf: changedModuleCategories.map(\.title))
        if ownerChanged { result.append(String(localized: "Owner")) }
        if channelsChanged { result.append(String(localized: "Channels")) }
        if cannedMessageTextChanged { result.append(String(localized: "Canned messages")) }
        if ringtoneChanged { result.append(String(localized: "Ringtone")) }
        if fixedPositionChanged { result.append(String(localized: "Fixed position")) }
        return result
    }

    static func between(_ updated: MeshConfigurationSnapshot, and original: MeshConfigurationSnapshot) -> Self {
        Self(
            changedConfigCategories: original.loadedConfigCategories.filter {
                updated.config(for: $0) != original.config(for: $0)
            }.sorted { $0.rawValue < $1.rawValue },
            changedModuleCategories: original.loadedModuleCategories.filter {
                updated.moduleConfig(for: $0) != original.moduleConfig(for: $0)
            }.sorted { $0.rawValue < $1.rawValue },
            ownerChanged: original.ownerLoaded && updated.owner != original.owner,
            channelsChanged: original.channelsLoaded && updated.channels != original.channels,
            cannedMessageTextChanged: original.cannedMessageTextLoaded
                && updated.cannedMessageText != original.cannedMessageText,
            ringtoneChanged: original.ringtoneLoaded && updated.ringtone != original.ringtone,
            fixedPositionChanged: original.loadedConfigCategories.contains(.position)
                && updated.loadedConfigCategories.contains(.position)
                && updated.fixedPosition != original.fixedPosition
        )
    }
}

enum AdminTarget: Equatable, Hashable, Sendable {
    case local
    case remote(UInt32)

    func destination(localNodeID: UInt32) -> UInt32? {
        switch self {
        case .local:
            return localNodeID == 0 ? nil : localNodeID
        case .remote(let nodeID):
            return nodeID == 0 || nodeID == UInt32.max ? nil : nodeID
        }
    }

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}

enum AdminNodeAction: Equatable, Sendable {
    case reboot(afterSeconds: Int32)
    case shutdown(afterSeconds: Int32)
    case resetNodeDatabase(preserveFavorites: Bool)
    case resetConfiguration(afterSeconds: Int32)
    case factoryResetDevice(afterSeconds: Int32)
    case synchronizeTime(Date)
    case removeFixedPosition

    var requiresDestructiveConfirmation: Bool {
        switch self {
        case .resetNodeDatabase, .resetConfiguration, .factoryResetDevice, .shutdown:
            return true
        case .reboot, .synchronizeTime, .removeFixedPosition:
            return false
        }
    }

    var resetsNodeDatabase: Bool {
        if case .resetNodeDatabase = self { return true }
        return false
    }

    var expectsLocalDisconnect: Bool {
        switch self {
        case .reboot, .shutdown, .resetNodeDatabase, .resetConfiguration, .factoryResetDevice:
            return true
        case .synchronizeTime, .removeFixedPosition:
            return false
        }
    }

    func adminMessage() -> Meshtastic_AdminMessage {
        var message = Meshtastic_AdminMessage()
        switch self {
        case .reboot(let seconds):
            message.rebootSeconds = seconds
        case .shutdown(let seconds):
            message.shutdownSeconds = seconds
        case .resetNodeDatabase(let preserveFavorites):
            message.nodedbReset = preserveFavorites
        case .resetConfiguration(let seconds):
            message.factoryResetConfig = seconds
        case .factoryResetDevice(let seconds):
            message.factoryResetDevice = seconds
        case .synchronizeTime(let date):
            message.setTimeOnly = UInt32(clamping: Int(date.timeIntervalSince1970))
        case .removeFixedPosition:
            message.removeFixedPosition = true
        }
        return message
    }
}
