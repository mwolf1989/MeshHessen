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
    private var pendingChannelNodes: [NodeInfo] = []
    private var pendingChannelInfos: [ChannelInfo] = []
    private var pendingMessages: [MessageItem] = []

    // Text-mode recovery
    private var lastValidPacketTime = Date()

    // Protocol constants
    private let packetStart1: UInt8 = 0x94
    private let packetStart2: UInt8 = 0xC3
    private let maxPacketLength = 512

    // Hardcoded Mesh Hessen PSK (for decryption hint — actual decrypt not implemented)
    static let meshHessenPSK = "+uTMEaOR7hkqaXv+DROOEd5BhvAIQY/CZ/Hr4soZcOU="
    static let meshHessenChannelName = "Mesh Hessen"

    // MARK: - Initialize & Connect

    func initialize() async {
        guard let conn = connectionService else { return }

        AppLogger.shared.log("[Protocol] Initializing connection type: \(conn.type.rawValue)", debug: true)
        isInitializing = true
        configComplete = false
        sessionPasskey = Data()
        tempChannels.removeAll()
        receivedChannelResponses.removeAll()
        pendingChannelNodes.removeAll()
        pendingChannelInfos.removeAll()
        pendingMessages.removeAll()
        receiveBuffer = Data()
        myNodeId = 0

        // 1. Small settle delay
        try? await Task.sleep(for: .seconds(1))

        // 2. Wakeup sequence for Serial/TCP (64 × 0xC3)
        if conn.type != .bluetooth {
            let wakeup = Data(repeating: 0xC3, count: 64)
            try? await conn.write(wakeup)
            AppLogger.shared.log("[Protocol] Wakeup sent", debug: SettingsService.shared.debugSerial)
        }

        // 3. Send WantConfigId
        await sendWantConfig()

        // 4. Wait up to 15s for configComplete
        let configDeadline = Date().addingTimeInterval(15)
        while !configComplete && Date() < configDeadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        AppLogger.shared.log("[Protocol] configComplete=\(configComplete)", debug: true)

        // 5. Wait for data stream to stabilize (3s no new nodes, max 30s)
        var lastNodeCount = 0
        var stableCount = 0
        let streamDeadline = Date().addingTimeInterval(30)
        while Date() < streamDeadline {
            let currentCount = pendingChannelNodes.count
            if currentCount == lastNodeCount {
                stableCount += 1
                if stableCount >= 15 { break }  // 15 × 200ms = 3s stable
            } else {
                stableCount = 0
            }
            lastNodeCount = currentCount
            try? await Task.sleep(for: .milliseconds(200))
        }

        // 6. Flush pending events
        isInitializing = false
        for node in pendingChannelNodes { appState?.upsertNode(node) }
        for channel in pendingChannelInfos {
            if !appState!.channels.contains(where: { $0.id == channel.id }) {
                appState?.channels.append(channel)
            }
        }
        for msg in pendingMessages {
            appState?.appendMessage(msg)
            // Log pending messages that were queued during init
            if msg.isDirect {
                let partnerId = msg.fromId == myNodeId ? msg.toId : msg.fromId
                let partnerName = appState?.node(forId: partnerId)?.name ?? msg.from
                MessageLogger.shared.logDirectMessage(msg, partnerName: partnerName, partnerNodeId: partnerId)
            } else {
                MessageLogger.shared.logChannelMessage(msg)
            }
        }
        pendingChannelNodes.removeAll()
        pendingChannelInfos.removeAll()
        pendingMessages.removeAll()

        // 7. Request channels (up to 3 rounds, 8 channels each)
        await requestAllChannels()

        AppLogger.shared.log("[Protocol] Initialization complete. Nodes: \(appState?.nodes.count ?? 0), Channels: \(appState?.channels.count ?? 0)", debug: true)
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
            // Find magic header 0x94 0xC3
            guard let startIdx = findPacketStart(in: buf) else {
                // No header found — discard all but last 3 bytes
                if buf.count > 3 {
                    buf = buf.suffix(3)
                }
                break
            }

            if startIdx > 0 {
                // Skip ASCII text before header (log it)
                let ascii = buf.prefix(startIdx)
                if let text = String(bytes: ascii, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    AppLogger.shared.log("[Serial] ASCII: \(text.trimmingCharacters(in: .whitespacesAndNewlines))", debug: SettingsService.shared.debugSerial)
                }
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
                continue
            }

            let totalSize = 4 + length
            guard buf.count >= totalSize else {
                // Incomplete — wait for more data
                // Timeout: if incomplete for > 5s, discard
                break
            }

            let payload = buf.subdata(in: 4..<totalSize)
            buf.removeFirst(totalSize)
            processPacket(payload)
            lastValidPacketTime = Date()
        }

        dataLock.lock()
        receiveBuffer = buf
        dataLock.unlock()
    }

    private func findPacketStart(in data: Data) -> Int? {
        for i in 0..<(data.count - 1) {
            if data[i] == packetStart1 && data[i+1] == packetStart2 {
                return i
            }
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
            case 6:  handleAdminPacket(data: data, packet: packet)   // ADMIN_APP
            case 67: handleTelemetry(data: data, packet: packet)     // TELEMETRY_APP
            default: break
            }
        case .encrypted:
            // Encrypted message we can't decode
            if SettingsService.shared.showEncryptedMessages {
                let ts = formatTime()
                let from = nodeDisplayName(packet.from)
                let chIndex = resolvedChannelIndex(for: packet.channel)
                let chName = channelName(for: Int(packet.channel))
                let msg = MessageItem(
                    time: ts, from: from, fromId: packet.from, toId: packet.to,
                    message: String(localized: "[Encrypted message — PSK required]"),
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
        guard var text = String(bytes: data.payload, encoding: .utf8) else { return }

        // Strip BEL character (0x07) used as alert trigger
        let hasAlertBell = text.contains("\u{0007}") || text.contains("🔔")
        text = text.replacingOccurrences(of: "\u{0007}", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let ts = formatTime()
        let from = nodeDisplayName(packet.from)
        let node = appState?.node(forId: packet.from)

        var msg = MessageItem(
            time: ts,
            from: from,
            fromId: packet.from,
            toId: packet.to,
            message: text,
            channelIndex: Int(packet.channel),
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
            if isInitializing {
                pendingMessages.append(msg)
            } else {
                appState?.addOrUpdateDM(msg, myNodeId: myNodeId)
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
            }
        } else {
            // Broadcast / channel message
            MessageLogger.shared.logChannelMessage(msg)
            deliver(msg)
            if hasAlertBell { triggerAlertBell(msg) }
        }
    }

    // MARK: - Position

    private func handlePosition(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        guard let pos = try? Meshtastic_Position(serializedBytes: data.payload) else { return }
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
        guard let user = try? Meshtastic_User(serializedBytes: data.payload) else { return }

        // If this is our own node
        if packet.from == myNodeId || myNodeId == 0 {
            appState?.myNodeInfo = MyNodeInfo(
                nodeId: packet.from,
                shortName: user.shortName,
                longName: user.longName,
                hardwareModel: user.hwModel.name,
                firmwareVersion: ""
            )
        }

        let nodeId = packet.from
        let node = makeNodeInfo(from: user, num: nodeId)
        if isInitializing {
            if !pendingChannelNodes.contains(where: { $0.id == nodeId }) {
                pendingChannelNodes.append(node)
            }
        } else {
            appState?.upsertNode(node)
        }
    }

    // MARK: - NodeInfo (from NodeInfo message)

    private func handleNodeInfo(_ info: Meshtastic_NodeInfo) {
        let node = makeNodeInfo(from: info.user, num: info.num)

        // Apply GPS if present
        if info.position.latitudeI != 0 || info.position.longitudeI != 0 {
            node.latitude = Double(info.position.latitudeI) / 1e7
            node.longitude = Double(info.position.longitudeI) / 1e7
            node.altitude = Int(info.position.altitude)
        }

        // Apply telemetry
        node.snrFloat = info.snr
        node.snr = info.snr != 0 ? String(format: "%.1f dB", info.snr) : "-"
        node.lastHeard = info.lastHeard
        node.lastSeen = info.lastHeard > 0 ? formatTimestamp(Int(info.lastHeard)) : "-"
        node.batteryLevel = info.deviceMetrics.batteryLevel
        node.battery = info.deviceMetrics.batteryLevel > 0 ? "\(info.deviceMetrics.batteryLevel)%" : "-"
        node.viaMqtt = info.viaMqtt

        // Apply saved color/note from settings
        node.colorHex = SettingsService.shared.colorHex(for: info.num)
        node.note = SettingsService.shared.note(for: info.num)

        if info.num == myNodeId {
            appState?.myNodeInfo = MyNodeInfo(
                nodeId: info.num,
                shortName: info.user.shortName,
                longName: info.user.longName,
                hardwareModel: info.user.hwModel.name,
                firmwareVersion: ""
            )
        }

        if isInitializing {
            if !pendingChannelNodes.contains(where: { $0.id == info.num }) {
                pendingChannelNodes.append(node)
            }
        } else {
            appState?.upsertNode(node)
        }

        AppLogger.shared.log("[Protocol] NodeInfo: \(node.name) (\(node.nodeId))", debug: SettingsService.shared.debugDevice)
    }

    // MARK: - Channel

    private func handleChannel(_ channel: Meshtastic_Channel) {
        guard channel.role != .disabled else { return }

        let name = extractChannelName(channel)
        let pskBase64 = channel.settings.psk.base64EncodedString()
        let info = ChannelInfo(
            id: Int(channel.index),
            name: name,
            psk: pskBase64,
            role: channel.role == .primary ? "PRIMARY" : "SECONDARY",
            uplinkEnabled: channel.settings.uplinkEnabled,
            downlinkEnabled: channel.settings.downlinkEnabled
        )

        if isInitializing {
            if !pendingChannelInfos.contains(where: { $0.id == info.id }) {
                pendingChannelInfos.append(info)
            }
        } else {
            if let idx = appState?.channels.firstIndex(where: { $0.id == info.id }) {
                appState?.channels[idx] = info
            } else {
                appState?.channels.append(info)
            }
            appState?.channels.sort { $0.id < $1.id }
        }

        receivedChannelResponses.insert(Int(channel.index))
        AppLogger.shared.log("[Protocol] Channel \(channel.index): \(name) [\(info.role)]", debug: SettingsService.shared.debugDevice)
    }

    private func extractChannelName(_ channel: Meshtastic_Channel) -> String {
        if !channel.settings.name.isEmpty { return channel.settings.name }
        if channel.role == .primary { return "Default" }
        return "Channel \(channel.index)"
    }

    // MARK: - Config

    private func handleConfig(_ config: Meshtastic_Config) {
        switch config.payloadVariant {
        case .lora(let lora):
            AppLogger.shared.log("[Protocol] Config: LoRa region=\(lora.region.name) modem=\(lora.modemPreset.name) hopLimit=\(lora.hopLimit) txEnabled=\(lora.txEnabled)", debug: SettingsService.shared.debugDevice)
        case .device(let device):
            AppLogger.shared.log("[Protocol] Config: Device role=\(device.role) serialEnabled=\(device.serialEnabled)", debug: SettingsService.shared.debugDevice)
        case .position(let pos):
            AppLogger.shared.log("[Protocol] Config: Position broadcastSecs=\(pos.positionBroadcastSecs) smartEnabled=\(pos.positionBroadcastSmartEnabled)", debug: SettingsService.shared.debugDevice)
        case .power(let pwr):
            AppLogger.shared.log("[Protocol] Config: Power saving=\(pwr.isPowerSaving)", debug: SettingsService.shared.debugDevice)
        case .network(let net):
            AppLogger.shared.log("[Protocol] Config: Network wifiEnabled=\(net.wifiEnabled) ssid=\(net.wifiSsid)", debug: SettingsService.shared.debugDevice)
        case .display(let disp):
            AppLogger.shared.log("[Protocol] Config: Display screenOnSecs=\(disp.screenOnSecs)", debug: SettingsService.shared.debugDevice)
        case .bluetooth(let bt):
            AppLogger.shared.log("[Protocol] Config: Bluetooth enabled=\(bt.enabled) mode=\(bt.mode)", debug: SettingsService.shared.debugDevice)
        case .none:
            AppLogger.shared.log("[Protocol] Config received (empty)", debug: SettingsService.shared.debugDevice)
        }
    }

    // MARK: - Admin

    private func handleAdminPacket(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        guard let admin = try? Meshtastic_AdminMessage(serializedBytes: data.payload) else { return }

        switch admin.payloadVariant {
        case .getChannelResponse(let channel):
            handleChannel(channel)
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

    // MARK: - Telemetry

    private func handleTelemetry(data: Meshtastic_Data, packet: Meshtastic_MeshPacket) {
        guard let node = appState?.node(forId: packet.from) else { return }

        // Always update lastSeen/lastHeard
        node.lastSeen = formatTime()
        node.lastHeard = Int32(Date().timeIntervalSince1970)

        // Parse Telemetry wrapper → DeviceMetrics
        guard let telemetry = try? Meshtastic_Telemetry(serializedBytes: data.payload) else {
            AppLogger.shared.log("[Protocol] Telemetry parse failed from \(nodeDisplayName(packet.from))", debug: SettingsService.shared.debugDevice)
            return
        }

        guard case .deviceMetrics(let metrics) = telemetry.variant else { return }

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
        AppLogger.shared.log("[Protocol] Requesting channels...", debug: true)
        for round in 0..<3 {
            for idx in 0..<8 {
                if receivedChannelResponses.contains(idx) { continue }
                await sendGetChannelRequest(index: idx)
                try? await Task.sleep(for: .milliseconds(150))
            }
            try? await Task.sleep(for: .seconds(5))
            AppLogger.shared.log("[Protocol] Channel round \(round+1): received \(receivedChannelResponses.count) channels", debug: true)
            if receivedChannelResponses.count >= (appState?.channels.count ?? 1) { break }
        }
    }

    // MARK: - Send Methods

    func sendTextMessage(_ text: String, toNodeId: UInt32 = 0xFFFFFFFF, channelIndex: Int = 0) async {
        var packet = Meshtastic_MeshPacket()
        packet.to = toNodeId
        packet.channel = UInt32(channelIndex)
        packet.hopLimit = 7
        packet.wantAck = false
        var data = Meshtastic_Data()
        data.portnum = 1   // TEXT_MESSAGE_APP
        data.payload = text.data(using: .utf8) ?? Data()
        packet.decoded = data

        await sendToRadio(packet: packet)
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
        if isInitializing {
            pendingMessages.append(msg)
        } else {
            appState?.appendMessage(msg)
        }
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
}

extension Notification.Name {
    static let alertBellTriggered = Notification.Name("MeshHessen.alertBellTriggered")
    static let incomingDirectMessage = Notification.Name("MeshHessen.incomingDirectMessage")
}
