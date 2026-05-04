import Foundation

package enum KBScanner {
    private static let videoIdRegex = try! NSRegularExpression(
        pattern: #"-([\w-]{11})\.md$"#
    )

    /// Count the number of indexed video files inside one channel folder.
    /// Used to populate `TrackedChannel.indexedCount` after each poll cycle so
    /// the popover can show "X / Y" without scanning on every redraw.
    package static func countIndexedVideos(in folder: URL) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return 0 }
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            guard url.pathExtension == "md", url.lastPathComponent != "index.md" else { continue }
            let name = url.lastPathComponent
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if videoIdRegex.firstMatch(in: name, options: [], range: range) != nil {
                count += 1
            }
        }
        return count
    }

    /// Walk the entire KB tree and return {video_id: md_path} for all known videos.
    /// Filename invariant: `<date>-<slug>-<11charID>.md`.
    package static func scanExistingIds(in kbRoot: URL) -> [String: URL] {
        let fm = FileManager.default
        var found: [String: URL] = [:]
        guard fm.fileExists(atPath: kbRoot.path) else { return found }

        guard let enumerator = fm.enumerator(
            at: kbRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return found }

        for case let url as URL in enumerator {
            guard url.pathExtension == "md", url.lastPathComponent != "index.md" else { continue }
            let name = url.lastPathComponent
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let m = videoIdRegex.firstMatch(in: name, options: [], range: range), m.numberOfRanges >= 2 else { continue }
            guard let r = Range(m.range(at: 1), in: name) else { continue }
            found[String(name[r])] = url
        }
        return found
    }
}
