import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers

/// What kind of connection an entry is.
enum ConnectionKind: String, AppEnum {
    case ssh, vm, container, node

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Connection Kind"
    static let caseDisplayRepresentations: [ConnectionKind: DisplayRepresentation] = [
        .ssh: "SSH Host",
        .vm: "Virtual Machine",
        .container: "Container",
        .node: "Proxmox Node",
    ]
}

/// An entry you can connect to (SSH connection, Proxmox node, VM or container), for Shortcuts,
/// Siri and Spotlight. The id is the sidebar id, so it stays the same across launches.
/// Contains no secrets: names, addresses, logins and states only.
struct ConnectionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Connection", numericFormat: "\(placeholder: .int) connections")
    static let defaultQuery = ConnectionQuery()

    var id: String
    @Property(title: "Name") var name: String
    @Property(title: "Kind") var kind: ConnectionKind
    @Property(title: "Address") var address: String
    @Property(title: "SSH Login") var sshLogin: String
    @Property(title: "VMID") var vmid: Int?
    @Property(title: "Status") var status: String
    /// The folder or Proxmox server it's in.
    @Property(title: "Location") var location: String

    init(id: String, name: String, kind: ConnectionKind, address: String, sshLogin: String, vmid: Int?,
         status: String, location: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.address = address
        self.sshLogin = sshLogin
        self.vmid = vmid
        self.status = status
        self.location = location
    }

    var subtitle: String {
        switch kind {
        case .ssh:
            return sshLogin.isEmpty ? address : sshLogin
        case .vm, .container:
            let label = kind == .vm ? "VM" : "CT"
            return ["\(label) \(vmid.map(String.init) ?? "")", status, address].filter { !$0.isEmpty }.joined(separator: " · ")
        case .node:
            return ["Node", status, address].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    var symbol: String {
        switch kind {
        case .ssh: return "terminal"
        case .vm: return "desktopcomputer"
        case .container: return "shippingbox"
        case .node: return "cpu"
        }
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)", image: .init(systemName: symbol))
    }
}

@available(macOS 15.0, *)
extension ConnectionEntity: IndexedEntity {
    /// What Spotlight shows and searches: the name, plus address, login, VMID and location.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = name
        attributes.displayName = name
        attributes.contentDescription = subtitle
        attributes.keywords = [address, sshLogin, vmid.map(String.init) ?? "", location].filter { !$0.isEmpty }
        return attributes
    }
}

extension ConnectionEntity {
    /// Every entry that can be opened, in sidebar order. Templates are left out.
    @MainActor
    static func all(in model: AppModel) -> [ConnectionEntity] {
        collect(model.sidebarRows(), location: "", model: model)
    }

    /// Entries matching `query` the way the sidebar filter does ("office web", "10.20.30", "101").
    @MainActor
    static func matching(_ query: String, in model: AppModel) -> [ConnectionEntity] {
        collect(SidebarFilter.apply(model.sidebarRows(), query: query), location: "", model: model)
    }

    @MainActor
    private static func collect(_ rows: [SidebarRow], location: String, model: AppModel) -> [ConnectionEntity] {
        rows.flatMap { row -> [ConnectionEntity] in
            let here = entity(for: row.id, location: location, model: model).map { [$0] } ?? []
            let inside: String
            switch row.id {
            case .item: inside = row.isFolder || row.children != nil ? row.title : location
            case .node, .guest: inside = location
            }
            return here + collect(row.children ?? [], location: inside, model: model)
        }
    }

    @MainActor
    static func entity(for id: SidebarID, location: String = "", model: AppModel) -> ConnectionEntity? {
        let login = model.sshTarget(for: id)?.userAtHost ?? ""
        switch id {
        case .item(let uuid):
            guard let item = model.library.item(uuid), item.kind == .ssh else { return nil }
            let config = item.ssh ?? SSHConfig()
            return ConnectionEntity(id: id.stringValue, name: item.name, kind: .ssh, address: config.host, sshLogin: login,
                                    vmid: nil, status: "", location: location)
        case .node(let server, let node):
            let info = model.proxmox.nodeInfo(server: server, node: node)
            return ConnectionEntity(id: id.stringValue, name: node, kind: .node, address: info?.ip ?? "", sshLogin: login,
                                    vmid: nil, status: info.map { $0.online ? "online" : "offline" } ?? "",
                                    location: model.library.item(server)?.name ?? location)
        case .guest(let server, let vmid):
            guard let guest = model.proxmox.guest(server: server, vmid: vmid), !guest.isTemplate else { return nil }
            return ConnectionEntity(id: id.stringValue, name: guest.name, kind: guest.type == .qemu ? .vm : .container,
                                    address: guest.ips.first ?? "", sshLogin: login, vmid: vmid, status: guest.status,
                                    location: model.library.item(server)?.name ?? location)
        }
    }

    /// Changes whenever something Shortcuts or Spotlight shows changes.
    @MainActor
    static func signature(in model: AppModel) -> Int {
        all(in: model).map { "\($0.id)|\($0.name)|\($0.subtitle)|\($0.location)" }.joined(separator: "\n").hashValue
    }
}

struct ConnectionQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ConnectionEntity] {
        let model = try AppModel.forIntents()
        var all = ConnectionEntity.all(in: model)
        if identifiers.contains(where: { id in !all.contains { $0.id == id } }) {
            await model.loadProxmoxIfNeeded()
            all = ConnectionEntity.all(in: model)
        }
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ConnectionEntity] {
        let model = try AppModel.forIntents()
        await model.loadProxmoxIfNeeded()
        return ConnectionEntity.matching(string, in: model)
    }

    @MainActor
    func suggestedEntities() async throws -> [ConnectionEntity] {
        let model = try AppModel.forIntents()
        await model.loadProxmoxIfNeeded()
        return ConnectionEntity.all(in: model)
    }
}
