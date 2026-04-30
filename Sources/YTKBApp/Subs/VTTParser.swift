import Foundation

enum VTTParser {
    private static let timestampRegex: NSRegularExpression = {
        // 00:00:01.234 --> 00:00:05.678
        let pattern = #"(\d{2}):(\d{2}):(\d{2})\.(\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})\.(\d{3})"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let tagRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "<[^>]+>")
    }()

    static func parse(at url: URL) throws -> [Segment] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var segments: [Segment] = []
        var currentStart: Double?
        var currentEnd: Double?
        var currentLines: [String] = []

        func flush() {
            if let start = currentStart, !currentLines.isEmpty {
                let joined = currentLines
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let textNoTags = stripTags(joined).trimmingCharacters(in: .whitespacesAndNewlines)
                if !textNoTags.isEmpty {
                    segments.append(Segment(start: start, end: currentEnd ?? start, text: textNoTags))
                }
            }
            currentStart = nil
            currentEnd = nil
            currentLines = []
        }

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).replacingOccurrences(of: "\r", with: "")
            if line.isEmpty {
                flush()
                continue
            }
            if let ts = parseTimestamp(line) {
                flush()
                currentStart = ts.start
                currentEnd = ts.end
                continue
            }
            if line.hasPrefix("WEBVTT") || line.hasPrefix("NOTE") || line.hasPrefix("Kind:") || line.hasPrefix("Language:") {
                continue
            }
            if currentStart != nil {
                currentLines.append(line)
            }
        }
        flush()
        return dedupe(segments)
    }

    /// Dedup rolling auto-captions: collapse "ABC" + "ABC DEF" → "ABC DEF".
    static func dedupe(_ segs: [Segment]) -> [Segment] {
        guard !segs.isEmpty else { return segs }
        var out: [Segment] = []
        var seen: Set<String> = []
        for s in segs {
            let key = s.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if seen.contains(key) { continue }
            if let last = out.last, s.text.hasPrefix(last.text), s.text != last.text {
                out[out.count - 1] = Segment(start: last.start, end: s.end, text: s.text)
                seen.insert(key)
                continue
            }
            out.append(s)
            seen.insert(key)
        }
        return out
    }

    private struct Timestamp {
        let start: Double
        let end: Double
    }

    private static func parseTimestamp(_ line: String) -> Timestamp? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let m = timestampRegex.firstMatch(in: line, options: [], range: range), m.numberOfRanges == 9 else {
            return nil
        }
        func group(_ i: Int) -> Int {
            guard let r = Range(m.range(at: i), in: line) else { return 0 }
            return Int(line[r]) ?? 0
        }
        let start = Double(group(1)) * 3600 + Double(group(2)) * 60 + Double(group(3)) + Double(group(4)) / 1000.0
        let end = Double(group(5)) * 3600 + Double(group(6)) * 60 + Double(group(7)) + Double(group(8)) / 1000.0
        return Timestamp(start: start, end: end)
    }

    private static func stripTags(_ s: String) -> String {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return tagRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }
}

/// Dispatch by extension. Phase 1: only VTT. SRV3/JSON3 stubs reject for now.
enum SubsDispatcher {
    static func parse(_ file: DownloadedSubFile) -> [Segment] {
        switch file.ext {
        case "vtt":
            return (try? VTTParser.parse(at: file.url)) ?? []
        case "srv3", "json3":
            // Phase 2 — we accept the format from yt-dlp but can't parse yet.
            Logger.shared.warn("SRV3/JSON3 parsing not yet implemented (file: \(file.url.lastPathComponent))")
            return []
        default:
            return []
        }
    }
}
