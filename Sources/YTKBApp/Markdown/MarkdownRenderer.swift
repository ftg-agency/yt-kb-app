import Foundation

enum MarkdownRenderer {
    static let chunkSeconds: Double = 150

    static func render(meta: VideoMetadata, transcript: Transcript) -> String {
        let title = meta.title ?? meta.id
        let channel = meta.displayChannel
        let channelURL = meta.displayChannelURL
        let videoURL = meta.canonicalURL
        let published = formatDate(meta.uploadDate)
        let durationStr = meta.duration.map { formatTimestamp($0) } ?? ""
        let viewCount = meta.viewCount
        let description = (meta.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(yamlQuote(title))")
        lines.append("channel: \(yamlQuote(channel))")
        if !channelURL.isEmpty { lines.append("channel_url: \(yamlQuote(channelURL))") }
        lines.append("video_id: \(yamlQuote(meta.id))")
        lines.append("url: \(yamlQuote(videoURL))")
        if let published { lines.append("published: \(published)") }
        if !durationStr.isEmpty { lines.append("duration: \(durationStr)") }
        if let vc = viewCount { lines.append("view_count: \(vc)") }
        lines.append("language: \(yamlQuote(transcript.language))")
        lines.append("source: \(yamlQuote(transcript.source))")
        if transcript.isFallback {
            lines.append("fallback_from: \(yamlQuote(meta.language ?? meta.originalLanguage ?? "?"))")
        }
        let today = DateFormatter.iso8601Date.string(from: Date())
        lines.append("transcribed_at: \(today)")
        lines.append("---")
        lines.append("")
        lines.append("# \(title)")
        lines.append("")
        lines.append("**Канал:** [\(channel)](\(channelURL))  ")
        lines.append("**Ссылка:** \(videoURL)  ")
        if let published { lines.append("**Дата:** \(published)  ") }
        if !durationStr.isEmpty { lines.append("**Длительность:** \(durationStr)  ") }
        if let vc = viewCount { lines.append("**Просмотров:** \(formatViewsFull(vc))  ") }
        lines.append("**Источник транскрипта:** \(transcript.source)")
        lines.append("")

        if !description.isEmpty {
            lines.append("<details><summary>Описание видео</summary>")
            lines.append("")
            lines.append(description)
            lines.append("")
            lines.append("</details>")
            lines.append("")
        }

        lines.append("## Транскрипт")
        lines.append("")
        for chunk in chunk(transcript.segments) where !chunk.isEmpty {
            let ts = formatTimestamp(chunk[0].start)
            lines.append("### [\(ts)](\(videoURL)&t=\(Int(chunk[0].start))s)")
            lines.append("")
            let text = chunk.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    static func chunk(_ segments: [Segment], window: Double = chunkSeconds) -> [[Segment]] {
        guard !segments.isEmpty else { return [] }
        var chunks: [[Segment]] = [[]]
        var chunkStart = segments[0].start
        for seg in segments {
            if seg.start - chunkStart >= window && !chunks[chunks.count - 1].isEmpty {
                chunks.append([])
                chunkStart = seg.start
            }
            chunks[chunks.count - 1].append(seg)
        }
        return chunks
    }

    static func formatTimestamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }

    /// "20240315" → "2024-03-15"
    static func formatDate(_ uploadDate: String?) -> String? {
        guard let d = uploadDate, d.count == 8 else { return nil }
        let chars = Array(d)
        return "\(String(chars[0..<4]))-\(String(chars[4..<6]))-\(String(chars[6..<8]))"
    }

    static func formatViewsCompact(_ n: Int?) -> String {
        guard let n else { return "—" }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return String(n)
    }

    static func formatViewsFull(_ n: Int?) -> String {
        guard let n else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func yamlQuote(_ value: String?) -> String {
        guard let value else { return "\"\"" }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

extension DateFormatter {
    static let iso8601Date: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
