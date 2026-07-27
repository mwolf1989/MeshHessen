# MeshHessen 1.1.1 – Reliability Update

Release date: 2026-07-27

> [English version below](#english)

MeshHessen 1.1.1 behebt sechs Fehler in der Knoten-, Kanal- und
Telemetrieverwaltung.

## Änderungen

- Die Knotensuche besitzt nur noch ein stabiles Suchfeld und verursacht beim
  Wechsel zwischen Sidebar und Knotenansicht keinen Toolbar-Absturz mehr.
- Nicht entschlüsselbare Nachrichten fremder Kanäle werden nicht länger einem
  lokalen Kanal zugeordnet. Sie erscheinen ausschließlich unter „Alle Kanäle“
  mit ihrem Kanal-Hash und ohne nicht ausführbare Antwortaktionen.
- Die Kanalkonfiguration wird als vollständiger Snapshot aller acht Slots
  übernommen. Unvollständige Abrufe bleiben sichtbar, löschen keine
  ungemeldeten Kanäle und können nicht versehentlich zurückgeschrieben werden.
- PSKs lassen sich zuverlässig einfügen. Leerzeichen und Zeilenumbrüche werden
  bereinigt, während ungültige Base64-Werte oder Schlüssellängen sichtbar
  bleiben und das Speichern blockieren.
- Das Telemetrie-Dashboard verwendet einen dynamischen Knoten-Katalog aus
  Live-Daten, Datenbank und gespeicherten Widgets. Telemetrie bislang
  unbekannter Sender wird gespeichert und legt einen Fallback-Knoten an.
- Sämtliche SQLite-Telemetriedaten können unter
  „Einstellungen → Daten → Telemetrie“ nach Bestätigung transaktional gelöscht
  werden. Nodes, Nachrichten, Einstellungen, Dashboards und der separate
  JSON-Traceroute-Verlauf bleiben erhalten.

## Qualitätssicherung

- Automatisierte Regressionstests für Kanalzuordnung, Kanal-Snapshots,
  PSK-Validierung, Telemetrie-Knoten und die globale Datenbereinigung
- 240 erfolgreiche Swift-Package-Tests in 37 Test-Suites sowie erfolgreiche
  Debug- und Release-Builds
- Validierter String Catalog, Property List und sauberer Git-Diff

---

## English

MeshHessen 1.1.1 fixes six reliability issues in node, channel, and telemetry
management.

## Changes

- Node search now has a single stable search field and no longer crashes the
  toolbar while switching between the sidebar and node view.
- Undecryptable messages from foreign channels are no longer assigned to a
  local channel. They appear only in “All Channels” with their channel hash and
  without actions that cannot be completed.
- Channel configuration is applied as a complete snapshot of all eight slots.
  Incomplete reads remain visible, do not delete unreported channels, and
  cannot accidentally be written back.
- PSKs can be pasted reliably. Spaces and line breaks are removed, while
  invalid Base64 or key lengths remain visible and block saving.
- The telemetry dashboard uses a dynamic node catalog built from live data,
  the database, and stored widgets. Telemetry from previously unknown senders
  is retained and creates a fallback node.
- All SQLite telemetry data can be cleared transactionally from
  “Settings → Data → Telemetry” after confirmation. Nodes, messages, settings,
  dashboards, and the separate JSON traceroute history are preserved.

## Quality

- Automated regression coverage for channel mapping, channel snapshots, PSK
  validation, telemetry nodes, and global data cleanup
- 240 successful Swift package tests across 37 suites plus successful Debug
  and Release builds
- Validated String Catalog, property list, and clean Git diff
