import AppIntents
import Foundation

// MARK: - App Intent Errors

enum MeshIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notConnected
    case message(_ message: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConnected:
            return "Not connected to a Meshtastic node."
        case .message(let msg):
            return LocalizedStringResource(stringLiteral: msg)
        }
    }
}

// MARK: - Message Channel Intent

struct MessageChannelIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Channel Message"
    static var description: IntentDescription = "Send a text message to a Meshtastic channel."
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Message")
    var message: String

    @Parameter(title: "Channel Index", default: 0, inclusiveRange: (0, 7))
    var channelIndex: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let coordinator = AppIntentCoordinatorProvider.shared.coordinator else {
            throw MeshIntentError.notConnected
        }
        guard coordinator.appState.connectionState.isConnected else {
            throw MeshIntentError.notConnected
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MeshIntentError.message("Message cannot be empty.")
        }
        guard trimmed.utf8.count <= 200 else {
            throw MeshIntentError.message("Message exceeds 200 byte limit.")
        }

        await coordinator.sendMessage(trimmed, toChannelIndex: channelIndex)
        return .result(dialog: "Message sent to channel \(channelIndex).")
    }
}

// MARK: - Message Node (DM) Intent

struct MessageNodeIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Direct Message"
    static var description: IntentDescription = "Send a direct message to a Meshtastic node."
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Message")
    var message: String

    @Parameter(title: "Node Number")
    var nodeNumber: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let coordinator = AppIntentCoordinatorProvider.shared.coordinator else {
            throw MeshIntentError.notConnected
        }
        guard coordinator.appState.connectionState.isConnected else {
            throw MeshIntentError.notConnected
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MeshIntentError.message("Message cannot be empty.")
        }

        await coordinator.sendDirectMessage(trimmed, toNodeId: UInt32(nodeNumber))
        return .result(dialog: "Direct message sent to node \(nodeNumber).")
    }
}

// MARK: - Disconnect Intent

struct DisconnectNodeIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect"
    static var description: IntentDescription = "Disconnect from the connected Meshtastic node."
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let coordinator = AppIntentCoordinatorProvider.shared.coordinator else {
            throw MeshIntentError.notConnected
        }
        guard coordinator.appState.connectionState.isConnected else {
            throw MeshIntentError.notConnected
        }

        await coordinator.disconnect()
        return .result(dialog: "Disconnected from Meshtastic node.")
    }
}

// MARK: - Send SOS Intent

struct SendSOSIntent: AppIntent {
    static var title: LocalizedStringResource = "Send SOS Alert"
    static var description: IntentDescription = "Send an SOS alert broadcast on channel 0."
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Custom Text", default: nil)
    var customText: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let coordinator = AppIntentCoordinatorProvider.shared.coordinator else {
            throw MeshIntentError.notConnected
        }
        guard coordinator.appState.connectionState.isConnected else {
            throw MeshIntentError.notConnected
        }

        await coordinator.sendSOSAlert(customText: customText)
        return .result(dialog: "SOS alert sent.")
    }
}

// MARK: - Shortcuts Provider

struct MeshHessenShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: MessageChannelIntent(),
            phrases: [
                "Send a message on \(.applicationName)",
                "Meshtastic channel message with \(.applicationName)"
            ],
            shortTitle: "Channel Message",
            systemImageName: "envelope"
        )
        AppShortcut(
            intent: MessageNodeIntent(),
            phrases: [
                "Send a direct message with \(.applicationName)",
                "DM a node with \(.applicationName)"
            ],
            shortTitle: "Direct Message",
            systemImageName: "bubble.left"
        )
        AppShortcut(
            intent: DisconnectNodeIntent(),
            phrases: [
                "Disconnect \(.applicationName)",
                "Disconnect from \(.applicationName)"
            ],
            shortTitle: "Disconnect",
            systemImageName: "network.slash"
        )
        AppShortcut(
            intent: SendSOSIntent(),
            phrases: [
                "Send SOS with \(.applicationName)",
                "SOS Alert via \(.applicationName)"
            ],
            shortTitle: "SOS Alert",
            systemImageName: "sos"
        )
    }
}

// MARK: - Coordinator Provider for AppIntents

/// Bridging singleton so that AppIntents can access the AppCoordinator.
/// Set from `MeshHessenApp.init()`.
@MainActor
final class AppIntentCoordinatorProvider {
    static let shared = AppIntentCoordinatorProvider()
    weak var coordinator: AppCoordinator?
    private init() {}
}
