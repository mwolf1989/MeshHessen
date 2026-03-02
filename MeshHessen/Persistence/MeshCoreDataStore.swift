import CoreData
import Foundation

struct CoreDataHydrationStats {
    var nodes: Int = 0
    var channels: Int = 0
    var channelMessages: Int = 0
    var directMessages: Int = 0
    var conversationsWithUnread: Int = 0
    var migratedColors: Int = 0
    var migratedNotes: Int = 0
}

final class MeshCoreDataStore {
    private let persistenceController: PersistenceController

    /// Maximum number of messages to keep per channel / conversation.
    /// Older messages are trimmed during retention passes.
    private let maxMessagesPerBucket = 5_000

    /// Nodes not heard from in this many days are considered stale.
    private let staleNodeDays = 90

    init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    // MARK: - UserDefaults → CoreData Migration

    /// Migrates `nodeColor_*` and `nodeNote_*` values from UserDefaults into CoreData.
    /// Idempotent — skips nodes that already have a non-empty value in CoreData.
    func migrateNodeCustomizationsFromUserDefaults() {
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys
        let context = persistenceController.newBackgroundContext()

        context.performAndWait {
            var migratedColors = 0
            var migratedNotes = 0

            for key in allKeys {
                if key.hasPrefix("nodeColor_") {
                    let hexPart = String(key.dropFirst("nodeColor_".count))
                    guard let nodeNum = UInt32(hexPart, radix: 16), nodeNum > 0 else { continue }
                    guard let colorHex = defaults.string(forKey: key), !colorHex.isEmpty else { continue }

                    let request = NSFetchRequest<NSManagedObject>(entityName: "MHNodeEntity")
                    request.fetchLimit = 1
                    request.predicate = NSPredicate(format: "nodeNum == %lld", Int64(nodeNum))

                    if let node = try? context.fetch(request).first {
                        let existing = node.value(forKey: "colorHex") as? String ?? ""
                        if existing.isEmpty {
                            node.setValue(colorHex, forKey: "colorHex")
                            migratedColors += 1
                        }
                    }
                }

                if key.hasPrefix("nodeNote_") {
                    let hexPart = String(key.dropFirst("nodeNote_".count))
                    guard let nodeNum = UInt32(hexPart, radix: 16), nodeNum > 0 else { continue }
                    guard let note = defaults.string(forKey: key), !note.isEmpty else { continue }

                    let request = NSFetchRequest<NSManagedObject>(entityName: "MHNodeEntity")
                    request.fetchLimit = 1
                    request.predicate = NSPredicate(format: "nodeNum == %lld", Int64(nodeNum))

                    if let node = try? context.fetch(request).first {
                        let existing = node.value(forKey: "note") as? String ?? ""
                        if existing.isEmpty {
                            node.setValue(note, forKey: "note")
                            migratedNotes += 1
                        }
                    }
                }
            }

            self.save(context: context, label: "migration-colors-notes")

            if migratedColors + migratedNotes > 0 {
                AppLogger.shared.log("[Migration] UserDefaults → CoreData: colors=\(migratedColors), notes=\(migratedNotes)")
            }
        }
    }

    // MARK: - Stale Node Cleanup

    /// Deletes nodes that haven't been heard from in `staleNodeDays`.
    /// Does NOT delete the user's own node.
    func clearStaleNodes(ownNodeId: UInt32? = nil) {
        let context = persistenceController.newBackgroundContext()
        context.perform {
            let cutoff = Int32(Date().addingTimeInterval(-Double(self.staleNodeDays) * 86400).timeIntervalSince1970)
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHNodeEntity")
            // lastHeard > 0 (has been heard at all) AND lastHeard < cutoff
            var predicates: [NSPredicate] = [
                NSPredicate(format: "lastHeard > 0"),
                NSPredicate(format: "lastHeard < %d", cutoff)
            ]
            if let ownId = ownNodeId {
                predicates.append(NSPredicate(format: "nodeNum != %lld", Int64(ownId)))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

            guard let stale = try? context.fetch(request) else { return }
            for obj in stale { context.delete(obj) }
            self.save(context: context, label: "stale-nodes")

            if !stale.isEmpty {
                AppLogger.shared.log("[Retention] Removed \(stale.count) stale nodes (>\(self.staleNodeDays) days)")
            }
        }
    }

    // MARK: - Message Retention / Trimming

    /// Trims old messages so each channel/conversation keeps at most `maxMessagesPerBucket`.
    func trimOldMessages() {
        let context = persistenceController.newBackgroundContext()
        context.perform {
            var totalDeleted = 0

            // Channel messages: group by channelIndex where isDirect == false
            totalDeleted += self.trimMessages(
                in: context,
                predicate: NSPredicate(format: "isDirect == NO"),
                groupKey: "channelIndex"
            )

            // DM messages: group by partnerNodeId where isDirect == true
            totalDeleted += self.trimMessages(
                in: context,
                predicate: NSPredicate(format: "isDirect == YES"),
                groupKey: "partnerNodeId"
            )

            if totalDeleted > 0 {
                AppLogger.shared.log("[Retention] Trimmed \(totalDeleted) old messages (limit: \(self.maxMessagesPerBucket) per bucket)")
            }
        }
    }

    private func trimMessages(in context: NSManagedObjectContext, predicate: NSPredicate, groupKey: String) -> Int {
        // Get distinct group values using NSDictionaryResultType
        let distinctRequest = NSFetchRequest<NSDictionary>(entityName: "MHMessageEntity")
        distinctRequest.predicate = predicate
        distinctRequest.propertiesToFetch = [groupKey]
        distinctRequest.returnsDistinctResults = true
        distinctRequest.resultType = .dictionaryResultType

        guard let groups = try? context.fetch(distinctRequest) else { return 0 }
        var deleted = 0

        for group in groups {
            guard let groupValue = group[groupKey] else { continue }

            let countRequest = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            if let stringVal = groupValue as? String {
                countRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    predicate,
                    NSPredicate(format: "\(groupKey) == %@", stringVal)
                ])
            } else if let numVal = groupValue as? NSNumber {
                countRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    predicate,
                    NSPredicate(format: "\(groupKey) == %@", numVal)
                ])
            } else {
                continue
            }
            let count = (try? context.count(for: countRequest)) ?? 0
            guard count > maxMessagesPerBucket else { continue }

            // Find oldest messages to delete
            let toDelete = count - maxMessagesPerBucket
            let deleteRequest = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            deleteRequest.predicate = countRequest.predicate
            deleteRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            deleteRequest.fetchLimit = toDelete

            if let old = try? context.fetch(deleteRequest) {
                for obj in old { context.delete(obj) }
                deleted += old.count
            }
        }

        save(context: context, label: "trim-\(groupKey)")
        return deleted
    }

    // MARK: - Conversation Unread Persistence

    /// Updates the `hasUnread` flag in CoreData for a conversation.
    func setConversationUnread(partnerNodeId: UInt32, hasUnread: Bool) {
        let context = persistenceController.newBackgroundContext()
        context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHConversationEntity")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "partnerNodeId == %lld", Int64(partnerNodeId))

            if let object = try? context.fetch(request).first {
                let current = object.value(forKey: "hasUnread") as? Bool ?? false
                if current != hasUnread {
                    object.setValue(hasUnread, forKey: "hasUnread")
                    self.save(context: context, label: "unread")
                }
            }
        }
    }

    // MARK: - Batch Operations

    /// Deletes all messages for a specific channel.
    func deleteChannelMessages(channelIndex: Int) {
        let context = persistenceController.newBackgroundContext()
        context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "isDirect == NO"),
                NSPredicate(format: "channelIndex == %d", Int32(channelIndex))
            ])
            if let messages = try? context.fetch(request) {
                for obj in messages { context.delete(obj) }
                self.save(context: context, label: "delete-channel-msgs")
                AppLogger.shared.log("[Persistence] Deleted \(messages.count) messages for channel \(channelIndex)", debug: true)
            }
        }
    }

    /// Deletes all DM messages for a specific conversation partner.
    func deleteConversationMessages(partnerNodeId: UInt32) {
        let context = persistenceController.newBackgroundContext()
        context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "isDirect == YES"),
                NSPredicate(format: "partnerNodeId == %lld", Int64(partnerNodeId))
            ])
            if let messages = try? context.fetch(request) {
                for obj in messages { context.delete(obj) }
            }
            // Also delete the conversation entity
            let convRequest = NSFetchRequest<NSManagedObject>(entityName: "MHConversationEntity")
            convRequest.fetchLimit = 1
            convRequest.predicate = NSPredicate(format: "partnerNodeId == %lld", Int64(partnerNodeId))
            if let conv = try? context.fetch(convRequest).first {
                context.delete(conv)
            }
            self.save(context: context, label: "delete-conv-msgs")
        }
    }

    /// Nuclear option: clears the entire database.
    func clearAllData() {
        let context = persistenceController.newBackgroundContext()
        context.perform {
            for entity in ["MHMessageEntity", "MHConversationEntity", "MHChannelEntity", "MHNodeEntity"] {
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                if let objects = try? context.fetch(request) {
                    for obj in objects { context.delete(obj) }
                }
            }
            self.save(context: context, label: "clear-all")
            AppLogger.shared.log("[Persistence] Database cleared")
        }
    }

    // MARK: - Paged Message Fetch

    /// Fetches channel messages with paging support.
    func fetchChannelMessages(channelIndex: Int, limit: Int = 200, offset: Int = 0) -> [MessageItem] {
        let context = persistenceController.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "isDirect == NO"),
            NSPredicate(format: "channelIndex == %d", Int32(channelIndex))
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchLimit = limit
        request.fetchOffset = offset

        guard let results = try? context.fetch(request) else { return [] }
        return results.reversed().compactMap(makeMessage(from:))
    }

    /// Fetches DM messages for a conversation with paging support.
    func fetchDirectMessages(partnerNodeId: UInt32, limit: Int = 200, offset: Int = 0) -> [MessageItem] {
        let context = persistenceController.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "isDirect == YES"),
            NSPredicate(format: "partnerNodeId == %lld", Int64(partnerNodeId))
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchLimit = limit
        request.fetchOffset = offset

        guard let results = try? context.fetch(request) else { return [] }
        return results.reversed().compactMap(makeMessage(from:))
    }

    func upsertNode(_ node: NodeInfo) {
        let context = persistenceController.newBackgroundContext()
        context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHNodeEntity")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "nodeNum == %lld", Int64(node.id))

            let object = (try? context.fetch(request).first) ?? NSEntityDescription.insertNewObject(forEntityName: "MHNodeEntity", into: context)

            object.setValue(Int64(node.id), forKey: "nodeNum")
            object.setValue(node.nodeId, forKey: "nodeId")
            object.setValue(node.shortName, forKey: "shortName")
            object.setValue(node.longName, forKey: "longName")
            object.setValue(node.name, forKey: "displayName")
            object.setValue(node.distance, forKey: "distanceText")
            object.setValue(node.snr, forKey: "snrText")
            object.setValue(node.rssi, forKey: "rssiText")
            object.setValue(node.battery, forKey: "batteryText")
            object.setValue(node.lastSeen, forKey: "lastSeenText")
            object.setValue(node.latitude, forKey: "latitude")
            object.setValue(node.longitude, forKey: "longitude")
            object.setValue(node.altitude.map { Int64($0) }, forKey: "altitude")
            object.setValue(node.colorHex, forKey: "colorHex")
            object.setValue(node.note, forKey: "note")
            object.setValue(Int32(node.lastHeard), forKey: "lastHeard")
            object.setValue(node.snrFloat, forKey: "snrFloat")
            object.setValue(Int32(node.rssiInt), forKey: "rssiInt")
            object.setValue(Int64(node.batteryLevel), forKey: "batteryLevel")
            object.setValue(node.voltage, forKey: "voltage")
            object.setValue(node.channelUtilization, forKey: "channelUtilization")
            object.setValue(node.airUtilTx, forKey: "airUtilTx")
            object.setValue(node.distanceMeters, forKey: "distanceMeters")
            object.setValue(node.viaMqtt, forKey: "viaMqtt")
            object.setValue(node.isPinned, forKey: "isPinned")

            self.save(context: context, label: "node")
        }
    }

    func upsertChannel(_ channel: ChannelInfo) {
        let context = persistenceController.newBackgroundContext()
        context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHChannelEntity")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "channelIndex == %d", channel.id)

            let object = (try? context.fetch(request).first) ?? NSEntityDescription.insertNewObject(forEntityName: "MHChannelEntity", into: context)

            object.setValue(Int32(channel.id), forKey: "channelIndex")
            object.setValue(channel.name, forKey: "name")
            object.setValue(channel.psk, forKey: "psk")
            object.setValue(channel.role, forKey: "role")
            object.setValue(channel.uplinkEnabled, forKey: "uplinkEnabled")
            object.setValue(channel.downlinkEnabled, forKey: "downlinkEnabled")

            self.save(context: context, label: "channel")
        }
    }

    func upsertMessage(_ message: MessageItem, isDirect: Bool, partnerNodeId: UInt32?, partnerName: String? = nil) {
        guard let packetId = message.packetId, packetId != 0 else { return }

        let context = persistenceController.newBackgroundContext()
        context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "packetId == %lld", Int64(packetId))

            let object = (try? context.fetch(request).first) ?? NSEntityDescription.insertNewObject(forEntityName: "MHMessageEntity", into: context)

            object.setValue(Int64(packetId), forKey: "packetId")
            object.setValue(Date(), forKey: "createdAt")
            object.setValue(message.time, forKey: "timeText")
            object.setValue(message.from, forKey: "fromName")
            object.setValue(Int64(message.fromId), forKey: "fromId")
            object.setValue(Int64(message.toId), forKey: "toId")
            object.setValue(message.message, forKey: "messageText")
            object.setValue(Int32(message.channelIndex), forKey: "channelIndex")
            object.setValue(message.channelName, forKey: "channelName")
            object.setValue(message.isEncrypted, forKey: "isEncrypted")
            object.setValue(message.isViaMqtt, forKey: "isViaMqtt")
            object.setValue(message.senderShortName, forKey: "senderShortName")
            object.setValue(message.senderColorHex, forKey: "senderColorHex")
            object.setValue(message.senderNote, forKey: "senderNote")
            object.setValue(message.hasAlertBell, forKey: "hasAlertBell")
            object.setValue(Self.deliveryStateString(from: message.deliveryState), forKey: "deliveryState")
            object.setValue(Self.deliveryErrorString(from: message.deliveryState), forKey: "deliveryError")
            object.setValue(isDirect, forKey: "isDirect")
            object.setValue(partnerNodeId.map { Int64($0) } ?? 0, forKey: "partnerNodeId")

            if isDirect, let partnerNodeId {
                let resolvedPartnerName = partnerName ?? message.from
                self.upsertConversation(in: context, partnerNodeId: partnerNodeId, nodeName: resolvedPartnerName, colorHex: message.senderColorHex)
            }

            self.save(context: context, label: "message")
        }
    }

    func updateDeliveryState(requestId: UInt32, state: MessageDeliveryState) {
        guard requestId != 0 else { return }

        let context = persistenceController.newBackgroundContext()
        context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "packetId == %lld", Int64(requestId))

            guard let object = try? context.fetch(request).first else { return }

            object.setValue(Self.deliveryStateString(from: state), forKey: "deliveryState")
            object.setValue(Self.deliveryErrorString(from: state), forKey: "deliveryError")

            self.save(context: context, label: "delivery")
        }
    }

    private func upsertConversation(in context: NSManagedObjectContext, partnerNodeId: UInt32, nodeName: String, colorHex: String) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHConversationEntity")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "partnerNodeId == %lld", Int64(partnerNodeId))

        let object = (try? context.fetch(request).first) ?? NSEntityDescription.insertNewObject(forEntityName: "MHConversationEntity", into: context)

        object.setValue(Int64(partnerNodeId), forKey: "partnerNodeId")
        object.setValue(nodeName, forKey: "nodeName")
        object.setValue(colorHex, forKey: "colorHex")
        object.setValue(Date(), forKey: "updatedAt")
    }

    private func save(context: NSManagedObjectContext, label: String) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            AppLogger.shared.log("[Persistence] Failed to save \(label): \(error.localizedDescription)")
        }
    }

    private static func deliveryStateString(from state: MessageDeliveryState) -> String {
        switch state {
        case .none: return "none"
        case .pending: return "pending"
        case .acknowledged: return "acknowledged"
        case .failed: return "failed"
        }
    }

    private static func deliveryErrorString(from state: MessageDeliveryState) -> String? {
        switch state {
        case .failed(let reason): return reason
        default: return nil
        }
    }

    @MainActor
    func hydrate(appState: AppState) -> CoreDataHydrationStats {
        let context = persistenceController.container.viewContext
        var stats = CoreDataHydrationStats()

        // 1. Hydrate nodes
        if appState.nodes.isEmpty {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHNodeEntity")
            request.sortDescriptors = [NSSortDescriptor(key: "lastHeard", ascending: false)]
            if let nodes = try? context.fetch(request) {
                for object in nodes {
                    guard let node = makeNode(from: object) else { continue }
                    appState.upsertNode(node)
                    stats.nodes += 1
                }
            }
        }

        // 2. Hydrate channels
        if appState.channels.isEmpty {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHChannelEntity")
            request.sortDescriptors = [NSSortDescriptor(key: "channelIndex", ascending: true)]
            if let channels = try? context.fetch(request) {
                let mapped = channels.compactMap(makeChannel(from:))
                if !mapped.isEmpty {
                    appState.channels = mapped
                    stats.channels = mapped.count
                }
            }
        }

        // 3. Hydrate conversations (metadata + unread state)
        let convRequest = NSFetchRequest<NSManagedObject>(entityName: "MHConversationEntity")
        convRequest.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        if let conversations = try? context.fetch(convRequest) {
            for convObj in conversations {
                let partnerNodeId = UInt32((convObj.value(forKey: "partnerNodeId") as? Int64) ?? 0)
                guard partnerNodeId > 0 else { continue }
                let nodeName = convObj.value(forKey: "nodeName") as? String ?? "Node \(partnerNodeId)"
                let colorHex = convObj.value(forKey: "colorHex") as? String ?? ""
                let hasUnread = convObj.value(forKey: "hasUnread") as? Bool ?? false

                if appState.dmConversations[partnerNodeId] == nil {
                    let conv = DirectMessageConversation(nodeId: partnerNodeId, nodeName: nodeName, colorHex: colorHex)
                    conv.hasUnread = hasUnread
                    appState.dmConversations[partnerNodeId] = conv
                    if hasUnread { stats.conversationsWithUnread += 1 }
                }
            }
        }

        // 4. Hydrate messages (with limit for performance)
        let messageRequest = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
        messageRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        messageRequest.fetchLimit = 10_000 // Safety cap for large databases
        if let messages = try? context.fetch(messageRequest) {
            var seenPacketIds = Set<UInt32>()
            for object in messages {
                guard let message = makeMessage(from: object) else { continue }

                // Deduplicate by packetId
                if let packetId = message.packetId, packetId != 0 {
                    guard seenPacketIds.insert(packetId).inserted else { continue }
                }

                let isDirect = object.value(forKey: "isDirect") as? Bool ?? false
                if isDirect {
                    _ = UInt32((object.value(forKey: "partnerNodeId") as? Int64) ?? Int64(message.fromId))
                    appState.addOrUpdateDM(message, myNodeId: appState.myNodeInfo?.nodeId ?? 0)
                    // Preserve unread state from conversation entity (already loaded above)
                    stats.directMessages += 1
                } else {
                    appState.appendMessage(message)
                    stats.channelMessages += 1
                }
            }
        }

        return stats
    }

    private func makeNode(from object: NSManagedObject) -> NodeInfo? {
        let nodeNum = object.value(forKey: "nodeNum") as? Int64 ?? 0
        guard nodeNum > 0 else { return nil }

        let shortName = object.value(forKey: "shortName") as? String ?? ""
        let longName = object.value(forKey: "longName") as? String ?? ""
        let nodeId = object.value(forKey: "nodeId") as? String ?? String(format: "!%08x", UInt32(nodeNum))

        let node = NodeInfo(id: UInt32(nodeNum), nodeId: nodeId, shortName: shortName, longName: longName)
        node.name = object.value(forKey: "displayName") as? String ?? (longName.isEmpty ? shortName : longName)
        node.distance = object.value(forKey: "distanceText") as? String ?? "-"
        node.snr = object.value(forKey: "snrText") as? String ?? "-"
        node.rssi = object.value(forKey: "rssiText") as? String ?? "-"
        node.battery = object.value(forKey: "batteryText") as? String ?? "-"
        node.lastSeen = object.value(forKey: "lastSeenText") as? String ?? "-"
        node.latitude = object.value(forKey: "latitude") as? Double
        node.longitude = object.value(forKey: "longitude") as? Double
        if let altitude = object.value(forKey: "altitude") as? Int64 {
            node.altitude = Int(altitude)
        }
        node.colorHex = object.value(forKey: "colorHex") as? String ?? ""
        node.note = object.value(forKey: "note") as? String ?? ""
        node.lastHeard = object.value(forKey: "lastHeard") as? Int32 ?? 0
        node.snrFloat = object.value(forKey: "snrFloat") as? Float ?? 0
        node.rssiInt = object.value(forKey: "rssiInt") as? Int32 ?? 0
        node.batteryLevel = UInt32((object.value(forKey: "batteryLevel") as? Int64) ?? 0)
        node.voltage = object.value(forKey: "voltage") as? Float ?? 0
        node.channelUtilization = object.value(forKey: "channelUtilization") as? Float ?? 0
        node.airUtilTx = object.value(forKey: "airUtilTx") as? Float ?? 0
        node.distanceMeters = object.value(forKey: "distanceMeters") as? Double ?? 0
        node.viaMqtt = object.value(forKey: "viaMqtt") as? Bool ?? false
        node.isPinned = object.value(forKey: "isPinned") as? Bool ?? false
        return node
    }

    private func makeChannel(from object: NSManagedObject) -> ChannelInfo? {
        let index = Int((object.value(forKey: "channelIndex") as? Int32) ?? 0)
        let name = object.value(forKey: "name") as? String ?? "Channel \(index)"
        let psk = object.value(forKey: "psk") as? String ?? ""
        let role = object.value(forKey: "role") as? String ?? "SECONDARY"
        let uplinkEnabled = object.value(forKey: "uplinkEnabled") as? Bool ?? false
        let downlinkEnabled = object.value(forKey: "downlinkEnabled") as? Bool ?? false

        return ChannelInfo(
            id: index,
            name: name,
            psk: psk,
            role: role,
            uplinkEnabled: uplinkEnabled,
            downlinkEnabled: downlinkEnabled
        )
    }

    private func makeMessage(from object: NSManagedObject) -> MessageItem? {
        let fromId = UInt32((object.value(forKey: "fromId") as? Int64) ?? 0)
        let toId = UInt32((object.value(forKey: "toId") as? Int64) ?? 0)
        let channelIndex = Int((object.value(forKey: "channelIndex") as? Int32) ?? 0)

        return MessageItem(
            packetId: UInt32((object.value(forKey: "packetId") as? Int64) ?? 0),
            time: object.value(forKey: "timeText") as? String ?? "",
            from: object.value(forKey: "fromName") as? String ?? "",
            fromId: fromId,
            toId: toId,
            message: object.value(forKey: "messageText") as? String ?? "",
            channelIndex: channelIndex,
            channelName: object.value(forKey: "channelName") as? String ?? "",
            isEncrypted: object.value(forKey: "isEncrypted") as? Bool ?? false,
            isViaMqtt: object.value(forKey: "isViaMqtt") as? Bool ?? false,
            senderShortName: object.value(forKey: "senderShortName") as? String ?? "",
            senderColorHex: object.value(forKey: "senderColorHex") as? String ?? "",
            senderNote: object.value(forKey: "senderNote") as? String ?? "",
            hasAlertBell: object.value(forKey: "hasAlertBell") as? Bool ?? false,
            deliveryState: Self.deliveryState(from: object.value(forKey: "deliveryState") as? String,
                                             error: object.value(forKey: "deliveryError") as? String)
        )
    }

    private static func deliveryState(from value: String?, error: String?) -> MessageDeliveryState {
        switch value {
        case "pending":
            return .pending
        case "acknowledged":
            return .acknowledged
        case "failed":
            return .failed(error ?? "Failed")
        default:
            return .none
        }
    }

    // MARK: - Targeted Node Customization

    /// Updates only the color and note for a specific node, without overwriting
    /// other fields. Creates the entity if it doesn't exist yet.
    func updateNodeCustomization(nodeId: UInt32, colorHex: String, note: String) {
        let context = persistenceController.newBackgroundContext()
        context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHNodeEntity")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "nodeNum == %lld", Int64(nodeId))

            let object = (try? context.fetch(request).first)
                ?? NSEntityDescription.insertNewObject(forEntityName: "MHNodeEntity", into: context)

            // Ensure nodeNum is set for new entities
            if (object.value(forKey: "nodeNum") as? Int64 ?? 0) == 0 {
                object.setValue(Int64(nodeId), forKey: "nodeNum")
                object.setValue(String(format: "!%08x", nodeId), forKey: "nodeId")
            }
            object.setValue(colorHex, forKey: "colorHex")
            object.setValue(note, forKey: "note")

            self.save(context: context, label: "node-customization")
        }
    }

    /// Updates only the pin state for a specific node.
    func updateNodePinState(nodeId: UInt32, isPinned: Bool) {
        let context = persistenceController.newBackgroundContext()
        context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHNodeEntity")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "nodeNum == %lld", Int64(nodeId))

            let object = (try? context.fetch(request).first)
                ?? NSEntityDescription.insertNewObject(forEntityName: "MHNodeEntity", into: context)

            if (object.value(forKey: "nodeNum") as? Int64 ?? 0) == 0 {
                object.setValue(Int64(nodeId), forKey: "nodeNum")
                object.setValue(String(format: "!%08x", nodeId), forKey: "nodeId")
            }
            object.setValue(isPinned, forKey: "isPinned")

            self.save(context: context, label: "node-pin")
        }
    }

    // MARK: - Robust PacketId Deduplication

    /// Checks whether a message with the given packetId already exists.
    func messageExists(packetId: UInt32) -> Bool {
        guard packetId != 0 else { return false }
        let context = persistenceController.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "packetId == %lld", Int64(packetId))
        return (try? context.count(for: request)) ?? 0 > 0
    }
}
