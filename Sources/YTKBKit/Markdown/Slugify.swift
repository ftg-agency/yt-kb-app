import Foundation

/// ASCII kebab-case slug, max length 60 by default.
/// Mirrors `python-slugify` defaults used in yt-kb.py: lowercase, ASCII-fold, hyphen separator.
package enum Slugify {
    package static func slug(_ text: String, maxLength: Int = 60) -> String {
        if text.isEmpty { return "untitled" }

        // 1. Transliterate to ASCII via NFKD + remove diacritics, then attempt Latin-ASCII transform
        var working = text as NSString
        let mutable = NSMutableString(string: working as String)
        // Try Apple's Any-Latin / Latin-ASCII transform; fall back to NFKD strip
        CFStringTransform(mutable as CFMutableString, nil, "Any-Latin; Latin-ASCII; Lower" as CFString, false)
        working = mutable

        // 2. Lowercase, replace non-alnum with hyphens
        let str = (working as String).lowercased()
        var out = ""
        var lastWasHyphen = true
        for ch in str.unicodeScalars {
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") {
                out.unicodeScalars.append(ch)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        // 3. Trim hyphens
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }

        if out.isEmpty { return "untitled" }

        // 4. Truncate to maxLength on a hyphen boundary if possible
        if out.count > maxLength {
            let idx = out.index(out.startIndex, offsetBy: maxLength)
            var truncated = String(out[..<idx])
            if let lastHyphen = truncated.lastIndex(of: "-"), truncated.distance(from: truncated.startIndex, to: lastHyphen) > maxLength / 2 {
                truncated = String(truncated[..<lastHyphen])
            }
            while truncated.hasSuffix("-") { truncated.removeLast() }
            out = truncated.isEmpty ? "untitled" : truncated
        }
        return out
    }
}
