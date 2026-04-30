import Foundation
import YTKBKit

@MainActor
func parserTests() {
    TestHarness.test("VTT parses with rolling-cap dedup") {
        guard let url = TestFixtures.url("sample", ext: "vtt") else {
            try expect(false, "fixture missing")
            return
        }
        let segments = try VTTParser.parse(at: url)
        try expectEq(segments.count, 3, "VTT should dedupe 5→3 with rolling captions")
        try expectTrue(segments[0].text.hasSuffix("show today"))
        try expectClose(segments[0].start, 0.5)
        try expectContains(segments[1].text, "auto-captions")
        try expectFalse(segments[1].text.contains("<"), "VTT tags must be stripped")
        try expectContains(segments.last?.text ?? "", "a few formats")
    }

    TestHarness.test("VTT empty cue body produces no segments") {
        let url = tempVTT("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n\n")
        let segments = (try? VTTParser.parse(at: url)) ?? []
        try expectTrue(segments.isEmpty)
    }

    TestHarness.test("VTT skips header/note lines") {
        let raw = "WEBVTT\nNOTE this is a note\nKind: captions\nLanguage: en\n\n00:00:01.000 --> 00:00:02.000\nHello\n"
        let url = tempVTT(raw)
        let segments = (try? VTTParser.parse(at: url)) ?? []
        try expectEq(segments.count, 1)
        try expectEq(segments.first?.text, "Hello")
    }

    TestHarness.test("SRV3 parses and dedupes") {
        guard let url = TestFixtures.url("sample", ext: "srv3") else {
            try expect(false, "fixture missing")
            return
        }
        let segments = SRV3Parser.parse(at: url)
        try expectEq(segments.count, 3, "SRV3 should match VTT after dedup")
        try expectClose(segments[0].start, 0.5)
        try expectContains(segments[1].text, "auto-captions")
        try expectFalse(segments.last?.text.isEmpty ?? true)
    }

    TestHarness.test("SRV3 handles nested <s> spans") {
        let xml = """
        <?xml version="1.0"?>
        <timedtext><body>
        <p t="0" d="1000"><s>foo </s><s>bar</s></p>
        </body></timedtext>
        """
        let url = tempFile(xml, ext: "srv3")
        let segments = SRV3Parser.parse(at: url)
        try expectEq(segments.count, 1)
        try expectEq(segments[0].text, "foo bar")
    }

    TestHarness.test("JSON3 parses and dedupes") {
        guard let url = TestFixtures.url("sample", ext: "json3") else {
            try expect(false, "fixture missing")
            return
        }
        let segments = JSON3Parser.parse(at: url)
        try expectEq(segments.count, 3)
        try expectClose(segments[0].start, 0.5)
        try expectContains(segments[1].text, "auto-captions")
        try expectEq(segments.last?.text, "And how YouTube serves them in a few formats")
    }

    TestHarness.test("JSON3 skips events without segs") {
        let url = tempFile(#"{"events":[{"tStartMs":0,"dDurationMs":1000}]}"#, ext: "json3")
        let segments = JSON3Parser.parse(at: url)
        try expectTrue(segments.isEmpty)
    }

    TestHarness.test("JSON3 joins multiple segs") {
        let url = tempFile(#"{"events":[{"tStartMs":0,"dDurationMs":1000,"segs":[{"utf8":"foo "},{"utf8":"bar "},{"utf8":"baz"}]}]}"#, ext: "json3")
        let segments = JSON3Parser.parse(at: url)
        try expectEq(segments.count, 1)
        try expectEq(segments[0].text, "foo bar baz")
    }

    TestHarness.test("All three formats agree on segment count") {
        guard let vttURL = TestFixtures.url("sample", ext: "vtt"),
              let srv3URL = TestFixtures.url("sample", ext: "srv3"),
              let json3URL = TestFixtures.url("sample", ext: "json3") else {
            try expect(false, "fixtures missing")
            return
        }
        let vtt = try VTTParser.parse(at: vttURL)
        let srv3 = SRV3Parser.parse(at: srv3URL)
        let json3 = JSON3Parser.parse(at: json3URL)
        try expectEq(vtt.count, srv3.count)
        try expectEq(srv3.count, json3.count)
        try expectEq(vtt.last?.text, srv3.last?.text)
        try expectEq(srv3.last?.text, json3.last?.text)
    }

    TestHarness.test("Dedupe collapses rolling captions") {
        let segs = [
            Segment(start: 0, end: 1, text: "Hello"),
            Segment(start: 1, end: 2, text: "Hello world"),
            Segment(start: 2, end: 3, text: "Hello world today"),
            Segment(start: 3, end: 4, text: "Different sentence")
        ]
        let result = VTTParser.dedupe(segs)
        try expectEq(result.count, 2)
        try expectEq(result[0].text, "Hello world today")
        try expectEq(result[0].start, 0)
        try expectEq(result[0].end, 3)
        try expectEq(result[1].text, "Different sentence")
    }

    TestHarness.test("Dedupe removes exact duplicates") {
        let segs = [
            Segment(start: 0, end: 1, text: "Hello"),
            Segment(start: 1, end: 2, text: "Hello"),
            Segment(start: 2, end: 3, text: "World")
        ]
        let result = VTTParser.dedupe(segs)
        try expectEq(result.count, 2)
        try expectEq(result.map(\.text), ["Hello", "World"])
    }

    TestHarness.test("Dispatcher routes to correct parser") {
        for ext in ["vtt", "srv3", "json3"] {
            guard let url = TestFixtures.url("sample", ext: ext) else { continue }
            let segments = SubsDispatcher.parse(DownloadedSubFile(url: url, ext: ext))
            try expectFalse(segments.isEmpty, "Dispatcher should yield segments for \(ext)")
        }
    }

    TestHarness.test("Dispatcher unknown ext returns empty") {
        let url = tempFile("irrelevant", ext: "txt")
        let segments = SubsDispatcher.parse(DownloadedSubFile(url: url, ext: "txt"))
        try expectTrue(segments.isEmpty)
    }
}

@MainActor
private func tempVTT(_ content: String) -> URL {
    tempFile(content, ext: "vtt")
}

@MainActor
private func tempFile(_ content: String, ext: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ytkb-test-\(UUID().uuidString).\(ext)")
    try? content.write(to: url, atomically: true, encoding: .utf8)
    TestHarness.addTeardown { try? FileManager.default.removeItem(at: url) }
    return url
}
