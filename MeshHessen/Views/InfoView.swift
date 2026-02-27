import SwiftUI

struct InfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Mesh Hessen")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("A native macOS client for the Meshtastic mesh radio network, focused on the Mesh Hessen community.")
                    .foregroundStyle(.secondary)

                Divider()

                Group {
                    Text("Open Source Libraries")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        LicenseRow(name: "SwiftProtobuf", author: "Apple Inc.", license: "Apache 2.0",
                                   url: "https://github.com/apple/swift-protobuf")
                        LicenseRow(name: "ORSSerialPort", author: "Andrew Madsen", license: "MIT",
                                   url: "https://github.com/armadsen/ORSSerialPort")
                        LicenseRow(name: "Meshtastic Protocol", author: "Meshtastic LLC", license: "GPL 3.0",
                                   url: "https://github.com/meshtastic/protobufs")
                    }
                }

                Divider()

                Group {
                    Text("Map Tiles")
                        .font(.headline)
                    Text("Tile server provided by schwarzes-seelenreich.de. OpenStreetMap data © OpenStreetMap contributors.")
                        .foregroundStyle(.secondary)
                    Text("OpenTopoMap © opentopomap.org")
                        .foregroundStyle(.secondary)
                }

                Divider()

                Group {
                    Text("Mesh Hessen")
                        .font(.headline)
                    Text("Channel information sourced from github.com/SMLunchen/mh_windowsclient.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }
}

private struct LicenseRow: View {
    let name: String
    let author: String
    let license: String
    let url: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).fontWeight(.semibold)
            Text("by \(author) — \(license)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link(url, destination: URL(string: url)!)
                .font(.caption2)
        }
        .padding(.vertical, 4)
    }
}
