// Fails when a text in the app has no German translation, or a translation lost a placeholder.
//
//   swift scripts/check-translations.swift <stringsdata dir> <extract.actionsdata> <Resources dir>
//
// <stringsdata dir>: written by the compiler with -emit-localized-strings (scripts/build-app.sh
// passes it to the release build). It lists every localizable literal: Text("…"), Button("…"),
// String(localized: "…"), App Intents titles and so on. <extract.actionsdata> adds what only the
// App Intents metadata knows (parameter summaries like "Open ${target}"). App Shortcut phrases
// are checked separately (AppShortcuts.strings, see the tests). Run from the package root.

import Foundation

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("check-translations: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else { die("usage: check-translations.swift <stringsdata dir> <extract.actionsdata> <Resources dir>") }
let (stringsDir, metadataPath, resources) = (arguments[1], arguments[2], arguments[3])
let sourceRoot = FileManager.default.currentDirectoryPath + "/Sources/"
/// The app and the shared code (HoatzinCore, HoatzinUI); not the helpers, which show no texts.
let checkedTargets = ["Hoatzin/", "HoatzinCore/", "HoatzinUI/"]

/// Keys of the app, with where they come from.
var keys: [String: String] = [:]

// 1. Compiler output. Files of sources that no longer exist are stale and skipped.
for name in (try? FileManager.default.contentsOfDirectory(atPath: stringsDir)) ?? [] where name.hasSuffix(".stringsdata") {
    guard let data = FileManager.default.contents(atPath: "\(stringsDir)/\(name)"),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let source = object["source"] as? String, source.hasPrefix(sourceRoot),
          checkedTargets.contains(where: { source.dropFirst(sourceRoot.count).hasPrefix($0) }),
          FileManager.default.fileExists(atPath: source)
    else { continue }
    for (table, entries) in object["tables"] as? [String: [[String: Any]]] ?? [:] where table == "Localizable" {
        for entry in entries {
            guard let key = entry["key"] as? String, !key.isEmpty else { continue }
            let line = (entry["location"] as? [String: Any])?["startingLine"] as? Int ?? 0
            keys[key] = keys[key] ?? "\(source.dropFirst(sourceRoot.count)):\(line)"
        }
    }
}
guard !keys.isEmpty else { die("no strings found in \(stringsDir); was the release build run with -emit-localized-strings?") }

// 2. App Intents metadata (localized string resources are {"key": …, "alternatives": …}).
if let data = FileManager.default.contents(atPath: metadataPath), let metadata = try? JSONSerialization.jsonObject(with: data) {
    func walk(_ value: Any) {
        if let dict = value as? [String: Any] {
            if let key = dict["key"] as? String, Set(dict.keys).isSubset(of: ["key", "alternatives", "table", "bundleURL"]),
               !key.contains("${applicationName}") {
                keys[key] = keys[key] ?? "App Intents metadata"
            }
            // Parameter summaries, e.g. "Open ${target}".
            if let format = dict["formatString"] as? String, dict["parameterIdentifiers"] != nil {
                keys[format] = keys[format] ?? "App Intents summary"
            }
            dict.values.forEach(walk)
        } else if let array = value as? [Any] {
            array.forEach(walk)
        }
    }
    walk(metadata)
} else {
    die("can't read \(metadataPath)")
}

// 3. Library purposes in the About panel (scripts/acknowledgements.swift, looked up at runtime).
let acknowledgements = URL(fileURLWithPath: metadataPath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Acknowledgements.json")
if let data = try? Data(contentsOf: acknowledgements),
   let libraries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
    for purpose in libraries.compactMap({ $0["purpose"] as? String }) { keys[purpose] = keys[purpose] ?? "Acknowledgements.json" }
}

// 4. Compare with the German files.
guard let german = NSDictionary(contentsOfFile: "\(resources)/de.lproj/Localizable.strings") as? [String: String] else {
    die("can't read \(resources)/de.lproj/Localizable.strings")
}
let plurals = Set((NSDictionary(contentsOfFile: "\(resources)/de.lproj/Localizable.stringsdict") as? [String: Any] ?? [:]).keys)

/// Format specifiers and ${…} placeholders, ignoring positions (%2$@ counts as %@).
func placeholders(_ text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|ld|d|@|lf|f|%)|\$\{[A-Za-z]+\}"#)
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        String(text[Range($0.range, in: text)!]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
    }.sorted()
}

var problems: [String] = []
for (key, origin) in keys.sorted(by: { $0.key < $1.key }) where german[key] == nil && !plurals.contains(key) {
    problems.append("missing German for \(origin): \"\(key)\"")
}
for (key, value) in german.sorted(by: { $0.key < $1.key }) where placeholders(key) != placeholders(value) {
    problems.append("placeholders differ: \"\(key)\" → \"\(value)\"")
}
let unused = german.keys.filter { keys[$0] == nil }.sorted()
if !unused.isEmpty {
    print("check-translations: \(unused.count) German entries no longer used: \(unused.prefix(5).map { "\"\($0)\"" }.joined(separator: ", "))\(unused.count > 5 ? ", …" : "")")
}
if !problems.isEmpty {
    problems.forEach { FileHandle.standardError.write(Data("check-translations: \($0)\n".utf8)) }
    die("\(problems.count) problem(s). Add the German text to Resources/de.lproj/Localizable.strings.")
}
print("Translations: \(keys.count) texts, all in German.")
