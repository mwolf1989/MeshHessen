import SwiftUI
import AppKit
import UserNotifications
import CoreData
import TipKit

@main
struct MeshHessenApp: App {
    private let persistenceController: PersistenceController
    @State private var coordinator: AppCoordinator
    @State private var settings = SettingsService.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        let persistenceController = PersistenceController.shared
        self.persistenceController = persistenceController
        let coord = AppCoordinator(persistenceController: persistenceController)
        _coordinator = State(initialValue: coord)

        // Bridge coordinator for AppIntents (Siri Shortcuts)
        AppIntentCoordinatorProvider.shared.coordinator = coord

        // Configure TipKit
        try? Tips.configure([
            .displayFrequency(.weekly),
            .datastoreLocation(.applicationDefault)
        ])

        AppLogger.shared.log("[App] MeshHessen starting up...", debug: true)
    }

    /// Compute a safe default window height that never exceeds the primary screen.
    private var safeDefaultHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return min(720, screenHeight - 40)
    }

    var body: some Scene {
        // MARK: - Main Window
        WindowGroup {
            MainView()
                .frame(minWidth: 800, minHeight: 500)
                .font(settings.scaledBodyFont)
                .environment(\.appState, coordinator.appState)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(\.persistenceController, persistenceController)
                .environment(coordinator)
                .environment(\.dynamicTypeSize, settings.dynamicTypeSize)
                .onReceive(NotificationCenter.default.publisher(for: .incomingDirectMessage)) { note in
                    handleIncomingDM(note)
                }
                .onOpenURL { url in
                    coordinator.router.route(url: url)
                }
                .background(WindowConstrainer())
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: safeDefaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .textFormatting) {
                Button("Schrift vergrößern") {
                    SettingsService.shared.fontSizeStep += 1
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Schrift verkleinern") {
                    SettingsService.shared.fontSizeStep -= 1
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Standardgröße") {
                    SettingsService.shared.fontSizeStep = 0
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        // MARK: - Direct Messages Window
        Window("Direct Messages", id: "dm") {
            DMWindowView()
                .font(settings.scaledBodyFont)
                .environment(\.appState, coordinator.appState)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(\.persistenceController, persistenceController)
                .environment(coordinator)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 750, height: 520)

        // MARK: - Settings (⌘,)
        Settings {
            SettingsView()
                .environment(\.appState, coordinator.appState)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(\.persistenceController, persistenceController)
        }
    }

    // MARK: - Incoming DM Handler

    private func handleIncomingDM(_ notification: Notification) {
        guard let partnerId = notification.userInfo?["partnerId"] as? UInt32 else { return }
        let msg = notification.userInfo?["message"] as? MessageItem
        let senderName = msg?.from ?? "Node \(partnerId)"

        AppLogger.shared.log("[App] Incoming DM from \(senderName) (\(partnerId))", debug: true)

        // Set target node so DMWindowView auto-selects the conversation
        coordinator.appState.dmTargetNodeId = partnerId

        // Open / bring DM window to front
        openWindow(id: "dm")

        // Play notification sound
        NSSound(named: "Blow")?.play()

        // Bounce dock icon to attract attention
        NSApp.requestUserAttention(.criticalRequest)

        // Post system notification for background awareness
        postSystemNotification(for: msg, partnerId: partnerId)
    }

    // MARK: - System Notification

    private func postSystemNotification(for message: MessageItem?, partnerId: UInt32) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                AppLogger.shared.log("[App] Notification authorization error: \(error.localizedDescription)", debug: true)
            }
            guard granted else {
                AppLogger.shared.log("[App] Notification authorization denied", debug: true)
                return
            }

            let content = UNMutableNotificationContent()
            let senderName = message?.from ?? "Node \(partnerId)"
            content.title = String(localized: "DM from \(senderName)")
            content.body = message?.message ?? String(localized: "New direct message")
            content.sound = .default
            content.categoryIdentifier = "INCOMING_DM"

            let request = UNNotificationRequest(
                identifier: "dm-\(partnerId)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil  // deliver immediately
            )
            center.add(request) { error in
                if let error {
                    AppLogger.shared.log("[App] Failed to post notification: \(error.localizedDescription)", debug: true)
                }
            }
        }
    }
}

// MARK: - Window Constrainer

/// Constrains the window frame to not exceed the screen's visible area on multi-monitor setups.
private struct WindowConstrainer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            guard let screen = window.screen ?? NSScreen.main else { return }
            let visibleFrame = screen.visibleFrame
            var frame = window.frame

            // If the window is taller than the screen, shrink it to fit
            if frame.height > visibleFrame.height {
                frame.size.height = visibleFrame.height
                frame.origin.y = visibleFrame.origin.y
            }

            // Ensure window stays within the visible screen bounds
            if frame.origin.y < visibleFrame.origin.y {
                frame.origin.y = visibleFrame.origin.y
            }
            let maxY = visibleFrame.origin.y + visibleFrame.height
            if frame.origin.y + frame.height > maxY {
                frame.origin.y = maxY - frame.height
            }

            window.setFrame(frame, display: true, animate: false)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window,
              let screen = window.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        var frame = window.frame

        if frame.height > visibleFrame.height {
            frame.size.height = visibleFrame.height
            frame.origin.y = visibleFrame.origin.y
        }
        if frame.origin.y < visibleFrame.origin.y {
            frame.origin.y = visibleFrame.origin.y
        }
        let maxY = visibleFrame.origin.y + visibleFrame.height
        if frame.origin.y + frame.height > maxY {
            frame.origin.y = maxY - frame.height
        }

        if frame != window.frame {
            window.setFrame(frame, display: true, animate: false)
        }
    }
}
