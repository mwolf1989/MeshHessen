import SwiftUI

struct DebugView: View {
    @Environment(\.appState) private var appState
    @State private var autoScroll = true
    @State private var pendingScrollTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Debug Log")
                    .font(.headline)
                Spacer()
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button("Clear") {
                    let count = appState.debugLines.count
                    appState.debugLines.removeAll()
                    AppLogger.shared.log("[UI] Debug log cleared (\(count) lines removed)", debug: true)
                }
                .buttonStyle(.bordered)
            }
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(appState.debugLines) { line in
                            Text(line.text)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(logColor(line.text))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(4)
                }
                .onChange(of: appState.debugLines.count) { _, _ in
                    guard autoScroll else { return }
                    pendingScrollTask?.cancel()
                    pendingScrollTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(50))
                        guard !Task.isCancelled,
                              let last = appState.debugLines.last
                        else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onDisappear {
                    pendingScrollTask?.cancel()
                    pendingScrollTask = nil
                }
            }
        }
    }

    private func logColor(_ line: String) -> Color {
        if line.contains("[ERROR]") || line.contains("failed") || line.contains("error") { return .red }
        if line.contains("[WARN]")  { return .orange }
        if line.contains("[BLE]") || line.contains("[Bluetooth]") { return .blue }
        if line.contains("[TCP]") || line.contains("[Coordinator]") { return .cyan }
        if line.contains("[SRL]") || line.contains("[SERIAL]") || line.contains("[Serial]") { return .green }
        if line.contains("[Protocol]") { return .purple }
        if line.contains("[Settings]") { return .orange.opacity(0.8) }
        if line.contains("[UI]") || line.contains("[App]") { return .pink }
        if line.contains("[History]") || line.contains("[MSG]") { return .teal }
        return .primary
    }
}
