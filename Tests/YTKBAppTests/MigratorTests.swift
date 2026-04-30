import Foundation
import YTKBKit

@MainActor
func migratorTests() {
    TestHarness.test("hasContent returns false for empty directory") {
        let dir = makeTmpDir()
        try expectFalse(KBMigrator.hasContent(at: dir))
    }

    TestHarness.test("hasContent returns true if any .md is nested anywhere") {
        let dir = makeTmpDir()
        let nested = dir.appendingPathComponent("c1/sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("video-AAAAAAAAAAA.md"))
        try expectTrue(KBMigrator.hasContent(at: dir))
    }

    TestHarness.test("hasContent ignores non-md files") {
        let dir = makeTmpDir()
        try Data().write(to: dir.appendingPathComponent("readme.txt"))
        try expectFalse(KBMigrator.hasContent(at: dir))
    }

    TestHarness.test("migrate moves files preserving subfolder structure") {
        let oldRoot = makeTmpDir()
        let newRoot = makeTmpDir()

        let channelA = oldRoot.appendingPathComponent("channel-a-abc123")
        let channelB = oldRoot.appendingPathComponent("channel-b-def456")
        try FileManager.default.createDirectory(at: channelA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: channelB, withIntermediateDirectories: true)

        let aFile = channelA.appendingPathComponent("2024-01-01-foo-AAAAAAAAAAA.md")
        let bFile = channelB.appendingPathComponent("2024-01-02-bar-BBBBBBBBBBB.md")
        try "content A".write(to: aFile, atomically: true, encoding: .utf8)
        try "content B".write(to: bFile, atomically: true, encoding: .utf8)

        let report = KBMigrator.migrate(from: oldRoot, to: newRoot)

        try expectEq(report.copied, 2)
        try expectEq(report.failed.count, 0)
        try expectTrue(FileManager.default.fileExists(atPath: newRoot.appendingPathComponent("channel-a-abc123/2024-01-01-foo-AAAAAAAAAAA.md").path))
        try expectTrue(FileManager.default.fileExists(atPath: newRoot.appendingPathComponent("channel-b-def456/2024-01-02-bar-BBBBBBBBBBB.md").path))
        // Source files removed
        try expectFalse(FileManager.default.fileExists(atPath: aFile.path))
        try expectFalse(FileManager.default.fileExists(atPath: bFile.path))
    }

    TestHarness.test("migrate skips files already in destination") {
        let oldRoot = makeTmpDir()
        let newRoot = makeTmpDir()
        let oldA = oldRoot.appendingPathComponent("channel/a.md")
        let newA = newRoot.appendingPathComponent("channel/a.md")
        try FileManager.default.createDirectory(at: oldA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old".write(to: oldA, atomically: true, encoding: .utf8)
        try "new".write(to: newA, atomically: true, encoding: .utf8)

        let report = KBMigrator.migrate(from: oldRoot, to: newRoot)
        try expectEq(report.copied, 0)
        try expectEq(report.skipped, 1)
        // Destination preserves "new" content (we don't overwrite)
        let dstContent = try String(contentsOf: newA, encoding: .utf8)
        try expectEq(dstContent, "new")
    }
}

@MainActor
private func makeTmpDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ytkb-mig-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    TestHarness.addTeardown { try? FileManager.default.removeItem(at: url) }
    return url
}
