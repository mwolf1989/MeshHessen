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
    // MARK: - Singleton / State
    weak var appState: AppState?
    var coreDataStore: MeshCoreDataStore?

    var connectionService: (any ConnectionService)?

    // MARK: - Protocol state (non-isolated mutable, protected by dataLock)
    private let dataLock = NSLock()
    private var receiveBuffer = Data()

    private var myNodeId: UInt32 = 0
    private var isInitializing = false
    private var isDisconnecting = false
    private var configComplete = false
    private var sessionPasskey = Data()

    private var tempChannels: [Int32: Meshtastic_Channel] = [:]
    private var receivedChannelResponses = Set<Int>()

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

    // MARK: - Initialize & Connect

    func initialize() async -> Bool {
        guard let conn = connectionService else { return false }

        AppLogger.shared.log("[Protocol] Initializing connection type: \(conn.type.rawValue)", debug: true)
        isDisconnecting = false
        isInitializing = true
        configComplete = false
        sessionPasskey = Data()
        tempChannels.removeAll()
        receivedChannelResponses.removeAll()
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
        }

        // 3. Send WantConfigId
        appState?.protocolStatusMessage = String(localized: "Syncing mesh config…")
        await sendWantConfig()

        // 4. Wait up to 15s for configComplete
        let configDeadline = Date().addingTimeInterval(15)
        while !configComplete && Date() < configDeadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        AppLogger.shared.log("[Protocol] configComplete=\(configComplete)", debug: true)

        // 5. Request channels only if protocol session is ready
        if configComplete, myNodeId != 0 {
            appState?.protocolStatusMessage = String(localized: "Loading channels…")
            await requestAllChannels()

            // Auch wenn nicht alle 8 Slots geladen wurden, gilt die Verbindung
            // als bereit — nicht geladene Slots sind typischerweise DISABLED.
            appState?.protocolStatusMessage = String(localized: "Finalizing sync…")
        } else {
            AppLogger.shared.log("[Protocol] Skipping channel request (configComplete=\(configComplete), myNodeId=\(String(format: "!%08x", myNodeId)))", debug: true)
            appState?.protocolStatusMessage = String(localized: "Connected, waiting for mesh data…")
        }

        // 6. Finish init; data continues to stream in live
        isInitializing = false

        let channelCount = appState?.channels.count ?? 0
        AppLogger.shared.log("[Protocol] Initialization complete. Nodes: \(appState?.nodes.count ?? 0), Channels: \(channelCount)", debug: true)

        // Verbindung als bereit melden, sobald configComplete und mindestens
        // ein Kanal geladen wurde — verhindert endloses Hängen bei BLE.
        return configComplete
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

    private func processPacket(_ data: Data) {
        do {
            let fromRadio = try Meshtastic_FromRadio(serializedBytes: data)
            Task { @MainActor in
                self.handleFromRadio(fromRadio)
            }
        } catch {
            AppLogger.shared.log("[Protocol] Parse error: \(error.localizedDescription)", debug: SettingsService.shared.debugDevice)
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
        switch fromRadio.payloadVariant {
        case .packet(let packet):
            handleMeshPacket(packet)
        case .myInfo(let info):
            myNodeId = info.myNodeNum
            AppLogger.shared.log("[Protocol] MyNodeId: \(String(format: "!%08x", myNodeId))", debug: SettingsService.shared.debugDevice)
        case .nodeInfo(let info):
            handleNodeInfo(info)
        case .channel(let channel):
            handleChannel(channel)
        case .config(let config):
            handleConfig(config)
        case .configCompleteID:
            configComplete = true
            AppLogger.shared.log("[Protocol] ConfigComplete received", debug: SettingsService.shared.debugDevice)
        case .moduleconfigCompleteID:
            configComplete = true
        default:
            break
        }
    }

    // MARK: - Mesh Packet

    private func handleMeshPacket(_ packet: Meshtastic_MeshPacket) {
        switch packet.payloadVariant {
        case .decoded(let data):
            let portnum = data.portnum
            switch portnum {
            case 1:  handleTextMessage(data: data, packet: packet)   // TEXT_MESSAGE_APP
            case 3:  handlePosition(data: data, packet: packet)      // POSITION_APP
            case 4:  handleNodeInfoPacket(data: data, packet: packet)// NODEINFO_APP
            case 5:  handleRoutingPacket(data: data, packet: packet) // ROUTING_APP
            case 6:  handleAdminPacket(data: data, packet: packet)   // ADMIN_APP
            case 8:  handleWaypointPacket(data: data, packet: packet)// WAYPOINT_APP
            case 67: handleTelemetry(data: data, packet: packet)     // TELEMETRY_APP
            case 70: handleTraceroutePacket(data: data, packet: packet)  // TRACEROUTE_APP
            case 71: handleNeighborInfoPacket(data: data, packet: packet)// NEIGHBORINFO_APP
            default:
                if SettingsService.shared.debugDevice {
                    AppLogger.shared.log("[Protocol] Unhandled portnum \(portnum) from \(String(format: "!%08x", packet.from))", debug: true)
                }
            }
        case .encrypted:
            // Encrypted message we can't decode
            if SettingsService.shared.showEncryptedMessages {
                let ts = formatTime()
                let from = nodeDisplayName(packet.from)
                let chIndex = resolvedChannelIndex(for: packet.channel)
                let chName = channelName(for: Int(packet.channel))
                let msg = MessageItem(
                    packetId: packet.id,
                    time: ts, from: from, fromId: packet.from, toId: packet.to,
                    message: String(localized: "[Encrypted — channel key not configured on this device]"),
                    channelIndex: chIndex >= 0 ? chIndex : 0,
                    channelName: chName,
                    isEncrypted: true, isViaMqtt: packet.viaMqtt
                )
                deliver(msg)
                if SettingsService.shared.debugMessages {
                    AppLogger.shared.log("[MSG] Encrypted from \(from) CH:\(packet.channel) (resolved:\(chIndex)) MQTT:\(packet.viaMqtt)", debug: true)
                }
            }
        default:
            break
        }
    }

    // MARK: - Text Message

    private func handleTextMessage(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
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
            packetId: packet.id,
            time: ts,
            from: from,
            fromId: packet.from,
            toId: packet.to,
            message: text,
            channelIndex: max(0, resolvedChannelIndex(for: packet.channel)),
            channelName: channelName(for: Int(packet.channel)),
            isViaMqtt: packet.viaMqtt,
            senderShortName: node?.shortName ?? "",
            senderColorHex: node?.colorHex ?? "",
            senderNote: node?.note ?? "",
            hasAlertBell: hasAlertBell
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

    // MARK: - Routing / ACK

    private func handleRoutingPacket(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        guard data.requestID != 0 else { return }

        // The official Meshtastic Routing message includes an error_reason field
        // (field number 3, varint type) that isn't in our slim proto.
        // Parse it from the raw payload to determine success vs. error code.
        let errorCode = parseRoutingErrorReason(from: data.payload)
        let routingError = RoutingError(rawValue: errorCode) ?? .none

        // For DMs (unicast): ignore the local ACK from our own node — only
        // mark as acknowledged when the actual destination node responds.
        // The firmware sends a local routing ACK when it accepts the ToRadio
        // packet, but that doesn't mean the recipient received it.
        // For broadcasts/channel messages: accept the local ACK since no
        // destination node will send a separate ACK.
        let isFromSelf = packet.from == myNodeId
        if isFromSelf && routingError == .none {
            let isDirect = appState?.findMessageByPacketId(data.requestID)?.isDirect ?? false
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

        appState?.updateDeliveryState(requestId: data.requestID, state: deliveryState)
        coreDataStore?.updateDeliveryState(requestId: data.requestID, state: deliveryState)

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
            appState?.recalculateDistance(for: packet.from)
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
            appState?.myNodeInfo = MyNodeInfo(
                nodeId: packet.from,
                shortName: user.shortName,
                longName: user.longName,
                hardwareModel: hardwareModelName(user.hwModel),
                firmwareVersion: ""
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
        }

        // Apply telemetry
        node.snrFloat = info.snr
        node.snr = info.snr != 0 ? String(format: "%.1f dB", info.snr) : "-"
        node.lastHeard = info.lastHeard
        node.lastSeen = info.lastHeard > 0 ? formatTimestamp(Int(info.lastHeard)) : "-"
        let metrics = info.deviceMetrics
        node.batteryLevel = metrics.batteryLevel
        node.battery = metrics.batteryLevel > 0 ? "\(metrics.batteryLevel)%" : "-"
        node.viaMqtt = info.viaMqtt

        // Apply saved color/note from settings
        node.colorHex = SettingsService.shared.colorHex(for: info.num)
        node.note = SettingsService.shared.note(for: info.num)

        if info.num == myNodeId {
            appState?.myNodeInfo = MyNodeInfo(
                nodeId: info.num,
                shortName: user.shortName,
                longName: user.longName,
                hardwareModel: hardwareModelName(user.hwModel),
                firmwareVersion: ""
            )
        }

        appState?.upsertNode(node)
        coreDataStore?.upsertNode(node)

        AppLogger.shared.log("[Protocol] NodeInfo: \(node.name) (\(node.nodeId))", debug: SettingsService.shared.debugDevice)
    }

    // MARK: - Channel

    private func handleChannel(_ channel: Meshtastic_Channel) {
        guard channel.role != .disabled else { return }

        let name = extractChannelName(channel)
        let s = channel.settings
        let pskBase64 = s.psk.base64EncodedString()
        let info = ChannelInfo(
            id: Int(channel.index),
            name: name,
            psk: pskBase64,
            role: channel.role == .primary ? "PRIMARY" : "SECONDARY",
            uplinkEnabled: s.uplinkEnabled,
            downlinkEnabled: s.downlinkEnabled
        )

        if let idx = appState?.channels.firstIndex(where: { $0.id == info.id }) {
            appState?.channels[idx] = info
        } else {
            appState?.channels.append(info)
        }
        appState?.channels.sort { $0.id < $1.id }
        coreDataStore?.upsertChannel(info)

        receivedChannelResponses.insert(Int(channel.index))
        AppLogger.shared.log("[Protocol] Channel \(channel.index): \(name) [\(info.role)]", debug: SettingsService.shared.debugDevice)
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
        case .lora(let lora):
            AppLogger.shared.log("[Protocol] Config: LoRa region=\(lora.region.rawValue) modem=\(lora.modemPreset.rawValue) hopLimit=\(lora.hopLimit) txEnabled=\(lora.txEnabled)", debug: SettingsService.shared.debugDevice)
        case .device(let device):
            _ = device
            AppLogger.shared.log("[Protocol] Config: Device", debug: SettingsService.shared.debugDevice)
        case .position(let pos):
            _ = pos
            AppLogger.shared.log("[Protocol] Config: Position", debug: SettingsService.shared.debugDevice)
        case .power(let pwr):
            _ = pwr
            AppLogger.shared.log("[Protocol] Config: Power", debug: SettingsService.shared.debugDevice)
        case .network(let net):
            _ = net
            AppLogger.shared.log("[Protocol] Config: Network", debug: SettingsService.shared.debugDevice)
        case .display(let disp):
            _ = disp
            AppLogger.shared.log("[Protocol] Config: Display", debug: SettingsService.shared.debugDevice)
        case .bluetooth(let bt):
            _ = bt
            AppLogger.shared.log("[Protocol] Config: Bluetooth", debug: SettingsService.shared.debugDevice)
        case .none:
            AppLogger.shared.log("[Protocol] Config received (empty)", debug: SettingsService.shared.debugDevice)
        }
    }

    // MARK: - Admin

    private func handleAdminPacket(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        guard let admin = try? Meshtastic_AdminMessage(serializedBytes: data.payload) else {
            AppLogger.shared.log("[Protocol] Admin parse failed from \(String(format: "!%08x", packet.from))", debug: SettingsService.shared.debugDevice)
            return
        }

        switch admin.payloadVariant {
        case .getChannelResponse(let channel):
            handleChannel(channel)
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
        case .none:
            // Session passkey in admin response
            if !admin.sessionPasskey.isEmpty {
                sessionPasskey = admin.sessionPasskey
                AppLogger.shared.log("[Protocol] Session passkey received (\(sessionPasskey.count) bytes)", debug: SettingsService.shared.debugDevice)
            }
        default:
            break
        }
    }

    // MARK: - Waypoint (portnum 8)

    private func handleWaypointPacket(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        // Waypoint protobuf is not in our slim proto schema, so parse raw fields:
        // field 1 (fixed32): id, field 2 (sfixed32): latitudeI, field 3 (sfixed32): longitudeI,
        // field 4 (int32): expire, field 5 (uint32): locked_to, field 6 (string): name,
        // field 7 (string): description, field 8 (fixed32): icon
        let from = nodeDisplayName(packet.from)
        let waypointId = parseFixed32(data.payload, fieldNumber: 1)
        let latI = parseSFixed32(data.payload, fieldNumber: 2)
        let lonI = parseSFixed32(data.payload, fieldNumber: 3)
        let name = parseString(data.payload, fieldNumber: 6) ?? "Waypoint"

        let lat = Double(latI) / 1e7
        let lon = Double(lonI) / 1e7

        AppLogger.shared.log(
            "[Waypoint] From \(from): \"\(name)\" id=\(waypointId) at (\(String(format: "%.5f", lat)), \(String(format: "%.5f", lon)))",
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
            message: String(localized: "📍 Waypoint: \(name) (\(String(format: "%.5f", lat)), \(String(format: "%.5f", lon)))"),
            channelIndex: chIndex >= 0 ? chIndex : 0,
            channelName: chName,
            isViaMqtt: packet.viaMqtt,
            senderShortName: node?.shortName ?? "",
            senderColorHex: node?.colorHex ?? "",
            senderNote: node?.note ?? ""
        )
        deliver(msg)
    }

    // MARK: - Traceroute (portnum 70)

    private func handleTraceroutePacket(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        guard let route = try? Meshtastic_RouteDiscovery(serializedBytes: data.payload) else {
            AppLogger.shared.log("[Protocol] Traceroute parse failed from \(String(format: "!%08x", packet.from))", debug: SettingsService.shared.debugDevice)
            return
        }

        let from = nodeDisplayName(packet.from)
        let hops = route.route.map { nodeDisplayName($0) }
        let hopStr = hops.isEmpty ? "(direct)" : hops.joined(separator: " → ")

        AppLogger.shared.log(
            "[Traceroute] From \(from): route = \(hopStr) (\(hops.count) hops)",
            debug: SettingsService.shared.debugDevice
        )

        // Inject as a channel message for visibility
        let ts = formatTime()
        let chIndex = resolvedChannelIndex(for: packet.channel)
        let chName = channelName(for: Int(packet.channel))
        let node = appState?.node(forId: packet.from)
        let msg = MessageItem(
            packetId: packet.id,
            time: ts, from: from, fromId: packet.from, toId: packet.to,
            message: String(localized: "🔀 Traceroute: \(hopStr)"),
            channelIndex: chIndex >= 0 ? chIndex : 0,
            channelName: chName,
            isViaMqtt: packet.viaMqtt,
            senderShortName: node?.shortName ?? "",
            senderColorHex: node?.colorHex ?? "",
            senderNote: node?.note ?? ""
        )
        deliver(msg)
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
        guard let node = appState?.node(forId: packet.from) else { return }

        // Always update lastSeen/lastHeard
        node.lastSeen = formatTime()
        node.lastHeard = Int32(Date().timeIntervalSince1970)

        // Parse DeviceMetrics payload (portnum 67)
        guard let metrics = try? Meshtastic_DeviceMetrics(serializedBytes: data.payload) else {
            AppLogger.shared.log("[Protocol] Telemetry parse failed from \(nodeDisplayName(packet.from))", debug: SettingsService.shared.debugDevice)
            return
        }

        // Update battery
        if metrics.batteryLevel > 0 {
            node.batteryLevel = metrics.batteryLevel
            node.battery = metrics.batteryLevel <= 100 ? "\(metrics.batteryLevel)%" : "-"
        }

        // Update voltage
        if metrics.voltage > 0 {
            node.voltage = metrics.voltage
        }

        // Update channel utilization
        node.channelUtilization = metrics.channelUtilization

        // Update air utilization TX
        node.airUtilTx = metrics.airUtilTx

        AppLogger.shared.log("[Protocol] Telemetry from \(nodeDisplayName(packet.from)): bat=\(metrics.batteryLevel)% v=\(String(format: "%.2f", metrics.voltage))V chUtil=\(String(format: "%.1f", metrics.channelUtilization))% airTx=\(String(format: "%.1f", metrics.airUtilTx))%", debug: SettingsService.shared.debugDevice)
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
            let before = receivedChannelResponses.count
            for idx in 0..<8 {
                if receivedChannelResponses.contains(idx) { continue }
                await sendGetChannelRequest(index: idx)
                try? await Task.sleep(for: .milliseconds(delayBetweenRequests))
            }
            try? await Task.sleep(for: .seconds(delayBetweenRounds))
            let missing = (0..<8).filter { !receivedChannelResponses.contains($0) }
            AppLogger.shared.log("[Protocol] Channel round \(round+1): received \(receivedChannelResponses.count) channels, missing: \(missing)", debug: true)
            if missing.isEmpty { break }

            // Wenn in dieser Runde keine neuen Antworten kamen und wir mindestens
            // den Primary-Kanal haben, brechen wir ab — die fehlenden Kanäle
            // sind wahrscheinlich nicht konfiguriert (DISABLED).
            if receivedChannelResponses.count == before {
                AppLogger.shared.log("[Protocol] Channel round \(round+1) produced no new responses — stopping early", debug: true)
                break
            }
        }
        AppLogger.shared.log("[Protocol] Channel loading complete: \(receivedChannelResponses.count) channels loaded", debug: true)
    }

    // MARK: - Send Methods

    func sendTextMessage(_ text: String, toNodeId: UInt32 = 0xFFFFFFFF, channelIndex: Int = 0) async {
        let packetId = UInt32.random(in: UInt32(UInt8.max)..<UInt32.max)

        var packet = Meshtastic_MeshPacket()
        packet.id = packetId
        packet.to = toNodeId
        packet.channel = UInt32(channelIndex)
        packet.hopLimit = 7
        packet.wantAck = true
        var data = Meshtastic_Data()
        data.portnum = 1   // TEXT_MESSAGE_APP
        data.payload = text.data(using: .utf8) ?? Data()
        packet.decoded = data

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

        await sendToRadio(packet: packet)
    }

    func setOwner(shortName: String, longName: String) async {
        await ensureSessionKey()

        var owner = Meshtastic_User()
        owner.shortName = shortName
        owner.longName = longName
        owner.id = String(format: "!%08x", myNodeId)

        var admin = Meshtastic_AdminMessage()
        admin.setOwner = owner
        admin.sessionPasskey = sessionPasskey
        await sendAdminMessage(admin)
    }

    func sendSOSAlert(_ customText: String? = nil) async {
        let msg = customText.map { "🔔 \($0)" } ?? "🔔 Alert Bell Character!"
        await sendTextMessage(msg)
    }

    func setChannel(index: Int, name: String, psk: Data, isSecondary: Bool,
                    uplinkEnabled: Bool, downlinkEnabled: Bool) async {
        await ensureSessionKey()

        var settings = Meshtastic_ChannelSettings()
        settings.name = name
        settings.psk = psk
        settings.uplinkEnabled = uplinkEnabled
        settings.downlinkEnabled = downlinkEnabled

        var channel = Meshtastic_Channel()
        channel.index = Int32(index)
        channel.settings = settings
        channel.role = isSecondary ? .secondary : .primary

        var admin = Meshtastic_AdminMessage()
        admin.setChannel = channel
        admin.sessionPasskey = sessionPasskey

        await sendAdminMessage(admin)
    }

    func deleteChannel(index: Int) async {
        await ensureSessionKey()
        // Shift channels down and disable last
        let maxIdx = (appState?.channels.count ?? 1)
        for i in index..<maxIdx {
            if let ch = appState?.channels.first(where: { $0.id == i + 1 }) {
                await setChannel(index: i, name: ch.name,
                                 psk: Data(base64Encoded: ch.psk) ?? Data(),
                                 isSecondary: ch.role == "SECONDARY",
                                 uplinkEnabled: ch.uplinkEnabled,
                                 downlinkEnabled: ch.downlinkEnabled)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        // Disable last channel
        var admin = Meshtastic_AdminMessage()
        var ch = Meshtastic_Channel()
        ch.index = Int32(maxIdx - 1)
        ch.role = .disabled
        admin.setChannel = ch
        admin.sessionPasskey = sessionPasskey
        await sendAdminMessage(admin)
    }

    func addMeshHessenChannel() async {
        guard let psk = Data(base64Encoded: MeshtasticProtocolService.meshHessenPSK) else { return }
        await setChannel(
            index: appState?.channels.count ?? 1,
            name: MeshtasticProtocolService.meshHessenChannelName,
            psk: psk,
            isSecondary: true,
            uplinkEnabled: true,
            downlinkEnabled: true
        )
    }

    func disconnect() {
        isDisconnecting = true
        connectionService?.disconnect()
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
        guard configComplete else {
            AppLogger.shared.log("[Protocol] Session key request skipped: config not complete", debug: SettingsService.shared.debugDevice)
            return
        }
        guard myNodeId != 0 else {
            AppLogger.shared.log("[Protocol] Session key request skipped: myNodeId unknown", debug: SettingsService.shared.debugDevice)
            return
        }

        var admin = Meshtastic_AdminMessage()
        admin.getConfigRequest = 8   // triggers session passkey response
        await sendAdminMessage(admin)
        // Wait up to 4s for passkey
        let deadline = Date().addingTimeInterval(4)
        while sessionPasskey.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func sendAdminMessage(_ admin: Meshtastic_AdminMessage) async {
        guard let data = try? admin.serializedData() else { return }
        var innerData = Meshtastic_Data()
        innerData.portnum = 6   // ADMIN_APP
        innerData.payload = data
        innerData.wantResponse = true

        var packet = Meshtastic_MeshPacket()
        packet.to = myNodeId   // admin messages go to self
        packet.hopLimit = 0
        packet.wantAck = true
        packet.decoded = innerData

        await sendToRadio(packet: packet)
    }

    private func sendToRadio(packet: Meshtastic_MeshPacket) async {
        var toRadio = Meshtastic_ToRadio()
        toRadio.packet = packet
        await sendRaw(toRadio)
    }

    private func sendRaw(_ toRadio: Meshtastic_ToRadio) async {
        guard let conn = connectionService, !isDisconnecting else { return }
        guard let payload = try? toRadio.serializedData() else { return }

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

        do {
            try await conn.write(data)
        } catch {
            AppLogger.shared.log("[Protocol] Write error: \(error.localizedDescription)", debug: true)
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
        node.colorHex = SettingsService.shared.colorHex(for: num)
        node.note = SettingsService.shared.note(for: num)
        return node
    }

    private func nodeDisplayName(_ nodeId: UInt32) -> String {
        appState?.node(forId: nodeId)?.name ?? String(format: "!%08x", nodeId)
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

    /// Returns a valid channel index (0–7) or -1 for hash-based channel values.
    /// When the channel value > 7, it's a hash and doesn't map to a local channel slot.
    private func resolvedChannelIndex(for packetChannel: UInt32) -> Int {
        let idx = Int(packetChannel)
        return idx <= 7 ? idx : -1
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
