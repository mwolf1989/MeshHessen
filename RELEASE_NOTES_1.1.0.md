# MeshHessen 1.1.0 – Windows Feature Parity

Release date: 2026-07-20

> [English version below](#english)

MeshHessen 1.1.0 ist das bisher größte Funktionsupdate des nativen macOS-Clients. Die Version schließt die wesentlichen Funktionslücken zur Windows-Version `v1.5.1S4.2` und erweitert Nachrichten, Geräteverwaltung, Telemetrie, Karten, Offline-Werkzeuge und Administration.

## Highlights

- Vollständiger Nachrichtenverlauf mit Antworten, Emoji-Reaktionen, Zustellstatus, RF-Empfangsdaten, Paging und konfigurierbarer Aufbewahrung
- Neue Ansicht „Alle Nachrichten“ über sämtliche Kanäle sowie verbesserte Direktnachrichten und SOS-Abläufe
- Native Konfigurationsoberfläche für alle unterstützten Geräte- und Modul-Kategorien
- Echtes MapLibre-Vektor-Rendering mit Raster-Fallback, persistentem Cache und Offline-Paketen
- Frei konfigurierbares Telemetrie-Dashboard mit 14 Widget-Typen
- Vollständiger Traceroute-Verlauf mit Filtern, Vergleich, Import/Export und Kartendarstellung
- Virtual Node TCP-Server und MQTT-3.1.1-Proxy
- T-Deck-Assistent für regions- und zoomabhängige Offline-Kartenpakete
- Kiosk-Modus, Update-Prüfung, Deep Links und erweiterte deutsch/englische Lokalisierung

## Nachrichten und Nodes

- Antworten und standardkonforme Emoji-Reaktionen werden gesendet, empfangen und dauerhaft gespeichert.
- Nachrichten zeigen – soweit verfügbar – Hop-Anzahl, RSSI, SNR, MQTT-Herkunft und direkte RF-Empfangsqualität.
- Große Verläufe werden seitenweise geladen; Nachrichten können vollständig oder nach Altersbereich gelöscht werden.
- Der Node-Browser unterstützt Tabellen- und Rasterdarstellung, Favoriten, Pins, Notizen, Farben und Positionspfade.
- Stationsnamen werden global oder gerätespezifisch verwaltet und einheitlich in Toolbar und Karte dargestellt.
- Änderungen öffentlicher Node-Schlüssel können vor dem Übernehmen bestätigt oder abgelehnt werden.

## Karten und Offline-Nutzung

- MapLibre GL JS rendert die offiziellen und benutzerdefinierten Vektorstile direkt in der macOS-App.
- Kartenressourcen werden mit korrekter Client-Kennung geladen, persistent zwischengespeichert und im Offline-Modus ausschließlich aus dem Cache bedient.
- Offline-Pakete können für Basiskarte, Topografie, Höhen-/Schummerungsdaten und Notfall-Layer vorbereitet werden.
- Waypoints können erstellt, angezeigt, geteilt und gelöscht werden.
- Node-Pfade, direkte Nachbarn und mehrere Traceroutes lassen sich gleichzeitig auf der Karte vergleichen.
- Der Notfall-Layer unterstützt alle 23 Feature-Klassen der Windows-Version einschließlich Filter, Zoom-Grenzen und Detailinformationen.
- Der T-Deck-Assistent erstellt additive SD-Karten-Strukturen für ausgewählte Regionen, Zoomstufen und Kartenstile.

## Telemetrie und Traceroutes

- Alle unterstützten Meshtastic-Telemetrievarianten werden normalisiert und dauerhaft gespeichert: Device, Environment, Air Quality, Power, Local Stats, Health, Host, Traffic und PAX.
- Das Dashboard bietet Linie, Fläche, Balken, Scatter, Gauge, Statistik, Heatmap, Histogramm, Candlestick, Aktivitäts-Zeitlinie, Ranking, Multi-Stat, Mesh Health und Uhr.
- Layout, Größe, Metrik, Node-Auswahl, Zeitraum, Grenzwerte und gleitende Mittelwerte sind pro Widget konfigurierbar.
- Traceroute-Verläufe unterstützen 3, 7, 14, 30 und 90 Tage sowie den vollständigen Zeitraum.
- Gespeicherte Routen können paarweise dedupliziert, mehrfach ausgewählt, als JSON importiert/exportiert und auf der Karte verglichen werden.

## Konfiguration, Verbindungen und Werkzeuge

- Native, validierte Formulare stehen für acht Kernkonfigurationen und acht Modulkonfigurationen zur Verfügung; die JSON-Ansicht bleibt für fortgeschrittene Anwendungsfälle erhalten.
- Remote-Administration, Zeitabgleich und gezielte Node-Informations- und Telemetrieabfragen wurden ergänzt.
- Der Virtual Node stellt einen Meshtastic-kompatiblen TCP-Endpunkt mit Konfigurations-Replay, mehreren Clients und bidirektionaler Weiterleitung bereit.
- Der MQTT-Proxy spricht MQTT 3.1.1 und folgt der Proxy-Konfiguration des verbundenen Funkgeräts.
- Die App merkt sich den zuletzt verwendeten Verbindungstyp und bekannte Bluetooth-Geräte.
- Sieben Hauptbereiche, Statusindikatoren, Werkzeugübersicht, Debug-Log-Zugriff und Deep Links vereinheitlichen die Desktop-Bedienung.

## Sicherheit und Zuverlässigkeit

- Kiosk-Zugangsdaten werden mit PBKDF2-HMAC-SHA256 abgeleitet und im macOS-Schlüsselbund statt im Klartext gespeichert.
- Admin-Befehle des Virtual Node können im Kiosk-Modus blockiert werden.
- Bestehende Einstellungen werden auf typisierte Werte migriert, ohne bewusste Benutzerauswahl zu verlieren.
- Das Core-Data-Modell wird automatisch auf Version 3 migriert und erhält bestehende Nodes, Kanäle und Nachrichten.
- Netzwerkfehler bei Vektorkarten verwenden nach Möglichkeit veraltete Cache-Daten; bei einem Rendererfehler wechselt die App automatisch zur Rasterkarte.

## Hinweise zum Update

- Erfordert macOS 14 Sonoma oder neuer.
- Beim ersten Start wird der lokale Datenspeicher automatisch migriert. Ein manueller Export ist nicht erforderlich; ein aktuelles Backup wird dennoch empfohlen.
- Der Virtual Node kann beim ersten Start eine macOS-Firewall-Abfrage auslösen.
- Offline-Vektorpakete können abhängig von Region und Zoomstufen erheblichen Speicherplatz benötigen.

## Qualitätssicherung

- 213 automatisierte Tests in 34 Test-Suites
- Erfolgreicher nativer macOS-Debug-Build einschließlich Signierung und Resource-Validierung
- Validierte MapLibre-Ressourcen und String-Catalog-Lokalisierung

---

## English

MeshHessen 1.1.0 is the largest feature update to the native macOS client so far. It closes the major feature gaps with Windows release `v1.5.1S4.2` and expands messaging, device management, telemetry, maps, offline tools, and administration.

## Highlights

- Complete message history with replies, emoji reactions, delivery state, RF reception data, paging, and configurable retention
- New all-channel message feed plus improved direct-message and SOS workflows
- Native configuration forms for every supported device and module category
- Real MapLibre vector rendering with raster fallback, persistent caching, and offline packages
- Configurable telemetry dashboard with 14 widget types
- Complete traceroute history with filters, comparison, import/export, and map visualization
- Virtual Node TCP server and MQTT 3.1.1 proxy
- T-Deck assistant for region- and zoom-based offline map packages
- Kiosk mode, update checks, deep links, and expanded German/English localization

## Messaging and Nodes

- Replies and standard emoji reactions are sent, received, and stored persistently.
- Messages show hop count, RSSI, SNR, MQTT origin, and direct RF reception quality when available.
- Large histories load in pages and can be deleted completely or by age range.
- The node browser supports table and grid layouts, favorites, pins, notes, colors, and position tracks.
- Station names can be configured globally or per device and are resolved consistently in the toolbar and map.
- Public-key changes can be reviewed, accepted, or rejected before replacing a trusted node key.

## Maps and Offline Use

- MapLibre GL JS renders the official and custom vector styles directly inside the macOS app.
- Map resources use the required client identity, a persistent cache, and cache-only behavior in offline mode.
- Offline packages can include the base map, topography, contour/hillshade data, and emergency overlays.
- Waypoints can be created, displayed, shared, and deleted.
- Node tracks, direct neighbors, and multiple traceroutes can be compared on the map.
- The emergency overlay supports all 23 Windows feature classes, including filters, zoom thresholds, and details.
- The T-Deck assistant creates additive SD-card structures for selected regions, zoom levels, and map styles.

## Telemetry and Traceroutes

- Every supported Meshtastic telemetry variant is normalized and persisted: Device, Environment, Air Quality, Power, Local Stats, Health, Host, Traffic, and PAX.
- Dashboard widgets include line, area, bar, scatter, gauge, statistic, heatmap, histogram, candlestick, activity timeline, ranking, multi-stat, mesh health, and clock.
- Layout, size, metric, node selection, time range, threshold, and moving average are configurable per widget.
- Traceroute history supports 3, 7, 14, 30, and 90 days as well as the complete history.
- Saved routes can be deduplicated by node pair, selected in groups, imported/exported as JSON, and compared on the map.

## Configuration, Connectivity, and Tools

- Validated native forms cover eight core and eight module configuration categories; the JSON view remains available for advanced use.
- Remote administration, time synchronization, and targeted node-information and telemetry requests are included.
- Virtual Node provides a Meshtastic-compatible TCP endpoint with configuration replay, multiple clients, and bidirectional forwarding.
- The MQTT proxy implements MQTT 3.1.1 and follows the connected radio's proxy settings.
- The app remembers the most recently used connection type and known Bluetooth devices.
- Seven main sections, status indicators, a tools overview, direct debug-log access, and deep links complete the desktop workflow.

## Security and Reliability

- Kiosk credentials are derived with PBKDF2-HMAC-SHA256 and stored in the macOS Keychain instead of plaintext.
- Virtual Node admin commands can be blocked while kiosk mode is active.
- Existing settings migrate to typed values without discarding explicit user choices.
- The Core Data store migrates automatically to version 3 while retaining existing nodes, channels, and messages.
- Vector-map network failures fall back to stale cached resources when possible; renderer failures automatically activate the raster map.

## Update Notes

- Requires macOS 14 Sonoma or later.
- The local data store migrates automatically on first launch. No manual export is required, although a current backup is always recommended.
- Starting Virtual Node for the first time may trigger a macOS firewall prompt.
- Offline vector packages can require substantial disk space depending on the selected region and zoom levels.

## Quality

- 213 automated tests across 34 suites
- Successful native macOS debug build, including signing and resource validation
- Validated MapLibre resources and String Catalog localization
