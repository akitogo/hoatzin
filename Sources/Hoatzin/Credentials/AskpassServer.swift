import Foundation
import Darwin
import Security

struct AskpassRequest: Sendable {
    let prompt: String
    /// Value of SSH_ASKPASS_PROMPT: "" (secret), "confirm" (yes/no via exit code) or "none" (notice).
    let kind: String
}

/// Returns the answer for ssh, or nil to cancel.
typealias AskpassHandler = @Sendable (AskpassRequest) async -> String?

/// Unix-domain socket that the `hoatzin-askpass` helper talks to.
///
/// A request is only answered if all of these hold:
/// * the socket (per-user temp dir, mode 600) is reached by the same user (getpeereid);
/// * the connecting process is the bundled helper binary;
/// * the helper was started by `/usr/bin/ssh`;
/// * that ssh is the process the token is bound to, or a child of it (ProxyJump);
/// * the token is still registered and not expired.
///
/// A token is bound to exactly one process: built-in tabs bind it to the ssh they start,
/// external launchers bind it to their own shell right before `exec ssh`. A second attempt
/// to bind a token revokes it. So another program that reads the token from ssh's
/// environment can neither ask with it directly nor through a copy of ssh it starts itself.
///
/// Secrets are only ever sent in answer to a request. They are never put in environment
/// variables, files or command lines.
final class AskpassServer: @unchecked Sendable {
    static let shared = AskpassServer()

    /// How many ancestors above the helper's parent ssh may sit between it and the bound
    /// process (ProxyJump runs a second ssh as a child of the first).
    static let maxAncestorDepth = 3

    let socketPath: String
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var registrations: [String: Registration] = [:]
    private var exitWatchers: [String: DispatchSourceProcess] = [:]
    private var _helperPath: String
    private var _trustedParents: Set<String> = ["/usr/bin/ssh"]

    private struct Registration {
        let handler: AskpassHandler
        let expires: Date?
        var bound: ProcessIdentity?
    }

    private final class ResultBox: @unchecked Sendable {
        var value: String?
    }

    private init() {
        let dir = NSTemporaryDirectory()
        socketPath = (dir as NSString).appendingPathComponent("hoatzin-\(getpid()).sock")
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        _helperPath = exe.deletingLastPathComponent().appendingPathComponent("hoatzin-askpass").path
    }

    /// The only executable allowed to connect.
    var helperPath: String {
        get { lock.withLock { _helperPath } }
        set { lock.withLock { _helperPath = newValue } }
    }

    /// Executables allowed to be the helper's parent (tests add their own runner).
    var trustedParents: Set<String> {
        get { lock.withLock { _trustedParents } }
        set { lock.withLock { _trustedParents = newValue } }
    }

    func start() {
        guard listenFD < 0 else { return }
        signal(SIGPIPE, SIG_IGN)
        removeStaleSockets()
        guard let fd = UnixSocket.listen(at: socketPath) else { return }
        listenFD = fd
        UnixSocket.acceptLoop(fd, name: "Hoatzin askpass") { [weak self] client in self?.serve(client) }
    }

    /// Deletes sockets left behind by Hoatzin processes that no longer run.
    private func removeStaleSockets() {
        let dir = (socketPath as NSString).deletingLastPathComponent
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            guard name.hasPrefix("hoatzin-"), name.hasSuffix(".sock"),
                  let pid = Int32(name.dropFirst("hoatzin-".count).dropLast(".sock".count)),
                  pid != getpid(), kill(pid, 0) != 0, errno == ESRCH
            else { continue }
            unlink((dir as NSString).appendingPathComponent(name))
        }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        unlink(socketPath)
    }

    // MARK: - Tokens

    /// Registers a handler and returns the token to hand to ssh via HOATZIN_TOKEN.
    /// The token answers nothing until it is bound to a process.
    func register(expiresIn: TimeInterval? = nil, handler: @escaping AskpassHandler) -> String {
        var raw = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
        let token = raw.map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            registrations[token] = Registration(handler: handler, expires: expiresIn.map { Date().addingTimeInterval($0) })
        }
        return token
    }

    func unregister(_ token: String) {
        let watcher = lock.withLock { () -> DispatchSourceProcess? in
            registrations[token] = nil
            return exitWatchers.removeValue(forKey: token)
        }
        watcher?.cancel()
    }

    /// Binds the token to the ssh process the app just started.
    @discardableResult
    func bind(_ token: String, to pid: pid_t) -> Bool {
        guard let identity = ProcessIdentity(pid: pid) else {
            NSLog("Hoatzin: askpass bind failed: process \(pid) not found")
            return false
        }
        return bind(token, to: identity)
    }

    private func bind(_ token: String, to identity: ProcessIdentity) -> Bool {
        enum Outcome { case bound, missing, revoked }
        let outcome = lock.withLock { () -> Outcome in
            guard let registration = registrations[token] else { return .missing }
            if registration.bound != nil {
                registrations[token] = nil
                return .revoked
            }
            registrations[token]?.bound = identity
            return .bound
        }
        switch outcome {
        case .bound:
            watchExit(of: identity.pid, token: token)
            return true
        case .missing:
            NSLog("Hoatzin: askpass bind refused: unknown or expired token")
            return false
        case .revoked:
            unregister(token)
            NSLog("Hoatzin: askpass token was bound twice, revoked it (attempt from \(identity))")
            return false
        }
    }

    /// Drops the token as soon as the bound process exits.
    private func watchExit(of pid: pid_t, token: String) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.unregister(token) }
        let previous = lock.withLock { exitWatchers.updateValue(source, forKey: token) }
        previous?.cancel()
        source.resume()
    }

    /// Environment entries that route ssh's prompts to the app.
    func environment(token: String) -> [String: String] {
        [
            "SSH_ASKPASS": helperPath,
            "SSH_ASKPASS_REQUIRE": "force",
            "HOATZIN_SOCKET": socketPath,
            "HOATZIN_TOKEN": token,
        ]
    }

    // MARK: - Socket handling

    private func refuse(_ fd: Int32, _ reason: String) {
        NSLog("Hoatzin: askpass request refused: \(reason)")
        reply(fd, ok: false, value: nil)
    }

    private func reply(_ fd: Int32, ok: Bool, value: String?) {
        var object: [String: Any] = ["ok": ok]
        if let value { object["value"] = value }
        UnixSocket.writeLine(fd, object)
    }

    /// The helper's parent and its ancestors, if the peer is genuinely our helper.
    private func verifiedHelperLineage(peer fd: Int32) -> (helper: pid_t, ancestors: [ProcessIdentity])? {
        guard let peer = ProcessIdentity.peerPID(of: fd),
              let path = ProcessIdentity.executablePath(of: peer),
              ProcessIdentity.canonicalPath(path) == ProcessIdentity.canonicalPath(helperPath),
              let parent = ProcessIdentity.parent(of: peer)
        else { return nil }
        return (peer, ProcessIdentity.lineage(from: parent, depth: Self.maxAncestorDepth))
    }

    /// The handler, if the token is live and bound to the helper's parent ssh or an ancestor of it.
    private func authorizedHandler(token: String, ancestors: [ProcessIdentity]) -> (AskpassHandler?, String) {
        guard let parent = ancestors.first else { return (nil, "helper has no parent") }
        let parentPath = ProcessIdentity.executablePath(of: parent.pid).map(ProcessIdentity.canonicalPath) ?? "?"
        let trusted = trustedParents.map(ProcessIdentity.canonicalPath)
        guard trusted.contains(parentPath) else { return (nil, "helper was started by \(parentPath), not ssh") }

        return lock.withLock {
            guard let registration = registrations[token] else { return (nil, "unknown token") }
            if let expires = registration.expires, expires < Date() {
                registrations[token] = nil
                return (nil, "expired token")
            }
            guard let bound = registration.bound else { return (nil, "token not bound to a process yet") }
            guard ancestors.contains(bound) else { return (nil, "token belongs to another ssh (\(bound))") }
            return (registration.handler, "")
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        guard UnixSocket.isSameUser(fd) else { return }
        let data = UnixSocket.readLine(fd, limit: 65_536)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let token = object["token"]
        else { return refuse(fd, "malformed request") }

        guard let lineage = verifiedHelperLineage(peer: fd) else {
            return refuse(fd, "client is not the Hoatzin askpass helper")
        }

        if object["op"] == "bind" {
            // Launcher script: bind to the shell that is about to exec ssh.
            guard let shell = lineage.ancestors.first else { return refuse(fd, "helper has no parent") }
            return reply(fd, ok: bind(token, to: shell), value: nil)
        }

        let (handler, reason) = authorizedHandler(token: token, ancestors: lineage.ancestors)
        guard let handler else { return refuse(fd, reason) }

        let request = AskpassRequest(prompt: object["prompt"] ?? "", kind: object["kind"] ?? "")
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.value = await handler(request)
            done.signal()
        }
        done.wait()
        reply(fd, ok: box.value != nil, value: box.value)
    }

}
