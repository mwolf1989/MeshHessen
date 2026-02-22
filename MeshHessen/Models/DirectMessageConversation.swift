import Foundation

/// Represents a DM conversation thread with one remote node
@Observable
final class DirectMessageConversation: Identifiable {
    let id: UInt32          // remote node's numeric ID
    var nodeName: String
    var colorHex: String
    var messages: [MessageItem] = []
    var hasUnread: Bool = false

    init(nodeId: UInt32, nodeName: String, colorHex: String = "") {
        self.id = nodeId
        self.nodeName = nodeName
        self.colorHex = colorHex
    }
}
