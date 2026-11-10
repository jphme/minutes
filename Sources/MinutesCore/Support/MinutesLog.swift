import Foundation
import os

/// Logs to the unified log and to ~/Library/Application Support/Minutes/logs/app.log, so problems can be
/// diagnosed from a plain file (the unified log does not persist info-level messages).
public struct MinutesLog: Sendable {
    private let logger: Logger
    private let category: String

    public init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: "me.jph.minutes", category: category)
    }

    public func info(_ message: String) {
        logger.info("\(message)")
        FileLog.shared.write("INFO", category, message)
    }

    public func warning(_ message: String) {
        logger.warning("\(message)")
        FileLog.shared.write("WARN", category, message)
    }

    public func error(_ message: String) {
        logger.error("\(message)")
        FileLog.shared.write("ERROR", category, message)
    }
}

final class FileLog: @unchecked Sendable {
    static let shared = FileLog()
    private let queue = DispatchQueue(label: "minutes.filelog")
    private var handle: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let dir = AppPaths.logs
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("app.log")
        // Keep the log small: start over when it passes 5 MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    func write(_ level: String, _ category: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) \(level) [\(category)] \(message)\n"
        queue.async { self.handle?.write(Data(line.utf8)) }
    }
}
