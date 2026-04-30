import Foundation
import YTKBKit

@MainActor
func markdownTests() {
    TestHarness.test("formatTimestamp covers boundaries") {
        try expectEq(MarkdownRenderer.formatTimestamp(0), "00:00:00")
        try expectEq(MarkdownRenderer.formatTimestamp(75), "00:01:15")
        try expectEq(MarkdownRenderer.formatTimestamp(3661), "01:01:01")
        try expectEq(MarkdownRenderer.formatTimestamp(86399.9), "23:59:59")
    }

    TestHarness.test("formatDate parses YYYYMMDD") {
        try expectEq(MarkdownRenderer.formatDate("20240315"), "2024-03-15")
        try expectEq(MarkdownRenderer.formatDate("19990101"), "1999-01-01")
        try expectNil(MarkdownRenderer.formatDate(nil))
        try expectNil(MarkdownRenderer.formatDate(""))
        try expectNil(MarkdownRenderer.formatDate("2024-03-15"))
    }

    TestHarness.test("formatViewsCompact produces K/M") {
        try expectEq(MarkdownRenderer.formatViewsCompact(nil), "—")
        try expectEq(MarkdownRenderer.formatViewsCompact(0), "0")
        try expectEq(MarkdownRenderer.formatViewsCompact(999), "999")
        try expectEq(MarkdownRenderer.formatViewsCompact(1234), "1.2K")
        try expectEq(MarkdownRenderer.formatViewsCompact(1_234_567), "1.2M")
    }

    TestHarness.test("formatViewsFull groups thousands") {
        try expectEq(MarkdownRenderer.formatViewsFull(nil), "—")
        let formatted = MarkdownRenderer.formatViewsFull(12345)
        try expectContains(formatted, "12")
        try expectContains(formatted, "345")
    }

    TestHarness.test("yamlQuote escapes correctly") {
        try expectEq(MarkdownRenderer.yamlQuote("foo"), "\"foo\"")
        try expectEq(MarkdownRenderer.yamlQuote(nil), "\"\"")
        try expectEq(MarkdownRenderer.yamlQuote("with \"quotes\""), "\"with \\\"quotes\\\"\"")
        try expectEq(MarkdownRenderer.yamlQuote("back\\slash"), "\"back\\\\slash\"")
    }

    TestHarness.test("chunk respects window") {
        let segs = (0..<10).map { i in
            Segment(start: Double(i) * 60, end: Double(i + 1) * 60, text: "seg\(i)")
        }
        let chunks = MarkdownRenderer.chunk(segs, window: 150)
        try expectEq(chunks.count, 4)
        try expectFalse(chunks.contains(where: \.isEmpty))
    }

    TestHarness.test("chunk empty input returns empty") {
        try expectTrue(MarkdownRenderer.chunk([]).isEmpty)
    }

    TestHarness.test("render produces all expected sections") {
        let meta = makeMeta(
            id: "VIDEOID1234",
            title: "Test Video",
            channel: "Test Channel",
            channelUrl: "https://www.youtube.com/@test",
            uploadDate: "20240315",
            duration: 125.0,
            viewCount: 1234,
            description: "A short test description.",
            language: "en"
        )
        let transcript = Transcript(
            segments: [
                Segment(start: 0, end: 60, text: "first chunk text"),
                Segment(start: 60, end: 120, text: "still first chunk"),
                Segment(start: 200, end: 260, text: "second chunk text")
            ],
            language: "en",
            source: "auto-subs",
            isFallback: false
        )
        let md = MarkdownRenderer.render(meta: meta, transcript: transcript)

        try expectTrue(md.hasPrefix("---\n"))
        try expectContains(md, "title: \"Test Video\"")
        try expectContains(md, "video_id: \"VIDEOID1234\"")
        try expectContains(md, "source: \"auto-subs\"")
        try expectContains(md, "language: \"en\"")
        try expectContains(md, "# Test Video")
        try expectContains(md, "**Канал:** [Test Channel](https://www.youtube.com/@test)")
        try expectContains(md, "**Длительность:** 00:02:05")
        try expectContains(md, "<details><summary>Описание видео</summary>")
        try expectContains(md, "## Транскрипт")
        try expectContains(md, "### [00:00:00](")
        try expectFalse(md.contains("fallback_from"), "fallback_from should NOT appear when isFallback=false")
    }

    TestHarness.test("render emits fallback_from when isFallback=true") {
        let meta = makeMeta(id: "X", title: "Y", language: "ru")
        let transcript = Transcript(
            segments: [Segment(start: 0, end: 1, text: "hi")],
            language: "en",
            source: "auto-subs",
            isFallback: true
        )
        let md = MarkdownRenderer.render(meta: meta, transcript: transcript)
        try expectContains(md, "fallback_from: \"ru\"")
    }
}

private func makeMeta(
    id: String,
    title: String,
    channel: String? = nil,
    channelUrl: String? = nil,
    uploadDate: String? = nil,
    duration: Double? = nil,
    viewCount: Int? = nil,
    description: String? = nil,
    language: String? = nil
) -> VideoMetadata {
    var dict: [String: Any] = ["id": id, "title": title]
    if let channel { dict["channel"] = channel }
    if let channelUrl { dict["channel_url"] = channelUrl }
    if let uploadDate { dict["upload_date"] = uploadDate }
    if let duration { dict["duration"] = duration }
    if let viewCount { dict["view_count"] = viewCount }
    if let description { dict["description"] = description }
    if let language { dict["language"] = language }
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(VideoMetadata.self, from: data)
}
