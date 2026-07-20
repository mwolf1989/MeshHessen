import SwiftUI

/// Edits the global and per-radio station labels used beside the connection
/// control. A per-node value allows one Mac to remember several radios.
struct StationNameEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let node: MyNodeInfo
    let onSave: () -> Void

    @State private var globalName: String
    @State private var nodeName: String

    init(node: MyNodeInfo, onSave: @escaping () -> Void = {}) {
        self.node = node
        self.onSave = onSave
        _globalName = State(initialValue: SettingsService.shared.stationName)
        _nodeName = State(initialValue: SettingsService.shared.stationName(for: node.nodeId))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Station Name") {
                    TextField("Global station name", text: $globalName)
                    TextField("Name for \(node.shortName.isEmpty ? node.nodeIdHex : node.shortName)", text: $nodeName)

                    LabeledContent("Effective name") {
                        Text(effectiveName)
                            .fontWeight(.semibold)
                            .foregroundStyle(effectiveColor)
                    }
                }

                Section {
                    Text("Resolution order: global station name, name saved for this connected node, then the node ShortName.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !trimmedGlobalName.isEmpty, !trimmedNodeName.isEmpty {
                        Label(
                            "The global name currently takes precedence over the node-specific name.",
                            systemImage: "info.circle"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Station Name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .frame(width: 520, height: 360)
    }

    private var trimmedGlobalName: String {
        globalName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNodeName: String {
        nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveName: String {
        if !trimmedGlobalName.isEmpty { return trimmedGlobalName }
        if !trimmedNodeName.isEmpty { return trimmedNodeName }
        let shortName = node.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        return shortName.isEmpty ? node.nodeIdHex : shortName
    }

    private var effectiveColor: Color {
        if !trimmedGlobalName.isEmpty { return .red }
        if !trimmedNodeName.isEmpty { return .orange }
        return .secondary
    }

    private func save() {
        SettingsService.shared.stationName = trimmedGlobalName
        SettingsService.shared.setStationName(trimmedNodeName, for: node.nodeId)
        onSave()
        dismiss()
    }
}
