import Foundation
import SwiftProtobuf

// NOTE: This file uses hand-written protobuf decoding since SwiftProtobuf generated files
// will be added when protoc-gen-swift is run against the .proto files.
// The generated files go in MeshHessen/Generated/
// Until then, manual decode stubs are provided that match the proto structure exactly.

/// Coordinates the Meshtastic framing protocol on top of any transport
/// Handles packet framing (Serial/TCP), raw protobuf (BLE), init sequence,
/// channel requests, and all incoming packet dispatch
@Observable
@MainActor
final class MeshtasticProtocolService {
    struct DeviceConfigSnapshot: Equatable {
        var device: Meshtastic_Config.DeviceConfig
        var position: Meshtastic_Config.PositionConfig
        var lora: Meshtastic_Config.LoRaConfig
        var bluetooth: Meshtastic_Config.BluetoothConfig
        var network: Meshtastic_Config.NetworkConfig
        var display: Meshtastic_Config.DisplayConfig
        var power: Meshtastic_Config.PowerConfig
        var mqtt: Meshtastic_ModuleConfig.MQTTConfig
    }

    enum DeviceConfigError: LocalizedError {
        case notConnected
        case missingSessionKey
        case requestFailed
        case invalidTarget
        case routingFailed(RoutingError)
        case adminTimedOut(String)
        case incompleteResponse([String])
        case writeFailed(String)
        case verificationFailed([String])
        case verificationTimedOut

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return String(localized: "The device is not connected.")
            case .missingSessionKey:
                return String(localized: "The device did not provide an admin session key.")
            case .requestFailed:
                return String(localized: "The configuration request could not be sent.")
            case .invalidTarget:
                return String(localized: "The administration target is invalid.")
            case .routingFailed(let error):
                return String(localized: "The administration request failed: \(error.display).")
            case .adminTimedOut(let operation):
                return String(localized: "The node did not answer the administration request: \(operation).")
            case .incompleteResponse(let categories):
                return String(
                    localized: "The device returned an incomplete configuration: \(categories.joined(separator: ", "))."
                )
            case .writeFailed(let category):
                return String(localized: "The configuration for \(category) could not be sent.")
            case .verificationFailed(let categories):
                return String(
                    localized: "The device did not retain the configuration for: \(categories.joined(separator: ", "))."
                )
            case .verificationTimedOut:
                return String(localized: "The saved configuration could not be verified after reconnecting.")
            }
        }
    }

    // MARK: - Singleton / State
    weak var appState: AppState?
    var coreDataStore: MeshCoreDataStore?
    private let telemetryDatabase: TelemetryDatabaseService

    var connectionService: (any ConnectionService)?
    var onFromRadioPayloadReceived: ((Data) -> Void)?
    var onMqttProxyMessageReceived: ((Meshtastic_MqttClientProxyMessage) -> Void)?
    var onMqttConfigurationReceived: ((Meshtastic_ModuleConfig.MQTTConfig) -> Void)?

    /// Waypoints and direct contacts are observable protocol state so map views can
    /// consume them without performing I/O themselves.
    private(set) var waypoints: [UInt32: MeshWaypoint] = [:]
    private(set) var directNeighborContacts: [DirectNeighborContact] = []

    var currentNodeId: UInt32 { myNodeId }

    // MARK: - Protocol state (non-isolated mutable, protected by dataLock)
    private let dataLock = NSLock()
    private var receiveBuffer = Data()

    private var myNodeId: UInt32 = 0
    private var isInitializing = false
    private var isDisconnecting = false
    private var configComplete = false
    private var sessionPasskey = Data()

    private var tempChannels = ChannelSnapshotAccumulator()
    private var isCollectingChannelSnapshot = false

    // Device config storage (populated by admin getConfigResponse / getModuleConfigResponse)
    enum ConfigCategory: String {
        case device, position, power, network, display, lora, bluetooth, security, session, deviceUI
    }
    var receivedConfigs: [ConfigCategory: Meshtastic_Config] = [:]
    var receivedModuleConfigs: [String: Meshtastic_ModuleConfig] = [:]

    private struct AdminResponseRecord {
        let sequence: UInt64
        let sourceNodeID: UInt32
        let requestID: UInt32
        let message: Meshtastic_AdminMessage
    }

    private var adminResponseSequence: UInt64 = 0
    private var adminResponses: [AdminResponseRecord] = []
    private var adminRoutingTracker = AdminRoutingFailureTracker()
    private var remoteSessionPasskeys: [UInt32: Data] = [:]
    private var remoteSessionPasskeyDates: [UInt32: Date] = [:]
    private var localSessionPasskeyDate: Date?

    struct AdminRoutingFailureTracker {
        private var pendingDestinations: [UInt32: UInt32] = [:]
        private var zeroSourceRequestIDs: Set<UInt32> = []
        private var failures: [UInt32: RoutingError] = [:]
        private var acknowledgements: Set<UInt32> = []

        mutating func register(
            requestID: UInt32,
            destination: UInt32,
            acceptsZeroSource: Bool = false
        ) {
            pendingDestinations[requestID] = destination
            if acceptsZeroSource {
                zeroSourceRequestIDs.insert(requestID)
            } else {
                zeroSourceRequestIDs.remove(requestID)
            }
            failures.removeValue(forKey: requestID)
            acknowledgements.remove(requestID)
        }

        @discardableResult
        mutating func record(
            requestID: UInt32,
            sourceNodeID: UInt32,
            error: RoutingError
        ) -> Bool {
            guard let destination = pendingDestinations[requestID] else { return false }
            if error != .none {
                failures[requestID] = error
                return true
            }
            if sourceNodeID == destination
                || (sourceNodeID == 0 && zeroSourceRequestIDs.contains(requestID)) {
                acknowledgements.insert(requestID)
                return true
            }
            return false
        }

        mutating func takeFailure(for requestID: UInt32) -> RoutingError? {
            failures.removeValue(forKey: requestID)
        }

        func isAcknowledged(_ requestID: UInt32) -> Bool {
            acknowledgements.contains(requestID)
        }

        mutating func finish(_ requestID: UInt32) {
            pendingDestinations.removeValue(forKey: requestID)
            zeroSourceRequestIDs.remove(requestID)
            failures.removeValue(forKey: requestID)
            acknowledgements.remove(requestID)
        }
    }

    // TCP heartbeat keepalive
    private var heartbeatTask: Task<Void, Never>?

    // Text-mode recovery
    private var lastValidPacketTime = Date()
    private var consecutiveTextChunks = 0
    private var recoveryInProgress = false
    private var textLineBuffer = ""
    private var bufferWaitingSince: Date?

    // Protocol constants
    private let packetStart1: UInt8 = 0x94
    private let packetStart2: UInt8 = 0xC3
    private let maxPacketLength = 512

    // Hardcoded Mesh Hessen PSK (for decryption hint — actual decrypt not implemented)
    static let meshHessenPSK = "+uTMEaOR7hkqaXv+DROOEd5BhvAIQY/CZ/Hr4soZcOU="
    static let meshHessenChannelName = "Mesh Hessen"

    init(telemetryDatabase: TelemetryDatabaseService = .shared) {
        self.telemetryDatabase = telemetryDatabase
    }

    // MARK: - Initialize & Connect

    func initialize() async -> Bool {
        guard let conn = connectionService else { return false }

        AppLogger.shared.log("[Protocol] Initializing connection type: \(conn.type.rawValue)", debug: true)
        isDisconnecting = false
        isInitializing = true
        configComplete = false
        sessionPasskey = Data()
        localSessionPasskeyDate = nil
        remoteSessionPasskeys.removeAll()
        remoteSessionPasskeyDates.removeAll()
        adminResponses.removeAll()
        adminResponseSequence = 0
        tempChannels.begin(targetNodeID: 0, requestedIndices: Set(0..<8))
        isCollectingChannelSnapshot = true
        receiveBuffer = Data()
        myNodeId = 0
        consecutiveTextChunks = 0
        recoveryInProgress = false
        textLineBuffer = ""
        bufferWaitingSince = nil
        lastValidPacketTime = .distantPast

        // 1. Small settle delay
        try? await Task.sleep(for: .seconds(1))

        // 2. Wakeup sequence for Serial/TCP (64 × 0xC3)
        if conn.type != .bluetooth {
            let wakeup = Data(repeating: 0xC3, count: 64)
            try? await conn.write(wakeup)
            AppLogger.shared.log("[Protocol] Wakeup sent", debug: SettingsService.shared.debugSerial)
            try? await Task.sleep(for: .milliseconds(500))
        }

        // 3. Send WantConfigId
        appState?.protocolStatusMessage = String(localized: "Syncing mesh config…")
        await sendWantConfig()

        // 4. Wait up to 15s for configComplete (or idle-data fallback)
        let configDeadline = Date().addingTimeInterval(15)
        while !configComplete && Date() < configDeadline {
            try? await Task.sleep(for: .milliseconds(100))
            // Fallback: if we have myNodeId and received valid packets but
            // no new data for 2s, treat config as complete. Some firmware
            // versions don't send configCompleteID over TCP.
            if !configComplete, myNodeId != 0,
               lastValidPacketTime > .distantPast,
               Date().timeIntervalSince(lastValidPacketTime) > 2.0 {
                configComplete = true
                AppLogger.shared.log("[Protocol] ConfigComplete inferred (idle timeout after valid data)", debug: true)
            }
        }
        AppLogger.shared.log("[Protocol] configComplete=\(configComplete), myNodeId=\(String(format: "!%08x", myNodeId))", debug: true)

        // 5. Even without configComplete, proceed if we have myNodeId.
        //    The Windows client does the same — configCompleteID is optional.
        let gotBasicInfo = myNodeId != 0
        if !configComplete && gotBasicInfo {
            configComplete = true
            AppLogger.shared.log("[Protocol] ConfigComplete forced (myNodeId received, configCompleteID absent)", debug: true)
        }

        // 6. Wait for data stream stability — node count stable for 3s (max 30s).
        //    Matches Windows client behavior: ensures all node info has arrived.
        if gotBasicInfo {
            appState?.protocolStatusMessage = String(localized: "Loading nodes…")
            var lastNodeCount = appState?.nodes.count ?? 0
            var stableIterations = 0
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                let currentNodeCount = appState?.nodes.count ?? 0
                if currentNodeCount == lastNodeCount {
                    stableIterations += 1
                    if stableIterations >= 6 { // 3 seconds stable
                        AppLogger.shared.log("[Protocol] Data stream stable (\(currentNodeCount) nodes)", debug: true)
                        break
                    }
                } else {
                    stableIterations = 0
                    lastNodeCount = currentNodeCount
                }
            }
        }

        // 7. Request DeviceMetadata and SecurityConfig
        if gotBasicInfo {
            try? await Task.sleep(for: .milliseconds(200))
            await requestDeviceMetadata()
            try? await Task.sleep(for: .milliseconds(200))
            await requestSecurityConfig()
        }

        // 8. Request channels if we have node identity
        if gotBasicInfo {
            appState?.protocolStatusMessage = String(localized: "Loading channels…")
            await requestAllChannels()
            finishChannelSnapshot()
            appState?.protocolStatusMessage = String(localized: "Finalizing sync…")
        } else {
            cancelChannelSnapshot()
            AppLogger.shared.log("[Protocol] Skipping channel request (no myNodeId received)", debug: true)
            appState?.protocolStatusMessage = String(localized: "Connected, waiting for mesh data…")
        }

        // 9. Finish init; data continues to stream in live
        isInitializing = false

        // 10. Start TCP heartbeat to prevent idle disconnects
        if gotBasicInfo && connectionService?.type != .bluetooth {
            startHeartbeat()
        }

        let channelCount = appState?.channels.count ?? 0
        AppLogger.shared.log("[Protocol] Initialization complete. Nodes: \(appState?.nodes.count ?? 0), Channels: \(channelCount)", debug: true)

        return gotBasicInfo
    }

    // MARK: - Data Received (called from connection service)

    func onDataReceived(_ data: Data) {
        if connectionService?.type == .bluetooth {
            // BLE: raw protobuf, no framing
            processPacket(data)
        } else {
            // Serial/TCP: framed
            dataLock.lock()
            receiveBuffer.append(data)
            dataLock.unlock()
            processBuffer()
        }
    }

    /// Processes a raw FromRadio protobuf emitted locally by a Virtual Node
    /// client, independently of the active physical transport's framing.
    func onVirtualFromRadioPayload(_ data: Data) {
        processPacket(data, forwardToVirtualNode: false)
    }

    // MARK: - Buffer Processing (Serial/TCP framing)

    private func processBuffer() {
        dataLock.lock()
        var buf = receiveBuffer
        dataLock.unlock()

        while buf.count >= 4 {
            if buf.startIndex != 0 {
                buf = Data(buf)
            }

            // Find magic header 0x94 0xC3
            guard let startIdx = findPacketStart(in: buf) else {
                var bytesToProcess = buf.count
                if buf.last == packetStart1 {
                    bytesToProcess -= 1
                }

                if bytesToProcess > 0 {
                    extractAndLogAsciiText(buf.prefix(bytesToProcess))
                    buf.removeFirst(bytesToProcess)
                }

                bufferWaitingSince = nil
                break
            }

            if startIdx > 0 {
                // Skip bytes before header (could be ASCII device output)
                extractAndLogAsciiText(buf.prefix(startIdx))
                buf.removeFirst(startIdx)
            }

            guard buf.count >= 4 else { break }

            // Read length (bytes 2-3, big-endian)
            let lenHi = buf[2]
            let lenLo = buf[3]
            let length = Int(lenHi) << 8 | Int(lenLo)

            if length == 0 || length > maxPacketLength {
                // Invalid length — skip this header
                buf.removeFirst(2)
                bufferWaitingSince = nil
                AppLogger.shared.log("[Protocol] Invalid packet length \(length); skipping false start", debug: SettingsService.shared.debugSerial)
                continue
            }

            let totalSize = 4 + length
            guard buf.count >= totalSize else {
                // Incomplete — wait for more data
                if let waitingSince = bufferWaitingSince {
                    if Date().timeIntervalSince(waitingSince) > 5 {
                        AppLogger.shared.log("[Protocol] Incomplete packet timed out (need \(totalSize), have \(buf.count)); skipping false start", debug: true)
                        buf.removeFirst(2)
                        bufferWaitingSince = nil
                        continue
                    }
                } else {
                    bufferWaitingSince = Date()
                }
                break
            }

            bufferWaitingSince = nil

            let payload = buf.subdata(in: 4..<totalSize)
            buf.removeFirst(totalSize)
            processPacket(payload)
            consecutiveTextChunks = 0
            lastValidPacketTime = Date()
        }

        dataLock.lock()
        receiveBuffer = buf
        dataLock.unlock()
    }

    private func findPacketStart(in data: Data) -> Int? {
        guard data.count >= 2 else { return nil }
        let lastComparableIndex = data.index(before: data.endIndex)
        var currentIndex = data.startIndex

        while currentIndex < lastComparableIndex {
            let nextIndex = data.index(after: currentIndex)
            if data[currentIndex] == packetStart1 && data[nextIndex] == packetStart2 {
                return data.distance(from: data.startIndex, to: currentIndex)
            }
            currentIndex = nextIndex
        }

        return nil
    }

    // MARK: - Packet Processing

    private func processPacket(_ data: Data, forwardToVirtualNode: Bool = true) {
        do {
            let fromRadio = try Meshtastic_FromRadio(serializedBytes: data)
            if forwardToVirtualNode {
                onFromRadioPayloadReceived?(data)
            }
            handleFromRadio(fromRadio)
        } catch {
            AppLogger.shared.log("[Protocol] Parse error: \(error.localizedDescription) (bytes: \(data.count))", debug: true)
        }
    }

    private func extractAndLogAsciiText(_ bytes: Data) {
        guard !bytes.isEmpty else { return }

        let printableCount = bytes.reduce(0) { partial, byte in
            let isPrintableAscii = (byte >= 0x20 && byte <= 0x7E)
            let isWhitespace = (byte == 0x0A || byte == 0x0D || byte == 0x09)
            let isAnsiEsc = (byte == 0x1B)
            return partial + ((isPrintableAscii || isWhitespace || isAnsiEsc) ? 1 : 0)
        }

        let printableRatio = Double(printableCount) / Double(bytes.count)
        guard printableRatio >= 0.8 else {
            if SettingsService.shared.debugSerial {
                AppLogger.shared.log("[Serial] Discarding \(bytes.count) non-protobuf bytes", debug: true)
            }
            return
        }

        textLineBuffer += String(decoding: bytes, as: UTF8.self)

        while let newlineIndex = textLineBuffer.firstIndex(of: "\n") {
            let line = String(textLineBuffer[..<newlineIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            textLineBuffer.removeSubrange(...newlineIndex)

            guard !line.isEmpty else { continue }
            let cleanedLine = stripANSICodes(from: line)
            guard !cleanedLine.isEmpty else { continue }

            checkForCriticalDeviceErrors(cleanedLine)
            if SettingsService.shared.debugDevice {
                AppLogger.shared.log("[DEVICE] \(cleanedLine)", debug: true)
            }
        }

        consecutiveTextChunks += 1
        let hadValidPacket = lastValidPacketTime != .distantPast
        let noProtobufForTooLong = hadValidPacket && Date().timeIntervalSince(lastValidPacketTime) > 60

        if !recoveryInProgress && !isInitializing && noProtobufForTooLong {
            AppLogger.shared.log("[Protocol] No protobuf packets for >60s while receiving device text; attempting recovery", debug: true)
            recoveryInProgress = true
            Task { @MainActor in
                await recoverProtobufMode()
            }
        }
    }

    private func stripANSICodes(from value: String) -> String {
        value.replacingOccurrences(
            of: "\\u{001B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
    }

    private func checkForCriticalDeviceErrors(_ line: String) {
        let upper = line.uppercased()
        if upper.contains("PANIC") || upper.contains("ASSERT") || upper.contains("FATAL") || upper.contains("ERROR") {
            AppLogger.shared.log("[DEVICE-CRITICAL] \(line)")
        }
    }

    private func recoverProtobufMode() async {
        defer { recoveryInProgress = false }
        guard let conn = connectionService, conn.type != .bluetooth, !isDisconnecting else { return }

        do {
            AppLogger.shared.log("[RECOVERY] Sending wakeup sequence...", debug: true)
            let wakeup = Data(repeating: packetStart2, count: 32)
            try await conn.write(wakeup)
            try? await Task.sleep(for: .milliseconds(500))

            guard !isDisconnecting else { return }

            AppLogger.shared.log("[RECOVERY] Sending WantConfigId to force protobuf mode...", debug: true)
            await sendWantConfig()
            try? await Task.sleep(for: .seconds(3))

            if consecutiveTextChunks == 0 {
                AppLogger.shared.log("[RECOVERY] Success - protobuf mode restored", debug: true)
            } else {
                AppLogger.shared.log("[RECOVERY] Warning - still receiving text after recovery attempt", debug: true)
            }
        } catch {
            AppLogger.shared.log("[RECOVERY] Error: \(error.localizedDescription)")
        }
    }

    // MARK: - FromRadio Dispatch

    private func handleFromRadio(_ fromRadio: Meshtastic_FromRadio) {
        let variant: String
        switch fromRadio.payloadVariant {
        case .packet: variant = "packet"
        case .myInfo: variant = "myInfo"
        case .nodeInfo: variant = "nodeInfo"
        case .channel: variant = "channel"
        case .config: variant = "config"
        case .configCompleteID(let id): variant = "configCompleteID(\(id))"
        case .logRecord: variant = "logRecord"
        case .rebooted: variant = "rebooted"
        case .moduleConfig: variant = "moduleConfig"
        case .queueStatus: variant = "queueStatus"
        case .metadata: variant = "metadata"
        case .xmodemPacket: variant = "xmodemPacket"
        case .mqttClientProxyMessage: variant = "mqttClientProxyMessage"
        case .fileInfo: variant = "fileInfo"
        case .clientNotification: variant = "clientNotification"
        case .deviceuiConfig: variant = "deviceuiConfig"
        case .none: variant = "none"
        }
        AppLogger.shared.log("[Protocol] FromRadio: \(variant)", debug: true)

        switch fromRadio.payloadVariant {
        case .packet(let packet):
            handleMeshPacket(packet)
        case .myInfo(let info):
            myNodeId = info.myNodeNum
            if isCollectingChannelSnapshot {
                tempChannels.adoptTargetNodeID(myNodeId)
            }
            AppLogger.shared.log("[Protocol] MyNodeId: \(String(format: "!%08x", myNodeId))", debug: SettingsService.shared.debugDevice)
        case .nodeInfo(let info):
            handleNodeInfo(info)
        case .channel(let channel):
            handleChannel(channel, sourceNodeID: myNodeId)
        case .config(let config):
            handleConfig(config)
        case .moduleConfig(let moduleConfig):
            handleModuleConfig(moduleConfig)
        case .configCompleteID:
            configComplete = true
            AppLogger.shared.log("[Protocol] ConfigComplete received", debug: true)
        case .metadata(let meta):
            handleDeviceMetadata(meta)
        case .mqttClientProxyMessage(let message):
            onMqttProxyMessageReceived?(message)
        default:
            break
        }
    }

    // MARK: - Mesh Packet

    private func handleMeshPacket(_ packet: Meshtastic_MeshPacket) {
        let hopCount = Self.hopCount(hopStart: packet.hopStart, hopLimit: packet.hopLimit)
        let isDirectRF = Self.isDirectRF(hopCount: hopCount, viaMqtt: packet.viaMqtt)

        // Signal values represent direct RF quality. A relayed or MQTT packet must
        // never replace a previously measured direct link with a misleading value.
        if packet.from != 0 && packet.from != myNodeId, let senderNode = appState?.node(forId: packet.from) {
            senderNode.hopsAway = hopCount
            senderNode.viaMqtt = packet.viaMqtt

            if isDirectRF {
                let timestamp = Int32(Date().timeIntervalSince1970)
                senderNode.lastDirectHeard = timestamp

                if packet.rxSnr != 0 {
                    senderNode.directSnr = packet.rxSnr
                    senderNode.snrFloat = packet.rxSnr
                    senderNode.snr = String(format: "%.1f dB", packet.rxSnr)
                }
                if packet.rxRssi != 0 {
                    senderNode.directRssi = packet.rxRssi
                    senderNode.rssiInt = packet.rxRssi
                    senderNode.rssi = "\(packet.rxRssi) dBm"
                }

                directNeighborContacts.insert(
                    DirectNeighborContact(
                        nodeId: packet.from,
                        timestamp: Date(),
                        snr: packet.rxSnr == 0 ? nil : packet.rxSnr,
                        rssi: packet.rxRssi == 0 ? nil : packet.rxRssi,
                        latitude: senderNode.latitude,
                        longitude: senderNode.longitude
                    ),
                    at: 0
                )
                if directNeighborContacts.count > 2_000 {
                    directNeighborContacts.removeLast(directNeighborContacts.count - 2_000)
                }
            }
        }

        // Record every received packet in the telemetry database
        if packet.from != 0 && packet.from != myNodeId {
            let senderNode = appState?.node(forId: packet.from)
            telemetryDatabase.insertPacketRx(
                nodeId: packet.from,
                packetId: packet.id,
                snr: packet.rxSnr,
                rssi: packet.rxRssi,
                hopCount: max(0, hopCount),
                viaMqtt: packet.viaMqtt,
                wantAck: packet.wantAck,
                latitude: senderNode?.latitude ?? 0,
                longitude: senderNode?.longitude ?? 0
            )
        }

        switch packet.payloadVariant {
        case .decoded(let data):
            switch data.portnum {
            case .textMessageApp:    handleTextMessage(data: data, packet: packet)
            case .positionApp:       handlePosition(data: data, packet: packet)
            case .nodeinfoApp:       handleNodeInfoPacket(data: data, packet: packet)
            case .routingApp:        handleRoutingPacket(data: data, packet: packet)
            case .adminApp:          handleAdminPacket(data: data, packet: packet)
            case .waypointApp:       handleWaypointPacket(data: data, packet: packet)
            case .telemetryApp:      handleTelemetry(data: data, packet: packet)
            case .paxcounterApp:     handlePaxCounter(data: data, packet: packet)
            case .tracerouteApp:     handleTraceroutePacket(data: data, packet: packet)
            case .neighborinfoApp:   handleNeighborInfoPacket(data: data, packet: packet)
            default:
                if SettingsService.shared.debugDevice {
                    AppLogger.shared.log("[Protocol] Unhandled portnum \(data.portnum) from \(String(format: "!%08x", packet.from))", debug: true)
                }
            }
        case .encrypted(let ciphertext):
            // TCP echoes our own sent packets back. For PKI-encrypted DMs the node
            // can't decrypt them, so they arrive as .encrypted. Silently ignore
            // these echoes to avoid false "PSK required" errors.
            if myNodeId != 0 && packet.from == myNodeId { break }

            // Attempt client-side PKI decryption if the packet is PKI-encrypted
            if packet.pkiEncrypted && PkiDecryptionService.shared.hasPrivateKey {
                // Get sender's public key: prefer from packet, fallback to NodeKeyService
                let senderPubKey = !packet.publicKey.isEmpty
                    ? packet.publicKey
                    : NodeKeyService.shared.publicKey(for: packet.from)

                if let pubKey = senderPubKey,
                   let plaintext = PkiDecryptionService.shared.tryDecrypt(
                       ciphertext: ciphertext,
                       senderPublicKey: pubKey,
                       fromNode: packet.from,
                       packetId: packet.id
                   ) {
                    // Successfully decrypted — parse as Data proto and route normally
                    if let decoded = try? Meshtastic_Data(serializedBytes: plaintext) {
                        var decryptedPacket = packet
                        decryptedPacket.decoded = decoded
                        AppLogger.shared.log("[PKI] Decrypted packet from \(nodeDisplayName(packet.from)) portnum=\(decoded.portnum)", debug: true)
                        // Re-enter dispatch with decoded payload
                        switch decoded.portnum {
                        case .textMessageApp:    handleTextMessage(data: decoded, packet: decryptedPacket)
                        case .positionApp:       handlePosition(data: decoded, packet: decryptedPacket)
                        case .nodeinfoApp:       handleNodeInfoPacket(data: decoded, packet: decryptedPacket)
                        case .routingApp:        handleRoutingPacket(data: decoded, packet: decryptedPacket)
                        case .telemetryApp:      handleTelemetry(data: decoded, packet: decryptedPacket)
                        case .paxcounterApp:     handlePaxCounter(data: decoded, packet: decryptedPacket)
                        case .tracerouteApp:     handleTraceroutePacket(data: decoded, packet: decryptedPacket)
                        default:
                            AppLogger.shared.log("[PKI] Decrypted portnum \(decoded.portnum) from \(nodeDisplayName(packet.from))", debug: true)
                        }
                        break
                    }
                }
                AppLogger.shared.log("[PKI] Decryption failed for packet from \(nodeDisplayName(packet.from))", debug: true)
            }

            // Encrypted message we can't decode.
            if SettingsService.shared.debugMessages {
                let from = nodeDisplayName(packet.from)
                AppLogger.shared.log("[MSG] Encrypted from \(from) CH-hash:\(packet.channel) MQTT:\(packet.viaMqtt) PKI:\(packet.pkiEncrypted)", debug: true)
            }
            handleEncryptedPacket(packet)
        default:
            break
        }
    }

    nonisolated static func hopCount(hopStart: UInt32, hopLimit: UInt32) -> Int {
        guard hopStart > 0 else { return 0 }
        return max(0, Int(hopStart) - Int(hopLimit))
    }

    nonisolated static func isDirectRF(hopCount: Int, viaMqtt: Bool) -> Bool {
        hopCount == 0 && !viaMqtt
    }

    // MARK: - Text Message

    private func handleTextMessage(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        // Check for emoji reaction (Data.emoji field is non-zero and replyId is set)
        if data.emoji != 0, data.replyID != 0 {
            handleEmojiReaction(data: data, packet: packet)
            return
        }

        guard var text = String(bytes: data.payload, encoding: .utf8) else {
            AppLogger.shared.log("[Protocol] Text message decode failed from \(String(format: "!%08x", packet.from))", debug: SettingsService.shared.debugDevice)
            return
        }

        // Strip BEL character (0x07) used as alert trigger
        let hasAlertBell = text.contains("\u{0007}") || text.contains("🔔")
        text = text.replacingOccurrences(of: "\u{0007}", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let ts = formatTime()
        let from = nodeDisplayName(packet.from)
        let node = appState?.node(forId: packet.from)

        let msg = MessageItem(
            packetId: packet.id == 0 ? nil : packet.id,
            replyToPacketId: data.replyID == 0 ? nil : data.replyID,
            time: ts,
            from: from,
            fromId: packet.from,
            toId: packet.to,
            message: text,
            channelIndex: resolvedChannelIndex(for: packet.channel),
            channelName: channelName(for: Int(packet.channel)),
            isViaMqtt: packet.viaMqtt,
            senderShortName: node?.shortName ?? "",
            senderColorHex: node?.colorHex ?? "",
            senderNote: node?.note ?? "",
            hasAlertBell: hasAlertBell,
            hopCount: packet.viaMqtt ? nil : Self.hopCount(hopStart: packet.hopStart, hopLimit: packet.hopLimit),
            receivedSnr: packet.viaMqtt || packet.rxSnr == 0 ? nil : packet.rxSnr,
            receivedRssi: packet.viaMqtt || packet.rxRssi == 0 ? nil : Int(packet.rxRssi)
        )

        if SettingsService.shared.debugMessages {
            AppLogger.shared.log("[MSG] From: \(from) To: \(String(format: "%08x", packet.to)) CH:\(packet.channel) MQTT:\(packet.viaMqtt) Bell:\(hasAlertBell) | \(text)", debug: true)
        }

        // Is it a DM?
        let isBroadcast = packet.to == 0xFFFFFFFF || packet.to == 0
        if !isBroadcast && (packet.to == myNodeId || packet.from == myNodeId) {
            // Direct message
            appState?.addOrUpdateDM(msg, myNodeId: myNodeId)
            let partnerNodeId = packet.from == myNodeId ? packet.to : packet.from
            coreDataStore?.upsertMessage(msg, isDirect: true, partnerNodeId: partnerNodeId, partnerName: nodeDisplayName(partnerNodeId))
            MessageLogger.shared.logDirectMessage(msg, partnerName: from,
                partnerNodeId: packet.from == myNodeId ? packet.to : packet.from)
            if hasAlertBell { triggerAlertBell(msg) }
            // Notify for incoming DMs (not self-sent)
            if packet.from != myNodeId {
                let partnerId = packet.from
                NotificationCenter.default.post(
                    name: .incomingDirectMessage,
                    object: nil,
                    userInfo: ["partnerId": partnerId, "message": msg]
                )
            }
        } else {
            // Broadcast / channel message
            MessageLogger.shared.logChannelMessage(msg)
            deliver(msg)
            if hasAlertBell { triggerAlertBell(msg) }
        }
    }

    private func handleEncryptedPacket(_ packet: Meshtastic_MeshPacket) {
        let channelIndex = Self.resolvedChannelIndex(
            for: packet.channel,
            isEncrypted: true
        )
        let node = appState?.node(forId: packet.from)
        let message = MessageItem(
            packetId: packet.id == 0 ? nil : packet.id,
            time: formatTime(),
            from: nodeDisplayName(packet.from),
            fromId: packet.from,
            toId: packet.to,
            message: "",
            channelIndex: channelIndex,
            channelName: MessageItem.unknownChannelName(hash: Int(packet.channel)),
            isEncrypted: true,
            isViaMqtt: packet.viaMqtt,
            senderShortName: node?.shortName ?? "",
            senderColorHex: node?.colorHex ?? "",
            senderNote: node?.note ?? "",
            hopCount: packet.viaMqtt ? nil : Self.hopCount(hopStart: packet.hopStart, hopLimit: packet.hopLimit),
            receivedSnr: packet.viaMqtt || packet.rxSnr == 0 ? nil : packet.rxSnr,
            receivedRssi: packet.viaMqtt || packet.rxRssi == 0 ? nil : Int(packet.rxRssi)
        )

        let isBroadcast = packet.to == 0xFFFFFFFF || packet.to == 0
        if !isBroadcast && (packet.to == myNodeId || packet.from == myNodeId) {
            let partnerNodeId = packet.from == myNodeId ? packet.to : packet.from
            appState?.addOrUpdateDM(message, myNodeId: myNodeId, partnerNodeId: partnerNodeId)
            coreDataStore?.upsertMessage(
                message,
                isDirect: true,
                partnerNodeId: partnerNodeId,
                partnerName: nodeDisplayName(partnerNodeId)
            )
        } else {
            deliver(message)
        }
    }

    // MARK: - Emoji Reaction

    private func handleEmojiReaction(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        let targetPacketId = data.replyID
        let emojiStr = Self.decodeEmojiReaction(data)
        let isBroadcast = packet.to == 0xFFFFFFFF || packet.to == 0
        let context: MessageStorageContext
        if isBroadcast {
            context = .channel(resolvedChannelIndex(for: packet.channel))
        } else {
            let partnerId = packet.from == myNodeId ? packet.to : packet.from
            context = .directMessage(partnerNodeId: partnerId)
        }

        appState?.addReaction(
            emoji: emojiStr,
            from: packet.from,
            toPacketId: targetPacketId,
            context: context
        )

        if SettingsService.shared.debugMessages {
            AppLogger.shared.log("[Reaction] \(nodeDisplayName(packet.from)) reacted \(emojiStr) to packet \(targetPacketId)", debug: true)
        }
    }

    func sendEmojiReaction(_ emoji: String, toPacketId: UInt32, toNodeId: UInt32 = 0xFFFFFFFF, channelIndex: Int = 0) async {
        let packetId = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)

        var packet = Meshtastic_MeshPacket()
        packet.from = myNodeId
        packet.id = packetId
        packet.to = toNodeId
        packet.channel = UInt32(channelIndex)
        packet.hopLimit = 7
        packet.wantAck = true

        let data = Self.makeEmojiReactionData(emoji: emoji, replyID: toPacketId)

        packet.decoded = data
        await sendToRadio(packet: packet)

        // Apply reaction locally
        let context: MessageStorageContext = (toNodeId == 0xFFFFFFFF || toNodeId == 0)
            ? .channel(channelIndex)
            : .directMessage(partnerNodeId: toNodeId)
        appState?.addReaction(
            emoji: emoji,
            from: myNodeId,
            toPacketId: toPacketId,
            context: context
        )
    }

    /// Meshtastic uses `emoji` as a boolean marker. The actual (possibly
    /// multi-scalar) emoji is UTF-8 encoded in the payload.
    nonisolated static func decodeEmojiReaction(_ data: Meshtastic_Data) -> String {
        if let payloadEmoji = String(bytes: data.payload, encoding: .utf8),
           !payloadEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return payloadEmoji
        }

        // Compatibility with older MeshHessen builds that incorrectly stored a
        // single Unicode scalar in the marker field.
        if data.emoji > 1,
           let scalar = Unicode.Scalar(data.emoji),
           !CharacterSet.controlCharacters.contains(scalar) {
            return String(scalar)
        }

        return "👍"
    }

    nonisolated static func makeEmojiReactionData(emoji: String, replyID: UInt32) -> Meshtastic_Data {
        var data = Meshtastic_Data()
        data.portnum = .textMessageApp
        data.payload = Data(emoji.utf8)
        data.replyID = replyID
        data.emoji = 1
        return data
    }

    /// Builds a regular text payload, optionally referencing another packet.
    /// An emoji marker is deliberately not set so replies remain distinct from reactions.
    nonisolated static func makeTextMessageData(text: String, replyToPacketId: UInt32? = nil) -> Meshtastic_Data {
        var data = Meshtastic_Data()
        data.portnum = .textMessageApp
        data.payload = Data(text.utf8)
        if let replyToPacketId, replyToPacketId != 0 {
            data.replyID = replyToPacketId
        }
        return data
    }

    // MARK: - Routing / ACK

    private func handleRoutingPacket(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        guard data.requestID != 0 else { return }

        // The official Meshtastic Routing message includes an error_reason field
        // (field number 3, varint type) that isn't in our slim proto.
        // Parse it from the raw payload to determine success vs. error code.
        let errorCode = parseRoutingErrorReason(from: data.payload)
        let routingError = RoutingError(rawValue: errorCode) ?? .none
        let matchedAdminRequest = adminRoutingTracker.record(
            requestID: data.requestID,
            sourceNodeID: packet.from,
            error: routingError
        )
        if matchedAdminRequest, routingError != .none {
            AppLogger.shared.log(
                "[Admin] Routing NACK correlated with packetID=\(data.requestID): \(routingError.display)",
                debug: true
            )
        }
        let storageContext: MessageStorageContext? = {
            if packet.from != 0 && packet.from != myNodeId {
                return .directMessage(partnerNodeId: packet.from)
            }
            guard let message = appState?.findMessageByPacketId(data.requestID) else {
                let channelIndex = resolvedChannelIndex(for: packet.channel)
                return channelIndex >= 0 ? .channel(channelIndex) : nil
            }
            if message.isDirect {
                let partnerNodeId = message.fromId == myNodeId ? message.toId : message.fromId
                return .directMessage(partnerNodeId: partnerNodeId)
            }
            return .channel(message.channelIndex)
        }()

        // For DMs (unicast): ignore the local ACK from our own node — only
        // mark as acknowledged when the actual destination node responds.
        // The firmware sends a local routing ACK when it accepts the ToRadio
        // packet, but that doesn't mean the recipient received it.
        // For broadcasts/channel messages: accept the local ACK since no
        // destination node will send a separate ACK.
        let isFromSelf = packet.from == myNodeId
        if isFromSelf && routingError == .none {
            let isDirect = appState?.findMessageByPacketId(data.requestID, context: storageContext)?.isDirect ?? false
            if isDirect {
                AppLogger.shared.log(
                    "[ACK] Local ACK for requestId=\(data.requestID) (ignoring — waiting for destination ACK)",
                    debug: SettingsService.shared.debugMessages
                )
                return
            }
            // Broadcast: fall through — accept local ACK as delivery confirmation
        }

        let deliveryState: MessageDeliveryState
        if routingError == .none {
            deliveryState = .acknowledged
        } else {
            deliveryState = .failed(routingError.display)
        }

        appState?.updateDeliveryState(
            requestId: data.requestID,
            state: deliveryState,
            context: storageContext
        )
        coreDataStore?.updateDeliveryState(
            requestId: data.requestID,
            state: deliveryState,
            storageContext: storageContext
        )

        if routingError == .none {
            telemetryDatabase.markAckReceived(packetId: data.requestID)
        }

        if routingError == .none {
            AppLogger.shared.log(
                "[ACK] Routing ACK for requestId=\(data.requestID) from \(String(format: "!%08x", packet.from))",
                debug: SettingsService.shared.debugMessages
            )
        } else {
            AppLogger.shared.log(
                "[ACK] Routing NACK for requestId=\(data.requestID): \(routingError.display) (canRetry=\(routingError.canRetry))",
                debug: SettingsService.shared.debugMessages
            )
        }
    }

    /// Parses the `error_reason` (field 3, varint) from a Routing protobuf payload.
    /// Returns 0 (none/success) if the field is absent or the payload is empty.
    private func parseRoutingErrorReason(from payload: Data) -> Int {
        // Quick path: if payload is the Routing message with just
        // error_reason (field 3, wire type 0 = varint), the tag byte is 0x18.
        // We scan for this tag and read the varint value.
        var idx = payload.startIndex
        while idx < payload.endIndex {
            // Read tag
            let (tag, tagBytes) = decodeVarint(payload, from: idx)
            guard tagBytes > 0 else { return 0 }
            idx += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            if fieldNumber == 3 && wireType == 0 {
                // Varint — this is error_reason
                let (value, _) = decodeVarint(payload, from: idx)
                return Int(value)
            }

            // Skip other fields
            switch wireType {
            case 0: // varint
                let (_, vBytes) = decodeVarint(payload, from: idx)
                guard vBytes > 0 else { return 0 }
                idx += vBytes
            case 1: // 64-bit
                idx += 8
            case 2: // length-delimited
                let (length, lBytes) = decodeVarint(payload, from: idx)
                guard lBytes > 0 else { return 0 }
                idx += lBytes + Int(length)
            case 5: // 32-bit
                idx += 4
            default:
                return 0 // Unknown wire type
            }
        }
        return 0
    }

    /// Decodes a protobuf varint at the given index. Returns (value, bytesConsumed).
    private func decodeVarint(_ data: Data, from start: Data.Index) -> (UInt64, Int) {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var idx = start
        while idx < data.endIndex {
            let byte = data[idx]
            result |= UInt64(byte & 0x7F) << shift
            idx += 1
            if byte & 0x80 == 0 {
                return (result, idx - start)
            }
            shift += 7
            if shift >= 64 { return (0, 0) }
        }
        return (0, 0)
    }

    // MARK: - Position

    private func handlePosition(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        guard let pos = try? Meshtastic_Position(serializedBytes: data.payload) else {
            AppLogger.shared.log("[Protocol] Position parse failed from \(String(format: "!%08x", packet.from))", debug: SettingsService.shared.debugDevice)
            return
        }
        guard pos.latitudeI != 0 || pos.longitudeI != 0 else { return }

        let lat = Double(pos.latitudeI) / 1e7
        let lon = Double(pos.longitudeI) / 1e7
        let alt = Int(pos.altitude)

        if let node = appState?.node(forId: packet.from) {
            node.latitude = lat
            node.longitude = lon
            node.altitude = alt
            node.groundSpeed = pos.groundSpeed
            node.groundTrack = pos.groundTrack
            appState?.recalculateDistance(for: packet.from)
        }

        // Location logging
        if SettingsService.shared.locationLoggingEnabled {
            let name = appState?.node(forId: packet.from)?.name ?? String(format: "!%08x", packet.from)
            LocationLogger.shared.logPosition(nodeId: packet.from, name: name, latitude: lat, longitude: lon, altitude: alt)
        }
    }

    // MARK: - NodeInfo (portnum 4)

    private func handleNodeInfoPacket(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        guard let user = try? Meshtastic_User(serializedBytes: data.payload) else {
            AppLogger.shared.log("[Protocol] NodeInfo(user) parse failed from \(String(format: "!%08x", packet.from))", debug: SettingsService.shared.debugDevice)
            return
        }

        // If this is our own node
        if packet.from == myNodeId || myNodeId == 0 {
            let existingFW = appState?.myNodeInfo?.firmwareVersion ?? ""
            let hwModel = user.hwModel != .unset ? hardwareModelName(user.hwModel) : (appState?.myNodeInfo?.hardwareModel ?? "Unknown")
            appState?.myNodeInfo = MyNodeInfo(
                nodeId: packet.from,
                shortName: user.shortName,
                longName: user.longName,
                hardwareModel: hwModel,
                firmwareVersion: existingFW
            )
        }

        let nodeId = packet.from
        let node = makeNodeInfo(from: user, num: nodeId)
        appState?.upsertNode(node)
        coreDataStore?.upsertNode(node)
    }

    // MARK: - NodeInfo (from NodeInfo message)

    private func handleNodeInfo(_ info: Meshtastic_NodeInfo) {
        let user = info.user
        let node = makeNodeInfo(from: user, num: info.num)

        // Apply GPS if present
        let position = info.position
        if position.latitudeI != 0 || position.longitudeI != 0 {
            node.latitude = Double(position.latitudeI) / 1e7
            node.longitude = Double(position.longitudeI) / 1e7
            node.altitude = Int(position.altitude)
            node.groundSpeed = position.groundSpeed
            node.groundTrack = position.groundTrack
        }

        // Apply telemetry
        node.snrFloat = info.snr
        node.snr = info.snr != 0 ? String(format: "%.1f dB", info.snr) : "-"
        node.lastHeard = Int32(bitPattern: info.lastHeard)
        node.lastSeen = info.lastHeard > 0 ? formatTimestamp(Int(info.lastHeard)) : "-"
        let metrics = info.deviceMetrics
        node.batteryLevel = metrics.batteryLevel
        node.battery = metrics.batteryLevel > 0 ? "\(metrics.batteryLevel)%" : "-"
        node.viaMqtt = info.viaMqtt
        node.hopsAway = info.hopsAway > 0 ? Int(info.hopsAway) : (info.viaMqtt ? nil : 0)
        node.isFavorite = info.isFavorite
        node.isOwnNode = info.num == myNodeId

        // Apply saved color/note from settings
        node.colorHex = SettingsService.shared.colorHex(for: info.num)
        node.note = SettingsService.shared.note(for: info.num)

        if info.num == myNodeId {
            let existingFW = appState?.myNodeInfo?.firmwareVersion ?? ""
            let hwModel = user.hwModel != .unset ? hardwareModelName(user.hwModel) : (appState?.myNodeInfo?.hardwareModel ?? "Unknown")
            appState?.myNodeInfo = MyNodeInfo(
                nodeId: info.num,
                shortName: user.shortName,
                longName: user.longName,
                hardwareModel: hwModel,
                firmwareVersion: existingFW
            )
        }

        appState?.upsertNode(node)
        coreDataStore?.upsertNode(node)

        AppLogger.shared.log("[Protocol] NodeInfo: \(node.name) (\(node.nodeId))", debug: SettingsService.shared.debugDevice)
    }

    // MARK: - Channel

    private func handleChannel(_ channel: Meshtastic_Channel, sourceNodeID: UInt32) {
        if isCollectingChannelSnapshot {
            guard tempChannels.record(channel, from: sourceNodeID) else { return }
            AppLogger.shared.log(
                "[Protocol] Channel slot \(channel.index) received (\(channel.role)); "
                    + "\(tempChannels.receivedIndices.count)/\(tempChannels.requestedIndices.count)",
                debug: SettingsService.shared.debugDevice
            )
            return
        }

        if channel.role == .disabled {
            appState?.channels.removeAll { $0.id == Int(channel.index) }
            AppLogger.shared.log(
                "[Protocol] Channel \(channel.index) disabled",
                debug: SettingsService.shared.debugDevice
            )
            return
        }
        let info = channelInfo(from: channel)
        if let idx = appState?.channels.firstIndex(where: { $0.id == info.id }) {
            appState?.channels[idx] = info
        } else {
            appState?.channels.append(info)
        }
        appState?.channels.sort { $0.id < $1.id }
        coreDataStore?.upsertChannel(info)

        AppLogger.shared.log(
            "[Protocol] Channel \(channel.index): \(info.name) [\(info.role)]",
            debug: SettingsService.shared.debugDevice
        )
    }

    private func channelInfo(from channel: Meshtastic_Channel) -> ChannelInfo {
        let name = extractChannelName(channel)
        let s = channel.settings
        let pskBase64 = s.psk.base64EncodedString()
        return ChannelInfo(
            id: Int(channel.index),
            name: name,
            psk: pskBase64,
            role: channel.role == .primary ? "PRIMARY" : "SECONDARY",
            uplinkEnabled: s.uplinkEnabled,
            downlinkEnabled: s.downlinkEnabled
        )
    }

    private func finishChannelSnapshot() {
        defer { isCollectingChannelSnapshot = false }
        guard tempChannels.isComplete else {
            let missing = tempChannels.requestedIndices.subtracting(tempChannels.receivedIndices).sorted()
            AppLogger.shared.log(
                "[Protocol] Channel snapshot incomplete; preserving current channels. Missing slots: \(missing)",
                debug: true
            )
            return
        }

        let activeChannels = tempChannels.activeChannels.map { channelInfo(from: $0) }
        appState?.channels = activeChannels
        activeChannels.forEach { coreDataStore?.upsertChannel($0) }
        coreDataStore?.removeChannelsNotIn(indices: Set(activeChannels.map(\.id)))
        AppLogger.shared.log(
            "[Protocol] Published authoritative channel snapshot with \(activeChannels.count) active slots",
            debug: true
        )
    }

    private func beginChannelSnapshot(for targetNodeID: UInt32, requestedIndices: Set<Int> = Set(0..<8)) {
        tempChannels.begin(targetNodeID: targetNodeID, requestedIndices: requestedIndices)
        isCollectingChannelSnapshot = true
    }

    private func cancelChannelSnapshot() {
        isCollectingChannelSnapshot = false
    }

    private func extractChannelName(_ channel: Meshtastic_Channel) -> String {
        let s = channel.settings
        if !s.name.isEmpty { return s.name }
        if channel.role == .primary { return "Default" }
        return "Channel \(channel.index)"
    }

    // MARK: - Config

    private func handleConfig(_ config: Meshtastic_Config) {
        switch config.payloadVariant {
        case .lora:
            receivedConfigs[.lora] = config
            AppLogger.shared.log("[Protocol] Config: LoRa region=\(config.lora.region.rawValue) modem=\(config.lora.modemPreset.rawValue) hopLimit=\(config.lora.hopLimit) txEnabled=\(config.lora.txEnabled)", debug: SettingsService.shared.debugDevice)
        case .device:
            receivedConfigs[.device] = config
            AppLogger.shared.log("[Protocol] Config: Device", debug: SettingsService.shared.debugDevice)
        case .position:
            receivedConfigs[.position] = config
            AppLogger.shared.log("[Protocol] Config: Position", debug: SettingsService.shared.debugDevice)
        case .power:
            receivedConfigs[.power] = config
            AppLogger.shared.log("[Protocol] Config: Power", debug: SettingsService.shared.debugDevice)
        case .network:
            receivedConfigs[.network] = config
            AppLogger.shared.log("[Protocol] Config: Network wifiEnabled=\(config.network.wifiEnabled) ssid='\(config.network.wifiSsid)' psk=\(config.network.wifiPsk.isEmpty ? "empty" : "set") ntp='\(config.network.ntpServer)'", debug: SettingsService.shared.debugDevice)
        case .display:
            receivedConfigs[.display] = config
            AppLogger.shared.log("[Protocol] Config: Display", debug: SettingsService.shared.debugDevice)
        case .bluetooth:
            receivedConfigs[.bluetooth] = config
            AppLogger.shared.log("[Protocol] Config: Bluetooth", debug: SettingsService.shared.debugDevice)
        case .security:
            receivedConfigs[.security] = config
            let sec = config.security
            if !sec.privateKey.isEmpty {
                PkiDecryptionService.shared.setPrivateKey(sec.privateKey)
            }
            AppLogger.shared.log("[Protocol] Config: Security (pubKey=\(sec.publicKey.count)B, privKey=\(sec.privateKey.count)B)", debug: SettingsService.shared.debugDevice)
        case .sessionkey:
            receivedConfigs[.session] = config
            // SessionkeyConfig is an empty message — the actual session key
            // comes via admin.sessionPasskey (handled in handleAdminPacket).
            AppLogger.shared.log("[Protocol] Config: Sessionkey", debug: SettingsService.shared.debugDevice)
        case .deviceUi:
            receivedConfigs[.deviceUI] = config
            AppLogger.shared.log("[Protocol] Config: DeviceUI", debug: SettingsService.shared.debugDevice)
        case .none:
            AppLogger.shared.log("[Protocol] Config received (empty)", debug: SettingsService.shared.debugDevice)
        }
    }

    private func handleModuleConfig(_ moduleConfig: Meshtastic_ModuleConfig) {
        switch moduleConfig.payloadVariant {
        case .mqtt:
            receivedModuleConfigs["mqtt"] = moduleConfig
            onMqttConfigurationReceived?(moduleConfig.mqtt)
            AppLogger.shared.log("[Protocol] ModuleConfig: MQTT", debug: SettingsService.shared.debugDevice)
        case .serial:
            receivedModuleConfigs["serial"] = moduleConfig
            AppLogger.shared.log("[Protocol] ModuleConfig: Serial", debug: SettingsService.shared.debugDevice)
        case .telemetry:
            receivedModuleConfigs["telemetry"] = moduleConfig
            AppLogger.shared.log("[Protocol] ModuleConfig: Telemetry", debug: SettingsService.shared.debugDevice)
        case .externalNotification:
            receivedModuleConfigs[MeshModuleConfigCategory.externalNotification.rawValue] = moduleConfig
        case .storeForward:
            receivedModuleConfigs[MeshModuleConfigCategory.storeForward.rawValue] = moduleConfig
        case .rangeTest:
            receivedModuleConfigs[MeshModuleConfigCategory.rangeTest.rawValue] = moduleConfig
        case .cannedMessage:
            receivedModuleConfigs[MeshModuleConfigCategory.cannedMessage.rawValue] = moduleConfig
        case .audio:
            receivedModuleConfigs[MeshModuleConfigCategory.audio.rawValue] = moduleConfig
        case .remoteHardware:
            receivedModuleConfigs[MeshModuleConfigCategory.remoteHardware.rawValue] = moduleConfig
        case .neighborInfo:
            receivedModuleConfigs[MeshModuleConfigCategory.neighborInfo.rawValue] = moduleConfig
        case .ambientLighting:
            receivedModuleConfigs[MeshModuleConfigCategory.ambientLighting.rawValue] = moduleConfig
        case .detectionSensor:
            receivedModuleConfigs[MeshModuleConfigCategory.detectionSensor.rawValue] = moduleConfig
        case .paxcounter:
            receivedModuleConfigs[MeshModuleConfigCategory.paxcounter.rawValue] = moduleConfig
        case .statusmessage:
            receivedModuleConfigs[MeshModuleConfigCategory.statusMessage.rawValue] = moduleConfig
        case .trafficManagement:
            receivedModuleConfigs[MeshModuleConfigCategory.trafficManagement.rawValue] = moduleConfig
        case .tak:
            receivedModuleConfigs[MeshModuleConfigCategory.tak.rawValue] = moduleConfig
        case nil:
            AppLogger.shared.log("[Protocol] ModuleConfig received (empty)", debug: SettingsService.shared.debugDevice)
        }
    }

    // MARK: - Admin

    private func handleAdminPacket(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        guard let admin = try? Meshtastic_AdminMessage(serializedBytes: data.payload) else {
            AppLogger.shared.log("[Protocol] Admin parse failed from \(String(format: "!%08x", packet.from))", debug: true)
            return
        }

        AppLogger.shared.log("[Protocol] Admin response: \(String(describing: admin.payloadVariant)), passkey=\(admin.sessionPasskey.count) bytes", debug: true)

        adminResponseSequence &+= 1
        adminResponses.append(
            AdminResponseRecord(
                sequence: adminResponseSequence,
                sourceNodeID: packet.from,
                requestID: data.requestID,
                message: admin
            )
        )
        if adminResponses.count > 512 {
            adminResponses.removeFirst(adminResponses.count - 512)
        }

        // Session keys are scoped to the responding node and expire after five
        // minutes. Keeping remote keys separate prevents a remote read from
        // invalidating subsequent local configuration writes.
        if !admin.sessionPasskey.isEmpty {
            if packet.from == myNodeId {
                sessionPasskey = admin.sessionPasskey
                localSessionPasskeyDate = Date()
            } else if packet.from != 0 {
                remoteSessionPasskeys[packet.from] = admin.sessionPasskey
                remoteSessionPasskeyDates[packet.from] = Date()
            }
            AppLogger.shared.log("[Protocol] Session passkey updated for \(String(format: "!%08x", packet.from)) (\(admin.sessionPasskey.count) bytes)", debug: true)
        }

        switch admin.payloadVariant {
        case .getChannelResponse(let channel):
            if packet.from == myNodeId {
                handleChannel(channel, sourceNodeID: packet.from)
            }
        case .getOwnerResponse(let owner):
            if packet.from == myNodeId {
                appState?.myNodeInfo?.shortName = owner.shortName
                appState?.myNodeInfo?.longName = owner.longName
                if let node = appState?.node(forId: packet.from) {
                    node.shortName = owner.shortName
                    node.longName = owner.longName
                    node.name = owner.longName.isEmpty ? owner.shortName : owner.longName
                }
            }
        case .getConfigResponse(let config):
            if packet.from == myNodeId { handleConfig(config) }
            AppLogger.shared.log("[Protocol] Admin getConfigResponse received", debug: true)
        case .getModuleConfigResponse(let moduleConfig):
            if packet.from == myNodeId { handleModuleConfig(moduleConfig) }
            AppLogger.shared.log("[Protocol] Admin getModuleConfigResponse received", debug: true)
        case .getDeviceMetadataResponse(let meta):
            if packet.from == myNodeId { handleDeviceMetadata(meta) }
        case .getUiConfigResponse(let config):
            if packet.from == myNodeId {
                var wrapper = Meshtastic_Config()
                wrapper.deviceUi = config
                handleConfig(wrapper)
            }
        default:
            break
        }
    }

    // MARK: - DeviceMetadata

    private func handleDeviceMetadata(_ meta: Meshtastic_DeviceMetadata) {
        if !meta.firmwareVersion.isEmpty {
            appState?.myNodeInfo?.firmwareVersion = meta.firmwareVersion
        }
        if meta.hwModel != .unset {
            appState?.myNodeInfo?.hardwareModel = hardwareModelName(meta.hwModel)
        }
        AppLogger.shared.log("[Protocol] DeviceMetadata: FW=\(meta.firmwareVersion), HW=\(meta.hwModel)", debug: SettingsService.shared.debugDevice)
    }

    private func requestDeviceMetadata() async {
        await ensureSessionKey()
        guard !sessionPasskey.isEmpty else { return }
        var admin = Meshtastic_AdminMessage()
        admin.getDeviceMetadataRequest = true
        admin.sessionPasskey = sessionPasskey
        await sendAdminMessage(admin)
        AppLogger.shared.log("[Protocol] Requested DeviceMetadata", debug: SettingsService.shared.debugDevice)
    }

    private func requestSecurityConfig() async {
        await ensureSessionKey()
        guard !sessionPasskey.isEmpty else { return }
        var admin = Meshtastic_AdminMessage()
        admin.getConfigRequest = .securityConfig
        admin.sessionPasskey = sessionPasskey
        await sendAdminMessage(admin)
        AppLogger.shared.log("[Protocol] Requested SecurityConfig", debug: SettingsService.shared.debugDevice)
    }

    // MARK: - Waypoint (portnum 8)

    private func handleWaypointPacket(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        let from = nodeDisplayName(packet.from)
        let protobuf: Meshtastic_Waypoint
        do {
            protobuf = try Meshtastic_Waypoint(serializedBytes: data.payload)
        } catch {
            AppLogger.shared.log("[Waypoint] Invalid payload from \(from): \(error.localizedDescription)")
            return
        }

        let expiration = protobuf.expire == 0
            ? nil
            : Date(timeIntervalSince1970: TimeInterval(protobuf.expire))
        let waypoint = MeshWaypoint(
            id: protobuf.id,
            latitude: Double(protobuf.latitudeI) / 1e7,
            longitude: Double(protobuf.longitudeI) / 1e7,
            name: protobuf.name,
            detail: protobuf.description_p,
            icon: protobuf.icon,
            expiration: expiration,
            lockedTo: protobuf.lockedTo,
            sourceNodeId: packet.from,
            channelIndex: packet.channel,
            receivedAt: Date()
        )

        if waypoint.isExpired {
            waypoints.removeValue(forKey: waypoint.id)
            AppLogger.shared.log("[Waypoint] Removed expired waypoint \(waypoint.id)", debug: SettingsService.shared.debugDevice)
            return
        }

        waypoints[waypoint.id] = waypoint

        AppLogger.shared.log(
            "[Waypoint] From \(from): \"\(waypoint.displayName)\" id=\(waypoint.id) at (\(String(format: "%.5f", waypoint.latitude)), \(String(format: "%.5f", waypoint.longitude)))",
            debug: SettingsService.shared.debugDevice
        )

        // Inject as a channel message so the user sees it
        let ts = formatTime()
        let chIndex = resolvedChannelIndex(for: packet.channel)
        let chName = channelName(for: Int(packet.channel))
        let node = appState?.node(forId: packet.from)
        let msg = MessageItem(
            packetId: packet.id,
            time: ts, from: from, fromId: packet.from, toId: packet.to,
            message: String(localized: "📍 Waypoint: \(waypoint.displayName) (\(String(format: "%.5f", waypoint.latitude)), \(String(format: "%.5f", waypoint.longitude)))"),
            channelIndex: chIndex,
            channelName: chName,
            isViaMqtt: packet.viaMqtt,
            senderShortName: node?.shortName ?? "",
            senderColorHex: node?.colorHex ?? "",
            senderNote: node?.note ?? "",
            hopCount: packet.viaMqtt ? nil : Self.hopCount(hopStart: packet.hopStart, hopLimit: packet.hopLimit),
            receivedSnr: packet.viaMqtt || packet.rxSnr == 0 ? nil : packet.rxSnr,
            receivedRssi: packet.viaMqtt || packet.rxRssi == 0 ? nil : Int(packet.rxRssi)
        )
        deliver(msg)
    }

    @discardableResult
    func sendWaypoint(
        _ waypoint: MeshWaypoint,
        toNodeId: UInt32 = 0xFFFFFFFF,
        channelIndex: Int = 0
    ) async -> Bool {
        guard myNodeId != 0 else { return false }

        var protobuf = Meshtastic_Waypoint()
        protobuf.id = waypoint.id
        protobuf.latitudeI = Int32((waypoint.latitude * 1e7).rounded())
        protobuf.longitudeI = Int32((waypoint.longitude * 1e7).rounded())
        protobuf.expire = waypoint.expiration.map {
            UInt32(clamping: Int($0.timeIntervalSince1970))
        } ?? 0
        protobuf.lockedTo = waypoint.lockedTo
        protobuf.name = String(waypoint.name.prefix(30))
        protobuf.description_p = String(waypoint.detail.prefix(100))
        protobuf.icon = waypoint.icon

        guard let payload = try? protobuf.serializedData() else { return false }
        var decoded = Meshtastic_Data()
        decoded.portnum = .waypointApp
        decoded.payload = payload

        var packet = Meshtastic_MeshPacket()
        packet.from = myNodeId
        packet.to = toNodeId
        packet.channel = UInt32(clamping: channelIndex)
        packet.id = UInt32.random(in: 1..<UInt32.max)
        packet.hopLimit = 7
        packet.wantAck = true
        packet.decoded = decoded

        let sent = await sendToRadio(packet: packet)
        if sent { waypoints[waypoint.id] = waypoint }
        return sent
    }

    @discardableResult
    func deleteWaypoint(
        id: UInt32,
        lockedTo: UInt32 = 0,
        toNodeId: UInt32 = 0xFFFFFFFF,
        channelIndex: Int = 0
    ) async -> Bool {
        let deletion = MeshWaypoint(
            id: id,
            latitude: 0,
            longitude: 0,
            name: "",
            detail: "",
            icon: 0,
            expiration: Date(timeIntervalSince1970: 1),
            lockedTo: lockedTo,
            sourceNodeId: myNodeId,
            channelIndex: UInt32(clamping: channelIndex),
            receivedAt: Date()
        )
        let sent = await sendWaypoint(deletion, toNodeId: toNodeId, channelIndex: channelIndex)
        if sent { waypoints.removeValue(forKey: id) }
        return sent
    }

    // MARK: - Traceroute (portnum 70)

    /// Pending traceroute requests keyed by packet ID
    var pendingTraceroutes: [UInt32: TracerouteResult] = [:]

    /// Completed traceroute results (most recent first)
    var tracerouteResults: [TracerouteResult] = TracerouteStore.shared.loadAll()
        .sorted { $0.requestTime > $1.requestTime }

    /// Uses the generated protobuf decoder so malformed/truncated payloads throw
    /// instead of advancing a hand-written cursor beyond the payload bounds.
    nonisolated static func decodeRouteDiscovery(_ payload: Data) throws -> Meshtastic_RouteDiscovery {
        try Meshtastic_RouteDiscovery(serializedBytes: payload)
    }

    private func handleTraceroutePacket(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        let route: Meshtastic_RouteDiscovery
        do {
            route = try Self.decodeRouteDiscovery(data.payload)
        } catch {
            AppLogger.shared.log(
                "[Protocol] Traceroute parse failed from \(String(format: "!%08x", packet.from)): \(error.localizedDescription)",
                debug: SettingsService.shared.debugDevice
            )
            return
        }

        let from = nodeDisplayName(packet.from)
        let hopNodeIds = route.route
        let hopNames = hopNodeIds.map { nodeDisplayName($0) }
        let hopStr = hopNames.isEmpty ? "(direct)" : hopNames.joined(separator: " → ")

        AppLogger.shared.log(
            "[Traceroute] From \(from): route = \(hopStr) (\(hopNames.count) hops)",
            debug: SettingsService.shared.debugDevice
        )

        let snrTowards = route.snrTowards

        // Build TracerouteResult
        var hops: [TracerouteHop] = []
        for (i, hopNodeId) in hopNodeIds.enumerated() {
            let hopNode = appState?.node(forId: hopNodeId)
            let snr: Float? = i < snrTowards.count ? Float(snrTowards[i]) / 4.0 : nil
            hops.append(TracerouteHop(
                nodeId: hopNodeId,
                nodeName: hopNode?.name ?? nodeDisplayName(hopNodeId),
                snr: snr,
                latitude: hopNode?.latitude,
                longitude: hopNode?.longitude,
                viaMqtt: hopNode?.viaMqtt ?? false
            ))
        }

        // Add the target node as the final hop
        let targetNode = appState?.node(forId: packet.from)
        hops.append(TracerouteHop(
            nodeId: packet.from,
            nodeName: targetNode?.name ?? from,
            latitude: targetNode?.latitude,
            longitude: targetNode?.longitude,
            viaMqtt: targetNode?.viaMqtt ?? false
        ))

        // Check if this is a response to a pending request
        if let requestId = data.requestID != 0 ? data.requestID : nil,
           let pending = pendingTraceroutes.removeValue(forKey: requestId) {
            let responseTime = Date()
            let completed = TracerouteResult(
                requestId: requestId,
                requestTime: pending.requestTime,
                sourceNodeId: myNodeId,
                targetNodeId: pending.targetNodeId,
                targetName: pending.targetName,
                hops: hops,
                responseTime: responseTime
            )
            storeTracerouteResult(completed)
        } else {
            let result = TracerouteResult(
                requestId: data.requestID != 0 ? data.requestID : packet.id,
                sourceNodeId: myNodeId,
                targetNodeId: packet.from,
                targetName: from,
                hops: hops,
                responseTime: Date()
            )
            storeTracerouteResult(result)
        }

        // Insert traceroute hops into telemetry database
        let traceHops = hops.enumerated().map { (i, hop) in
            (nodeId: hop.nodeId, snrTowards: hop.snr, snrBack: nil as Float?)
        }
        telemetryDatabase.insertTracerouteHops(
            requestId: data.requestID != 0 ? data.requestID : packet.id,
            sourceNodeId: myNodeId,
            destNodeId: packet.from,
            hops: traceHops
        )

    }

    private func storeTracerouteResult(_ result: TracerouteResult) {
        tracerouteResults.insert(result, at: 0)
        TracerouteStore.shared.save(result)

        if let targetNode = appState?.node(forId: result.targetNodeId) {
            targetNode.lastTracerouteHopCount = result.hops.count
        }
        coreDataStore?.updateNodeTracerouteHopCount(
            nodeId: result.targetNodeId,
            hopCount: result.hops.count
        )
    }

    /// Send a traceroute request to a target node
    func sendTraceroute(to targetNodeId: UInt32) async -> Bool {
        let packetId = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)

        let routeDiscovery = Meshtastic_RouteDiscovery()
        _ = routeDiscovery // empty request

        guard let payload = try? routeDiscovery.serializedData() else { return false }

        var data = Meshtastic_Data()
        data.portnum = .tracerouteApp
        data.payload = payload
        data.wantResponse = true

        var packet = Meshtastic_MeshPacket()
        packet.id = packetId
        packet.to = targetNodeId
        packet.hopLimit = 7
        packet.wantAck = true
        packet.decoded = data

        // Record pending traceroute
        let targetName = nodeDisplayName(targetNodeId)
        let pending = TracerouteResult(
            requestId: packetId,
            sourceNodeId: myNodeId,
            targetNodeId: targetNodeId,
            targetName: targetName
        )
        pendingTraceroutes[packetId] = pending

        guard await sendToRadio(packet: packet) else {
            pendingTraceroutes.removeValue(forKey: packetId)
            return false
        }

        AppLogger.shared.log("[Traceroute] Request sent to \(targetName) (packetId=\(packetId))", debug: true)
        return true
    }

    // MARK: - Device Config (admin requests)

    /// Request all device configs from the connected node via admin messages.
    /// Config request field numbers: 0=Device, 1=Position, 2=Power, 3=Network, 4=Display, 5=LoRa, 6=Bluetooth
    /// Module config request field numbers: 0=MQTT
    func requestAllDeviceConfigs(timeout: Duration = .seconds(10)) async throws -> DeviceConfigSnapshot {
        guard connectionService?.isConnected == true else {
            throw DeviceConfigError.notConnected
        }
        await ensureSessionKey()
        guard !sessionPasskey.isEmpty else {
            AppLogger.shared.log("[Protocol] requestAllDeviceConfigs aborted: no session key", debug: true)
            throw DeviceConfigError.missingSessionKey
        }

        receivedConfigs.removeAll()
        receivedModuleConfigs.removeValue(forKey: "mqtt")

        // Request each config type
        let configTypes: [Meshtastic_AdminMessage.ConfigType] = [
            .deviceConfig, .positionConfig, .powerConfig,
            .networkConfig, .displayConfig, .loraConfig, .bluetoothConfig
        ]
        for configType in configTypes {
            var admin = Meshtastic_AdminMessage()
            admin.getConfigRequest = configType
            admin.sessionPasskey = sessionPasskey
            guard await sendAdminMessage(admin) else {
                throw DeviceConfigError.requestFailed
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Request MQTT module config
        var mqttAdmin = Meshtastic_AdminMessage()
        mqttAdmin.getModuleConfigRequest = .mqttConfig
        mqttAdmin.sessionPasskey = sessionPasskey
        guard await sendAdminMessage(mqttAdmin) else {
            throw DeviceConfigError.requestFailed
        }
        AppLogger.shared.log("[Protocol] Requested all device configs", debug: SettingsService.shared.debugDevice)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if let snapshot = currentDeviceConfigSnapshot {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw DeviceConfigError.incompleteResponse(missingDeviceConfigCategories)
    }

    /// Save only changed device configs back to the node.
    /// Returns `true` when a commit was sent and the node is expected to reboot.
    func saveDeviceConfigs(_ snapshot: DeviceConfigSnapshot, replacing original: DeviceConfigSnapshot) async throws -> Bool {
        guard snapshot != original else { return false }
        guard connectionService?.isConnected == true else {
            throw DeviceConfigError.notConnected
        }
        await ensureSessionKey()
        guard !sessionPasskey.isEmpty else {
            AppLogger.shared.log("[Protocol] saveDeviceConfigs aborted: no session key", debug: true)
            throw DeviceConfigError.missingSessionKey
        }

        // Begin edit settings session
        var beginEdit = Meshtastic_AdminMessage()
        beginEdit.beginEditSettings = true
        beginEdit.sessionPasskey = sessionPasskey
        guard await sendAdminMessage(beginEdit) else {
            throw DeviceConfigError.writeFailed("Begin Edit")
        }

        // Avoid writing unchanged categories. Besides being faster, this prevents a
        // partial load from overwriting valid device settings with default values.
        let configs: [(String, Meshtastic_Config.OneOf_PayloadVariant)] = [
            ("Device", .device(snapshot.device)),
            ("Position", .position(snapshot.position)),
            ("Power", .power(snapshot.power)),
            ("Network", .network(snapshot.network)),
            ("Display", .display(snapshot.display)),
            ("LoRa", .lora(snapshot.lora)),
            ("Bluetooth", .bluetooth(snapshot.bluetooth)),
        ]
        let changedCategories = Set(Self.changedDeviceConfigCategories(snapshot, replacing: original))

        for entry in configs where changedCategories.contains(entry.0) {
            var config = Meshtastic_Config()
            config.payloadVariant = entry.1
            var admin = Meshtastic_AdminMessage()
            admin.setConfig = config
            admin.sessionPasskey = sessionPasskey
            guard await sendAdminMessage(admin) else {
                throw DeviceConfigError.writeFailed(entry.0)
            }
            try await Task.sleep(for: .milliseconds(300))
        }

        if snapshot.mqtt != original.mqtt {
            var moduleConfig = Meshtastic_ModuleConfig()
            moduleConfig.mqtt = snapshot.mqtt
            var mqttAdmin = Meshtastic_AdminMessage()
            mqttAdmin.setModuleConfig = moduleConfig
            mqttAdmin.sessionPasskey = sessionPasskey
            guard await sendAdminMessage(mqttAdmin) else {
                throw DeviceConfigError.writeFailed("MQTT")
            }
            try await Task.sleep(for: .milliseconds(300))
        }

        // Commit edit settings
        var commitEdit = Meshtastic_AdminMessage()
        commitEdit.commitEditSettings = true
        commitEdit.sessionPasskey = sessionPasskey
        guard await sendAdminMessage(commitEdit) else {
            throw DeviceConfigError.writeFailed("Commit")
        }

        AppLogger.shared.log("[Protocol] Changed device configs saved", debug: SettingsService.shared.debugDevice)
        return true
    }

    nonisolated static func changedDeviceConfigCategories(
        _ snapshot: DeviceConfigSnapshot,
        replacing original: DeviceConfigSnapshot
    ) -> [String] {
        var categories: [String] = []
        if snapshot.device != original.device { categories.append("Device") }
        if snapshot.position != original.position { categories.append("Position") }
        if snapshot.power != original.power { categories.append("Power") }
        if snapshot.network != original.network { categories.append("Network") }
        if snapshot.display != original.display { categories.append("Display") }
        if snapshot.lora != original.lora { categories.append("LoRa") }
        if snapshot.bluetooth != original.bluetooth { categories.append("Bluetooth") }
        if snapshot.mqtt != original.mqtt { categories.append("MQTT") }
        return categories
    }

    nonisolated static func mismatchedDeviceConfigCategories(
        actual: DeviceConfigSnapshot,
        expected: DeviceConfigSnapshot,
        categories: [String]
    ) -> [String] {
        let differences = Set(changedDeviceConfigCategories(actual, replacing: expected))
        return categories.filter(differences.contains)
    }

    private var currentDeviceConfigSnapshot: DeviceConfigSnapshot? {
        guard let device = receivedConfigs[.device]?.device,
              let position = receivedConfigs[.position]?.position,
              let lora = receivedConfigs[.lora]?.lora,
              let bluetooth = receivedConfigs[.bluetooth]?.bluetooth,
              let network = receivedConfigs[.network]?.network,
              let display = receivedConfigs[.display]?.display,
              let power = receivedConfigs[.power]?.power,
              let mqtt = receivedModuleConfigs["mqtt"]?.mqtt
        else { return nil }

        return DeviceConfigSnapshot(
            device: device,
            position: position,
            lora: lora,
            bluetooth: bluetooth,
            network: network,
            display: display,
            power: power,
            mqtt: mqtt
        )
    }

    private var missingDeviceConfigCategories: [String] {
        var missing: [String] = []
        let expected: [(ConfigCategory, String)] = [
            (.device, "Device"), (.position, "Position"), (.lora, "LoRa"),
            (.bluetooth, "Bluetooth"), (.network, "Network"),
            (.display, "Display"), (.power, "Power"),
        ]
        missing.append(contentsOf: expected.compactMap { receivedConfigs[$0.0] == nil ? $0.1 : nil })
        if receivedModuleConfigs["mqtt"] == nil { missing.append("MQTT") }
        return missing
    }

    // MARK: - Complete Local / Remote Administration

    private enum CompleteAdminRequestKind: Hashable {
        case owner
        case config(MeshConfigCategory)
        case module(MeshModuleConfigCategory)
        case channel(Int)
        case metadata
        case cannedMessages
        case ringtone
    }

    /// Reads every core and module category supported by the generated schema.
    /// Unsupported categories remain marked as unavailable in the returned
    /// snapshot and are consequently excluded from later writes.
    func requestCompleteConfiguration(
        from target: AdminTarget = .local,
        selection: MeshConfigurationRequestSelection = .all,
        timeout: Duration = .seconds(30)
    ) async throws -> MeshConfigurationSnapshot {
        guard connectionService?.isConnected == true else {
            throw DeviceConfigError.notConnected
        }
        guard let destination = target.destination(localNodeID: myNodeId) else {
            throw DeviceConfigError.invalidTarget
        }

        guard !selection.isEmpty else { return MeshConfigurationSnapshot() }
        let key = try await ensureAdminSession(for: target, destination: destination, timeout: timeout)
        var requestQueue: [(Meshtastic_AdminMessage, CompleteAdminRequestKind)] = []

        if selection.includeOwner {
            var request = Meshtastic_AdminMessage()
            request.getOwnerRequest = true
            requestQueue.append((request, .owner))
        }
        for category in MeshConfigCategory.allCases where selection.configCategories.contains(category) {
            var request = Meshtastic_AdminMessage()
            request.getConfigRequest = category.requestType
            requestQueue.append((request, .config(category)))
        }
        for category in MeshModuleConfigCategory.allCases where selection.moduleCategories.contains(category) {
            var request = Meshtastic_AdminMessage()
            request.getModuleConfigRequest = category.requestType
            requestQueue.append((request, .module(category)))
        }
        for index in selection.channelIndices.sorted() where (0..<8).contains(index) {
            var request = Meshtastic_AdminMessage()
            request.getChannelRequest = UInt32(index + 1)
            requestQueue.append((request, .channel(index)))
        }
        if selection.includeMetadata {
            var request = Meshtastic_AdminMessage()
            request.getDeviceMetadataRequest = true
            requestQueue.append((request, .metadata))
        }
        if selection.includeCannedMessages {
            var request = Meshtastic_AdminMessage()
            request.getCannedMessageModuleMessagesRequest = true
            requestQueue.append((request, .cannedMessages))
        }
        if selection.includeRingtone {
            var request = Meshtastic_AdminMessage()
            request.getRingtoneRequest = true
            requestQueue.append((request, .ringtone))
        }

        let requestedChannelIndices = Set(selection.channelIndices.filter { (0..<8).contains($0) })
        var channelResponses = ChannelSnapshotAccumulator()
        channelResponses.begin(
            targetNodeID: destination,
            requestedIndices: requestedChannelIndices
        )
        let publishesLocalChannelSnapshot = !target.isRemote
            && requestedChannelIndices == Set(0..<8)
        if publishesLocalChannelSnapshot {
            beginChannelSnapshot(for: destination)
        }
        defer {
            if publishesLocalChannelSnapshot {
                finishChannelSnapshot()
            }
        }

        var snapshot = MeshConfigurationSnapshot()
        let clock = ContinuousClock()
        var inactivityWindow = AdminInactivityWindow(timeout: timeout, startingAt: clock.now)
        var receivedResponse = false

        // Radios have a shallow admin queue. Send exactly one request and wait
        // for its response (or the Windows-compatible 8-second category
        // timeout) before advancing to the next category.
        for (rawRequest, kind) in requestQueue {
            try Task.checkCancellation()
            guard !inactivityWindow.isExpired(at: clock.now) else { break }
            let baselineSequence = adminResponseSequence
            var request = rawRequest
            request.sessionPasskey = key
            guard let requestID = await sendAdminPacket(
                request,
                toNodeID: destination,
                wantResponse: true
            ) else {
                throw DeviceConfigError.requestFailed
            }

            let categoryDeadline = min(
                inactivityWindow.deadline,
                clock.now.advanced(by: .seconds(8))
            )
            var matchingRecord: AdminResponseRecord?
            while clock.now < categoryDeadline {
                try Task.checkCancellation()
                try throwIfAdminRoutingFailed(requestID: requestID)
                matchingRecord = adminResponses.first { record in
                    guard record.sequence > baselineSequence,
                          record.sourceNodeID == destination
                            || (!target.isRemote && record.sourceNodeID == 0)
                    else { return false }
                    let requestMatches = record.requestID != 0 && record.requestID == requestID
                    let kindMatches = inferredRequestKind(for: record.message) == kind
                    return requestMatches || kindMatches
                }
                if matchingRecord != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try throwIfAdminRoutingFailed(requestID: requestID)
            adminRoutingTracker.finish(requestID)

            if let matchingRecord {
                apply(matchingRecord.message, kind: kind, to: &snapshot)
                if case .getChannelResponse(let channel) = matchingRecord.message.payloadVariant {
                    channelResponses.record(channel, from: destination)
                    if publishesLocalChannelSnapshot {
                        tempChannels.record(channel, from: destination)
                    }
                }
                receivedResponse = true
                inactivityWindow.recordActivity(at: clock.now)
            } else {
                AppLogger.shared.log(
                    "[Admin] No response for \(String(describing: kind)); continuing sequential load",
                    debug: SettingsService.shared.debugDevice
                )
            }
        }

        if selection == .all, !receivedResponse {
            throw DeviceConfigError.adminTimedOut(String(localized: "Read configuration"))
        }

        if !requestedChannelIndices.isEmpty {
            snapshot.channels = channelResponses.activeChannels
            snapshot.channelsLoaded = channelResponses.isComplete
        }
        snapshot.channels.sort { $0.index < $1.index }
        if snapshot.position.fixedPosition,
           let node = appState?.node(forId: destination),
           let latitude = node.latitude,
           let longitude = node.longitude {
            var fixed = Meshtastic_Position()
            fixed.latitudeI = Int32((latitude * 1e7).rounded())
            fixed.longitudeI = Int32((longitude * 1e7).rounded())
            fixed.altitude = Int32(clamping: node.altitude ?? 0)
            snapshot.fixedPosition = fixed
        }
        return snapshot
    }

    /// Writes the exact diff in one firmware edit transaction. A failed category
    /// aborts before commit so a partially loaded snapshot can never reset other
    /// settings to protobuf defaults.
    @discardableResult
    func saveCompleteConfiguration(
        _ snapshot: MeshConfigurationSnapshot,
        replacing original: MeshConfigurationSnapshot,
        to target: AdminTarget = .local,
        timeout: Duration = .seconds(30)
    ) async throws -> MeshConfigurationDiff {
        let diff = MeshConfigurationDiff.between(snapshot, and: original)
        guard !diff.isEmpty else { return diff }
        guard connectionService?.isConnected == true else {
            throw DeviceConfigError.notConnected
        }
        guard let destination = target.destination(localNodeID: myNodeId) else {
            throw DeviceConfigError.invalidTarget
        }
        let key = try await ensureAdminSession(for: target, destination: destination, timeout: timeout)

        func write(_ message: Meshtastic_AdminMessage, label: String) async throws {
            var authenticated = message
            authenticated.sessionPasskey = key
            guard let requestID = await sendAdminPacket(
                authenticated,
                toNodeID: destination,
                wantResponse: false
            ) else {
                throw DeviceConfigError.writeFailed(label)
            }
            try await waitForAdminRoutingOutcome(requestID: requestID)
        }

        var begin = Meshtastic_AdminMessage()
        begin.beginEditSettings = true
        try await write(begin, label: String(localized: "Begin Edit"))

        for category in diff.changedConfigCategories {
            // SessionkeyConfig carries no editable values; the actual key is in
            // AdminMessage.sessionPasskey and must not be set as normal config.
            guard category != .session else { continue }
            var message = Meshtastic_AdminMessage()
            message.setConfig = snapshot.config(for: category)
            try await write(message, label: category.title)
        }

        for category in diff.changedModuleCategories {
            var message = Meshtastic_AdminMessage()
            message.setModuleConfig = snapshot.moduleConfig(for: category)
            try await write(message, label: category.title)
        }

        if diff.ownerChanged {
            var message = Meshtastic_AdminMessage()
            message.setOwner = snapshot.owner
            try await write(message, label: String(localized: "Owner"))
        }

        if diff.channelsChanged {
            for channel in snapshot.channels.sorted(by: { $0.index < $1.index }) {
                var message = Meshtastic_AdminMessage()
                message.setChannel = channel
                try await write(message, label: String(localized: "Channel \(channel.index)"))
            }
        }

        if diff.cannedMessageTextChanged {
            var message = Meshtastic_AdminMessage()
            message.setCannedMessageModuleMessages = snapshot.cannedMessageText
            try await write(message, label: String(localized: "Canned messages"))
        }

        if diff.ringtoneChanged {
            var message = Meshtastic_AdminMessage()
            message.setRingtoneMessage = snapshot.ringtone
            try await write(message, label: String(localized: "Ringtone"))
        }

        if diff.fixedPositionChanged {
            var message = Meshtastic_AdminMessage()
            if let position = snapshot.fixedPosition {
                message.setFixedPosition = position
            } else {
                message.removeFixedPosition = true
            }
            try await write(message, label: String(localized: "Fixed position"))
        }

        var commit = Meshtastic_AdminMessage()
        commit.commitEditSettings = true
        try await write(commit, label: String(localized: "Commit"))
        if target.isRemote {
            clearRemoteAdminSession(for: destination)
        } else {
            sessionPasskey = Data()
            localSessionPasskeyDate = nil
        }
        return diff
    }

    @discardableResult
    func performAdminAction(
        _ action: AdminNodeAction,
        on target: AdminTarget = .local,
        timeout: Duration = .seconds(30)
    ) async throws -> Bool {
        guard connectionService?.isConnected == true else {
            throw DeviceConfigError.notConnected
        }
        guard let destination = target.destination(localNodeID: myNodeId) else {
            throw DeviceConfigError.invalidTarget
        }
        let key = try await ensureAdminSession(for: target, destination: destination, timeout: timeout)
        var message = action.adminMessage()
        message.sessionPasskey = key
        guard let requestID = await sendAdminPacket(
            message,
            toNodeID: destination,
            wantResponse: false
        ) else {
            throw DeviceConfigError.writeFailed(String(localized: "Administrative action"))
        }
        try await waitForAdminRoutingOutcome(requestID: requestID)
        return true
    }

    /// Windows parity quick setup: SHORT_SLOW, EU_868 when unset, hop limit 7,
    /// and the Mesh Hessen channel in the first free secondary slot.
    @discardableResult
    func applyMeshHessenQuickConfiguration(
        to target: AdminTarget = .local,
        timeout: Duration = .seconds(30)
    ) async throws -> MeshConfigurationDiff {
        let original = try await requestCompleteConfiguration(from: target, timeout: timeout)
        var updated = original
        updated.lora.usePreset = true
        updated.lora.modemPreset = .shortSlow
        if updated.lora.region == .unset { updated.lora.region = .eu868 }
        updated.lora.hopLimit = 7

        let meshPSK = Data(base64Encoded: Self.meshHessenPSK) ?? Data()
        let alreadyPresent = updated.channels.contains { $0.settings.psk == meshPSK }
        if !alreadyPresent,
           let freeIndex = (1..<8).first(where: { index in
               !updated.channels.contains { $0.index == Int32(index) && $0.role != .disabled }
           }) {
            var settings = Meshtastic_ChannelSettings()
            settings.name = Self.meshHessenChannelName
            settings.psk = meshPSK
            settings.uplinkEnabled = true
            settings.downlinkEnabled = true
            var channel = Meshtastic_Channel()
            channel.index = Int32(freeIndex)
            channel.role = .secondary
            channel.settings = settings
            updated.channels.removeAll { $0.index == Int32(freeIndex) }
            updated.channels.append(channel)
        }
        return try await saveCompleteConfiguration(
            updated,
            replacing: original,
            to: target,
            timeout: timeout
        )
    }

    func clearRemoteAdminSession(for nodeID: UInt32) {
        remoteSessionPasskeys.removeValue(forKey: nodeID)
        remoteSessionPasskeyDates.removeValue(forKey: nodeID)
    }

    private func ensureAdminSession(
        for target: AdminTarget,
        destination: UInt32,
        timeout: Duration
    ) async throws -> Data {
        let now = Date()
        if target.isRemote,
           let key = remoteSessionPasskeys[destination],
           !key.isEmpty,
           now.timeIntervalSince(remoteSessionPasskeyDates[destination] ?? .distantPast) < 240 {
            return key
        }
        if !target.isRemote,
           !sessionPasskey.isEmpty,
           localSessionPasskeyDate == nil
                || now.timeIntervalSince(localSessionPasskeyDate ?? .distantPast) < 240 {
            return sessionPasskey
        }

        if target.isRemote {
            clearRemoteAdminSession(for: destination)
        } else {
            sessionPasskey = Data()
            localSessionPasskeyDate = nil
        }

        let baseline = adminResponseSequence
        var request = Meshtastic_AdminMessage()
        request.getConfigRequest = .sessionkeyConfig
        guard let requestID = await sendAdminPacket(
            request,
            toNodeID: destination,
            wantResponse: true
        ) else {
            throw DeviceConfigError.requestFailed
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            try throwIfAdminRoutingFailed(requestID: requestID)
            if target.isRemote,
               let key = remoteSessionPasskeys[destination], !key.isEmpty {
                adminRoutingTracker.finish(requestID)
                return key
            }
            if !target.isRemote, !sessionPasskey.isEmpty {
                adminRoutingTracker.finish(requestID)
                return sessionPasskey
            }

            if let response = adminResponses.last(where: {
                $0.sequence > baseline
                    && ($0.sourceNodeID == destination || (!target.isRemote && $0.sourceNodeID == 0))
                    && !$0.message.sessionPasskey.isEmpty
            }) {
                adminRoutingTracker.finish(requestID)
                return response.message.sessionPasskey
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try throwIfAdminRoutingFailed(requestID: requestID)
        adminRoutingTracker.finish(requestID)
        throw DeviceConfigError.missingSessionKey
    }

    private func inferredRequestKind(for message: Meshtastic_AdminMessage) -> CompleteAdminRequestKind? {
        switch message.payloadVariant {
        case .getOwnerResponse: return .owner
        case .getConfigResponse(let config):
            guard let category = configCategory(for: config) else { return nil }
            return .config(category)
        case .getModuleConfigResponse(let config):
            guard let category = moduleCategory(for: config) else { return nil }
            return .module(category)
        case .getChannelResponse(let channel): return .channel(Int(channel.index))
        case .getDeviceMetadataResponse: return .metadata
        case .getCannedMessageModuleMessagesResponse: return .cannedMessages
        case .getRingtoneResponse: return .ringtone
        case .getUiConfigResponse: return .config(.deviceUI)
        default: return nil
        }
    }

    private func apply(
        _ message: Meshtastic_AdminMessage,
        kind: CompleteAdminRequestKind,
        to snapshot: inout MeshConfigurationSnapshot
    ) {
        switch (kind, message.payloadVariant) {
        case (.owner, .getOwnerResponse(let owner)):
            snapshot.owner = owner
            snapshot.ownerLoaded = true
        case (.config(let category), .getConfigResponse(let config)):
            snapshot.apply(config)
            snapshot.loadedConfigCategories.insert(category)
        case (.config(.deviceUI), .getUiConfigResponse(let config)):
            snapshot.deviceUI = config
            snapshot.loadedConfigCategories.insert(.deviceUI)
        case (.module(let category), .getModuleConfigResponse(let config)):
            snapshot.apply(config)
            snapshot.loadedModuleCategories.insert(category)
        case (.channel, .getChannelResponse(let channel)):
            snapshot.channels.removeAll { $0.index == channel.index }
            snapshot.channels.append(channel)
        case (.metadata, .getDeviceMetadataResponse(let metadata)):
            snapshot.metadata = metadata
            snapshot.metadataLoaded = true
        case (.cannedMessages, .getCannedMessageModuleMessagesResponse(let text)):
            snapshot.cannedMessageText = text
            snapshot.cannedMessageTextLoaded = true
        case (.ringtone, .getRingtoneResponse(let ringtone)):
            snapshot.ringtone = ringtone
            snapshot.ringtoneLoaded = true
        default:
            break
        }
    }

    private func configCategory(for config: Meshtastic_Config) -> MeshConfigCategory? {
        switch config.payloadVariant {
        case .device: return .device
        case .position: return .position
        case .power: return .power
        case .network: return .network
        case .display: return .display
        case .lora: return .lora
        case .bluetooth: return .bluetooth
        case .security: return .security
        case .sessionkey: return .session
        case .deviceUi: return .deviceUI
        case nil: return nil
        }
    }

    private func moduleCategory(for config: Meshtastic_ModuleConfig) -> MeshModuleConfigCategory? {
        switch config.payloadVariant {
        case .mqtt: return .mqtt
        case .serial: return .serial
        case .externalNotification: return .externalNotification
        case .storeForward: return .storeForward
        case .rangeTest: return .rangeTest
        case .telemetry: return .telemetry
        case .cannedMessage: return .cannedMessage
        case .audio: return .audio
        case .remoteHardware: return .remoteHardware
        case .neighborInfo: return .neighborInfo
        case .ambientLighting: return .ambientLighting
        case .detectionSensor: return .detectionSensor
        case .paxcounter: return .paxcounter
        case .statusmessage: return .statusMessage
        case .trafficManagement: return .trafficManagement
        case .tak: return .tak
        case nil: return nil
        }
    }

    // MARK: - NeighborInfo (portnum 71)

    private func handleNeighborInfoPacket(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        // NeighborInfo proto: field 1 (uint32): node_id, field 2 (repeated Neighbor): neighbors
        // Neighbor: field 1 (uint32): node_id, field 2 (float): snr
        // Since we don't have a generated NeighborInfo message, we log the raw info
        let from = nodeDisplayName(packet.from)

        // Parse neighbor count from the payload
        // Each neighbor is a length-delimited sub-message (field 2, wire type 2)
        var neighborCount = 0
        var idx = data.payload.startIndex
        while idx < data.payload.endIndex {
            let (tag, tagBytes) = decodeVarint(data.payload, from: idx)
            guard tagBytes > 0 else { break }
            idx += tagBytes
            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            if fieldNumber == 2 && wireType == 2 {
                neighborCount += 1
            }

            // Skip field value
            switch wireType {
            case 0: // varint
                let (_, vBytes) = decodeVarint(data.payload, from: idx)
                guard vBytes > 0 else { return }
                idx += vBytes
            case 1: idx += 8
            case 2:
                let (length, lBytes) = decodeVarint(data.payload, from: idx)
                guard lBytes > 0 else { return }
                idx += lBytes + Int(length)
            case 5: idx += 4
            default: return
            }
        }

        AppLogger.shared.log(
            "[NeighborInfo] From \(from): \(neighborCount) neighbor(s) reported",
            debug: SettingsService.shared.debugDevice
        )
    }

    // MARK: - Raw Protobuf Field Parsers (for messages not in our generated code)

    private func parseVarintField(_ data: Data, fieldNumber: UInt64) -> UInt64? {
        var index = data.startIndex
        while index < data.endIndex {
            let (tag, tagByteCount) = decodeVarint(data, from: index)
            guard tagByteCount > 0 else { return nil }
            index += tagByteCount

            let currentField = tag >> 3
            let wireType = tag & 0x07
            if currentField == fieldNumber && wireType == 0 {
                let (value, valueByteCount) = decodeVarint(data, from: index)
                return valueByteCount > 0 ? value : nil
            }

            switch wireType {
            case 0:
                let (_, byteCount) = decodeVarint(data, from: index)
                guard byteCount > 0 else { return nil }
                index += byteCount
            case 1:
                guard index + 8 <= data.endIndex else { return nil }
                index += 8
            case 2:
                let (length, byteCount) = decodeVarint(data, from: index)
                guard byteCount > 0, length <= UInt64(data.endIndex - index - byteCount) else { return nil }
                index += byteCount + Int(length)
            case 5:
                guard index + 4 <= data.endIndex else { return nil }
                index += 4
            default:
                return nil
            }
        }
        return nil
    }

    /// Parse a fixed32 (wire type 5) at the given field number.
    private func parseFixed32(_ data: Data, fieldNumber: UInt64) -> UInt32 {
        var idx = data.startIndex
        while idx < data.endIndex {
            let (tag, tagBytes) = decodeVarint(data, from: idx)
            guard tagBytes > 0 else { return 0 }
            idx += tagBytes
            let fn = tag >> 3
            let wt = tag & 0x07
            if fn == fieldNumber && wt == 5 {
                guard idx + 4 <= data.endIndex else { return 0 }
                return data[idx...].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            }
            switch wt {
            case 0: let (_, vb) = decodeVarint(data, from: idx); idx += max(vb, 1)
            case 1: idx += 8
            case 2: let (len, lb) = decodeVarint(data, from: idx); idx += lb + Int(len)
            case 5: idx += 4
            default: return 0
            }
        }
        return 0
    }

    /// Parse a sfixed32 (wire type 5) at the given field number.
    private func parseSFixed32(_ data: Data, fieldNumber: UInt64) -> Int32 {
        Int32(bitPattern: parseFixed32(data, fieldNumber: fieldNumber))
    }

    /// Parse a string (wire type 2) at the given field number.
    private func parseString(_ data: Data, fieldNumber: UInt64) -> String? {
        var idx = data.startIndex
        while idx < data.endIndex {
            let (tag, tagBytes) = decodeVarint(data, from: idx)
            guard tagBytes > 0 else { return nil }
            idx += tagBytes
            let fn = tag >> 3
            let wt = tag & 0x07
            if fn == fieldNumber && wt == 2 {
                let (length, lb) = decodeVarint(data, from: idx)
                guard lb > 0 else { return nil }
                idx += lb
                let end = idx + Int(length)
                guard end <= data.endIndex else { return nil }
                return String(data: data[idx..<end], encoding: .utf8)
            }
            switch wt {
            case 0: let (_, vb) = decodeVarint(data, from: idx); idx += max(vb, 1)
            case 1: idx += 8
            case 2: let (len, lb) = decodeVarint(data, from: idx); idx += lb + Int(len)
            case 5: idx += 4
            default: return nil
            }
        }
        return nil
    }

    // MARK: - Telemetry

    private func handleTelemetry(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        guard packet.from != 0 else { return }
        let node = nodeForTelemetry(senderID: packet.from)
        defer { coreDataStore?.upsertNode(node) }

        // Always update lastSeen/lastHeard
        node.lastSeen = formatTime()
        node.lastHeard = Int32(Date().timeIntervalSince1970)

        // Node position for day/night classification
        let lat = node.latitude ?? 0
        let lon = node.longitude ?? 0
        let timestamp = Date()

        // Parse the Telemetry envelope (contains a variant oneof)
        guard let telemetry = try? Meshtastic_Telemetry(serializedBytes: data.payload) else {
            AppLogger.shared.log("[Protocol] Telemetry parse failed from \(nodeDisplayName(packet.from))", debug: SettingsService.shared.debugDevice)
            return
        }

        switch telemetry.variant {
        case .deviceMetrics(let metrics):
            if metrics.hasBatteryLevel, metrics.batteryLevel > 0 {
                node.batteryLevel = metrics.batteryLevel
                node.battery = metrics.batteryLevel <= 100 ? "\(metrics.batteryLevel)%" : "-"
            }
            if metrics.hasVoltage, metrics.voltage > 0 {
                node.voltage = metrics.voltage
            }
            if metrics.hasChannelUtilization {
                node.channelUtilization = metrics.channelUtilization
            }
            if metrics.hasAirUtilTx {
                node.airUtilTx = metrics.airUtilTx
            }

            telemetryDatabase.insertDeviceTelemetrySample(
                nodeId: packet.from,
                timestamp: timestamp,
                batteryPercent: metrics.hasBatteryLevel ? Double(metrics.batteryLevel) : nil,
                voltage: metrics.hasVoltage ? Double(metrics.voltage) : nil,
                channelUtilization: metrics.hasChannelUtilization ? Double(metrics.channelUtilization) : nil,
                airUtilTx: metrics.hasAirUtilTx ? Double(metrics.airUtilTx) : nil,
                uptimeSeconds: metrics.hasUptimeSeconds ? Double(metrics.uptimeSeconds) : nil,
                latitude: lat, longitude: lon
            )

            AppLogger.shared.log("[Protocol] DeviceMetrics from \(nodeDisplayName(packet.from)): bat=\(metrics.batteryLevel)% v=\(String(format: "%.2f", metrics.voltage))V chUtil=\(String(format: "%.1f", metrics.channelUtilization))% airTx=\(String(format: "%.1f", metrics.airUtilTx))%", debug: SettingsService.shared.debugDevice)

        case .environmentMetrics(let env):
            if env.hasTemperature { node.temperature = env.temperature }
            if env.hasRelativeHumidity { node.relativeHumidity = env.relativeHumidity }
            if env.hasBarometricPressure { node.barometricPressure = env.barometricPressure }
            if env.hasIaq { node.airQualityIndex = env.iaq }

            telemetryDatabase.insertEnvironmentTelemetrySample(
                nodeId: packet.from,
                timestamp: timestamp,
                sample: EnvironmentTelemetrySample(
                    temperature: env.hasTemperature ? Double(env.temperature) : nil,
                    relativeHumidity: env.hasRelativeHumidity ? Double(env.relativeHumidity) : nil,
                    barometricPressure: env.hasBarometricPressure ? Double(env.barometricPressure) : nil,
                    gasResistance: env.hasGasResistance ? Double(env.gasResistance) : nil,
                    voltage: env.hasVoltage ? Double(env.voltage) : nil,
                    current: env.hasCurrent ? Double(env.current) : nil,
                    iaq: env.hasIaq ? Double(env.iaq) : nil,
                    distance: env.hasDistance ? Double(env.distance) : nil,
                    lux: env.hasLux ? Double(env.lux) : nil,
                    whiteLux: env.hasWhiteLux ? Double(env.whiteLux) : nil,
                    irLux: env.hasIrLux ? Double(env.irLux) : nil,
                    uvLux: env.hasUvLux ? Double(env.uvLux) : nil,
                    windDirection: env.hasWindDirection ? Double(env.windDirection) : nil,
                    windSpeed: env.hasWindSpeed ? Double(env.windSpeed) : nil,
                    weight: env.hasWeight ? Double(env.weight) : nil,
                    windGust: env.hasWindGust ? Double(env.windGust) : nil,
                    windLull: env.hasWindLull ? Double(env.windLull) : nil,
                    radiation: env.hasRadiation ? Double(env.radiation) : nil,
                    rainfall1Hour: env.hasRainfall1H ? Double(env.rainfall1H) : nil,
                    rainfall24Hours: env.hasRainfall24H ? Double(env.rainfall24H) : nil,
                    soilMoisture: env.hasSoilMoisture ? Double(env.soilMoisture) : nil,
                    soilTemperature: env.hasSoilTemperature ? Double(env.soilTemperature) : nil
                ),
                latitude: lat, longitude: lon
            )

            AppLogger.shared.log("[Protocol] EnvironmentMetrics from \(nodeDisplayName(packet.from)): temp=\(String(format: "%.1f", env.temperature))°C hum=\(String(format: "%.0f", env.relativeHumidity))% pres=\(String(format: "%.0f", env.barometricPressure))hPa", debug: SettingsService.shared.debugDevice)

        case .airQualityMetrics(let air):
            if air.hasPm25Standard { node.pm25 = air.pm25Standard }
            if air.hasPm100Standard { node.pm10 = air.pm100Standard }

            var values: [TelemetrySeriesMetric: Double] = [:]
            func store(_ metric: TelemetrySeriesMetric, _ present: Bool, _ value: Double) {
                if present { values[metric] = value }
            }
            store(.pm10Standard, air.hasPm10Standard, Double(air.pm10Standard))
            store(.pm25Standard, air.hasPm25Standard, Double(air.pm25Standard))
            store(.pm100Standard, air.hasPm100Standard, Double(air.pm100Standard))
            store(.pm40Standard, air.hasPm40Standard, Double(air.pm40Standard))
            store(.pm10Environmental, air.hasPm10Environmental, Double(air.pm10Environmental))
            store(.pm25Environmental, air.hasPm25Environmental, Double(air.pm25Environmental))
            store(.pm100Environmental, air.hasPm100Environmental, Double(air.pm100Environmental))
            store(.particles03Um, air.hasParticles03Um, Double(air.particles03Um))
            store(.particles05Um, air.hasParticles05Um, Double(air.particles05Um))
            store(.particles10Um, air.hasParticles10Um, Double(air.particles10Um))
            store(.particles25Um, air.hasParticles25Um, Double(air.particles25Um))
            store(.particles40Um, air.hasParticles40Um, Double(air.particles40Um))
            store(.particles50Um, air.hasParticles50Um, Double(air.particles50Um))
            store(.particles100Um, air.hasParticles100Um, Double(air.particles100Um))
            store(.particlesTypicalSize, air.hasParticlesTps, Double(air.particlesTps))
            store(.co2, air.hasCo2, Double(air.co2))
            store(.co2Temperature, air.hasCo2Temperature, Double(air.co2Temperature))
            store(.co2Humidity, air.hasCo2Humidity, Double(air.co2Humidity))
            store(.formaldehyde, air.hasFormFormaldehyde, Double(air.formFormaldehyde))
            store(.formaldehydeHumidity, air.hasFormHumidity, Double(air.formHumidity))
            store(.formaldehydeTemperature, air.hasFormTemperature, Double(air.formTemperature))
            store(.pmTemperature, air.hasPmTemperature, Double(air.pmTemperature))
            store(.pmHumidity, air.hasPmHumidity, Double(air.pmHumidity))
            store(.pmVocIndex, air.hasPmVocIdx, Double(air.pmVocIdx))
            store(.pmNoxIndex, air.hasPmNoxIdx, Double(air.pmNoxIdx))
            telemetryDatabase.insertAirQualityTelemetry(
                nodeId: packet.from,
                timestamp: timestamp,
                sample: AirQualityTelemetrySample(values: values),
                latitude: lat,
                longitude: lon
            )
            AppLogger.shared.log(
                "[Protocol] AirQualityMetrics from \(nodeDisplayName(packet.from)): PM2.5=\(air.pm25Standard) PM10=\(air.pm100Standard)",
                debug: SettingsService.shared.debugDevice
            )

        case .powerMetrics(let power):
            let channels: [(Int, Float, Float, Bool)] = [
                (1, power.ch1Voltage, power.ch1Current, power.hasCh1Voltage || power.hasCh1Current),
                (2, power.ch2Voltage, power.ch2Current, power.hasCh2Voltage || power.hasCh2Current),
                (3, power.ch3Voltage, power.ch3Current, power.hasCh3Voltage || power.hasCh3Current),
                (4, power.ch4Voltage, power.ch4Current, power.hasCh4Voltage || power.hasCh4Current),
                (5, power.ch5Voltage, power.ch5Current, power.hasCh5Voltage || power.hasCh5Current),
                (6, power.ch6Voltage, power.ch6Current, power.hasCh6Voltage || power.hasCh6Current),
                (7, power.ch7Voltage, power.ch7Current, power.hasCh7Voltage || power.hasCh7Current),
                (8, power.ch8Voltage, power.ch8Current, power.hasCh8Voltage || power.hasCh8Current)
            ]
            node.powerMetrics = channels.compactMap { channel, voltage, current, isPresent in
                guard isPresent else { return nil }
                return PowerChannelMetric(channel: channel, voltage: voltage, current: current)
            }
            telemetryDatabase.insertPowerTelemetry(
                nodeId: packet.from,
                timestamp: timestamp,
                channels: [
                    PowerChannelTelemetrySample(channel: 1, voltage: power.hasCh1Voltage ? Double(power.ch1Voltage) : nil, current: power.hasCh1Current ? Double(power.ch1Current) : nil),
                    PowerChannelTelemetrySample(channel: 2, voltage: power.hasCh2Voltage ? Double(power.ch2Voltage) : nil, current: power.hasCh2Current ? Double(power.ch2Current) : nil),
                    PowerChannelTelemetrySample(channel: 3, voltage: power.hasCh3Voltage ? Double(power.ch3Voltage) : nil, current: power.hasCh3Current ? Double(power.ch3Current) : nil),
                    PowerChannelTelemetrySample(channel: 4, voltage: power.hasCh4Voltage ? Double(power.ch4Voltage) : nil, current: power.hasCh4Current ? Double(power.ch4Current) : nil),
                    PowerChannelTelemetrySample(channel: 5, voltage: power.hasCh5Voltage ? Double(power.ch5Voltage) : nil, current: power.hasCh5Current ? Double(power.ch5Current) : nil),
                    PowerChannelTelemetrySample(channel: 6, voltage: power.hasCh6Voltage ? Double(power.ch6Voltage) : nil, current: power.hasCh6Current ? Double(power.ch6Current) : nil),
                    PowerChannelTelemetrySample(channel: 7, voltage: power.hasCh7Voltage ? Double(power.ch7Voltage) : nil, current: power.hasCh7Current ? Double(power.ch7Current) : nil),
                    PowerChannelTelemetrySample(channel: 8, voltage: power.hasCh8Voltage ? Double(power.ch8Voltage) : nil, current: power.hasCh8Current ? Double(power.ch8Current) : nil)
                ],
                latitude: lat,
                longitude: lon
            )

        case .localStats(let stats):
            node.localStats = NodeLocalStats(
                uptimeSeconds: stats.uptimeSeconds,
                channelUtilization: stats.channelUtilization,
                airUtilTx: stats.airUtilTx,
                packetsTx: stats.numPacketsTx,
                packetsRx: stats.numPacketsRx,
                packetsRxBad: stats.numPacketsRxBad,
                onlineNodes: stats.numOnlineNodes,
                totalNodes: stats.numTotalNodes,
                duplicatePackets: stats.numRxDupe,
                relayedPackets: stats.numTxRelay,
                canceledRelays: stats.numTxRelayCanceled,
                heapTotalBytes: stats.heapTotalBytes,
                heapFreeBytes: stats.heapFreeBytes,
                droppedTransmissions: stats.numTxDropped,
                noiseFloor: stats.noiseFloor
            )
            telemetryDatabase.insertLocalStatsTelemetry(
                nodeId: packet.from,
                timestamp: timestamp,
                sample: LocalTelemetrySample(
                    uptimeSeconds: Double(stats.uptimeSeconds),
                    channelUtilization: Double(stats.channelUtilization),
                    airUtilTx: Double(stats.airUtilTx),
                    packetsTx: Double(stats.numPacketsTx),
                    packetsRx: Double(stats.numPacketsRx),
                    packetsRxBad: Double(stats.numPacketsRxBad),
                    onlineNodes: Double(stats.numOnlineNodes),
                    totalNodes: Double(stats.numTotalNodes),
                    rxDuplicates: Double(stats.numRxDupe),
                    txRelays: Double(stats.numTxRelay),
                    canceledRelays: Double(stats.numTxRelayCanceled),
                    heapTotalBytes: Double(stats.heapTotalBytes),
                    heapFreeBytes: Double(stats.heapFreeBytes),
                    txDropped: Double(stats.numTxDropped),
                    noiseFloor: Double(stats.noiseFloor)
                ),
                latitude: lat,
                longitude: lon
            )

        case .healthMetrics(let health):
            node.healthMetrics = NodeHealthMetrics(
                heartRateBPM: health.heartBpm,
                oxygenSaturation: health.spO2,
                temperature: health.temperature
            )
            telemetryDatabase.insertHealthTelemetry(
                nodeId: packet.from,
                timestamp: timestamp,
                sample: HealthTelemetrySample(
                    heartRate: health.hasHeartBpm ? Double(health.heartBpm) : nil,
                    spO2: health.hasSpO2 ? Double(health.spO2) : nil,
                    temperature: health.hasTemperature ? Double(health.temperature) : nil
                ),
                latitude: lat,
                longitude: lon
            )

        case .hostMetrics(let host):
            node.hostMetrics = NodeHostMetrics(
                uptimeSeconds: host.uptimeSeconds,
                freeMemoryBytes: host.freememBytes,
                diskFreeBytes: host.diskfree1Bytes,
                load1: host.load1,
                load5: host.load5,
                load15: host.load15,
                userString: host.userString
            )
            telemetryDatabase.insertHostTelemetry(
                nodeId: packet.from,
                timestamp: timestamp,
                sample: HostTelemetrySample(
                    uptimeSeconds: Double(host.uptimeSeconds),
                    freeMemoryBytes: Double(host.freememBytes),
                    disk1FreeBytes: Double(host.diskfree1Bytes),
                    disk2FreeBytes: host.hasDiskfree2Bytes ? Double(host.diskfree2Bytes) : nil,
                    disk3FreeBytes: host.hasDiskfree3Bytes ? Double(host.diskfree3Bytes) : nil,
                    load1: Double(host.load1) / 100,
                    load5: Double(host.load5) / 100,
                    load15: Double(host.load15) / 100,
                    userString: host.hasUserString ? host.userString : nil
                ),
                latitude: lat,
                longitude: lon
            )

        case .trafficManagementStats(let stats):
            node.trafficStats = NodeTrafficStats(
                packetsInspected: stats.packetsInspected,
                positionDedupDrops: stats.positionDedupDrops,
                nodeInfoCacheHits: stats.nodeinfoCacheHits,
                rateLimitDrops: stats.rateLimitDrops,
                unknownPacketDrops: stats.unknownPacketDrops,
                hopExhaustedPackets: stats.hopExhaustedPackets,
                routerHopsPreserved: stats.routerHopsPreserved
            )
            telemetryDatabase.insertTrafficTelemetry(
                nodeId: packet.from,
                timestamp: timestamp,
                sample: TrafficTelemetrySample(
                    packetsInspected: Double(stats.packetsInspected),
                    positionDedupDrops: Double(stats.positionDedupDrops),
                    nodeInfoCacheHits: Double(stats.nodeinfoCacheHits),
                    rateLimitDrops: Double(stats.rateLimitDrops),
                    unknownPacketDrops: Double(stats.unknownPacketDrops),
                    hopExhaustedPackets: Double(stats.hopExhaustedPackets),
                    routerHopsPreserved: Double(stats.routerHopsPreserved)
                ),
                latitude: lat,
                longitude: lon
            )

        case nil:
            AppLogger.shared.log(
                "[Protocol] Empty telemetry response from \(nodeDisplayName(packet.from))",
                debug: SettingsService.shared.debugDevice
            )
        }
    }

    private func handlePaxCounter(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        guard packet.from != 0 else { return }
        let node = nodeForTelemetry(senderID: packet.from)
        let wifi = UInt32(clamping: parseVarintField(data.payload, fieldNumber: 1) ?? 0)
        let ble = UInt32(clamping: parseVarintField(data.payload, fieldNumber: 2) ?? 0)
        let uptimeSeconds = UInt32(clamping: parseVarintField(data.payload, fieldNumber: 3) ?? 0)
        node.paxMetrics = NodePaxMetrics(wifi: wifi, ble: ble, uptimeSeconds: uptimeSeconds)
        node.lastSeen = formatTime()
        node.lastHeard = Int32(Date().timeIntervalSince1970)
        telemetryDatabase.insertPaxTelemetry(
            nodeId: packet.from,
            sample: PaxTelemetrySample(
                wifiCount: Double(wifi),
                bleCount: Double(ble),
                uptimeSeconds: Double(uptimeSeconds)
            ),
            latitude: node.latitude ?? 0,
            longitude: node.longitude ?? 0
        )
        coreDataStore?.upsertNode(node)
    }

    // MARK: - Channel Requests

    private func requestAllChannels() async {
        guard configComplete else {
            AppLogger.shared.log("[Protocol] requestAllChannels skipped: config not complete", debug: true)
            return
        }
        guard myNodeId != 0 else {
            AppLogger.shared.log("[Protocol] requestAllChannels skipped: myNodeId unknown", debug: true)
            return
        }

        // BLE braucht mehr Zeit zwischen Requests als Serial/TCP
        let isBLE = connectionService?.type == .bluetooth
        let delayBetweenRequests: UInt64 = isBLE ? 300 : 150
        let delayBetweenRounds: UInt64 = isBLE ? 3 : 5

        AppLogger.shared.log("[Protocol] Requesting channels (BLE=\(isBLE))...", debug: true)
        for round in 0..<3 {
            for idx in 0..<8 {
                if tempChannels.receivedIndices.contains(idx) { continue }
                await sendGetChannelRequest(index: idx)
                try? await Task.sleep(for: .milliseconds(delayBetweenRequests))
            }
            try? await Task.sleep(for: .seconds(delayBetweenRounds))
            let missing = (0..<8).filter { !tempChannels.receivedIndices.contains($0) }
            AppLogger.shared.log(
                "[Protocol] Channel round \(round + 1): received "
                    + "\(tempChannels.receivedIndices.count) channels, missing: \(missing)",
                debug: true
            )
            if missing.isEmpty { break }
        }
        AppLogger.shared.log(
            "[Protocol] Channel loading complete: \(tempChannels.receivedIndices.count) slots answered",
            debug: true
        )
    }

    // MARK: - Send Methods

    @discardableResult
    func sendMqttProxyMessage(_ message: Meshtastic_MqttClientProxyMessage) async -> Bool {
        var toRadio = Meshtastic_ToRadio()
        toRadio.mqttClientProxyMessage = message
        return await sendRaw(toRadio)
    }

    @discardableResult
    func requestNodeInfo(_ type: NodeInfoRequestType, from destinationId: UInt32) async -> Bool {
        guard myNodeId != 0, destinationId != 0 else { return false }

        let data: Meshtastic_Data
        do {
            data = try Self.makeNodeInfoRequestData(
                type,
                destinationId: destinationId,
                timestamp: UInt32(clamping: Int(Date().timeIntervalSince1970))
            )
        } catch {
            AppLogger.shared.log("[Protocol] Could not encode \(type.rawValue) request: \(error.localizedDescription)")
            return false
        }

        var packet = Meshtastic_MeshPacket()
        packet.from = myNodeId
        packet.to = destinationId
        packet.channel = 0
        packet.id = UInt32.random(in: 1..<UInt32.max)
        packet.wantAck = false
        packet.hopLimit = 7
        packet.hopStart = 7
        packet.decoded = data

        let sent = await sendToRadio(packet: packet)
        if sent {
            AppLogger.shared.log("[Protocol] \(type.rawValue) request sent to \(nodeDisplayName(destinationId))", debug: true)
        }
        return sent
    }

    nonisolated static func makeNodeInfoRequestData(
        _ type: NodeInfoRequestType,
        destinationId: UInt32,
        timestamp: UInt32
    ) throws -> Meshtastic_Data {
        var data = Meshtastic_Data()
        data.wantResponse = true
        data.dest = destinationId

        switch type {
        case .userInfo:
            data.portnum = .nodeinfoApp

        case .position:
            var position = Meshtastic_Position()
            position.time = timestamp
            data.portnum = .positionApp
            data.payload = try position.serializedData()

        case .paxCounter:
            data.portnum = .paxcounterApp

        case .deviceMetrics, .environmentMetrics, .airQualityMetrics,
             .powerMetrics, .localStats, .hostMetrics:
            var telemetry = Meshtastic_Telemetry()
            switch type {
            case .deviceMetrics:
                telemetry.deviceMetrics = Meshtastic_DeviceMetrics()
            case .environmentMetrics:
                telemetry.environmentMetrics = Meshtastic_EnvironmentMetrics()
            case .airQualityMetrics:
                telemetry.airQualityMetrics = Meshtastic_AirQualityMetrics()
            case .powerMetrics:
                telemetry.powerMetrics = Meshtastic_PowerMetrics()
            case .localStats:
                telemetry.localStats = Meshtastic_LocalStats()
            case .hostMetrics:
                telemetry.hostMetrics = Meshtastic_HostMetrics()
            default:
                break
            }
            data.portnum = .telemetryApp
            data.payload = try telemetry.serializedData()
        }

        return data
    }

    func sendTextMessage(
        _ text: String,
        toNodeId: UInt32 = 0xFFFFFFFF,
        channelIndex: Int = 0,
        replyToPacketId: UInt32? = nil
    ) async {
        guard myNodeId != 0 else {
            AppLogger.shared.log("[Protocol] sendTextMessage skipped: protocol not ready (myNodeId=0)", debug: true)
            return
        }
        let packetId = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)
        let replyTargetId = replyToPacketId.flatMap { $0 == 0 ? nil : $0 }

        var packet = Meshtastic_MeshPacket()
        packet.from = myNodeId
        packet.id = packetId
        packet.to = toNodeId
        packet.channel = UInt32(channelIndex)
        packet.hopLimit = 7
        packet.wantAck = true
        packet.decoded = Self.makeTextMessageData(text: text, replyToPacketId: replyTargetId)

        // Optimistic local message so the sender sees it immediately.
        let ts = formatTime()
        let myId = myNodeId
        let myName = appState?.myNodeInfo?.longName.isEmpty == false
            ? (appState?.myNodeInfo?.longName ?? String(localized: "Me"))
            : (appState?.myNodeInfo?.shortName.isEmpty == false
                ? (appState?.myNodeInfo?.shortName ?? String(localized: "Me"))
                : String(localized: "Me"))

        let outgoing = MessageItem(
            packetId: packetId,
            replyToPacketId: replyTargetId,
            time: ts,
            from: myName,
            fromId: myId,
            toId: toNodeId,
            message: text,
            channelIndex: channelIndex,
            channelName: channelName(for: channelIndex),
            deliveryState: .pending
        )

        let isBroadcast = toNodeId == 0xFFFFFFFF || toNodeId == 0
        if isBroadcast {
            appState?.appendMessage(outgoing)
            coreDataStore?.upsertMessage(outgoing, isDirect: false, partnerNodeId: nil)
            MessageLogger.shared.logChannelMessage(outgoing)
        } else {
            appState?.addOrUpdateDM(outgoing, myNodeId: myId)
            coreDataStore?.upsertMessage(outgoing, isDirect: true, partnerNodeId: toNodeId, partnerName: nodeDisplayName(toNodeId))
            MessageLogger.shared.logDirectMessage(outgoing, partnerName: nodeDisplayName(toNodeId), partnerNodeId: toNodeId)
        }

        let sent = await sendToRadio(packet: packet)
        if !sent {
            let failState: MessageDeliveryState = .failed(String(localized: "Not connected"))
            let storageContext: MessageStorageContext = isBroadcast
                ? .channel(channelIndex)
                : .directMessage(partnerNodeId: toNodeId)
            appState?.updateDeliveryState(requestId: packetId, state: failState, context: storageContext)
            coreDataStore?.updateDeliveryState(
                requestId: packetId,
                state: failState,
                storageContext: storageContext
            )
        }
    }

    func setOwner(shortName: String, longName: String) async {
        await ensureSessionKey()
        guard !sessionPasskey.isEmpty else {
            AppLogger.shared.log("[Protocol] setOwner aborted: no session key", debug: true)
            return
        }

        var owner = Meshtastic_User()
        owner.shortName = shortName
        owner.longName = longName
        owner.id = String(format: "!%08x", myNodeId)

        var admin = Meshtastic_AdminMessage()
        admin.setOwner = owner
        admin.sessionPasskey = sessionPasskey
        await sendAdminMessage(admin)
    }

    func sendSOSAlert(_ customText: String? = nil, channelIndex: Int = 0) async {
        let msg = customText.map { "🔔 \($0)" } ?? "🔔 Alert Bell Character!"
        await sendTextMessage(msg, channelIndex: channelIndex)
    }

    @discardableResult
    func setFavorite(_ isFavorite: Bool, nodeId: UInt32) async -> Bool {
        await ensureSessionKey()
        guard !sessionPasskey.isEmpty, nodeId != 0 else { return false }

        var admin = Meshtastic_AdminMessage()
        if isFavorite {
            admin.setFavoriteNode = nodeId
        } else {
            admin.removeFavoriteNode = nodeId
        }
        admin.sessionPasskey = sessionPasskey

        let sent = await sendAdminMessage(admin)
        if sent { appState?.node(forId: nodeId)?.isFavorite = isFavorite }
        return sent
    }

    /// Adds or removes a favorite in the NodeDB of the selected admin target.
    /// For a remote target the command is authenticated with that node's own
    /// session key and routed to it instead of mutating the locally connected
    /// radio.
    @discardableResult
    func setFavorite(
        _ isFavorite: Bool,
        nodeId: UInt32,
        on target: AdminTarget,
        timeout: Duration = .seconds(30)
    ) async throws -> Bool {
        guard nodeId != 0,
              let destination = target.destination(localNodeID: myNodeId)
        else { throw DeviceConfigError.invalidTarget }
        if !target.isRemote {
            return await setFavorite(isFavorite, nodeId: nodeId)
        }

        let key = try await ensureAdminSession(
            for: target,
            destination: destination,
            timeout: timeout
        )
        var admin = Meshtastic_AdminMessage()
        if isFavorite {
            admin.setFavoriteNode = nodeId
        } else {
            admin.removeFavoriteNode = nodeId
        }
        admin.sessionPasskey = key
        guard let requestID = await sendAdminPacket(
            admin,
            toNodeID: destination,
            wantResponse: true
        ) else {
            return false
        }
        try await waitForAdminRoutingOutcome(requestID: requestID)
        return true
    }

    @discardableResult
    func synchronizeDeviceTime(to date: Date = Date()) async -> Bool {
        await ensureSessionKey()
        guard !sessionPasskey.isEmpty else { return false }
        var admin = Meshtastic_AdminMessage()
        admin.setTimeOnly = UInt32(clamping: Int(date.timeIntervalSince1970))
        admin.sessionPasskey = sessionPasskey
        return await sendAdminMessage(admin)
    }

    @discardableResult
    func setFixedPosition(latitude: Double, longitude: Double, altitude: Int) async -> Bool {
        await ensureSessionKey()
        guard !sessionPasskey.isEmpty,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else { return false }

        var position = Meshtastic_Position()
        position.latitudeI = Int32((latitude * 1e7).rounded())
        position.longitudeI = Int32((longitude * 1e7).rounded())
        position.altitude = Int32(clamping: altitude)
        position.time = UInt32(clamping: Int(Date().timeIntervalSince1970))

        var admin = Meshtastic_AdminMessage()
        admin.setFixedPosition = position
        admin.sessionPasskey = sessionPasskey
        return await sendAdminMessage(admin)
    }

    @discardableResult
    func removeFixedPosition() async -> Bool {
        await ensureSessionKey()
        guard !sessionPasskey.isEmpty else { return false }
        var admin = Meshtastic_AdminMessage()
        admin.removeFixedPosition = true
        admin.sessionPasskey = sessionPasskey
        return await sendAdminMessage(admin)
    }

    @discardableResult
    func setChannel(index: Int, name: String, psk: Data, isSecondary: Bool,
                    uplinkEnabled: Bool, downlinkEnabled: Bool) async -> Bool {
        await ensureSessionKey()
        guard !sessionPasskey.isEmpty else {
            AppLogger.shared.log("[Protocol] setChannel aborted: no session key", debug: true)
            return false
        }

        var settings = Meshtastic_ChannelSettings()
        settings.name = name
        settings.psk = psk
        settings.uplinkEnabled = uplinkEnabled
        settings.downlinkEnabled = downlinkEnabled

        var channel = Meshtastic_Channel()
        channel.index = Int32(index)
        channel.settings = settings
        channel.role = isSecondary ? .secondary : .primary

        AppLogger.shared.log("[Protocol] setChannel idx=\(index), name=\(name), role=\(channel.role), psk=\(psk.count) bytes, passkey=\(sessionPasskey.count) bytes", debug: true)

        var admin = Meshtastic_AdminMessage()
        admin.setChannel = channel
        admin.sessionPasskey = sessionPasskey

        guard await sendAdminMessage(admin) else {
            AppLogger.shared.log("[Protocol] setChannel failed to send slot \(index)", debug: true)
            return false
        }
        // Give the device time to process
        try? await Task.sleep(for: .milliseconds(500))

        // Optimistic local state update — add the channel to appState immediately
        // so the app can decrypt messages without waiting for a full re-sync.
        handleChannel(channel, sourceNodeID: myNodeId)

        return true
    }

    func deleteChannel(index: Int) async {
        await ensureSessionKey()
        guard !sessionPasskey.isEmpty else {
            AppLogger.shared.log("[Protocol] deleteChannel aborted: no session key", debug: true)
            return
        }

        let remaining = (appState?.channels ?? [])
            .filter { $0.id != index }
            .sorted { $0.id < $1.id }

        for (newIndex, channelInfo) in remaining.enumerated() {
            var settings = Meshtastic_ChannelSettings()
            settings.name = channelInfo.name
            settings.psk = Data(base64Encoded: channelInfo.psk) ?? Data()
            settings.uplinkEnabled = channelInfo.uplinkEnabled
            settings.downlinkEnabled = channelInfo.downlinkEnabled

            var channel = Meshtastic_Channel()
            channel.index = Int32(newIndex)
            channel.settings = settings
            channel.role = newIndex == 0 ? .primary : .secondary

            var admin = Meshtastic_AdminMessage()
            admin.setChannel = channel
            admin.sessionPasskey = sessionPasskey
            guard await sendAdminMessage(admin) else { return }
        }

        // Always disable all trailing slots. This also handles sparse channel
        // indices correctly; using `channels.count - 1` disabled the wrong slot.
        for trailingIndex in remaining.count..<8 {
            var channel = Meshtastic_Channel()
            channel.index = Int32(trailingIndex)
            channel.role = .disabled

            var admin = Meshtastic_AdminMessage()
            admin.setChannel = channel
            admin.sessionPasskey = sessionPasskey
            guard await sendAdminMessage(admin) else { return }
        }

        let normalized = remaining.enumerated().map { newIndex, channel in
            ChannelInfo(
                id: newIndex,
                name: channel.name,
                psk: channel.psk,
                role: newIndex == 0 ? "PRIMARY" : "SECONDARY",
                uplinkEnabled: channel.uplinkEnabled,
                downlinkEnabled: channel.downlinkEnabled
            )
        }
        appState?.channels = normalized
        normalized.forEach { coreDataStore?.upsertChannel($0) }
        coreDataStore?.removeChannelsNotIn(indices: Set(normalized.map(\.id)))
    }

    @discardableResult
    func addMeshHessenChannel() async -> Bool {
        // Don't add if a channel with this name already exists
        if let existing = appState?.channels.first(where: {
            $0.name.localizedCaseInsensitiveCompare(MeshtasticProtocolService.meshHessenChannelName) == .orderedSame
        }) {
            AppLogger.shared.log("[Protocol] Mesh Hessen channel already exists at index \(existing.id), skipping", debug: true)
            return true
        }

        guard let psk = Data(base64Encoded: MeshtasticProtocolService.meshHessenPSK),
              let freeIndex = ChannelSlotAllocator.firstFreeSecondarySlot(
                  usedIndices: appState?.channels.map(\.id) ?? []
              )
        else { return false }
        return await setChannel(
            index: freeIndex,
            name: MeshtasticProtocolService.meshHessenChannelName,
            psk: psk,
            isSecondary: true,
            uplinkEnabled: true,
            downlinkEnabled: true
        )
    }

    /// Removes duplicate channels from the device, keeping only the first
    /// occurrence of each channel name. Sends all changes in rapid fire
    /// because the firmware may reset TCP after channel writes.
    func cleanupDuplicateChannels() async {
        await ensureSessionKey()
        guard !sessionPasskey.isEmpty else {
            AppLogger.shared.log("[Protocol] cleanupDuplicateChannels aborted: no session key", debug: true)
            return
        }

        let current = appState?.channels.sorted(by: { $0.id < $1.id }) ?? []
        guard !current.isEmpty else { return }

        // Keep first occurrence of each channel name
        var desired: [ChannelInfo] = []
        var seenNames = Set<String>()
        for ch in current {
            let key = ch.name.lowercased()
            if ch.id == 0 || !seenNames.contains(key) {
                seenNames.insert(key)
                desired.append(ch)
            }
        }

        let removed = current.count - desired.count
        if removed == 0 {
            AppLogger.shared.log("[Protocol] No duplicate channels found", debug: true)
            return
        }

        AppLogger.shared.log("[Protocol] Cleaning up \(removed) duplicate channel(s): keeping \(desired.map(\.name))", debug: true)

        // Write desired channels into slots 0..<desired.count
        // Send rapidly — no sleep between writes — to get them all out
        // before a potential TCP reset.
        for (newIdx, ch) in desired.enumerated() {
            var settings = Meshtastic_ChannelSettings()
            settings.name = ch.name
            settings.psk = Data(base64Encoded: ch.psk) ?? Data()
            settings.uplinkEnabled = ch.uplinkEnabled
            settings.downlinkEnabled = ch.downlinkEnabled

            var channel = Meshtastic_Channel()
            channel.index = Int32(newIdx)
            channel.settings = settings
            channel.role = newIdx == 0 ? .primary : .secondary

            var admin = Meshtastic_AdminMessage()
            admin.setChannel = channel
            admin.sessionPasskey = sessionPasskey
            await sendAdminMessage(admin)
        }

        // Disable remaining slots
        for idx in desired.count..<8 {
            var channel = Meshtastic_Channel()
            channel.index = Int32(idx)
            channel.role = .disabled

            var admin = Meshtastic_AdminMessage()
            admin.setChannel = channel
            admin.sessionPasskey = sessionPasskey
            await sendAdminMessage(admin)
        }

        // Update local state optimistically
        appState?.channels = desired.enumerated().map { newIdx, ch in
            ChannelInfo(
                id: newIdx, name: ch.name, psk: ch.psk,
                role: newIdx == 0 ? "PRIMARY" : "SECONDARY",
                uplinkEnabled: ch.uplinkEnabled, downlinkEnabled: ch.downlinkEnabled
            )
        }

        AppLogger.shared.log("[Protocol] Channel cleanup complete: \(desired.count) channels remain", debug: true)
    }

    func disconnect() {
        isDisconnecting = true
        stopHeartbeat()
        PkiDecryptionService.shared.clearPrivateKey()
        connectionService?.disconnect()
    }

    // MARK: - TCP Heartbeat

    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                guard let self, !self.isDisconnecting else { break }
                var toRadio = Meshtastic_ToRadio()
                toRadio.heartbeat = Meshtastic_Heartbeat()
                await self.sendRaw(toRadio)
                AppLogger.shared.log("[Protocol] Heartbeat sent", debug: SettingsService.shared.debugDevice)
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    // MARK: - Private send helpers

    private func sendWantConfig() async {
        var toRadio = Meshtastic_ToRadio()
        toRadio.wantConfigID = UInt32.random(in: 1..<0xFFFFFFFF)
        await sendRaw(toRadio)
        AppLogger.shared.log("[Protocol] WantConfigId sent", debug: SettingsService.shared.debugDevice)
    }

    private func sendGetChannelRequest(index: Int) async {
        await ensureSessionKey()
        var admin = Meshtastic_AdminMessage()
        admin.getChannelRequest = UInt32(index + 1)  // 1-based
        admin.sessionPasskey = sessionPasskey
        await sendAdminMessage(admin)
    }

    private func ensureSessionKey() async {
        guard sessionPasskey.isEmpty else { return }
        guard myNodeId != 0 else {
            AppLogger.shared.log("[Protocol] Session key request skipped: myNodeId unknown", debug: SettingsService.shared.debugDevice)
            return
        }

        var admin = Meshtastic_AdminMessage()
        admin.getConfigRequest = .sessionkeyConfig
        await sendAdminMessage(admin)
        // Wait up to 4s for passkey
        let deadline = Date().addingTimeInterval(4)
        while sessionPasskey.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if sessionPasskey.isEmpty {
            AppLogger.shared.log("[Protocol] Warning: No session key received after timeout", debug: true)
        }
    }

    @discardableResult
    private func sendAdminMessage(_ admin: Meshtastic_AdminMessage) async -> Bool {
        await sendAdminPacket(admin, toNodeID: myNodeId, wantResponse: true) != nil
    }

    /// Pure packet construction is kept separate so destination/session behavior
    /// can be covered without a physical radio in unit tests.
    nonisolated static func makeAdminMeshPacket(
        payload: Data,
        fromNodeID: UInt32,
        toNodeID: UInt32,
        packetID: UInt32,
        wantResponse: Bool,
        targetPublicKey: Data?,
        adminChannel: UInt32
    ) -> Meshtastic_MeshPacket {
        var innerData = Meshtastic_Data()
        innerData.portnum = .adminApp
        innerData.payload = payload
        innerData.wantResponse = wantResponse

        var packet = Meshtastic_MeshPacket()
        packet.from = fromNodeID
        packet.to = toNodeID
        packet.id = packetID
        packet.decoded = innerData
        packet.wantAck = true
        packet.priority = .reliable

        let isRemote = fromNodeID != toNodeID
        if isRemote, let targetPublicKey, targetPublicKey.count == 32 {
            packet.channel = 0
            packet.publicKey = targetPublicKey
            packet.pkiEncrypted = true
        } else if isRemote {
            packet.channel = adminChannel
        } else {
            packet.channel = 0
        }
        return packet
    }

    @discardableResult
    private func sendAdminPacket(
        _ admin: Meshtastic_AdminMessage,
        toNodeID: UInt32,
        wantResponse: Bool
    ) async -> UInt32? {
        guard let data = try? admin.serializedData() else { return nil }
        guard myNodeId != 0, toNodeID != 0, toNodeID != UInt32.max else { return nil }
        let packetID = UInt32.random(in: 1..<UInt32(Int32.max))
        let isRemote = toNodeID != myNodeId
        let targetPublicKey = isRemote ? adminTargetPublicKey(for: toNodeID) : nil
        let configuredAdminChannel = isRemote ? configuredAdminChannelIndex() : nil
        let packet = Self.makeAdminMeshPacket(
            payload: data,
            fromNodeID: myNodeId,
            toNodeID: toNodeID,
            packetID: packetID,
            wantResponse: wantResponse,
            targetPublicKey: targetPublicKey,
            adminChannel: configuredAdminChannel ?? 0
        )
        let path: String
        if !isRemote {
            path = "local"
        } else if packet.pkiEncrypted {
            path = "pki"
        } else if configuredAdminChannel != nil {
            path = "admin-channel"
        } else {
            path = "primary-fallback"
        }

        AppLogger.shared.log(
            "[Admin] Sending target=\(String(format: "!%08x", toNodeID)) "
                + "path=\(path) channel=\(packet.channel) pki=\(packet.pkiEncrypted) "
                + "keySize=\(targetPublicKey?.count ?? 0) packetID=\(packetID) payloadSize=\(data.count)",
            debug: true
        )

        adminRoutingTracker.register(
            requestID: packetID,
            destination: toNodeID,
            acceptsZeroSource: toNodeID == myNodeId
        )
        guard await sendToRadio(packet: packet) else {
            adminRoutingTracker.finish(packetID)
            return nil
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.adminRoutingTracker.finish(packetID)
        }
        return packetID
    }

    private func adminTargetPublicKey(for nodeID: UInt32) -> Data? {
        if let liveKey = appState?.node(forId: nodeID)?.publicKey, liveKey.count == 32 {
            return liveKey
        }
        if let storedKey = NodeKeyService.shared.publicKey(for: nodeID), storedKey.count == 32 {
            return storedKey
        }
        return nil
    }

    private func configuredAdminChannelIndex() -> UInt32? {
        appState?.channels
            .filter { (0..<8).contains($0.id) }
            .sorted { $0.id < $1.id }
            .first { channel in
                channel.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    == "admin"
            }
            .map { UInt32($0.id) }
    }

    private func throwIfAdminRoutingFailed(requestID: UInt32) throws {
        guard let error = adminRoutingTracker.takeFailure(for: requestID) else { return }
        adminRoutingTracker.finish(requestID)
        throw DeviceConfigError.routingFailed(error)
    }

    private func waitForAdminRoutingOutcome(
        requestID: UInt32,
        timeout: Duration = .seconds(1)
    ) async throws {
        defer { adminRoutingTracker.finish(requestID) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            try throwIfAdminRoutingFailed(requestID: requestID)
            if adminRoutingTracker.isAcknowledged(requestID) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try throwIfAdminRoutingFailed(requestID: requestID)
    }

    @discardableResult
    private func sendToRadio(packet: Meshtastic_MeshPacket) async -> Bool {
        var toRadio = Meshtastic_ToRadio()
        toRadio.packet = packet
        return await sendRaw(toRadio)
    }

    @discardableResult
    private func sendRaw(_ toRadio: Meshtastic_ToRadio) async -> Bool {
        guard let conn = connectionService, !isDisconnecting else {
            AppLogger.shared.log("[Protocol] sendRaw skipped: not connected", debug: true)
            return false
        }
        guard let payload = try? toRadio.serializedData() else { return false }

        let data: Data
        if conn.type == .bluetooth {
            // BLE: raw protobuf, no framing
            data = payload
        } else {
            // Serial/TCP: frame with 0x94 0xC3 + 2-byte BE length
            var framed = Data([packetStart1, packetStart2])
            let len = UInt16(payload.count)
            framed.append(UInt8(len >> 8))
            framed.append(UInt8(len & 0xFF))
            framed.append(payload)
            data = framed
        }

        AppLogger.shared.log("[Protocol] sendRaw: \(data.count) bytes (payload=\(payload.count), type=\(conn.type))", debug: true)

        do {
            try await conn.write(data)
            return true
        } catch {
            AppLogger.shared.log("[Protocol] Write error: \(error.localizedDescription)", debug: true)
            return false
        }
    }

    // MARK: - Alert Bell

    private func triggerAlertBell(_ msg: MessageItem) {
        appState?.activeAlertBell = msg
        appState?.showAlertBell = true
        NotificationCenter.default.post(name: .alertBellTriggered, object: msg)
    }

    // MARK: - Helpers

    private func makeNodeInfo(from user: Meshtastic_User, num: UInt32) -> NodeInfo {
        let nodeIdHex = "!" + String(format: "%08x", num)
        let node = NodeInfo(
            id: num,
            nodeId: nodeIdHex,
            shortName: user.shortName,
            longName: user.longName
        )
        node.hardwareModel = hardwareModelName(user.hwModel)
        node.role = String(describing: user.role)
        node.isInfrastructure = Self.isInfrastructureRole(user.role)
        node.isOwnNode = num == myNodeId
        node.colorHex = SettingsService.shared.colorHex(for: num)
        node.note = SettingsService.shared.note(for: num)
        if !user.publicKey.isEmpty {
            node.publicKey = user.publicKey
            NodeKeyService.shared.checkAndUpdate(
                nodeId: num,
                shortName: user.shortName,
                longName: user.longName,
                publicKey: user.publicKey
            )
        }
        return node
    }

    nonisolated private static func isInfrastructureRole(_ role: Meshtastic_Config.DeviceConfig.Role) -> Bool {
        switch role {
        case .router, .routerClient, .repeater, .routerLate, .clientBase:
            return true
        default:
            return false
        }
    }

    private func nodeDisplayName(_ nodeId: UInt32) -> String {
        appState?.node(forId: nodeId)?.name ?? String(format: "!%08x", nodeId)
    }

    private func nodeForTelemetry(senderID: UInt32) -> NodeInfo {
        if let existing = appState?.node(forId: senderID) {
            return existing
        }

        let node = NodeInfo(
            id: senderID,
            nodeId: String(format: "!%08x", senderID),
            shortName: "",
            longName: ""
        )
        appState?.upsertNode(node)
        AppLogger.shared.log(
            "[Protocol] Created fallback node for telemetry sender \(node.nodeId)",
            debug: SettingsService.shared.debugDevice
        )
        return node
    }

    private func channelName(for index: Int) -> String {
        // In Meshtastic: channel indices 0–7 are valid slot indices.
        // Higher values are channel hashes — the message was sent on a channel
        // where we don't have the matching PSK to decrypt it.
        if index <= 7 {
            return appState?.channels.first(where: { $0.id == index })?.name ?? "Channel \(index)"
        } else {
            return String(localized: "Other Channel (\(index & 0xFF))")
        }
    }

    /// Returns a valid decoded channel index (0–7), or the explicit unknown
    /// context for encrypted packets and hash-based channel values.
    nonisolated static func resolvedChannelIndex(
        for packetChannel: UInt32,
        isEncrypted: Bool
    ) -> Int {
        guard !isEncrypted, packetChannel <= 7 else {
            return MessageItem.unknownChannelIndex
        }
        return Int(packetChannel)
    }

    private func resolvedChannelIndex(for packetChannel: UInt32) -> Int {
        Self.resolvedChannelIndex(for: packetChannel, isEncrypted: false)
    }

    private func deliver(_ msg: MessageItem) {
        appState?.appendMessage(msg)
        coreDataStore?.upsertMessage(msg, isDirect: false, partnerNodeId: nil)
    }

    private func formatTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    private func formatTimestamp(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func hardwareModelName(_ model: Meshtastic_HardwareModel) -> String {
        switch model {
        case .unset:
            return "Unknown"
        case .UNRECOGNIZED(let value):
            return "HW(\(value))"
        default:
            return String(describing: model)
        }
    }
}

extension Notification.Name {
    static let alertBellTriggered = Notification.Name("MeshHessen.alertBellTriggered")
    static let incomingDirectMessage = Notification.Name("MeshHessen.incomingDirectMessage")
}
