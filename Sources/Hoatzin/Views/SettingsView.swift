import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.sshOpenIn) private var sshOpenIn = TerminalChoice.iterm.rawValue
    @AppStorage(Prefs.itermNewTab) private var itermNewTab = true
    @AppStorage(Prefs.savePasswordsByDefault) private var saveByDefault = true
    @AppStorage(Prefs.terminalFontSize) private var fontSize = 13.0
    @AppStorage(Prefs.defaultSSHUser) private var defaultUser = "root"
    @AppStorage(Prefs.defaultSSHAuth) private var defaultAuth: SSHAuthMode = .password
    @AppStorage(Prefs.defaultSSHKeyFile) private var defaultKeyFile = ""
    @AppStorage(Prefs.requireTouchID) private var requireTouchID = true
    @AppStorage(Prefs.touchIDGracePeriod) private var gracePeriod = 300.0
    @AppStorage(Prefs.aiAccess) private var aiAccess: AIAccess = .off
    @AppStorage(Prefs.aiReadOutput) private var aiReadOutput = true
    @AppStorage(Prefs.runCommandAction) private var runCommandAction: CommandActionPolicy = .ask
    @AppStorage(Prefs.spotlightConnections) private var spotlightConnections = true
    @AppStorage(Prefs.addressTruncation) private var addressTruncation: AddressTruncation = .start
    @AppStorage(Prefs.iCloudSync) private var iCloudSync = false
    @AppStorage(Prefs.proxmoxRefreshInterval) private var proxmoxRefreshInterval = 10.0
    @State private var copied: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("SSH") {
                Picker("Open SSH sessions in", selection: $sshOpenIn) {
                    ForEach(TerminalChoice.allCases) { choice in
                        Text(choice.isInstalled ? choice.label : String(localized: "\(choice.label) (not installed)"))
                            .tag(choice.rawValue)
                    }
                }
                Toggle("iTerm2: open as a new tab in the front window", isOn: $itermNewTab)
                    .disabled(sshOpenIn != TerminalChoice.iterm.rawValue)
                Text("New tabs are created via AppleScript; macOS asks once to allow Hoatzin to control iTerm2. Without it, each session opens in a new iTerm2 window.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Built-in terminal font size: \(Int(fontSize))", value: $fontSize, in: 9...24)
                    .onChange(of: fontSize) { _, size in
                        for case .terminal(let session) in model.sessions { session.applyFontSize(size) }
                    }
            }
            Section("Sidebar") {
                Picker("Shorten long addresses", selection: $addressTruncation) {
                    ForEach(AddressTruncation.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Proxmox") {
                Picker("Update live values", selection: $proxmoxRefreshInterval) {
                    ForEach(RefreshInterval.choices, id: \.self) { Text(RefreshInterval.label($0)).tag($0) }
                }
                Text("CPU and memory in the guest list, the figures above the graphs and the Live graph follow this. The other graphs come from Proxmox, which keeps at most one value per minute. Updates pause while Hoatzin’s windows can’t be seen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Default login") {
                TextField("User", text: $defaultUser, prompt: Text("root"))
                Picker("Method", selection: $defaultAuth) {
                    ForEach(SSHAuthMode.allCases) { Text($0.label).tag($0) }
                }
                IdentityFileField(path: $defaultKeyFile, placeholder: String(localized: "empty = ssh's own keys, agent and ~/.ssh/config"))
                Text("Used for new SSH connections and for VMs / containers on Proxmox servers, unless the server or the guest says otherwise. Proxmox itself (login, node shell, SSH to the nodes) keeps using the Proxmox user and password.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Passwords") {
                Toggle("Require Touch ID to use saved passwords", isOn: $requireTouchID)
                Picker("Ask again after", selection: $gracePeriod) {
                    Text("Every time").tag(0.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                    Text("1 hour").tag(3600.0)
                }
                .disabled(!requireTouchID)
                HStack {
                    Text("Locks again when the Mac sleeps or the screen locks. Without Touch ID (e.g. lid closed) your Mac password is asked instead.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Lock Now") { SecretGate.shared.lock() }.disabled(!requireTouchID)
                }
                Toggle("Offer to remember passwords in the Keychain", isOn: $saveByDefault)
                Text("Hoatzin itself never stores secrets. Saved passwords are internet-password items in your login keychain (visible in Keychain Access), filed under host + user.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AI Access") {
                Picker("AI apps may", selection: $aiAccess) {
                    ForEach(AIAccess.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Include terminal output of built-in SSH tabs", isOn: $aiReadOutput)
                    .disabled(aiAccess == .off)
                Text("AI apps such as Claude connect through Hoatzin's MCP helper. They see names, IDs, addresses and states, never passwords. Before an AI opens a tab, runs a command or types into a tab, Hoatzin asks you and shows exactly what will happen.")
                    .font(.caption).foregroundStyle(.secondary)
                if aiAccess == .commands {
                    Label("Commands run with your login on that host. Approve only what you understand: text from a server can try to steer an AI. New or changed host keys are never accepted for AI commands.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Activity") {
                    Button("Show AI Activity…") { openWindow(id: AIActivityView.windowID) }
                }
                if ControlServer.shared.status == .busy {
                    Label("Another Hoatzin instance is already answering AI requests.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("MCP helper") {
                    Text(ControlServer.bundledHelperPath)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2).multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("Copy Claude Code Command") {
                        copy("claude mcp add --scope user hoatzin \(SSHTarget.shellQuote(ControlServer.bundledHelperPath))", as: "code")
                    }
                    Button("Copy Claude Desktop Config") {
                        copy("""
                        {
                          "mcpServers": {
                            "hoatzin": {
                              "command": "\(ControlServer.bundledHelperPath)"
                            }
                          }
                        }
                        """, as: "desktop")
                    }
                    if let copied {
                        Text(copied == "code" ? "Copied. Run it in Terminal." : "Copied. Merge it into claude_desktop_config.json.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("The path changes if you move Hoatzin.app; copy the setup again after moving it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcuts, Siri & Spotlight") {
                Picker("Run Command action", selection: $runCommandAction) {
                    ForEach(CommandActionPolicy.allCases) { Text($0.label).tag($0) }
                }
                if runCommandAction == .always {
                    Label("Any shortcut, Siri or Apple Intelligence can then run commands on your hosts without asking you.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if #available(macOS 15.0, *) {
                    Toggle("Show connections in Spotlight", isOn: $spotlightConnections)
                        .onChange(of: spotlightConnections) { _, _ in Task { await IntentsSync.update(model) } }
                }
                Text("The Shortcuts app lists Hoatzin's actions: Open Connection, Find Connections and Run Command over SSH. Siri and Spotlight offer them too, e.g. “Open web01 in Hoatzin”. Spotlight gets names, addresses and logins, never passwords. Run Command never accepts new host keys, and each run is logged in AI Activity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Library") {
                Toggle("Sync with iCloud", isOn: $iCloudSync)
                    .disabled(!LibrarySync.hasCloudKitEntitlement && !iCloudSync)
                    .onChange(of: iCloudSync) { _, _ in model.sync.settingChanged() }
                if iCloudSync || !LibrarySync.hasCloudKitEntitlement {
                    SyncStatusRow(sync: model.sync)
                }
                Text("Keeps folders, connections and Proxmox servers the same on your Macs, end-to-end encrypted in your iCloud. Passwords stay in each Mac’s Keychain and are never synced.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Connections file") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.library.fileURL])
                    }
                }
                Text(model.library.fileURL.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onChange(of: aiAccess) { _, _ in
            copied = nil
            model.ai.revokeAllowances()
        }
        .frame(width: 520)
        .padding(.vertical, 8)
    }

    private func copy(_ text: String, as kind: String) {
        model.copyToPasteboard(text)
        copied = kind
    }
}

/// The state of iCloud sync, with a button to sync right away.
private struct SyncStatusRow: View {
    let sync: LibrarySync

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                if case .synced = sync.status, let device = sync.lastChangedBy {
                    Text("Last changed on “\(device)”.").foregroundStyle(.secondary)
                }
            }
            Spacer()
            if LibrarySync.hasCloudKitEntitlement, sync.isEnabled {
                Button("Sync Now") { sync.syncNow() }
                    .disabled(sync.status == .syncing)
            }
        }
        .font(.caption)
    }

    private var message: String {
        switch sync.status {
        case .off:
            return LibrarySync.hasCloudKitEntitlement ? "" : String(localized: "This build of Hoatzin cannot use iCloud. The notarized app from the GitHub releases can.")
        case .unavailable(let text), .failed(let text): return text
        case .syncing: return String(localized: "Syncing…")
        case .synced(let date): return String(localized: "Up to date, checked at \(date.formatted(date: .omitted, time: .shortened)).")
        }
    }

    private var symbol: String {
        switch sync.status {
        case .off, .unavailable: return "icloud.slash"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .synced: return "checkmark.icloud"
        case .failed: return "exclamationmark.icloud"
        }
    }

    private var color: Color {
        switch sync.status {
        case .failed: return .orange
        case .synced: return .green
        default: return .secondary
        }
    }
}
