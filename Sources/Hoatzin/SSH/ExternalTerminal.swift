import AppKit

/// Starts ssh in iTerm2 or Terminal.app.
///
/// A short-lived, self-deleting launcher script (mode 700, in a private folder) carries the
/// askpass socket path and a session token, never a password. The script binds the token to
/// itself before `exec ssh`, so only that ssh can use it. ssh's prompts in the external
/// terminal are answered by the app exactly like in an embedded tab.
@MainActor
enum ExternalTerminal {
    private static var launchDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Hoatzin-launch", isDirectory: true)
    }

    /// Removes launcher scripts that were never executed.
    static func cleanupStaleScripts() {
        let dir = launchDir
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(modified) > 600 { try? FileManager.default.removeItem(at: file) }
        }
    }

    static func open(_ target: SSHTarget, in choice: TerminalChoice, preResolved: ResolvedCredential?,
                     broker: CredentialBroker, prompts: PromptCenter) throws {
        guard let bundleID = choice.bundleID,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { throw NSError(domain: "Hoatzin", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "\(choice.label) is not installed.")]) }

        let agent = SSHAuthAgent(target: target, owner: UUID(), preResolved: preResolved, broker: broker, prompts: prompts)
        // The token only has to survive the login phase.
        let token = AskpassServer.shared.register(expiresIn: 15 * 60) { request in await agent.handle(request) }
        let script = try writeScript(for: target, token: token)

        if choice == .iterm, UserDefaults.standard.bool(forKey: Prefs.itermNewTab),
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false,
           openInITermTab(script) {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([script], withApplicationAt: appURL, configuration: configuration) { _, error in
            if let error { NSLog("Hoatzin: opening \(choice.label) failed: \(error)") }
        }
    }

    private static func writeScript(for target: SSHTarget, token: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: launchDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let safeName = target.displayName.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let url = launchDir.appendingPathComponent("\(safeName)-\(UUID().uuidString.prefix(8)).command")

        let q = SSHTarget.shellQuote
        let exports = AskpassServer.shared.environment(token: token)
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(q($0.value))" }
            .joined(separator: "\n")
        let command = (["/usr/bin/ssh"] + target.sshArguments).map(q).joined(separator: " ")
        // The helper binds the token to this shell, which then execs ssh (same pid). A token
        // that something else bound first is revoked, so the launch stops here.
        let script = """
        #!/bin/zsh
        rm -f -- "$0"
        \(exports)
        if ! HOATZIN_BIND=1 "$SSH_ASKPASS"; then
          print -u2 \(q(String(localized: "Hoatzin refused this launch: the app is not running, the link expired, or another process tried to use it.")))
          read -sk1 \(q("?" + String(localized: "Press any key to close.")))
          exit 1
        fi
        printf '\\033]0;%s\\007' \(q(target.displayName))
        clear
        exec \(command)

        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Opens the launcher as a new tab in iTerm2's front window (needs Automation permission once).
    private static func openInITermTab(_ script: URL) -> Bool {
        let path = script.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "com.googlecode.iterm2"
            activate
            if (count of windows) is 0 then
                create window with default profile command "\(path)"
            else
                tell current window
                    create tab with default profile command "\(path)"
                end tell
            end if
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("Hoatzin: iTerm2 AppleScript failed, falling back to a new window: \(error)")
            return false
        }
        return true
    }
}
