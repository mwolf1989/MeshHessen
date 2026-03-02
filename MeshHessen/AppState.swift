import Foundation
import SwiftUI

/// Central application state — injected as environment object
@Observable
@MainActor
final class AppState {
    // MARK: - Connection
    var connectionState: ConnectionState = .disconnected
    var protocolReady: Bool = false
    var protocolStatusMessage: String?
    var myNodeInfo: MyNodeInfo?

    // MARK: - Nodes
    var nodes: [UInt32: NodeInfo] = [:] {
        didSet { recomputeFilteredNodes() }
    }
    var nodeFilter: String = "" {
        didSet { recomputeFilteredNodes() }
    }

    private(set) var filteredNodes: [NodeInfo] = []

    private func recomputeFilteredNodes() {
        let sorted = nodes.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        guard !nodeFilter.isEmpty else { filteredNodes = sorted; return }
        let q = nodeFilter.lowercased()
        filteredNodes = sorted.filter {
            $0.name.lowercased().contains(q) ||
            $0.shortName.lowercased().contains(q) ||
            $0.nodeId.lowercased().contains(q) ||
            $0.note.lowercased().contains(q)
        }
    }

    // MARK: - Channels
    var channels: [ChannelInfo] = []

    // MARK: - Messages per channel (index → messages)
    var channelMessages: [Int: [MessageItem]] = [:]
    var allMessages: [MessageItem] = []   // unified feed

    /// Fast lookup: packetId → index in allMessages for O(1) dedup and delivery updates
    private var packetIdToAllIndex: [UInt32: Int] = [:]

    /// Number of unread messages per channel index.
    /// Only incremented for incoming messages (not from self) while that channel is not active.
    var channelUnreadCounts: [Int: Int] = [:]

    var totalChannelUnread: Int { channelUnreadCounts.values.reduce(0, +) }

    // MARK: - Direct Messages
    var dmConversations: [UInt32: DirectMessageConversation] = [:]
    var dmUnreadCount: Int {
        dmConversations.values.filter { $0.hasUnread }.count
    }

    // MARK: - Alert Bell
    var activeAlertBell: MessageItem?
    var showAlertBell: Bool = false

    // MARK: - Map
    var showMap: Bool = false
    /// Set to a node ID to have MapView center on that node's position.
    var mapFocusNodeId: UInt32?

    // MARK: - DM Window Target
    /// Set before opening the DM window to auto-select a conversation.
    var dmTargetNodeId: UInt32?

    /// Ensures a DM conversation exists for the given node, creating one if needed.
    @discardableResult
    func ensureDMConversation(for nodeId: UInt32) -> DirectMessageConversation {
        if let existing = dmConversations[nodeId] { return existing }
        let name = nodes[nodeId]?.name ?? "Node \(nodeId)"
        let color = nodes[nodeId]?.colorHex ?? ""
        let conv = DirectMessageConversation(nodeId: nodeId, nodeName: name, colorHex: color)
        dmConversations[nodeId] = conv
        return conv
    }

    // MARK: - Active tab
    var selectedTab: MainTab = .messages
    var selectedChannelIndex: Int = 0

    // MARK: - Debug log
    struct DebugLine: Identifiable {
        let id: Int
        let text: String
    }
    var debugLines: [DebugLine] = []
    private var debugLineCounter: Int = 0
    let maxDebugLines = 10_000

    func appendDebugLine(_ line: String) {
        debugLineCounter += 1
        debugLines.append(DebugLine(id: debugLineCounter, text: line))
        if debugLines.count > maxDebugLines {
            debugLines.removeFirst(debugLines.count - maxDebugLines)
        }
    }

    // MARK: - Message helpers

    func appendMessage(_ msg: MessageItem) {
        if let packetId = msg.packetId {
            if let allIndex = packetIdToAllIndex[packetId] {
                let merged = mergeMessage(existing: allMessages[allIndex], incoming: msg)
                allMessages[allIndex] = merged

                let existingChannel = merged.channelIndex
                if let channelIndex = channelMessages[existingChannel]?.firstIndex(where: { $0.packetId == packetId }) {
                    channelMessages[existingChannel]?[channelIndex] = merged
                }
                return
            }
        }

        let newIndex = allMessages.count
        allMessages.append(msg)
        channelMessages[msg.channelIndex, default: []].append(msg)
        if let packetId = msg.packetId {
            packetIdToAllIndex[packetId] = newIndex
        }

        // Increment unread counter for incoming messages that arrive in an inactive channel
        let isOwn = msg.fromId != 0 && msg.fromId == myNodeInfo?.nodeId
        let isActive = selectedTab == .messages && msg.channelIndex == selectedChannelIndex
        if !isOwn && !isActive {
            channelUnreadCounts[msg.channelIndex, default: 0] += 1
        }
    }

    /// Mark all messages in `index` as read.
    func clearChannelUnread(_ index: Int) {
        channelUnreadCounts[index] = 0
    }

    /// Remove all in-memory messages for a given channel.
    func clearChannelMessages(_ index: Int) {
        channelMessages[index]?.removeAll()
        allMessages.removeAll { $0.channelIndex == index }
        rebuildPacketIdIndex()
        channelUnreadCounts[index] = 0
    }

    /// Remove all in-memory messages for a DM conversation.
    func clearDMMessages(for nodeId: UInt32) {
        dmConversations[nodeId]?.messages.removeAll()
    }

    func addOrUpdateDM(_ msg: MessageItem, myNodeId: UInt32) {
        let partnerId = msg.fromId == myNodeId ? msg.toId : msg.fromId
        let partnerName = nodes[partnerId]?.name ?? msg.from
        let colorHex = nodes[partnerId]?.colorHex ?? ""

        if dmConversations[partnerId] == nil {
            dmConversations[partnerId] = DirectMessageConversation(
                nodeId: partnerId, nodeName: partnerName, colorHex: colorHex
            )
        }
        if let packetId = msg.packetId,
           let existing = dmConversations[partnerId]?.messages.firstIndex(where: { $0.packetId == packetId }) {
            if let current = dmConversations[partnerId]?.messages[existing] {
                dmConversations[partnerId]?.messages[existing] = mergeMessage(existing: current, incoming: msg)
            }
        } else {
            dmConversations[partnerId]?.messages.append(msg)
        }
        // Only mark unread for incoming messages, not our own
        if msg.fromId != myNodeId {
            dmConversations[partnerId]?.hasUnread = true
        }
    }

    /// Look up a message by its packet ID, searching channel messages first, then DMs.
    func findMessageByPacketId(_ packetId: UInt32) -> MessageItem? {
        if let idx = packetIdToAllIndex[packetId] {
            return allMessages[idx]
        }
        for conv in dmConversations.values {
            if let msg = conv.messages.first(where: { $0.packetId == packetId }) {
                return msg
            }
        }
        return nil
    }

    func addReaction(emoji: String, from senderId: UInt32, toPacketId: UInt32) {
        if let allIndex = packetIdToAllIndex[toPacketId] {
            allMessages[allIndex].addReaction(emoji: emoji, from: senderId)
            let channelIndex = allMessages[allIndex].channelIndex
            if let channelMsgIdx = channelMessages[channelIndex]?.firstIndex(where: { $0.packetId == toPacketId }) {
                channelMessages[channelIndex]?[channelMsgIdx].addReaction(emoji: emoji, from: senderId)
            }
        }
        for key in dmConversations.keys {
            guard let msgIdx = dmConversations[key]?.messages.firstIndex(where: { $0.packetId == toPacketId }) else { continue }
            dmConversations[key]?.messages[msgIdx].addReaction(emoji: emoji, from: senderId)
        }
    }

    func updateDeliveryState(requestId: UInt32, state: MessageDeliveryState) {
        if let allIndex = packetIdToAllIndex[requestId] {
            allMessages[allIndex].deliveryState = state
            let channelIndex = allMessages[allIndex].channelIndex
            if let channelMessageIndex = channelMessages[channelIndex]?.firstIndex(where: { $0.packetId == requestId }) {
                channelMessages[channelIndex]?[channelMessageIndex].deliveryState = state
            }
        }

        for key in dmConversations.keys {
            guard let msgIndex = dmConversations[key]?.messages.firstIndex(where: { $0.packetId == requestId }) else {
                continue
            }
            dmConversations[key]?.messages[msgIndex].deliveryState = state
        }
    }

    /// Rebuild the packetId→index mapping after destructive array operations.
    private func rebuildPacketIdIndex() {
        packetIdToAllIndex.removeAll(keepingCapacity: true)
        for (i, msg) in allMessages.enumerated() {
            if let pid = msg.packetId {
                packetIdToAllIndex[pid] = i
            }
        }
    }

    private func mergeMessage(existing: MessageItem, incoming: MessageItem) -> MessageItem {
        var merged = existing

        if !incoming.message.isEmpty { merged.message = incoming.message }
        if !incoming.from.isEmpty { merged.from = incoming.from }
        if !incoming.channelName.isEmpty { merged.channelName = incoming.channelName }
        if !incoming.senderShortName.isEmpty { merged.senderShortName = incoming.senderShortName }
        if !incoming.senderColorHex.isEmpty { merged.senderColorHex = incoming.senderColorHex }
        if !incoming.senderNote.isEmpty { merged.senderNote = incoming.senderNote }

        merged.time = incoming.time
        merged.fromId = incoming.fromId
        merged.toId = incoming.toId
        merged.channelIndex = incoming.channelIndex
        merged.isEncrypted = incoming.isEncrypted
        merged.isViaMqtt = incoming.isViaMqtt
        merged.hasAlertBell = incoming.hasAlertBell

        if incoming.deliveryState != .none {
            merged.deliveryState = incoming.deliveryState
        }

        return merged
    }

    // MARK: - Node helpers

    func node(forId id: UInt32) -> NodeInfo? { nodes[id] }

    func upsertNode(_ info: NodeInfo) {
        if let existing = nodes[info.id] {
            existing.shortName = info.shortName
            existing.longName = info.longName
            existing.name = info.name
            if info.snr != "-"       { existing.snr = info.snr; existing.snrFloat = info.snrFloat }
            if info.lastSeen != "-"  { existing.lastSeen = info.lastSeen; existing.lastHeard = info.lastHeard }
            if info.battery != "-"   { existing.battery = info.battery; existing.batteryLevel = info.batteryLevel }
            if info.rssi != "-"      { existing.rssi = info.rssi; existing.rssiInt = info.rssiInt }
            if let lat = info.latitude  { existing.latitude = lat }
            if let lon = info.longitude { existing.longitude = lon }
            if let alt = info.altitude  { existing.altitude = alt }
            existing.viaMqtt = info.viaMqtt
            // Preserve pin state from existing node (don't overwrite with incoming data)
            if info.isPinned { existing.isPinned = info.isPinned }
        } else {
            nodes[info.id] = info
        }
        // Recalculate distance if we have own position and node GPS
        recalculateDistance(for: info.id)
    }

    func recalculateDistance(for nodeId: UInt32) {
        guard let node = nodes[nodeId],
              let nLat = node.latitude, let nLon = node.longitude
        else { return }

        guard let myCoordinate = effectiveOwnCoordinate() else {
            node.distanceMeters = 0
            node.distance = "-"
            return
        }
        let myLat = myCoordinate.latitude
        let myLon = myCoordinate.longitude

        // Haversine
        let R = 6371000.0
        let dLat = (nLat - myLat) * .pi / 180
        let dLon = (nLon - myLon) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2)
             + cos(myLat * .pi/180) * cos(nLat * .pi/180)
             * sin(dLon/2) * sin(dLon/2)
        let c = 2 * atan2(sqrt(a), sqrt(1-a))
        let dist = R * c

        node.distanceMeters = dist
        if dist < 1000 {
            node.distance = String(format: "%.0f m", dist)
        } else {
            node.distance = String(format: "%.1f km", dist / 1000)
        }
    }

    func effectiveOwnCoordinate() -> (latitude: Double, longitude: Double)? {
        let settings = SettingsService.shared
        if settings.hasExplicitOwnPosition {
            return (settings.myLatitude, settings.myLongitude)
        }

        if let myNodeId = myNodeInfo?.nodeId,
           let myNode = nodes[myNodeId],
           let lat = myNode.latitude,
           let lon = myNode.longitude {
            return (lat, lon)
        }

        return nil
    }

    func recalculateAllDistances() {
        for id in nodes.keys { recalculateDistance(for: id) }
    }

    // MARK: - Reset on disconnect

    /// Resets transient connection state. CoreData-backed data (nodes, channels,
    /// messages) is preserved so it can be rehydrated on reconnect.
    func resetForDisconnect() {
        protocolReady = false
        protocolStatusMessage = nil
        myNodeInfo = nil
        // Keep nodes, channels, and messages — they live in CoreData
        // and will be re-merged on next connect.
        activeAlertBell = nil
        showAlertBell = false
    }

    /// Full reset: clears everything including in-memory caches.
    /// Used after a "Clear All Data" action.
    func resetAll() {
        protocolReady = false
        protocolStatusMessage = nil
        myNodeInfo = nil
        nodes.removeAll()
        channels.removeAll()
        channelMessages.removeAll()
        allMessages.removeAll()
        packetIdToAllIndex.removeAll()
        dmConversations.removeAll()
        activeAlertBell = nil
        showAlertBell = false
    }
}

enum MainTab: String, CaseIterable, Identifiable {
    case messages  = "Messages"
    case nodes     = "Nodes"
    case channels  = "Channels"
    case map       = "Map"
    case debug     = "Debug"
    case info      = "Info"

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .messages: return "Messages"
        case .nodes:    return "Nodes"
        case .channels: return "Channels"
        case .map:      return "Map"
        case .debug:    return "Debug"
        case .info:     return "Info"
        }
    }

    var icon: String {
        switch self {
        case .messages: return "envelope"
        case .nodes:    return "wifi"
        case .channels: return "antenna.radiowaves.left.and.right"
        case .map:      return "map"
        case .debug:    return "ladybug"
        case .info:     return "info.circle"
        }
    }
}
