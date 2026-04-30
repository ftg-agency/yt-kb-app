import Foundation

package enum ChannelIndexBuilder {
    private static let viewCountRegex = try! NSRegularExpression(
        pattern: #"^view_count:\s*(\d+)\s*$"#,
        options: [.anchorsMatchLines]
    )
    private static let durationRegex = try! NSRegularExpression(
        pattern: #"^duration:\s*"?(\d{2}:\d{2}:\d{2})"?\s*$"#,
        options: [.anchorsMatchLines]
    )

    package static func rebuild(channelDir: URL, channelName: String, channelURL: String) {
        let fm = FileManager.default
        var entries: [(sortKey: String, line: String)] = []
        var totalViews = 0

        let mds = (try? fm.contentsOfDirectory(at: channelDir, includingPropertiesForKeys: nil)) ?? []
        for md in mds.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard md.pathExtension == "md", md.lastPathComponent != "index.md" else { continue }
            let name = md.lastPathComponent
            let sortKey = String(name.prefix(10))  // YYYY-MM-DD
            var title = (name as NSString).deletingPathExtension

            let head = readFrontmatterHead(md)
            // Override title from H1 if present
            if let body = try? String(contentsOf: md, encoding: .utf8) {
                for line in body.split(separator: "\n") {
                    if line.hasPrefix("# ") {
                        title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
            }

            let views = firstMatchInt(viewCountRegex, in: head)
            if let v = views { totalViews += v }
            let duration = firstMatchString(durationRegex, in: head)

            var bits = ["`\(sortKey)`"]
            if let v = views { bits.append("👁 \(MarkdownRenderer.formatViewsCompact(v))") }
            if let d = duration { bits.append("⏱ \(d)") }
            bits.append("[\(title)](\(name))")
            entries.append((sortKey, "- " + bits.joined(separator: " · ")))
        }

        entries.sort { $0.sortKey > $1.sortKey }

        var header: [String] = ["# \(channelName)", ""]
        if !channelURL.isEmpty {
            header.append("**Канал:** \(channelURL)")
            header.append("")
        }
        header.append("**Видео в базе:** \(entries.count)")
        if totalViews > 0 {
            header.append("**Суммарно просмотров:** \(MarkdownRenderer.formatViewsFull(totalViews))")
        }
        header.append("")
        header.append("---")
        header.append("")

        let body = entries.map(\.line)
        let content = (header + body).joined(separator: "\n") + "\n"
        let url = channelDir.appendingPathComponent("index.md")

        do {
            // Atomic write via temp file
            let tmp = url.appendingPathExtension("tmp")
            try content.write(to: tmp, atomically: true, encoding: .utf8)
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            Logger.shared.error("ChannelIndexBuilder write failed: \(error)")
        }
    }

    private static func readFrontmatterHead(_ url: URL) -> String {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        guard content.hasPrefix("---") else { return "" }
        if let endRange = content.range(of: "\n---", range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex) {
            return String(content[..<endRange.lowerBound])
        }
        return String(content.prefix(2000))
    }

    private static func firstMatchString(_ regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: range), m.numberOfRanges >= 2 else { return nil }
        guard let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func firstMatchInt(_ regex: NSRegularExpression, in text: String) -> Int? {
        firstMatchString(regex, in: text).flatMap(Int.init)
    }
}
