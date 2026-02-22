import Foundation
import SwiftUI

/// Central application state — injected as environment object
@Observable
@MainActor
final class AppState {
    // MARK: - Connection
    var connectionState: ConnectionState = .disconnected
    var myNodeInfo: MyNodeInfo?

    // MARK: - Nodes
    var nodes: [UInt32: NodeInfo] = [:]
    var nodeFilter: String = ""

    var filteredNodes: [NodeInfo] {
        let sorted = nodes.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        guard !nodeFilter.isEmpty else { return sorted }
        let q = nodeFilter.lowercased()
        return sorted.filter {
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
    var debugLines: [String] = []
    let maxDebugLines = 10_000

    func appendDebugLine(_ line: String) {
        debugLines.append(line)
        if debugLines.count > maxDebugLines {
            debugLines.removeFirst(debugLines.count - maxDebugLines)
        }
    }

    // MARK: - Message helpers

    func appendMessage(_ msg: MessageItem) {
        allMessages.append(msg)
        channelMessages[msg.channelIndex, default: []].append(msg)
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
        dmConversations[partnerId]?.messages.append(msg)
        // Only mark unread for incoming messages, not our own
        if msg.fromId != myNodeId {
            dmConversations[partnerId]?.hasUnread = true
        }
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

        let settings = SettingsService.shared
        let myLat = settings.myLatitude
        let myLon = settings.myLongitude

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

    func recalculateAllDistances() {
        for id in nodes.keys { recalculateDistance(for: id) }
    }

    // MARK: - Reset on disconnect

    func resetForDisconnect() {
        myNodeInfo = nil
        nodes.removeAll()
        channels.removeAll()
        channelMessages.removeAll()
        allMessages.removeAll()
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
