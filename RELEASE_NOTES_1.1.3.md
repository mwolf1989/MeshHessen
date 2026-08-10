# MeshHessen 1.1.3 – Search, Telemetry Alarms and Remote Admin

Release date: 2026-08-10

> [English version below](#english)

MeshHessen 1.1.3 erweitert die Nachrichtensuche und das Telemetrie-Dashboard
und korrigiert die Remote-Administration über Meshtastic-PKI.

## Änderungen

- Kanalnachrichten lassen sich sowohl in einem einzelnen Kanal als auch unter
  „Alle Kanäle“ durchsuchen. Die Suche berücksichtigt den vollständigen lokal
  gespeicherten Verlauf, Absender und – in der kombinierten Ansicht – den
  Kanalnamen, unabhängig von Groß-/Kleinschreibung und Diakritika.
- Telemetrie-Widgets unterstützen eigene Anzeigebereiche sowie optionale
  untere und obere Alarmgrenzen. Neue Grenzwertverletzungen markieren das
  Widget und lösen einmalig eine macOS-Mitteilung aus; nach einer Erholung wird
  der Alarm erneut scharf. Der Alarmzustand bleibt über App-Neustarts erhalten.
- Remote-Admin-Pakete verwenden bei bekanntem 32-Byte-Zielschlüssel jetzt den
  offiziellen PKI-Pfad mit Zielschlüssel, Kanal 0, ACK und zuverlässiger
  Priorität. Ohne Schlüssel wird ein konfigurierter Admin-Kanal verwendet und
  andernfalls auf Kanal 0 zurückgefallen. Routing-NACKs werden über die
  Paket-ID als konkrete PKI-, Autorisierungs- oder Routingfehler gemeldet.

## Qualitätssicherung

- 252 erfolgreiche Swift-Package-Tests in 37 Test-Suites
- Erfolgreicher signierungsfreier nativer macOS-Debug-Build
- Regressionstests für vollständige Verlaufssuche, Dashboard-Migration,
  Anzeigebereiche, Alarm-Entprellung und Remote-Admin-Routing

---

## English

MeshHessen 1.1.3 expands message search and the telemetry dashboard and fixes
remote administration over Meshtastic PKI.

## Changes

- Channel messages can now be searched within an individual channel and in
  “All Channels.” Search covers the complete locally retained history, sender,
  and—in the combined view—the channel name, ignoring case and diacritics.
- Telemetry widgets support custom display ranges and optional lower and upper
  alarm limits. A new violation highlights the widget and sends one macOS
  notification; the alarm rearms after recovery and its state survives app
  restarts.
- Remote admin packets now use the official PKI path whenever a known 32-byte
  destination key is available, including the destination key, channel 0, ACK,
  and reliable priority. Without a key, a configured admin channel is used,
  falling back to channel 0. Routing NACKs are correlated by packet ID and
  reported as concrete PKI, authorization, or routing errors.

## Quality

- 252 passing Swift package tests across 37 suites
- Successful unsigned native macOS Debug build
- Regression coverage for full-history search, dashboard migration, display
  ranges, alarm debouncing, and remote-admin routing
