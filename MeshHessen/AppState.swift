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

    /// Persistence hook installed by AppCoordinator. Keeping the callback on
    /// state avoids coupling this UI model directly to CoreData while allowing
    /// reaction mutations to be stored immediately.
    @ObservationIgnored
    var onMessageMutation: ((MessageItem, MessageStorageContext) -> Void)?

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
    /// One-shot request from another view to toggle a node's position track.
    var mapPathToggleNodeId: UInt32?

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

    func appendMessage(_ incomingMessage: MessageItem, markUnread: Bool = true) {
        let msg = incomingMessage.normalizingUnknownChannel()
        let storageContext = MessageStorageContext.channel(msg.channelIndex)
        let persistenceKey = msg.persistenceKey(in: storageContext)
        if let existingIdx = allMessages.firstIndex(where: {
            $0.persistenceKey(in: .channel($0.channelIndex)) == persistenceKey
        }) {
            let merged = mergeMessage(existing: allMessages[existingIdx], incoming: msg)
            allMessages[existingIdx] = merged

            let existingChannel = merged.channelIndex
            if let channelIdx = channelMessages[existingChannel]?.firstIndex(where: {
                $0.persistenceKey(in: .channel(existingChannel)) == persistenceKey
            }) {
                channelMessages[existingChannel]?[channelIdx] = merged
            }
            return
        }

        allMessages.append(msg)
        if msg.hasKnownChannel {
            channelMessages[msg.channelIndex, default: []].append(msg)
        }

        // Increment unread counter for incoming messages that arrive in an inactive channel
        let isOwn = msg.fromId != 0 && msg.fromId == myNodeInfo?.nodeId
        let isActive = selectedTab == .messages && msg.channelIndex == selectedChannelIndex
        if markUnread && !isOwn && !isActive {
            channelUnreadCounts[msg.channelIndex, default: 0] += 1
        }
    }

    /// Prepends an older persisted channel page without duplicating live or
    /// previously hydrated messages.
    func prependChannelMessages(_ messages: [MessageItem], channelIndex: Int) {
        let knownMessages = messages
            .map { $0.normalizingUnknownChannel() }
            .filter { $0.hasKnownChannel && $0.channelIndex == channelIndex }
        guard !knownMessages.isEmpty else { return }

        let context = MessageStorageContext.channel(channelIndex)
        let existingKeys = Set(
            (channelMessages[channelIndex] ?? []).map { $0.persistenceKey(in: context) }
        )
        let uniqueOlder = knownMessages.filter {
            !existingKeys.contains($0.persistenceKey(in: context))
        }
        guard !uniqueOlder.isEmpty else { return }

        channelMessages[channelIndex, default: []].insert(contentsOf: uniqueOlder, at: 0)
        let allKeys = Set(allMessages.map {
            $0.persistenceKey(in: .channel($0.channelIndex))
        })
        allMessages.append(contentsOf: uniqueOlder.filter {
            !allKeys.contains($0.persistenceKey(in: context))
        })
        allMessages.sort { $0.createdAt < $1.createdAt }
    }

    /// Prepends an older persisted direct-message page to the selected partner.
    func prependDirectMessages(_ messages: [MessageItem], partnerNodeId: UInt32) {
        let conversation = ensureDMConversation(for: partnerNodeId)
        let context = MessageStorageContext.directMessage(partnerNodeId: partnerNodeId)
        let existingKeys = Set(conversation.messages.map { $0.persistenceKey(in: context) })
        let uniqueOlder = messages.filter { !existingKeys.contains($0.persistenceKey(in: context)) }
        guard !uniqueOlder.isEmpty else { return }
        conversation.messages.insert(contentsOf: uniqueOlder, at: 0)
    }

    /// Mark all messages in `index` as read.
    func clearChannelUnread(_ index: Int) {
        channelUnreadCounts[index] = 0
    }

    /// Remove all in-memory messages for a given channel.
    func clearChannelMessages(_ index: Int) {
        channelMessages[index]?.removeAll()
        allMessages.removeAll { $0.channelIndex == index }
        channelUnreadCounts[index] = 0
    }

    /// Removes only channel messages older than `cutoff`, keeping the live
    /// in-memory view consistent with a scoped persistence deletion.
    func clearChannelMessages(_ index: Int, olderThan cutoff: Date) {
        channelMessages[index]?.removeAll { $0.createdAt < cutoff }
        allMessages.removeAll { $0.channelIndex == index && $0.createdAt < cutoff }
    }

    /// Remove all in-memory messages for a DM conversation.
    func clearDMMessages(for nodeId: UInt32) {
        dmConversations[nodeId]?.messages.removeAll()
    }

    func clearDMMessages(for nodeId: UInt32, olderThan cutoff: Date) {
        dmConversations[nodeId]?.messages.removeAll { $0.createdAt < cutoff }
    }

    func addOrUpdateDM(
        _ msg: MessageItem,
        myNodeId: UInt32,
        partnerNodeId: UInt32? = nil,
        markUnread: Bool = true
    ) {
        let partnerId = partnerNodeId ?? (msg.fromId == myNodeId ? msg.toId : msg.fromId)
        let partnerName = nodes[partnerId]?.name ?? msg.from
        let colorHex = nodes[partnerId]?.colorHex ?? ""
        let storageContext = MessageStorageContext.directMessage(partnerNodeId: partnerId)
        let persistenceKey = msg.persistenceKey(in: storageContext)

        if dmConversations[partnerId] == nil {
            dmConversations[partnerId] = DirectMessageConversation(
                nodeId: partnerId, nodeName: partnerName, colorHex: colorHex
            )
        }
        if let existing = dmConversations[partnerId]?.messages.firstIndex(where: {
            $0.persistenceKey(in: storageContext) == persistenceKey
        }) {
            if let current = dmConversations[partnerId]?.messages[existing] {
                dmConversations[partnerId]?.messages[existing] = mergeMessage(existing: current, incoming: msg)
            }
        } else {
            dmConversations[partnerId]?.messages.append(msg)
        }
        // Only mark unread for incoming messages, not our own
        if markUnread && msg.fromId != myNodeId {
            dmConversations[partnerId]?.hasUnread = true
        }
    }

    /// Look up a message by its packet ID, searching channel messages first, then DMs.
    func findMessageByPacketId(
        _ packetId: UInt32,
        context: MessageStorageContext? = nil
    ) -> MessageItem? {
        if let msg = allMessages.first(where: {
            $0.packetId == packetId && (context == nil || context == .channel($0.channelIndex))
        }) {
            return msg
        }
        for conv in dmConversations.values where context == nil || context == .directMessage(partnerNodeId: conv.id) {
            if let msg = conv.messages.first(where: { $0.packetId == packetId }) {
                return msg
            }
        }
        return nil
    }

    func addReaction(
        emoji: String,
        from senderId: UInt32,
        toPacketId: UInt32,
        context: MessageStorageContext? = nil
    ) {
        if let allIdx = allMessages.firstIndex(where: {
            $0.packetId == toPacketId && (context == nil || context == .channel($0.channelIndex))
        }) {
            allMessages[allIdx].addReaction(emoji: emoji, from: senderId)
            let channelIndex = allMessages[allIdx].channelIndex
            if let channelMsgIdx = channelMessages[channelIndex]?.firstIndex(where: {
                $0.persistenceKey(in: .channel(channelIndex))
                    == allMessages[allIdx].persistenceKey(in: .channel(channelIndex))
            }) {
                channelMessages[channelIndex]?[channelMsgIdx].addReaction(emoji: emoji, from: senderId)
            }
            onMessageMutation?(allMessages[allIdx], .channel(channelIndex))
        }
        for key in dmConversations.keys where context == nil || context == .directMessage(partnerNodeId: key) {
            guard let msgIdx = dmConversations[key]?.messages.firstIndex(where: { $0.packetId == toPacketId }) else { continue }
            dmConversations[key]?.messages[msgIdx].addReaction(emoji: emoji, from: senderId)
            if let message = dmConversations[key]?.messages[msgIdx] {
                onMessageMutation?(message, .directMessage(partnerNodeId: key))
            }
        }
    }

    func updateDeliveryState(
        requestId: UInt32,
        state: MessageDeliveryState,
        context: MessageStorageContext? = nil
    ) {
        if let allIdx = allMessages.firstIndex(where: {
            $0.packetId == requestId && (context == nil || context == .channel($0.channelIndex))
        }) {
            let mergedState = allMessages[allIdx].deliveryState.merging(state)
            allMessages[allIdx].deliveryState = mergedState
            let channelIndex = allMessages[allIdx].channelIndex
            if let channelMessageIndex = channelMessages[channelIndex]?.firstIndex(where: { $0.packetId == requestId }) {
                channelMessages[channelIndex]?[channelMessageIndex].deliveryState = mergedState
            }
        }

        for key in dmConversations.keys where context == nil || context == .directMessage(partnerNodeId: key) {
            guard let msgIndex = dmConversations[key]?.messages.firstIndex(where: { $0.packetId == requestId }) else {
                continue
            }
            let currentState = dmConversations[key]?.messages[msgIndex].deliveryState ?? .none
            dmConversations[key]?.messages[msgIndex].deliveryState = currentState.merging(state)
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
        if let replyToPacketId = incoming.replyToPacketId {
            merged.replyToPacketId = replyToPacketId
        }

        merged.time = incoming.time
        merged.fromId = incoming.fromId
        merged.toId = incoming.toId
        merged.channelIndex = incoming.channelIndex
        merged.isEncrypted = incoming.isEncrypted
        merged.isViaMqtt = incoming.isViaMqtt
        merged.hasAlertBell = incoming.hasAlertBell
        if let hopCount = incoming.hopCount { merged.hopCount = hopCount }
        if let receivedSnr = incoming.receivedSnr { merged.receivedSnr = receivedSnr }
        if let receivedRssi = incoming.receivedRssi { merged.receivedRssi = receivedRssi }

        if incoming.deliveryState != .none {
            merged.deliveryState = incoming.deliveryState
        }

        for (emoji, senders) in incoming.reactionsByEmoji {
            for senderId in senders {
                merged.addReaction(emoji: emoji, from: senderId)
            }
        }

        if incoming.createdAt < merged.createdAt {
            merged.createdAt = incoming.createdAt
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
            existing.isFavorite = info.isFavorite
            existing.isOwnNode = info.isOwnNode
            // Preserve pin state from existing node (don't overwrite with incoming data)
            if info.isPinned { existing.isPinned = info.isPinned }
            if info.lastTracerouteHopCount > 0 {
                existing.lastTracerouteHopCount = info.lastTracerouteHopCount
            }
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

    /// Clears the client-side mirror of the radio's NodeDB while preserving
    /// channels, messages, and conversations.
    func resetNodeDatabaseMirror() {
        nodes.removeAll()
    }

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
