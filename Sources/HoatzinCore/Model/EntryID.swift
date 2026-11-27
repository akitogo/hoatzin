import Foundation

/// A library entry, or a node or guest of a Proxmox server: what both apps select, connect to
/// and keep as favourites.
public enum EntryID: Hashable, Sendable {
    case item(UUID)
    case node(server: UUID, node: String)
    case guest(server: UUID, vmid: Int)

    /// "item:UUID", "node:UUID:name" or "guest:UUID:vmid", as Shortcuts and AI apps see it.
    public var stringValue: String {
        switch self {
        case .item(let id): return "item:\(id.uuidString)"
        case .node(let server, let node): return "node:\(server.uuidString):\(node)"
        case .guest(let server, let vmid): return "guest:\(server.uuidString):\(vmid)"
        }
    }

    /// Parses `stringValue`.
    public init?(string: String) {
        let parts = string.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let uuid = UUID(uuidString: parts[1]) else { return nil }
        switch (parts[0], parts.count) {
        case ("item", 2): self = .item(uuid)
        case ("node", 3) where !parts[2].isEmpty: self = .node(server: uuid, node: parts[2])
        case ("guest", 3): guard let vmid = Int(parts[2]) else { return nil }; self = .guest(server: uuid, vmid: vmid)
        default: return nil
        }
    }

    public var libraryID: UUID? {
        if case .item(let id) = self { return id }
        return nil
    }

    /// The Proxmox server of a node or guest.
    public var serverID: UUID? {
        switch self {
        case .item: return nil
        case .node(let server, _), .guest(let server, _): return server
        }
    }
}

extension EntryID: Identifiable {
    public var id: String { stringValue }
}
