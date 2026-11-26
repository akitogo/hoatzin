import Foundation
import HoatzinCore

/// Hoatzin was called RemoteDeck (bundle ID com.akitogo.RemoteDeck). On the first launch as
/// Hoatzin this copies what the old app stored: the library, the settings and the AI activity
/// log. The old files stay as they are, and nothing that already exists is overwritten. Saved
/// passwords need nothing: Keychain items are filed under host and user, not under the app.
enum LegacyMigration {
    static let oldBundleID = "com.akitogo.RemoteDeck"
    static let oldFolder = "RemoteDeck"
    static let newFolder = "Hoatzin"
    static let doneKey = "migratedFromRemoteDeck"

    /// Runs once and returns what was copied. A setting is only copied when Hoatzin has none saved
    /// (`domain` is where its saved settings live; registered defaults don't count).
    @discardableResult
    static func run(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    defaults: UserDefaults = .standard,
                    domain: String = Bundle.main.bundleIdentifier ?? "com.akitogo.Hoatzin",
                    oldSetting: (String) -> Any? = { CFPreferencesCopyAppValue($0 as CFString, oldBundleID as CFString) }) -> [String] {
        guard !defaults.bool(forKey: doneKey) else { return [] }
        defer { defaults.set(true, forKey: doneKey) }
        var copied: [String] = []

        let support = home.appendingPathComponent("Library/Application Support")
        if copyIfMissing(support.appendingPathComponent("\(oldFolder)/library.json"),
                         to: support.appendingPathComponent("\(newFolder)/library.json")) {
            copied.append("library")
        }
        let logs = home.appendingPathComponent("Library/Logs")
        for name in ["ai-activity.jsonl", "ai-activity.1.jsonl"]
        where copyIfMissing(logs.appendingPathComponent("\(oldFolder)/\(name)"), to: logs.appendingPathComponent("\(newFolder)/\(name)")) {
            copied.append(name)
        }
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        for key in Prefs.all where saved[key] == nil {
            if let value = oldSetting(key) {
                defaults.set(value, forKey: key)
                copied.append(key)
            }
        }
        return copied
    }

    private static func copyIfMissing(_ source: URL, to destination: URL) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path), !manager.fileExists(atPath: destination.path) else { return false }
        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: source, to: destination)
            return true
        } catch {
            NSLog("Hoatzin: couldn't copy \(source.path) from RemoteDeck: \(error.localizedDescription)")
            return false
        }
    }
}
