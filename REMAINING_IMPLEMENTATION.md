# MeshHessen – verbleibende Implementierungen

## 1) CoreData-Rollout abschließen
- [ ] Read-Path vollständig auf CoreData umstellen (Views/AppState primär aus CoreData statt Log-Dateien)
- [ ] Legacy-Fallback reduzieren/entfernen, sobald CoreData-Hydration stabil ist
- [ ] Migration für `nodeColor_*` und `nodeNote_*` (UserDefaults) in CoreData integrieren
- [ ] Idempotenz der Migration über Versionssprünge sicherstellen (v2/v3-Schema möglich)
- [ ] Datenbereinigung/Retention definieren (z. B. alte Messages trimmen)

## 2) Persistenzqualität & Konsistenz
- [ ] DM-Unread/Conversation-Metadaten konsistent in CoreData persistieren und beim Start korrekt rehydrieren
- [ ] ACK-/Delivery-State für alle relevanten Message-Pfade vollständig angleichen
- [ ] Konfliktfälle bei doppelten/fehlenden `packetId` robust behandeln
- [ ] CoreData-Fetches optimieren (Sortierung, Limits, Paging bei großen Historien)

## 3) Windows-Must-Keep vollständig absichern
- [ ] DM-Workflow-Endabnahme (Unread, Fokuswechsel, Zustellung, Neustartverhalten)
- [ ] Channel-Browser + `CHANNELS.csv`-Flow robust machen (Online/Fallback/Schema-Toleranz)
- [ ] Tile-Downloader + ZIP-Import auf Persistenz-/Pfadkonsistenz prüfen und abschließen
- [ ] Node-Info-Flow vollständig auf persistente Daten angleichen

## 4) Offizielle Meshtastic-Parität (macOS-äquivalent)
- [ ] Router/Deep-Link-Navigation einführen (State + URL-Scheme)
- [ ] AppIntents für macOS-fähige Flows ergänzen
- [ ] Widget-Target inkl. Shared-Store-Datenzugriff aufbauen
- [ ] Export-/Measurement-/Tips-Bereiche aus offizieller App übernehmen (wo macOS-sinnvoll)

## 5) Protobuf-/Domain-Parität erweitern
- [ ] Protobuf-Abdeckung über `admin/mesh/portnums` hinaus erhöhen (schrittweise)
- [ ] Noch fehlende Portnum-/Admin-Pfade aus offizieller App angleichen
- [ ] Domain-Mapping für zusätzliche Meshtastic-Features in Persistenz + UI durchziehen

## 6) Projekt-/Build-Härtung
- [ ] `xcodebuild`-Validierung für die neuen CoreData-Stufen reproduzierbar grün machen
- [ ] Build-/Smoke-Checks als wiederholbaren Ablauf dokumentieren
- [ ] Risiken aus DataModel-Codegen/DerivedData in der Doku festhalten

## 7) Tests & Abnahme
- [ ] Mindesttests für Router/Persistenz (ähnlich `RouterTests`-Muster) ergänzen
- [ ] Smoke-Testmatrix für Connect → Sync → Messaging → Restart → Recovery erstellen
- [ ] DoD pro Featureblock festziehen (Parität + Windows-Erhalt + Persistenzstabilität)
