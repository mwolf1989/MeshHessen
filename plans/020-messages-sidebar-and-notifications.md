# Plan 020: The Messages tab has a channel + DM sidebar with unread badges, optional inline DMs, and message notifications

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Views/MainView.swift MeshHessen/Views/ChannelTabsView.swift MeshHessen/Views/DMWindowView.swift MeshHessen/MeshHessenApp.swift MeshHessen/Services/SettingsService.swift MeshHessen/AppState.swift`
> Plan 006 is expected to have touched `DMWindowView.swift` and the chat views.

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: MED (central UI)
- **Depends on**: plans/006-messaging-quick-fixes.md
- **Category**: direction (feature parity with Windows 1.6.4 / 1.6.4.6)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Windows 1.6.4 reorganised messaging around a sidebar listing channels and direct-message conversations with unread badges; DMs can be read inline in the main window or in the separate DM window (a setting). It also notifies about new channel messages when the app is in the background, bundles notifications, and never notifies for old backlog messages. On the Mac, channels are tabs with "(n)" appended, DMs live only in a separate window, only DMs notify, each DM gets its own notification, and backlog DMs after reconnect each pop up the DM window and bounce the Dock.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; tests in `Tests/MeshHessenTests/` (Swift Testing).
- Reference (READ-ONLY): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Models/DmSidebarItem.cs`, `MeshhessenClient/MainWindow.xaml.cs` (`ApplyDmStyle` ~742–784, toast trigger ~2355–2370), `MeshhessenClient/Services/ToastService.cs`.
- State: `@Environment(\.appState) private var appState`, `@Environment(AppCoordinator.self) private var coordinator`. Settings pattern in `MeshHessen/Services/SettingsService.swift`: computed properties with `access(keyPath:)` / `withMutation(keyPath:)` over `defaults`.
- UI strings: English in code + German in `MeshHessen/Localizable.xcstrings` (only add keys).

## Current state (read these before coding)

- `MeshHessen/Views/MainView.swift`: `tabContent` (~223) shows `ChannelTabsView` for the messages tab; a toolbar DM button with a badge (~332–354); an incoming-DM consumer (~504–509) that opens the DM window.
- `MeshHessen/Views/ChannelTabsView.swift`: a `TabView` over `appState.channels`, each tab a `ChannelChatView`; unread count appended to the tab label; there is also the "all channels" view (`AllChannelsChatView`).
- `MeshHessen/Views/DMWindowView.swift`: conversation list (~17–41) + a `private` conversation view (the message list and input for one DM).
- `MeshHessen/AppState.swift`: `channelMessages[idx]`, `dmConversations`, per-channel and per-DM unread tracking (~51–58, ~134–139, ~234), `selectedChannelIndex`, `dmTargetNodeId`.
- `MeshHessen/MeshHessenApp.swift` (~159–193): observes `.incomingDirectMessage` notifications, opens the DM window, plays a sound, posts a `UNNotificationRequest` with a unique identifier per message. The `.incomingDirectMessage` post is in `MeshtasticProtocolService.swift` (~788–796) with no age check.
- Message timestamps: `MessageItem` has a creation/receive time (read the model for the property name used for sorting).

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter MessageNotification` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: `MeshHessen/Views/MessagesSidebarView.swift` (create), `MeshHessen/Services/MessageNotificationService.swift` (create), the six files in the drift check, `MeshHessen/Views/SettingsView.swift`, `MeshHessen/Services/MeshtasticProtocolService.swift` (only the notification trigger points), `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/MessageNotificationTests.swift` (create).

**Out of scope**: message storage, the DM window itself (it stays and keeps working), text formatting (plan 021), kiosk masks.

## Git workflow

Branch `feat/020-messages-sidebar`. Conventional commits per step. Do not push.

## Steps

### Step 1: Settings
`SettingsService`: `dmStyle: String` (`"window"` default | `"inline"`), `messageNotificationsEnabled: Bool` (default true). Controls in `SettingsView.swift` ("Direct messages: Separate window / Inline in Messages tab", "Notify about new messages").

### Step 2: Make the DM conversation view reusable
In `DMWindowView.swift` change the private single-conversation view to `internal` (name it `DMConversationView` if it has no good name) with the conversation's node id as input. No behaviour change in the DM window.

### Step 3: Sidebar
`MessagesSidebarView`: `NavigationSplitView` (or `HSplitView` if the main window already is a split view — check `MainView`) with a `List(selection:)`:
- Section "Channels": "All channels" entry + one row per `appState.channels` (name, MQTT icon as today, unread badge).
- Section "Direct Messages" (only when `dmStyle == "inline"`): one row per conversation (resolved node name, unread badge, capped "99+"), sorted by most recent message.
Detail: `AllChannelsChatView`, `ChannelChatView` for the selected channel, or `DMConversationView`. Selecting a channel sets `appState.selectedChannelIndex` (keep whatever marks a channel as read today working); selecting a DM marks it read. Persist the last selection in `@SceneStorage`.
Replace `ChannelTabsView` with `MessagesSidebarView` in `MainView.tabContent`. Leave `ChannelTabsView.swift` in the repo only if something else uses it; otherwise delete it.

### Step 4: Route "Send DM" by style
All places that open a DM (`appState.dmTargetNodeId = …; openWindow(id: "dm")` — grep for `openWindow(id: "dm")`) go through one helper on `AppCoordinator`/router: `openDirectMessage(nodeId:)` → inline style: switch to the messages tab and select that conversation in the sidebar; window style: current behaviour. In inline style an incoming DM must not open the DM window (`MainView` consumer ~504).

### Step 5: Notification service
`MessageNotificationService` (pure decision + thin UN wrapper):
```swift
static func shouldNotify(isOwn: Bool, isEncryptedPlaceholder: Bool, text: String, messageDate: Date, now: Date, appIsActive: Bool, enabled: Bool, isInitializing: Bool) -> Bool
```
true only when enabled, not own, not a placeholder, non-empty text, `now - messageDate <= 180 s`, app not active, not initializing. Posting: one notification identifier (`"mh-messages"`) that **replaces** the previous one; events within 1.5 s are batched ("3 new messages" with the last sender · channel as subtitle); title "Sender · Channel" for a single message. Clicking activates the app (the existing `UNUserNotificationCenter` delegate in `MeshHessenApp.swift` — extend it to select the channel/DM if the identifier carries that info; otherwise just activate).
Trigger it from the channel text path and the DM path in `MeshtasticProtocolService` (where the message is delivered to `AppState`). Replace the per-DM notification in `MeshHessenApp.swift` with this service; keep the alert sound for live DMs but apply the same 180 s / `isInitializing` guard to the sound, the Dock bounce and auto-opening the window.

**Verify (after each step)**: `swift build` exit 0; app build succeeds after steps 3–5.

## Test plan

`MessageNotificationTests.swift`: table-driven tests of `shouldNotify` (each condition flips the result); batching logic if extracted as a pure function (`summary(for events:) -> (title, body)`): 1 event → sender · channel; 3 events → count text.

**Verify**: `swift test --filter MessageNotification` → pass; `swift test` → all pass (update tests that referenced `ChannelTabsView` behaviour, if any, and list them).

## Done criteria

- [ ] `swift test` exits 0; xcodebuild Debug build succeeds
- [ ] `grep -rn "openWindow(id: \"dm\")" MeshHessen/Views | wc -l` → only inside the single routing helper (or the DM toolbar button)
- [ ] Backlog messages (older than 3 minutes or received during init) trigger no notification, sound, bounce or window
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- Unread tracking depends on `ChannelTabsView` internals that cannot be reproduced from the sidebar selection.
- The DM conversation view cannot be reused without the DM window's own state object.
- More than ~250 lines of `MainView.swift` would need to change.

## Maintenance notes

- This plan changes the primary navigation; the reviewer must click through: channel switching, unread badges clearing, inline DM vs. window mode, DM from node list/map, notification while app is in background, reconnect with backlog.
- Plan 021's formatting toolbar attaches to the chat input views reused here.
