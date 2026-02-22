import TipKit

// MARK: - Connection Tip

struct ConnectionTip: Tip {
    var id: String { "connection-tip" }

    var title: Text {
        Text("Connect to Your Radio")
    }

    var message: Text? {
        Text("Use Serial/USB, Bluetooth, or TCP/WiFi to connect to a Meshtastic node. Click 'Connect' in the toolbar to get started.")
    }

    var image: Image? {
        Image(systemName: "antenna.radiowaves.left.and.right")
    }
}

// MARK: - Channel Sharing Tip

struct ShareChannelsTip: Tip {
    var id: String { "share-channels-tip" }

    var title: Text {
        Text("Share Channel Settings")
    }

    var message: Text? {
        Text("You can browse and add community channels like 'Mesh Hessen' from the Channels tab. Use the Channel Browser to discover more.")
    }

    var image: Image? {
        Image(systemName: "qrcode")
    }
}

// MARK: - Direct Messages Tip

struct MessagesTip: Tip {
    var id: String { "messages-tip" }

    var title: Text {
        Text("Direct Messages")
    }

    var message: Text? {
        Text("Right-click any node in the sidebar to send a direct message. DMs open in a separate window for easy multitasking.")
    }

    var image: Image? {
        Image(systemName: "bubble.left.and.bubble.right")
    }
}

// MARK: - SOS Alert Tip

struct SOSAlertTip: Tip {
    var id: String { "sos-alert-tip" }

    var title: Text {
        Text("SOS Alert")
    }

    var message: Text? {
        Text("The red SOS button in the chat bar sends an alert bell broadcast to the entire mesh network. Use it for emergencies only.")
    }

    var image: Image? {
        Image(systemName: "sos")
    }
}

// MARK: - Map Tip

struct MapTip: Tip {
    var id: String { "map-tip" }

    var title: Text {
        Text("Node Map")
    }

    var message: Text? {
        Text("Nodes with GPS data appear on the map. You can download tiles for offline use and switch between map styles in Settings.")
    }

    var image: Image? {
        Image(systemName: "map")
    }
}
