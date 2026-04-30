import Foundation

package struct SubsPlan {
    package struct Attempt: Equatable {
        package let langKey: String
        package let isAuto: Bool
        package init(langKey: String, isAuto: Bool) {
            self.langKey = langKey
            self.isAuto = isAuto
        }
    }
    package let attempts: [Attempt]
    package init(attempts: [Attempt]) { self.attempts = attempts }
}

package enum SubsPlanner {
    /// Pick a language key matching `desired` from the available track keys.
    /// Tries exact, then prefix (so "en" matches "en-US"). Returns nil if none.
    package static func pickLang(_ desired: String?, in tracks: [String: [SubFormat]]?) -> String? {
        guard let desired, !desired.isEmpty, let tracks, !tracks.isEmpty else { return nil }
        if tracks[desired] != nil { return desired }
        let base = desired.split(separator: "-").first.map(String.init)?.lowercased() ?? desired.lowercased()
        for key in tracks.keys {
            let keyBase = key.split(separator: "-").first.map(String.init)?.lowercased() ?? key.lowercased()
            if keyBase == base { return key }
        }
        return nil
    }

    /// Build a deduplicated, ordered priority plan based on user-configured `languagePriority`.
    /// Special tokens (top-down):
    ///   "@original" — video's original audio language
    ///   "@english"  — English fallback
    ///   "@any"      — first alphabetical key in (auto), then (manual)
    /// Other strings are treated as raw BCP-47 language codes (e.g. "ru", "fr-FR").
    /// For each requested language, both auto-subs and manual-subs are tried (auto first).
    package static func buildPlan(meta: VideoMetadata, languagePriority: [String] = ["@original", "@english", "@any"]) -> SubsPlan {
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

        for token in languagePriority {
            switch token {
            case "@original":
                add(pickLang(orig, in: auto), true)
                add(pickLang(orig, in: manual), false)
            case "@english":
                add(pickLang("en", in: auto), true)
                add(pickLang("en", in: manual), false)
            case "@any":
                if let firstAuto = auto.keys.sorted().first { add(firstAuto, true) }
                if let firstManual = manual.keys.sorted().first { add(firstManual, false) }
            default:
                add(pickLang(token, in: auto), true)
                add(pickLang(token, in: manual), false)
            }
        }

        return SubsPlan(attempts: attempts)
    }

    package static func isFallback(_ langKey: String, original: String?) -> Bool {
        guard let original, !original.isEmpty else { return false }
        let base = original.split(separator: "-").first.map(String.init)?.lowercased() ?? original.lowercased()
        let pickedBase = langKey.split(separator: "-").first.map(String.init)?.lowercased() ?? langKey.lowercased()
        return pickedBase != base
    }
}
