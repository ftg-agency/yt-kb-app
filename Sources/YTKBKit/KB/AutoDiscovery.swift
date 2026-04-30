import Foundation

struct DiscoveredChannel: Equatable {
    let name: String
    let url: String
    let folderName: String
    let videoCount: Int
}

/// Walk a KB root, find per-channel sub-folders, and read each one's
/// channel name + URL — either from `index.md` or from the first video's
/// frontmatter. Used when the user picks an existing KB folder so we can
/// pre-populate the tracked-channels list.
enum AutoDiscovery {
    static func discover(in kbRoot: URL) -> [DiscoveredChannel] {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: kbRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var found: [DiscoveredChannel] = []
        for subdir in subdirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subdir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let mds = (try? fm.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil)) ?? []
            let videos = mds.filter { $0.pathExtension == "md" && $0.lastPathComponent != "index.md" }
            guard !videos.isEmpty else { continue }

            // Try index.md first
            let indexURL = subdir.appendingPathComponent("index.md")
            var name: String?
            var url: String?
            if let indexData = try? String(contentsOf: indexURL, encoding: .utf8) {
                let extracted = parseIndex(indexData)
                name = extracted.name
                url = extracted.url
            }

            // Fall back to first video's frontmatter
            if name == nil || url == nil {
                if let videoMD = videos.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first,
                   let content = try? String(contentsOf: videoMD, encoding: .utf8) {
                    let frontmatter = parseFrontmatter(content)
                    if name == nil { name = frontmatter["channel"] }
                    if url == nil { url = frontmatter["channel_url"] }
                }
            }

            guard let resolvedName = name, !resolvedName.isEmpty,
                  let resolvedURL = url, !resolvedURL.isEmpty else {
                continue
            }
            found.append(DiscoveredChannel(
                name: resolvedName,
                url: resolvedURL,
                folderName: subdir.lastPathComponent,
                videoCount: videos.count
            ))
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Header of `index.md` looks like:
    ///   # <Channel Name>
    ///
    ///   **Канал:** <url>
    private static func parseIndex(_ content: String) -> (name: String?, url: String?) {
        var name: String?
        var url: String?
        for line in content.split(separator: "\n").prefix(20) {
            let s = String(line)
            if name == nil, s.hasPrefix("# ") {
                name = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if url == nil, s.contains("**Канал:**") {
                url = s.replacingOccurrences(of: "**Канал:**", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return (name, url)
    }

    /// Parse simple key:value pairs from YAML frontmatter region.
    private static func parseFrontmatter(_ content: String) -> [String: String] {
        guard content.hasPrefix("---") else { return [:] }
        guard let end = content.range(of: "\n---", range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex) else {
            return [:]
        }
        let region = content[content.startIndex..<end.lowerBound]
        var dict: [String: String] = [:]
        for line in region.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            dict[key] = value
        }
        return dict
    }
}
