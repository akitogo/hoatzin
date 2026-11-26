import Foundation
import Observation

// MARK: - Persisted model
//
// Everything in here is written to ~/Library/Application Support/Hoatzin/library.json.
// It must never contain a secret: passwords, passphrases and tickets live only in the
// macOS Keychain or in memory.

public enum ItemKind: String, Codable {
    case folder, ssh, proxmox
}

public enum SSHAuthMode: String, Codable, CaseIterable, Identifiable {
    /// Password from the Keychain; asked (with Passwords AutoFill) before connecting if missing.
    case password
    /// Key file / ssh-agent. A password is only asked for if the server falls back to it.
    case key

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .password: return String(localized: "Password (Keychain / Passwords)")
        case .key: return String(localized: "SSH key / agent")
        }
    }
}

public struct SSHConfig: Codable, Hashable {
    public var host: String = ""
    public var port: Int = 22
    public var username: String = "root"
    public var auth: SSHAuthMode = .password
    public var identityFile: String = ""
    /// Host name the password is filed under in the Keychain. Empty = `host`.
    public var keychainHost: String = ""
    /// Additional raw ssh arguments, e.g. "-A -J jump@bastion".
    public var extraArgs: String = ""

    public init(host: String = "", port: Int = 22, username: String = "root", auth: SSHAuthMode = .password, identityFile: String = "", keychainHost: String = "", extraArgs: String = "") {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.identityFile = identityFile
        self.keychainHost = keychainHost
        self.extraArgs = extraArgs
    }

    public var effectiveKeychainHost: String {
        let trimmed = keychainHost.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? host : trimmed
    }
}

public struct GuestOverride: Codable, Hashable {
    public var sshHost: String = ""
    public var sshUser: String = ""
    public var sshPort: Int? = nil
    public var keychainHost: String = ""
    /// nil = the server's / app's default.
    public var sshAuth: SSHAuthMode? = nil

    public init(sshHost: String = "", sshUser: String = "", sshPort: Int? = nil, keychainHost: String = "", sshAuth: SSHAuthMode? = nil) {
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.keychainHost = keychainHost
        self.sshAuth = sshAuth
    }
}

public struct ProxmoxConfig: Codable, Hashable {
    public var host: String = ""
    public var port: Int = 8006
    public var username: String = "root"
    public var realm: String = "pam"
    /// Host name the Proxmox password is filed under in the Keychain. Empty = `host`.
    public var keychainHost: String = ""
    /// SHA-256 fingerprint of the accepted (usually self-signed) certificate.
    public var pinnedSHA256: String? = nil

    // SSH into guests discovered on this server. Empty / nil = the app-wide defaults (Settings).
    // Node shells / SSH to the nodes themselves use the Proxmox login user instead.
    public var sshUsername: String = ""
    public var sshAuth: SSHAuthMode? = nil
    public var sshIdentityFile: String = ""

    /// Per-guest SSH settings, keyed by VMID.
    public var guestOverrides: [String: GuestOverride] = [:]

    public init(host: String = "", port: Int = 8006, username: String = "root", realm: String = "pam", keychainHost: String = "", pinnedSHA256: String? = nil, sshUsername: String = "", sshAuth: SSHAuthMode? = nil, sshIdentityFile: String = "", guestOverrides: [String: GuestOverride] = [:]) {
        self.host = host
        self.port = port
        self.username = username
        self.realm = realm
        self.keychainHost = keychainHost
        self.pinnedSHA256 = pinnedSHA256
        self.sshUsername = sshUsername
        self.sshAuth = sshAuth
        self.sshIdentityFile = sshIdentityFile
        self.guestOverrides = guestOverrides
    }

    /// Linux user of the Proxmox login ("root" for root@pam).
    public var loginUser: String {
        String(username.split(separator: "@").first ?? Substring(username))
    }

    public var apiUser: String {
        username.contains("@") ? username : "\(username)@\(realm)"
    }

    public var effectiveKeychainHost: String {
        let trimmed = keychainHost.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? host : trimmed
    }
}

public struct LibraryItem: Identifiable, Codable, Hashable {
    public var id: UUID = UUID()
    public var kind: ItemKind
    public var name: String
    public var children: [LibraryItem] = []
    public var ssh: SSHConfig? = nil
    public var proxmox: ProxmoxConfig? = nil

    public init(id: UUID = UUID(), kind: ItemKind, name: String, children: [LibraryItem] = [], ssh: SSHConfig? = nil, proxmox: ProxmoxConfig? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.children = children
        self.ssh = ssh
        self.proxmox = proxmox
    }

    public static func folder(_ name: String) -> LibraryItem {
        LibraryItem(kind: .folder, name: name)
    }

    public static func sshConnection(_ name: String, config: SSHConfig = SSHConfig()) -> LibraryItem {
        LibraryItem(kind: .ssh, name: name, ssh: config)
    }

    public static func proxmoxServer(_ name: String, config: ProxmoxConfig = ProxmoxConfig()) -> LibraryItem {
        LibraryItem(kind: .proxmox, name: name, proxmox: config)
    }
}

/// The file format of library.json, also what iCloud sync stores (see `LibrarySync`).
public struct LibraryFile: Codable {
    public static let currentVersion = 2
    public var version: Int = LibraryFile.currentVersion
    public var items: [LibraryItem]

    public init(version: Int = LibraryFile.currentVersion, items: [LibraryItem]) {
        self.version = version
        self.items = items
    }
}

// MARK: - Store

@MainActor
@Observable
public final class LibraryStore {
    public private(set) var items: [LibraryItem] = []
    public var loadError: String?
    /// Called after each change made in this app (not after `replaceAll`), e.g. to sync it.
    @ObservationIgnored public var onChange: (() -> Void)?

    public let fileURL: URL

    public nonisolated static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Hoatzin", isDirectory: true).appendingPathComponent("library.json")
    }

    public init(fileURL: URL = LibraryStore.defaultURL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        load()
    }

    public func load() {
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
    public nonisolated static func migrate(_ list: [LibraryItem], from version: Int) -> [LibraryItem] {
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

    /// Replaces the whole library, e.g. with the one from iCloud. Does not call `onChange`.
    public func replaceAll(_ newItems: [LibraryItem]) {
        items = newItems
        write()
    }

    private func save() {
        write()
        onChange?()
    }

    private func write() {
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

    public func item(_ id: UUID) -> LibraryItem? {
        Self.find(id, in: items)
    }

    private static func find(_ id: UUID, in list: [LibraryItem]) -> LibraryItem? {
        for item in list {
            if item.id == id { return item }
            if let hit = find(id, in: item.children) { return hit }
        }
        return nil
    }

    public func parentID(of id: UUID) -> UUID? {
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
    public var folderPaths: [(id: UUID, path: String)] {
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

    public var proxmoxServers: [LibraryItem] {
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

    public func add(_ item: LibraryItem, to folderID: UUID?) {
        if let folderID, Self.mutate(folderID, in: &items, { $0.children.append(item) }) {
            // added to folder
        } else {
            items.append(item)
        }
        save()
    }

    public func update(_ item: LibraryItem) {
        _ = Self.mutate(item.id, in: &items) { existing in
            let children = existing.children
            existing = item
            existing.children = children
        }
        save()
    }

    public func modify(_ id: UUID, _ change: (inout LibraryItem) -> Void) {
        _ = Self.mutate(id, in: &items, change)
        save()
    }

    public func remove(_ id: UUID) {
        _ = Self.detach(id, from: &items)
        save()
    }

    public func duplicate(_ id: UUID) {
        guard var copy = item(id), copy.kind != .folder else { return }
        copy.id = UUID()
        copy.name = String(localized: "\(copy.name) copy")
        add(copy, to: parentID(of: id))
    }

    /// Moves `id` into `folderID` (nil = top level) at `index` (nil = end).
    public func move(_ id: UUID, to folderID: UUID?, index: Int?) {
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
