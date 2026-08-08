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
    private let isMessageHistoryEnabled: () -> Bool
    private let nodeDatabaseMutationLock = NSLock()
    private var nodeDatabaseGeneration: UInt64 = 0

    /// Maximum number of messages to keep per channel / conversation.
    /// Older messages are trimmed during retention passes.
    private let maxMessagesPerBucket = 5_000

    /// Nodes not heard from in this many days are considered stale.
    private let staleNodeDays = 90

    /// Initial hydration mirrors the Windows client: recent history is shown
    /// immediately and older messages are available through cursor paging.
    private let initialMessageHistoryInterval: TimeInterval = 24 * 60 * 60

    init(
        persistenceController: PersistenceController,
        isMessageHistoryEnabled: @escaping () -> Bool = { true }
    ) {
        self.persistenceController = persistenceController
        self.isMessageHistoryEnabled = isMessageHistoryEnabled
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

    /// Applies the user-selected age retention to all persisted messages.
    /// `unlimited` deliberately performs no write.
    @discardableResult
    func enforceMessageRetention(
        _ retention: MessageHistoryRetention,
        relativeTo referenceDate: Date = Date()
    ) -> Int {
        guard let cutoff = retention.cutoffDate(relativeTo: referenceDate) else { return 0 }

        let context = persistenceController.newBackgroundContext()
        var deleted = 0
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            request.predicate = NSPredicate(format: "createdAt < %@", cutoff as NSDate)
            guard let messages = try? context.fetch(request) else { return }
            messages.forEach(context.delete)
            deleted = messages.count
            self.removeEmptyConversations(in: context)
            self.save(context: context, label: "message-retention")
        }

        if deleted > 0 {
            AppLogger.shared.log("[Retention] Removed \(deleted) messages older than \(retention.rawValue) days")
        }
        return deleted
    }

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
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHConversationEntity")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "partnerNodeId == %lld", Int64(partnerNodeId))

            let existingObject = try? context.fetch(request).first
            let object = existingObject
                ?? NSEntityDescription.insertNewObject(forEntityName: "MHConversationEntity", into: context)
            if (object.value(forKey: "partnerNodeId") as? Int64 ?? 0) == 0 {
                object.setValue(Int64(partnerNodeId), forKey: "partnerNodeId")
                object.setValue("Node \(partnerNodeId)", forKey: "nodeName")
                object.setValue(Date(), forKey: "updatedAt")
            }
            let current = object.value(forKey: "hasUnread") as? Bool ?? false
            if current != hasUnread {
                object.setValue(hasUnread, forKey: "hasUnread")
            }
            self.save(context: context, label: "unread")
        }
    }

    // MARK: - Batch Operations

    /// Deletes all messages for a specific channel.
    @discardableResult
    func deleteChannelMessages(
        channelIndex: Int,
        scope: MessageHistoryDeletionScope = .all,
        relativeTo referenceDate: Date = Date()
    ) -> Int {
        let context = persistenceController.newBackgroundContext()
        var deleted = 0
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            var predicates = [
                NSPredicate(format: "isDirect == NO"),
                NSPredicate(format: "channelIndex == %d", Int32(channelIndex))
            ]
            if let cutoff = scope.cutoffDate(relativeTo: referenceDate) {
                predicates.append(NSPredicate(format: "createdAt < %@", cutoff as NSDate))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            if let messages = try? context.fetch(request) {
                for obj in messages { context.delete(obj) }
                deleted = messages.count
                self.save(context: context, label: "delete-channel-msgs")
                AppLogger.shared.log("[Persistence] Deleted \(messages.count) messages for channel \(channelIndex)", debug: true)
            }
        }
        return deleted
    }

    /// Deletes all DM messages for a specific conversation partner.
    @discardableResult
    func deleteConversationMessages(
        partnerNodeId: UInt32,
        scope: MessageHistoryDeletionScope = .all,
        relativeTo referenceDate: Date = Date()
    ) -> Int {
        let context = persistenceController.newBackgroundContext()
        var deleted = 0
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            var predicates = [
                NSPredicate(format: "isDirect == YES"),
                NSPredicate(format: "partnerNodeId == %lld", Int64(partnerNodeId))
            ]
            if let cutoff = scope.cutoffDate(relativeTo: referenceDate) {
                predicates.append(NSPredicate(format: "createdAt < %@", cutoff as NSDate))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            if let messages = try? context.fetch(request) {
                for obj in messages { context.delete(obj) }
                deleted = messages.count
            }

            if scope == .all {
                let convRequest = NSFetchRequest<NSManagedObject>(entityName: "MHConversationEntity")
                convRequest.fetchLimit = 1
                convRequest.predicate = NSPredicate(format: "partnerNodeId == %lld", Int64(partnerNodeId))
                if let conv = try? context.fetch(convRequest).first {
                    context.delete(conv)
                }
            }
            self.save(context: context, label: "delete-conv-msgs")
        }
        return deleted
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

    /// Hides every persisted node from NodeDB hydration without deleting local
    /// customizations. Nodes received from the radio become visible again when
    /// `upsertNode(_:)` stores fresh NodeDB data for them.
    @discardableResult
    func resetNodeDatabaseMirror() -> Int {
        let context = persistenceController.newBackgroundContext()
        var resetCount = 0

        nodeDatabaseMutationLock.lock()
        nodeDatabaseGeneration &+= 1
        defer { nodeDatabaseMutationLock.unlock() }

        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHNodeEntity")
            guard let nodes = try? context.fetch(request) else { return }

            for node in nodes where node.value(forKey: "isInNodeDatabase") as? Bool != false {
                node.setValue(false, forKey: "isInNodeDatabase")
                resetCount += 1
            }
            self.save(context: context, label: "reset-node-database-mirror")
        }

        persistenceController.container.viewContext.performAndWait {
            persistenceController.container.viewContext.refreshAllObjects()
        }
        return resetCount
    }

    // MARK: - Paged Message Fetch

    /// Cursor-based page of channel history. Results are returned oldest to
    /// newest so they can be prepended directly to the visible conversation.
    func fetchChannelMessagePage(
        channelIndex: Int,
        limit: Int = 50,
        before cursor: MessagePageCursor? = nil
    ) -> MessagePage {
        fetchMessagePage(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "isDirect == NO"),
                NSPredicate(format: "channelIndex == %d", Int32(channelIndex)),
            ]),
            limit: limit,
            before: cursor
        )
    }

    /// Cursor-based page of direct-message history.
    func fetchDirectMessagePage(
        partnerNodeId: UInt32,
        limit: Int = 50,
        before cursor: MessagePageCursor? = nil
    ) -> MessagePage {
        fetchMessagePage(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "isDirect == YES"),
                NSPredicate(format: "partnerNodeId == %lld", Int64(partnerNodeId)),
            ]),
            limit: limit,
            before: cursor
        )
    }

    /// Fetches channel messages with paging support.
    func fetchChannelMessages(channelIndex: Int, limit: Int = 200, offset: Int = 0) -> [MessageItem] {
        preparePersistedMessagesForRead()
        let context = persistenceController.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "isDirect == NO"),
            NSPredicate(format: "channelIndex == %d", Int32(channelIndex))
        ])
        request.sortDescriptors = [
            NSSortDescriptor(key: "createdAt", ascending: false),
            NSSortDescriptor(key: "persistenceKey", ascending: false),
        ]
        request.fetchLimit = limit
        request.fetchOffset = offset

        guard let results = try? context.fetch(request) else { return [] }
        return results.reversed().compactMap(makeMessage(from:))
    }

    /// Fetches DM messages for a conversation with paging support.
    func fetchDirectMessages(partnerNodeId: UInt32, limit: Int = 200, offset: Int = 0) -> [MessageItem] {
        preparePersistedMessagesForRead()
        let context = persistenceController.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "isDirect == YES"),
            NSPredicate(format: "partnerNodeId == %lld", Int64(partnerNodeId))
        ])
        request.sortDescriptors = [
            NSSortDescriptor(key: "createdAt", ascending: false),
            NSSortDescriptor(key: "persistenceKey", ascending: false),
        ]
        request.fetchLimit = limit
        request.fetchOffset = offset

        guard let results = try? context.fetch(request) else { return [] }
        return results.reversed().compactMap(makeMessage(from:))
    }

    func upsertNode(_ node: NodeInfo) {
        let context = persistenceController.newBackgroundContext()
        nodeDatabaseMutationLock.lock()
        let generation = nodeDatabaseGeneration
        nodeDatabaseMutationLock.unlock()

        context.perform {
            self.nodeDatabaseMutationLock.lock()
            defer { self.nodeDatabaseMutationLock.unlock() }
            guard generation == self.nodeDatabaseGeneration else { return }

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
            object.setValue(true, forKey: "isInNodeDatabase")
            if node.lastTracerouteHopCount > 0 {
                object.setValue(Int32(node.lastTracerouteHopCount), forKey: "lastTracerouteHopCount")
            }
            // Preserve existing pin state — only set to true, never overwrite with false
            if node.isPinned {
                object.setValue(true, forKey: "isPinned")
            }

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

    /// Removes any persisted channels whose index is NOT in the given set.
    func removeChannelsNotIn(indices: Set<Int>) {
        let context = persistenceController.newBackgroundContext()
        context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHChannelEntity")
            guard let all = try? context.fetch(request) else { return }
            for obj in all {
                let idx = Int(obj.value(forKey: "channelIndex") as? Int32 ?? -1)
                if !indices.contains(idx) {
                    context.delete(obj)
                }
            }
            self.save(context: context, label: "removeStaleChannels")
        }
    }

    func upsertMessage(
        _ incomingMessage: MessageItem,
        isDirect: Bool,
        partnerNodeId: UInt32?,
        partnerName: String? = nil
    ) {
        guard isMessageHistoryEnabled() else { return }
        let message = isDirect
            ? incomingMessage
            : incomingMessage.normalizingUnknownChannel()
        let storageContext = messageStorageContext(
            isDirect: isDirect,
            partnerNodeId: partnerNodeId,
            channelIndex: message.channelIndex
        )
        let persistenceKey = message.persistenceKey(in: storageContext)

        let context = persistenceController.newBackgroundContext()
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "persistenceKey == %@", persistenceKey)

            var object = try? context.fetch(request).first
            if object == nil,
               storageContext != .channel(MessageItem.unknownChannelIndex),
               let packetId = message.packetId,
               packetId != 0 {
                object = self.findLegacyMessage(
                    in: context,
                    packetId: packetId,
                    senderId: message.fromId,
                    storageContext: storageContext
                )
            }
            let isNewMessage = object == nil
            let messageObject = object
                ?? NSEntityDescription.insertNewObject(forEntityName: "MHMessageEntity", into: context)

            if messageObject.value(forKey: "messageUUID") == nil {
                messageObject.setValue(message.id, forKey: "messageUUID")
            }
            messageObject.setValue(persistenceKey, forKey: "persistenceKey")
            messageObject.setValue(message.packetId.map(Int64.init) ?? 0, forKey: "packetId")
            // A later duplicate/echo without reply metadata must not erase the
            // target captured from the original packet or optimistic send.
            if let replyToPacketId = message.replyToPacketId {
                messageObject.setValue(Int64(replyToPacketId), forKey: "replyToPacketId")
            }
            if messageObject.value(forKey: "createdAt") == nil {
                messageObject.setValue(message.createdAt, forKey: "createdAt")
            }
            messageObject.setValue(message.time, forKey: "timeText")
            messageObject.setValue(message.from, forKey: "fromName")
            messageObject.setValue(Int64(message.fromId), forKey: "fromId")
            messageObject.setValue(Int64(message.toId), forKey: "toId")
            messageObject.setValue(message.message, forKey: "messageText")
            messageObject.setValue(Int32(message.channelIndex), forKey: "channelIndex")
            messageObject.setValue(message.channelName, forKey: "channelName")
            messageObject.setValue(message.isEncrypted, forKey: "isEncrypted")
            messageObject.setValue(message.isViaMqtt, forKey: "isViaMqtt")
            messageObject.setValue(message.senderShortName, forKey: "senderShortName")
            messageObject.setValue(message.senderColorHex, forKey: "senderColorHex")
            messageObject.setValue(message.senderNote, forKey: "senderNote")
            messageObject.setValue(message.hasAlertBell, forKey: "hasAlertBell")
            if message.deliveryState != .none || messageObject.value(forKey: "deliveryState") == nil {
                messageObject.setValue(Self.deliveryStateString(from: message.deliveryState), forKey: "deliveryState")
                messageObject.setValue(Self.deliveryErrorString(from: message.deliveryState), forKey: "deliveryError")
            }
            messageObject.setValue(isDirect, forKey: "isDirect")
            messageObject.setValue(partnerNodeId.map { Int64($0) } ?? 0, forKey: "partnerNodeId")
            if let hopCount = message.hopCount {
                messageObject.setValue(Int32(clamping: hopCount), forKey: "hopCount")
            }
            if let receivedSnr = message.receivedSnr {
                messageObject.setValue(receivedSnr, forKey: "receivedSnr")
            }
            if let receivedRssi = message.receivedRssi {
                messageObject.setValue(Int32(clamping: receivedRssi), forKey: "receivedRssi")
            }

            let persistedReactions = Self.decodeReactions(messageObject.value(forKey: "reactionsData") as? Data)
            let mergedReactions = Self.mergingReactions(persistedReactions, with: message.reactionsByEmoji)
            messageObject.setValue(Self.encodeReactions(mergedReactions), forKey: "reactionsData")

            if isDirect, let partnerNodeId {
                let resolvedPartnerName = partnerName ?? message.from
                self.upsertConversation(
                    in: context,
                    partnerNodeId: partnerNodeId,
                    nodeName: resolvedPartnerName,
                    colorHex: message.senderColorHex,
                    markUnread: isNewMessage && message.fromId == partnerNodeId
                )
            }

            self.save(context: context, label: "message")
        }
    }

    /// Replaces reaction state after an in-memory reaction mutation. Unlike
    /// `upsertMessage`, this exact replacement also supports reaction removal.
    func replaceReactions(for message: MessageItem, context storageContext: MessageStorageContext) {
        guard isMessageHistoryEnabled() else { return }
        let persistenceKey = message.persistenceKey(in: storageContext)
        let context = persistenceController.newBackgroundContext()
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "persistenceKey == %@", persistenceKey)
            guard let object = try? context.fetch(request).first else { return }
            object.setValue(Self.encodeReactions(message.reactionsByEmoji), forKey: "reactionsData")
            self.save(context: context, label: "message-reactions")
        }
    }

    func updateDeliveryState(
        requestId: UInt32,
        state: MessageDeliveryState,
        storageContext: MessageStorageContext? = nil
    ) {
        guard requestId != 0, isMessageHistoryEnabled() else { return }

        let context = persistenceController.newBackgroundContext()
        context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            request.fetchLimit = 1
            switch storageContext {
            case .channel(let channelIndex):
                request.predicate = NSPredicate(
                    format: "packetId == %lld AND isDirect == NO AND channelIndex == %d",
                    Int64(requestId),
                    channelIndex
                )
            case .directMessage(let partnerNodeId):
                request.predicate = NSPredicate(
                    format: "packetId == %lld AND isDirect == YES AND partnerNodeId == %lld",
                    Int64(requestId),
                    Int64(partnerNodeId)
                )
            case nil:
                request.predicate = NSPredicate(format: "packetId == %lld", Int64(requestId))
            }

            guard let object = try? context.fetch(request).first else { return }

            let currentState = Self.deliveryState(
                from: object.value(forKey: "deliveryState") as? String,
                error: object.value(forKey: "deliveryError") as? String
            )
            let mergedState = currentState.merging(state)
            object.setValue(Self.deliveryStateString(from: mergedState), forKey: "deliveryState")
            object.setValue(Self.deliveryErrorString(from: mergedState), forKey: "deliveryError")

            self.save(context: context, label: "delivery")
        }
    }

    private func upsertConversation(
        in context: NSManagedObjectContext,
        partnerNodeId: UInt32,
        nodeName: String,
        colorHex: String,
        markUnread: Bool
    ) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHConversationEntity")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "partnerNodeId == %lld", Int64(partnerNodeId))

        let object = (try? context.fetch(request).first) ?? NSEntityDescription.insertNewObject(forEntityName: "MHConversationEntity", into: context)

        object.setValue(Int64(partnerNodeId), forKey: "partnerNodeId")
        object.setValue(nodeName, forKey: "nodeName")
        object.setValue(colorHex, forKey: "colorHex")
        object.setValue(Date(), forKey: "updatedAt")
        if markUnread {
            object.setValue(true, forKey: "hasUnread")
        }
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
        preparePersistedMessagesForRead()
        let context = persistenceController.container.viewContext
        var stats = CoreDataHydrationStats()

        // 1. Hydrate nodes. Live node packets may arrive before hydration finishes,
        // so merge local-only fields without replacing fresher network data.
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHNodeEntity")
        request.sortDescriptors = [NSSortDescriptor(key: "lastHeard", ascending: false)]
        if let nodes = try? context.fetch(request) {
            for object in nodes {
                guard let node = makeNode(from: object) else { continue }
                if let liveNode = appState.node(forId: node.id) {
                    liveNode.colorHex = node.colorHex
                    liveNode.note = node.note
                    liveNode.isPinned = node.isPinned
                    liveNode.lastTracerouteHopCount = node.lastTracerouteHopCount
                } else if object.value(forKey: "isInNodeDatabase") as? Bool != false {
                    appState.upsertNode(node)
                } else {
                    continue
                }
                stats.nodes += 1
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
        let recentCutoff = Date().addingTimeInterval(-initialMessageHistoryInterval)
        messageRequest.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "createdAt >= %@", recentCutoff as NSDate),
            NSPredicate(format: "createdAt == nil"),
        ])
        messageRequest.fetchLimit = 10_000 // Safety cap for large databases
        if let messages = try? context.fetch(messageRequest) {
            var seenPersistenceKeys = Set<String>()
            for object in messages {
                guard let message = makeMessage(from: object) else { continue }

                let isDirect = object.value(forKey: "isDirect") as? Bool ?? false
                let storedPartnerNodeId = UInt32(clamping: (object.value(forKey: "partnerNodeId") as? Int64) ?? 0)
                let partnerNodeId = storedPartnerNodeId == 0
                    ? (message.fromId == appState.myNodeInfo?.nodeId ? message.toId : message.fromId)
                    : storedPartnerNodeId
                let storageContext = messageStorageContext(
                    isDirect: isDirect,
                    partnerNodeId: partnerNodeId,
                    channelIndex: message.channelIndex
                )
                guard seenPersistenceKeys.insert(message.persistenceKey(in: storageContext)).inserted else {
                    continue
                }

                if isDirect {
                    appState.addOrUpdateDM(
                        message,
                        myNodeId: appState.myNodeInfo?.nodeId ?? 0,
                        partnerNodeId: partnerNodeId,
                        markUnread: false
                    )
                    stats.directMessages += 1
                } else {
                    appState.appendMessage(message, markUnread: false)
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
        let persistedName = object.value(forKey: "displayName") as? String ?? ""
        node.name = persistedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? NodeInfo.resolvedName(id: node.id, shortName: shortName, longName: longName)
            : persistedName
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
        node.lastTracerouteHopCount = Int(object.value(forKey: "lastTracerouteHopCount") as? Int32 ?? 0)
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
        let rawPacketId = object.value(forKey: "packetId") as? Int64 ?? 0
        let packetId = UInt32(exactly: rawPacketId).flatMap { $0 == 0 ? nil : $0 }
        let rawReplyToPacketId = object.value(forKey: "replyToPacketId") as? Int64 ?? 0
        let replyToPacketId = UInt32(exactly: rawReplyToPacketId).flatMap { $0 == 0 ? nil : $0 }
        let messageId = object.value(forKey: "messageUUID") as? UUID ?? UUID()
        let createdAt = object.value(forKey: "createdAt") as? Date ?? .distantPast
        let hopCount = (object.value(forKey: "hopCount") as? NSNumber).map(\.intValue)
        let receivedSnr = (object.value(forKey: "receivedSnr") as? NSNumber).map(\.floatValue)
        let receivedRssi = (object.value(forKey: "receivedRssi") as? NSNumber).map(\.intValue)

        let message = MessageItem(
            id: messageId,
            createdAt: createdAt,
            packetId: packetId,
            replyToPacketId: replyToPacketId,
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
                                             error: object.value(forKey: "deliveryError") as? String),
            hopCount: hopCount,
            receivedSnr: receivedSnr,
            receivedRssi: receivedRssi,
            reactionsByEmoji: Self.decodeReactions(object.value(forKey: "reactionsData") as? Data)
        )
        let isDirect = object.value(forKey: "isDirect") as? Bool ?? false
        return isDirect ? message : message.normalizingUnknownChannel()
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

    // MARK: - Message Identity / Paging Helpers

    private func messageStorageContext(
        isDirect: Bool,
        partnerNodeId: UInt32?,
        channelIndex: Int
    ) -> MessageStorageContext {
        if isDirect {
            return .directMessage(partnerNodeId: partnerNodeId ?? 0)
        }
        return .channel(channelIndex)
    }

    private func findLegacyMessage(
        in context: NSManagedObjectContext,
        packetId: UInt32,
        senderId: UInt32,
        storageContext: MessageStorageContext
    ) -> NSManagedObject? {
        var predicates = [
            NSPredicate(format: "packetId == %lld", Int64(packetId)),
            NSPredicate(format: "fromId == %lld", Int64(senderId)),
        ]
        switch storageContext {
        case .channel(let channelIndex):
            predicates.append(NSPredicate(format: "isDirect == NO"))
            predicates.append(NSPredicate(format: "channelIndex == %d", Int32(channelIndex)))
        case .directMessage(let partnerNodeId):
            predicates.append(NSPredicate(format: "isDirect == YES"))
            predicates.append(NSPredicate(format: "partnerNodeId == %lld", Int64(partnerNodeId)))
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
        request.fetchLimit = 1
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        return try? context.fetch(request).first
    }

    private func preparePersistedMessagesForRead() {
        backfillMessageMetadataIfNeeded()
        normalizeEncryptedBroadcastChannelsIfNeeded()
    }

    /// Backfills optional v3 attributes after an inferred lightweight
    /// migration. This is idempotent and intentionally does not rewrite
    /// message content or timestamps that already exist.
    private func backfillMessageMetadataIfNeeded() {
        let context = persistenceController.newBackgroundContext()
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "messageUUID == nil"),
                NSPredicate(format: "persistenceKey == nil"),
                NSPredicate(format: "createdAt == nil"),
            ])
            guard let objects = try? context.fetch(request), !objects.isEmpty else { return }

            for object in objects {
                let messageId = object.value(forKey: "messageUUID") as? UUID ?? UUID()
                object.setValue(messageId, forKey: "messageUUID")
                if object.value(forKey: "createdAt") == nil {
                    object.setValue(Date.distantPast, forKey: "createdAt")
                }

                guard object.value(forKey: "persistenceKey") as? String == nil else { continue }
                let fromId = UInt32(clamping: object.value(forKey: "fromId") as? Int64 ?? 0)
                let rawPacketId = object.value(forKey: "packetId") as? Int64 ?? 0
                let packetId = UInt32(exactly: rawPacketId).flatMap { $0 == 0 ? nil : $0 }
                let isDirect = object.value(forKey: "isDirect") as? Bool ?? false
                let channelIndex = Int(object.value(forKey: "channelIndex") as? Int32 ?? 0)
                let partnerNodeId = UInt32(clamping: object.value(forKey: "partnerNodeId") as? Int64 ?? 0)
                let storageContext = self.messageStorageContext(
                    isDirect: isDirect,
                    partnerNodeId: partnerNodeId,
                    channelIndex: channelIndex
                )
                var message = MessageItem(
                    id: messageId,
                    packetId: packetId,
                    time: "",
                    from: "",
                    fromId: fromId,
                    toId: 0,
                    message: "",
                    channelIndex: channelIndex,
                    channelName: ""
                )
                message.createdAt = object.value(forKey: "createdAt") as? Date ?? .distantPast
                object.setValue(message.persistenceKey(in: storageContext), forKey: "persistenceKey")
            }
            self.save(context: context, label: "message-v3-backfill")
        }
    }

    /// Versions before 1.1.1 could interpret a small channel hash as a local
    /// channel slot, while larger hashes fell back to Primary. Move every
    /// encrypted broadcast into the explicit unknown bucket without requiring
    /// a Core Data schema migration.
    private func normalizeEncryptedBroadcastChannelsIfNeeded() {
        let context = persistenceController.newBackgroundContext()
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "isDirect == NO"),
                NSPredicate(format: "isEncrypted == YES"),
                NSPredicate(
                    format: "channelIndex != %d",
                    Int32(MessageItem.unknownChannelIndex)
                ),
            ])
            guard let objects = try? context.fetch(request), !objects.isEmpty else { return }

            for object in objects {
                guard let message = self.makeMessage(from: object) else { continue }
                let normalized = message.normalizingUnknownChannel()
                object.setValue(Int32(normalized.channelIndex), forKey: "channelIndex")
                object.setValue(normalized.channelName, forKey: "channelName")
                object.setValue(
                    normalized.persistenceKey(in: .channel(MessageItem.unknownChannelIndex)),
                    forKey: "persistenceKey"
                )
            }

            self.save(context: context, label: "encrypted-channel-normalization")
            AppLogger.shared.log(
                "[Migration] Moved \(objects.count) encrypted broadcasts to the unknown channel"
            )
        }
    }

    private func fetchMessagePage(
        predicate basePredicate: NSPredicate,
        limit: Int,
        before cursor: MessagePageCursor?
    ) -> MessagePage {
        guard limit > 0 else { return MessagePage(messages: [], nextCursor: nil) }
        preparePersistedMessagesForRead()

        let context = persistenceController.newBackgroundContext()
        var page = MessagePage(messages: [], nextCursor: nil)
        context.performAndWait {
            var predicates = [basePredicate]
            if let cursor {
                predicates.append(NSPredicate(
                    format: "(createdAt < %@) OR (createdAt == %@ AND persistenceKey < %@)",
                    cursor.createdAt as NSDate,
                    cursor.createdAt as NSDate,
                    cursor.persistenceKey
                ))
            }

            let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [
                NSSortDescriptor(key: "createdAt", ascending: false),
                NSSortDescriptor(key: "persistenceKey", ascending: false),
            ]
            request.fetchLimit = limit + 1

            guard let results = try? context.fetch(request) else { return }
            let hasMore = results.count > limit
            let selected = Array(results.prefix(limit))
            let messages = selected.reversed().compactMap(self.makeMessage(from:))
            let nextCursor: MessagePageCursor?
            if hasMore,
               let oldest = selected.last,
               let createdAt = oldest.value(forKey: "createdAt") as? Date,
               let persistenceKey = oldest.value(forKey: "persistenceKey") as? String {
                nextCursor = MessagePageCursor(createdAt: createdAt, persistenceKey: persistenceKey)
            } else {
                nextCursor = nil
            }
            page = MessagePage(messages: messages, nextCursor: nextCursor)
        }
        return page
    }

    private func removeEmptyConversations(in context: NSManagedObjectContext) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHConversationEntity")
        guard let conversations = try? context.fetch(request) else { return }
        for conversation in conversations {
            let partnerNodeId = conversation.value(forKey: "partnerNodeId") as? Int64 ?? 0
            let countRequest = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
            countRequest.fetchLimit = 1
            countRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "isDirect == YES"),
                NSPredicate(format: "partnerNodeId == %lld", partnerNodeId),
            ])
            if (try? context.count(for: countRequest)) == 0 {
                context.delete(conversation)
            }
        }
    }

    private static func encodeReactions(_ reactions: [String: [UInt32]]) -> Data? {
        try? JSONEncoder().encode(reactions)
    }

    private static func decodeReactions(_ data: Data?) -> [String: [UInt32]] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: [UInt32]].self, from: data)) ?? [:]
    }

    private static func mergingReactions(
        _ existing: [String: [UInt32]],
        with incoming: [String: [UInt32]]
    ) -> [String: [UInt32]] {
        var merged = existing
        for (emoji, senders) in incoming {
            var mergedSenders = merged[emoji, default: []]
            for sender in senders where !mergedSenders.contains(sender) {
                mergedSenders.append(sender)
            }
            merged[emoji] = mergedSenders
        }
        return merged
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

            let existing = try? context.fetch(request).first
            let object = existing
                ?? NSEntityDescription.insertNewObject(forEntityName: "MHNodeEntity", into: context)

            // Ensure nodeNum is set for new entities
            if (object.value(forKey: "nodeNum") as? Int64 ?? 0) == 0 {
                object.setValue(Int64(nodeId), forKey: "nodeNum")
                object.setValue(String(format: "!%08x", nodeId), forKey: "nodeId")
                object.setValue(false, forKey: "isInNodeDatabase")
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

            let existing = try? context.fetch(request).first
            let object = existing
                ?? NSEntityDescription.insertNewObject(forEntityName: "MHNodeEntity", into: context)

            if (object.value(forKey: "nodeNum") as? Int64 ?? 0) == 0 {
                object.setValue(Int64(nodeId), forKey: "nodeNum")
                object.setValue(String(format: "!%08x", nodeId), forKey: "nodeId")
                object.setValue(false, forKey: "isInNodeDatabase")
            }
            object.setValue(isPinned, forKey: "isPinned")

            self.save(context: context, label: "node-pin")
        }
    }

    /// Persists the most recent successful route length without replacing node metadata.
    func updateNodeTracerouteHopCount(nodeId: UInt32, hopCount: Int) {
        let context = persistenceController.newBackgroundContext()
        context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MHNodeEntity")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "nodeNum == %lld", Int64(nodeId))

            let existing = try? context.fetch(request).first
            let object = existing
                ?? NSEntityDescription.insertNewObject(forEntityName: "MHNodeEntity", into: context)

            if (object.value(forKey: "nodeNum") as? Int64 ?? 0) == 0 {
                object.setValue(Int64(nodeId), forKey: "nodeNum")
                object.setValue(String(format: "!%08x", nodeId), forKey: "nodeId")
                object.setValue(false, forKey: "isInNodeDatabase")
            }
            object.setValue(Int32(clamping: hopCount), forKey: "lastTracerouteHopCount")
            self.save(context: context, label: "node-traceroute-hop-count")
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

    /// Context-aware existence check for callers that have the complete mesh
    /// identity. Prefer this overload to the legacy packet-only query.
    func messageExists(
        packetId: UInt32,
        senderId: UInt32,
        context storageContext: MessageStorageContext
    ) -> Bool {
        guard packetId != 0, senderId != 0 else { return false }
        let probe = MessageItem(
            packetId: packetId,
            time: "",
            from: "",
            fromId: senderId,
            toId: 0,
            message: "",
            channelIndex: 0,
            channelName: ""
        )
        let persistenceKey = probe.persistenceKey(in: storageContext)
        let context = persistenceController.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHMessageEntity")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "persistenceKey == %@", persistenceKey)
        return (try? context.count(for: request)) ?? 0 > 0
    }
}
