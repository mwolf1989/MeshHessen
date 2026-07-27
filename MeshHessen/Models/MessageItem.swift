import Foundation

/// Identifies the conversation bucket in which a message is stored.
/// Meshtastic packet IDs are not globally unique, so the bucket is part of
/// the durable identity used for deduplication.
enum MessageStorageContext: Hashable, Sendable {
    case channel(Int)
    case directMessage(partnerNodeId: UInt32)

    fileprivate var persistenceComponent: String {
        switch self {
        case .channel(let index):
            return "channel:\(index)"
        case .directMessage(let partnerNodeId):
            return "dm:\(partnerNodeId)"
        }
    }
}

/// Retention choices shared by persistence and settings UI.
enum MessageHistoryRetention: Int, CaseIterable, Identifiable, Sendable {
    case thirtyDays = 30
    case ninetyDays = 90
    case oneYear = 365
    case unlimited = 0

    var id: Int { rawValue }

    func cutoffDate(relativeTo referenceDate: Date = Date()) -> Date? {
        guard rawValue > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -rawValue, to: referenceDate)
    }
}

/// User-selectable scope for deleting a channel or direct-message history.
enum MessageHistoryDeletionScope: Equatable, Sendable {
    case all
    case olderThanThirtyDays
    case olderThanNinetyDays
    case olderThanOneYear

    func cutoffDate(relativeTo referenceDate: Date = Date()) -> Date? {
        let days: Int
        switch self {
        case .all:
            return nil
        case .olderThanThirtyDays:
            days = 30
        case .olderThanNinetyDays:
            days = 90
        case .olderThanOneYear:
            days = 365
        }
        return Calendar.current.date(byAdding: .day, value: -days, to: referenceDate)
    }
}

/// Cursor returned by paged message-history queries.
struct MessagePageCursor: Equatable, Sendable {
    let createdAt: Date
    let persistenceKey: String
}

/// A chronologically ordered page plus a cursor for older history.
struct MessagePage: Sendable {
    let messages: [MessageItem]
    let nextCursor: MessagePageCursor?

    var hasMore: Bool { nextCursor != nil }
}

enum MessageDeliveryState: Equatable, Sendable {
    case none
    case pending
    case acknowledged
    case failed(String)

    /// Merge potentially duplicated or out-of-order routing responses.
    /// A successful acknowledgement is terminal and must never be replaced by
    /// a later timeout/NACK from another transport path.
    func merging(_ incoming: MessageDeliveryState) -> MessageDeliveryState {
        switch (self, incoming) {
        case (.acknowledged, _):
            return self
        case (_, .acknowledged):
            return incoming
        case (.failed, _):
            return self
        case (.pending, .none):
            return self
        default:
            return incoming
        }
    }
}

/// A single message in a channel or DM conversation
struct MessageItem: Identifiable, Sendable {
    static let maximumPayloadBytes = 200
    static let unknownChannelIndex = -1

    /// Stable local identity. Messages without a usable mesh packet ID use
    /// this UUID as their durable storage identity.
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var packetId: UInt32? = nil
    /// Packet ID of the message this text message replies to.
    /// Emoji reactions use the same Meshtastic field but are handled separately.
    var replyToPacketId: UInt32? = nil
    var time: String
    var from: String
    var fromId: UInt32
    var toId: UInt32        // 0xFFFFFFFF = broadcast
    var message: String
    var channelIndex: Int
    var channelName: String
    var isEncrypted: Bool = false
    var isViaMqtt: Bool = false
    var senderShortName: String = ""
    var senderColorHex: String = ""
    var senderNote: String = ""
    var hasAlertBell: Bool = false
    var deliveryState: MessageDeliveryState = .none

    /// RF metadata captured with the packet. `nil` means unavailable (for
    /// example for MQTT traffic or imported legacy history).
    var hopCount: Int? = nil
    var receivedSnr: Float? = nil
    var receivedRssi: Int? = nil

    /// Emoji reactions: emoji string → list of sender node IDs
    var reactionsByEmoji: [String: [UInt32]] = [:]

    /// true if this is a direct message (not broadcast)
    var isDirect: Bool { toId != 0xFFFFFFFF && toId != 0 }

    /// Whether this message belongs to a locally configured channel slot.
    /// Unknown encrypted broadcasts remain visible in the combined feed, but
    /// cannot be used as a destination for replies, reactions or retries.
    var hasKnownChannel: Bool { channelIndex >= 0 }

    var isUnknownChannel: Bool { channelIndex == Self.unknownChannelIndex }

    /// Packet ID that can be referenced by another mesh packet.
    /// Legacy log imports use synthetic IDs for local persistence and have no
    /// recoverable sender node ID, so they must not be used for replies/reactions.
    var routablePacketId: UInt32? {
        guard fromId != 0, let packetId, packetId != 0 else { return nil }
        return packetId
    }

    /// Add a reaction from a sender
    mutating func addReaction(emoji: String, from senderId: UInt32) {
        var senders = reactionsByEmoji[emoji, default: []]
        if !senders.contains(senderId) {
            senders.append(senderId)
            reactionsByEmoji[emoji] = senders
        }
    }

    /// Remove a reaction from a sender
    mutating func removeReaction(emoji: String, from senderId: UInt32) {
        reactionsByEmoji[emoji]?.removeAll { $0 == senderId }
        if reactionsByEmoji[emoji]?.isEmpty == true {
            reactionsByEmoji.removeValue(forKey: emoji)
        }
    }

    /// Whether this message has any reactions
    var hasReactions: Bool { !reactionsByEmoji.isEmpty }

    /// Stable key used by CoreData and in-memory deduplication.
    /// Network messages use sender + packet ID + conversation context;
    /// messages without a valid packet ID fall back to their persisted UUID.
    func persistenceKey(in context: MessageStorageContext) -> String {
        if fromId != 0, let packetId, packetId != 0 {
            var contextComponent = context.persistenceComponent
            if case .channel(Self.unknownChannelIndex) = context,
               let hash = Self.persistedUnknownChannelHash(in: channelName) {
                contextComponent += ":hash:\(hash & 0xFF)"
            }
            return "packet:\(fromId):\(packetId):\(contextComponent)"
        }
        return "local:\(id.uuidString.lowercased())"
    }

    /// Localized display name for a channel hash that cannot be mapped to one
    /// of the configured channel slots.
    static func unknownChannelName(hash: Int) -> String {
        String(localized: "Other Channel (\(hash & 0xFF))")
    }

    /// Moves an encrypted channel-feed message into the explicit unknown
    /// bucket. Callers decide whether the message is a broadcast before using
    /// this helper so encrypted direct messages keep their DM context.
    func normalizingUnknownChannel() -> MessageItem {
        guard isEncrypted else { return self }

        var normalized = self
        let previousIndex = channelIndex
        normalized.channelIndex = Self.unknownChannelIndex

        if previousIndex >= 0 {
            let hash = Self.persistedUnknownChannelHash(in: channelName) ?? previousIndex
            normalized.channelName = Self.unknownChannelName(hash: hash)
        }
        return normalized
    }

    /// UTF-8 byte count used by Meshtastic's text-payload limit.
    static func payloadByteCount(_ text: String) -> Int {
        text.utf8.count
    }

    /// Truncates at a Character boundary so a pasted emoji or composed
    /// grapheme is never split into invalid UTF-8.
    static func truncatingToPayloadLimit(_ text: String) -> String {
        guard payloadByteCount(text) > maximumPayloadBytes else { return text }

        var result = ""
        var byteCount = 0
        for character in text {
            let characterText = String(character)
            let characterBytes = characterText.utf8.count
            guard byteCount + characterBytes <= maximumPayloadBytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }

    private static func persistedUnknownChannelHash(in name: String) -> Int? {
        let prefixes = ["Other Channel (", "Anderer Kanal ("]
        guard let prefix = prefixes.first(where: { name.hasPrefix($0) }),
              name.hasSuffix(")")
        else {
            return nil
        }

        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(before: name.endIndex)
        return Int(name[start..<end])
    }
}
