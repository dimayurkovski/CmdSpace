# CmdSpace

A lightweight macOS menubar utility that replaces **⌘ Space** with a faster, more reliable input source switcher (EN → DE → FR → …).

No Dock icon, no windows — just a small language indicator in your menubar.

## Download

[**Download the latest DMG**](https://github.com/dimayurkovski/CmdSpace/releases/latest) from GitHub Releases.

## Installation

1. Open the DMG and drag **CmdSpace** into **Applications**.
2. Launch CmdSpace from Applications.
3. A dialog will ask for Accessibility permission — click **"Open System Settings"** and enable **CmdSpace** in **Privacy & Security → Accessibility**.

That's it. The app appears as a language indicator (EN / DE / …) in your menubar.

### Disable conflicting shortcuts

macOS may already have ⌘Space assigned to Spotlight or Input Sources. To avoid conflicts:

- **System Settings → Keyboard → Keyboard Shortcuts → Spotlight** — uncheck "Show Spotlight search" (⌘Space)
- **System Settings → Keyboard → Keyboard Shortcuts → Input Sources** — uncheck "Select the next input source" and "Select the previous input source" (⌘Space)
- **Raycast** users: change its hotkey in Raycast settings

## Usage

- **⌘ Space** — cycle to the next input source
- **Click the menubar icon** — see all available layouts and switch with a click
- **Launch at Login** — toggle in the menubar menu (or via System Settings → General → Login Items)
- **Check for Updates…** — the app auto-updates via Sparkle; you can also check manually from the menu

## Features

- Global ⌘Space hotkey — works system-wide
- Round-robin cycling through all enabled keyboard layouts
- Menubar indicator showing current language
- Click-to-switch from the menubar menu
- Launch at Login toggle
- Automatic updates via Sparkle
- Suppresses the macOS inline language indicator to avoid stale tooltips
- No Dock icon, no windows — pure background utility

## Requirements

- macOS 26.0+ (Tahoe)

## Technical Details

### How the hotkey works

CmdSpace uses two interception strategies:

1. **CGEventTap** (preferred) — intercepts ⌘Space *before* the system processes it and consumes the event. Requires Accessibility permission.
2. **Carbon Hot Key** (fallback) — registers ⌘Space via the Carbon Event Manager. Works without any permissions but fires *after* the system has already processed the event.

The app starts with Carbon immediately for instant startup, then auto-upgrades to CGEventTap once Accessibility is granted.

> Without Accessibility the app still works via Carbon Hot Key, but the macOS inline language indicator may show stale values.

> Accessibility is tied to the binary's code signature. If you rebuild from source, the old permission becomes stale. The app auto-cleans stale entries on startup. Once installed from a signed Release build, the permission persists permanently.

### Inline language indicator

macOS Sonoma and later shows a small blue tooltip near the text cursor on every input source switch. In Carbon fallback mode this tooltip can display the wrong (pre-switch) language.

CmdSpace automatically disables this indicator on launch and restores it when you quit. No manual action needed. To re-enable it while CmdSpace is running:

```bash
defaults write -g TSMLanguageIndicatorEnabled -bool YES
```

### Input source switching

- `TISCopyInputSourceList` enumerates all selectable keyboard sources
- `TISSelectInputSource` switches to the next one in round-robin order
- `DistributedNotificationCenter` observes `kTISNotifySelectedKeyboardInputSourceChanged` to keep the menubar indicator in sync

### Architecture

```
main.swift               — App entry point (no storyboard)
AppDelegate.swift         — Menubar, hotkey lifecycle, Accessibility management
InputSourceService.swift  — Input source enumeration and switching via Carbon API
Log.swift                 — os.Logger instance (debug logs stripped in Release)
```

### Building from source

```bash
git clone https://github.com/dimayurkovski/CmdSpace.git
cd CmdSpace
open CmdSpace.xcodeproj
```

1. In Xcode: **Product → Build** (⌘B) with **Release** configuration.
2. Copy the built app to Applications:

```bash
cp -R ~/Library/Developer/Xcode/DerivedData/CmdSpace-*/Build/Products/Release/CmdSpace.app /Applications/CmdSpace.app
```

Requires Xcode 26+.
