import CoreData
import Foundation

/// Builds an NSManagedObjectModel programmatically, mirroring MeshHessen.xcdatamodeld.
/// Used by SPM tests where the .xcdatamodeld cannot be compiled to .momd.
enum TestModelFactory {

    static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        model.entities = [
            nodeEntity(),
            channelEntity(),
            messageEntity(),
            conversationEntity(),
        ]
        return model
    }

    // MARK: - Entities

    private static func nodeEntity() -> NSEntityDescription {
        let e = NSEntityDescription()
        e.name = "MHNodeEntity"
        e.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        e.properties = [
            int64("nodeNum", optional: false),
            string("nodeId"),
            string("shortName"),
            string("longName"),
            string("displayName"),
            string("distanceText"),
            string("snrText"),
            string("rssiText"),
            string("batteryText"),
            string("lastSeenText"),
            double("latitude"),
            double("longitude"),
            int64("altitude"),
            string("colorHex"),
            string("note"),
            int32("lastHeard"),
            float("snrFloat"),
            int32("rssiInt"),
            int64("batteryLevel"),
            float("voltage"),
            float("channelUtilization"),
            float("airUtilTx"),
            double("distanceMeters"),
            bool("viaMqtt"),
        ]
        e.uniquenessConstraints = [["nodeNum"]]
        return e
    }

    private static func channelEntity() -> NSEntityDescription {
        let e = NSEntityDescription()
        e.name = "MHChannelEntity"
        e.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        e.properties = [
            int32("channelIndex", optional: false),
            string("name"),
            string("psk"),
            string("role"),
            bool("uplinkEnabled"),
            bool("downlinkEnabled"),
        ]
        e.uniquenessConstraints = [["channelIndex"]]
        return e
    }

    private static func messageEntity() -> NSEntityDescription {
        let e = NSEntityDescription()
        e.name = "MHMessageEntity"
        e.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        e.properties = [
            int64("packetId"),
            date("createdAt"),
            string("timeText"),
            string("fromName"),
            int64("fromId"),
            int64("toId"),
            string("messageText"),
            int32("channelIndex"),
            string("channelName"),
            bool("isEncrypted"),
            bool("isViaMqtt"),
            string("senderShortName"),
            string("senderColorHex"),
            string("senderNote"),
            bool("hasAlertBell"),
            string("deliveryState"),
            string("deliveryError"),
            bool("isDirect"),
            int64("partnerNodeId"),
        ]
        e.uniquenessConstraints = [["packetId"]]
        return e
    }

    private static func conversationEntity() -> NSEntityDescription {
        let e = NSEntityDescription()
        e.name = "MHConversationEntity"
        e.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        e.properties = [
            int64("partnerNodeId", optional: false),
            string("nodeName"),
            string("colorHex"),
            bool("hasUnread"),
            date("updatedAt"),
        ]
        e.uniquenessConstraints = [["partnerNodeId"]]
        return e
    }

    // MARK: - Attribute Helpers

    private static func string(_ name: String, optional: Bool = true) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = .stringAttributeType
        a.isOptional = optional
        return a
    }

    private static func int32(_ name: String, optional: Bool = true) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = .integer32AttributeType
        a.isOptional = optional
        return a
    }

    private static func int64(_ name: String, optional: Bool = true) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = .integer64AttributeType
        a.isOptional = optional
        return a
    }

    private static func double(_ name: String, optional: Bool = true) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = .doubleAttributeType
        a.isOptional = optional
        return a
    }

    private static func float(_ name: String, optional: Bool = true) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = .floatAttributeType
        a.isOptional = optional
        return a
    }

    private static func bool(_ name: String, optional: Bool = true) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = .booleanAttributeType
        a.isOptional = optional
        return a
    }

    private static func date(_ name: String, optional: Bool = true) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = .dateAttributeType
        a.isOptional = optional
        return a
    }
}
