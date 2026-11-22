// Writes Acknowledgements.json for the About panel: every direct package dependency with
// its resolved version, URL and license text, taken from Package.resolved and the checkout.
//
//   swift scripts/acknowledgements.swift <manifest.json> <output.json>
//
// <manifest.json> is the output of `swift package dump-package`. Run from the package root
// after a build (so .build/checkouts exists). Fails if a dependency has no license file.

import Foundation

/// Why Hoatzin uses a dependency (shown under its name). Add new dependencies here.
let purposes = [
    "swiftterm": "Terminal emulator for the built-in SSH tabs.",
]

struct Library: Encodable {
    var name: String
    var version: String
    var url: String
    var license: String
    var licenseText: String
    var purpose: String?
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("acknowledgements: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { die("usage: acknowledgements.swift <manifest.json> <output.json>") }

func json(_ path: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { die("can't read \(path)") }
    return object
}

let manifest = json(arguments[1])
let resolved = json("Package.resolved")
let pins = (resolved["pins"] as? [[String: Any]] ?? []).reduce(into: [String: [String: Any]]()) {
    if let identity = $1["identity"] as? String { $0[identity] = $1 }
}

func licenseName(_ text: String) -> String {
    if text.contains("Permission is hereby granted, free of charge") { return "MIT License" }
    if text.contains("Apache License") { return "Apache License 2.0" }
    if text.contains("Redistribution and use in source and binary forms") { return "BSD License" }
    if text.contains("Mozilla Public License") { return "Mozilla Public License 2.0" }
    return "License"
}

var libraries: [Library] = []
for dependency in manifest["dependencies"] as? [[String: Any]] ?? [] {
    guard let source = (dependency["sourceControl"] as? [[String: Any]])?.first,
          let identity = source["identity"] as? String
    else { continue }
    let url = (((source["location"] as? [String: Any])?["remote"] as? [[String: Any]])?.first?["urlString"] as? String) ?? ""
    let state = pins[identity]?["state"] as? [String: Any]
    let version = state?["version"] as? String ?? (state?["revision"] as? String).map { String($0.prefix(7)) } ?? "?"

    let repoName = URL(string: url)?.deletingPathExtension().lastPathComponent ?? identity
    let checkout = ".build/checkouts/\(repoName)"
    let files = (try? FileManager.default.contentsOfDirectory(atPath: checkout)) ?? []
    guard let licenseFile = files.sorted().first(where: { $0.uppercased().hasPrefix("LICENSE") || $0.uppercased().hasPrefix("COPYING") }),
          let text = try? String(contentsOfFile: "\(checkout)/\(licenseFile)", encoding: .utf8)
    else { die("no license file found for \(identity) in \(checkout)") }

    libraries.append(Library(name: repoName, version: version, url: url, license: licenseName(text),
                             licenseText: text.trimmingCharacters(in: .whitespacesAndNewlines),
                             purpose: purposes[identity]))
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
do {
    try encoder.encode(libraries.sorted { $0.name.lowercased() < $1.name.lowercased() }).write(to: URL(fileURLWithPath: arguments[2]))
} catch {
    die("can't write \(arguments[2]): \(error)")
}
print("Acknowledgements: \(libraries.map { "\($0.name) \($0.version) (\($0.license))" }.joined(separator: ", "))")
