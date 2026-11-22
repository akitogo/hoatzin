import AppKit
import SwiftUI

struct EditorSheet: View {
    let request: EditorRequest
    @Environment(AppModel.self) private var model

    var body: some View {
        switch request {
        case .newItem(let kind, let parent):
            ItemEditor(original: nil, kind: kind, parent: parent)
        case .edit(let id):
            if let item = model.library.item(id) {
                ItemEditor(original: item, kind: item.kind, parent: model.library.parentID(of: id))
            }
        case .guest(let server, let vmid):
            GuestEditor(serverID: server, vmid: vmid)
        }
    }
}

// MARK: - Library items

private let topLevelTag = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

struct ItemEditor: View {
    let original: LibraryItem?
    let kind: ItemKind
    let parent: UUID?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var folder = topLevelTag
    @State private var ssh = SSHConfig()
    @State private var pve = ProxmoxConfig()

    /// Whole phrases: gender and word order differ between languages.
    private var title: String {
        switch (kind, original == nil) {
        case (.folder, true): return String(localized: "New Folder")
        case (.folder, false): return String(localized: "Edit Folder")
        case (.ssh, true): return String(localized: "New SSH Connection")
        case (.ssh, false): return String(localized: "Edit SSH Connection")
        case (.proxmox, true): return String(localized: "New Proxmox Server")
        case (.proxmox, false): return String(localized: "Edit Proxmox Server")
        }
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .folder: return true
        case .ssh: return !ssh.host.trimmingCharacters(in: .whitespaces).isEmpty
        case .proxmox: return !pve.host.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(kind == .proxmox ? "e.g. Office cluster" : kind == .ssh ? "e.g. web192" : "e.g. Customers"))
                    Picker("Folder", selection: $folder) {
                        Text("Top level").tag(topLevelTag)
                        ForEach(model.library.folderPaths.filter { $0.id != original?.id }, id: \.id) { entry in
                            Text(entry.path).tag(entry.id)
                        }
                    }
                }

                if kind == .ssh { sshSection }
                if kind == .proxmox { proxmoxSection }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add" : "Save", action: save).keyboardShortcut(.defaultAction).disabled(!isValid)
            }
            .padding(14)
        }
        .frame(width: 520, height: kind == .folder ? 200 : 640)
        .navigationTitle(title)
        .onAppear(perform: load)
    }

    // MARK: SSH

    @ViewBuilder private var sshSection: some View {
        Section("Connection") {
            TextField("Host", text: $ssh.host, prompt: Text("10.20.30.192 or host.example.com"))
            TextField("Port", value: $ssh.port, format: .number.grouping(.never))
            TextField("User", text: $ssh.username)
            TextField("Extra ssh options", text: $ssh.extraArgs, prompt: Text("e.g. -A -J jump@bastion"))
        }
        Section("Authentication") {
            Picker("Method", selection: $ssh.auth) {
                ForEach(SSHAuthMode.allCases) { Text($0.label).tag($0) }
            }
            IdentityFileField(path: $ssh.identityFile)
            if ssh.auth == .password {
                TextField("Keychain entry", text: $ssh.keychainHost, prompt: Text(ssh.host.isEmpty ? String(localized: "same as host") : ssh.host))
                KeychainStatusRow(key: CredentialKey(server: ssh.effectiveKeychainHost, account: ssh.username, proto: .ssh, port: ssh.port))
            }
        }
    }

    // MARK: Proxmox

    @ViewBuilder private var proxmoxSection: some View {
        Section("Proxmox VE API") {
            TextField("Host", text: $pve.host, prompt: Text("10.20.30.10 or pve.example.com"))
            TextField("Port", value: $pve.port, format: .number.grouping(.never))
            TextField("User", text: $pve.username)
            Picker("Realm", selection: $pve.realm) {
                Text("Linux PAM (pam)").tag("pam")
                Text("Proxmox VE (pve)").tag("pve")
                if !["pam", "pve"].contains(pve.realm) { Text(pve.realm).tag(pve.realm) }
            }
            TextField("Keychain entry", text: $pve.keychainHost, prompt: Text(pve.host.isEmpty ? String(localized: "same as host") : pve.host))
            KeychainStatusRow(key: CredentialKey(server: pve.effectiveKeychainHost, account: pve.username, proto: .https, port: pve.port))
            if let pin = pve.pinnedSHA256 {
                LabeledContent("Trusted certificate") {
                    HStack {
                        Text(pin.prefix(23) + "…").font(.system(.caption, design: .monospaced)).help(pin)
                        Button("Forget") { pve.pinnedSHA256 = nil }.controlSize(.small)
                    }
                }
            }
        }
        let app = Prefs.sshDefaults
        Section("SSH into guests") {
            TextField("User", text: $pve.sshUsername, prompt: Text("\(app.user) (app default)"))
            Picker("Method", selection: $pve.sshAuth) {
                Text("App default — \(app.auth.label)").tag(SSHAuthMode?.none)
                ForEach(SSHAuthMode.allCases) { Text($0.label).tag(SSHAuthMode?.some($0)) }
            }
            IdentityFileField(path: $pve.sshIdentityFile,
                              placeholder: app.keyFile.isEmpty ? String(localized: "app default (ssh's own keys)") : String(localized: "\(app.keyFile) (app default)"))
            let loginUser = pve.loginUser.isEmpty ? String(localized: "the Proxmox user") : pve.loginUser
            Text("Empty fields use the defaults from Settings. Override per guest with “SSH Settings…”. Node shells and SSH to the Proxmox nodes always use \(loginUser) with the Proxmox password.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Load / save

    private func load() {
        folder = parent ?? (original == nil ? (model.insertionFolder ?? topLevelTag) : topLevelTag)
        guard let original else {
            if kind == .ssh {
                let defaults = Prefs.sshDefaults
                ssh.username = defaults.user
                ssh.auth = defaults.auth
                ssh.identityFile = defaults.keyFile
            }
            return
        }
        name = original.name
        ssh = original.ssh ?? SSHConfig()
        pve = original.proxmox ?? ProxmoxConfig()
    }

    private func save() {
        let targetFolder = folder == topLevelTag ? nil : folder
        var item = original ?? LibraryItem(kind: kind, name: "")
        item.name = name.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .folder: break
        case .ssh:
            ssh.host = ssh.host.trimmingCharacters(in: .whitespaces)
            item.ssh = ssh
        case .proxmox:
            pve.host = pve.host.trimmingCharacters(in: .whitespaces)
            item.proxmox = pve
        }

        if let original {
            let hostChanged = original.proxmox?.host != item.proxmox?.host || original.proxmox?.port != item.proxmox?.port
            model.library.update(item)
            if model.library.parentID(of: item.id) != targetFolder {
                model.library.move(item.id, to: targetFolder, index: nil)
            }
            if kind == .proxmox && hostChanged {
                model.proxmox.logout(item.id)
                Task { await model.proxmox.refresh(item.id) }
            }
        } else {
            model.library.add(item, to: targetFolder)
            model.selection = .item(item.id)
            if kind == .proxmox { Task { await model.proxmox.refresh(item.id) } }
        }
        dismiss()
    }
}

// MARK: - Guest SSH settings

struct GuestEditor: View {
    let serverID: UUID
    let vmid: Int

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var override = GuestOverride()
    @State private var portText = ""

    var body: some View {
        let guest = model.proxmox.guest(server: serverID, vmid: vmid)
        let config = model.serverItem(serverID)?.proxmox ?? ProxmoxConfig()
        let defaults = model.guestDefaults(config)
        let host = override.sshHost.isEmpty ? (guest?.ips.first ?? "") : override.sshHost
        let user = override.sshUser.isEmpty ? defaults.user : override.sshUser
        let auth = override.sshAuth ?? defaults.auth
        let keychainHost = override.keychainHost.isEmpty ? host : override.keychainHost

        VStack(spacing: 0) {
            Form {
                Section("\(guest?.name ?? String(localized: "Guest")) (\(String(vmid)))") {
                    TextField("SSH host", text: $override.sshHost, prompt: Text(guest?.ips.first ?? String(localized: "no address discovered")))
                    if let ips = guest?.ips, ips.count > 1 {
                        LabeledContent("Discovered") {
                            HStack {
                                ForEach(ips, id: \.self) { ip in
                                    Button(ip) { override.sshHost = ip }.controlSize(.small)
                                }
                            }
                        }
                    }
                    TextField("Port", text: $portText, prompt: Text("22"))
                    TextField("User", text: $override.sshUser, prompt: Text("\(defaults.user) (default)"))
                    Picker("Method", selection: $override.sshAuth) {
                        Text("Default — \(defaults.auth.label)").tag(SSHAuthMode?.none)
                        ForEach(SSHAuthMode.allCases) { Text($0.label).tag(SSHAuthMode?.some($0)) }
                    }
                    if auth == .key {
                        LabeledContent("Key file", value: defaults.keyFile.isEmpty ? String(localized: "ssh's own keys / agent / ~/.ssh/config") : defaults.keyFile)
                    }
                    TextField("Keychain entry", text: $override.keychainHost, prompt: Text(host.isEmpty ? String(localized: "same as host") : host))
                    if !host.isEmpty && auth == .password {
                        KeychainStatusRow(key: CredentialKey(server: keychainHost, account: user, proto: .ssh, port: Int(portText) ?? 22))
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Reset to defaults") { override = GuestOverride(); portText = "" }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 500, height: 460)
        .onAppear {
            override = config.guestOverrides[String(vmid)] ?? GuestOverride()
            portText = override.sshPort.map(String.init) ?? ""
        }
    }

    private func save() {
        var value = override
        value.sshHost = value.sshHost.trimmingCharacters(in: .whitespaces)
        value.sshPort = Int(portText.trimmingCharacters(in: .whitespaces))
        model.library.modify(serverID) { item in
            item.proxmox?.guestOverrides[String(vmid)] = value == GuestOverride() ? nil : value
        }
        dismiss()
    }
}

// MARK: - Shared rows

struct IdentityFileField: View {
    @Binding var path: String
    var placeholder = String(localized: "optional, e.g. ~/.ssh/id_ed25519")

    var body: some View {
        LabeledContent("Key file") {
            HStack {
                TextField("Key file", text: $path, prompt: Text(placeholder))
                    .labelsHidden()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.showsHiddenFiles = true
                    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
                    if panel.runModal() == .OK, let url = panel.url {
                        path = (url.path as NSString).abbreviatingWithTildeInPath
                    }
                }
            }
        }
    }
}

/// Shows whether a Keychain item exists for `key` (attributes only, never reads the secret)
/// and lets the user store or remove one.
struct KeychainStatusRow: View {
    let key: CredentialKey

    @Environment(AppModel.self) private var model
    @State private var exists: Bool?
    @State private var editing = false
    @State private var secret = ""
    @State private var handle = FieldHandle()

    var body: some View {
        LabeledContent("Password") {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    switch exists {
                    case .some(true):
                        Label("in Keychain", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    case .some(false):
                        Label("asked on connect", systemImage: "questionmark.key.filled").foregroundStyle(.secondary)
                    case .none:
                        ProgressView().controlSize(.small)
                    }
                    if exists == true {
                        Button("Remove") { Task { await model.forgetPassword(key) } }.controlSize(.small)
                    }
                    Button(exists == true ? "Replace…" : "Save…") { editing.toggle() }.controlSize(.small)
                }
                .font(.callout)
                if editing {
                    HStack {
                        AutoFillField(text: $secret, placeholder: String(localized: "password (AutoFill from Passwords)"), secure: true,
                                      contentType: .password, autofocus: true, handle: handle, onSubmit: store)
                            .frame(minWidth: 220)
                        Button("Store", action: store).controlSize(.small)
                    }
                    Text("Saved as \(key.display) (\(key.proto.rawValue)) in your login keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: "\(key.server)|\(key.account)|\(key.proto.rawValue)|\(model.keychainRevision)") {
            guard !key.server.isEmpty, !key.account.isEmpty else { exists = false; return }
            exists = await CredentialBroker.hasKeychainItem(key)
        }
    }

    private func store() {
        let value = handle.value ?? secret
        guard !value.isEmpty, !key.server.isEmpty else { return }
        Task {
            await model.savePassword(value, for: key)
            secret = ""
            editing = false
        }
    }
}
