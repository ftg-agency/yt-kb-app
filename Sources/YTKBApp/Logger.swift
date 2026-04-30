import Foundation

final class Logger: @unchecked Sendable {
    static let shared = Logger()

    enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR" }

    private let queue = DispatchQueue(label: "io.yt-kb.logger", qos: .utility)
    private let logURL: URL
    private let formatter: ISO8601DateFormatter

    private init() {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/yt-kb", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.logURL = logsDir.appendingPathComponent("yt-kb.log")
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func info(_ msg: String) { write(.info, msg) }
    func warn(_ msg: String) { write(.warn, msg) }
    func error(_ msg: String) { write(.error, msg) }

    private func write(_ level: Level, _ msg: String) {
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(msg)\n"
        queue.async { [logURL] in
            #if DEBUG
            print(line, terminator: "")
            #endif
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path),
                   let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: logURL)
                }
            }
        }
    }
}
