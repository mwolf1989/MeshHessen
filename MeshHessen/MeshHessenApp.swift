import AppKit
import CoreData
import SwiftUI
import TipKit
import UserNotifications

@main
struct MeshHessenApp: App {
    private let persistenceController: PersistenceController
    private let notificationDelegate: NotificationPresentationDelegate
    @State private var coordinator: AppCoordinator
    @State private var settings = SettingsService.shared
    @State private var kioskState = KioskState.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        let persistenceController = PersistenceController.shared
        self.persistenceController = persistenceController
        let notificationDelegate = NotificationPresentationDelegate()
        self.notificationDelegate = notificationDelegate
        UNUserNotificationCenter.current().delegate = notificationDelegate
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
                .environment(\.locale, settings.appLocale)
                .preferredColorScheme(settings.preferredColorScheme)
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
                .onChange(of: settings.virtualNodeEnabled) { _, _ in
                    Task { await coordinator.applyAuxiliaryServiceSettings() }
                }
                .onChange(of: settings.virtualNodePort) { _, _ in
                    Task { await coordinator.applyAuxiliaryServiceSettings() }
                }
                .onChange(of: settings.virtualNodeBlockAdmin) { _, _ in
                    Task { await coordinator.applyAuxiliaryServiceSettings() }
                }
                .onChange(of: kioskState.isLocked) { _, _ in
                    Task { await coordinator.applyAuxiliaryServiceSettings() }
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
                .environment(\.locale, settings.appLocale)
                .preferredColorScheme(settings.preferredColorScheme)
                .environment(\.appState, coordinator.appState)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(\.persistenceController, persistenceController)
                .environment(coordinator)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 750, height: 520)

        // MARK: - Telemetry Dashboard
        Window("Telemetry Dashboard", id: "dashboard") {
            TelemetryDashboardView()
            .font(settings.scaledBodyFont)
            .environment(\.locale, settings.appLocale)
            .preferredColorScheme(settings.preferredColorScheme)
            .environment(\.appState, coordinator.appState)
            .environment(coordinator)
            .environment(\.dynamicTypeSize, settings.dynamicTypeSize)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)

        // MARK: - Telemetry Chart Windows
        WindowGroup("Telemetry Charts", for: TelemetryChartWindowRequest.self) { request in
            if let request = request.wrappedValue {
                TelemetryChartView(
                    nodeId: request.nodeId,
                    nodeName: request.nodeName,
                    days: request.days
                )
                .font(settings.scaledBodyFont)
                .environment(\.locale, settings.appLocale)
                .preferredColorScheme(settings.preferredColorScheme)
                .environment(\.dynamicTypeSize, settings.dynamicTypeSize)
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 950, height: 650)
        .windowResizability(.contentMinSize)

        // MARK: - Settings (⌘,)
        Settings {
            SettingsView()
                .environment(\.locale, settings.appLocale)
                .preferredColorScheme(settings.preferredColorScheme)
                .environment(\.appState, coordinator.appState)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(\.persistenceController, persistenceController)
                .environment(coordinator)
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

    private func postSystemNotification(for message: MessageItem?, partnerId: UInt32) {
        let senderName = message?.from ?? "Node \(partnerId)"
        let notification = AppNotification(
            identifier: "dm-\(partnerId)-\(Date().timeIntervalSince1970)",
            title: String(localized: "DM from \(senderName)"),
            body: message?.message ?? String(localized: "New direct message"),
            categoryIdentifier: "INCOMING_DM"
        )
        Task {
            await SystemNotificationService.shared.deliver(notification)
        }
    }
}

// MARK: - Notification Presentation

/// By default macOS suppresses notification banners while the app is in the
/// foreground. Explicit presentation keeps incoming DMs visible in every app state.
private final class NotificationPresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
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
            // Defer frame change to avoid layout recursion
            DispatchQueue.main.async {
                window.setFrame(frame, display: true, animate: false)
            }
        }
    }
}
