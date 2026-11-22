import SwiftUI

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
            // Debug aid: HOATZIN_AUTOCONNECT=<entry name> connects to that entry on launch.
            guard let name = ProcessInfo.processInfo.environment["HOATZIN_AUTOCONNECT"] else { return }
            func find(_ items: [LibraryItem]) -> LibraryItem? {
                for item in items {
                    if item.kind == .ssh && item.name == name { return item }
                    if let hit = find(item.children) { return hit }
                }
                return nil
            }
            if let item = find(model.library.items) {
                model.selection = .item(item.id)
                model.connect(.item(item.id))
            }
        }
    }
}
