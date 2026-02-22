import SwiftUI

/// Preset color choices for quick node tagging.
let nodeColorPresets: [(name: String, hex: String)] = [
    (String(localized: "Red"),    "#FF3B30"),
    (String(localized: "Blue"),   "#007AFF"),
    (String(localized: "Green"),  "#34C759"),
    (String(localized: "Yellow"), "#FFD60A"),
    (String(localized: "Orange"), "#FF9500"),
    (String(localized: "Purple"), "#AF52DE"),
    (String(localized: "Cyan"),   "#32D4DE"),
    (String(localized: "Gray"),   "#8E8E93"),
]

/// Sheet showing detailed info for a single node with color/note editing.
struct NodeInfoSheet: View {
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss

    let node: NodeInfo
    @State private var colorHex: String = ""
    @State private var note: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.name)
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(node.nodeId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { saveAndDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }

            Divider()

            // Details grid
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Short Name").foregroundStyle(.secondary)
                    Text(node.shortName).fontWeight(.medium)
                }
                GridRow {
                    Text("Long Name").foregroundStyle(.secondary)
                    Text(node.longName).fontWeight(.medium)
                }
                if node.batteryLevel > 0 {
                    GridRow {
                        Text("Battery").foregroundStyle(.secondary)
                        Text("\(node.batteryLevel)%")
                    }
                }
                if node.snrFloat != 0 {
                    GridRow {
                        Text("SNR").foregroundStyle(.secondary)
                        Text(String(format: "%.1f dB", node.snrFloat))
                    }
                }
                if node.distanceMeters > 0 {
                    GridRow {
                        Text("Distance").foregroundStyle(.secondary)
                        let km = node.distanceMeters / 1000
                        Text(km >= 1 ? String(format: "%.2f km", km) : String(format: "%.0f m", node.distanceMeters))
                    }
                }
                if let lat = node.latitude, let lon = node.longitude {
                    GridRow {
                        Text("Position").foregroundStyle(.secondary)
                        Text(String(format: "%.5f, %.5f", lat, lon))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                if node.lastHeard > 0 {
                    GridRow {
                        Text("Last Heard").foregroundStyle(.secondary)
                        let date = Date(timeIntervalSince1970: TimeInterval(node.lastHeard))
                        Text(date, style: .relative) + Text(" ago")
                    }
                }
            }

            Divider()

            // Color + note editing
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Color Tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("#RRGGBB", text: $colorHex)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .font(.system(.caption, design: .monospaced))
                        if !colorHex.isEmpty, let color = Color(hex: colorHex) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(color)
                                .frame(width: 24, height: 24)
                        }
                        Button("Clear") { colorHex = "" }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    // Preset color swatches
                    HStack(spacing: 6) {
                        ForEach(nodeColorPresets, id: \.hex) { preset in
                            Button {
                                colorHex = preset.hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: preset.hex) ?? .gray)
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
                                    )
                                    .overlay(
                                        colorHex.uppercased() == preset.hex.uppercased()
                                            ? Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.white)
                                            : nil
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(preset.name)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Optional note…", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 200)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 320)
        .onAppear {
            // Load persisted values from UserDefaults, falling back to in-memory model
            let savedColor = SettingsService.shared.colorHex(for: node.id)
            colorHex = savedColor.isEmpty ? node.colorHex : savedColor
            let savedNote = SettingsService.shared.note(for: node.id)
            note = savedNote.isEmpty ? node.note : savedNote
        }
    }

    private func saveAndDismiss() {
        node.colorHex = colorHex
        node.note = note
        // Persist via UserDefaults
        SettingsService.shared.setColorHex(colorHex, for: node.id)
        SettingsService.shared.setNote(note, for: node.id)
        dismiss()
    }
}
