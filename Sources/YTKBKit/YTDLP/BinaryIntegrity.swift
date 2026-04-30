import Foundation
import CryptoKit

/// SHA256 anti-tamper check for the embedded yt-dlp binary (spec §6.1).
///
/// At build time, `scripts/build.sh` writes the hash of the bundled binary
/// into `Resources/yt-dlp.sha256` (a single hex line). At launch we recompute
/// the hash of the binary on disk and compare. On mismatch we log an error
/// and surface a banner — but we do NOT refuse to run, because in dev/CI
/// builds the hash file may simply be missing.
enum BinaryIntegrity {
    package static func verifyEmbedded() {
        guard let binary = Bundle.main.url(forResource: "yt-dlp", withExtension: nil) else {
            Logger.shared.warn("BinaryIntegrity: yt-dlp not found in bundle")
            return
        }
        guard let hashFile = Bundle.main.url(forResource: "yt-dlp", withExtension: "sha256") else {
            Logger.shared.info("BinaryIntegrity: no expected hash file in bundle (skipping verification)")
            return
        }
        guard let expectedRaw = try? String(contentsOf: hashFile, encoding: .utf8) else {
            Logger.shared.warn("BinaryIntegrity: cannot read expected hash file")
            return
        }
        let expected = expectedRaw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init)?
            .lowercased() ?? ""
        guard expected.count == 64 else {
            Logger.shared.warn("BinaryIntegrity: invalid expected hash format (\(expected.prefix(20))...)")
            return
        }
        do {
            let actual = try sha256Hex(of: binary)
            if actual == expected {
                Logger.shared.info("BinaryIntegrity: yt-dlp hash OK (\(String(actual.prefix(12)))…)")
            } else {
                Logger.shared.error("BinaryIntegrity: yt-dlp hash MISMATCH — bundle may be tampered. expected=\(String(expected.prefix(12)))… got=\(String(actual.prefix(12)))…")
            }
        } catch {
            Logger.shared.warn("BinaryIntegrity: hash compute failed: \(error)")
        }
    }

    /// SHA256 of file contents as lowercase hex string.
    package static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20  // 1 MB
        while autoreleasepool(invoking: { () -> Bool in
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
