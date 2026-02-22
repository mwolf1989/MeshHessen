import SwiftUI

struct DebugView: View {
    @Environment(\.appState) private var appState
    @State private var autoScroll = true

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
                    appState.debugLines.removeAll()
                }
                .buttonStyle(.bordered)
            }
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(appState.debugLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(logColor(line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(4)
                }
                .onChange(of: appState.debugLines.count) { _, _ in
                    if autoScroll, let last = appState.debugLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func logColor(_ line: String) -> Color {
        if line.contains("[ERROR]") { return .red }
        if line.contains("[WARN]")  { return .orange }
        if line.contains("[BLE]")   { return .blue }
        if line.contains("[TCP]")   { return .cyan }
        if line.contains("[SRL]") || line.contains("[SERIAL]") { return .green }
        return .primary
    }
}
