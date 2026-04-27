# CmdSpace — Development Notes

## Project overview

macOS menubar utility that intercepts ⌘Space to cycle keyboard input sources. Pure Swift, no storyboards, no external dependencies. Xcode project name is `CmdSpace`, display name is `CmdSpace`.

## Build & run

```bash
xcodebuild -project CmdSpace.xcodeproj -scheme CmdSpace -configuration Debug build
# Release:
xcodebuild -project CmdSpace.xcodeproj -scheme CmdSpace -configuration Release build
```

Install to /Applications for stable Accessibility permissions:
```bash
cp -R ~/Library/Developer/Xcode/DerivedData/CmdSpace-*/Build/Products/Release/CmdSpace.app /Applications/CmdSpace.app
```

## Architecture

- `main.swift` — programmatic entry point (`NSApplicationMain`), no storyboard
- `AppDelegate.swift` — menubar setup, hotkey installation (CGEventTap + Carbon fallback), Accessibility management, inline indicator suppression, Launch at Login via `SMAppService`, Sparkle auto-updater
- `InputSourceService.swift` — isolated service for enumerating and switching input sources via Carbon TIS API
- `Log.swift` — shared `os.Logger` instance (subsystem: `com.cmdspace`)
- `Sources/Info.plist` — Sparkle keys (`SUFeedURL`, `SUPublicEDKey`), merged with auto-generated plist

## Key technical decisions

### Hotkey strategy (dual mode)

1. **CGEventTap** (best) — intercepts keyDown events before the system, consumes ⌘Space by returning `nil`. Requires Accessibility. Prevents the macOS inline language indicator from showing stale values.
2. **Carbon RegisterEventHotKey** (fallback) — works without permissions but fires after the system processes the event. The inline indicator may desync.

The app starts with Carbon immediately, then polls `AXIsProcessTrusted()` and auto-upgrades to CGEventTap when Accessibility is granted. Carbon is unregistered after upgrade.

### Accessibility permissions & code signing

- Accessibility is tied to the binary's code signature (cdhash)
- Ad-hoc signing ("Sign to Run Locally") produces a new cdhash on every rebuild
- The app calls `tccutil reset Accessibility <bundleID>` on startup to clean stale TCC entries
- Once installed in /Applications from a Release build, the permission persists permanently

### Inline language indicator

macOS Sonoma+ shows a blue tooltip near the text cursor on input source change. With Carbon fallback, this indicator shows the pre-switch language (stale). The app suppresses it via `CFPreferencesSetValue("TSMLanguageIndicatorEnabled", false, ...)` on launch and restores it on quit.

### Input source switching

- `TISCreateInputSourceList` — enumerate all sources
- Filter by `kTISCategoryKeyboardInputSource` + `kTISPropertyInputSourceIsSelectCapable`
- Round-robin: find current index, select `(index + 1) % count`
- Detects system double-switch (system ⌘Space shortcut still enabled) by comparing `currentSourceID` with `lastKnownSourceID` within 150ms window

### Launch at Login

Uses `SMAppService.mainApp` (macOS 13+) — register/unregister via menu toggle. Status checked on each menu open.

## Project settings (pbxproj)

- `ENABLE_APP_SANDBOX = NO` — required for CGEventTap and tccutil
- `INFOPLIST_KEY_LSUIElement = YES` — no Dock icon
- `INFOPLIST_KEY_CFBundleDisplayName = CmdSpace` — display name
- `PRODUCT_BUNDLE_IDENTIFIER = com.cmdspace`
- `CODE_SIGN_STYLE = Automatic` — for stable signing (requires Apple ID in Xcode)
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — Xcode 26 default; C callbacks use `nonisolated`
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` — requires explicit `import os` in each file using Logger

### Auto-updates (Sparkle)

Sparkle 2 is added via SPM (`https://github.com/sparkle-project/Sparkle`). `AppDelegate` creates `SPUStandardUpdaterController(startingUpdater: true, ...)` and the menubar menu includes "Check for Updates…" wired to `updaterController.checkForUpdates(_:)`.

- `SUFeedURL` and `SUPublicEDKey` are in `Sources/Info.plist` (merged with generated plist via `INFOPLIST_FILE` + `GENERATE_INFOPLIST_FILE = YES`)
- Appcast is hosted on GitHub Pages at `https://dimayurkovski.github.io/CmdSpace/appcast.xml`
- EdDSA private key is in the local Keychain (never committed)
- See `RELEASE.md` for the full release + Sparkle signing workflow

## Gotchas

- C callbacks (`eventTapCallback`, `carbonHotKeyCallback`) must be `nonisolated` global functions — they cannot capture `self`. State is shared via `nonisolated(unsafe)` module-level vars.
- `CGEvent.tapCreate` returns `nil` silently if Accessibility is not granted — always check `AXIsProcessTrusted()` first.
- `DistributedNotificationCenter` observer needs `suspensionBehavior: .deliverImmediately` for background (LSUIElement) apps.
- `TISCopyCurrentKeyboardInputSource().takeRetainedValue()` — Carbon APIs return retained references.
- Changing `PRODUCT_BUNDLE_IDENTIFIER` invalidates existing TCC (Accessibility) entries — users must re-grant.
