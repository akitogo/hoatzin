import AppKit
import Observation

enum SidebarID: Hashable {
    case item(UUID)
    case node(server: UUID, node: String)
    case guest(server: UUID, vmid: Int)

    var stringValue: String {
        switch self {
        case .item(let id): return "item:\(id.uuidString)"
        case .node(let server, let node): return "node:\(server.uuidString):\(node)"
        case .guest(let server, let vmid): return "guest:\(server.uuidString):\(vmid)"
        }
    }

    var libraryID: UUID? {
        if case .item(let id) = self { return id }
        return nil
    }
}

@MainActor
enum OpenSession: Identifiable {
    case terminal(TerminalSession)
    case console(ConsoleSession)

    nonisolated var id: UUID {
        switch self {
        case .terminal(let s): return s.id
        case .console(let s): return s.id
        }
    }

    var title: String {
        switch self {
        case .terminal(let s): return s.title
        case .console(let s): return s.title
        }
    }

    var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .console(let s): return s.kind == .qemuNoVNC ? "display" : "rectangle.terminal"
        }
    }

    var isAlive: Bool {
        switch self {
        case .terminal(let s): return s.isRunning
        case .console(let s): return s.error == nil
        }
    }

    var view: NSView {
        switch self {
        case .terminal(let s): return s.containerView
        case .console(let s): return s.webView
        }
    }

    @MainActor func focus() {
        switch self {
        case .terminal(let s): s.focus()
        case .console(let s): s.focus()
        }
    }
}

enum EditorRequest: Identifiable {
    case newItem(ItemKind, parent: UUID?)
    case edit(UUID)
    case guest(server: UUID, vmid: Int)

    var id: String {
        switch self {
        case .newItem(let kind, let parent): return "new-\(kind.rawValue)-\(parent?.uuidString ?? "root")"
        case .edit(let id): return "edit-\(id)"
        case .guest(let server, let vmid): return "guest-\(server)-\(vmid)"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let library: LibraryStore
    let prompts: PromptCenter
    let broker: CredentialBroker
    let proxmox: ProxmoxRuntime
    /// Keeps the library the same on the user's Macs through iCloud, if turned on.
    let sync: LibrarySync

    var selection: SidebarID?
    var sessions: [OpenSession] = []
    var selectedSessionID: UUID?
    var editor: EditorRequest?
    var alertMessage: String?
    /// Bumped whenever a Keychain item is added/removed so status badges refresh.
    var keychainRevision = 0
    /// Sidebar filter text (not persisted).
    var sidebarFilter = ""
    /// Bumped by ⌘F to focus the sidebar filter field.
    var filterFocusRequest = 0

    /// Answers tool calls from AI clients (see `ControlServer`).
    @ObservationIgnored private(set) var ai: AIBridge!

    /// The app's model, used by App Intents (Shortcuts, Siri, Spotlight). Tests set their own.
    static var shared: AppModel?

    convenience init() {
        // HOATZIN_LIBRARY lets you point the app at another library file (testing, demos).
        let libraryURL = ProcessInfo.processInfo.environment["HOATZIN_LIBRARY"].map { URL(fileURLWithPath: $0) }
        // First launch after the rename from RemoteDeck (not for test instances with their own library).
        if libraryURL == nil {
            let copied = LegacyMigration.run()
            if !copied.isEmpty { NSLog("Hoatzin: copied from RemoteDeck: \(copied.joined(separator: ", "))") }
        }
        self.init(library: LibraryStore(fileURL: libraryURL ?? LibraryStore.defaultURL))
        Self.shared = self
        // Debug aid: HOATZIN_DEMO_PROXMOX=<file> fills Proxmox servers from a file (screenshots, demos).
        if let demo = ProcessInfo.processInfo.environment["HOATZIN_DEMO_PROXMOX"] {
            proxmox.loadDemo(from: URL(fileURLWithPath: demo))
        }
    }

    /// `activityLogURL` defaults to HOATZIN_AI_LOG, then to ~/Library/Logs/Hoatzin for the
    /// real library, and to a file next to the library for any other one (tests, demos).
    init(library: LibraryStore, activityLogURL: URL? = nil) {
        Prefs.registerDefaults()
        let prompts = PromptCenter()
        let broker = CredentialBroker(prompts: prompts)
        self.library = library
        self.prompts = prompts
        self.broker = broker
        self.proxmox = ProxmoxRuntime(library: library, broker: broker, prompts: prompts)
        self.sync = LibrarySync(library: library)
        broker.onError = { [weak self] message in self?.alertMessage = message }
        alertMessage = library.loadError
        let logURL = activityLogURL
            ?? ProcessInfo.processInfo.environment["HOATZIN_AI_LOG"].map { URL(fileURLWithPath: $0) }
            ?? (library.fileURL.standardizedFileURL == LibraryStore.defaultURL.standardizedFileURL
                ? AIActivityLog.defaultURL
                : library.fileURL.deletingPathExtension().appendingPathExtension("ai-activity.jsonl"))
        ai = AIBridge(model: self, activity: AIActivityLog(fileURL: logURL))
    }

    /// Starts answering AI clients (once per app run).
    func startAIControl() {
        let bridge = ai!
        ControlServer.shared.start { call in await bridge.handle(call) }
    }

    // MARK: Lookup

    func serverItem(_ id: UUID) -> LibraryItem? {
        guard let item = library.item(id), item.kind == .proxmox else { return nil }
        return item
    }

    func sshTarget(for id: SidebarID) -> SSHTarget? {
        switch id {
        case .item(let uuid):
            guard let item = library.item(uuid), item.kind == .ssh, let c = item.ssh, !c.host.isEmpty else { return nil }
            return SSHTarget(displayName: item.name, host: c.host, port: c.port, username: c.username, auth: c.auth,
                             identityFile: c.identityFile, keychainHost: c.keychainHost, extraArgs: c.extraArgs)

        case .guest(let serverID, let vmid):
            guard let server = serverItem(serverID), let config = server.proxmox,
                  let guest = proxmox.guest(server: serverID, vmid: vmid) else { return nil }
            let override = config.guestOverrides[String(vmid)] ?? GuestOverride()
            let host = override.sshHost.isEmpty ? guest.ips.first : override.sshHost
            guard let host else { return nil }
            let defaults = guestDefaults(config)
            return SSHTarget(displayName: guest.name, host: host, port: override.sshPort ?? 22,
                             username: override.sshUser.isEmpty ? defaults.user : override.sshUser,
                             auth: override.sshAuth ?? defaults.auth, identityFile: defaults.keyFile,
                             keychainHost: override.keychainHost)

        case .node(let serverID, let node):
            guard let server = serverItem(serverID), let config = server.proxmox else { return nil }
            let info = proxmox.nodeInfo(server: serverID, node: node)
            guard let host = info?.ip ?? (proxmox.state(serverID).nodes.count == 1 ? config.host : nil) else { return nil }
            // Proxmox nodes: the Proxmox login (e.g. root) with its password. For the PAM realm
            // that is the node's Linux password, so the saved Proxmox login is reused.
            let proxmoxLogin = CredentialKey(server: config.effectiveKeychainHost, account: config.username,
                                             proto: .https, port: config.port)
            return SSHTarget(displayName: node, host: host, port: 22, username: config.loginUser, auth: .password,
                             fallbackKey: config.realm == "pam" ? proxmoxLogin : nil)
        }
    }

    /// Guest SSH defaults of a Proxmox server, falling back to the app-wide defaults.
    func guestDefaults(_ config: ProxmoxConfig) -> (user: String, auth: SSHAuthMode, keyFile: String) {
        let app = Prefs.sshDefaults
        return (config.sshUsername.isEmpty ? app.user : config.sshUsername,
                config.sshAuth ?? app.auth,
                config.sshIdentityFile.isEmpty ? app.keyFile : config.sshIdentityFile)
    }

    // MARK: Actions

    /// Double-click / Return in the sidebar.
    func activate(_ id: SidebarID) {
        switch id {
        case .item(let uuid):
            guard let item = library.item(uuid) else { return }
            switch item.kind {
            case .ssh: connect(id)
            case .proxmox: Task { await proxmox.refresh(uuid) }
            case .folder: break
            }
        case .node(let server, let node):
            openConsole(server: server, kind: .nodeShell, node: node, vmid: nil, name: nil)
        case .guest(let server, let vmid):
            if sshTarget(for: id) != nil {
                connect(id)
            } else {
                openGuestConsole(server: server, vmid: vmid)
            }
        }
    }

    /// Connects via SSH, in the preferred terminal unless `choice` overrides it.
    func connect(_ id: SidebarID, in choice: TerminalChoice? = nil) {
        Task { await openSSH(id, in: choice) }
    }

    /// Like `connect`; returns the new tab's id when the session opened in a built-in tab.
    @discardableResult
    func openSSH(_ id: SidebarID, in choice: TerminalChoice? = nil) async -> UUID? {
        guard sshTarget(for: id) != nil else {
            alertMessage = String(localized: "No SSH address known for this entry. Set one with “SSH Settings…”.")
            return nil
        }
        guard let prepared = await preparedSSHTarget(id) else { return nil }
        return open(prepared.target, in: choice ?? Prefs.preferredTerminal, preResolved: prepared.credential)
    }

    /// The SSH target of `id` with its password looked up (Keychain after Touch ID, or the
    /// AutoFill sheet). Nil when there is no SSH address or the user cancelled.
    func preparedSSHTarget(_ id: SidebarID) async -> (target: SSHTarget, credential: ResolvedCredential?)? {
        guard var target = sshTarget(for: id) else { return nil }
        guard target.auth == .password else { return (target, nil) }
        guard let credential = await broker.resolve(
            target.credentialKey,
            fallbacks: target.fallbackKey.map { [$0] } ?? [],
            title: String(localized: "SSH — \(target.displayName)"),
            message: String(localized: "No saved password for \(target.credentialKey.display). Pick it from Passwords (AutoFill) or type it.")
        ) else { return nil }
        if credential.key.account != target.username {
            target.username = credential.key.account
            rememberUsername(credential.key.account, for: id)
        }
        return (target, credential)
    }

    /// Runs one command on `id` over SSH without a terminal (AI tool `run_command`, Run Command
    /// action). Never accepts host keys. Nil when there is no SSH address or the password prompt
    /// was cancelled.
    func runCommand(on id: SidebarID, command: String, timeout: TimeInterval) async -> (target: SSHTarget, result: RemoteCommand.Result)? {
        guard let prepared = await preparedSSHTarget(id) else { return nil }
        let target = prepared.target
        let agent = SSHAuthAgent(target: target, owner: UUID(), preResolved: prepared.credential,
                                 broker: broker, prompts: prompts, refusesHostKeys: true)
        let result = await RemoteCommand.run(arguments: target.commandArguments(command), timeout: timeout) { request in
            await agent.handle(request)
        }
        // A remote exit code isn't a login failure; only 255 (ssh's own errors) is.
        agent.processEnded(exitCode: result.exitCode == 255 ? 255 : 0, after: result.duration)
        return (target, result)
    }

    /// Waits until every Proxmox server has been loaded once (or failed), starting the load
    /// where nothing has. App Intents can run before the window has refreshed the servers.
    func loadProxmoxIfNeeded(timeout: TimeInterval = 30) async {
        let servers = library.proxmoxServers.map(\.id)
        for server in servers {
            let state = proxmox.state(server)
            if state.lastRefresh == nil, state.error == nil, !state.isLoading {
                Task { await proxmox.refresh(server) }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, servers.contains(where: { proxmox.state($0).lastRefresh == nil && proxmox.state($0).error == nil }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// The SSH target of `id`, waiting a little while a guest's address is still being discovered.
    func waitForSSHTarget(_ id: SidebarID, timeout: TimeInterval = 15) async -> SSHTarget? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let target = sshTarget(for: id) { return target }
            guard case .guest(let server, _) = id, proxmox.state(server).isLoading, Date() < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func open(_ target: SSHTarget, in choice: TerminalChoice, preResolved: ResolvedCredential?) -> UUID? {
        if choice == .builtin {
            let session = TerminalSession(target: target, preResolved: preResolved, broker: broker, prompts: prompts)
            let id = session.id
            session.onCleanExit = { [weak self] in self?.closeSession(id) }
            sessions.append(.terminal(session))
            selectedSessionID = session.id
            session.start()
            return session.id
        }
        do {
            try ExternalTerminal.open(target, in: choice, preResolved: preResolved, broker: broker, prompts: prompts)
        } catch {
            alertMessage = error.localizedDescription
        }
        return nil
    }

    private func rememberUsername(_ username: String, for id: SidebarID) {
        switch id {
        case .item(let uuid):
            library.modify(uuid) { $0.ssh?.username = username }
        case .guest(let server, let vmid):
            library.modify(server) { item in
                var override = item.proxmox?.guestOverrides[String(vmid)] ?? GuestOverride()
                override.sshUser = username
                item.proxmox?.guestOverrides[String(vmid)] = override
            }
        case .node:
            break // nodes always use the Proxmox login user
        }
    }

    @discardableResult
    func openGuestConsole(server: UUID, vmid: Int, preferXterm: Bool = false) -> UUID? {
        guard let guest = proxmox.guest(server: server, vmid: vmid) else { return nil }
        let kind: ConsoleKind = guest.type == .lxc ? .lxc : (preferXterm ? .qemuXterm : .qemuNoVNC)
        return openConsole(server: server, kind: kind, node: guest.node, vmid: vmid, name: guest.name)
    }

    @discardableResult
    func openConsole(server: UUID, kind: ConsoleKind, node: String, vmid: Int?, name: String?) -> UUID {
        let title = name.map { String(localized: "\($0) (console)") } ?? String(localized: "\(node) shell")
        let session = ConsoleSession(serverID: server, kind: kind, node: node, vmid: vmid, guestName: name, title: title, runtime: proxmox)
        sessions.append(.console(session))
        selectedSessionID = session.id
        Task { await session.load() }
        return session.id
    }

    func closeSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        switch sessions[index] {
        case .terminal(let s): s.terminate()
        case .console(let s): s.terminate()
        }
        sessions.remove(at: index)
        if selectedSessionID == id {
            selectedSessionID = sessions.indices.contains(index) ? sessions[index].id : sessions.last?.id
        }
    }

    func reconnect(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        switch session {
        case .terminal(let s): s.start()
        case .console(let s): Task { await s.load() }
        }
    }

    func openWebUI(server: UUID) {
        guard let config = serverItem(server)?.proxmox,
              let url = URL(string: "https://\(config.host):\(config.port)/") else { return }
        NSWorkspace.shared.open(url)
    }

    func delete(_ id: UUID) {
        guard let item = library.item(id) else { return }
        Task {
            let count = item.children.count
            let ok = await prompts.confirm(ConfirmPrompt(
                title: String(localized: "Delete “\(item.name)”?"),
                message: item.kind == .folder && count > 0
                    ? String(localized: "The folder and the \(count) entries inside it are removed from Hoatzin. Saved Keychain passwords are kept.")
                    : String(localized: "The entry is removed from Hoatzin. Saved Keychain passwords are kept."),
                confirmTitle: String(localized: "Delete"),
                destructive: true
            ))
            guard ok else { return }
            library.remove(id)
            proxmox.logout(id)
            if selection == .item(id) { selection = nil }
        }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Folder that new items should go into, based on the current selection.
    var insertionFolder: UUID? {
        guard let id = selection?.libraryID, let item = library.item(id) else { return nil }
        return item.kind == .folder ? item.id : library.parentID(of: item.id)
    }

    // MARK: Keychain helpers for the UI

    func savePassword(_ secret: String, for key: CredentialKey) async {
        await broker.store(key, secret: secret)
        keychainRevision += 1
    }

    func forgetPassword(_ key: CredentialKey) async {
        await broker.forget(key)
        keychainRevision += 1
    }
}
