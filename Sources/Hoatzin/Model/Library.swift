import Foundation
import Observation

// MARK: - Persisted model
//
// Everything in here is written to ~/Library/Application Support/Hoatzin/library.json.
// It must never contain a secret: passwords, passphrases and tickets live only in the
// macOS Keychain or in memory.

enum ItemKind: String, Codable {
    case folder, ssh, proxmox
}

enum SSHAuthMode: String, Codable, CaseIterable, Identifiable {
    /// Password from the Keychain; asked (with Passwords AutoFill) before connecting if missing.
    case password
    /// Key file / ssh-agent. A password is only asked for if the server falls back to it.
    case key

    var id: String { rawValue }
    var label: String {
        switch self {
        case .password: return String(localized: "Password (Keychain / Passwords)")
        case .key: return String(localized: "SSH key / agent")
        }
    }
}

struct SSHConfig: Codable, Hashable {
    var host: String = ""
    var port: Int = 22
    var username: String = "root"
    var auth: SSHAuthMode = .password
    var identityFile: String = ""
    /// Host name the password is filed under in the Keychain. Empty = `host`.
    var keychainHost: String = ""
    /// Additional raw ssh arguments, e.g. "-A -J jump@bastion".
    var extraArgs: String = ""

    var effectiveKeychainHost: String {
        let trimmed = keychainHost.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? host : trimmed
    }
}

struct GuestOverride: Codable, Hashable {
    var sshHost: String = ""
    var sshUser: String = ""
    var sshPort: Int? = nil
    var keychainHost: String = ""
    /// nil = the server's / app's default.
    var sshAuth: SSHAuthMode? = nil
}

struct ProxmoxConfig: Codable, Hashable {
    var host: String = ""
    var port: Int = 8006
    var username: String = "root"
    var realm: String = "pam"
    /// Host name the Proxmox password is filed under in the Keychain. Empty = `host`.
    var keychainHost: String = ""
    /// SHA-256 fingerprint of the accepted (usually self-signed) certificate.
    var pinnedSHA256: String? = nil

    // SSH into guests discovered on this server. Empty / nil = the app-wide defaults (Settings).
    // Node shells / SSH to the nodes themselves use the Proxmox login user instead.
    var sshUsername: String = ""
    var sshAuth: SSHAuthMode? = nil
    var sshIdentityFile: String = ""

    /// Per-guest SSH settings, keyed by VMID.
    var guestOverrides: [String: GuestOverride] = [:]

    /// Linux user of the Proxmox login ("root" for root@pam).
    var loginUser: String {
        String(username.split(separator: "@").first ?? Substring(username))
    }

    var apiUser: String {
        username.contains("@") ? username : "\(username)@\(realm)"
    }

    var effectiveKeychainHost: String {
        let trimmed = keychainHost.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? host : trimmed
    }
}

struct LibraryItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var kind: ItemKind
    var name: String
    var children: [LibraryItem] = []
    var ssh: SSHConfig? = nil
    var proxmox: ProxmoxConfig? = nil

    static func folder(_ name: String) -> LibraryItem {
        LibraryItem(kind: .folder, name: name)
    }

    static func sshConnection(_ name: String, config: SSHConfig = SSHConfig()) -> LibraryItem {
        LibraryItem(kind: .ssh, name: name, ssh: config)
    }

    static func proxmoxServer(_ name: String, config: ProxmoxConfig = ProxmoxConfig()) -> LibraryItem {
        LibraryItem(kind: .proxmox, name: name, proxmox: config)
    }
}

private struct LibraryFile: Codable {
    static let currentVersion = 2
    var version: Int = LibraryFile.currentVersion
    var items: [LibraryItem]
}

// MARK: - Store

@MainActor
@Observable
final class LibraryStore {
    private(set) var items: [LibraryItem] = []
    var loadError: String?

    let fileURL: URL

    nonisolated static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Hoatzin", isDirectory: true).appendingPathComponent("library.json")
    }

    init(fileURL: URL = LibraryStore.defaultURL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try JSONDecoder().decode(LibraryFile.self, from: data)
            items = file.items
            if file.version < LibraryFile.currentVersion {
                items = Self.migrate(items, from: file.version)
                save()
            }
        } catch {
            loadError = String(localized: "Could not read \(fileURL.path): \(error.localizedDescription)")
        }
    }

    /// v1 stored "root"/password as fixed guest SSH settings; untouched values now mean
    /// "use the app-wide default".
    private static func migrate(_ list: [LibraryItem], from version: Int) -> [LibraryItem] {
        list.map { item in
            var item = item
            item.children = migrate(item.children, from: version)
            if version < 2, var config = item.proxmox,
               config.sshUsername == "root", config.sshAuth == .password, config.sshIdentityFile.isEmpty {
                config.sshUsername = ""
                config.sshAuth = nil
                item.proxmox = config
            }
            return item
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(LibraryFile(items: items))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("Hoatzin: saving library failed: \(error)")
        }
    }

    // MARK: Queries

    func item(_ id: UUID) -> LibraryItem? {
        Self.find(id, in: items)
    }

    private static func find(_ id: UUID, in list: [LibraryItem]) -> LibraryItem? {
        for item in list {
            if item.id == id { return item }
            if let hit = find(id, in: item.children) { return hit }
        }
        return nil
    }

    func parentID(of id: UUID) -> UUID? {
        func search(_ list: [LibraryItem], parent: UUID?) -> UUID?? {
            for item in list {
                if item.id == id { return .some(parent) }
                if let hit = search(item.children, parent: item.id) { return hit }
            }
            return nil
        }
        return search(items, parent: nil) ?? nil
    }

    /// All folders as (id, "Parent / Child") for pickers.
    var folderPaths: [(id: UUID, path: String)] {
        var out: [(UUID, String)] = []
        func walk(_ list: [LibraryItem], prefix: String) {
            for item in list where item.kind == .folder {
                let path = prefix.isEmpty ? item.name : "\(prefix) / \(item.name)"
                out.append((item.id, path))
                walk(item.children, prefix: path)
            }
        }
        walk(items, prefix: "")
        return out.map { (id: $0.0, path: $0.1) }
    }

    var proxmoxServers: [LibraryItem] {
        var out: [LibraryItem] = []
        func walk(_ list: [LibraryItem]) {
            for item in list {
                if item.kind == .proxmox { out.append(item) }
                walk(item.children)
            }
        }
        walk(items)
        return out
    }

    // MARK: Mutations

    func add(_ item: LibraryItem, to folderID: UUID?) {
        if let folderID, Self.mutate(folderID, in: &items, { $0.children.append(item) }) {
            // added to folder
        } else {
            items.append(item)
        }
        save()
    }

    func update(_ item: LibraryItem) {
        _ = Self.mutate(item.id, in: &items) { existing in
            let children = existing.children
            existing = item
            existing.children = children
        }
        save()
    }

    func modify(_ id: UUID, _ change: (inout LibraryItem) -> Void) {
        _ = Self.mutate(id, in: &items, change)
        save()
    }

    func remove(_ id: UUID) {
        _ = Self.detach(id, from: &items)
        save()
    }

    func duplicate(_ id: UUID) {
        guard var copy = item(id), copy.kind != .folder else { return }
        copy.id = UUID()
        copy.name = String(localized: "\(copy.name) copy")
        add(copy, to: parentID(of: id))
    }

    /// Moves `id` into `folderID` (nil = top level) at `index` (nil = end).
    func move(_ id: UUID, to folderID: UUID?, index: Int?) {
        guard id != folderID else { return }
        // Refuse to move a folder into its own subtree.
        if let folderID, let moving = item(id), Self.find(folderID, in: moving.children) != nil { return }

        let oldParent = parentID(of: id)
        var oldIndex: Int?
        if oldParent == folderID {
            let siblings = folderID.flatMap { item($0)?.children } ?? items
            oldIndex = siblings.firstIndex { $0.id == id }
        }
        guard let detached = Self.detach(id, from: &items) else { return }

        var target = index
        if let t = target, let o = oldIndex, o < t { target = t - 1 }

        func insert(into list: inout [LibraryItem]) {
            let i = min(max(target ?? list.count, 0), list.count)
            list.insert(detached, at: i)
        }
        if let folderID {
            if !Self.mutate(folderID, in: &items, { insert(into: &$0.children) }) { insert(into: &items) }
        } else {
            insert(into: &items)
        }
        save()
    }

    @discardableResult
    private static func mutate(_ id: UUID, in list: inout [LibraryItem], _ change: (inout LibraryItem) -> Void) -> Bool {
        for index in list.indices {
            if list[index].id == id {
                change(&list[index])
                return true
            }
            if mutate(id, in: &list[index].children, change) { return true }
        }
        return false
    }

    private static func detach(_ id: UUID, from list: inout [LibraryItem]) -> LibraryItem? {
        if let index = list.firstIndex(where: { $0.id == id }) {
            return list.remove(at: index)
        }
        for index in list.indices {
            if let hit = detach(id, from: &list[index].children) { return hit }
        }
        return nil
    }
}
