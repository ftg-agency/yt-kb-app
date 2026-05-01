import Foundation
import AppKit

/// Downloads the new YTKB.dmg, mounts it, stages the new YTKB.app to a
/// temporary directory, then spawns a detached `/bin/sh` script that swaps
/// /Applications/YTKB.app once our process exits and re-launches the new
/// version. We can't replace the running .app from inside, so the swap has
/// to be deferred to a child process that outlives us.
@MainActor
final class UpdateInstaller {
    static let shared = UpdateInstaller()

    /// Reports installer progress: 0...1, plus a human-readable phase label.
    package struct Progress: Equatable, Sendable {
        package var phase: String     // "Скачиваю DMG…", "Распаковываю…", "Перезапуск…"
        package var fraction: Double  // 0...1; -1 = indeterminate

        package init(phase: String, fraction: Double) {
            self.phase = phase
            self.fraction = fraction
        }
    }

    private init() {}

    private(set) var isInstalling = false

    /// Run the full update flow. The returned task completes on success or
    /// throws on failure. On success the app terminates and the helper
    /// script takes over.
    package func install(
        update: AppUpdate,
        progress: @MainActor @escaping (Progress) -> Void
    ) async throws {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }

        // 1. Download DMG to a temp location
        progress(Progress(phase: "Скачиваю DMG…", fraction: -1))
        let tmpDMG = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytkb-update-\(UUID().uuidString).dmg")
        let req = URLRequest(url: update.assetURL)
        let (downloadURL, response) = try await URLSession.shared.download(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateError.install("DMG download HTTP error")
        }
        // URLSession.download returns the file at a temp path that's auto-deleted —
        // move it to our own temp file so we control the lifetime.
        try? FileManager.default.removeItem(at: tmpDMG)
        try FileManager.default.moveItem(at: downloadURL, to: tmpDMG)
        Logger.shared.info("UpdateInstaller: DMG downloaded to \(tmpDMG.path)")

        // 2. Mount DMG
        progress(Progress(phase: "Монтирую DMG…", fraction: -1))
        let mountPoint = try mount(dmg: tmpDMG)
        Logger.shared.info("UpdateInstaller: mounted at \(mountPoint)")
        defer {
            // Best-effort detach. If the helper script hasn't copied yet, this
            // can leave the volume mounted briefly; the helper has its own
            // detach in case.
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", mountPoint, "-force"])
        }

        // 3. Stage the new YTKB.app to a temp dir (off the mount, so we can
        //    detach the DMG before the helper runs).
        progress(Progress(phase: "Распаковываю…", fraction: -1))
        let stagedAppDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytkb-update-staged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedAppDir, withIntermediateDirectories: true)
        let stagedApp = stagedAppDir.appendingPathComponent("YTKB.app")
        let mountedApp = URL(fileURLWithPath: mountPoint).appendingPathComponent("YTKB.app")
        guard FileManager.default.fileExists(atPath: mountedApp.path) else {
            throw UpdateError.install("YTKB.app not found in DMG")
        }
        // ditto preserves codesign + extended attrs
        let dittoResult = try Process.run(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: [mountedApp.path, stagedApp.path]
        )
        dittoResult.waitUntilExit()
        guard dittoResult.terminationStatus == 0 else {
            throw UpdateError.install("ditto failed: \(dittoResult.terminationStatus)")
        }

        // 4. Detach DMG now (defer above will re-attempt if this fails)
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", mountPoint, "-force"])

        // 5. Write a helper script that:
        //    - waits for our PID to die
        //    - removes /Applications/YTKB.app
        //    - moves staged YTKB.app into /Applications
        //    - clears the quarantine xattr
        //    - launches the new YTKB.app
        progress(Progress(phase: "Перезапуск…", fraction: -1))
        let appPath = "/Applications/YTKB.app"
        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytkb-update-\(UUID().uuidString).sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        # Wait for the running YTKB process to die before swapping.
        for i in $(seq 1 60); do
            if ! kill -0 \(pid) 2>/dev/null; then
                break
            fi
            sleep 1
        done
        # Remove old, install new
        rm -rf '\(appPath)'
        ditto '\(stagedApp.path)' '\(appPath)'
        # Strip Gatekeeper quarantine so it launches without prompts
        xattr -dr com.apple.quarantine '\(appPath)' 2>/dev/null || true
        # Clean up the staging dir
        rm -rf '\(stagedAppDir.path)'
        rm -f '\(tmpDMG.path)'
        # Re-launch
        open '\(appPath)'
        # Self-delete
        rm -f '\(scriptPath.path)'
        """
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        // 6. Detach the script and quit. The script will outlive us by waiting
        //    on our PID.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptPath.path]
        // Detach: don't pipe stdio, don't wait
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        Logger.shared.info("UpdateInstaller: helper script spawned at \(scriptPath.path), terminating self")

        // 7. Quit the app — script picks up after we're gone
        NSApp.terminate(nil)
    }

    /// Mount the DMG and return the volume mount point ("/Volumes/yt-kb").
    /// We parse `hdiutil attach -plist` output for safety.
    private func mount(dmg: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "attach",
            "-readonly",
            "-noverify",
            "-noautoopen",
            "-plist",
            dmg.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.install("hdiutil attach exit \(process.terminationStatus)")
        }
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw UpdateError.install("hdiutil attach: malformed plist")
        }
        for ent in entities {
            if let mountPoint = ent["mount-point"] as? String, !mountPoint.isEmpty {
                return mountPoint
            }
        }
        throw UpdateError.install("hdiutil attach: no mount point in plist")
    }
}
