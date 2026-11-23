import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.selection {
            case .none:
                WelcomeView()
            case .item(let id):
                if let item = model.library.item(id) {
                    switch item.kind {
                    case .folder: FolderOverview(item: item)
                    case .ssh: SSHOverview(item: item)
                    case .proxmox: ProxmoxOverview(item: item)
                    }
                } else {
                    WelcomeView()
                }
            case .node(let server, let node):
                NodeOverview(serverID: server, node: node)
            case .guest(let server, let vmid):
                GuestOverview(serverID: server, vmid: vmid)
            }
        }
    }
}

// MARK: - Building blocks

private struct Header: View {
    let symbol: String
    let title: String
    let subtitle: String?
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
        }
    }
}

private struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Like `Page`, but without scrolling: its last element (a table) takes the rest of the height
/// and scrolls by itself.
private struct FillingPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) { content }
            .padding(24)
            .frame(maxWidth: 820, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct InfoGrid: View {
    let rows: [(LocalizedStringKey, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    Text(rows[i].0).foregroundStyle(.secondary)
                    Text(rows[i].1).textSelection(.enabled)
                }
            }
        }
        .font(.callout)
    }
}

private struct ConnectButtons: View {
    let id: SidebarID
    @Environment(AppModel.self) private var model

    var body: some View {
        let preferred = Prefs.preferredTerminal
        HStack {
            Button {
                model.connect(id)
            } label: {
                Label("Connect — \(preferred.label)", systemImage: "bolt.fill")
            }
            .buttonStyle(.borderedProminent)
            ForEach(TerminalChoice.allCases.filter { $0 != preferred && $0.isInstalled }) { choice in
                Button(choice.label) { model.connect(id, in: choice) }
            }
        }
    }
}

// MARK: - Pages

private struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page {
            Header(symbol: "rectangle.connected.to.line.below", title: "Hoatzin", subtitle: nil)
            Text("Add a Proxmox server to list all its VMs and containers, or add plain SSH connections. Double-click an entry to connect.")
                .foregroundStyle(.secondary)
            HStack {
                Button { model.editor = .newItem(.proxmox, parent: model.insertionFolder) } label: {
                    Label("Add Proxmox Server", systemImage: "server.rack")
                }
                .buttonStyle(.borderedProminent)
                Button { model.editor = .newItem(.ssh, parent: model.insertionFolder) } label: {
                    Label("Add SSH Connection", systemImage: "terminal")
                }
                Button { model.editor = .newItem(.folder, parent: model.insertionFolder) } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
            }
            GroupBox("How passwords are handled") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• Hoatzin stores only host names, users and ports. No secrets.")
                    Text("• Passwords are read from your login keychain, filed under host + user (e.g. root @ 10.20.30.192).")
                    Text("• If none is saved, you pick it from the Passwords app via AutoFill (Touch ID) and can let Hoatzin remember it in the Keychain.")
                    Text("• ssh asks the app for passwords through a private socket, never via files or command lines. This works in iTerm2 and Terminal too.")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }
}

private struct FolderOverview: View {
    let item: LibraryItem
    @Environment(AppModel.self) private var model

    var body: some View {
        Page {
            Header(symbol: "folder", title: item.name, subtitle: String(localized: "\(item.children.count) entries"))
            HStack {
                Button("New SSH Connection") { model.editor = .newItem(.ssh, parent: item.id) }
                Button("New Proxmox Server") { model.editor = .newItem(.proxmox, parent: item.id) }
                Button("New Folder") { model.editor = .newItem(.folder, parent: item.id) }
            }
            ForEach(item.children) { child in
                HStack {
                    Image(systemName: child.kind == .folder ? "folder" : child.kind == .ssh ? "terminal" : "server.rack")
                        .frame(width: 20)
                    Text(child.name)
                    Spacer()
                    Text(child.ssh?.host ?? child.proxmox?.host ?? "").foregroundStyle(.secondary).font(.system(.callout, design: .monospaced))
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.activate(.item(child.id)) }
                .onTapGesture { model.selection = .item(child.id) }
                Divider()
            }
        }
    }
}

private struct SSHOverview: View {
    let item: LibraryItem
    @Environment(AppModel.self) private var model

    var body: some View {
        let c = item.ssh ?? SSHConfig()
        Page {
            Header(symbol: "terminal", title: item.name, subtitle: "\(c.username)@\(c.host)\(c.port == 22 ? "" : ":\(c.port)")")
            ConnectButtons(id: .item(item.id))
            InfoGrid(rows: [
                ("Authentication", c.auth.label),
                ("Key file", c.identityFile.isEmpty ? "—" : c.identityFile),
                ("Extra options", c.extraArgs.isEmpty ? "—" : c.extraArgs),
            ])
            if c.auth == .password {
                Form { KeychainStatusRow(key: CredentialKey(server: c.effectiveKeychainHost, account: c.username, proto: .ssh, port: c.port)) }
                    .formStyle(.grouped).frame(maxWidth: 560)
            }
            Button("Edit…") { model.editor = .edit(item.id) }
        }
    }
}

private struct ProxmoxOverview: View {
    let item: LibraryItem
    @Environment(AppModel.self) private var model
    @State private var tableSelection: Int?
    @AppStorage(Prefs.proxmoxRefreshInterval) private var interval = 10.0

    private struct UsageKey: Hashable { let server: UUID; let interval: Double }

    var body: some View {
        let c = item.proxmox ?? ProxmoxConfig()
        let state = model.proxmox.state(item.id)
        FillingPage {
            Header(symbol: "server.rack", title: item.name, subtitle: "\(c.apiUser) @ \(c.host):\(c.port)")
            HStack {
                Button {
                    Task { await model.proxmox.refresh(item.id) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(state.isLoading)
                Button("Open Web UI") { model.openWebUI(server: item.id) }
                Button("Edit…") { model.editor = .edit(item.id) }
                if state.isLoading { ProgressView().controlSize(.small) }
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            InfoGrid(rows: [
                ("Logged in as", state.loggedInAs ?? "—"),
                ("Nodes", state.nodes.map(\.name).joined(separator: ", ").ifEmpty("—")),
                ("Guests", state.lastRefresh == nil ? "—" : String(localized: "\(state.guests.filter(\.isRunning).count) running / \(state.guests.count) total")),
                ("Updated", state.lastRefresh.map { $0.formatted(date: .omitted, time: .standard) } ?? "—"),
            ])

            if !state.guests.isEmpty {
                Table(state.guests, selection: $tableSelection) {
                    TableColumn("") { g in
                        Circle().fill(g.isRunning ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                    }
                    .width(14)
                    TableColumn("ID") { g in Text(String(g.vmid)).monospacedDigit() }.width(50)
                    TableColumn("Name", value: \.name)
                    TableColumn("Type") { g in Text(g.type.label) }.width(40)
                    TableColumn("Node", value: \.node).width(80)
                    TableColumn("CPU") { g in
                        UsageCell(fraction: g.cpu, text: g.cpu.map(MetricUnit.percent.format))
                    }
                    .width(100)
                    TableColumn("Memory") { g in
                        UsageCell(fraction: g.memory.flatMap { used in g.maxMemory.map { $0 > 0 ? used / $0 : 0 } },
                                  text: g.memory.map(MetricUnit.bytes.format))
                    }
                    .width(120)
                    TableColumn("Address") { g in
                        Text(g.ips.first ?? "").font(.system(.body, design: .monospaced))
                    }
                }
                .frame(minHeight: 200, maxHeight: .infinity)
                .contextMenu(forSelectionType: Int.self) { ids in
                    if let vmid = ids.first {
                        ForEach(Array(model.menuItems(for: .guest(server: item.id, vmid: vmid)).enumerated()), id: \.offset) { _, entry in
                            if entry.isSeparator { Divider() } else { Button(entry.title) { entry.action?() } }
                        }
                    }
                } primaryAction: { ids in
                    if let vmid = ids.first { model.activate(.guest(server: item.id, vmid: vmid)) }
                }
            }
        }
        .task(id: UsageKey(server: item.id, interval: interval)) {
            // CPU and memory in the table follow the live-value interval while they're visible.
            var first = true
            while !Task.isCancelled {
                if first || AppVisibility.isVisible { await model.proxmox.refreshUsage(item.id) }
                first = false
                guard interval > 0 else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
}

private struct NodeOverview: View {
    let serverID: UUID
    let node: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let info = model.proxmox.nodeInfo(server: serverID, node: node)
        Page {
            Header(symbol: "cpu", title: node, subtitle: info?.ip, tint: info?.online == true ? .green : .secondary)
            HStack {
                Button {
                    model.openConsole(server: serverID, kind: .nodeShell, node: node, vmid: nil, name: nil)
                } label: {
                    Label("Node Shell (Proxmox)", systemImage: "rectangle.terminal")
                }
                .buttonStyle(.borderedProminent)
            }
            if model.sshTarget(for: .node(server: serverID, node: node)) != nil {
                ConnectButtons(id: .node(server: serverID, node: node))
            }
            if info?.online != false {
                let subject = MetricsSubject.node(server: serverID, node: node)
                MetricsPanel(subject: subject).id(subject).padding(.top, 6)
            }
        }
    }
}

private struct GuestOverview: View {
    let serverID: UUID
    let vmid: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        let id = SidebarID.guest(server: serverID, vmid: vmid)
        if let guest = model.proxmox.guest(server: serverID, vmid: vmid) {
            let target = model.sshTarget(for: id)
            Page {
                Header(symbol: guest.type == .qemu ? "desktopcomputer" : "shippingbox",
                       title: guest.name,
                       subtitle: target.map { $0.userAtHost } ?? String(localized: "no SSH address"),
                       tint: guest.isRunning ? .green : .secondary)
                HStack {
                    Button {
                        model.openGuestConsole(server: serverID, vmid: vmid)
                    } label: {
                        Label(guest.type == .lxc ? "Console (Proxmox)" : "Console — noVNC", systemImage: "rectangle.terminal")
                    }
                    if guest.type == .qemu {
                        Button("Serial console") { model.openGuestConsole(server: serverID, vmid: vmid, preferXterm: true) }
                    }
                    Button("SSH Settings…") { model.editor = .guest(server: serverID, vmid: vmid) }
                }
                if target != nil { ConnectButtons(id: id) }
                InfoGrid(rows: [
                    ("VMID", String(guest.vmid)),
                    ("Type", guest.type == .qemu ? String(localized: "Virtual machine (QEMU)") : String(localized: "Container (LXC)")),
                    ("Node", guest.node),
                    ("Status", guest.status),
                    ("Addresses", guest.ips.joined(separator: ", ").ifEmpty(guest.isRunning ? String(localized: "none reported (guest agent?)") : "—")),
                ])
                if let target, target.auth == .password {
                    Form { KeychainStatusRow(key: target.credentialKey) }
                        .formStyle(.grouped).frame(maxWidth: 560)
                }
                if !guest.isTemplate {
                    let subject = MetricsSubject.guest(server: serverID, node: guest.node, type: guest.type, vmid: vmid)
                    MetricsPanel(subject: subject).id(subject).padding(.top, 6)
                }
            }
        } else {
            Page { Text("This guest is no longer listed.").foregroundStyle(.secondary) }
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
