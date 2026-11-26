import Foundation
import Observation

public enum GuestType: String, Hashable {
    case qemu, lxc

    public var label: String { self == .qemu ? "VM" : "CT" }
}

public struct PVEGuest: Identifiable, Hashable {
    public var vmid: Int
    public var name: String
    public var node: String
    public var type: GuestType
    public var status: String
    public var isTemplate: Bool
    public var ips: [String] = []
    /// CPU use as a share of `cpus` (0…1) and memory use in bytes; nil while stopped.
    public var cpu: Double? = nil
    public var cpus: Int? = nil
    public var memory: Double? = nil
    public var maxMemory: Double? = nil

    public init(vmid: Int, name: String, node: String, type: GuestType, status: String, isTemplate: Bool, ips: [String] = [], cpu: Double? = nil, cpus: Int? = nil, memory: Double? = nil, maxMemory: Double? = nil) {
        self.vmid = vmid
        self.name = name
        self.node = node
        self.type = type
        self.status = status
        self.isTemplate = isTemplate
        self.ips = ips
        self.cpu = cpu
        self.cpus = cpus
        self.memory = memory
        self.maxMemory = maxMemory
    }

    public var id: Int { vmid }
    public var isRunning: Bool { status == "running" }

    /// Status and usage from an entry of `/cluster/resources`.
    public mutating func applyUsage(_ entry: [String: Any]) {
        status = entry["status"] as? String ?? status
        cpus = ProxmoxClient.int(entry["maxcpu"]) ?? cpus
        maxMemory = MetricsParser.double(entry["maxmem"]) ?? maxMemory
        cpu = isRunning ? MetricsParser.double(entry["cpu"]) : nil
        memory = isRunning ? MetricsParser.double(entry["mem"]) : nil
    }
}

public struct PVENodeInfo: Identifiable, Hashable {
    public var name: String
    public var online: Bool
    public var ip: String?

    public init(name: String, online: Bool, ip: String? = nil) {
        self.name = name
        self.online = online
        self.ip = ip
    }

    public var id: String { name }
}

public enum ConsoleKind {
    case lxc, qemuNoVNC, qemuXterm, nodeShell
}

/// What logging in to a Proxmox server needs from the app: passwords and the user's answers.
/// The Mac app answers from the Keychain (after Touch ID) and with its prompt sheets.
@MainActor
public protocol ProxmoxLoginHandler: AnyObject {
    /// The password for `key`, saved or asked for; nil cancels the login.
    func credential(for key: CredentialKey, title: String, message: String, forcePrompt: Bool, isRetry: Bool) async -> ResolvedCredential?
    /// The login with `credential` worked, e.g. to save it if the user asked for that.
    func loginSucceeded(with credential: ResolvedCredential) async
    /// The code for a two-factor login; nil cancels.
    func oneTimeCode(title: String, message: String) async -> String?
    /// Whether to trust a certificate the system doesn't. `changed`: it replaces one trusted before.
    func trustCertificate(title: String, message: String, fingerprint: String, changed: Bool) async -> Bool
}

/// Live (never persisted) state of the configured Proxmox servers.
@MainActor
@Observable
public final class ProxmoxRuntime {
    public struct ServerState {
        public var nodes: [PVENodeInfo] = []
        public var guests: [PVEGuest] = []
        public var isLoading = false
        public var error: String?
        public var lastRefresh: Date?
        public var loggedInAs: String?
        /// Why the usage columns couldn't be updated last time; nil after a success.
        public var usageProblem: LiveDataProblem?
        /// When CPU and memory were last fetched.
        public var usageUpdated: Date?

        public init(nodes: [PVENodeInfo] = [], guests: [PVEGuest] = [], isLoading: Bool = false, error: String? = nil, lastRefresh: Date? = nil, loggedInAs: String? = nil, usageProblem: LiveDataProblem? = nil, usageUpdated: Date? = nil) {
            self.nodes = nodes
            self.guests = guests
            self.isLoading = isLoading
            self.error = error
            self.lastRefresh = lastRefresh
            self.loggedInAs = loggedInAs
            self.usageProblem = usageProblem
            self.usageUpdated = usageUpdated
        }
    }

    public private(set) var states: [UUID: ServerState] = [:]
    @ObservationIgnored private var clients: [UUID: ProxmoxClient] = [:]
    @ObservationIgnored private var logins: [UUID: Task<ProxmoxClient, Error>] = [:]

    public let library: LibraryStore
    public let loginHandler: any ProxmoxLoginHandler

    public init(library: LibraryStore, loginHandler: any ProxmoxLoginHandler) {
        self.library = library
        self.loginHandler = loginHandler
    }

    public func state(_ serverID: UUID) -> ServerState {
        states[serverID] ?? ServerState()
    }

    // MARK: Demo data (debug aid)

    /// Servers filled from a demo file (HOATZIN_DEMO_PROXMOX); they are never contacted.
    @ObservationIgnored private var demoServers: Set<UUID> = []

    private struct DemoServer: Decodable {
        struct Node: Decodable { var name: String; var online: Bool; var ip: String? }
        struct Guest: Decodable {
            public var vmid: Int, name: String, node: String, type: String, status: String
            public var template: Bool?, ips: [String]?
        }
        var nodes: [Node]
        var guests: [Guest]
        var loggedInAs: String?
    }

    /// Fills servers from a JSON file shaped `{"<server id>": {"nodes": […], "guests": […]}}`
    /// instead of their API: for screenshots and demos without a Proxmox server.
    public func loadDemo(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let servers = try? JSONDecoder().decode([String: DemoServer].self, from: data)
        else { return NSLog("Hoatzin: can't read demo Proxmox data at \(url.path)") }
        for (key, demo) in servers {
            guard let id = UUID(uuidString: key) else { continue }
            demoServers.insert(id)
            states[id] = ServerState(
                nodes: demo.nodes.map { PVENodeInfo(name: $0.name, online: $0.online, ip: $0.ip) },
                guests: demo.guests.map {
                    PVEGuest(vmid: $0.vmid, name: $0.name, node: $0.node, type: GuestType(rawValue: $0.type) ?? .qemu,
                             status: $0.status, isTemplate: $0.template ?? false, ips: $0.ips ?? [])
                }.sorted { $0.vmid < $1.vmid },
                lastRefresh: Date(), loggedInAs: demo.loggedInAs
            )
        }
    }

    public func guest(server: UUID, vmid: Int) -> PVEGuest? {
        states[server]?.guests.first { $0.vmid == vmid }
    }

    public func nodeInfo(server: UUID, node: String) -> PVENodeInfo? {
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
    public func authenticatedClient(_ serverID: UUID) async throws -> ProxmoxClient {
        if let running = logins[serverID] { return try await running.value }
        guard let item = library.item(serverID), let client = client(for: item) else {
            throw ProxmoxError.transport(String(localized: "Proxmox server has no host configured."))
        }
        if client.hasValidTicket { return client }
        // A ticket that's nearly two hours old can still be renewed without asking for a password.
        if client.ticket != nil {
            await renew(serverID, client)
            if client.hasValidTicket { return client }
        }

        let task = Task { @MainActor in
            try await self.login(serverID: serverID, client: client)
            return client
        }
        logins[serverID] = task
        defer { logins[serverID] = nil }
        return try await task.value
    }

    public func logout(_ serverID: UUID) {
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
            guard let credential = await loginHandler.credential(
                for: key,
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

            await loginHandler.loginSucceeded(with: credential)
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
            guard let code = await loginHandler.oneTimeCode(
                title: String(localized: "Two-factor code — \(serverName)"),
                message: String(localized: "Enter the TOTP code from your authenticator (or recovery:KEY).")
            ) else { throw CancellationError() }
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
                let ok = await loginHandler.trustCertificate(
                    title: changed ? String(localized: "Certificate changed — \(name)") : String(localized: "Trust certificate — \(name)?"),
                    message: changed
                        ? String(localized: "The certificate of \(client.host):\(String(client.port)) is different from the one you trusted before. Only continue if you renewed it.")
                        : String(localized: "\(client.host):\(String(client.port)) uses a certificate macOS does not trust (normal for Proxmox' self-signed certificate). Compare the fingerprint with Datacenter › Node › System › Certificates."),
                    fingerprint: fingerprint,
                    changed: changed
                )
                guard ok else { throw CancellationError() }
                library.modify(serverID) { $0.proxmox?.pinnedSHA256 = fingerprint }
                client.pinned = fingerprint
            }
        }
        try await client.probe()
    }

    // MARK: Refresh

    public func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for server in library.proxmoxServers {
                group.addTask { await self.refresh(server.id) }
            }
        }
    }

    public func refresh(_ serverID: UUID) async {
        guard library.item(serverID)?.proxmox != nil, !demoServers.contains(serverID) else { return }
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
            var guest = PVEGuest(
                vmid: vmid,
                name: entry["name"] as? String ?? "\(type.label) \(vmid)",
                node: node,
                type: type,
                status: entry["status"] as? String ?? "unknown",
                isTemplate: ProxmoxClient.int(entry["template"]) == 1,
                ips: previous[vmid] ?? []
            )
            guest.applyUsage(entry)
            return guest
        }
        guests.sort { $0.vmid < $1.vmid }

        states[serverID, default: ServerState()].nodes = nodes
        states[serverID]?.guests = guests
        states[serverID]?.error = nil
        states[serverID]?.lastRefresh = Date()
        states[serverID]?.usageProblem = nil
        states[serverID]?.usageUpdated = Date()

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

    // MARK: Live data (graphs, usage columns)

    @ObservationIgnored private var renewals: [UUID: Task<Void, Never>] = [:]

    /// The `data` of an API call made with the current session. Never asks for a password:
    /// without a session it throws `notLoggedIn`. A session older than an hour is renewed first,
    /// so graphs that stay open keep working.
    public func sessionGet(_ serverID: UUID, _ path: String) async throws -> Any? {
        if demoServers.contains(serverID) {
            // Debug aid: HOATZIN_DEMO_LOGGED_OUT=1 acts as if the login had expired.
            if ProcessInfo.processInfo.environment["HOATZIN_DEMO_LOGGED_OUT"] != nil { throw ProxmoxError.notLoggedIn }
            return DemoMetrics.response(path, state: states[serverID])
        }
        guard let item = library.item(serverID), let client = client(for: item), client.ticket != nil else {
            throw ProxmoxError.notLoggedIn
        }
        if let age = client.ticketAge, age > 60 * 60 { await renew(serverID, client) }
        guard client.hasValidTicket else { throw ProxmoxError.notLoggedIn }
        return try await client.get(path)
    }

    /// Renews the ticket once, however many callers ask at the same time.
    private func renew(_ serverID: UUID, _ client: ProxmoxClient) async {
        if let running = renewals[serverID] { return await running.value }
        let task = Task { _ = try? await client.renewTicket() }
        renewals[serverID] = task
        await task.value
        renewals[serverID] = nil
    }

    /// Updates the guests' status and CPU and memory use with one quick call, without asking
    /// for a login; when that fails, `usageProblem` says why. New or removed guests wait for
    /// the next full refresh.
    public func refreshUsage(_ serverID: UUID) async {
        let resources: [[String: Any]]
        do {
            resources = try await sessionGet(serverID, "/cluster/resources?type=vm") as? [[String: Any]] ?? []
        } catch {
            if !Task.isCancelled, states[serverID] != nil { states[serverID]?.usageProblem = LiveDataProblem(error) }
            return
        }
        guard var guests = states[serverID]?.guests else { return }
        var entries: [Int: [String: Any]] = [:]
        for entry in resources {
            if let vmid = ProxmoxClient.int(entry["vmid"]) { entries[vmid] = entry }
        }
        for index in guests.indices {
            if let entry = entries[guests[index].vmid] { guests[index].applyUsage(entry) }
        }
        states[serverID]?.guests = guests
        states[serverID]?.usageProblem = nil
        states[serverID]?.usageUpdated = Date()
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

    public nonisolated static func isIgnoredInterface(_ name: String?) -> Bool {
        guard let name else { return false }
        let ignored = ["lo", "docker", "br-", "veth", "virbr", "cni", "flannel", "cali", "kube", "tailscale", "zt"]
        return ignored.contains { name == $0 || name.hasPrefix($0) }
    }

    nonisolated private static func stripPrefix(_ cidr: String) -> String {
        String(cidr.split(separator: "/").first ?? Substring(cidr))
    }

    public nonisolated static func isUsableIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] != 127 && !(parts[0] == 169 && parts[1] == 254)
    }

    /// Addresses sharing the most leading octets with the Proxmox host first.
    public nonisolated static func rank(_ ips: [String], near host: String) -> [String] {
        let hostParts = host.split(separator: ".")
        func score(_ ip: String) -> Int {
            zip(ip.split(separator: "."), hostParts).prefix { $0 == $1 }.count
        }
        var seen = Set<String>()
        return ips.filter { seen.insert($0).inserted }.sorted { score($0) > score($1) }
    }

    // MARK: Console URLs

    public func consoleURL(client: ProxmoxClient, kind: ConsoleKind, node: String, vmid: Int?, name: String?) -> URL {
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
