import Foundation

/// Result of a KB-directory migration (move) operation.
package struct KBMigrationReport {
    package var copied: Int = 0
    package var skipped: Int = 0
    package var failed: [(URL, String)] = []
    package var bytesCopied: Int64 = 0
}

/// Move all `.md` files (and any nested channel folders) from `oldRoot` to
/// `newRoot`. Implementation is rsync-like: copy first, remove on success;
/// on per-file failure, record but keep going.
///
/// This is intentionally non-atomic — if the user has 50 GB of transcripts on
/// a slow disk and aborts halfway, partial state is fine because file naming
/// is deterministic and the next poll will reconcile via KBScanner.
package enum KBMigrator {
    package static func migrate(from oldRoot: URL, to newRoot: URL) -> KBMigrationReport {
        var report = KBMigrationReport()
        let fm = FileManager.default

        let oldRoot = oldRoot.resolvingSymlinksInPath().standardizedFileURL
        let newRoot = newRoot.resolvingSymlinksInPath().standardizedFileURL

        try? fm.createDirectory(at: newRoot, withIntermediateDirectories: true)

        guard let enumerator = fm.enumerator(
            at: oldRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return report }

        let oldPrefix = oldRoot.path
        for case let rawSrc as URL in enumerator {
            let src = rawSrc.resolvingSymlinksInPath().standardizedFileURL
            let isFile = (try? src.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile else { continue }
            // Compute destination preserving the relative structure
            guard src.path.hasPrefix(oldPrefix) else { continue }
            var relative = String(src.path.dropFirst(oldPrefix.count))
            while relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { continue }
            let dst = newRoot.appendingPathComponent(relative)
            let dstDir = dst.deletingLastPathComponent()

            do {
                try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst.path) {
                    report.skipped += 1
                    try? fm.removeItem(at: src)  // already in target — drop the duplicate
                    continue
                }
                try fm.moveItem(at: src, to: dst)
                let size = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
                report.copied += 1
                report.bytesCopied += size
            } catch {
                report.failed.append((src, "\(error)"))
            }
        }

        // Remove now-empty source directories (best effort)
        // Walk children, deepest-first, removing empty ones.
        var dirsToCheck: [URL] = []
        if let dirs = fm.enumerator(at: oldRoot, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
            for case let dir as URL in dirs {
                if let isDir = try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir == true {
                    dirsToCheck.append(dir)
                }
            }
        }
        // Deepest first
        for dir in dirsToCheck.sorted(by: { $0.path.count > $1.path.count }) {
            if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
        return report
    }

    /// True when the directory contains any `.md` files (so a migration prompt
    /// is worth showing).
    package static func hasContent(at url: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return false
        }
        for case let item as URL in enumerator where item.pathExtension == "md" {
            return true
        }
        return false
    }
}
