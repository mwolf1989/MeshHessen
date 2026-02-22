import SwiftUI
import AppKit

/// Red flashing border + notification bar overlay triggered by alert bell in messages.
struct AlertBellOverlay: View {
    @Environment(\.appState) private var appState
    @State private var blinkVisible: Bool = true
    @State private var dismissTask: Task<Void, Never>?
    @State private var soundTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if appState.showAlertBell {
                // Blinking red border
                RoundedRectangle(cornerRadius: 0)
                    .stroke(Color.red, lineWidth: 6)
                    .opacity(blinkVisible ? 1 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                VStack {
                    HStack(spacing: 12) {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(.white)
                        Text("Alert from \(senderName)")
                            .foregroundStyle(.white)
                            .fontWeight(.bold)
                        Spacer()

                        // Show on Map button (only if sender has GPS)
                        if senderHasLocation {
                            Button {
                                showOnMap()
                            } label: {
                                Label("Show on Map", systemImage: "map")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                        }

                        Button("Dismiss") {
                            dismissAlert()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                    }
                    .padding(8)
                    .background(Color.red)

                    Spacer()
                }
                .ignoresSafeArea()
                .onAppear {
                    startBlinkAnimation()
                    playSirenSound()
                    startAutoDismissTimer()
                }
                .onDisappear {
                    cancelTimers()
                }
            }
        }
    }

    // MARK: - Computed Properties

    private var senderName: String {
        guard let alert = appState.activeAlertBell else { return String(localized: "Unknown") }
        if !alert.senderShortName.isEmpty { return alert.senderShortName }
        if !alert.from.isEmpty { return alert.from }
        return String(localized: "Unknown")
    }

    private var senderHasLocation: Bool {
        guard let alert = appState.activeAlertBell,
              let node = appState.nodes[alert.fromId],
              node.latitude != nil, node.longitude != nil
        else { return false }
        return true
    }

    // MARK: - Blink Animation (6 cycles / 3 seconds)

    private func startBlinkAnimation() {
        blinkVisible = true
        // 6 full on/off cycles in 3 seconds = 0.25s per half-cycle
        withAnimation(
            .easeInOut(duration: 0.25)
            .repeatCount(12, autoreverses: true)
        ) {
            blinkVisible = false
        }
        // Reset to fully visible after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            blinkVisible = true
        }
    }

    // MARK: - Siren Sound

    private func playSirenSound() {
        guard SettingsService.shared.alertBellSound else { return }

        soundTask = Task { @MainActor in
            // Play alternating system sounds to create a siren effect
            for i in 0..<4 {
                if Task.isCancelled { break }
                // Alternate between two system sounds
                if i % 2 == 0 {
                    NSSound.beep()
                } else {
                    NSSound(named: "Sosumi")?.play()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - Auto-Dismiss (30 seconds)

    private func startAutoDismissTimer() {
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            dismissAlert()
        }
    }

    // MARK: - Actions

    private func dismissAlert() {
        cancelTimers()
        appState.showAlertBell = false
        appState.activeAlertBell = nil
    }

    private func showOnMap() {
        guard let alert = appState.activeAlertBell else { return }
        // Set focus node for the map, then switch to Map tab
        appState.mapFocusNodeId = alert.fromId
        appState.selectedTab = .map
        dismissAlert()
    }

    private func cancelTimers() {
        dismissTask?.cancel()
        dismissTask = nil
        soundTask?.cancel()
        soundTask = nil
    }
}
