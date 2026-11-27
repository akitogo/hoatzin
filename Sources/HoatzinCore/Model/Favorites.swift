import Foundation

// Favourites are kept in the library, so they are the same on every Mac and iPhone that syncs
// it: a flag on SSH connections and Proxmox servers, and lists of nodes and guests on their
// server. Older versions of the apps ignore these fields when reading the library.

/// A favourite guest of a Proxmox server.
public struct FavoriteGuest: Codable, Hashable, Sendable {
    public var vmid: Int
    /// Its name and type when it was last seen, so it can be shown before its server is loaded.
    public var name: String
    public var type: GuestType?

    public init(vmid: Int, name: String, type: GuestType?) {
        self.vmid = vmid
        self.name = name
        self.type = type
    }
}

/// One favourite as the apps list it.
public struct Favorite: Identifiable, Hashable {
    public var id: EntryID
    public var name: String
    /// The Proxmox server of a node or guest.
    public var serverName: String?
    /// SSH connection or Proxmox server; nil for nodes and guests.
    public var kind: ItemKind?
    public var guestType: GuestType?

    public init(id: EntryID, name: String, serverName: String? = nil, kind: ItemKind? = nil, guestType: GuestType? = nil) {
        self.id = id
        self.name = name
        self.serverName = serverName
        self.kind = kind
        self.guestType = guestType
    }
}

@MainActor
extension LibraryStore {
    /// The favourites in library order; a server's nodes before its guests, guests by VMID.
    public var favorites: [Favorite] {
        var out: [Favorite] = []
        func walk(_ list: [LibraryItem]) {
            for item in list {
                if item.favorite == true, item.kind != .folder {
                    out.append(Favorite(id: .item(item.id), name: item.name, kind: item.kind))
                }
                if let config = item.proxmox {
                    for node in config.favoriteNodes ?? [] {
                        out.append(Favorite(id: .node(server: item.id, node: node), name: node, serverName: item.name))
                    }
                    for guest in (config.favoriteGuests ?? []).sorted(by: { $0.vmid < $1.vmid }) {
                        out.append(Favorite(id: .guest(server: item.id, vmid: guest.vmid), name: guest.name,
                                            serverName: item.name, guestType: guest.type))
                    }
                }
                walk(item.children)
            }
        }
        walk(items)
        return out
    }

    public func isFavorite(_ id: EntryID) -> Bool {
        switch id {
        case .item(let uuid):
            return item(uuid)?.favorite == true
        case .node(let server, let node):
            return item(server)?.proxmox?.favoriteNodes?.contains(node) == true
        case .guest(let server, let vmid):
            return item(server)?.proxmox?.favoriteGuests?.contains { $0.vmid == vmid } == true
        }
    }

    /// Adds or removes a favourite. A guest needs `guest`, its name and type to show until its
    /// server is loaded.
    public func setFavorite(_ id: EntryID, _ on: Bool, guest: PVEGuest? = nil) {
        guard isFavorite(id) != on else { return }
        switch id {
        case .item(let uuid):
            guard let item = item(uuid), item.kind != .folder else { return }
            modify(uuid) { $0.favorite = on ? true : nil }
        case .node(let server, let node):
            guard item(server)?.proxmox != nil else { return }
            modify(server) { item in
                var nodes = item.proxmox?.favoriteNodes ?? []
                if on { nodes.append(node) } else { nodes.removeAll { $0 == node } }
                nodes.sort { $0.localizedStandardCompare($1) == .orderedAscending }
                item.proxmox?.favoriteNodes = nodes.isEmpty ? nil : nodes
            }
        case .guest(let server, let vmid):
            guard item(server)?.proxmox != nil else { return }
            modify(server) { item in
                var guests = item.proxmox?.favoriteGuests ?? []
                if on {
                    guests.append(FavoriteGuest(vmid: vmid, name: guest?.name ?? "\(vmid)", type: guest?.type))
                } else {
                    guests.removeAll { $0.vmid == vmid }
                }
                guests.sort { $0.vmid < $1.vmid }
                item.proxmox?.favoriteGuests = guests.isEmpty ? nil : guests
            }
        }
    }

    /// Keeps the names and types of a server's favourite guests as Proxmox reports them.
    public func updateFavoriteGuests(server: UUID, from guests: [PVEGuest]) {
        guard let favorites = item(server)?.proxmox?.favoriteGuests, !favorites.isEmpty else { return }
        let byID = Dictionary(guests.map { ($0.vmid, $0) }, uniquingKeysWith: { first, _ in first })
        let updated = favorites.map { favorite -> FavoriteGuest in
            guard let guest = byID[favorite.vmid] else { return favorite }
            return FavoriteGuest(vmid: favorite.vmid, name: guest.name, type: guest.type)
        }
        guard updated != favorites else { return }
        modify(server) { $0.proxmox?.favoriteGuests = updated }
    }
}
