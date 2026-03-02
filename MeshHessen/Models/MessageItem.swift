import Foundation

enum MessageDeliveryState: Equatable {
    case none
    case pending
    case acknowledged
    case failed(String)
}

/// A single message in a channel or DM conversation
struct MessageItem: Identifiable {
    let id: UUID = UUID()
    var packetId: UInt32? = nil
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

    /// Emoji reactions: emoji string → list of sender node IDs
    var reactionsByEmoji: [String: [UInt32]] = [:]

    /// true if this is a direct message (not broadcast)
    var isDirect: Bool { toId != 0xFFFFFFFF && toId != 0 }

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
}
