import Carbon.HIToolbox
import Foundation

/// The languages "System" speech recognition listens for: the system languages plus the languages of
/// the enabled keyboard layouts. Someone with an English system who types in Russian speaks Russian too.
enum SpeechLanguages {
    static let maximum = 3

    static func automatic() -> [Locale] {
        candidates(preferred: Locale.preferredLanguages, keyboard: keyboardLanguages())
    }

    /// One locale per language, system languages first, at most `maximum`.
    static func candidates(preferred: [String], keyboard: [String]) -> [Locale] {
        var seen: Set<String> = []
        var locales: [Locale] = []
        for identifier in preferred + keyboard {
            let locale = Locale(identifier: identifier)
            guard let language = locale.language.languageCode?.identifier, seen.insert(language).inserted else { continue }
            locales.append(locale)
            if locales.count == maximum { break }
        }
        return locales.isEmpty ? [Locale(identifier: "en-US")] : locales
    }

    /// Primary languages of the enabled keyboard layouts, e.g. "ru" for the Russian layout.
    static func keyboardLanguages() -> [String] {
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return sources.compactMap { source in
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
            let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
            return languages?.first
        }
    }
}
