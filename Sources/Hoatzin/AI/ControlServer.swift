import Foundation
import Darwin

/// One tool call from an AI client, as forwarded by the `hoatzin-mcp` helper.
struct ToolCall: Sendable {
    var tool: String
    /// JSON object with the tool's arguments.
    var arguments: Data
    /// Name of the program that started the helper (e.g. "Claude"), for confirmation sheets.
    var caller: String
}

struct ToolReply: Sendable, Equatable {
    var ok: Bool
    var text: String
    /// Short outcome for the activity log ("denied by you", "exit 0 · 0.8 s"). Not sent to the AI.
    var summary: String? = nil

    static func failure(_ text: String) -> ToolReply { ToolReply(ok: false, text: text) }
}

/// Socket that the bundled `hoatzin-mcp` helper talks to.
///
/// * It lives in the per-user temp dir, mode 600, at a fixed name so the helper (started by
///   an AI client, not by Hoatzin) can find it.
/// * Only processes of the same user that are the bundled helper binary may connect.
/// * Each connection carries one tool call; what a call may do is decided by `AIBridge`.
final class ControlServer: @unchecked Sendable {
    enum Status: Equatable { case stopped, active, busy, failed }

    typealias Handler = @Sendable (ToolCall) async -> ToolReply

    static let shared = ControlServer(path: defaultPath)

    static var defaultPath: String {
        if let path = ProcessInfo.processInfo.environment["HOATZIN_CONTROL_SOCKET"], !path.isEmpty { return path }
        return (UnixSocket.userTemporaryDirectory as NSString).appendingPathComponent("hoatzin-control.sock")
    }

    /// The helper inside this app bundle, the path AI clients are configured with.
    static var bundledHelperPath: String {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return exe.deletingLastPathComponent().appendingPathComponent("hoatzin-mcp").path
    }

    let path: String
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var _status: Status = .stopped
    private var _handler: Handler?
    private var _allowedClients: Set<String>

    init(path: String, allowedClients: Set<String>? = nil) {
        self.path = path
        _allowedClients = allowedClients ?? [Self.bundledHelperPath]
    }

    var status: Status { lock.withLock { _status } }

    /// Executables allowed to connect (tests use their own build of the helper).
    var allowedClients: Set<String> {
        get { lock.withLock { _allowedClients } }
        set { lock.withLock { _allowedClients = newValue } }
    }

    /// Starts listening unless another Hoatzin already serves this socket.
    @discardableResult
    func start(handler: @escaping Handler) -> Status {
        lock.withLock { _handler = handler }
        guard status != .active else { return .active }
        signal(SIGPIPE, SIG_IGN)
        if let other = UnixSocket.connect(to: path) {
            close(other)
            NSLog("Hoatzin: another Hoatzin already answers AI requests at \(path)")
            lock.withLock { _status = .busy }
            return .busy
        }
        guard let fd = UnixSocket.listen(at: path) else {
            lock.withLock { _status = .failed }
            return .failed
        }
        lock.withLock { listenFD = fd; _status = .active }
        UnixSocket.acceptLoop(fd, name: "Hoatzin AI control") { [weak self] client in self?.serve(client) }
        return .active
    }

    func stop() {
        let fd = lock.withLock { () -> Int32 in
            defer { listenFD = -1; _status = .stopped }
            return listenFD
        }
        guard fd >= 0 else { return }
        close(fd)
        unlink(path)
    }

    // MARK: - Connections

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        guard UnixSocket.isSameUser(fd) else { return }
        guard let caller = verifiedCaller(fd) else {
            NSLog("Hoatzin: AI control connection refused: client is not the Hoatzin MCP helper")
            return UnixSocket.writeLine(fd, ["ok": false, "text": "Only the Hoatzin MCP helper may use this socket."])
        }
        let data = UnixSocket.readLine(fd)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = object["tool"] as? String
        else { return UnixSocket.writeLine(fd, ["ok": false, "text": "Malformed request."]) }

        let arguments = (object["arguments"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data("{}".utf8)
        guard let handler = lock.withLock({ _handler }) else {
            return UnixSocket.writeLine(fd, ["ok": false, "text": "Hoatzin is still starting."])
        }

        final class Box: @unchecked Sendable { var reply = ToolReply.failure("No reply.") }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let call = ToolCall(tool: tool, arguments: arguments, caller: caller)
        Task {
            box.reply = await handler(call)
            done.signal()
        }
        done.wait()
        UnixSocket.writeLine(fd, ["ok": box.reply.ok, "text": box.reply.text])
    }

    /// The name of the program that started the helper, if the peer is the bundled helper.
    private func verifiedCaller(_ fd: Int32) -> String? {
        guard let peer = ProcessIdentity.peerPID(of: fd),
              let path = ProcessIdentity.executablePath(of: peer)
        else { return nil }
        let allowed = allowedClients.map(ProcessIdentity.canonicalPath)
        guard allowed.contains(ProcessIdentity.canonicalPath(path)) else { return nil }
        let parentPath = ProcessIdentity.parent(of: peer).flatMap(ProcessIdentity.executablePath(of:))
        return parentPath.map(Self.programName) ?? "An AI app"
    }

    /// "Claude" for /Applications/Claude.app/Contents/…, otherwise the executable's name.
    static func programName(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if let app = parts.first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
        return parts.last.map(String.init) ?? path
    }
}
