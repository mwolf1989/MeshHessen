# MeshHessen 1.2.0 – Firmware-Updates, Funk-Echo und Firmware 2.8

Release date: 2026-11-15

> [English version below](#english)

MeshHessen 1.2.0 schließt zum Windows-Client (Stand 1.7.3) auf. Die App
unterstützt jetzt Meshtastic-Firmware 2.8, kann Firmware selbst einspielen und
bringt viele neue Ansichten für Funkverbindungen, Telemetrie und Nachrichten.

## Neu

- **Firmware-Assistent**: Firmware-Katalog, Download mit Prüfsumme und
  Updates per ESP32-WLAN-OTA, ESP32-Bluetooth-OTA, nRF52-Bluetooth-DFU und
  UF2. Vor jedem Update wird automatisch eine Konfigurationssicherung angelegt.
- **Konfiguration sichern und wiederherstellen** als JSON-Datei.
- **Funk-Echo**: Erkennung, Journal, Statistik, Radar, Route auf der Karte und
  Airtime-Berechnung.
- **Karte**: Umweltdaten als Boxen oder Heatmap, Höhenprofil einer Funkstrecke,
  3D-Gelände, Offline-Kartenquelle und Funknachbarn als Linien.
- **Nachrichten**: neue Seitenleiste mit DMs, Mitteilungen, Textformatierung
  mit Format-Leiste.
- **Telemetrie**: Blitz-, Boden- und Wassersensoren, Anzeige in µSv/h,
  Warn- und Alarmzonen im Dashboard, Abfrage von Telemetrie und LocalStats-Raten.
- **Node-Status** (Port 36) anzeigen, merken und setzen.
- **Gerätedisplay spiegeln**.
- Sechs native Modul-Formulare und Mesh Beacon.
- Firmware 2.8: signierte ACKs, Signatur-Richtlinie, „gehört auf LoRa“,
  AEAD-Kennzeichnung, neue Presets.

## Verbessert und korrigiert

- PKI-Entschlüsselung nutzt AES-256-CCM; späte PKI-Entschlüsselung und
  automatische NodeInfo-Anfrage bei unbekannten Absendern.
- Kanalnachrichten werden bei Bedarf in der App entschlüsselt (PSK und AEAD);
  Traceroute nur über Funk möglich.
- Schreiben von Kanal- und Besitzerdaten verliert keine Gerätefelder mehr;
  Längenlimits zählen UTF-8-Bytes.
- Node-Positionen überstehen NodeInfo-Pakete und Neustarts.
- Signalwerte nur aus direktem Funkempfang, richtige Diagrammskalen.
- Verbindungs-Watchdog, Heartbeat auch über Bluetooth, Geräte-Metadaten.
- Acht Korrekturen bei Nachrichten (Klingelzeichen, Enter, Scrollen, Namen …).
- Virtual Node mit zweistufiger Konfiguration; NodeDB zurücksetzen,
  Admin-Hinweise und Schnellkonfiguration.
- Protobufs auf Meshtastic 2.8.2 aktualisiert.

## Qualitätssicherung

- 791 erfolgreiche Swift-Package-Tests in 101 Test-Suites
- Signierter, notarisierter Release-Build (Developer ID)

## Hinweis

Die Firmware-Updates (WLAN-OTA, Bluetooth-OTA, nRF52-DFU, UF2) sind durch
Unit-Tests abgedeckt, aber noch nicht auf allen Geräten getestet. Bitte vorher
eine Sicherung behalten und Rückmeldungen melden.

---

## English

MeshHessen 1.2.0 catches up with the Windows client (as of 1.7.3). The app now
supports Meshtastic firmware 2.8, can flash firmware itself and adds many new
views for radio links, telemetry and messages.

## New

- **Firmware assistant**: firmware catalog, checksum-verified download and
  updates via ESP32 Wi-Fi OTA, ESP32 Bluetooth OTA, nRF52 Bluetooth DFU and UF2.
  A configuration backup is made automatically before each update.
- **Configuration backup and restore** as a JSON file.
- **Funk-Echo**: detection, journal, statistics, radar, route on the map and
  airtime calculation.
- **Map**: environment data as boxes or heatmap, link elevation profile,
  3D terrain, offline map source and RF neighbour links.
- **Messages**: new sidebar with DMs, notifications, text formatting with a
  format toolbar.
- **Telemetry**: lightning, soil and water sensors, µSv/h display, warn and
  alarm zones on the dashboard, telemetry polling and LocalStats rates.
- **Node status** (port 36): show, remember and set.
- **Device display mirroring**.
- Six native module forms and Mesh Beacon.
- Firmware 2.8: signed ACKs, signature policy, "heard on LoRa", AEAD badge,
  new presets.

## Improved and fixed

- PKI decryption uses AES-256-CCM; late PKI decryption and automatic NodeInfo
  requests for unknown senders.
- Channel messages are decrypted in the app when needed (PSK and AEAD);
  RF-only traceroute.
- Channel and owner writes no longer drop device fields; length limits count
  UTF-8 bytes.
- Node positions survive NodeInfo packets and restarts.
- Signal values from direct RF reception only, correct chart scales.
- Link watchdog, heartbeat over Bluetooth too, device metadata.
- Eight messaging fixes (bell character, Enter, scrolling, names …).
- Virtual Node two-stage configuration; NodeDB reset, admin hints and quick
  configuration.
- Protobufs updated to Meshtastic 2.8.2.

## Quality assurance

- 791 passing Swift package tests in 101 test suites
- Signed, notarized release build (Developer ID)

## Note

Firmware updates (Wi-Fi OTA, Bluetooth OTA, nRF52 DFU, UF2) are covered by unit
tests but have not yet been tested on every device. Keep a backup and please
report problems.
