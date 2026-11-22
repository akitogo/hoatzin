import AppKit

struct SidebarRow: Equatable {
    enum Tint: Equatable { case none, running, stopped, warning, accent }

    var id: SidebarID
    var title: String
    var detail: String?
    /// Short ID shown as a pill at the trailing edge (Proxmox VMID).
    var badge: String? = nil
    var symbol: String
    var tint: Tint = .none
    /// Extra words the filter matches besides title and badge (hosts, IPs, users). Not shown.
    var keywords: [String] = []
    var children: [SidebarRow]? = nil
    /// Library folder (accepts drops).
    var isFolder = false
    /// Library item (can be dragged).
    var isMovable = false
}

/// Narrows the sidebar tree in place.
///
/// The query is split into words; a row is shown when every word appears (case- and
/// accent-insensitive) in its title, badge or keywords, or in those of its parents. So
/// "office web" finds "web01" under the server "Office". A folder or server that matches
/// on its own keeps all its children; otherwise only the matching branches are kept.
enum SidebarFilter {
    static func words(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func apply(_ rows: [SidebarRow], query: String) -> [SidebarRow] {
        let words = words(query)
        return words.isEmpty ? rows : filter(rows, remaining: words)
    }

    private static func filter(_ rows: [SidebarRow], remaining: [String]) -> [SidebarRow] {
        rows.compactMap { row in
            let text = fold(([row.title, row.badge ?? ""] + row.keywords).joined(separator: " "))
            let unmatched = remaining.filter { !text.contains($0) }
            if unmatched.isEmpty { return row }
            guard let children = row.children else { return nil }
            let kept = filter(children, remaining: unmatched)
            guard !kept.isEmpty else { return nil }
            var copy = row
            copy.children = kept
            return copy
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

struct SidebarMenuItem {
    var title: String
    var symbol: String? = nil
    var isSeparator = false
    var action: (() -> Void)? = nil

    static let separator = SidebarMenuItem(title: "", isSeparator: true)
}

@MainActor
extension AppModel {
    func sidebarRows() -> [SidebarRow] {
        library.items.map(row(for:))
    }

    private func row(for item: LibraryItem) -> SidebarRow {
        switch item.kind {
        case .folder:
            return SidebarRow(id: .item(item.id), title: item.name, symbol: "folder",
                              children: item.children.map(row(for:)), isFolder: true, isMovable: true)
        case .ssh:
            let c = item.ssh ?? SSHConfig()
            return SidebarRow(id: .item(item.id), title: item.name, detail: c.host, symbol: "terminal",
                              keywords: [c.host, c.username], isMovable: true)
        case .proxmox:
            let state = proxmox.state(item.id)
            var detail: String?
            var tint: SidebarRow.Tint = .accent
            if state.isLoading { detail = String(localized: "loading…") }
            else if state.error != nil { detail = String(localized: "error"); tint = .warning }
            else if state.lastRefresh != nil { detail = "\(state.guests.count)" }

            let guestRows: (String) -> [SidebarRow] = { node in
                state.guests.filter { $0.node == node }.map { self.guestRow(server: item.id, $0) }
            }
            var children: [SidebarRow]
            if state.nodes.count == 1, let node = state.nodes.first {
                children = [nodeRow(server: item.id, node, children: nil)] + guestRows(node.name)
            } else {
                children = state.nodes.map { nodeRow(server: item.id, $0, children: guestRows($0.name)) }
            }
            return SidebarRow(id: .item(item.id), title: item.name, detail: detail, symbol: "server.rack",
                              tint: tint, keywords: [item.proxmox?.host ?? ""], children: children, isMovable: true)
        }
    }

    private func nodeRow(server: UUID, _ node: PVENodeInfo, children: [SidebarRow]?) -> SidebarRow {
        SidebarRow(id: .node(server: server, node: node.name), title: node.name,
                   detail: children == nil ? String(localized: "node shell") : node.ip, symbol: "cpu",
                   tint: node.online ? .running : .stopped, keywords: [node.ip ?? ""], children: children)
    }

    private func guestRow(server: UUID, _ guest: PVEGuest) -> SidebarRow {
        let override = serverItem(server)?.proxmox?.guestOverrides[String(guest.vmid)]
        let address = (override?.sshHost).flatMap { $0.isEmpty ? nil : $0 } ?? guest.ips.first
        let symbol = guest.isTemplate ? "doc.on.doc" : (guest.type == .qemu ? "desktopcomputer" : "shippingbox")
        return SidebarRow(id: .guest(server: server, vmid: guest.vmid), title: guest.name,
                          detail: address, badge: String(guest.vmid),
                          symbol: symbol, tint: guest.isRunning ? .running : .stopped,
                          keywords: guest.ips + [override?.sshHost ?? ""])
    }

    // MARK: Context menus

    func menuItems(for id: SidebarID?) -> [SidebarMenuItem] {
        let newItems: (UUID?) -> [SidebarMenuItem] = { parent in [
            SidebarMenuItem(title: String(localized: "New SSH Connection…"), symbol: "terminal") { self.editor = .newItem(.ssh, parent: parent) },
            SidebarMenuItem(title: String(localized: "New Proxmox Server…"), symbol: "server.rack") { self.editor = .newItem(.proxmox, parent: parent) },
            SidebarMenuItem(title: String(localized: "New Folder…"), symbol: "folder.badge.plus") { self.editor = .newItem(.folder, parent: parent) },
        ] }

        guard let id else { return newItems(nil) }
        let terminal = Prefs.preferredTerminal
        let sshItems: [SidebarMenuItem] = sshTarget(for: id) == nil ? [] : [
            SidebarMenuItem(title: String(localized: "Connect (\(terminal.label))"), symbol: "bolt.fill") { self.connect(id) },
        ] + TerminalChoice.allCases.filter { $0 != terminal && $0.isInstalled }.map { choice in
            SidebarMenuItem(title: choice.connectInTitle, symbol: choice == .builtin ? "rectangle.split.3x1" : "arrow.up.forward.app") {
                self.connect(id, in: choice)
            }
        }

        switch id {
        case .item(let uuid):
            guard let item = library.item(uuid) else { return [] }
            switch item.kind {
            case .folder:
                return newItems(uuid) + [.separator,
                    SidebarMenuItem(title: String(localized: "Rename…"), symbol: "pencil") { self.editor = .edit(uuid) },
                    SidebarMenuItem(title: String(localized: "Delete…"), symbol: "trash") { self.delete(uuid) }]
            case .ssh:
                return sshItems + [.separator,
                    SidebarMenuItem(title: String(localized: "Edit…"), symbol: "pencil") { self.editor = .edit(uuid) },
                    SidebarMenuItem(title: String(localized: "Duplicate"), symbol: "plus.square.on.square") { self.library.duplicate(uuid) },
                    SidebarMenuItem(title: String(localized: "Copy Host"), symbol: "doc.on.clipboard") { self.copyToPasteboard(item.ssh?.host ?? "") },
                    .separator,
                    SidebarMenuItem(title: String(localized: "Delete…"), symbol: "trash") { self.delete(uuid) }]
            case .proxmox:
                return [
                    SidebarMenuItem(title: String(localized: "Refresh"), symbol: "arrow.clockwise") { Task { await self.proxmox.refresh(uuid) } },
                    SidebarMenuItem(title: String(localized: "Open Web UI"), symbol: "safari") { self.openWebUI(server: uuid) },
                    .separator,
                    SidebarMenuItem(title: String(localized: "Edit…"), symbol: "pencil") { self.editor = .edit(uuid) },
                    SidebarMenuItem(title: String(localized: "Log Out"), symbol: "rectangle.portrait.and.arrow.right") { self.proxmox.logout(uuid) },
                    .separator,
                    SidebarMenuItem(title: String(localized: "Delete…"), symbol: "trash") { self.delete(uuid) },
                ]
            }

        case .node(let server, let node):
            return [
                SidebarMenuItem(title: String(localized: "Node Shell (Proxmox console)"), symbol: "rectangle.terminal") {
                    self.openConsole(server: server, kind: .nodeShell, node: node, vmid: nil, name: nil)
                },
            ] + sshItems + [
                .separator,
                SidebarMenuItem(title: String(localized: "Copy Address"), symbol: "doc.on.clipboard") {
                    self.copyToPasteboard(self.proxmox.nodeInfo(server: server, node: node)?.ip ?? "")
                },
            ]

        case .guest(let server, let vmid):
            guard let guest = proxmox.guest(server: server, vmid: vmid) else { return [] }
            var items = sshItems
            if !items.isEmpty { items.append(.separator) }
            if guest.type == .lxc {
                items.append(SidebarMenuItem(title: String(localized: "Console (Proxmox)"), symbol: "rectangle.terminal") {
                    self.openGuestConsole(server: server, vmid: vmid)
                })
            } else {
                items.append(SidebarMenuItem(title: String(localized: "Console — noVNC (Proxmox)"), symbol: "display") {
                    self.openGuestConsole(server: server, vmid: vmid)
                })
                items.append(SidebarMenuItem(title: String(localized: "Console — Serial / xterm.js (Proxmox)"), symbol: "rectangle.terminal") {
                    self.openGuestConsole(server: server, vmid: vmid, preferXterm: true)
                })
            }
            items += [
                .separator,
                SidebarMenuItem(title: String(localized: "SSH Settings…"), symbol: "slider.horizontal.3") { self.editor = .guest(server: server, vmid: vmid) },
            ]
            if let ip = sshTarget(for: id)?.host {
                items.append(SidebarMenuItem(title: String(localized: "Copy Address (\(ip))"), symbol: "doc.on.clipboard") { self.copyToPasteboard(ip) })
            }
            return items
        }
    }
}
