import Foundation

/// Parser for YouTube's `json3` subtitle format.
/// Schema: `{"events": [{"tStartMs": int, "dDurationMs": int, "segs": [{"utf8": "..."}]}]}`.
/// Some events have no segs (chapter markers, silences) — skipped.
package enum JSON3Parser {
    private struct Captions: Decodable {
        let events: [Event]
        struct Event: Decodable {
            let tStartMs: Int?
            let dDurationMs: Int?
            let segs: [Seg]?
        }
        struct Seg: Decodable {
            let utf8: String?
        }
    }

    package static func parse(at url: URL) -> [Segment] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let captions: Captions
        do {
            captions = try JSONDecoder().decode(Captions.self, from: data)
        } catch {
            Logger.shared.warn("JSON3 decode failed: \(error)")
            return []
        }

        var segments: [Segment] = []
        for event in captions.events {
            guard let start = event.tStartMs, let dur = event.dDurationMs else { continue }
            let parts = (event.segs ?? []).compactMap(\.utf8)
            let joined = parts.joined()
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty else { continue }
            segments.append(Segment(
                start: Double(start) / 1000.0,
                end: Double(start + dur) / 1000.0,
                text: joined
            ))
        }
        return VTTParser.dedupe(segments)
    }
}
