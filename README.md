# MeshHessen — Nativer macOS-Client für Meshtastic

> [English version below / Englische Version weiter unten](#meshhessen--native-macos-client-for-meshtastic)

---

## Was ist MeshHessen?

**MeshHessen** ist ein nativer macOS-Client für das [Meshtastic](https://meshtastic.org/) LoRa-Mesh-Funknetzwerk. Die App wurde speziell für die **Mesh Hessen**-Community in Deutschland entwickelt und bietet eine vollwertige Desktop-Oberfläche zum Senden und Empfangen von Nachrichten, zur Node-Verwaltung und zur Kartenvisualisierung — komplett ohne Cloud, ohne Registrierung, vollständig offline-fähig.

Die Anwendung ist in **Swift / SwiftUI** geschrieben und läuft nativ auf macOS 14 (Sonoma) und neuer.

## Voraussetzungen

| Anforderung | Details |
|---|---|
| **Betriebssystem** | macOS 14.0 (Sonoma) oder neuer |
| **Meshtastic-Gerät** | Jedes Meshtastic-kompatible LoRa-Board (z. B. Heltec V3, T-Beam, RAK WisBlock, etc.) |
| **Verbindung** | USB/Seriell, Bluetooth (BLE) oder TCP/WiFi |
| **Build-Tools** (nur für Entwickler) | Xcode 15+, Swift 5.9+ |

## Schnellstart

### 1. App herunterladen

Lade die neueste Version von der [Releases-Seite](../../releases) herunter, oder baue die App selbst aus dem Quellcode (siehe [Für Entwickler](#für-entwickler)).

### 2. Meshtastic-Gerät anschließen

Verbinde dein Meshtastic-Gerät per **USB-Kabel**, **Bluetooth** oder stelle sicher, dass es im **gleichen WLAN** erreichbar ist.

### 3. Verbinden

1. Starte **MeshHessen**
2. Klicke auf den **Connect**-Button in der Toolbar (oder `Datei → Verbinden`)
3. Wähle den Verbindungstyp:
   - **Serial / USB** — Wähle den COM-Port aus der Dropdown-Liste und klicke "Connect"
   - **Bluetooth** — Klicke "Scan", warte bis dein Gerät erscheint, wähle es aus und klicke "Connect"
   - **TCP / WiFi** — Gib Host-Adresse und Port (Standard: 4403) ein und klicke "Connect"
4. Warte 3–10 Sekunden, bis Kanäle und Nodes geladen sind

> Die App merkt sich deine letzte Verbindung und bietet sie beim nächsten Start wieder an.

## Features

### Nachrichten & Chat

- **Kanal-Chat** — Sende und empfange Nachrichten auf allen konfigurierten Kanälen
- **Direktnachrichten (DM)** — Private Nachrichten an einzelne Nodes in einem eigenen Fenster
- **Emoji-Reaktionen (Tapbacks)** — Reagiere auf Nachrichten mit Emojis (Daumen hoch, Herz, etc.)
- **Nachrichtenhistorie** — Alle Nachrichten werden lokal gespeichert und beim Neustart wiederhergestellt
- **Ungelesene-Nachrichten-Zähler** — Badge-Anzeige für ungelesene DMs
- **SOS-Funktion** — Sende einen Notruf-Alarm direkt aus dem Chat
- **Alert Bell** — Visueller und akustischer Alarm bei eingehenden Notrufen (blinkender roter Rahmen + Ton)
- **Nachrichten löschen** — Lösche die Chat-Historie einzelner Kanäle

### Node-Verwaltung

- **Node-Liste** — Übersicht aller Nodes im Mesh mit Live-Telemetrie
- **Node-Details** — Detailansicht mit Name, Batterie, SNR, RSSI, Entfernung, Firmware, GPS-Position
- **Farbige Node-Markierung** — Vergib individuelle Farben an Nodes zur besseren Unterscheidung
- **Node-Notizen** — Füge eigene Notizen zu einzelnen Nodes hinzu
- **Eigenen Node umbenennen** — Ändere Short Name und Long Name deines eigenen Knotens direkt aus der App
- **Telemetrie** — Batterie, Spannung, SNR, RSSI, Kanal-Auslastung, Airtime

### Kartenansicht

- **Node-Positionen** — Alle Nodes mit GPS-Koordinaten auf der Karte
- **Mehrere Kartenstile** — OpenStreetMap, OpenTopoMap, Carto Dark
- **Offline-Karten** — Lade Kartenkacheln pro Bundesland herunter für Offline-Nutzung
- **Tile-Import** — Importiere vorhandene Kachel-Archive (.zip) in den lokalen Cache
- **Tile-Downloader** — Lade Kacheln für einzelne Bundesländer oder eigene Bounding-Boxen herunter (Zoom 1–16)
- **"Auf Karte zeigen"** — Springe direkt zur Position eines Nodes auf der Karte

### Kanal-Verwaltung

- **Kanal-Browser** — Durchsuche die CHANNELS.csv mit Filter nach Bundesland und Freitextsuche
- **Kanäle hinzufügen** — Füge neue Kanäle zum Gerät hinzu
- **Kanalübersicht** — Übersicht aller aktiven Kanäle mit Name, Rolle (Primary/Secondary) und PSK

### Konfiguration

- **Node-Konfiguration** — Geräterolle, Region (EU_868 etc.), Modem-Preset, Bluetooth-Modus und weitere Einstellungen direkt aus der App
- **Mesh Hessen Preset** — Ein-Klick-Konfiguration für die EU_868-Region mit den empfohlenen Einstellungen für das Mesh Hessen Netzwerk
- **Einstellungen** — Fünf Reiter: Allgemein, Verbindung, Karte, Benachrichtigungen, Debug
- **Textgröße** — Einstellbare Schriftgröße (kleiner/größer) für die gesamte App

### Export & Daten

- **CSV-Export** — Exportiere Nodes, Nachrichten, Kanäle und Positionen als CSV-Dateien
- **Debug-Log** — Vollständiger Protokoll-Log mit Export-Funktion
- **Log-Export** — Exportiere App-Logs und Nachrichtenverläufe als Textdateien

### Sonstiges

- **Siri Shortcuts / AppIntents** — Steuere grundlegende Funktionen per Siri oder Kurzbefehle
- **URL-Scheme / Deep Links** — Öffne bestimmte Ansichten per URL
- **macOS-native UI** — SwiftUI-Oberfläche mit Toolbar, Sidebar, Tabs, Sheets — kein Web-Wrapper
- **Keine Cloud** — Kein Account, keine Registrierung, keine Cloud-Abhängigkeit
- **Tipps** — Kontextabhängige Tipps für neue Benutzer (TipKit)
- **Lokalisierung** — Deutsch und Englisch

## Für Entwickler

### Repository klonen

```bash
git clone https://github.com/mwolf1989/MeshHessen.git
cd MeshHessen
```

### Bauen mit Xcode

```bash
# Debug Build
xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build

# Release Build
xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Release build
```

Oder öffne `MeshHessen.xcodeproj` direkt in Xcode und drücke `⌘B`.

### Bauen mit Swift Package Manager

```bash
# SPM Build (nur Library-Targets, kein App-Bundle)
swift build
```

### Projektstruktur

```
MeshHessen/
├── Models/          # Datentypen (Structs/Enums, keine Geschäftslogik)
├── Services/        # Geschäftslogik, I/O, Transportschichten
│   ├── SerialConnectionService.swift     # USB/Seriell-Verbindung
│   ├── BluetoothConnectionService.swift  # BLE-Verbindung
│   ├── TcpConnectionService.swift        # TCP/WiFi-Verbindung
│   ├── MeshtasticProtocolService.swift   # Protobuf-Dekodierung & Paketverarbeitung
│   ├── SettingsService.swift             # Einstellungen (UserDefaults)
│   ├── AppLogger.swift                   # Logging
│   └── ...
├── Views/           # SwiftUI-Views (keine Geschäftslogik)
│   ├── MainView.swift          # Hauptfenster mit Sidebar + Tabs
│   ├── ConnectSheetView.swift  # Verbindungsdialog
│   ├── MapView.swift           # Kartenansicht
│   ├── ChannelChatView.swift   # Chat pro Kanal
│   ├── DMWindowView.swift      # Direktnachrichten-Fenster
│   ├── NodeInfoSheet.swift     # Node-Detailansicht
│   ├── SettingsView.swift      # Einstellungsfenster (⌘,)
│   └── ...
├── Generated/       # Protobuf-generierter Code — NICHT manuell bearbeiten
├── Proto/           # .proto Quelldateien
├── Persistence/     # CoreData-Stack
└── Resources/       # Ressourcen (CHANNELS.csv etc.)
```

### Abhängigkeiten

| Paket | Version | Lizenz |
|---|---|---|
| [SwiftProtobuf](https://github.com/apple/swift-protobuf) | ab 1.28.0 | Apache 2.0 |
| [ORSSerialPort](https://github.com/armadsen/ORSSerialPort) | ab 2.1.0 | MIT |

### Protobuf neu generieren

```bash
protoc --swift_out=MeshHessen/Generated MeshHessen/Proto/*.proto
```

## Datenspeicherung

| Daten | Speicherort |
|---|---|
| Einstellungen | `UserDefaults` (macOS Standard) |
| Logs & Nachrichtenhistorie | `~/Library/Application Support/MeshHessen/` |
| Kartenkachel-Cache | `~/Library/Application Support/MeshHessen/tiles/` |
| Persistente Node-/Nachrichtendaten | CoreData (SQLite unter Application Support) |

## Häufige Fragen (FAQ)

**Welche Meshtastic-Geräte werden unterstützt?**
Alle Meshtastic-kompatiblen LoRa-Boards, die USB-Seriell, Bluetooth LE oder TCP unterstützen.

**Brauche ich einen Account oder Internetzugang?**
Nein. Die App funktioniert komplett offline. Nur für den Download von Kartenkacheln wird eine Internetverbindung benötigt.

**Kann ich die App auch außerhalb von Hessen nutzen?**
Ja! Die App funktioniert mit jedem Meshtastic-Netzwerk weltweit. Der Kanal-Browser und das Mesh-Hessen-Preset sind auf die Hessen-Community zugeschnitten, aber alle anderen Funktionen sind universell nutzbar.

**Welche Baudrate wird für USB verwendet?**
115200 Baud, 8N1 — das ist der Meshtastic-Standard.

**Wie lade ich Offline-Karten herunter?**
Gehe in die Kartenansicht → Toolbar → "Download Tiles". Wähle ein Bundesland oder definiere eine eigene Bounding-Box und den gewünschten Zoom-Level.

## Lizenz & Credits

- **Meshtastic Protocol** — [Meshtastic LLC](https://github.com/meshtastic/protobufs) (GPL 3.0)
- **SwiftProtobuf** — [Apple Inc.](https://github.com/apple/swift-protobuf) (Apache 2.0)
- **ORSSerialPort** — [Andrew Madsen](https://github.com/armadsen/ORSSerialPort) (MIT)
- **Kartendaten** — OpenStreetMap-Mitwirkende, OpenTopoMap, CARTO
- **Tile-Server** — schwarzes-seelenreich.de
- **Kanal-Daten** — [SMLunchen/mh_windowsclient](https://github.com/SMLunchen/mh_windowsclient)

---
---

# MeshHessen — Native macOS Client for Meshtastic

> [Deutsche Version oben / German version above](#meshhessen--nativer-macos-client-für-meshtastic)

---

## What is MeshHessen?

**MeshHessen** is a native macOS client for the [Meshtastic](https://meshtastic.org/) LoRa mesh radio network. The app was specifically developed for the **Mesh Hessen** community in Germany and provides a full-featured desktop interface for sending and receiving messages, node management, and map visualization — completely without cloud services, no registration required, fully offline-capable.

The application is written in **Swift / SwiftUI** and runs natively on macOS 14 (Sonoma) and later.

## Requirements

| Requirement | Details |
|---|---|
| **Operating System** | macOS 14.0 (Sonoma) or later |
| **Meshtastic Device** | Any Meshtastic-compatible LoRa board (e.g. Heltec V3, T-Beam, RAK WisBlock, etc.) |
| **Connection** | USB/Serial, Bluetooth (BLE), or TCP/WiFi |
| **Build Tools** (developers only) | Xcode 15+, Swift 5.9+ |

## Quick Start

### 1. Download the App

Download the latest version from the [Releases page](../../releases), or build the app yourself from source (see [For Developers](#for-developers)).

### 2. Connect Your Meshtastic Device

Connect your Meshtastic device via **USB cable**, **Bluetooth**, or make sure it is reachable on the **same WiFi network**.

### 3. Connect

1. Launch **MeshHessen**
2. Click the **Connect** button in the toolbar (or `File → Connect`)
3. Select the connection type:
   - **Serial / USB** — Select the COM port from the dropdown and click "Connect"
   - **Bluetooth** — Click "Scan", wait for your device to appear, select it, and click "Connect"
   - **TCP / WiFi** — Enter the host address and port (default: 4403) and click "Connect"
4. Wait 3–10 seconds for channels and nodes to load

> The app remembers your last connection and offers it again on the next launch.

## Features

### Messaging & Chat

- **Channel Chat** — Send and receive messages on all configured channels
- **Direct Messages (DM)** — Private messages to individual nodes in a dedicated window
- **Emoji Reactions (Tapbacks)** — React to messages with emojis (thumbs up, heart, etc.)
- **Message History** — All messages are stored locally and restored on restart
- **Unread Message Counter** — Badge display for unread DMs
- **SOS Function** — Send an emergency alert directly from the chat
- **Alert Bell** — Visual and audible alarm on incoming emergency alerts (flashing red border + sound)
- **Delete Messages** — Clear chat history for individual channels

### Node Management

- **Node List** — Overview of all nodes in the mesh with live telemetry
- **Node Details** — Detailed view with name, battery, SNR, RSSI, distance, firmware, GPS position
- **Color-coded Nodes** — Assign individual colors to nodes for easy identification
- **Node Notes** — Add personal notes to individual nodes
- **Rename Own Node** — Change your node's Short Name and Long Name directly from the app
- **Telemetry** — Battery, voltage, SNR, RSSI, channel utilization, airtime

### Map View

- **Node Positions** — All nodes with GPS coordinates displayed on the map
- **Multiple Map Styles** — OpenStreetMap, OpenTopoMap, Carto Dark
- **Offline Maps** — Download map tiles per German federal state for offline use
- **Tile Import** — Import existing tile archives (.zip) into the local cache
- **Tile Downloader** — Download tiles for individual federal states or custom bounding boxes (zoom 1–16)
- **"Show on Map"** — Jump directly to a node's position on the map

### Channel Management

- **Channel Browser** — Browse CHANNELS.csv with federal state filter and free-text search
- **Add Channels** — Add new channels to the device
- **Channel Overview** — Overview of all active channels with name, role (Primary/Secondary), and PSK

### Configuration

- **Node Configuration** — Device role, region (EU_868 etc.), modem preset, Bluetooth mode, and more — directly from the app
- **Mesh Hessen Preset** — One-click configuration for the EU_868 region with recommended settings for the Mesh Hessen network
- **Settings** — Five tabs: General, Connection, Map, Notifications, Debug
- **Text Size** — Adjustable font size (smaller/larger) for the entire app

### Export & Data

- **CSV Export** — Export nodes, messages, channels, and positions as CSV files
- **Debug Log** — Full protocol log with export function
- **Log Export** — Export app logs and message history as text files

### Miscellaneous

- **Siri Shortcuts / AppIntents** — Control basic functions via Siri or Shortcuts
- **URL Scheme / Deep Links** — Open specific views via URL
- **macOS-native UI** — SwiftUI interface with toolbar, sidebar, tabs, sheets — no web wrapper
- **No Cloud** — No account, no registration, no cloud dependency
- **Tips** — Context-sensitive tips for new users (TipKit)
- **Localization** — German and English

## For Developers

### Clone the Repository

```bash
git clone https://github.com/mwolf1989/MeshHessen.git
cd MeshHessen
```

### Build with Xcode

```bash
# Debug Build
xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build

# Release Build
xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Release build
```

Or open `MeshHessen.xcodeproj` directly in Xcode and press `⌘B`.

### Build with Swift Package Manager

```bash
# SPM build (library targets only, no app bundle)
swift build
```

### Project Structure

```
MeshHessen/
├── Models/          # Data types (structs/enums, no business logic)
├── Services/        # Business logic, I/O, transport layers
│   ├── SerialConnectionService.swift     # USB/Serial connection
│   ├── BluetoothConnectionService.swift  # BLE connection
│   ├── TcpConnectionService.swift        # TCP/WiFi connection
│   ├── MeshtasticProtocolService.swift   # Protobuf decoding & packet processing
│   ├── SettingsService.swift             # Settings (UserDefaults)
│   ├── AppLogger.swift                   # Logging
│   └── ...
├── Views/           # SwiftUI views (no business logic)
│   ├── MainView.swift          # Main window with sidebar + tabs
│   ├── ConnectSheetView.swift  # Connection dialog
│   ├── MapView.swift           # Map view
│   ├── ChannelChatView.swift   # Per-channel chat
│   ├── DMWindowView.swift      # Direct messages window
│   ├── NodeInfoSheet.swift     # Node detail sheet
│   ├── SettingsView.swift      # Settings window (⌘,)
│   └── ...
├── Generated/       # Protobuf-generated code — DO NOT edit manually
├── Proto/           # .proto source definitions
├── Persistence/     # CoreData stack
└── Resources/       # Resources (CHANNELS.csv etc.)
```

### Dependencies

| Package | Version | License |
|---|---|---|
| [SwiftProtobuf](https://github.com/apple/swift-protobuf) | from 1.28.0 | Apache 2.0 |
| [ORSSerialPort](https://github.com/armadsen/ORSSerialPort) | from 2.1.0 | MIT |

### Regenerate Protobuf

```bash
protoc --swift_out=MeshHessen/Generated MeshHessen/Proto/*.proto
```

## Data Storage

| Data | Location |
|---|---|
| Settings | `UserDefaults` (macOS standard) |
| Logs & message history | `~/Library/Application Support/MeshHessen/` |
| Map tile cache | `~/Library/Application Support/MeshHessen/tiles/` |
| Persistent node/message data | CoreData (SQLite under Application Support) |

## FAQ

**Which Meshtastic devices are supported?**
All Meshtastic-compatible LoRa boards that support USB Serial, Bluetooth LE, or TCP.

**Do I need an account or internet access?**
No. The app works completely offline. An internet connection is only needed for downloading map tiles.

**Can I use the app outside of Hessen?**
Yes! The app works with any Meshtastic network worldwide. The channel browser and Mesh Hessen preset are tailored to the Hessen community, but all other features are universally usable.

**What baud rate is used for USB?**
115200 baud, 8N1 — the Meshtastic standard.

**How do I download offline maps?**
Go to the map view → toolbar → "Download Tiles". Select a federal state or define a custom bounding box and the desired zoom level.

## License & Credits

- **Meshtastic Protocol** — [Meshtastic LLC](https://github.com/meshtastic/protobufs) (GPL 3.0)
- **SwiftProtobuf** — [Apple Inc.](https://github.com/apple/swift-protobuf) (Apache 2.0)
- **ORSSerialPort** — [Andrew Madsen](https://github.com/armadsen/ORSSerialPort) (MIT)
- **Map Data** — OpenStreetMap contributors, OpenTopoMap, CARTO
- **Tile Server** — schwarzes-seelenreich.de
- **Channel Data** — [SMLunchen/mh_windowsclient](https://github.com/SMLunchen/mh_windowsclient)
