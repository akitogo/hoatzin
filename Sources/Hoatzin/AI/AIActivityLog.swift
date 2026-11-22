import Foundation
import Observation

/// One call from an AI client.
struct AIActivity: Codable, Identifiable, Equatable {
    var id = UUID()
    var time: Date
    /// The program that started the MCP helper, e.g. "Claude".
    var app: String
    var tool: String
    /// The connection or tab it was about.
    var target: String?
    /// The command, the typed text, the filter, …
    var detail: String?
    /// How it ended: "ok", "denied by you", "exit 0 · 0.8 s", the refusal, …
    var outcome: String
    var ok: Bool
}

/// The audit log of everything AI clients did, shown in Window → AI Activity.
///
/// Stored as JSON lines in ~/Library/Logs/Hoatzin/ai-activity.jsonl, readable only by the
/// user. It holds commands and typed text so they can be reviewed later, never terminal output
/// or passwords (AI clients never get those). At 2 MB the file moves to ai-activity.1.jsonl.
@MainActor
@Observable
final class AIActivityLog {
    static let memoryLimit = 1000
    static let fileLimit = 2 * 1024 * 1024
    static let detailLimit = 4000

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Hoatzin/ai-activity.jsonl")
    }

    let fileURL: URL
    /// Oldest first.
    private(set) var entries: [AIActivity] = []

    init(fileURL: URL) {
        self.fileURL = fileURL
        entries = Self.load(fileURL)
    }

    func record(_ activity: AIActivity) {
        var activity = activity
        if let detail = activity.detail, detail.count > Self.detailLimit {
            activity.detail = String(detail.prefix(Self.detailLimit)) + "…"
        }
        entries.append(activity)
        if entries.count > Self.memoryLimit { entries.removeFirst(entries.count - Self.memoryLimit) }
        append(activity)
    }

    // MARK: - File

    /// ISO 8601 with milliseconds, e.g. 2026-11-13T20:25:33.512Z.
    nonisolated private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp.format(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func load(_ url: URL) -> [AIActivity] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try timestamp.parse(decoder.singleValueContainer().decode(String.self))
        }
        let lines = data.split(separator: 0x0A).suffix(memoryLimit)
        return lines.compactMap { try? decoder.decode(AIActivity.self, from: Data($0)) }
    }

    private func append(_ activity: AIActivity) {
        guard var line = try? Self.encoder.encode(activity) else { return }
        line.append(0x0A)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size + line.count > Self.fileLimit {
                let old = fileURL.deletingPathExtension().appendingPathExtension("1.jsonl")
                try? manager.removeItem(at: old)
                try manager.moveItem(at: fileURL, to: old)
            }
            if !manager.fileExists(atPath: fileURL.path) {
                manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            NSLog("Hoatzin: couldn't write the AI activity log: \(error.localizedDescription)")
        }
    }
}
