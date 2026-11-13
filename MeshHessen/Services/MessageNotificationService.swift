import AppKit
import Foundation
import UserNotifications

/// One incoming message waiting to be shown in the bundled notification.
struct MessageNotificationEvent: Equatable, Sendable {
    let sender: String
    /// Channel name, or the "Direct message" label for DMs.
    let conversation: String
    let text: String
    /// Sidebar entry to open when the notification is clicked.
    let target: MessagesSidebarSelection
}

/// Text of the bundled message notification.
struct MessageNotificationSummary: Equatable, Sendable {
    let title: String
    let subtitle: String
    let body: String
}

/// Decides whether a new message deserves a system notification and posts it.
///
/// All messages share one notification identifier, so a new notification
/// replaces the previous one; messages arriving within `batchWindow` are
/// bundled into a single "n new messages" notification.
@MainActor
final class MessageNotificationService {
    static let shared = MessageNotificationService()

    nonisolated static let notificationIdentifier = "mh-messages"
    nonisolated static let categoryIdentifier = "INCOMING_MESSAGE"
    /// `userInfo` key carrying `MessagesSidebarSelection.storageValue`.
    nonisolated static let targetUserInfoKey = "target"
    /// Messages older than this are backlog, never notified.
    nonisolated static let maximumMessageAge: TimeInterval = 180
    nonisolated static let batchWindow: Duration = .milliseconds(1500)

    private var pendingEvents: [MessageNotificationEvent] = []
    private var flushTask: Task<Void, Never>?

    // MARK: - Decision (pure)

    /// A message is live when it is at most `maximumMessageAge` old and did not
    /// arrive while the handshake replays the device's queue.
    nonisolated static func isLive(messageDate: Date, now: Date, isInitializing: Bool) -> Bool {
        guard !isInitializing else { return false }
        return now.timeIntervalSince(messageDate) <= maximumMessageAge
    }

    nonisolated static func shouldNotify(
        isOwn: Bool,
        isEncryptedPlaceholder: Bool,
        text: String,
        messageDate: Date,
        now: Date,
        appIsActive: Bool,
        enabled: Bool,
        isInitializing: Bool
    ) -> Bool {
        guard enabled, !isOwn, !isEncryptedPlaceholder, !appIsActive else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return isLive(messageDate: messageDate, now: now, isInitializing: isInitializing)
    }

    /// The time a packet was received by the radio, or `now` when the radio
    /// had no valid clock (`rx_time` 0 or before 2020).
    nonisolated static func messageDate(rxTime: UInt32, now: Date) -> Date {
        let earliestPlausible: UInt32 = 1_577_836_800 // 2020-01-01
        guard rxTime >= earliestPlausible else { return now }
        return Date(timeIntervalSince1970: TimeInterval(rxTime))
    }

    /// Title/subtitle/body for a batch: one message → "Sender · Channel" with the
    /// text; several → "n new messages" with the latest sender as subtitle.
    nonisolated static func summary(for events: [MessageNotificationEvent]) -> MessageNotificationSummary? {
        guard let last = events.last else { return nil }
        let origin = "\(last.sender) · \(last.conversation)"
        if events.count == 1 {
            return MessageNotificationSummary(title: origin, subtitle: "", body: last.text)
        }
        return MessageNotificationSummary(
            title: String(localized: "\(events.count) new messages"),
            subtitle: origin,
            body: last.text
        )
    }

    // MARK: - Posting

    /// Records an incoming message; posts (bundled) when `shouldNotify` allows it.
    func handleIncoming(
        _ message: MessageItem,
        conversation: String,
        target: MessagesSidebarSelection,
        messageDate: Date,
        isOwn: Bool,
        isInitializing: Bool
    ) {
        guard Self.shouldNotify(
            isOwn: isOwn,
            isEncryptedPlaceholder: message.isEncrypted,
            text: message.message,
            messageDate: messageDate,
            now: Date(),
            appIsActive: NSApp?.isActive ?? false,
            enabled: SettingsService.shared.messageNotificationsEnabled,
            isInitializing: isInitializing
        ) else { return }

        pendingEvents.append(MessageNotificationEvent(
            sender: message.from.isEmpty ? String(format: "!%08x", message.fromId) : message.from,
            conversation: conversation,
            text: message.message,
            target: target
        ))
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.batchWindow)
            self?.flush()
        }
    }

    private func flush() {
        flushTask = nil
        let events = pendingEvents
        pendingEvents.removeAll()
        guard let summary = Self.summary(for: events), let target = events.last?.target else { return }
        Task { await Self.post(summary, target: target) }
    }

    private nonisolated static func post(_ summary: MessageNotificationSummary, target: MessagesSidebarSelection) async {
        // UNUserNotificationCenter traps outside an app bundle (e.g. `swift test`).
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        guard await isAuthorized(center) else {
            AppLogger.shared.log("[Notifications] Message notification not authorized", debug: true)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = summary.title
        content.subtitle = summary.subtitle
        content.body = summary.body
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = notificationIdentifier
        content.userInfo = [targetUserInfoKey: target.storageValue]

        do {
            try await center.add(UNNotificationRequest(
                identifier: notificationIdentifier,
                content: content,
                trigger: nil
            ))
        } catch {
            AppLogger.shared.log(
                "[Notifications] Message notification failed: \(error.localizedDescription)",
                debug: true
            )
        }
    }

    private nonisolated static func isAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                AppLogger.shared.log(
                    "[Notifications] Authorization failed: \(error.localizedDescription)",
                    debug: true
                )
                return false
            }
        default:
            return false
        }
    }
}

extension Notification.Name {
    /// Posted when the user clicks a message notification; `object` is the
    /// target's `MessagesSidebarSelection.storageValue` (or nil).
    static let openMessageNotificationTarget = Notification.Name("MeshHessen.openMessageNotificationTarget")
}
