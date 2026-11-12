# Plan 006: Messaging behaves like the Windows client in eight small ways

> **Executor instructions**: Follow this plan step by step. Each step is independent — commit after each. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Views/ChannelChatView.swift MeshHessen/Views/AllChannelsChatView.swift MeshHessen/Views/DMWindowView.swift MeshHessen/Views/SharedMessageViews.swift MeshHessen/Views/DebugView.swift MeshHessen/AppState.swift`

## Status

- **Priority**: P1
- **Effort**: M (eight S items)
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Small behaviours that Windows users rely on and that the Mac either lacks or gets wrong: the SOS/alert bell does not actually ring other devices (the BEL byte is missing), Enter does not send, chats open at the oldest message, backlog messages show "Channel 3" instead of the channel name, and a few context-menu/tooltip gaps.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; tests in `Tests/MeshHessenTests/` (Swift Testing). Baseline: `swift test` → 261 pass.
- Reference (READ-ONLY): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`), e.g. `MeshhessenClient/Helpers/EmojiPalette.cs` (`AlertPrefix`), `MeshhessenClient.Tests/AlertBellTests.cs`.
- UI strings: English in code; add the German translation of every new string to `MeshHessen/Localizable.xcstrings` (it has an unrelated uncommitted change — only add keys).
- Views get state via `@Environment(\.appState) private var appState` and `@Environment(AppCoordinator.self) private var coordinator`.

## Current state (excerpts at `d470b3a`)

1. Alert bell — three senders build the text without the BEL byte:
   - `Views/ChannelChatView.swift:295` and `Views/DMWindowView.swift:307`: `additionalText.isEmpty ? "🔔 Alert Bell Character!" : "🔔 \(additionalText)"`
   - `Views/AllChannelsChatView.swift:211`: `extra.isEmpty ? "🔔 Alert Bell Character!" : "🔔 \(extra)"`
   Receiving already detects and strips `\u{0007}` (`MeshtasticProtocolService.swift` ~746, `SharedMessageViews.swift` ~448).
2. Input field (`ChannelChatView.swift` ~143; same shape in `DMWindowView.swift` ~192 and `AllChannelsChatView.swift` ~111):
   ```swift
   TextField("Message…", text: $messageText, axis: .vertical)
       .lineLimit(1...4)
   ...
   Button(action: sendMessage) { … }.keyboardShortcut(.return, modifiers: .command)
   ```
   Send is Cmd+Return; in `AllChannelsChatView` the send button has no shortcut.
3. Scrolling (`ChannelChatView.swift` ~105): only `.onChange(of: messages.count)` scrolls to the last message — nothing scrolls when the view first appears.
4. `AllChannelsChatView.channelDisplayName(for:)` (~182) returns the **stored** `message.channelName` (which can be the placeholder "Channel N" persisted before channels were loaded).
5. `ReactionPillsView` (`SharedMessageViews.swift` ~92) takes `reactions: [String: [UInt32]]` and shows no tooltip.
6. Message context menu (`SharedMessageViews.swift` ~374): node actions exist only inside `if let senderNode { … }` and contain no "request info" items. `NodeInfoRequestType.allCases` (in `Models/NodeInfoRequestType.swift`) is used for such menus in `Views/NodeListView.swift` (~68).
7. `DebugView.swift` (~52): `.onChange(of: appState.debugLines.count)` — once the line cap is reached the count stays constant and auto-scroll stops.
8. DM conversation titles use the stored `conv.nodeName` (`DMWindowView.swift`), which goes stale when a node is renamed.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter AlertBell` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: the six files in the drift check, `MeshHessen/Models/MeshEnums.swift` (one constant), `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/AlertBellTests.swift` (create).

**Out of scope**: a messages sidebar or inline DMs (plan 020), notifications (plan 020), text formatting (plan 021), `MeshtasticProtocolService` receive paths.

## Git workflow

Branch `fix/006-messaging-quick-fixes`; one conventional commit per step. Do not push.

## Steps

### Step 1: Alert bell sends BEL
Add to `MeshEnums.swift`:
```swift
enum AlertBell {
    static let prefix = "\u{0007}🔔 "
    static func text(_ extra: String) -> String {
        prefix + (extra.isEmpty ? "Alert Bell Character!" : extra)
    }
}
```
Use `AlertBell.text(...)` in all three senders. Make sure the result is still passed through the existing payload-limit truncation if the sender does that today.

**Verify**: `grep -rn '"🔔 ' MeshHessen/Views` → no matches; `swift build` exit 0.

### Step 2: Enter sends, Shift+Enter inserts a newline
On each of the three `TextField`s add
```swift
.onKeyPress(.return, phases: .down) { press in
    if press.modifiers.contains(.shift) { messageText += "\n"; return .handled }
    sendMessage(); return .handled
}
```
(use each view's own send function and text binding names; do nothing and return `.handled` if the send button would be disabled). Keep the Cmd+Return shortcut; add it to the send button in `AllChannelsChatView`. Raise `.lineLimit(1...4)` to `1...6`.

**Verify**: app build succeeds.

### Step 3: Chats open at the newest message
Add `.defaultScrollAnchor(.bottom)` to the message `ScrollView` in the three chat views. If a view restores a scroll position for history paging (`suppressNextAutoScroll` in `ChannelChatView`), leave that logic unchanged.

### Step 4: Resolve channel names from the current channel list
`channelDisplayName(for:)`: if `!message.isUnknownChannel` and `appState.channels.first(where: { $0.id == message.channelIndex })` exists with a non-empty `name`, return that; otherwise fall back to the current code.

### Step 5: Reaction tooltip
Give `ReactionPillsView` an optional closure `nameForNode: ((UInt32) -> String)? = nil` and add `.help("\(emoji)  \(names.joined(separator: ", "))")` to each pill when it is set. At the call site(s) pass `{ appState.node(forId: $0)?.name ?? String(format: "!%08x", $0) }`.

### Step 6: "Request info" in the message context menu
Outside the `if let senderNode` block, for any message whose sender id is non-zero and not our own node, add a `Menu("Request Info")` listing `NodeInfoRequestType.allCases`, calling the same coordinator/protocol function `NodeListView.swift` uses (read lines ~60–80 there and copy the call, with the message's sender id as target).

### Step 7: Debug log keeps auto-scrolling at the cap
Change the observed value to the last line's identity (`appState.debugLines.last?.id`; if lines have no `id`, observe a monotonically increasing counter you add to `AppState.appendDebugLine`).

### Step 8: DM titles follow node renames
Where `DMWindowView` shows `conv.nodeName`, prefer `appState.node(forId: conv.nodeId)?.name` when non-empty (check the actual property names on `DirectMessageConversation` in `Models/DirectMessageConversation.swift`).

**Verify (steps 3–8)**: `swift build` exit 0 and app build succeeds after each step.

## Test plan

`AlertBellTests.swift`: `AlertBell.text("")` starts with `"\u{0007}"`, contains "🔔" and the default text; `AlertBell.text("Hilfe")` == `"\u{0007}🔔 Hilfe"`; the first UTF-8 byte is `0x07`.

**Verify**: `swift test --filter AlertBell` → pass; `swift test` → all pass.

## Done criteria

- [ ] All eight steps committed; `swift test` and xcodebuild Debug build succeed
- [ ] `grep -rn "defaultScrollAnchor(.bottom)" MeshHessen/Views | wc -l` ≥ 3
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- `.onKeyPress` on the vertical `TextField` does not compile for the macOS 14 deployment target.
- Step 2 cannot be made to work without replacing `TextField` by a custom `NSTextView` wrapper — report instead of building one.

## Maintenance notes

- Step 2 and 3 cannot be verified by unit tests — the reviewer must try them in the running app (Enter, Shift+Enter, opening a long channel).
- Plan 020 replaces the channel tab view; these fixes live in the chat views it will reuse.
