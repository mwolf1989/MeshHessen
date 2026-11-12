# Plan 021: Messages render Meshtastic text formatting and the input has a format toolbar

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Views/SharedMessageViews.swift MeshHessen/Views/ChannelChatView.swift MeshHessen/Views/AllChannelsChatView.swift MeshHessen/Views/DMWindowView.swift`
> Plans 006/020 are expected to have touched these files.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/006-messaging-quick-fixes.md (same input views)
- **Category**: direction (feature parity with Windows 1.6.1.0)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

The official Meshtastic apps render a small Markdown subset in chat (`**bold**`, `*italic*`, `~~strike~~`, `` `mono` ``, `[text](https://…)`). Windows renders it and offers toolbar buttons that wrap the selection. On the Mac the markers show up as literal asterisks.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; tests in `Tests/MeshHessenTests/` (Swift Testing).
- Reference (READ-ONLY): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Converters/MessageDocumentConverter.cs` (rendering rules), `MeshhessenClient/Helpers/TextFormattingHelper.cs` (`Wrap`, `InsertLink`, toolbar).
- UI strings: English in code + German in `MeshHessen/Localizable.xcstrings` (only add keys).

## Current state

- `MeshHessen/Views/SharedMessageViews.swift`: `MessageBubbleView` (~245) renders message text; link detection uses `NSDataDetector` in a helper (~518–545) that builds an `AttributedString`/`Text` with clickable bare URLs; alert-bell stripping (~448).
- Inputs: `TextField("Message…", text: $messageText, axis: .vertical)` in `ChannelChatView.swift` (~143), `AllChannelsChatView.swift` (~111), `DMWindowView.swift` (~192), each followed by a byte counter using `MessageItem.payloadByteCount` / `MessageItem.maximumPayloadBytes` and truncation via `MessageItem.truncatingToPayloadLimit`.

Rendering rules (Windows): bold `**x**`, italic `*x*`, strike `~~x~~`, inline code `` `x` `` (content literal — no nested formatting inside), links `[label](http…/https…)` only for http/https; nesting of bold/italic/strike is allowed; unmatched markers stay literal; bare URLs remain clickable; line breaks preserved.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter MessageFormatting` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: `MeshHessen/Models/MessageFormatting.swift` (create), `MeshHessen/Views/MessageFormatToolbar.swift` (create), the four view files in the drift check, `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/MessageFormattingTests.swift` (create).

**Out of scope**: block-level Markdown (headings, lists, images, tables), HTML, non-http link schemes, changing what is sent on the wire (formatting markers are sent as plain text).

## Git workflow

Branch `feat/021-message-formatting`. Conventional commits. Do not push.

## Steps

### Step 1: Parser (pure)
`MessageFormatting.swift`:
```swift
enum MessageFormatting {
    static func attributed(_ text: String) -> AttributedString
    static func wrap(_ text: String, selection: Range<String.Index>?, marker: String) -> (text: String, selection: Range<String.Index>)
    static func insertLink(_ text: String, selection: Range<String.Index>?, url: String) -> String
}
```
Implement `attributed` with `try? AttributedString(markdown: text, options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible))`, falling back to `AttributedString(text)`. Then post-process: remove link attributes whose URL scheme is not http/https (keep the label text), and run the existing bare-URL detection over runs that have no link yet. Markdown images (`![…](…)`) must render as literal text, not as attachments — if the inline parser turns them into something else, pre-escape `![`.

### Step 2: Use it in the bubble
Replace the plain/link-detected text construction in `MessageBubbleView` by `MessageFormatting.attributed(...)` (after the existing alert-bell stripping). Keep text selection and existing context menus working. Encrypted placeholders and system messages stay unformatted.

### Step 3: Toolbar
`MessageFormatToolbar`: a compact row of buttons **B**, *I*, ~~S~~, `</>`, link — each calls `MessageFormatting.wrap` on the bound text. SwiftUI's `TextField` on macOS 14 exposes no selection, so the views pass `selection: nil` and `wrap` then appends the marker pair at the end of the text (e.g. `"abc"` → `"abc****"`); the `selection` parameter exists so a later selection-aware input can reuse the function. The link button asks for a URL in a small popover and appends `[text](url)`. After each insert re-apply `MessageItem.truncatingToPayloadLimit`. Add the toolbar above the input in the three chat views, collapsed behind a single "Aa" toggle button so the default layout does not grow.

**Verify**: app build succeeds.

## Test plan

`MessageFormattingTests.swift`:
- `**a**` → run "a" has bold intent; `*a*` italic; `~~a~~` strikethrough; `` `a*b*` `` → code run with literal `a*b*`.
- `[x](https://example.org)` → link attribute present; `[x](javascript:alert(1))` and `[x](file:///etc/passwd)` → no link attribute, text "x" kept.
- `**unclosed` → literal text preserved exactly.
- `"line1\nline2"` keeps the newline.
- `https://example.org` bare → link attribute present.
- `wrap("abc", nil, "**")` → `"abc****"` (or whatever simple behaviour you implemented — assert it explicitly).

**Verify**: `swift test --filter MessageFormatting` → pass; `swift test` → all pass.

## Done criteria

- [ ] `swift test` exits 0; xcodebuild Debug build succeeds
- [ ] Only http/https links are clickable (covered by tests)
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- `AttributedString(markdown:)` with inline-only syntax mangles ordinary radio chatter (e.g. `CQ * 73 *`, `5*5`, `_underscores_in_names`) in a way that drops characters — test these three strings; if characters are lost, STOP and report (a hand-written parser would then be needed).
- Rendering `AttributedString` breaks text selection in bubbles.

## Maintenance notes

- Security: links come from untrusted radio traffic — the http/https allow-list in Step 1 is mandatory; reviewers should check it first.
- Underscore emphasis (`_x_`) is interpreted by Apple's parser but not by Windows; acceptable difference, noted for support.
