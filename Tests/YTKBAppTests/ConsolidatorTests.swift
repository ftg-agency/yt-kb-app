import Foundation
import YTKBKit

@MainActor
func consolidatorTests() {
    TestHarness.test("Single canonical folder: pins folderName, no I/O") {
        let kb = makeTmpDir()
        let dir = kb.appendingPathComponent("alex-hormozi")
        try writeChannelFolder(dir, name: "Alex Hormozi", url: "https://www.youtube.com/@AlexHormozi")

        let channel = makeChannel(name: "Alex Hormozi", url: "https://www.youtube.com/@AlexHormozi")
        let report = KBConsolidator.consolidate(kbRoot: kb, channels: [channel])

        try expectEq(report.outcomes.count, 1)
        try expectEq(report.outcomes[0].folderName, "alex-hormozi")
        try expectFalse(report.outcomes[0].renamed)
        try expectEq(report.outcomes[0].merged, 0)
        try expectTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    TestHarness.test("Single legacy-named folder: rename to canonical") {
        let kb = makeTmpDir()
        let legacy = kb.appendingPathComponent("alex-hormozi-46d-zw")
        try writeChannelFolder(legacy, name: "Alex Hormozi", url: "https://www.youtube.com/@AlexHormozi")

        let channel = makeChannel(name: "Alex Hormozi", url: "https://www.youtube.com/@AlexHormozi")
        let report = KBConsolidator.consolidate(kbRoot: kb, channels: [channel])

        try expectEq(report.outcomes.count, 1)
        try expectEq(report.outcomes[0].folderName, "alex-hormozi")
        try expectTrue(report.outcomes[0].renamed)
        try expectEq(report.outcomes[0].merged, 0)
        try expectFalse(FileManager.default.fileExists(atPath: legacy.path))
        try expectTrue(FileManager.default.fileExists(atPath: kb.appendingPathComponent("alex-hormozi").path))
    }

    TestHarness.test("Two folders for one channel: merge legacy into canonical") {
        let kb = makeTmpDir()
        let legacy = kb.appendingPathComponent("gleb-shkut-i0ep9w")
        let canonical = kb.appendingPathComponent("gleb-shkut")
        try writeChannelFolder(legacy, name: "Gleb Shkut", url: "https://www.youtube.com/channel/UCZmHx1F4DeyMjOxzdi0Ep9w", videoCount: 5)
        try writeChannelFolder(canonical, name: "Gleb Shkut", url: "https://www.youtube.com/channel/UCZmHx1F4DeyMjOxzdi0Ep9w", videoCount: 1)

        let channel = makeChannel(name: "Gleb Shkut", url: "https://www.youtube.com/channel/UCZmHx1F4DeyMjOxzdi0Ep9w")
        let report = KBConsolidator.consolidate(kbRoot: kb, channels: [channel])

        try expectEq(report.outcomes.count, 1)
        try expectEq(report.outcomes[0].folderName, "gleb-shkut")
        try expectFalse(report.outcomes[0].renamed)
        try expectEq(report.outcomes[0].merged, 1)
        try expectFalse(FileManager.default.fileExists(atPath: legacy.path))
        // Canonical folder now has both: 5 from legacy + 1 originally there.
        // index.md gets overwritten on dup; that's fine — next poll regenerates.
        let mds = try FileManager.default.contentsOfDirectory(atPath: canonical.path).filter { $0.hasSuffix(".md") && $0 != "index.md" }
        try expectEq(mds.count, 6)
    }

    TestHarness.test("Idempotent: second run is a no-op") {
        let kb = makeTmpDir()
        let legacy = kb.appendingPathComponent("gleb-shkut-i0ep9w")
        try writeChannelFolder(legacy, name: "Gleb Shkut", url: "https://www.youtube.com/channel/UCZmHx1F4DeyMjOxzdi0Ep9w", videoCount: 3)

        let channel = makeChannel(name: "Gleb Shkut", url: "https://www.youtube.com/channel/UCZmHx1F4DeyMjOxzdi0Ep9w")
        _ = KBConsolidator.consolidate(kbRoot: kb, channels: [channel])

        // Pretend the persisted folderName is now set (simulating bootstrap).
        let pinned = makeChannel(name: "Gleb Shkut", url: "https://www.youtube.com/channel/UCZmHx1F4DeyMjOxzdi0Ep9w", folderName: "gleb-shkut")
        let report2 = KBConsolidator.consolidate(kbRoot: kb, channels: [pinned])

        try expectEq(report2.outcomes.count, 1)
        try expectEq(report2.outcomes[0].folderName, "gleb-shkut")
        try expectFalse(report2.outcomes[0].renamed)
        try expectEq(report2.outcomes[0].merged, 0)
    }

    TestHarness.test("URL trailing slash mismatch still groups together") {
        let kb = makeTmpDir()
        let legacy = kb.appendingPathComponent("alex-hormozi-46d-zw")
        // Folder writes URL without trailing slash; tracked channel has trailing slash.
        try writeChannelFolder(legacy, name: "Alex Hormozi", url: "https://www.youtube.com/@AlexHormozi")

        let channel = makeChannel(name: "Alex Hormozi", url: "https://www.youtube.com/@AlexHormozi/")
        let report = KBConsolidator.consolidate(kbRoot: kb, channels: [channel])

        try expectEq(report.outcomes[0].folderName, "alex-hormozi")
        try expectTrue(report.outcomes[0].renamed)
    }

    TestHarness.test("Channel with no folder on disk: outcome preserves nil folderName") {
        let kb = makeTmpDir()
        // Folder for a *different* channel only.
        let other = kb.appendingPathComponent("other")
        try writeChannelFolder(other, name: "Other", url: "https://www.youtube.com/@Other")

        let channel = makeChannel(name: "Ghost", url: "https://www.youtube.com/@Ghost")
        let report = KBConsolidator.consolidate(kbRoot: kb, channels: [channel])

        try expectEq(report.outcomes.count, 1)
        try expectNil(report.outcomes[0].folderName)
        try expectEq(report.outcomes[0].merged, 0)
        try expectFalse(report.outcomes[0].renamed)
    }

    TestHarness.test("existingFolderName: returns folder for known URL, nil otherwise") {
        let kb = makeTmpDir()
        let dir = kb.appendingPathComponent("known-channel")
        try writeChannelFolder(dir, name: "Known", url: "https://www.youtube.com/@Known")

        try expectEq(KBConsolidator.existingFolderName(forURL: "https://www.youtube.com/@Known", in: kb), "known-channel")
        try expectEq(KBConsolidator.existingFolderName(forURL: "https://www.youtube.com/@Known/", in: kb), "known-channel")
        try expectNil(KBConsolidator.existingFolderName(forURL: "https://www.youtube.com/@Other", in: kb))
    }

    TestHarness.test("normalizeURL: strips trailing slashes and whitespace") {
        try expectEq(KBConsolidator.normalizeURL("  https://x.com/@a  "), "https://x.com/@a")
        try expectEq(KBConsolidator.normalizeURL("https://x.com/@a/"), "https://x.com/@a")
        try expectEq(KBConsolidator.normalizeURL("https://x.com/@a"), "https://x.com/@a")
    }

    TestHarness.test("TrackedChannel decodes legacy state.json without folderName") {
        let json = """
        {
          "url": "https://www.youtube.com/@A",
          "name": "A",
          "addedAt": "2024-01-01T00:00:00Z",
          "enabled": true
        }
        """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let ch = try dec.decode(TrackedChannel.self, from: json)
        try expectEq(ch.url, "https://www.youtube.com/@A")
        try expectNil(ch.folderName)
    }
}

@MainActor
private func makeTmpDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ytkb-cons-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    TestHarness.addTeardown { try? FileManager.default.removeItem(at: url) }
    return url
}

private func makeChannel(name: String, url: String, folderName: String? = nil) -> TrackedChannel {
    TrackedChannel(
        url: url,
        channelId: nil,
        name: name,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000),
        folderName: folderName
    )
}

/// Write a minimal channel folder with an `index.md` AutoDiscovery can parse,
/// plus `videoCount` dummy `.md` files so KBScanner-style file enumeration sees content.
private func writeChannelFolder(_ dir: URL, name: String, url: String, videoCount: Int = 1) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let index = """
    # \(name)

    **Канал:** \(url)

    **Видео в базе:** \(videoCount)
    """
    try index.write(to: dir.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    for i in 0..<videoCount {
        // 11-char id placeholder unique per dir+i to avoid KBMigrator-skip collisions
        // when two folders are merged in the multi-folder test.
        let prefix = (dir.lastPathComponent + String(i)).replacingOccurrences(of: "-", with: "").prefix(8)
        let id = (prefix + "AAAAAAAAAAA").prefix(11)
        let fname = "2024-01-0\(i % 9 + 1)-video-\(id).md"
        let body = """
        ---
        title: "Video \(i)"
        channel: \"\(name)\"
        channel_url: \"\(url)\"
        video_id: \"\(id)\"
        ---
        # Video \(i)
        """
        try body.write(to: dir.appendingPathComponent(fname), atomically: true, encoding: .utf8)
    }
}
