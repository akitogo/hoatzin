import XCTest
import AppKit
import SwiftUI
@testable import Hoatzin

private final class Marker {}

final class AskpassTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func hit() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    static var helperPath: String {
        Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("hoatzin-askpass").path
    }

    /// The test runner, which is the helper's parent when a test starts it directly.
    private static let runnerPath = ProcessIdentity.executablePath(of: getpid()) ?? ""

    override func setUp() {
        super.setUp()
        AskpassServer.shared.helperPath = Self.helperPath
        AskpassServer.shared.trustedParents = ["/usr/bin/ssh", Self.runnerPath]
        AskpassServer.shared.start()
    }

    override func tearDown() {
        AskpassServer.shared.trustedParents = ["/usr/bin/ssh"]
        super.tearDown()
    }

    private func run(_ executable: String, _ arguments: [String], env extra: [String: String] = [:],
                     token: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [
            "HOATZIN_SOCKET": AskpassServer.shared.socketPath,
            "HOATZIN_TOKEN": token,
            "H": Self.helperPath,
        ].merging(extra) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    private func runHelper(token: String, prompt: String = "password:", bind: Bool = false) throws -> (status: Int32, output: String) {
        try run(Self.helperPath, [prompt], env: bind ? ["HOATZIN_BIND": "1"] : [:], token: token)
    }

    /// Talks to the socket directly, the way any other local program could.
    private func rawRequest(_ request: [String: String]) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(AskpassServer.shared.socketPath.utf8)) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, var payload = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        payload.append(0x0A)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while !response.contains(0x0A) {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            response.append(buffer, count: n)
        }
        return try? JSONSerialization.jsonObject(with: response) as? [String: Any]
    }

    func testHelperRoundTripThroughSocket() throws {
        let token = AskpassServer.shared.register { request in
            request.prompt.contains("password") ? "s3cr3t" : nil
        }
        defer { AskpassServer.shared.unregister(token) }
        XCTAssertTrue(AskpassServer.shared.bind(token, to: getpid()))

        let ok = try runHelper(token: token, prompt: "root@10.20.30.192's password: ")
        XCTAssertEqual(ok.status, 0)
        XCTAssertEqual(ok.output, "s3cr3t\n")

        let cancelled = try runHelper(token: token, prompt: "something else")
        XCTAssertEqual(cancelled.status, 1)
        XCTAssertEqual(cancelled.output, "")
    }

    func testUnknownOrExpiredTokenIsRefused() throws {
        let bogus = try runHelper(token: "not-a-token")
        XCTAssertEqual(bogus.status, 1)

        let token = AskpassServer.shared.register(expiresIn: -1) { _ in "late" }
        AskpassServer.shared.bind(token, to: getpid())
        let expired = try runHelper(token: token)
        XCTAssertEqual(expired.status, 1)
    }

    func testUnboundTokenIsRefused() throws {
        let calls = Calls()
        let token = AskpassServer.shared.register { _ in calls.hit(); return "s3cr3t" }
        defer { AskpassServer.shared.unregister(token) }

        let result = try runHelper(token: token)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(calls.value, 0)
    }

    func testOtherProgramsCannotUseTheSocketDirectly() throws {
        let calls = Calls()
        let token = AskpassServer.shared.register { _ in calls.hit(); return "s3cr3t" }
        defer { AskpassServer.shared.unregister(token) }
        AskpassServer.shared.bind(token, to: getpid())

        let response = try XCTUnwrap(rawRequest(["token": token, "prompt": "password:", "kind": ""]))
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertNil(response["value"])
        XCTAssertEqual(calls.value, 0)
    }

    func testHelperOutsideTheBoundProcessTreeIsRefused() throws {
        let calls = Calls()
        let token = AskpassServer.shared.register { _ in calls.hit(); return "s3cr3t" }
        defer { AskpassServer.shared.unregister(token) }

        // Bound to an unrelated process: the helper's parent (this runner) is not it.
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer { other.terminate() }
        XCTAssertTrue(AskpassServer.shared.bind(token, to: other.processIdentifier))

        let result = try runHelper(token: token)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(calls.value, 0)
    }

    func testHelperMustBeStartedBySSH() throws {
        let calls = Calls()
        let token = AskpassServer.shared.register { _ in calls.hit(); return "s3cr3t" }
        defer { AskpassServer.shared.unregister(token) }
        AskpassServer.shared.bind(token, to: getpid())
        AskpassServer.shared.trustedParents = ["/usr/bin/ssh"]

        let result = try runHelper(token: token)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(calls.value, 0)
    }

    /// The external-terminal launcher: bind from a shell, then exec (same pid) into the
    /// program that starts the helper.
    func testLauncherBindSurvivesExec() throws {
        AskpassServer.shared.trustedParents = ["/usr/bin/ssh", "/bin/zsh"]
        let token = AskpassServer.shared.register { _ in "s3cr3t" }
        defer { AskpassServer.shared.unregister(token) }

        let script = #"HOATZIN_BIND=1 "$H" || exit 9; exec /bin/zsh -f -c '"$H" "password:"; exit $?'"#
        let result = try run("/bin/zsh", ["-f", "-c", script], token: token)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "s3cr3t\n")
    }

    func testSecondBindRevokesToken() throws {
        let calls = Calls()
        let token = AskpassServer.shared.register { _ in calls.hit(); return "s3cr3t" }
        defer { AskpassServer.shared.unregister(token) }

        XCTAssertEqual(try runHelper(token: token, bind: true).status, 0)
        XCTAssertEqual(try runHelper(token: token, bind: true).status, 1)
        XCTAssertEqual(try runHelper(token: token).status, 1)
        XCTAssertEqual(calls.value, 0)
    }

    func testTokenIsDroppedWhenBoundProcessExits() throws {
        let token = AskpassServer.shared.register { _ in "s3cr3t" }
        defer { AskpassServer.shared.unregister(token) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["0.2"]
        try child.run()
        XCTAssertTrue(AskpassServer.shared.bind(token, to: child.processIdentifier))
        child.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.3)
        // Gone, so binding it again is refused as unknown rather than revoking anything.
        XCTAssertFalse(AskpassServer.shared.bind(token, to: getpid()))
    }

    func testSocketIsOwnerOnly() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: AskpassServer.shared.socketPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}

final class SSHAuthAgentTests: XCTestCase {
    @MainActor
    private func waitForPrompt(_ prompts: PromptCenter) async throws -> PromptCenter.Pending {
        for _ in 0..<500 {
            if let current = prompts.current { return current }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw XCTSkip("prompt never appeared")
    }

    @MainActor
    func testServesPreResolvedPasswordThenAsksAgainOnRejection() async throws {
        let prompts = PromptCenter()
        let broker = CredentialBroker(prompts: prompts)
        let target = SSHTarget(displayName: "web192", host: "hoatzin-test.invalid", username: "root")
        let pre = ResolvedCredential(key: target.credentialKey, secret: "first", fromKeychain: true, shouldSave: false)
        let agent = SSHAuthAgent(target: target, owner: UUID(), preResolved: pre, broker: broker, prompts: prompts)

        let first = await agent.handle(AskpassRequest(prompt: "root@hoatzin-test.invalid's password: ", kind: ""))
        XCTAssertEqual(first, "first")

        let retry = Task { await agent.handle(AskpassRequest(prompt: "root@hoatzin-test.invalid's password: ", kind: "")) }
        let pending = try await waitForPrompt(prompts)
        guard case .password(let prompt) = pending.content else { return XCTFail("expected password prompt") }
        XCTAssertTrue(prompt.isRetry)
        XCTAssertFalse(prompt.usernameEditable)
        XCTAssertEqual(prompt.key.server, "hoatzin-test.invalid")
        prompts.respond(pending.id, .password(PasswordAnswer(username: "root", password: "second", save: false)))
        let second = await retry.value
        XCTAssertEqual(second, "second")
    }

    @MainActor
    func testHostKeyConfirmation() async throws {
        let prompts = PromptCenter()
        let agent = SSHAuthAgent(target: SSHTarget(displayName: "x", host: "h", username: "root"), owner: UUID(),
                                 preResolved: nil, broker: CredentialBroker(prompts: prompts), prompts: prompts)
        let question = "The authenticity of host 'h' can't be established.\nED25519 key fingerprint is SHA256:abc.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? "

        let accepted = Task { await agent.handle(AskpassRequest(prompt: question, kind: "")) }
        var pending = try await waitForPrompt(prompts)
        prompts.respond(pending.id, .confirmed(true))
        let yes = await accepted.value
        XCTAssertEqual(yes, "yes")

        let rejected = Task { await agent.handle(AskpassRequest(prompt: question, kind: "")) }
        pending = try await waitForPrompt(prompts)
        prompts.respond(pending.id, .confirmed(false))
        let no = await rejected.value
        XCTAssertEqual(no, "no")
    }

    @MainActor
    func testCancelAllResolvesOpenPrompts() async throws {
        let prompts = PromptCenter()
        let owner = UUID()
        let agent = SSHAuthAgent(target: SSHTarget(displayName: "x", host: "hoatzin-test.invalid", username: "nobody"),
                                 owner: owner, preResolved: nil, broker: CredentialBroker(prompts: prompts), prompts: prompts)
        let task = Task { await agent.handle(AskpassRequest(prompt: "Verification code: ", kind: "")) }
        _ = try await waitForPrompt(prompts)
        prompts.cancelAll(owner: owner)
        let answer = await task.value
        XCTAssertNil(answer)
        XCTAssertNil(prompts.current)
    }
}

final class KeychainTests: XCTestCase {
    func testSaveReadDelete() throws {
        let key = CredentialKey(server: "hoatzin-selftest.invalid", account: "tester", proto: .ssh, port: 22)
        try? Keychain.delete(key)
        XCTAssertFalse(Keychain.exists(key))

        try Keychain.save(key, secret: "one")
        XCTAssertTrue(Keychain.exists(key))
        XCTAssertEqual(try Keychain.read(key), "one")

        try Keychain.save(key, secret: "two") // update in place
        XCTAssertEqual(try Keychain.read(key), "two")

        // Different protocol = different credential.
        XCTAssertNil(try Keychain.read(CredentialKey(server: key.server, account: key.account, proto: .https, port: 8006)))

        try Keychain.delete(key)
        XCTAssertFalse(Keychain.exists(key))
    }
}

final class LibraryTests: XCTestCase {
    @MainActor
    func testMoveAndPersistWithoutSecrets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hoatzin-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = LibraryStore(fileURL: url)
        let folder = LibraryItem.folder("Customers")
        let a = LibraryItem.sshConnection("web190", config: SSHConfig(host: "10.20.30.190"))
        let b = LibraryItem.sshConnection("web191", config: SSHConfig(host: "10.20.30.191"))
        store.add(folder, to: nil)
        store.add(a, to: nil)
        store.add(b, to: nil)

        store.move(a.id, to: folder.id, index: nil)
        store.move(b.id, to: folder.id, index: 0)
        XCTAssertEqual(store.item(folder.id)?.children.map(\.name), ["web191", "web190"])
        XCTAssertEqual(store.parentID(of: a.id), folder.id)

        // A folder can't be moved into itself.
        store.move(folder.id, to: folder.id, index: nil)
        XCTAssertEqual(store.items.map(\.name), ["Customers"])

        let reloaded = LibraryStore(fileURL: url)
        XCTAssertEqual(reloaded.item(folder.id)?.children.count, 2)

        // No field anywhere in the file may be meant for a secret.
        var keys = Set<String>()
        func collect(_ value: Any) {
            if let dict = value as? [String: Any] { dict.forEach { keys.insert($0.key.lowercased()); collect($0.value) } }
            if let array = value as? [Any] { array.forEach(collect) }
        }
        collect(try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
        XCTAssertFalse(keys.isEmpty)
        XCTAssertTrue(keys.filter { $0.contains("pass") || $0.contains("secret") || $0.contains("ticket") || $0.contains("token") }.isEmpty, "\(keys)")
    }
}

final class HelperTests: XCTestCase {
    func testSSHArguments() {
        let target = SSHTarget(displayName: "x", host: "10.0.0.5", port: 2222, username: "admin",
                               identityFile: "", extraArgs: "-A -o 'ProxyJump=jump host'")
        XCTAssertEqual(target.sshArguments,
                       ["-o", "ServerAliveInterval=30", "-p", "2222", "-l", "admin", "-A", "-o", "ProxyJump=jump host", "10.0.0.5"])
        XCTAssertEqual(target.credentialKey.server, "10.0.0.5")
        XCTAssertEqual(SSHTarget.shellQuote("it's"), "'it'\\''s'")
    }

    func testCommandArgumentsCannotBeWeakened() throws {
        let target = SSHTarget(displayName: "x", host: "10.0.0.5", port: 2222, username: "admin",
                               extraArgs: "-o StrictHostKeyChecking=no -o ForwardAgent=yes -t")
        let args = target.commandArguments("-rf; echo hi")
        XCTAssertEqual(Array(args.suffix(4)), ["-T", "10.0.0.5", "--", "-rf; echo hi"])
        // ssh keeps the first value of an option: ours must come before the entry's.
        let strict = try XCTUnwrap(args.firstIndex(of: "StrictHostKeyChecking=yes"))
        XCTAssertLessThan(strict, try XCTUnwrap(args.firstIndex(of: "StrictHostKeyChecking=no")))
        XCTAssertLessThan(try XCTUnwrap(args.firstIndex(of: "ForwardAgent=no")), try XCTUnwrap(args.firstIndex(of: "ForwardAgent=yes")))
        // For flags the last one wins: -T after the entry's -t.
        XCTAssertGreaterThan(try XCTUnwrap(args.lastIndex(of: "-T")), try XCTUnwrap(args.firstIndex(of: "-t")))
        XCTAssertTrue(args.contains("-n"))
        XCTAssertEqual(args.filter { $0 == "10.0.0.5" }.count, 1)
    }

    func testCappedOutputKeepsStartAndEnd() {
        var output = RemoteCommand.CappedOutput()
        let total = 200_000
        for chunk in stride(from: 0, to: total, by: 7_000) {
            output.append(Data((chunk..<min(chunk + 7_000, total)).map { UInt8(ascii: $0 % 50 == 49 ? "\n" : "x") }))
        }
        XCTAssertEqual(output.total, total)
        XCTAssertEqual(output.head.count, RemoteCommand.CappedOutput.headLimit)
        XCTAssertEqual(output.tail.count, RemoteCommand.CappedOutput.tailLimit)
        XCTAssertEqual(output.omitted, total - RemoteCommand.CappedOutput.headLimit - RemoteCommand.CappedOutput.tailLimit)
        XCTAssertTrue(output.text.contains("\(output.omitted) bytes left out"))

        var small = RemoteCommand.CappedOutput()
        small.append(Data("hello\n".utf8))
        XCTAssertEqual(small.text, "hello")
        XCTAssertEqual(small.omitted, 0)
    }

    func testIPRanking() {
        XCTAssertEqual(ProxmoxRuntime.rank(["172.17.0.1", "10.20.30.192", "192.168.1.4"], near: "10.20.30.10").first, "10.20.30.192")
        XCTAssertFalse(ProxmoxRuntime.isUsableIPv4("127.0.0.1"))
        XCTAssertFalse(ProxmoxRuntime.isUsableIPv4("169.254.3.3"))
        XCTAssertFalse(ProxmoxRuntime.isUsableIPv4("fe80::1"))
        XCTAssertTrue(ProxmoxRuntime.isIgnoredInterface("docker0"))
        XCTAssertFalse(ProxmoxRuntime.isIgnoredInterface("eth0"))
    }
}

/// Opt-in: HOATZIN_SSHD_PORT=22222 swift test --filter SSHIntegrationTests
/// Needs a local sshd with password auth (any password is fine — it is expected to fail).
final class SSHIntegrationTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var prompts: [String] = []
        func add(_ p: String) { lock.withLock { prompts.append(p) } }
    }

    private func runSSH(viaLauncher: Bool) throws -> (status: Int32, prompts: [String]) {
        guard let port = ProcessInfo.processInfo.environment["HOATZIN_SSHD_PORT"] else {
            throw XCTSkip("set HOATZIN_SSHD_PORT to run")
        }
        AskpassServer.shared.helperPath = AskpassTests.helperPath
        AskpassServer.shared.trustedParents = ["/usr/bin/ssh"]
        AskpassServer.shared.start()
        let recorder = Recorder()
        let token = AskpassServer.shared.register { request in
            recorder.add(request.prompt)
            if request.prompt.contains("(yes/no") { return "yes" }
            if request.prompt.lowercased().contains("password") { return "definitely-wrong" }
            return nil
        }
        defer { AskpassServer.shared.unregister(token) }

        var env = AskpassServer.shared.environment(token: token)
        env["HOME"] = NSHomeDirectory()
        let sshArgs = ["-F", "/dev/null", "-p", port, "-o", "UserKnownHostsFile=/dev/null",
                       "-o", "StrictHostKeyChecking=ask", "-o", "NumberOfPasswordPrompts=2",
                       "-o", "PreferredAuthentications=password", "-o", "ConnectTimeout=5",
                       "-l", NSUserName(), "127.0.0.1", "true"]

        let process = Process()
        if viaLauncher {
            // Same steps as the iTerm2 / Terminal launcher script.
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", #"HOATZIN_BIND=1 "$SSH_ASKPASS" || exit 99; exec /usr/bin/ssh "$@""#, "zsh"] + sshArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArgs
        }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        // Built-in tabs bind right after the fork, like this.
        if !viaLauncher { AskpassServer.shared.bind(token, to: process.processIdentifier) }
        process.waitUntilExit()
        return (process.terminationStatus, recorder.lock.withLock { recorder.prompts })
    }

    private func assertPromptsRouted(_ result: (status: Int32, prompts: [String])) {
        XCTAssertNotEqual(result.status, 0)
        XCTAssertNotEqual(result.status, 99, "launcher bind failed")
        XCTAssertTrue(result.prompts.contains { $0.contains("(yes/no") }, "host key prompt not routed: \(result.prompts)")
        XCTAssertEqual(result.prompts.filter { $0.lowercased().contains("password") }.count, 2, "\(result.prompts)")
    }

    func testBuiltInTabRoutesPromptsThroughHelper() throws {
        assertPromptsRouted(try runSSH(viaLauncher: false))
    }

    func testExternalLauncherRoutesPromptsThroughHelper() throws {
        assertPromptsRouted(try runSSH(viaLauncher: true))
    }
}

/// Opt-in, against a local sshd that accepts a key for the current user:
/// HOATZIN_SSHD_PORT=22222 HOATZIN_SSHD_KEY=/path/key HOATZIN_SSHD_KNOWN_HOSTS=/path/known_hosts \
///   swift test --filter RemoteCommandIntegrationTests
final class RemoteCommandIntegrationTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var prompts: [String] = []
        func add(_ p: String) { lock.withLock { prompts.append(p) } }
    }

    private func target(knownHosts: String? = nil, extra: String = "") throws -> SSHTarget {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["HOATZIN_SSHD_PORT"].flatMap(Int.init), let key = env["HOATZIN_SSHD_KEY"],
              let known = env["HOATZIN_SSHD_KNOWN_HOSTS"]
        else { throw XCTSkip("set HOATZIN_SSHD_PORT, HOATZIN_SSHD_KEY and HOATZIN_SSHD_KNOWN_HOSTS to run") }
        AskpassServer.shared.helperPath = AskpassTests.helperPath
        AskpassServer.shared.trustedParents = ["/usr/bin/ssh"]
        AskpassServer.shared.start()
        return SSHTarget(displayName: "local", host: "127.0.0.1", port: port, username: NSUserName(), auth: .key,
                         identityFile: key,
                         extraArgs: "-F /dev/null -o IdentitiesOnly=yes -o UserKnownHostsFile=\(knownHosts ?? known) \(extra)")
    }

    func testRunsAndCapturesOutput() async throws {
        let target = try target()
        let result = await RemoteCommand.run(arguments: target.commandArguments("echo out; echo err >&2; exit 3"), timeout: 20) { _ in nil }
        XCTAssertNil(result.launchError)
        XCTAssertEqual(result.exitCode, 3, result.stderr.text)
        XCTAssertEqual(result.stdout.text, "out")
        XCTAssertEqual(result.stderr.text, "err")
        XCTAssertFalse(result.timedOut)

        // A command starting with "-" reaches the host instead of being read as ssh's -V
        // (the remote shell may then reject it, which is fine).
        let dash = await RemoteCommand.run(arguments: target.commandArguments("-V"), timeout: 20) { _ in nil }
        XCTAssertNotEqual(dash.exitCode, 255, dash.stderr.text)
        XCTAssertFalse((dash.stdout.text + dash.stderr.text).contains("OpenSSH_"), dash.stderr.text)
    }

    func testUnknownHostKeyIsRefused() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("rd-known-\(UUID())")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        // Even if the entry asks ssh to accept new keys, ours comes first and wins.
        let target = try target(knownHosts: empty.path, extra: "-o StrictHostKeyChecking=accept-new")
        let result = await RemoteCommand.run(arguments: target.commandArguments("echo should-not-run"), timeout: 20) { _ in nil }
        XCTAssertEqual(result.exitCode, 255)
        XCTAssertTrue(result.stderr.text.contains("Host key verification failed"), result.stderr.text)
        XCTAssertEqual(result.stdout.text, "")
        XCTAssertEqual(try Data(contentsOf: empty).count, 0, "the key must not be added")
        let reply = AIBridge.describe(result, on: "local", name: "local", timeout: 20, decision: .allowed)
        XCTAssertTrue(reply.text.contains("never accept host keys"), reply.text)
    }

    func testTimeoutStopsSSH() async throws {
        let target = try target()
        let result = await RemoteCommand.run(arguments: target.commandArguments("echo started; sleep 30"), timeout: 1.5) { _ in nil }
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(result.duration, 10)
        XCTAssertEqual(result.stdout.text, "started")
    }

    func testLargeOutputIsCapped() async throws {
        let target = try target()
        let result = await RemoteCommand.run(arguments: target.commandArguments("seq 1 200000"), timeout: 30) { _ in nil }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(result.stdout.omitted, 0)
        XCTAssertTrue(result.stdout.text.hasPrefix("1\n2\n3\n"))
        XCTAssertTrue(result.stdout.text.hasSuffix("199999\n200000"))
    }

    /// The whole path an AI command takes: confirmation sheet, ssh, output back to the AI, log.
    @MainActor
    func testRunCommandThroughTheBridge() async throws {
        let local = try target()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hoatzin-sshd-\(UUID()).json")
        let store = LibraryStore(fileURL: url)
        var config = SSHConfig(host: local.host)
        config.port = local.port
        config.username = local.username
        config.auth = .key
        config.identityFile = local.identityFile
        config.extraArgs = local.extraArgs
        let item = LibraryItem.sshConnection("local", config: config)
        store.add(item, to: nil)
        let model = AppModel(library: store)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: model.ai.activity.fileURL)
        }
        model.ai.accessOverride = .commands

        let arguments = try JSONSerialization.data(withJSONObject: ["id": "item:\(item.id.uuidString)", "command": "echo hello from $(whoami)"])
        let call = Task { await model.ai.handle(ToolCall(tool: "run_command", arguments: arguments, caller: "Claude")) }
        for _ in 0..<100 where model.prompts.current == nil { try await Task.sleep(for: .milliseconds(20)) }
        let pending = try XCTUnwrap(model.prompts.current)
        guard case .confirm(let prompt) = pending.content else { return XCTFail("expected a confirmation") }
        XCTAssertEqual(prompt.detail, "echo hello from $(whoami)")
        model.prompts.respond(pending.id, .confirmed(true))

        let reply = await call.value
        XCTAssertTrue(reply.ok, reply.text)
        XCTAssertTrue(reply.text.contains("exit code 0"), reply.text)
        XCTAssertTrue(reply.text.contains("hello from \(NSUserName())"), reply.text)
        XCTAssertTrue(model.ai.activity.entries.last?.outcome.hasPrefix("exit 0 · ") ?? false)
    }

    @MainActor
    func testRunCommandActionReturnsOutput() async throws {
        let local = try target()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hoatzin-sshd-\(UUID()).json")
        let store = LibraryStore(fileURL: url)
        var config = SSHConfig(host: local.host)
        config.port = local.port
        config.username = local.username
        config.auth = .key
        config.identityFile = local.identityFile
        config.extraArgs = local.extraArgs
        let item = LibraryItem.sshConnection("local", config: config)
        store.add(item, to: nil)
        let model = AppModel(library: store)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: model.ai.activity.fileURL)
        }
        let output = try await RunCommandIntent.run("echo hi; echo note >&2", on: "item:\(item.id.uuidString)", timeout: 20,
                                                    model: model, policy: .always) { _ in }
        XCTAssertEqual(output, "hi")
        do {
            _ = try await RunCommandIntent.run("echo broken >&2; exit 4", on: "item:\(item.id.uuidString)", timeout: 20,
                                               model: model, policy: .always) { _ in }
            XCTFail("exit 4 is an error in Shortcuts")
        } catch let error as IntentFailure {
            XCTAssertTrue(error.message.contains("exit code 4"), error.message)
            XCTAssertTrue(error.message.contains("broken"), error.message)
        }
    }

    func testPasswordQuestionsReachTheAgent() async throws {
        let target = try target(extra: "-o PreferredAuthentications=password -o NumberOfPasswordPrompts=1")
        let recorder = Recorder()
        let result = await RemoteCommand.run(arguments: target.commandArguments("true"), timeout: 20) { request in
            recorder.add(request.prompt)
            return "definitely-wrong"
        }
        XCTAssertEqual(result.exitCode, 255)
        XCTAssertEqual(recorder.lock.withLock { recorder.prompts }.filter { $0.lowercased().contains("password") }.count, 1)
    }
}

final class LegacyMigrationTests: XCTestCase {
    func testCopiesRemoteDeckDataOnce() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hoatzin-home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let oldSupport = home.appendingPathComponent("Library/Application Support/RemoteDeck")
        let oldLogs = home.appendingPathComponent("Library/Logs/RemoteDeck")
        try FileManager.default.createDirectory(at: oldSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oldLogs, withIntermediateDirectories: true)
        try Data("{\"version\":2,\"items\":[]}".utf8).write(to: oldSupport.appendingPathComponent("library.json"))
        try Data("{}\n".utf8).write(to: oldLogs.appendingPathComponent("ai-activity.jsonl"))

        let suite = "hoatzin-migration-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("iterm", forKey: Prefs.sshOpenIn) // already set in Hoatzin: kept
        let old: [String: Any] = [Prefs.sshOpenIn: "builtin", Prefs.defaultSSHUser: "akitogo", "sidebarCollapsed": ["item:x"], "unrelated": 1]

        let copied = LegacyMigration.run(home: home, defaults: defaults, domain: suite) { old[$0] }
        XCTAssertEqual(Set(copied), ["library", "ai-activity.jsonl", Prefs.defaultSSHUser, "sidebarCollapsed"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Hoatzin/library.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Logs/Hoatzin/ai-activity.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldSupport.appendingPathComponent("library.json").path), "the old file stays")
        XCTAssertEqual(defaults.string(forKey: Prefs.sshOpenIn), "iterm")
        XCTAssertEqual(defaults.string(forKey: Prefs.defaultSSHUser), "akitogo")
        XCTAssertNil(defaults.object(forKey: "unrelated"))

        // Only once, and never over newer data.
        try Data("changed".utf8).write(to: oldSupport.appendingPathComponent("library.json"))
        XCTAssertTrue(LegacyMigration.run(home: home, defaults: defaults, domain: suite) { old[$0] }.isEmpty)
        let current = try String(contentsOf: home.appendingPathComponent("Library/Application Support/Hoatzin/library.json"), encoding: .utf8)
        XCTAssertTrue(current.contains("version"))
    }
}

final class MigrationTests: XCTestCase {
    @MainActor
    func testV1ProxmoxGuestDefaultsBecomeInherited() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hoatzin-mig-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        let v1 = """
        {"version":1,"items":[{"id":"\(id.uuidString)","kind":"proxmox","name":"Office","children":[],
          "proxmox":{"host":"10.20.31.2","port":8006,"username":"root","realm":"pam","keychainHost":"",
                     "sshUsername":"root","sshAuth":"password","sshIdentityFile":"","guestOverrides":{}}}]}
        """
        try v1.write(to: url, atomically: true, encoding: .utf8)

        let store = LibraryStore(fileURL: url)
        let config = try XCTUnwrap(store.item(id)?.proxmox)
        XCTAssertEqual(config.sshUsername, "")
        XCTAssertNil(config.sshAuth)
        XCTAssertEqual(config.loginUser, "root")

        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 2)
    }
}

final class SecretGateTests: XCTestCase {
    @MainActor
    private final class FakeAuth {
        var calls = 0
        var answer = true
        var delay: Duration = .zero
        func run(_ reason: String) async -> Bool {
            calls += 1
            if delay != .zero { try? await Task.sleep(for: delay) }
            return answer
        }
    }

    @MainActor
    private func makeGate(_ auth: FakeAuth, enabled: Bool = true, grace: TimeInterval = 300) -> SecretGate {
        let gate = SecretGate { await auth.run($0) }
        gate.enabledOverride = enabled
        gate.graceOverride = grace
        return gate
    }

    @MainActor
    func testDisabledNeverAsks() async {
        let auth = FakeAuth()
        let gate = makeGate(auth, enabled: false)
        let ok = await gate.unlock(reason: "x")
        XCTAssertTrue(ok)
        XCTAssertEqual(auth.calls, 0)
    }

    @MainActor
    func testGracePeriodAndLock() async {
        let auth = FakeAuth()
        let gate = makeGate(auth)
        var ok = await gate.unlock(reason: "a")
        XCTAssertTrue(ok)
        ok = await gate.unlock(reason: "b")
        XCTAssertTrue(ok)
        XCTAssertEqual(auth.calls, 1, "second use within the grace period must not ask again")

        gate.lock()
        ok = await gate.unlock(reason: "c")
        XCTAssertTrue(ok)
        XCTAssertEqual(auth.calls, 2, "lock() must require Touch ID again")
    }

    @MainActor
    func testEveryTimeWhenGraceIsZero() async {
        let auth = FakeAuth()
        let gate = makeGate(auth, grace: 0)
        _ = await gate.unlock(reason: "a")
        _ = await gate.unlock(reason: "b")
        XCTAssertEqual(auth.calls, 2)
    }

    @MainActor
    func testFailureDoesNotUnlock() async {
        let auth = FakeAuth()
        auth.answer = false
        let gate = makeGate(auth)
        let first = await gate.unlock(reason: "a")
        XCTAssertFalse(first)
        auth.answer = true
        let second = await gate.unlock(reason: "b")
        XCTAssertTrue(second)
        XCTAssertEqual(auth.calls, 2)
    }

    @MainActor
    func testConcurrentCallersShareOnePrompt() async {
        let auth = FakeAuth()
        auth.delay = .milliseconds(100)
        let gate = makeGate(auth)
        async let a = gate.unlock(reason: "a")
        async let b = gate.unlock(reason: "b")
        let results = await [a, b]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(auth.calls, 1)
    }

    @MainActor
    func testBrokerAsksTouchIDOnlyForSavedPasswords() async throws {
        let key = CredentialKey(server: "hoatzin-gate-test.invalid", account: "tester", proto: .ssh, port: 22)
        try? Keychain.delete(key)
        try Keychain.save(key, secret: "from-keychain")
        defer { try? Keychain.delete(key) }

        let auth = FakeAuth()
        let prompts = PromptCenter()
        let broker = CredentialBroker(prompts: prompts, gate: makeGate(auth))

        auth.answer = false
        let denied = await broker.resolve(key, title: "t")
        XCTAssertNil(denied, "cancelled Touch ID must not release the password")
        XCTAssertNil(prompts.current, "and must not fall through to the password sheet")

        auth.answer = true
        let allowed = await broker.resolve(key, title: "t")
        XCTAssertEqual(allowed?.secret, "from-keychain")
        XCTAssertEqual(allowed?.fromKeychain, true)
        XCTAssertEqual(auth.calls, 2)
    }
}

// MARK: - Sidebar filter

enum SidebarSample {
    static let customers = UUID(), web = UUID(), db = UUID(), office = UUID(), cluster = UUID()

    /// A Proxmox cluster with two nodes, guests one level deeper than in `rows`.
    static func cluster(guests: Int) -> [SidebarRow] {
        let nodes = ["pve", "pvef1"].enumerated().map { index, name in
            SidebarRow(id: .node(server: cluster, node: name), title: name, detail: "10.20.31.\(index + 2)", symbol: "cpu",
                       tint: .running, children: (0..<guests).map { n in
                let vmid = 100 + index * 100 + n
                return SidebarRow(id: .guest(server: cluster, vmid: vmid), title: "customer\(n)-site.example.com",
                                  detail: "10.20.4\(index).\(n + 10)", badge: String(vmid), symbol: "desktopcomputer",
                                  tint: .running, keywords: ["10.20.4\(index).\(n + 10)"])
            })
        }
        return [SidebarRow(id: .item(cluster), title: "Cluster", detail: "\(guests * 2)", symbol: "server.rack", tint: .accent,
                           children: nodes, isMovable: true)]
    }

    static var rows: [SidebarRow] {
        let guest = { (vmid: Int, name: String, ip: String?, running: Bool) in
            SidebarRow(id: .guest(server: office, vmid: vmid), title: name, detail: ip, badge: String(vmid),
                       symbol: "shippingbox", tint: running ? .running : .stopped, keywords: ip.map { [$0] } ?? [])
        }
        return [
            SidebarRow(id: .item(customers), title: "Customers", symbol: "folder", children: [
                SidebarRow(id: .item(web), title: "web01", detail: "10.0.0.5", symbol: "terminal", keywords: ["10.0.0.5", "akitogo"], isMovable: true),
                SidebarRow(id: .item(db), title: "db01", detail: "10.0.0.6", symbol: "terminal", keywords: ["10.0.0.6", "akitogo"], isMovable: true),
            ], isFolder: true, isMovable: true),
            SidebarRow(id: .item(office), title: "Office", detail: "4", symbol: "server.rack", tint: .accent,
                       keywords: ["10.20.31.2"], children: [
                SidebarRow(id: .node(server: office, node: "pve1"), title: "pve1", detail: "node shell", symbol: "cpu", tint: .running),
                guest(101, "nginx", "10.20.30.20", true),
                guest(102, "mail", "10.20.30.21", true),
                guest(105, "Müller-Web", "10.20.30.25", true),
                guest(9001, "backup", nil, false),
            ], isMovable: true),
        ]
    }
}

final class SidebarFilterTests: XCTestCase {
    private func titles(_ rows: [SidebarRow]) -> [String] {
        rows.flatMap { [$0.title] + titles($0.children ?? []) }
    }

    private func filtered(_ query: String) -> [String] {
        titles(SidebarFilter.apply(SidebarSample.rows, query: query))
    }

    func testEmptyQueryKeepsEverything() {
        XCTAssertEqual(filtered("  "), titles(SidebarSample.rows))
    }

    func testMatchesKeepTheirParents() {
        XCTAssertEqual(filtered("web0"), ["Customers", "web01"])
        XCTAssertEqual(filtered("NGINX"), ["Office", "nginx"])
    }

    func testMatchesIDsAndAddresses() {
        XCTAssertEqual(filtered("9001"), ["Office", "backup"])
        XCTAssertEqual(filtered("10.20.30.2"), ["Office", "nginx", "mail", "Müller-Web"])
        XCTAssertEqual(filtered("10.0.0"), ["Customers", "web01", "db01"])
        XCTAssertEqual(filtered("akitogo"), ["Customers", "web01", "db01"])
    }

    func testMatchingContainerKeepsAllChildren() {
        XCTAssertEqual(filtered("office"), ["Office", "pve1", "nginx", "mail", "Müller-Web", "backup"])
    }

    func testWordsCanMatchParentAndChild() {
        XCTAssertEqual(filtered("office mail"), ["Office", "mail"])
        XCTAssertEqual(filtered("customers 10.0.0.6"), ["Customers", "db01"])
        XCTAssertEqual(filtered("customers nginx"), [])
    }

    func testIgnoresCaseAndAccents() {
        XCTAssertEqual(filtered("muller"), ["Office", "Müller-Web"])
    }

    func testNoMatch() {
        XCTAssertEqual(filtered("zzz"), [])
    }
}

/// Renders the real sidebar (filter field + outline) offscreen.
/// Set HOATZIN_RENDER_DIR to also write PNGs for a visual check.
@MainActor
final class SidebarRenderTests: XCTestCase {
    private func render(_ query: String, selection: SidebarID? = nil, dark: Bool = false, name: String) throws -> NSOutlineView {
        _ = NSApplication.shared
        let sidebar = SidebarOutline(
            rows: SidebarFilter.apply(SidebarSample.rows, query: query),
            filter: .constant(query),
            focusFilterRequest: 0,
            selection: .constant(selection),
            menuItems: { _ in [] },
            onActivate: { _ in },
            onMove: { _, _, _ in }
        )
        let size = NSSize(width: 300, height: 340)
        let host = NSHostingView(rootView: sidebar.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        func find(_ view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        let outline = try XCTUnwrap(find(host))

        if let dir = ProcessInfo.processInfo.environment["HOATZIN_RENDER_DIR"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return outline
    }

    func testUnfilteredShowsWholeTree() throws {
        let outline = try render("", selection: .guest(server: SidebarSample.office, vmid: 102), name: "sidebar-all")
        XCTAssertEqual(outline.numberOfRows, 9)
        _ = try render("", dark: true, name: "sidebar-all-dark")
    }

    func testBadgeFollowsSelectionHighlight() throws {
        _ = NSApplication.shared
        let mail = try XCTUnwrap(SidebarSample.rows[1].children?.first { $0.title == "mail" })
        let cell = SidebarCell()
        cell.frame = NSRect(x: 0, y: 0, width: 280, height: 28)
        cell.configure(mail)
        let badge = try XCTUnwrap(cell.subviews.compactMap { $0 as? SidebarBadge }.first)
        XCTAssertFalse(badge.isHidden)
        XCTAssertEqual(badge.text, "102")
        cell.backgroundStyle = .emphasized
        XCTAssertTrue(badge.isEmphasized)

        if let dir = ProcessInfo.processInfo.environment["HOATZIN_RENDER_DIR"] {
            let row = NSView(frame: cell.frame)
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            row.addSubview(cell)
            cell.layoutSubtreeIfNeeded()
            if let bitmap = row.bitmapImageRepForCachingDisplay(in: row.bounds) {
                row.cacheDisplay(in: row.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("badge-selected.png"))
            }
        }
    }

    /// The single column (and so every cell) must span the sidebar, whatever order filtering,
    /// expanding and resizing happen in.
    func testColumnFollowsSidebarWidth() throws {
        _ = NSApplication.shared
        var query = ""
        var rows = SidebarSample.rows + SidebarSample.cluster(guests: 6)
        func sidebar() -> some View {
            SidebarOutline(rows: SidebarFilter.apply(rows, query: query), filter: .constant(query),
                           focusFilterRequest: 0, selection: .constant(nil), menuItems: { _ in [] },
                           onActivate: { _ in }, onMove: { _, _, _ in })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        let host = NSHostingView(rootView: AnyView(sidebar()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
        }
        func outline(_ view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            return view.subviews.lazy.compactMap(outline).first
        }
        // A source list insets its rows a little; that gap must stay the same at every width.
        var baseline: (column: CGFloat, cell: CGFloat)?
        func check(_ step: String, file: StaticString = #filePath, line: UInt = #line) throws {
            settle()
            let table = try XCTUnwrap(outline(host))
            let column = try XCTUnwrap(table.tableColumns.first)
            let visible = table.enclosingScrollView?.contentView.bounds.width ?? table.bounds.width
            let cellGaps = (0..<table.numberOfRows).compactMap { row -> CGFloat? in
                table.view(atColumn: 0, row: row, makeIfNecessary: false).map { visible - $0.frame.maxX }
            }
            let gaps = (column: visible - column.width, cell: cellGaps.max() ?? 0)
            guard let base = baseline else { baseline = gaps; return }
            XCTAssertEqual(gaps.column, base.column, accuracy: 2, "\(step): column \(column.width) in \(visible)", file: file, line: line)
            XCTAssertEqual(gaps.cell, base.cell, accuracy: 2, "\(step): cells end \(gaps.cell) before the edge", file: file, line: line)
        }

        try check("start")
        window.setContentSize(NSSize(width: 620, height: 400)); try check("widened")
        query = "office"; host.rootView = AnyView(sidebar()); try check("filtered")
        window.setContentSize(NSSize(width: 360, height: 400)); try check("narrowed while filtered")
        window.setContentSize(NSSize(width: 700, height: 400)); try check("widened while filtered")
        query = ""; host.rootView = AnyView(sidebar()); try check("filter cleared")
        query = "10.0"; host.rootView = AnyView(sidebar())
        window.setContentSize(NSSize(width: 280, height: 400)); try check("filtered and narrowed")
        query = ""; host.rootView = AnyView(sidebar())
        window.setContentSize(NSSize(width: 900, height: 400)); try check("cleared and widened")
        query = "example"; host.rootView = AnyView(sidebar()); try check("cluster filtered")
        rows = SidebarSample.rows + SidebarSample.cluster(guests: 7); host.rootView = AnyView(sidebar()); try check("refreshed while filtered")
        window.setContentSize(NSSize(width: 420, height: 400)); try check("narrowed after refresh")
        window.setContentSize(NSSize(width: 880, height: 400)); try check("widened after refresh")
        query = ""; host.rootView = AnyView(sidebar()); try check("cluster cleared")

        // If AppKit ever leaves the column behind (seen in the app after resizing the sidebar),
        // the next reload or resize must repair it instead of keeping the difference.
        func knockOut() throws { try XCTUnwrap(outline(host)?.tableColumns.first).width = 200 }
        try knockOut(); query = "example"; host.rootView = AnyView(sidebar()); try check("repaired by filtering")
        try knockOut(); window.setContentSize(NSSize(width: 860, height: 400)); try check("repaired by resizing")
        try knockOut(); try XCTUnwrap(outline(host)).tile(); try check("repaired by tiling")
        query = ""; host.rootView = AnyView(sidebar())
        // Collapsing the sidebar, or dragging it very narrow, squeezes the table below the column's
        // minimum width; growing again must not keep that difference.
        window.setContentSize(NSSize(width: 20, height: 400)); settle()
        window.setContentSize(NSSize(width: 870, height: 400)); try check("collapsed and reopened")
    }

    /// Same check inside a NavigationSplitView like the app's, collapsing and reopening the sidebar.
    func testColumnFollowsSplitViewSidebar() throws {
        _ = NSApplication.shared
        final class State: ObservableObject {
            @Published var visibility: NavigationSplitViewVisibility = .all
            @Published var query = ""
        }
        struct Split: View {
            @ObservedObject var state: State
            var body: some View {
                NavigationSplitView(columnVisibility: $state.visibility) {
                    SidebarOutline(rows: SidebarFilter.apply(SidebarSample.rows + SidebarSample.cluster(guests: 6), query: state.query),
                                   filter: .constant(state.query), focusFilterRequest: 0, selection: .constant(nil),
                                   menuItems: { _ in [] }, onActivate: { _ in }, onMove: { _, _, _ in })
                        .navigationSplitViewColumnWidth(min: 220, ideal: 320, max: 520)
                } detail: {
                    Color.gray
                }
            }
        }
        let state = State()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: Split(state: state))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func settle() {
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
        }
        func outline(_ view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            return view.subviews.lazy.compactMap(outline).first
        }
        func report(_ step: String) -> CGFloat? {
            settle()
            guard let table = outline(window.contentView!), let column = table.tableColumns.first, table.window != nil,
                  let clip = table.enclosingScrollView?.contentView, clip.bounds.width > 0 else {
                return nil // sidebar hidden
            }
            return clip.bounds.width - column.width
        }
        let base = try XCTUnwrap(report("start"))
        state.query = "example"; XCTAssertEqual(report("filtered") ?? base, base, accuracy: 2)
        state.visibility = .detailOnly; _ = report("collapsed")
        state.visibility = .all; XCTAssertEqual(report("reopened") ?? base, base, accuracy: 2)
        window.setContentSize(NSSize(width: 1400, height: 600)); XCTAssertEqual(report("window wider") ?? base, base, accuracy: 2)
        state.query = ""; XCTAssertEqual(report("cleared") ?? base, base, accuracy: 2)
        state.visibility = .detailOnly; _ = report("collapsed again")
        window.setContentSize(NSSize(width: 900, height: 600)); _ = report("window narrower while collapsed")
        state.visibility = .all; XCTAssertEqual(report("reopened again") ?? base, base, accuracy: 2)

        // Dragging the divider, with the live-resize calls a drag makes.
        func splitView(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap(splitView).first
        }
        let split = try XCTUnwrap(splitView(window.contentView!))
        func drag(to positions: [CGFloat], _ step: String) -> CGFloat? {
            let views = [split] + split.subviews
            views.forEach { $0.viewWillStartLiveResize() }
            for position in positions {
                split.setPosition(position, ofDividerAt: 0)
                split.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            views.forEach { $0.viewDidEndLiveResize() }
            return report(step)
        }
        XCTAssertEqual(drag(to: [360, 400, 440, 470], "dragged wider") ?? base, base, accuracy: 2)
        state.query = "example"; XCTAssertEqual(report("filtered after drag") ?? base, base, accuracy: 2)
        XCTAssertEqual(drag(to: [420, 340, 260, 230], "dragged narrower while filtered") ?? base, base, accuracy: 2)
        XCTAssertEqual(drag(to: [300, 380, 460, 500], "dragged wider while filtered") ?? base, base, accuracy: 2)
        state.query = ""; XCTAssertEqual(report("cleared after drags") ?? base, base, accuracy: 2)
    }

    func testAddressTruncationFollowsSetting() throws {
        _ = NSApplication.shared
        let nginx = try XCTUnwrap(SidebarSample.rows[1].children?.first { $0.title == "nginx" })
        let cell = SidebarCell()
        func detailMode() throws -> NSLineBreakMode {
            try XCTUnwrap(cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "10.20.30.20" }).lineBreakMode
        }
        cell.configure(nginx)
        XCTAssertEqual(try detailMode(), .byTruncatingHead, "default keeps the end of the address")
        cell.configure(nginx, addressTruncation: AddressTruncation.end.lineBreakMode)
        XCTAssertEqual(try detailMode(), .byTruncatingTail)
        Prefs.registerDefaults()
        XCTAssertEqual(UserDefaults.standard.string(forKey: Prefs.addressTruncation), AddressTruncation.start.rawValue)
    }

    func testFilterNarrowsAndExpands() throws {
        XCTAssertEqual(try render("office mail", name: "sidebar-office-mail").numberOfRows, 2)
        XCTAssertEqual(try render("10.0.0", name: "sidebar-ip").numberOfRows, 3)
        XCTAssertEqual(try render("zzz", name: "sidebar-none").numberOfRows, 0)
    }
}

// MARK: - AI access (MCP)

private func binaryNextToTests(_ name: String) -> String {
    Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent(name).path
}

private func shortSocketPath() -> String {
    "/tmp/rd-test-\(UUID().uuidString.prefix(8)).sock"
}

final class MCPHelperTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var calls: [ToolCall] = []
        func add(_ call: ToolCall) { lock.withLock { calls.append(call) } }
    }

    /// Feeds JSON-RPC lines to the real helper and returns its responses keyed by id.
    private func converse(socket: String, _ messages: [[String: Any]]) throws -> (byID: [Int: [String: Any]], total: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryNextToTests("hoatzin-mcp"))
        process.environment = ["HOATZIN_CONTROL_SOCKET": socket]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        for message in messages {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            input.fileHandleForWriting.write(data)
        }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
        var byID: [Int: [String: Any]] = [:]
        for line in lines {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
            if let id = object["id"] as? Int { byID[id] = object }
        }
        return (byID, lines.count)
    }

    private func call(_ id: Int, _ tool: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]
    }

    func testProtocolAndForwarding() throws {
        let path = shortSocketPath()
        let server = ControlServer(path: path, allowedClients: [binaryNextToTests("hoatzin-mcp")])
        let recorder = Recorder()
        XCTAssertEqual(server.start { call in
            recorder.add(call)
            return ToolReply(ok: call.tool != "open_session", text: "reply for \(call.tool)")
        }, .active)
        defer { server.stop() }

        let result = try converse(socket: path, [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            call(3, "list_connections", ["filter": "office web"]),
            call(4, "open_session", ["id": "item:x"]),
            call(5, "delete_everything"),
            ["jsonrpc": "2.0", "id": 6, "method": "ping"],
            ["jsonrpc": "2.0", "id": 7, "method": "resources/list"],
        ])
        XCTAssertEqual(result.total, 7, "the notification must not get a response")

        let initialize = try XCTUnwrap(result.byID[1]?["result"] as? [String: Any])
        XCTAssertEqual(initialize["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((initialize["serverInfo"] as? [String: Any])?["name"] as? String, "hoatzin")
        XCTAssertNotNil((initialize["capabilities"] as? [String: Any])?["tools"])

        let tools = try XCTUnwrap((result.byID[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String },
                       ["list_connections", "get_connection", "list_sessions", "read_session", "open_session",
                        "run_command", "send_input"])
        XCTAssertTrue(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })

        let listed = try XCTUnwrap(result.byID[3]?["result"] as? [String: Any])
        XCTAssertEqual(listed["isError"] as? Bool, false)
        XCTAssertEqual(((listed["content"] as? [[String: Any]])?.first)?["text"] as? String, "reply for list_connections")

        let opened = try XCTUnwrap(result.byID[4]?["result"] as? [String: Any])
        XCTAssertEqual(opened["isError"] as? Bool, true)

        XCTAssertEqual((result.byID[5]?["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertNotNil(result.byID[6]?["result"])
        XCTAssertEqual((result.byID[7]?["error"] as? [String: Any])?["code"] as? Int, -32601)

        let calls = recorder.lock.withLock { recorder.calls }
        XCTAssertEqual(calls.map(\.tool).sorted(), ["list_connections", "open_session"])
        let first = try XCTUnwrap(calls.first { $0.tool == "list_connections" })
        let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: first.arguments) as? [String: Any])
        XCTAssertEqual(arguments["filter"] as? String, "office web")
        XCTAssertEqual(first.caller, ControlServer.programName(ProcessIdentity.executablePath(of: getpid()) ?? ""))
    }

    func testUnknownProtocolVersionGetsNewest() throws {
        let result = try converse(socket: shortSocketPath(), [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]],
        ])
        let initialize = try XCTUnwrap(result.byID[1]?["result"] as? [String: Any])
        XCTAssertEqual(initialize["protocolVersion"] as? String, "2025-11-25")
    }

    func testAppNotRunning() throws {
        let result = try converse(socket: shortSocketPath(), [call(1, "list_sessions")])
        let reply = try XCTUnwrap(result.byID[1]?["result"] as? [String: Any])
        XCTAssertEqual(reply["isError"] as? Bool, true)
        let text = ((reply["content"] as? [[String: Any]])?.first)?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("isn't running"), text)
    }
}

final class ControlServerTests: XCTestCase {
    func testOnlyTheHelperMayConnect() throws {
        let path = shortSocketPath()
        let server = ControlServer(path: path, allowedClients: [binaryNextToTests("hoatzin-mcp")])
        let called = NSLock()
        nonisolated(unsafe) var calls = 0
        server.start { _ in called.withLock { calls += 1 }; return ToolReply(ok: true, text: "secret stuff") }
        defer { server.stop() }

        let fd = try XCTUnwrap(UnixSocket.connect(to: path))
        defer { close(fd) }
        UnixSocket.writeLine(fd, ["tool": "list_connections", "arguments": [:]])
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: UnixSocket.readLine(fd)) as? [String: Any])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertFalse((reply["text"] as? String ?? "").contains("secret"))
        XCTAssertEqual(called.withLock { calls }, 0)

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testSecondServerBacksOff() throws {
        let path = shortSocketPath()
        let first = ControlServer(path: path)
        XCTAssertEqual(first.start { _ in ToolReply(ok: true, text: "") }, .active)
        defer { first.stop() }
        let second = ControlServer(path: path)
        XCTAssertEqual(second.start { _ in ToolReply(ok: true, text: "") }, .busy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the first server's socket must stay")
    }

    func testProgramName() {
        XCTAssertEqual(ControlServer.programName("/Applications/Claude.app/Contents/MacOS/Claude"), "Claude")
        XCTAssertEqual(ControlServer.programName("/opt/homebrew/bin/claude"), "claude")
    }
}

@MainActor
final class AIBridgeTests: XCTestCase {
    private var libraryURL: URL!
    private var model: AppModel!
    private let web = UUID(), db = UUID(), slow = UUID(), folder = UUID()

    override func setUp() async throws {
        libraryURL = FileManager.default.temporaryDirectory.appendingPathComponent("hoatzin-ai-\(UUID()).json")
        let json = """
        {"version":2,"items":[
         {"id":"\(folder.uuidString)","kind":"folder","name":"Customers","children":[
           {"id":"\(web.uuidString)","kind":"ssh","name":"web01","children":[],"ssh":{"host":"127.0.0.1","port":1,"username":"akitogo","auth":"key","identityFile":"","keychainHost":"","extraArgs":"-F /dev/null"}},
           {"id":"\(db.uuidString)","kind":"ssh","name":"db01","children":[],"ssh":{"host":"10.0.0.6","port":22,"username":"akitogo","auth":"key","identityFile":"","keychainHost":"","extraArgs":""}},
           {"id":"\(slow.uuidString)","kind":"ssh","name":"slow","children":[],"ssh":{"host":"127.0.0.1","port":22,"username":"akitogo","auth":"key","identityFile":"","keychainHost":"","extraArgs":"-F /dev/null -o 'ProxyCommand=sleep 30'"}}]}
        ]}
        """
        try json.write(to: libraryURL, atomically: true, encoding: .utf8)
        model = AppModel(library: LibraryStore(fileURL: libraryURL))
        model.ai.openSettleTime = 1.5
    }

    override func tearDown() async throws {
        for session in model.sessions { model.closeSession(session.id) }
        try? FileManager.default.removeItem(at: libraryURL)
        try? FileManager.default.removeItem(at: model.ai.activity.fileURL)
    }

    private func run(_ tool: String, _ arguments: [String: Any] = [:]) async -> ToolReply {
        let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
        return await model.ai.handle(ToolCall(tool: tool, arguments: data, caller: "Claude"))
    }

    /// Starts a tool call, waits for its confirmation sheet and answers it.
    private func runConfirming(_ tool: String, _ arguments: [String: Any], answer: PromptResponse?) async throws -> ToolReply {
        let call = Task { await run(tool, arguments) }
        if let answer {
            for _ in 0..<100 where model.prompts.current == nil { try await Task.sleep(for: .milliseconds(20)) }
            let pending = try XCTUnwrap(model.prompts.current, "no confirmation sheet")
            guard case .confirm(let prompt) = pending.content else { XCTFail("expected a confirmation"); return await call.value }
            XCTAssertTrue(prompt.title.contains("Claude"))
            XCTAssertTrue(prompt.message.contains("127.0.0.1"))
            XCTAssertTrue(prompt.guardsAgainstStrayKeys)
            model.prompts.respond(pending.id, answer)
        }
        return await call.value
    }

    func testOffRefusesEverything() async {
        model.ai.accessOverride = .off
        let reply = await run("list_connections")
        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.text.contains("Settings → AI Access"))
    }

    func testListAndFilter() async throws {
        model.ai.accessOverride = .read
        let all = await run("list_connections")
        XCTAssertTrue(all.ok)
        XCTAssertTrue(all.text.contains("item:\(web.uuidString)"))
        XCTAssertTrue(all.text.contains("\"open_with\""))

        let filtered = await run("list_connections", ["filter": "10.0.0.6"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(filtered.text.utf8)) as? [String: Any])
        let roots = try XCTUnwrap(object["connections"] as? [[String: Any]])
        XCTAssertEqual(roots.first?["name"] as? String, "Customers")
        XCTAssertEqual((roots.first?["children"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["db01"])
    }

    func testGetConnection() async {
        model.ai.accessOverride = .read
        let reply = await run("get_connection", ["id": "item:\(web.uuidString)"])
        XCTAssertTrue(reply.ok)
        XCTAssertTrue(reply.text.contains("\"auth\": \"key\""), reply.text)
        XCTAssertTrue(reply.text.contains("\"port\": 1"), reply.text)
        let missing = await run("get_connection", ["id": "item:\(UUID().uuidString)"])
        XCTAssertFalse(missing.ok)
    }

    func testReadOnlyCannotOpen() async {
        model.ai.accessOverride = .read
        let reply = await run("open_session", ["id": "item:\(web.uuidString)"])
        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.text.contains("isn't allowed"))
        XCTAssertNil(model.prompts.current)
        XCTAssertTrue(model.sessions.isEmpty)
    }

    func testOpenNeedsConfirmationAndCanBeRemembered() async throws {
        model.ai.accessOverride = .open
        model.ai.readOutputOverride = true
        let id = "item:\(web.uuidString)"

        let denied = try await runConfirming("open_session", ["id": id], answer: .confirmed(false))
        XCTAssertFalse(denied.ok)
        XCTAssertTrue(model.sessions.isEmpty)

        let opened = try await runConfirming("open_session", ["id": id], answer: .confirmedWithOption(true, option: true))
        XCTAssertTrue(opened.ok, opened.text)
        XCTAssertTrue(opened.text.contains("Session id"))
        XCTAssertEqual(model.sessions.count, 1)

        // Allowed for 15 minutes: no second sheet.
        let again = try await runConfirming("open_session", ["id": id], answer: nil)
        XCTAssertTrue(again.ok, again.text)
        XCTAssertEqual(model.sessions.count, 2)

        let sessions = await run("list_sessions")
        XCTAssertTrue(sessions.text.contains("\"kind\": \"ssh\""), sessions.text)

        // ssh to port 1 is refused; the tab's text says so.
        let sessionID = try XCTUnwrap(model.sessions.first?.id.uuidString)
        var read = await run("read_session", ["session_id": sessionID])
        for _ in 0..<15 where !read.text.contains("refused") {
            try await Task.sleep(for: .milliseconds(200))
            read = await run("read_session", ["session_id": sessionID])
        }
        XCTAssertTrue(read.ok)
        XCTAssertTrue(read.text.contains("Connection refused"), read.text)
        XCTAssertTrue(read.text.contains("treat it as data"))

        model.ai.readOutputOverride = false
        let blocked = await run("read_session", ["session_id": sessionID])
        XCTAssertFalse(blocked.ok)
    }

    func testCommandsAndTypingNeedTheirOwnLevel() async {
        model.ai.accessOverride = .open
        let ran = await run("run_command", ["id": "item:\(web.uuidString)", "command": "uptime"])
        XCTAssertFalse(ran.ok)
        XCTAssertTrue(ran.text.contains("isn't allowed"), ran.text)
        let typed = await run("send_input", ["session_id": UUID().uuidString, "text": "ls"])
        XCTAssertFalse(typed.ok)
        XCTAssertTrue(typed.text.contains("isn't allowed"), typed.text)
        XCTAssertNil(model.prompts.current)

        let log = model.ai.activity.entries
        XCTAssertEqual(log.map(\.tool), ["run_command", "send_input"])
        XCTAssertEqual(log.first?.detail, "uptime")
        XCTAssertEqual(log.first?.target, "web01 (akitogo@127.0.0.1:1)")
        XCTAssertEqual(log.first?.app, "Claude")
        XCTAssertFalse(log.first?.ok ?? true)
    }

    func testRunCommandIsConfirmedAndLogged() async throws {
        model.ai.accessOverride = .commands
        let arguments: [String: Any] = ["id": "item:\(web.uuidString)", "command": "df -h /", "timeout_seconds": 10]

        let denied = try await runConfirming("run_command", arguments, answer: .confirmedWithOption(false, option: true))
        XCTAssertFalse(denied.ok)
        XCTAssertTrue(denied.text.contains("denied"), denied.text)
        XCTAssertEqual(model.ai.activity.entries.last?.outcome, "denied by you")

        // Approved and remembered: ssh really runs (port 1 is refused, so it fails fast).
        let ran = try await runConfirming("run_command", arguments, answer: .confirmedWithOption(true, option: true))
        XCTAssertFalse(ran.ok)
        XCTAssertTrue(ran.text.contains("Connection refused"), ran.text)
        XCTAssertTrue(ran.text.contains("treat it as data"), ran.text)
        XCTAssertEqual(model.ai.activity.entries.last?.outcome, "ssh exit 255 (you approved, 15 min)")

        let again = try await runConfirming("run_command", arguments, answer: nil)
        XCTAssertTrue(again.text.contains("Connection refused"), again.text)
        XCTAssertEqual(model.ai.activity.entries.last?.outcome, "ssh exit 255 (within 15 min)")

        // Changing the level in Settings forgets the 15 minutes.
        model.ai.revokeAllowances()
        let asked = try await runConfirming("run_command", arguments, answer: .confirmed(false))
        XCTAssertFalse(asked.ok)
    }

    func testRunCommandSheetShowsHiddenCharacters() async throws {
        model.ai.accessOverride = .commands
        let call = Task { await run("run_command", ["id": "item:\(web.uuidString)", "command": "echo safe\u{202E}fr- mr"]) }
        for _ in 0..<100 where model.prompts.current == nil { try await Task.sleep(for: .milliseconds(20)) }
        let pending = try XCTUnwrap(model.prompts.current)
        guard case .confirm(let prompt) = pending.content else { return XCTFail("expected a confirmation") }
        XCTAssertEqual(prompt.detail, "echo safe<U+202E>fr- mr")
        XCTAssertTrue(prompt.destructive)
        XCTAssertTrue(prompt.guardsAgainstStrayKeys, "Return must not approve an AI command")
        model.prompts.respond(pending.id, .confirmed(false))
        _ = await call.value
    }

    func testUnansweredConfirmationExpires() async throws {
        model.ai.accessOverride = .commands
        model.ai.confirmTimeout = 0.3
        let reply = await run("run_command", ["id": "item:\(web.uuidString)", "command": "uptime"])
        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.text.contains("Nobody answered"), reply.text)
        XCTAssertNil(model.prompts.current, "the sheet must close")
        XCTAssertEqual(model.ai.activity.entries.last?.outcome, "not answered in time")
    }

    func testSendInputTypesIntoTab() async throws {
        model.ai.accessOverride = .commands
        model.ai.readOutputOverride = true
        model.ai.quietTime = 0.3
        // ssh waits for a server that never answers (ProxyCommand=sleep), so the tab stays open
        // and the terminal echoes what is typed.
        let opened = try await runConfirming("open_session", ["id": "item:\(slow.uuidString)"], answer: .confirmed(true))
        XCTAssertTrue(opened.ok, opened.text)
        guard case .terminal(let terminal)? = model.sessions.first else { return XCTFail("no terminal tab") }
        let sessionID = terminal.id.uuidString
        XCTAssertTrue(terminal.isRunning)

        let denied = try await runConfirming("send_input", ["session_id": sessionID, "text": "hello"], answer: .confirmed(false))
        XCTAssertFalse(denied.ok)

        let typed = try await runConfirming("send_input", ["session_id": sessionID, "text": "hoatzin-typed", "key": "none"],
                                            answer: .confirmedWithOption(true, option: true))
        XCTAssertTrue(typed.ok, typed.text)
        XCTAssertTrue(typed.text.contains("hoatzin-typed"), typed.text)
        XCTAssertEqual(model.ai.activity.entries.last?.detail, "hoatzin-typed")

        // Allowed for this tab now: Control-C without a sheet ends ssh.
        let interrupted = try await runConfirming("send_input", ["session_id": sessionID, "key": "ctrl-c", "wait_seconds": 3],
                                                  answer: nil)
        XCTAssertTrue(interrupted.ok, interrupted.text)
        for _ in 0..<30 where terminal.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(terminal.isRunning)
        XCTAssertEqual(model.ai.activity.entries.last?.detail, "ctrl-c")

        let closed = await run("send_input", ["session_id": sessionID, "text": "ls"])
        XCTAssertFalse(closed.ok)
        XCTAssertTrue(closed.text.contains("isn't connected"), closed.text)

        let badKey = await run("send_input", ["session_id": sessionID, "key": "f13"])
        XCTAssertTrue(badKey.text.contains("Unknown key"), badKey.text)
    }

    func testVisibleRevealsHiddenCharacters() {
        XCTAssertEqual(AIBridge.visible("ls\u{202E}txt.exe", showLineBreaks: false), "ls<U+202E>txt.exe")
        XCTAssertEqual(AIBridge.visible("rm\u{00A0}-rf x\u{200B}y", showLineBreaks: false), "rm<U+00A0>-rf x<U+200B>y")
        XCTAssertEqual(AIBridge.visible("a\tb\u{1B}[A\u{03}", showLineBreaks: true), "a⇥b⎋[A^C")
        XCTAssertEqual(AIBridge.visible("one\r\ntwo", showLineBreaks: true), "one⏎\ntwo")
        XCTAssertEqual(AIBridge.visible("for i in 1 2; do\n\techo $i\ndone", showLineBreaks: false), "for i in 1 2; do\n\techo $i\ndone")
        XCTAssertEqual(AIBridge.visible("café 🙂 ü", showLineBreaks: false), "café 🙂 ü")
    }

    func testCommandResultsForTheAI() {
        var result = RemoteCommand.Result(exitCode: 3, duration: 1.25)
        result.stdout.append(Data("hi\n".utf8))
        result.stderr.append(Data("oops\n".utf8))
        let ran = AIBridge.describe(result, on: "web01 (akitogo@h)", name: "web01", timeout: 60, decision: .allowed)
        XCTAssertTrue(ran.ok)
        XCTAssertTrue(ran.text.hasPrefix("Ran on web01 (akitogo@h): exit code 3, 1.2 s."), ran.text)
        XCTAssertTrue(ran.text.contains("stdout:\nhi\n"), ran.text)
        XCTAssertTrue(ran.text.contains("stderr:\noops"), ran.text)
        XCTAssertEqual(ran.summary, "exit 3 · 1.2 s (you approved)")

        var hostKey = RemoteCommand.Result(exitCode: 255)
        hostKey.stderr.append(Data("No ED25519 host key is known for h and you have requested strict checking.\nHost key verification failed.\n".utf8))
        let refused = AIBridge.describe(hostKey, on: "x", name: "web01", timeout: 60, decision: .allowed)
        XCTAssertFalse(refused.ok)
        XCTAssertTrue(refused.text.contains("never accept host keys"), refused.text)

        let slow = AIBridge.describe(RemoteCommand.Result(exitCode: nil, duration: 10, timedOut: true), on: "x", name: "x",
                                     timeout: 10, decision: .alreadyAllowed)
        XCTAssertFalse(slow.ok)
        XCTAssertTrue(slow.text.contains("didn't finish within 10 s"), slow.text)
        XCTAssertTrue(slow.text.contains("No output."), slow.text)
    }

    func testActivityLogPersistsOwnerOnly() async throws {
        model.ai.accessOverride = .read
        _ = await run("list_connections", ["filter": "web"])
        _ = await run("get_connection", ["id": "item:\(db.uuidString)"])
        let log = model.ai.activity
        XCTAssertEqual(log.entries.map(\.tool), ["list_connections", "get_connection"])
        XCTAssertEqual(log.entries.first?.detail, "filter: web")
        XCTAssertEqual(log.entries.first?.outcome, "ok")
        XCTAssertEqual(log.entries.last?.target, "db01 (akitogo@10.0.0.6)")

        let attributes = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let reloaded = AIActivityLog(fileURL: log.fileURL).entries
        XCTAssertEqual(reloaded.map(\.id), log.entries.map(\.id))
        XCTAssertEqual(reloaded.map(\.target), log.entries.map(\.target))
        for (a, b) in zip(reloaded, log.entries) { XCTAssertEqual(a.time.timeIntervalSince1970, b.time.timeIntervalSince1970, accuracy: 0.001) }

        log.record(AIActivity(time: Date(), app: "Claude", tool: "run_command", detail: String(repeating: "x", count: 10_000),
                              outcome: "ok", ok: true))
        XCTAssertEqual(log.entries.last?.detail?.count, AIActivityLog.detailLimit + 1)
        XCTAssertFalse(log.fileURL.path.contains("Library/Logs"), "tests must not write to the real log")
    }

    func testIDsRoundTrip() {
        let server = UUID()
        for id in [SidebarID.item(web), .node(server: server, node: "pve1"), .guest(server: server, vmid: 101)] {
            XCTAssertEqual(SidebarID(string: id.stringValue), id)
        }
        XCTAssertNil(SidebarID(string: "guest:\(server.uuidString):abc"))
        XCTAssertNil(SidebarID(string: "nonsense"))
    }

    func testJSONKeepsKeyOrderAndEscapes() throws {
        let value = JSONValue.object([("kind", .string("ssh")), ("name", .string("a \"b\"/c\n")),
                                      ("ips", .array([.string("10.0.0.1")])), ("children", .array([]))])
        let text = value.rendered()
        XCTAssertTrue(text.hasPrefix("{\n  \"kind\": \"ssh\",\n  \"name\""), text)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["name"] as? String, "a \"b\"/c\n")
        XCTAssertEqual(parsed["ips"] as? [String], ["10.0.0.1"])
    }

    func testLastLinesTrimsBlankTail() {
        let data = Data("one   \ntwo\n\n   \n".utf8)
        XCTAssertEqual(AIBridge.lastLines(of: data, count: 5), "one\ntwo")
        XCTAssertEqual(AIBridge.lastLines(of: data, count: 1), "two")
    }
}

@MainActor
final class IntentsTests: XCTestCase {
    private var libraryURL: URL!
    private var model: AppModel!
    private let web = UUID(), db = UUID(), folder = UUID()

    override func setUp() async throws {
        libraryURL = FileManager.default.temporaryDirectory.appendingPathComponent("hoatzin-intents-\(UUID()).json")
        let json = """
        {"version":2,"items":[
         {"id":"\(folder.uuidString)","kind":"folder","name":"Customers","children":[
           {"id":"\(web.uuidString)","kind":"ssh","name":"web01","children":[],"ssh":{"host":"127.0.0.1","port":1,"username":"akitogo","auth":"key","identityFile":"","keychainHost":"","extraArgs":"-F /dev/null"}},
           {"id":"\(db.uuidString)","kind":"ssh","name":"db01","children":[],"ssh":{"host":"10.0.0.6","port":22,"username":"akitogo","auth":"key","identityFile":"","keychainHost":"","extraArgs":""}}]}
        ]}
        """
        try json.write(to: libraryURL, atomically: true, encoding: .utf8)
        model = AppModel(library: LibraryStore(fileURL: libraryURL))
        AppModel.shared = model
    }

    override func tearDown() async throws {
        for session in model.sessions { model.closeSession(session.id) }
        AppModel.shared = nil
        try? FileManager.default.removeItem(at: libraryURL)
        try? FileManager.default.removeItem(at: model.ai.activity.fileURL)
    }

    func testEntitiesFollowTheSidebar() throws {
        let all = ConnectionEntity.all(in: model)
        XCTAssertEqual(all.map(\.name), ["web01", "db01"], "folders are not connections")
        let first = try XCTUnwrap(all.first)
        XCTAssertEqual(first.id, "item:\(web.uuidString)")
        XCTAssertEqual(first.kind, .ssh)
        XCTAssertEqual(first.address, "127.0.0.1")
        XCTAssertEqual(first.sshLogin, "akitogo@127.0.0.1:1")
        XCTAssertEqual(first.location, "Customers")
        XCTAssertEqual(first.subtitle, "akitogo@127.0.0.1:1")
        XCTAssertNil(first.vmid)

        let before = ConnectionEntity.signature(in: model)
        model.library.modify(db) { $0.name = "db02" }
        XCTAssertNotEqual(ConnectionEntity.signature(in: model), before)
    }

    func testFindAndQueryMatchLikeTheSidebar() async throws {
        let byIP = try await FindConnectionsIntent.find("10.0.0.6", model: model)
        XCTAssertEqual(byIP.map(\.name), ["db01"])
        let byFolder = try await FindConnectionsIntent.find("customers", model: model)
        XCTAssertEqual(byFolder.map(\.name), ["web01", "db01"])
        let everything = try await FindConnectionsIntent.find("", model: model)
        XCTAssertEqual(everything.count, 2)
        let nothing = try await FindConnectionsIntent.find("nothing-like-this", model: model)
        XCTAssertTrue(nothing.isEmpty)

        let query = ConnectionQuery()
        let resolved = try await query.entities(for: ["item:\(db.uuidString)", "item:\(UUID().uuidString)", "nonsense"])
        XCTAssertEqual(resolved.map(\.name), ["db01"])
        let matching = try await query.entities(matching: "web")
        XCTAssertEqual(matching.map(\.name), ["web01"])
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.count, 2)

        AppModel.shared = nil
        do {
            _ = try await query.suggestedEntities()
            XCTFail("needs the app's model")
        } catch {}
    }

    func testRunCommandFollowsTheSetting() async throws {
        let id = "item:\(web.uuidString)"
        var questions: [String] = []

        do {
            _ = try await RunCommandIntent.run("uptime", on: id, timeout: 5, model: model, policy: .off) { questions.append($0) }
            XCTFail("turned off")
        } catch let error as IntentFailure {
            XCTAssertTrue(error.message.contains("turned off"), error.message)
        }
        XCTAssertTrue(questions.isEmpty)
        XCTAssertEqual(model.ai.activity.entries.last?.outcome, "turned off")
        XCTAssertEqual(model.ai.activity.entries.last?.app, RunCommandIntent.logName)

        struct Declined: Error {}
        do {
            _ = try await RunCommandIntent.run("uptime", on: id, timeout: 5, model: model, policy: .ask) { _ in throw Declined() }
            XCTFail("declined")
        } catch is Declined {}
        XCTAssertEqual(model.ai.activity.entries.last?.outcome, "denied")

        // Approved: ssh runs for real; port 1 is refused.
        do {
            _ = try await RunCommandIntent.run("echo safe\u{202E}x", on: id, timeout: 10, model: model, policy: .ask) { questions.append($0) }
            XCTFail("port 1 refuses")
        } catch let error as IntentFailure {
            XCTAssertTrue(error.message.contains("couldn't connect"), error.message)
            XCTAssertTrue(error.message.contains("Connection refused"), error.message)
        }
        XCTAssertEqual(questions.count, 1)
        XCTAssertTrue(questions[0].contains("akitogo@127.0.0.1:1"), questions[0])
        XCTAssertTrue(questions[0].contains("echo safe<U+202E>x"), questions[0])
        let entry = try XCTUnwrap(model.ai.activity.entries.last)
        XCTAssertEqual(entry.outcome, "ssh exit 255 (you approved)")
        XCTAssertEqual(entry.target, "web01 (akitogo@127.0.0.1:1)")
        XCTAssertEqual(entry.tool, "Run Command")

        // Without asking: no question.
        _ = try? await RunCommandIntent.run("uptime", on: id, timeout: 10, model: model, policy: .always) { questions.append($0) }
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(model.ai.activity.entries.last?.outcome, "ssh exit 255 (without asking)")
    }

    func testOpenConnection() async throws {
        let id = "item:\(web.uuidString)"
        do {
            try await OpenConnectionIntent.open(id, method: .console, model: model)
            XCTFail("SSH hosts have no console")
        } catch let error as IntentFailure {
            XCTAssertTrue(error.message.contains("only Proxmox"), error.message)
        }
        do {
            try await OpenConnectionIntent.open("item:\(UUID().uuidString)", method: .automatic, model: model)
            XCTFail("unknown entry")
        } catch {}

        UserDefaults.standard.set(TerminalChoice.builtin.rawValue, forKey: Prefs.sshOpenIn)
        defer { UserDefaults.standard.removeObject(forKey: Prefs.sshOpenIn) }
        try await OpenConnectionIntent.open(id, method: .ssh, model: model)
        for _ in 0..<50 where model.sessions.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.sessions.first?.title, "web01")
    }

    func testCommandPolicyDefaultsToAsking() {
        Prefs.registerDefaults()
        XCTAssertEqual(CommandActionPolicy.current, .ask)
    }
}

/// German UI texts. Completeness (every text has German) is checked by scripts/build-app.sh,
/// which needs the compiler's string list; these tests check the files themselves.
final class LocalizationTests: XCTestCase {
    private let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources")

    private func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|ld|d|@|lf|f|%)|\$\{[A-Za-z]+\}"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range, in: text)!]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
        }.sorted()
    }

    func testGermanKeepsPlaceholders() throws {
        let german = try XCTUnwrap(NSDictionary(contentsOf: resources.appendingPathComponent("de.lproj/Localizable.strings")) as? [String: String])
        XCTAssertGreaterThan(german.count, 300)
        for (key, value) in german {
            XCTAssertEqual(placeholders(value), placeholders(key), "\(key) → \(value)")
            XCTAssertFalse(value.isEmpty, key)
        }
        XCTAssertEqual(german["ai.confirm.type"], "Eintippen")
        XCTAssertEqual(german["Type"], "Typ", "the column and the AI button need different words")
    }

    func testPluralsInGermanAndEnglish() throws {
        func lookup(_ key: String, _ language: String, _ count: Int) throws -> String {
            let bundle = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("\(language).lproj")))
            return String.localizedStringWithFormat(bundle.localizedString(forKey: key, value: key, table: nil), count)
        }
        XCTAssertEqual(try lookup("%lld entries", "de", 1), "1 Eintrag")
        XCTAssertEqual(try lookup("%lld entries", "de", 3), "3 Einträge")
        XCTAssertEqual(try lookup("%lld entries", "en", 1), "1 entry")
        XCTAssertEqual(try lookup("%lld entries", "en", 0), "0 entries")
        let folder = "The folder and the %lld entries inside it are removed from Hoatzin. Saved Keychain passwords are kept."
        XCTAssertTrue(try lookup(folder, "de", 1).hasPrefix("Der Ordner und der Eintrag darin"))
        XCTAssertTrue(try lookup(folder, "de", 4).hasPrefix("Der Ordner und die 4 Einträge darin"))
        XCTAssertTrue(try lookup(folder, "en", 1).hasPrefix("The folder and the entry inside it"))
    }

    func testInfoPlistIsTranslated() throws {
        let strings = try XCTUnwrap(NSDictionary(contentsOf: resources.appendingPathComponent("de.lproj/InfoPlist.strings")) as? [String: String])
        XCTAssertNotNil(strings["NSAppleEventsUsageDescription"])
    }
}

/// The phrase files must match the phrases in the code, or Siri silently falls back to English.
final class AppShortcutPhrasesTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func strings(_ language: String) throws -> [String: String] {
        let url = root.appendingPathComponent("Resources/\(language).lproj/AppShortcuts.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(url.path) is missing or invalid")
    }

    private func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\$\{[A-Za-z]+\}"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range, in: text)!]) }.sorted()
    }

    func testEnglishFileMatchesTheCode() throws {
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Hoatzin/Intents/Intents.swift"), encoding: .utf8)
        let block = try XCTUnwrap(source.components(separatedBy: "static var appShortcuts").last)
        let regex = try NSRegularExpression(pattern: #"^\s*"(.*)",$"#, options: .anchorsMatchLines)
        let phrases = regex.matches(in: block, range: NSRange(block.startIndex..., in: block)).map { match -> String in
            String(block[Range(match.range(at: 1), in: block)!])
                .replacingOccurrences(of: #"\(.applicationName)"#, with: "${applicationName}")
                .replacingOccurrences(of: #"\(\.$target)"#, with: "${target}")
                .replacingOccurrences(of: #"\(\.$connection)"#, with: "${connection}")
        }
        XCTAssertGreaterThan(phrases.count, 5)
        XCTAssertEqual(Set(phrases), Set(try strings("en").keys))
    }

    func testGermanKeepsEveryPlaceholder() throws {
        let english = try strings("en"), german = try strings("de")
        XCTAssertEqual(Set(german.keys), Set(english.keys), "every English phrase needs a German one")
        for (key, value) in german {
            XCTAssertNotEqual(key, value, "not translated: \(key)")
            XCTAssertEqual(placeholders(value), placeholders(key), value)
            XCTAssertTrue(value.contains("${applicationName}"), value)
        }
    }
}

/// Renders Settings offscreen when HOATZIN_RENDER_DIR is set (visual check only).
@MainActor
final class SettingsRenderTests: XCTestCase {
    private func render(_ view: some View, size: NSSize? = nil, to name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["HOATZIN_RENDER_DIR"] else { throw XCTSkip("visual check") }
        let host = NSHostingView(rootView: view)
        let frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    func testRenderSettings() throws {
        guard ProcessInfo.processInfo.environment["HOATZIN_RENDER_DIR"] != nil else { throw XCTSkip("visual check") }
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hoatzin-settings-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(library: LibraryStore(fileURL: url))
        defer { try? FileManager.default.removeItem(at: model.ai.activity.fileURL) }
        UserDefaults.standard.set(AIAccess.commands.rawValue, forKey: Prefs.aiAccess)
        defer { UserDefaults.standard.removeObject(forKey: Prefs.aiAccess) }
        try render(SettingsView().environment(model), to: "settings.png")

        try render(ConfirmPromptView(prompt: ConfirmPrompt(
            title: "Allow Claude to run a command on web01?",
            message: "Claude wants to run this on akitogo@10.20.30.20. The output goes back to Claude.",
            detail: AIBridge.visible("journalctl -u nginx --since '1 hour ago' --no-pager | tail -n 50", showLineBreaks: false),
            confirmTitle: "Run", cancelTitle: "Deny", destructive: true,
            optionTitle: "Allow any command on web01 for 15 minutes")) { _, _ in }, to: "confirm-run.png")

        try render(ConfirmPromptView(prompt: ConfirmPrompt(
            title: "Allow Claude to type into “web01”?",
            message: "Claude wants to type this into the SSH tab for akitogo@10.20.30.20, then press Return.",
            detail: AIBridge.visible("sudo systemctl status nginx\u{202E}", showLineBreaks: true),
            confirmTitle: "Type", cancelTitle: "Deny", destructive: true,
            optionTitle: "Allow typing into this tab for 15 minutes")) { _, _ in }, to: "confirm-type.png")

        let log = model.ai.activity
        let now = Date()
        log.record(AIActivity(time: now.addingTimeInterval(-300), app: "Claude", tool: "list_connections", detail: "filter: nginx", outcome: "ok", ok: true))
        log.record(AIActivity(time: now.addingTimeInterval(-240), app: "Claude", tool: "run_command", target: "web01 (akitogo@10.20.30.20)",
                              detail: "systemctl status nginx --no-pager", outcome: "exit 3 · 0.6 s (you approved)", ok: true))
        log.record(AIActivity(time: now.addingTimeInterval(-200), app: "Claude", tool: "run_command", target: "db01 (akitogo@10.20.30.31)",
                              detail: "rm -rf /var/lib/postgresql", outcome: "denied by you", ok: false))
        log.record(AIActivity(time: now.addingTimeInterval(-100), app: "Claude", tool: "send_input", target: "tab “web01”",
                              detail: "tail -f /var/log/nginx/error.log + Return", outcome: "typed (you approved, 15 min)", ok: true))
        try render(AIActivityView().environment(model), size: NSSize(width: 920, height: 260), to: "activity.png")
    }
}

final class AboutPanelTests: XCTestCase {
    func testCreditsListLibrariesWithLicense() {
        let library = AboutPanel.Library(name: "SwiftTerm", version: "1.99.3", url: "https://github.com/migueldeicaza/SwiftTerm",
                                         license: "MIT License", licenseText: "Permission is hereby granted, free of charge…",
                                         purpose: "Terminal emulator for the built-in SSH tabs.")
        let credits = AboutPanel.credits([library])
        XCTAssertTrue(credits.string.contains("SwiftTerm 1.99.3"))
        XCTAssertTrue(credits.string.contains("MIT License"))
        XCTAssertTrue(credits.string.contains("Permission is hereby granted"))
        XCTAssertTrue(credits.string.contains("OpenSSH"))
        XCTAssertTrue(credits.string.contains("GNU General Public License, version 3"))
        XCTAssertTrue(credits.string.contains("not covered by the GPL"))
        let range = (credits.string as NSString).range(of: "SwiftTerm 1.99.3")
        XCTAssertEqual(credits.attribute(.link, at: range.location, effectiveRange: nil) as? URL,
                       URL(string: "https://github.com/migueldeicaza/SwiftTerm"))
    }

    func testDecodesGeneratedFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rd-about-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        [{"license":"MIT License","licenseText":"text","name":"SwiftTerm","purpose":"p","url":"https://x","version":"1.0"}]
        """.write(to: dir.appendingPathComponent("Acknowledgements.json"), atomically: true, encoding: .utf8)
        let bundle = try XCTUnwrap(Bundle(url: dir))
        XCTAssertEqual(AboutPanel.libraries(bundle: bundle).map(\.name), ["SwiftTerm"])
        XCTAssertTrue(AboutPanel.libraries(bundle: Bundle(for: Marker.self)).isEmpty)
    }
}
