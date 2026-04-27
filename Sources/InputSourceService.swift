//
//  InputSourceService.swift
//  CmdSpace
//
//  Created by Dmitry Yurkovski on 18/04/2026.
//

import Carbon
import os

final class InputSourceService: @unchecked Sendable {

    // MARK: Properties

    private nonisolated(unsafe) var lastKnownSourceID: String?
    private nonisolated(unsafe) var lastChangeTimestamp: CFAbsoluteTime = 0

    nonisolated func trackInputSourceChange() {
        lastKnownSourceID = currentSourceID()
        lastChangeTimestamp = CFAbsoluteTimeGetCurrent()
    }

    @discardableResult
    nonisolated func switchToNext() -> Bool {
        let sources = selectableKeyboardSources()
        guard sources.count > 1 else { return false }

        let currentID = currentSourceID()

        if let lastKnown = lastKnownSourceID,
           lastKnown != currentID,
           CFAbsoluteTimeGetCurrent() - lastChangeTimestamp < 0.15 {
            log.debug("system already switched, skipping")
            return false
        }

        let ids = sources.map { sourceID($0) }
        let currentIndex = ids.firstIndex(of: currentID) ?? 0
        let nextIndex = (currentIndex + 1) % sources.count
        let target = sources[nextIndex]

        log.debug("switch: \(self.shortID(currentID)) → \(self.shortID(self.sourceID(target))) (\(nextIndex + 1)/\(sources.count))")
        TISSelectInputSource(target)
        return true
    }

    nonisolated func currentLanguageCode() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return languageCode(for: source)
    }

    nonisolated func availableSources() -> [(id: String, name: String, code: String)] {
        return selectableKeyboardSources().compactMap { source in
            guard let id = sourceID(source) else { return nil }
            let name = sourceName(source) ?? id
            let code = languageCode(for: source)
            return (id: id, name: name, code: code)
        }
    }

    // MARK: Private

    private nonisolated func languageCode(for source: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
              let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String],
              let lang = langs.first else { return "??" }
        return String(lang.prefix(2)).uppercased()
    }

    private nonisolated func sourceName(_ source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private nonisolated func shortID(_ id: String?) -> String {
        guard let id else { return "nil" }
        return id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
    }

    nonisolated func selectableKeyboardSources() -> [TISInputSource] {
        guard let all = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return all.filter { isSelectableKeyboard($0) }
    }

    private nonisolated func isSelectableKeyboard(_ source: TISInputSource) -> Bool {
        guard let catPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory) else { return false }
        let category = Unmanaged<CFString>.fromOpaque(catPtr).takeUnretainedValue() as String
        guard category == (kTISCategoryKeyboardInputSource as String) else { return false }

        guard let selPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(selPtr).takeUnretainedValue())
    }

    private nonisolated func currentSourceID() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return sourceID(source)
    }

    nonisolated func sourceID(_ source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}
