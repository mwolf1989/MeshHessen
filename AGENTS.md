# AGENTS.md — MeshHessen

Guidelines for agentic coding agents working in this repository.

## Project Overview

MeshHessen is a native **macOS 14+ (Sonoma)** client for the [Meshtastic](https://meshtastic.org/) LoRa mesh radio network, built for the Mesh Hessen community in Germany. It connects to Meshtastic nodes via Serial/USB, Bluetooth (BLE), or TCP/WiFi. The UI is pure SwiftUI; there is no JavaScript, TypeScript, or web stack.

- **Language:** Swift 5.9+
- **UI:** SwiftUI (macOS 14 APIs)
- **Package manager:** Swift Package Manager (SPM) via `Package.swift`; Xcode is the primary build tool via `MeshHessen.xcodeproj`
- **Dependencies:** SwiftProtobuf 1.35.0, ORSSerialPort 2.1.0

---

## Build Commands

```bash
# Debug build
xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build

# Release build
xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Release build

# SPM build (library targets only, no app bundle)
swift build

# Clean
xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen clean
```

## Test Commands

There are currently **no test targets** in this project. If tests are added in the future:

```bash
# Run all tests
xcodebuild test -project MeshHessen.xcodeproj -scheme MeshHessen -destination 'platform=macOS'

# Run a single test class
xcodebuild test -project MeshHessen.xcodeproj -scheme MeshHessen \
  -only-testing:MeshHessenTests/MyTestClass

# Run a single test method
xcodebuild test -project MeshHessen.xcodeproj -scheme MeshHessen \
  -only-testing:MeshHessenTests/MyTestClass/testMethodName
```

When adding tests, prefer **Swift Testing** (`import Testing`, `@Test`) over legacy XCTest where the deployment target allows.

## Lint / Format

No automated linter or formatter is configured. Follow the conventions below consistently. Xcode's built-in re-indent (`Ctrl+I`) is the only formatting tool in use.

---

## Code Style Guidelines

### General Formatting

- **Indentation:** 4 spaces (no tabs)
- **Line length:** Keep lines readable; no hard limit, but prefer staying under ~120 characters
- **Trailing whitespace:** None
- **Braces:** Opening brace on the same line (`K&R style`)
- **MARK comments:** Use `// MARK: - SectionName` liberally to section files into logical groups (e.g. `// MARK: - Connect`, `// MARK: - Private`, `// MARK: - Delegate`)

### Imports

- List Apple framework imports first, alphabetically grouped by subsystem
- Third-party imports follow, separated by a blank line
- No unused imports

```swift
import CoreBluetooth
import Foundation
import Network
import SwiftUI

import SwiftProtobuf
import ORSSerial
```

### Naming Conventions

| Construct | Convention | Example |
|---|---|---|
| Types (class, struct, enum, protocol) | `UpperCamelCase` | `AppCoordinator`, `NodeInfo` |
| Properties and methods | `lowerCamelCase` | `connectionState`, `sendTextMessage` |
| Enum cases | `lowerCamelCase` | `ConnectionType.serial`, `ConnectionState.disconnected` |
| Constants | `lowerCamelCase` | `let maxRetries = 3` |
| Private helpers | Always mark `private` | `private func parsePacket()` |
| Protocol names | Noun phrase, no `-able`/`-ing` suffix | `ConnectionService` |

> **Note:** `protocol_` (trailing underscore) is used in a few places to avoid collision with the Swift keyword `protocol`. Prefer renaming via a different noun if possible.

### Types and Swift Features

- Prefer **value types** (`struct`, `enum`) over `class` unless reference semantics are needed
- Use `@Observable` (Swift Observation, macOS 14+) for model objects; do **not** use `ObservableObject`/`@Published`
- Use `@MainActor` on classes that own UI state
- Prefer Swift **Structured Concurrency** (`async/await`, `Task`, `withCheckedThrowingContinuation`) over callbacks or `DispatchQueue`
- Bridge callback APIs (CoreBluetooth, ORSSerialPort, NWConnection) using `withCheckedThrowingContinuation`
- Use `LocalizedStringKey` in SwiftUI `Text` views; use `String(localized: "…")` in code — **never** `NSLocalizedString`

### Error Handling

- Define errors as `enum MyError: LocalizedError` with descriptive `errorDescription` strings
- Use `do/catch` with `AppLogger.shared.log(...)` for protocol-level or I/O errors that must be recorded
- Use `try?` only for genuinely non-critical operations where silent failure is acceptable (file writes, sleeps)
- Use `guard` at function entry for early-exit preconditions; avoid deeply nested `if let` chains
- Display user-facing errors via `@State private var errorMessage: String?` shown in a `.alert`

```swift
// Preferred error-handling pattern
guard let data = someOptional else {
    AppLogger.shared.log("Expected data was nil in \(#function)")
    return
}
do {
    try riskyOperation(data)
} catch {
    AppLogger.shared.log("riskyOperation failed: \(error)")
}
```

### SwiftUI Patterns

- Views are always `struct`, never `class`
- Extract sub-views as `private struct` within the same file when a view body exceeds ~40 lines
- Use `.task { }` for async work tied to view lifecycle; avoid `onAppear` + `Task { }` combinations
- Use `ContentUnavailableView` (macOS 14+) for empty states
- Use `LazyVStack` inside `ScrollView` for lists of messages or dynamically-loaded content
- Use `@ViewBuilder` and `@ToolbarContentBuilder` for complex conditional view compositions
- Inject `AppState` into the view tree via the custom `AppEnvironment` environment key; inject `AppCoordinator` via `@Environment(AppCoordinator.self)`

### Architecture Patterns

- **Singleton (shared instance):** `AppLogger`, `MessageLogger`, `SettingsService` — use only for true app-wide singletons
- **Protocol-based transports:** `ConnectionService` protocol with concrete implementations (`SerialConnectionService`, `BluetoothConnectionService`, `TcpConnectionService`) — add new transport types by conforming to this protocol
- **Coordinator:** `AppCoordinator` is `@Observable` + `@MainActor` and owns the connection lifecycle; business logic lives in `AppState`; views are passive consumers
- **Pending/flush:** During handshake, `MeshtasticProtocolService` buffers nodes/channels/messages in pending arrays and flushes to `AppState` after initialization completes — preserve this pattern when adding new packet types

### File Organization

```
MeshHessen/
├── Models/          # Pure data types (structs/enums, no business logic)
├── Services/        # Business logic, I/O, and transport layers
├── Views/           # SwiftUI views only; no business logic
├── Generated/       # Protobuf-generated code — do not edit manually
└── Proto/           # Source .proto definitions
```

- Keep `Models/` as pure data (no `AppState` dependencies)
- Keep `Views/` free of direct I/O; delegate all mutations through `AppCoordinator` or `AppState`
- Do **not** manually edit files under `Generated/` — regenerate from `.proto` sources using `protoc`

### Persistence

- **Settings:** `SettingsService` wraps `UserDefaults`; add new settings there
- **Logs and message history:** Plain files under `~/Library/Application Support/MeshHessen/`; managed by `AppLogger` and `MessageLogger`
- **Tile cache:** OSM tiles cached to disk by `CachedTileOverlay`; do not bypass this cache

### Protobuf / Protocol

- Packet framing and protobuf decode/dispatch is entirely in `MeshtasticProtocolService`
- Add new packet type handling by extending the `switch` in `handleDecodedPacket` (or equivalent)
- Regenerate `Generated/MeshtasticProto.swift` with: `protoc --swift_out=Generated Proto/*.proto`
