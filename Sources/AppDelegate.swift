//
//  AppDelegate.swift
//  CmdSpace
//
//  Created by Dmitry Yurkovski on 18/04/2026.
//

import Cocoa
import Carbon
import os
import ServiceManagement
import Sparkle

nonisolated(unsafe) private var sharedService: InputSourceService!
nonisolated(unsafe) private var sharedEventTap: CFMachPort?

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: Properties

    private var statusItem: NSStatusItem!
    private let inputSourceService = InputSourceService()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var accessibilityTimer: Timer?
    private var usingEventTap = false

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    // MARK: Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        sharedService = inputSourceService
        inputSourceService.trackInputSourceChange()

        log.info("App path: \(Bundle.main.bundlePath)")
        log.info("AXIsProcessTrusted: \(AXIsProcessTrusted())")

        enableLaunchAtLoginIfFirstRun()
        disableInlineIndicator()
        setupStatusItem()
        installHotkeyHandler()
        observeInputSourceChanges()
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityTimer?.invalidate()
        restoreInlineIndicator()
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
        if let tap = sharedEventTap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    // MARK: Inline Indicator Control

    private let indicatorKey = "TSMLanguageIndicatorEnabled" as CFString

    private func disableInlineIndicator() {
        CFPreferencesSetValue(
            indicatorKey, kCFBooleanFalse,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        log.debug("Inline input indicator disabled")
    }

    private func restoreInlineIndicator() {
        CFPreferencesSetValue(
            indicatorKey, kCFBooleanTrue,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
    }

    nonisolated func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemTitle()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let titleItem = NSMenuItem(title: "CmdSpace", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        let currentCode = inputSourceService.currentLanguageCode()
        let sources = inputSourceService.availableSources()

        for (index, source) in sources.enumerated() {
            let item = NSMenuItem(
                title: "\(source.code)  \(source.name)",
                action: #selector(selectInputSource(_:)),
                keyEquivalent: ""
            )
            item.tag = index
            if source.code == currentCode {
                item.state = .on
            }
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let axStatus = AXIsProcessTrusted()
        let axTitle = axStatus
            ? "Accessibility: Granted"
            : "Accessibility: Not Granted — Open Settings…"
        let axItem = NSMenuItem(
            title: axTitle,
            action: axStatus ? nil : #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        if axStatus {
            axItem.isEnabled = false
        }
        menu.addItem(axItem)

        menu.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updaterController
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
    }

    private func updateStatusItemTitle() {
        statusItem?.button?.title = inputSourceService.currentLanguageCode()
    }

    @objc private func selectInputSource(_ sender: NSMenuItem) {
        let sources = inputSourceService.selectableKeyboardSources()
        guard sender.tag < sources.count else { return }
        TISSelectInputSource(sources[sender.tag])
    }

    private func enableLaunchAtLoginIfFirstRun() {
        let key = "hasLaunchedBefore"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
        log.info("First launch — Launch at Login enabled")
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                log.info("Launch at Login disabled")
            } else {
                try SMAppService.mainApp.register()
                log.info("Launch at Login enabled")
            }
        } catch {
            log.warning("Failed to toggle Launch at Login: \(error.localizedDescription)")
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        startAccessibilityPolling()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: Hotkey Installation

    private func installHotkeyHandler() {
        if AXIsProcessTrusted() {
            log.info("Accessibility already granted")
            if installEventTap() { return }
        } else {
            resetStaleAccessibilityEntry()
        }

        let hasCarbonFallback = installCarbonHotKey()
        if hasCarbonFallback {
            log.info("✅ Carbon hot key active")
        }

        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        startAccessibilityPolling()
    }

    private func resetStaleAccessibilityEntry() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        log.debug("Reset stale Accessibility entry for \(bundleID)")
    }

    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        var attempts = 0
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            attempts += 1
            let trusted = AXIsProcessTrusted()

            if attempts <= 3 {
                log.debug("poll #\(attempts): AXIsProcessTrusted=\(trusted)")
            }

            if trusted {
                timer.invalidate()
                self.upgradeToEventTap()
            }
            if attempts >= 60 {
                timer.invalidate()
                log.debug("Stopped polling for Accessibility")
            }
        }
    }

    private func upgradeToEventTap() {
        guard !usingEventTap else { return }
        log.info("Accessibility granted, upgrading to CGEventTap…")
        if installEventTap() {
            usingEventTap = true
            if let ref = hotKeyRef {
                UnregisterEventHotKey(ref)
                hotKeyRef = nil
            }
            if let ref = eventHandlerRef {
                RemoveEventHandler(ref)
                eventHandlerRef = nil
            }
            log.info("✅ Upgraded: Carbon removed, CGEventTap is primary")
        } else {
            log.warning("CGEventTap failed even with Accessibility, keeping Carbon")
        }
    }

    // MARK: CGEventTap

    private func installEventTap() -> Bool {
        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: nil
        ) {
            log.info("✅ Active CGEventTap installed (best mode)")
            sharedEventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }

        log.warning("CGEventTap failed (AXTrusted=\(AXIsProcessTrusted()))")
        return false
    }

    // MARK: Carbon Hot Key

    private func installCarbonHotKey() -> Bool {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyCallback,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else { return false }

        var hotKeyID = EventHotKeyID(signature: 0x4353_5753, id: 1)
        let regStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard regStatus == noErr else {
            if let ref = eventHandlerRef { RemoveEventHandler(ref); eventHandlerRef = nil }
            return false
        }

        return true
    }

    // MARK: Input Source Observation

    private func observeInputSourceChanges() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceDidChange),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func inputSourceDidChange() {
        inputSourceService.trackInputSourceChange()
        updateStatusItemTitle()
    }
}

// MARK: CGEventTap C Callback

private nonisolated func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = sharedEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown else {
        return Unmanaged.passRetained(event)
    }

    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let relevantModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]

    if keycode == 49 && flags.intersection(relevantModifiers) == [.maskCommand] {
        sharedService.switchToNext()
        return nil
    }

    return Unmanaged.passRetained(event)
}

// MARK: Carbon Hot Key C Callback

nonisolated(unsafe) private var lastSwitchTime: CFAbsoluteTime = 0
private let kSwitchCooldown: CFAbsoluteTime = 0.3

nonisolated(unsafe) private let carbonHotKeyCallback: EventHandlerUPP = { _, event, _ in
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.id == 1 else {
        return OSStatus(eventNotHandledErr)
    }

    let now = CFAbsoluteTimeGetCurrent()
    guard now - lastSwitchTime >= kSwitchCooldown else {
        return noErr
    }
    lastSwitchTime = now
    sharedService.switchToNext()
    return noErr
}
