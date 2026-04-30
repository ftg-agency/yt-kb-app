import Foundation
import YTKBKit

@MainActor
func scannerTests() {
    TestHarness.test("Empty directory returns empty") {
        let root = makeTmpDir()
        let result = KBScanner.scanExistingIds(in: root)
        try expectTrue(result.isEmpty)
    }

    TestHarness.test("Non-existent directory returns empty") {
        let root = makeTmpDir()
        let bogus = root.appendingPathComponent("nope")
        let result = KBScanner.scanExistingIds(in: bogus)
        try expectTrue(result.isEmpty)
    }

    TestHarness.test("Extracts valid 11-char video IDs") {
        let root = makeTmpDir()
        let channelDir = root.appendingPathComponent("test-channel-abc123")
        try FileManager.default.createDirectory(at: channelDir, withIntermediateDirectories: true)
        try touchFile(at: channelDir.appendingPathComponent("2024-03-15-some-title-dQw4w9WgXcQ.md"))
        let result = KBScanner.scanExistingIds(in: root)
        try expectEq(result.count, 1)
        try expectNotNil(result["dQw4w9WgXcQ"])
    }

    TestHarness.test("Ignores index.md") {
        let root = makeTmpDir()
        let channelDir = root.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: channelDir, withIntermediateDirectories: true)
        try touchFile(at: channelDir.appendingPathComponent("index.md"))
        try touchFile(at: channelDir.appendingPathComponent("2024-01-01-title-AAAAAAAAAAA.md"))
        let result = KBScanner.scanExistingIds(in: root)
        try expectEq(result.count, 1)
        try expectNotNil(result["AAAAAAAAAAA"])
    }

    TestHarness.test("Bare-name file with no hyphen+11 prefix is not matched") {
        let root = makeTmpDir()
        let channelDir = root.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: channelDir, withIntermediateDirectories: true)
        try touchFile(at: channelDir.appendingPathComponent("ABCDE.md"))
        let result = KBScanner.scanExistingIds(in: root)
        try expectEq(result.count, 0)
    }

    TestHarness.test("Filename whose 11-char window is not preceded by '-' is not matched") {
        let root = makeTmpDir()
        let channelDir = root.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: channelDir, withIntermediateDirectories: true)
        // 16-char alphanumeric block: 11 chars before .md = "FGHIJKLMNOP", preceded by "E", not "-"
        try touchFile(at: channelDir.appendingPathComponent("ABCDEFGHIJKLMNOP.md"))
        let result = KBScanner.scanExistingIds(in: root)
        try expectEq(result.count, 0)
    }

    TestHarness.test("Hyphen inside the captured 11 chars is allowed (matches Python yt-kb regex)") {
        // The regex [\w-]{11} permits hyphens within the id — real YouTube ids use them.
        // For "2024-short-ABCDE.md" the capture is "short-ABCDE" (11 chars, hyphen-internal).
        let root = makeTmpDir()
        let channelDir = root.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: channelDir, withIntermediateDirectories: true)
        try touchFile(at: channelDir.appendingPathComponent("2024-short-ABCDE.md"))
        let result = KBScanner.scanExistingIds(in: root)
        try expectEq(result.count, 1)
        try expectNotNil(result["short-ABCDE"])
    }

    TestHarness.test("Allows hyphen and underscore in id") {
        let root = makeTmpDir()
        let channelDir = root.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: channelDir, withIntermediateDirectories: true)
        try touchFile(at: channelDir.appendingPathComponent("2024-01-01-with-XyZ_abc-DeF.md"))
        let result = KBScanner.scanExistingIds(in: root)
        try expectEq(result["XyZ_abc-DeF"]?.lastPathComponent, "2024-01-01-with-XyZ_abc-DeF.md")
    }

    TestHarness.test("Recurses into subdirs") {
        let root = makeTmpDir()
        let nested = root.appendingPathComponent("channelA").appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try touchFile(at: nested.appendingPathComponent("2024-01-01-deep-VIDEOAAAAAA.md"))
        let result = KBScanner.scanExistingIds(in: root)
        try expectEq(result.count, 1)
        try expectNotNil(result["VIDEOAAAAAA"])
    }

    TestHarness.test("Ignores non-md files") {
        let root = makeTmpDir()
        let channelDir = root.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: channelDir, withIntermediateDirectories: true)
        try touchFile(at: channelDir.appendingPathComponent("2024-01-01-title-AAAAAAAAAAA.txt"))
        try touchFile(at: channelDir.appendingPathComponent("2024-01-01-title-BBBBBBBBBBB.md"))
        let result = KBScanner.scanExistingIds(in: root)
        try expectEq(result.count, 1)
        try expectNotNil(result["BBBBBBBBBBB"])
    }
}

@MainActor
private func makeTmpDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ytkb-scanner-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    TestHarness.addTeardown { try? FileManager.default.removeItem(at: url) }
    return url
}

private func touchFile(at url: URL) throws {
    try Data().write(to: url)
}
