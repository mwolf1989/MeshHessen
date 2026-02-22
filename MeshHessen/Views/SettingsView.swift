import SwiftUI
import AppKit

/// macOS Settings window (⌘,) — five tabs
struct SettingsView: View {
    @State private var selectedTab = SettingsTab.general
    @State private var settings = SettingsService.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            ConnectionSettingsPane()
                .tabItem { Label("Connection", systemImage: "network") }
                .tag(SettingsTab.connection)

            MapSettingsPane()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(SettingsTab.map)

            NotificationSettingsPane()
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsTab.notifications)

            DebugSettingsPane()
                .tabItem { Label("Debug", systemImage: "ladybug") }
                .tag(SettingsTab.debug)
        }
        .frame(width: 500, height: 360)
    }
}

private enum SettingsTab {
    case general, connection, map, notifications, debug
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @State private var settings = SettingsService.shared

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Station Name", text: Binding(
                    get: { settings.stationName },
                    set: { settings.stationName = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .help("Your station name shown to other nodes")
            }

            Section("Text Size") {
                HStack {
                    Button {
                        settings.fontSizeStep -= 1
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .buttonStyle(.bordered)
                    .disabled(settings.fontSizeStep <= -3)
                    .help("Smaller text (⌘-)")

                    Spacer()
                    Text(fontSizeLabel(settings.fontSizeStep))
                        .monospacedDigit()
                    Spacer()

                    Button {
                        settings.fontSizeStep += 1
                    } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .buttonStyle(.bordered)
                    .disabled(settings.fontSizeStep >= 3)
                    .help("Larger text (⌘+)")
                }
                Button("Reset to default") { settings.fontSizeStep = 0 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.accent)
                    .font(.caption)
                    .disabled(settings.fontSizeStep == 0)
                Text("Shortcut: ⌘+ / ⌘- / ⌘ 0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Messages") {
                Toggle("Show encrypted messages", isOn: Binding(
                    get: { settings.showEncryptedMessages },
                    set: { settings.showEncryptedMessages = $0 }
                ))
            }

            Section("Own Position") {
                HStack {
                    Text("Latitude:")
                    TextField("50.9", value: Binding(
                        get: { settings.myLatitude },
                        set: { settings.myLatitude = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)

                    Text("Longitude:")
                    TextField("9.5", value: Binding(
                        get: { settings.myLongitude },
                        set: { settings.myLongitude = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                }
                Text("Used to calculate distance to other nodes and show your position on the map.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func fontSizeLabel(_ step: Int) -> String {
        switch step {
        case -3: return "XS"
        case -2: return "S"
        case -1: return "M"
        case  0: return "Standard"
        case  1: return "L"
        case  2: return "XL"
        default: return "XXL"
        }
    }
}

// MARK: - Connection

private struct ConnectionSettingsPane: View {
    @State private var settings = SettingsService.shared

    var body: some View {
        Form {
            Section("Last Used Connection") {
                HStack {
                    Text("Serial Port:")
                    TextField("/dev/ttyUSB0", text: Binding(
                        get: { settings.lastComPort },
                        set: { settings.lastComPort = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("TCP Host:")
                    TextField("192.168.1.1", text: Binding(
                        get: { settings.lastTcpHost },
                        set: { settings.lastTcpHost = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Text("Port:")
                    TextField("4403", value: Binding(
                        get: { settings.lastTcpPort },
                        set: { settings.lastTcpPort = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Map

private struct MapSettingsPane: View {
    @State private var settings = SettingsService.shared
    @Environment(\.appState) private var appState
    @State private var showTileDownloader = false

    var body: some View {
        Form {
            Section("Map Source") {
                Picker("Map Source", selection: Binding(
                    get: { settings.mapSource },
                    set: { settings.mapSource = $0 }
                )) {
                    Text("OpenStreetMap Standard").tag("osm")
                    Text("OpenTopoMap").tag("osmtopo")
                    Text("OSM Dark").tag("osmdark")
                }
                .pickerStyle(.radioGroup)
            }

            Section("Tile Server URLs") {
                LabeledContent("OSM Standard:") {
                    TextField("URL", text: Binding(
                        get: { settings.osmTileUrl },
                        set: { settings.osmTileUrl = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                }
                LabeledContent("OpenTopoMap:") {
                    TextField("URL", text: Binding(
                        get: { settings.osmTopoTileUrl },
                        set: { settings.osmTopoTileUrl = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                }
                LabeledContent("OSM Dark:") {
                    TextField("URL", text: Binding(
                        get: { settings.osmDarkTileUrl },
                        set: { settings.osmDarkTileUrl = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                }
            }

            Section("Offline Tiles") {
                Button("Download Tiles…") { showTileDownloader = true }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showTileDownloader) {
            TileDownloaderSheet()
        }
    }
}

// MARK: - Notifications

private struct NotificationSettingsPane: View {
    @State private var settings = SettingsService.shared

    var body: some View {
        Form {
            Section("Alert Bell") {
                Toggle("Play sound on alert bell (🔔)", isOn: Binding(
                    get: { settings.alertBellSound },
                    set: { settings.alertBellSound = $0 }
                ))
                Text("When a message containing 🔔 or the BEL character is received, the app flashes red and plays a sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Debug

private struct DebugSettingsPane: View {
    @State private var settings = SettingsService.shared

    var body: some View {
        Form {
            Section("Debug Logging") {
                Toggle("Debug Messages", isOn: Binding(
                    get: { settings.debugMessages },
                    set: { settings.debugMessages = $0 }
                ))
                Toggle("Debug Serial", isOn: Binding(
                    get: { settings.debugSerial },
                    set: { settings.debugSerial = $0 }
                ))
                Toggle("Debug Device", isOn: Binding(
                    get: { settings.debugDevice },
                    set: { settings.debugDevice = $0 }
                ))
                Toggle("Debug Bluetooth", isOn: Binding(
                    get: { settings.debugBluetooth },
                    set: { settings.debugBluetooth = $0 }
                ))
            }
            .help("Enables verbose logging in the Debug tab")
        }
        .formStyle(.grouped)
        .padding()
    }
}

#Preview {
    SettingsView()
}
