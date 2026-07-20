import CoreLocation
import SwiftUI

struct WaypointEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let coordinate: CLLocationCoordinate2D
    let sourceNodeId: UInt32
    let onSave: (MeshWaypoint, Bool) -> Void

    @State private var name = ""
    @State private var detail = ""
    @State private var icon = "📍"
    @State private var expirationHours = 24
    @State private var neverExpires = false
    @State private var sendToMesh = true
    @State private var channelIndex = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Waypoint") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $detail, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Icon or emoji", text: $icon)
                        .frame(maxWidth: 180)
                    LabeledContent(
                        "Position",
                        value: String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
                    )
                }

                Section("Expiration") {
                    Toggle("Never expires", isOn: $neverExpires)
                    Stepper("Expires in \(expirationHours) hours", value: $expirationHours, in: 1...720)
                        .disabled(neverExpires)
                }

                Section("Mesh") {
                    Toggle("Send to mesh", isOn: $sendToMesh)
                    Stepper("Channel: \(channelIndex)", value: $channelIndex, in: 0...7)
                        .disabled(!sendToMesh)
                }
            }
            .formStyle(.grouped)
            .padding()
            .navigationTitle("Create Waypoint")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 430)
    }

    private func save() {
        let scalar = icon.unicodeScalars.first?.value ?? 0
        let waypoint = MeshWaypoint(
            id: UInt32.random(in: 1..<UInt32.max),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)),
            detail: String(detail.prefix(100)),
            icon: scalar,
            expiration: neverExpires ? nil : Date().addingTimeInterval(TimeInterval(expirationHours * 3600)),
            lockedTo: 0,
            sourceNodeId: sourceNodeId,
            channelIndex: UInt32(channelIndex),
            receivedAt: Date()
        )
        onSave(waypoint, sendToMesh)
        dismiss()
    }
}

struct WaypointDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let waypoint: MeshWaypoint

    var body: some View {
        Form {
            LabeledContent("Name", value: waypoint.displayName)
            if !waypoint.detail.isEmpty {
                LabeledContent("Description", value: waypoint.detail)
            }
            LabeledContent(
                "Position",
                value: String(format: "%.6f, %.6f", waypoint.latitude, waypoint.longitude)
            )
            LabeledContent("Source", value: String(format: "!%08x", waypoint.sourceNodeId))
            LabeledContent("Channel", value: waypoint.channelIndex.formatted())
            if let expiration = waypoint.expiration {
                LabeledContent("Expires", value: expiration.formatted(date: .abbreviated, time: .shortened))
            } else {
                LabeledContent("Expires", value: String(localized: "Never"))
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 400, minHeight: 280)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: dismiss.callAsFunction)
            }
        }
    }
}
