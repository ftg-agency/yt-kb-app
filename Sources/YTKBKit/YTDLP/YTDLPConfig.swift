import Foundation

/// Immutable, Sendable snapshot of the user-facing settings that the YT-DLP actors care about.
/// Built on @MainActor from `Settings`, then handed to actor inits — so no `@Published` /
/// non-Sendable mutable state crosses actor boundaries.
struct YTDLPConfig: Sendable {
    let browserKey: String?
    let languagePriority: [String]

    var hasCookies: Bool { browserKey != nil }

    var baseArgs: [String] {
        var args: [String] = []
        if let key = browserKey {
            args.append(contentsOf: ["--cookies-from-browser", key])
        }
        return args
    }

    /// Same as `baseArgs` but with any cookies-related flags removed.
    var argsWithoutCookies: [String] {
        var out: [String] = []
        var i = 0
        let src = baseArgs
        while i < src.count {
            let opt = src[i]
            if opt == "--cookies-from-browser" || opt == "--cookies" {
                i += 2
                continue
            }
            out.append(opt)
            i += 1
        }
        return out
    }
}

@MainActor
extension Settings {
    var ytdlpConfig: YTDLPConfig {
        YTDLPConfig(
            browserKey: browser.ytDlpKey,
            languagePriority: languagePriority
        )
    }
}
