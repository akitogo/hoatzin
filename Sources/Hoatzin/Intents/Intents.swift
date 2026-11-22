import AppIntents
import CoreSpotlight

/// An error shown by Shortcuts, Siri or Spotlight.
struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    init(_ message: String.LocalizationValue) { self.message = String(localized: message) }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

extension AppModel {
    static func forIntents() throws -> AppModel {
        guard let shared else { throw IntentFailure("Hoatzin is still starting. Try again in a moment.") }
        return shared
    }
}

/// Whether the Run Command action may run (Settings → Shortcuts, Siri & Spotlight).
enum CommandActionPolicy: String, CaseIterable, Identifiable {
    case off, ask, always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return String(localized: "Off")
        case .ask: return String(localized: "Ask each time")
        case .always: return String(localized: "Run without asking")
        }
    }

    static var current: CommandActionPolicy {
        CommandActionPolicy(rawValue: UserDefaults.standard.string(forKey: Prefs.runCommandAction) ?? "") ?? .ask
    }
}

// MARK: - Open Connection

enum OpenMethod: String, AppEnum {
    case automatic, ssh, console

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Open With"
    static let caseDisplayRepresentations: [OpenMethod: DisplayRepresentation] = [
        .automatic: "Default",
        .ssh: "SSH",
        .console: "Proxmox Console",
    ]
}

/// Opens a connection like a double-click in the sidebar. Also what Spotlight runs when you
/// pick a connection there.
struct OpenConnectionIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Connection"
    static let description = IntentDescription(
        "Opens a connection in Hoatzin: SSH in the terminal chosen in Settings, or the Proxmox console.",
        categoryName: "Connections"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Connection")
    var target: ConnectionEntity

    /// Optional: an OpenIntent may only require `target`. Empty means Default.
    @Parameter(title: "Open With")
    var method: OpenMethod?

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)") {
            \.$method
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await Self.open(target.id, method: method ?? .automatic, model: AppModel.forIntents())
        return .result()
    }

    @MainActor
    static func open(_ entityID: String, method: OpenMethod, model: AppModel) async throws {
        guard let id = SidebarID(string: entityID) else { throw IntentFailure("Hoatzin doesn't know this connection.") }
        await model.loadProxmoxIfNeeded()
        guard let entity = ConnectionEntity.entity(for: id, model: model) else {
            throw IntentFailure("This connection isn't in Hoatzin any more.")
        }
        switch method {
        case .automatic:
            if model.sshTarget(for: id) == nil, case .item = id {
                throw IntentFailure("\(entity.name) has no SSH address.")
            }
            model.activate(id)
        case .ssh:
            guard await model.waitForSSHTarget(id) != nil else {
                throw IntentFailure("\(entity.name) has no SSH address. Set one with SSH Settings… in Hoatzin.")
            }
            model.connect(id)
        case .console:
            switch id {
            case .guest(let server, let vmid): model.openGuestConsole(server: server, vmid: vmid)
            case .node(let server, let node): model.openConsole(server: server, kind: .nodeShell, node: node, vmid: nil, name: nil)
            case .item: throw IntentFailure("\(entity.name) is an SSH host; only Proxmox VMs, containers and nodes have a console.")
            }
        }
    }
}

// MARK: - Find Connections

struct FindConnectionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Connections"
    static let description = IntentDescription(
        "Finds connections by name, VMID, IP address, host or user, like the sidebar filter. Every word has to match, e.g. “office web” or “10.20.30”.",
        categoryName: "Connections"
    )

    @Parameter(title: "Search", description: "Words to match. Empty finds all connections.")
    var search: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Find connections matching \(\.$search)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ConnectionEntity]> & ProvidesDialog {
        let found = try await Self.find(search ?? "", model: AppModel.forIntents())
        let names = found.prefix(5).map(\.name).joined(separator: ", ") + (found.count > 5 ? ", …" : "")
        let dialog: IntentDialog = found.isEmpty
            ? "No connection matches “\(search ?? "")”."
            : "Found \(found.count): \(names)"
        return .result(value: found, dialog: dialog)
    }

    @MainActor
    static func find(_ search: String, model: AppModel) async throws -> [ConnectionEntity] {
        await model.loadProxmoxIfNeeded()
        return ConnectionEntity.matching(search, in: model)
    }
}

// MARK: - Run Command

/// Runs one command over SSH without a terminal, like the AI tool `run_command`: the same
/// hardened ssh options, no new host keys, passwords from the Keychain. Asks first unless the
/// user chose "Run without asking", and every run goes to the activity log.
struct RunCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Command over SSH"
    static let description = IntentDescription(
        "Runs a command on a connection over SSH and returns its output. There's no terminal, so use commands that need no input. Hosts whose key isn't known yet are refused.",
        categoryName: "Commands"
    )

    @Parameter(title: "Connection")
    var connection: ConnectionEntity

    @Parameter(title: "Command", inputOptions: String.IntentInputOptions(multiline: true))
    var command: String

    @Parameter(title: "Timeout (seconds)", default: 60, inclusiveRange: (1, 300))
    var timeout: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) on \(\.$connection)") {
            \.$timeout
        }
    }

    static let logName = "Shortcuts & Siri"

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = try AppModel.forIntents()
        let output = try await Self.run(command, on: connection.id, timeout: timeout, model: model,
                                        policy: CommandActionPolicy.current) { question in
            if #available(macOS 15.0, *) {
                try await requestConfirmation(actionName: .run, dialog: IntentDialog("\(question)"))
            } else {
                guard try await $command.requestConfirmation(for: command, dialog: IntentDialog("\(question)")) else {
                    throw IntentFailure("The command didn't run.")
                }
            }
        }
        let shown = output.count > 1500 ? String(output.prefix(1500)) + "\n…" : output
        return .result(value: output, dialog: IntentDialog("\(shown.isEmpty ? String(localized: "Done, no output.") : shown)"))
    }

    /// Checks, asks (via `confirm`, which throws when declined), runs and logs. Returns the
    /// output (stdout, or stderr when stdout is empty); throws on errors and non-zero exits.
    @MainActor
    static func run(_ raw: String, on entityID: String, timeout requested: Int, model: AppModel,
                    policy: CommandActionPolicy, confirm: (String) async throws -> Void) async throws -> String {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var target: String?
        func log(_ outcome: String, ok: Bool) {
            model.ai.activity.record(AIActivity(time: Date(), app: logName, tool: "Run Command", target: target,
                                                detail: AIBridge.visible(command, showLineBreaks: false), outcome: outcome, ok: ok))
        }
        func fail(_ outcome: String, _ message: String.LocalizationValue) -> IntentFailure {
            log(outcome, ok: false)
            return IntentFailure(message)
        }

        guard policy != .off else {
            throw fail("turned off", "Running commands from Shortcuts and Siri is turned off in Hoatzin → Settings → Shortcuts, Siri & Spotlight.")
        }
        guard !command.isEmpty else { throw IntentFailure("The command is empty.") }
        guard let id = SidebarID(string: entityID) else { throw IntentFailure("Hoatzin doesn't know this connection.") }
        await model.loadProxmoxIfNeeded()
        guard let entity = ConnectionEntity.entity(for: id, model: model) else {
            throw IntentFailure("This connection isn't in Hoatzin any more.")
        }
        guard let planned = await model.waitForSSHTarget(id) else {
            throw IntentFailure("\(entity.name) has no SSH address, so commands can't run there.")
        }
        target = "\(entity.name) (\(planned.userAtHost))"

        var how = "(without asking)"
        if policy == .ask {
            do {
                try await confirm(String(localized: "Run this on \(entity.name) as \(planned.userAtHost)?") + "\n\n" + AIBridge.visible(command, showLineBreaks: false))
            } catch {
                log("denied", ok: false)
                throw error
            }
            how = "(you approved)"
        }

        let seconds = TimeInterval(min(max(requested, 1), Int(AIBridge.maxCommandTimeout)))
        guard let (_, result) = await model.runCommand(on: id, command: command, timeout: seconds) else {
            throw fail("password prompt cancelled", "The password prompt for \(entity.name) was cancelled, so the command didn't run.")
        }
        let stdout = result.stdout.text, stderr = result.stderr.text
        let time = String(format: "%.1f s", result.duration)
        if let error = result.launchError {
            throw fail("ssh didn't start", "ssh couldn't be started: \(error)")
        }
        if result.timedOut {
            throw fail("stopped after \(Int(seconds)) s \(how)",
                       "The command on \(entity.name) didn't finish within \(Int(seconds)) s and was stopped. It may still be running there.")
        }
        if result.exitCode == 255, stderr.contains("Host key verification failed") {
            throw fail("host key not known",
                       "Hoatzin didn't connect: the host key of \(entity.name) isn't known yet or has changed. Connect once in Hoatzin and check the key, then try again.")
        }
        if result.exitCode == 255 {
            throw fail("ssh exit 255 \(how)", "ssh couldn't connect or log in to \(entity.name) (exit 255). \(stderr)")
        }
        guard result.exitCode == 0 else {
            let code = result.exitCode.map(String.init) ?? "none"
            throw fail("exit \(code) · \(time) \(how)",
                       "The command on \(entity.name) failed with exit code \(code). \(stderr.isEmpty ? stdout : stderr)")
        }
        log("exit 0 · \(time) \(how)", ok: true)
        return stdout.isEmpty ? stderr : stdout
    }
}

// MARK: - Siri and Spotlight

/// Actions offered without any setup: in Spotlight, to Siri, and in the Shortcuts app.
/// German phrases: Resources/de.lproj/AppShortcuts.strings, keyed by these English phrases.
struct HoatzinShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenConnectionIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Open \(\.$target) with \(.applicationName)",
                "Connect to \(\.$target) with \(.applicationName)",
                "Open a connection in \(.applicationName)",
            ],
            shortTitle: "Open Connection",
            systemImageName: "terminal"
        )
        AppShortcut(
            intent: FindConnectionsIntent(),
            phrases: [
                "Find connections in \(.applicationName)",
                "Search \(.applicationName)",
                "Show connections in \(.applicationName)",
            ],
            shortTitle: "Find Connections",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: RunCommandIntent(),
            phrases: [
                "Run a command with \(.applicationName)",
                "Run a command on \(\.$connection) with \(.applicationName)",
            ],
            shortTitle: "Run Command",
            systemImageName: "apple.terminal"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .grayBlue
}

/// Keeps Siri's phrases and the Spotlight index in step with the sidebar.
@MainActor
enum IntentsSync {
    static func update(_ model: AppModel) async {
        HoatzinShortcuts.updateAppShortcutParameters()
        guard #available(macOS 15.0, *) else { return }
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteAppEntities(ofType: ConnectionEntity.self)
            if UserDefaults.standard.bool(forKey: Prefs.spotlightConnections) {
                try await index.indexAppEntities(ConnectionEntity.all(in: model))
            }
        } catch {
            NSLog("Hoatzin: couldn't update the Spotlight index: \(error.localizedDescription)")
        }
    }
}
