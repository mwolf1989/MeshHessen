import AppKit
import SwiftUI

/// Status-bar radar for Funk-Echo: unread badge, a coloured pulse per request and a
/// short popover with the message. Clicking opens the journal window.
struct RequestEchoIndicator: View {
    @Environment(\.appState) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settings = SettingsService.shared
    @State private var kioskState = KioskState.shared

    @State private var pulseColor: Color = .teal
    @State private var pulseScale: CGFloat = 0.6
    @State private var pulseOpacity: Double = 0
    @State private var pulseTask: Task<Void, Never>?
    @State private var popoverMessage: String?
    @State private var popoverTask: Task<Void, Never>?

    private static let pulseDuration: Double = 0.85
    private static let popoverDuration: Duration = .seconds(5)

    var body: some View {
        Button(action: openJournal) {
            ZStack {
                Circle()
                    .stroke(pulseColor, lineWidth: 2)
                    .frame(width: 19, height: 19)
                    .scaleEffect(pulseScale)
                    .opacity(pulseOpacity)

                Image(systemName: settings.funkEchoQuiet
                    ? "antenna.radiowaves.left.and.right.slash"
                    : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 19, height: 19)
                    .background(settings.funkEchoQuiet ? Color.gray : Color.teal, in: Circle())
                    .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 0.5))
            }
            .overlay(alignment: .topTrailing) { badge }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Funk-Echo: requests other stations sent to your node — click opens the journal"))
        .accessibilityLabel(Text("Funk-Echo"))
        .accessibilityValue(Text("\(appState.requestEchoUnread) new requests"))
        .contextMenu {
            Toggle("Quiet mode", isOn: $settings.funkEchoQuiet)
            Button("Open journal", action: openJournal)
        }
        .popover(isPresented: popoverBinding, arrowEdge: .bottom) {
            Text(popoverMessage ?? "")
                .font(.callout)
                .padding(10)
                .frame(maxWidth: 320)
        }
        .onChange(of: appState.lastRequestEcho) { _, event in
            guard let event else { return }
            handle(event)
        }
        .onDisappear {
            pulseTask?.cancel()
            popoverTask?.cancel()
        }
    }

    @ViewBuilder
    private var badge: some View {
        if appState.requestEchoUnread > 0 {
            Text(verbatim: appState.requestEchoUnread > 99 ? "99+" : "\(appState.requestEchoUnread)")
                .font(.system(size: 8, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 12, minHeight: 12)
                .background(Color.red, in: Capsule())
                .offset(x: 5, y: -4)
                .allowsHitTesting(false)
        }
    }

    private var popoverBinding: Binding<Bool> {
        Binding(
            get: { popoverMessage != nil },
            set: { if !$0 { popoverMessage = nil } }
        )
    }

    // MARK: - Actions

    private func openJournal() {
        guard !kioskState.isFeatureLocked(.funkEcho) else { return }
        appState.requestEchoUnread = 0
        popoverMessage = nil
        openWindow(id: "request-echo")
    }

    private func handle(_ event: RequestEchoEvent) {
        guard settings.funkEchoEnabled, !settings.funkEchoQuiet else { return }
        let message = RequestEchoText.message(
            type: event.type,
            from: nodeLabel(event.fromId),
            detail: event.detail,
            tone: settings.funkEchoToneValue
        )
        pulse(type: event.type)
        showPopover(message)
        if settings.funkEchoNotifications, !NSApp.isActive {
            let notification = AppNotification(
                identifier: "funk-echo-\(event.id.uuidString)",
                title: String(localized: "📡 Who's pinging us?"),
                body: message,
                categoryIdentifier: "FUNK_ECHO"
            )
            Task { await SystemNotificationService.shared.deliver(notification) }
        }
    }

    private func pulse(type: RequestEchoType) {
        pulseTask?.cancel()
        pulseColor = Color(hex: type.colorHex) ?? .teal
        let repeats = type == .traceroute ? 2 : 1
        guard !reduceMotion else {
            pulseTask = Task { @MainActor in
                pulseScale = 1.4
                pulseOpacity = 0.9
                try? await Task.sleep(for: .seconds(Self.pulseDuration))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { pulseOpacity = 0 }
            }
            return
        }
        pulseTask = Task { @MainActor in
            for _ in 0..<repeats {
                guard !Task.isCancelled else { return }
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) {
                    pulseScale = 0.6
                    pulseOpacity = 0.9
                }
                // Let the reset render before animating outward.
                try? await Task.sleep(for: .milliseconds(16))
                withAnimation(.easeOut(duration: Self.pulseDuration)) {
                    pulseScale = 2.1
                    pulseOpacity = 0
                }
                try? await Task.sleep(for: .seconds(Self.pulseDuration))
            }
        }
    }

    private func showPopover(_ message: String) {
        popoverTask?.cancel()
        popoverMessage = message
        popoverTask = Task { @MainActor in
            try? await Task.sleep(for: Self.popoverDuration)
            guard !Task.isCancelled else { return }
            popoverMessage = nil
        }
    }

    private func nodeLabel(_ nodeId: UInt32) -> String {
        if let node = appState.node(forId: nodeId) {
            let short = node.shortName.trimmingCharacters(in: .whitespaces)
            if !short.isEmpty { return short }
            let name = node.name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return String(format: "!%08x", nodeId)
    }
}
