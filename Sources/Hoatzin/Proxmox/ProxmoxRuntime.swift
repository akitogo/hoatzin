import Foundation
import Observation

enum GuestType: String, Hashable {
    case qemu, lxc

    var label: String { self == .qemu ? "VM" : "CT" }
}

struct PVEGuest: Identifiable, Hashable {
    var vmid: Int
    var name: String
    var node: String
    var type: GuestType
    var status: String
    var isTemplate: Bool
    var ips: [String] = []

    var id: Int { vmid }
    var isRunning: Bool { status == "running" }
}

struct PVENodeInfo: Identifiable, Hashable {
    var name: String
    var online: Bool
    var ip: String?

    var id: String { name }
}

enum ConsoleKind {
    case lxc, qemuNoVNC, qemuXterm, nodeShell
}

/// Live (never persisted) state of the configured Proxmox servers.
@MainActor
@Observable
final class ProxmoxRuntime {
    struct ServerState {
        var nodes: [PVENodeInfo] = []
        var guests: [PVEGuest] = []
        var isLoading = false
        var error: String?
        var lastRefresh: Date?
        var loggedInAs: String?
    }

    private(set) var states: [UUID: ServerState] = [:]
    @ObservationIgnored private var clients: [UUID: ProxmoxClient] = [:]
    @ObservationIgnored private var logins: [UUID: Task<ProxmoxClient, Error>] = [:]

    let library: LibraryStore
    let broker: CredentialBroker
    let prompts: PromptCenter

    init(library: LibraryStore, broker: CredentialBroker, prompts: PromptCenter) {
        self.library = library
        self.broker = broker
        self.prompts = prompts
    }

    func state(_ serverID: UUID) -> ServerState {
        states[serverID] ?? ServerState()
    }

    func guest(server: UUID, vmid: Int) -> PVEGuest? {
        states[server]?.guests.first { $0.vmid == vmid }
    }

    func nodeInfo(server: UUID, node: String) -> PVENodeInfo? {
        states[server]?.nodes.first { $0.name == node }
    }

    // MARK: Clients & login

    private func client(for item: LibraryItem) -> ProxmoxClient? {
        guard let config = item.proxmox, !config.host.isEmpty else { return nil }
        if let existing = clients[item.id], existing.host == config.host, existing.port == config.port {
            existing.pinned = config.pinnedSHA256
            return existing
        }
        let client = ProxmoxClient(host: config.host, port: config.port, pinned: config.pinnedSHA256)
        clients[item.id] = client
        return client
    }

    /// Returns a client with a valid ticket, logging in (and asking for trust / password / OTP) if needed.
    /// Concurrent callers share one login.
    func authenticatedClient(_ serverID: UUID) async throws -> ProxmoxClient {
        if let running = logins[serverID] { return try await running.value }
        guard let item = library.item(serverID), let client = client(for: item) else {
            throw ProxmoxError.transport(String(localized: "Proxmox server has no host configured."))
        }
        if client.hasValidTicket { return client }

        let task = Task { @MainActor in
            try await self.login(serverID: serverID, client: client)
            return client
        }
        logins[serverID] = task
        defer { logins[serverID] = nil }
        return try await task.value
    }

    func logout(_ serverID: UUID) {
        clients[serverID]?.invalidateTicket()
        clients[serverID] = nil
        states[serverID]?.loggedInAs = nil
    }

    private func login(serverID: UUID, client: ProxmoxClient) async throws {
        try await ensureTrusted(serverID: serverID, client: client)

        var attempt = 0
        while true {
            guard let item = library.item(serverID), let config = item.proxmox else { throw CancellationError() }
            let key = CredentialKey(server: config.effectiveKeychainHost, account: config.username, proto: .https, port: config.port)
            guard let credential = await broker.resolve(
                key,
                title: String(localized: "Proxmox login — \(item.name)"),
                message: attempt == 0
                    ? String(localized: "No saved password for \(key.display). Pick it from Passwords (AutoFill) or type it.")
                    : String(localized: "Login failed. Check user name, realm and password."),
                forcePrompt: attempt > 0,
                isRetry: attempt > 0
            ) else { throw CancellationError() }

            let account = credential.key.account
            let apiUser = account.contains("@") ? account : "\(account)@\(config.realm)"
            do {
                try await performLogin(client: client, user: apiUser, password: credential.secret, serverName: item.name)
            } catch ProxmoxError.authenticationFailed {
                attempt += 1
                if attempt >= 4 { throw ProxmoxError.authenticationFailed }
                continue
            }

            await broker.commit(credential)
            if account != config.username {
                library.modify(serverID) { $0.proxmox?.username = account }
            }
            states[serverID, default: ServerState()].loggedInAs = client.user ?? apiUser
            return
        }
    }

    private func performLogin(client: ProxmoxClient, user: String, password: String, serverName: String) async throws {
        do {
            try await client.login(user: user, password: password)
        } catch ProxmoxError.needsTFA(let challenge) {
            guard let code = await prompts.askText(TextPrompt(
                title: String(localized: "Two-factor code — \(serverName)"),
                message: String(localized: "Enter the TOTP code from your authenticator (or recovery:KEY)."),
                placeholder: "123456",
                secure: false
            )) else { throw CancellationError() }
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            let response = trimmed.contains(":") ? trimmed : "totp:\(trimmed)"
            try await client.completeTFA(user: user, challenge: challenge, response: response)
        }
    }

    /// Trust-on-first-use for the (typically self-signed) Proxmox certificate.
    private func ensureTrusted(serverID: UUID, client: ProxmoxClient) async throws {
        for _ in 0..<2 {
            do {
                try await client.probe()
                return
            } catch ProxmoxError.untrustedCertificate(let fingerprint, let changed) {
                let name = library.item(serverID)?.name ?? client.host
                let ok = await prompts.confirm(ConfirmPrompt(
                    title: changed ? String(localized: "Certificate changed — \(name)") : String(localized: "Trust certificate — \(name)?"),
                    message: changed
                        ? String(localized: "The certificate of \(client.host):\(String(client.port)) is different from the one you trusted before. Only continue if you renewed it.")
                        : String(localized: "\(client.host):\(String(client.port)) uses a certificate macOS does not trust (normal for Proxmox' self-signed certificate). Compare the fingerprint with Datacenter › Node › System › Certificates."),
                    detail: "SHA-256\n\(fingerprint)",
                    confirmTitle: String(localized: "Trust"),
                    destructive: changed
                ))
                guard ok else { throw CancellationError() }
                library.modify(serverID) { $0.proxmox?.pinnedSHA256 = fingerprint }
                client.pinned = fingerprint
            }
        }
        try await client.probe()
    }

    // MARK: Refresh

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for server in library.proxmoxServers {
                group.addTask { await self.refresh(server.id) }
            }
        }
    }

    func refresh(_ serverID: UUID) async {
        guard library.item(serverID)?.proxmox != nil else { return }
        states[serverID, default: ServerState()].isLoading = true
        defer { states[serverID]?.isLoading = false }

        do {
            try await load(serverID)
        } catch ProxmoxError.notLoggedIn {
            do { try await load(serverID) } catch { record(error, for: serverID) }
        } catch {
            record(error, for: serverID)
        }
    }

    private func record(_ error: Error, for serverID: UUID) {
        if error is CancellationError {
            states[serverID]?.error = String(localized: "Login cancelled.")
        } else {
            states[serverID]?.error = error.localizedDescription
        }
    }

    private func load(_ serverID: UUID) async throws {
        let client = try await authenticatedClient(serverID)
        let serverHost = client.host

        let nodesData = try await client.get("/nodes") as? [[String: Any]] ?? []
        let clusterStatus = (try? await client.get("/cluster/status")) as? [[String: Any]] ?? []
        let resources = try await client.get("/cluster/resources?type=vm") as? [[String: Any]] ?? []

        var nodeIPs: [String: String] = [:]
        for entry in clusterStatus where entry["type"] as? String == "node" {
            if let name = entry["name"] as? String, let ip = entry["ip"] as? String { nodeIPs[name] = ip }
        }
        let nodes = nodesData.compactMap { entry -> PVENodeInfo? in
            guard let name = entry["node"] as? String else { return nil }
            return PVENodeInfo(name: name, online: (entry["status"] as? String) == "online", ip: nodeIPs[name] ?? (nodesData.count == 1 ? serverHost : nil))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let previous = Dictionary(uniqueKeysWithValues: (states[serverID]?.guests ?? []).map { ($0.vmid, $0.ips) })
        var guests = resources.compactMap { entry -> PVEGuest? in
            guard let vmid = ProxmoxClient.int(entry["vmid"]),
                  let node = entry["node"] as? String,
                  let type = GuestType(rawValue: entry["type"] as? String ?? "")
            else { return nil }
            return PVEGuest(
                vmid: vmid,
                name: entry["name"] as? String ?? "\(type.label) \(vmid)",
                node: node,
                type: type,
                status: entry["status"] as? String ?? "unknown",
                isTemplate: ProxmoxClient.int(entry["template"]) == 1,
                ips: previous[vmid] ?? []
            )
        }
        guests.sort { $0.vmid < $1.vmid }

        states[serverID, default: ServerState()].nodes = nodes
        states[serverID]?.guests = guests
        states[serverID]?.error = nil
        states[serverID]?.lastRefresh = Date()

        // Discover addresses (guest agent / LXC interfaces / static config) in the background.
        let targets = guests.filter { !$0.isTemplate }
        await withTaskGroup(of: (Int, [String]).self) { group in
            var iterator = targets.makeIterator()
            func addNext() {
                guard let guest = iterator.next() else { return }
                group.addTask { (guest.vmid, await Self.discoverIPs(client: client, guest: guest, near: serverHost)) }
            }
            for _ in 0..<8 { addNext() }
            for await (vmid, ips) in group {
                if !ips.isEmpty, let index = states[serverID]?.guests.firstIndex(where: { $0.vmid == vmid }) {
                    states[serverID]?.guests[index].ips = ips
                }
                addNext()
            }
        }
    }

    // MARK: IP discovery

    nonisolated private static func discoverIPs(client: ProxmoxClient, guest: PVEGuest, near: String) async -> [String] {
        var found: [String] = []
        let base = "/nodes/\(guest.node)/\(guest.type.rawValue)/\(guest.vmid)"

        if guest.isRunning {
            switch guest.type {
            case .qemu:
                if let data = try? await client.get(base + "/agent/network-get-interfaces") as? [String: Any],
                   let interfaces = data["result"] as? [[String: Any]] {
                    for iface in interfaces where !isIgnoredInterface(iface["name"] as? String) {
                        for addr in iface["ip-addresses"] as? [[String: Any]] ?? [] where addr["ip-address-type"] as? String == "ipv4" {
                            if let ip = addr["ip-address"] as? String { found.append(ip) }
                        }
                    }
                }
            case .lxc:
                if let interfaces = try? await client.get(base + "/interfaces") as? [[String: Any]] {
                    for iface in interfaces where !isIgnoredInterface(iface["name"] as? String) {
                        if let inet = iface["inet"] as? String { found.append(stripPrefix(inet)) }
                    }
                }
            }
        }

        if found.isEmpty, let config = try? await client.get(base + "/config") as? [String: Any] {
            // LXC: net0 = "name=eth0,bridge=vmbr0,ip=10.0.0.5/24,…"; QEMU cloud-init: ipconfig0 = "ip=10.0.0.5/24,gw=…"
            for (key, value) in config where key.hasPrefix("net") || key.hasPrefix("ipconfig") {
                guard let text = value as? String else { continue }
                for part in text.split(separator: ",") where part.hasPrefix("ip=") {
                    let ip = stripPrefix(String(part.dropFirst(3)))
                    if ip != "dhcp", ip != "manual" { found.append(ip) }
                }
            }
        }

        return rank(found.filter(isUsableIPv4), near: near)
    }

    nonisolated static func isIgnoredInterface(_ name: String?) -> Bool {
        guard let name else { return false }
        let ignored = ["lo", "docker", "br-", "veth", "virbr", "cni", "flannel", "cali", "kube", "tailscale", "zt"]
        return ignored.contains { name == $0 || name.hasPrefix($0) }
    }

    nonisolated private static func stripPrefix(_ cidr: String) -> String {
        String(cidr.split(separator: "/").first ?? Substring(cidr))
    }

    nonisolated static func isUsableIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] != 127 && !(parts[0] == 169 && parts[1] == 254)
    }

    /// Addresses sharing the most leading octets with the Proxmox host first.
    nonisolated static func rank(_ ips: [String], near host: String) -> [String] {
        let hostParts = host.split(separator: ".")
        func score(_ ip: String) -> Int {
            zip(ip.split(separator: "."), hostParts).prefix { $0 == $1 }.count
        }
        var seen = Set<String>()
        return ips.filter { seen.insert($0).inserted }.sorted { score($0) > score($1) }
    }

    // MARK: Console URLs

    func consoleURL(client: ProxmoxClient, kind: ConsoleKind, node: String, vmid: Int?, name: String?) -> URL {
        var components = URLComponents(url: client.baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/"
        var query: [URLQueryItem] = []
        switch kind {
        case .lxc: query = [.init(name: "console", value: "lxc"), .init(name: "xtermjs", value: "1")]
        case .qemuNoVNC: query = [.init(name: "console", value: "kvm"), .init(name: "novnc", value: "1"), .init(name: "resize", value: "scale")]
        case .qemuXterm: query = [.init(name: "console", value: "kvm"), .init(name: "xtermjs", value: "1")]
        case .nodeShell: query = [.init(name: "console", value: "shell"), .init(name: "xtermjs", value: "1")]
        }
        query += [
            .init(name: "vmid", value: String(vmid ?? 0)),
            .init(name: "vmname", value: name ?? ""),
            .init(name: "node", value: node),
            .init(name: "cmd", value: ""),
        ]
        components.queryItems = query
        return components.url!
    }
}
