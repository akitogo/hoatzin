import SwiftUI
import HoatzinCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.addressTruncation) private var addressTruncation: AddressTruncation = .start

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarOutline(
                rows: SidebarFilter.apply(model.sidebarRows(), query: model.sidebarFilter),
                filter: $model.sidebarFilter,
                focusFilterRequest: model.filterFocusRequest,
                selection: $model.selection,
                menuItems: { model.menuItems(for: $0) },
                onActivate: { model.activate($0) },
                onMove: { id, folder, index in model.library.move(id, to: folder, index: index) },
                addressTruncation: addressTruncation.lineBreakMode
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 320, max: 520)
        } detail: {
            DetailView()
                .sheet(item: $model.editor) { request in
                    EditorSheet(request: request).environment(model)
                }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Menu {
                    ForEach(Array(model.menuItems(for: nil).enumerated()), id: \.offset) { _, entry in
                        Button(entry.title) { entry.action?() }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add connection, Proxmox server or folder")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if let id = model.selection { model.connect(id) }
                } label: {
                    Label("Connect", systemImage: "bolt.fill")
                }
                .disabled(model.selection.flatMap { model.sshTarget(for: $0) } == nil)
                .help("Connect via SSH")

                Button {
                    Task { await model.proxmox.refreshAll() }
                } label: {
                    Label("Refresh Proxmox", systemImage: "arrow.clockwise")
                }
                .help("Reload VMs and containers from all Proxmox servers")
            }
        }
        .focusedSceneValue(\.isMainWindow, true)
        .sheet(item: Binding(get: { model.prompts.current }, set: { _ in })) { pending in
            PromptSheet(pending: pending).environment(model)
        }
        .alert("Hoatzin", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .task {
            model.sync.start()
            model.startAIControl()
            await model.proxmox.refreshAll()
        }
        .task(id: ConnectionEntity.signature(in: model)) {
            // Siri's phrases and the Spotlight index follow the sidebar, once changes settle.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await IntentsSync.update(model)
        }
        .task {
            // Debug aids: HOATZIN_SELECT=<entry name> selects that entry on launch,
            // HOATZIN_AUTOCONNECT=<entry name> connects to that SSH entry.
            let environment = ProcessInfo.processInfo.environment
            func find(_ name: String, in items: [LibraryItem], ssh: Bool) -> LibraryItem? {
                for item in items {
                    if item.name == name && (!ssh || item.kind == .ssh) { return item }
                    if let hit = find(name, in: item.children, ssh: ssh) { return hit }
                }
                return nil
            }
            if let name = environment["HOATZIN_SELECT"] {
                // A library entry, or else a Proxmox node or guest of that name.
                if let item = find(name, in: model.library.items, ssh: false) {
                    model.selection = .item(item.id)
                } else {
                    for server in model.library.proxmoxServers {
                        let state = model.proxmox.state(server.id)
                        if state.nodes.contains(where: { $0.name == name }) {
                            model.selection = .node(server: server.id, node: name)
                        } else if let guest = state.guests.first(where: { $0.name == name }) {
                            model.selection = .guest(server: server.id, vmid: guest.vmid)
                        }
                    }
                }
            }
            if let name = environment["HOATZIN_AUTOCONNECT"], let item = find(name, in: model.library.items, ssh: true) {
                model.selection = .item(item.id)
                model.connect(.item(item.id))
            }
        }
    }
}
