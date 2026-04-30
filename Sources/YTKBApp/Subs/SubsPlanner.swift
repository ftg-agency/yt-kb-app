import Foundation

struct SubsPlan {
    struct Attempt: Equatable {
        let langKey: String
        let isAuto: Bool
    }
    let attempts: [Attempt]
}

enum SubsPlanner {
    /// Pick a language key matching `desired` from the available track keys.
    /// Tries exact, then prefix (so "en" matches "en-US"). Returns nil if none.
    static func pickLang(_ desired: String?, in tracks: [String: [SubFormat]]?) -> String? {
        guard let desired, !desired.isEmpty, let tracks, !tracks.isEmpty else { return nil }
        if tracks[desired] != nil { return desired }
        let base = desired.split(separator: "-").first.map(String.init)?.lowercased() ?? desired.lowercased()
        for key in tracks.keys {
            let keyBase = key.split(separator: "-").first.map(String.init)?.lowercased() ?? key.lowercased()
            if keyBase == base { return key }
        }
        return nil
    }

    /// Build a 6-tier priority plan, deduped by (lang, isAuto).
    static func buildPlan(meta: VideoMetadata) -> SubsPlan {
        let auto = meta.automaticCaptions ?? [:]
        let manual = meta.subtitles ?? [:]
        let orig = meta.language ?? meta.originalLanguage

        var attempts: [SubsPlan.Attempt] = []
        var seen: Set<String> = []

        func add(_ key: String?, _ isAuto: Bool) {
            guard let key, !key.isEmpty else { return }
            let id = "\(key)|\(isAuto)"
            guard !seen.contains(id) else { return }
            seen.insert(id)
            attempts.append(SubsPlan.Attempt(langKey: key, isAuto: isAuto))
        }

        // Tier 1+2: original language
        add(pickLang(orig, in: auto), true)
        add(pickLang(orig, in: manual), false)
        // Tier 3+4: English
        add(pickLang("en", in: auto), true)
        add(pickLang("en", in: manual), false)
        // Tier 5+6: anything else (alphabetical)
        if let firstAuto = auto.keys.sorted().first { add(firstAuto, true) }
        if let firstManual = manual.keys.sorted().first { add(firstManual, false) }

        return SubsPlan(attempts: attempts)
    }

    static func isFallback(_ langKey: String, original: String?) -> Bool {
        guard let original, !original.isEmpty else { return false }
        let base = original.split(separator: "-").first.map(String.init)?.lowercased() ?? original.lowercased()
        let pickedBase = langKey.split(separator: "-").first.map(String.init)?.lowercased() ?? langKey.lowercased()
        return pickedBase != base
    }
}
