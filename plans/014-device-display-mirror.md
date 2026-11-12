# Plan 014: The connected device's screen can be mirrored live in a window

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Services/MeshtasticProtocolService.swift MeshHessen/Views/ToolsView.swift MeshHessen/MeshHessenApp.swift`

## Status

- **Priority**: P3
- **Effort**: M–L
- **Risk**: LOW (additive)
- **Depends on**: plans/002-protobuf-v2.8.2-and-firmware-capabilities.md (hard); plans/008 (cached `DeviceMetadata`)
- **Category**: direction (feature parity with Windows 1.7.2)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Firmware 2.8 can stream its display contents to a locally connected client. Windows 1.7.2 shows a "mirror device display" entry in the Tools tab when the device reports a display; one click opens a live, pixel-exact view. Useful for headless boxes, support and screenshots.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; tests in `Tests/MeshHessenTests/` (Swift Testing).
- Reference (READ-ONLY, **authoritative for the frame format**): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Services/DisplayMirrorAssembler.cs`, `MeshhessenClient.Tests/DisplayMirrorTests.cs`, `MeshhessenClient/DisplayMirrorWindow.cs`, `MeshhessenClient/Services/MeshtasticProtocolService.cs` (~1292–1298 receive, ~3741 `GetDisplayInfo`, ~3994–4004 admin commands).
- Confirm generated Swift names by grep in `MeshHessen/Generated/` (expected: `FromRadio` oneof cases `.displayFrame` / `.displayPalette`, `DeviceMetadata.display` + `hasDisplay`, admin fields `setDisplayMirror`, `getDisplayFrameRequest`).
- UI strings: English in code + German in `MeshHessen/Localizable.xcstrings` (only add keys).

## Current state

- `handleFromRadio` in `MeshHessen/Services/MeshtasticProtocolService.swift` (~538) dispatches known FromRadio variants; after plan 002 the two display cases exist in the logging switch but are otherwise ignored.
- Admin messages to the local node are sent like `requestDeviceMetadata` (~1455):
  ```swift
  await ensureSessionKey()
  guard !sessionPasskey.isEmpty else { return }
  var admin = Meshtastic_AdminMessage()
  admin.getDeviceMetadataRequest = true
  admin.sessionPasskey = sessionPasskey
  await sendAdminMessage(admin)
  ```
- `MeshHessen/Views/ToolsView.swift` is a `Form` with `virtualNodeSection`, `mqttProxySection`, `tDeckSection` (each a `private var …: some View { Section … }`).
- Windows scenes are declared in `MeshHessen/MeshHessenApp.swift` (e.g. the DM window opened with `openWindow(id: "dm")`).

Frame format summary (verify every detail against `DisplayMirrorAssembler.cs` before coding):
- **Mono (MONO_VLSB)**: full frames; `total_size = width * ceil(height / 8)`; pixel (x, y) is bit `y % 8` of byte `(y / 8) * width + x`. Frames arrive in chunks with an offset; offset 0 starts a new frame; chunks must be contiguous and share frame id and geometry; total size capped at 512 KB.
- **RGB565** (little-endian): dirty rectangles (`rect_x/y/width/height` latched from the offset-0 chunk) composited into a persistent canvas of the panel size; 5/6/5 bits expanded to 8 bits by bit replication.
- **Palette**: separate chunked message with default on/off colours and up to 64 regions; the highest matching region index wins; applies to a mono frame only when the frame's palette signature matches.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter DisplayMirror` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: `MeshHessen/Services/DisplayMirrorAssembler.swift` (create), `MeshHessen/Views/DisplayMirrorView.swift` (create), the three files in the drift check, `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/DisplayMirrorTests.swift` (create).

**Out of scope**: remote nodes (mirroring is local-connection only), recording/export, input injection.

## Git workflow

Branch `feat/014-display-mirror`. Conventional commits. Do not push.

## Steps

### Step 1: Assembler (pure)
Port `DisplayMirrorAssembler.cs` to a Swift `struct DisplayMirrorAssembler` with `mutating func ingest(frame: Meshtastic_DisplayFrame) -> DisplayMirrorImage?` and `mutating func ingest(palette: Meshtastic_DisplayPalette)` (use the real generated type names), where `DisplayMirrorImage` is `{ width: Int, height: Int, rgba: Data }`. Port **all** tests from `DisplayMirrorTests.cs`.

**Verify**: `swift test --filter DisplayMirror` → all pass.

### Step 2: Protocol hooks
- `var onDisplayFrame: ((Meshtastic_DisplayFrame) -> Void)?`, `var onDisplayPalette: (…) -> Void)?`; call them from `handleFromRadio`.
- `var displayInfo: <generated DisplayInfo type>?` computed from the cached device metadata (plan 008's `deviceMetadata`) — nil when the device reports no display.
- `func setDisplayMirror(_ enabled: Bool) async` and `func requestDisplayFrame() async` built exactly like the admin example above.

### Step 3: Window
- `DisplayMirrorView`: owns a `DisplayMirrorAssembler` in an `@Observable` model; converts each `DisplayMirrorImage` to a `CGImage` (`CGDataProvider`, 32-bit RGBA) and shows it with `Image(decorative:scale:)` using `.interpolation(.none)` and `.aspectRatio(contentMode: .fit)`; `.task { await protocol.setDisplayMirror(true); await protocol.requestDisplayFrame() }`; `.onDisappear` → `setDisplayMirror(false)` and clear the callbacks.
- Register a `Window("Device Display", id: "display-mirror")` scene in `MeshHessenApp.swift` following the existing secondary-window pattern (environment injection included).
- `ToolsView`: new `displayMirrorSection` shown only when connected locally and `displayInfo != nil`, with a button that calls `openWindow(id: "display-mirror")`.

**Verify**: `swift build` exit 0; app build succeeds.

## Test plan

Ported Windows tests (mono full frame in two chunks → correct pixels; out-of-order chunk discarded; RGB565 dirty rect composited at the right offset; palette applied only on matching signature; oversize frame rejected) plus one test that the RGBA buffer length is `width * height * 4`.

## Done criteria

- [ ] `swift test` exits 0 including `DisplayMirror` suite; xcodebuild Debug build succeeds
- [ ] `grep -n "setDisplayMirror" MeshHessen/Services/MeshtasticProtocolService.swift` ≥ 1 match
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- The generated code has no display frame/palette messages.
- The C# assembler relies on fields that do not exist in the Swift generated message — list the differences.
- `deviceMetadata` is not available (plan 008 not done): STOP rather than adding a second metadata cache.

## Maintenance notes

- Cannot be verified without a firmware-2.8 device with a display. Reviewer needs one (mono OLED and, ideally, a TFT device).
- The mirror must always be switched off on window close/disconnect; otherwise the device keeps streaming frames over the link.
