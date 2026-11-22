import Foundation
import Darwin

/// Runs one command on a host with /usr/bin/ssh, without a terminal (the AI tool `run_command`).
///
/// ssh's questions (password, key passphrase) go through askpass like everywhere else, and
/// the token is bound to this ssh process right after it starts.
enum RemoteCommand {
    struct Result: Sendable {
        /// nil when ssh was stopped by a signal (timeout).
        var exitCode: Int32?
        var stdout = CappedOutput()
        var stderr = CappedOutput()
        var duration: TimeInterval = 0
        var timedOut = false
        var launchError: String?
    }

    /// Keeps the start and the end of a long output, and how much was left out between them.
    struct CappedOutput: Sendable {
        static let headLimit = 16 * 1024
        static let tailLimit = 48 * 1024

        private(set) var head = Data()
        private(set) var tail = Data()
        private(set) var total = 0

        mutating func append(_ data: Data) {
            total += data.count
            var rest = data[...]
            if head.count < Self.headLimit {
                let take = min(Self.headLimit - head.count, rest.count)
                head.append(rest.prefix(take))
                rest = rest.dropFirst(take)
            }
            guard !rest.isEmpty else { return }
            tail.append(rest)
            if tail.count > Self.tailLimit { tail = Data(tail.suffix(Self.tailLimit)) }
        }

        var omitted: Int { total - head.count - tail.count }

        var text: String {
            var result = String(decoding: head, as: UTF8.self)
            if omitted > 0 { result += "\n… \(omitted) bytes left out …\n" }
            result += String(decoding: tail, as: UTF8.self)
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Collects both pipes; written from two reader threads.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var out = CappedOutput()
        private var err = CappedOutput()

        func add(_ data: Data, error: Bool) { lock.withLock { error ? err.append(data) : out.append(data) } }
        var outputs: (CappedOutput, CappedOutput) { lock.withLock { (out, err) } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// Starts `/usr/bin/ssh arguments…` and waits until it exits or `timeout` passes.
    static func run(arguments: [String], timeout: TimeInterval, askpass: @escaping AskpassHandler) async -> Result {
        let token = AskpassServer.shared.register(handler: askpass)
        defer { AskpassServer.shared.unregister(token) }

        var environment = ProcessInfo.processInfo.environment
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        for (key, value) in AskpassServer.shared.environment(token: token) { environment[key] = value }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = Collector()
        let readers = DispatchGroup()
        let timedOut = Flag()
        let started = Date()

        let status: (code: Int32?, error: String?) = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                let code = finished.terminationReason == .exit ? finished.terminationStatus : nil
                continuation.resume(returning: (code, nil))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (nil, error.localizedDescription))
                return
            }
            // ssh needs a network round trip before its first question, so this is in time.
            AskpassServer.shared.bind(token, to: process.processIdentifier)

            for (pipe, isError) in [(stdout, false), (stderr, true)] {
                readers.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    // Using `pipe` here keeps it (and its descriptor) open until reading ends.
                    let fd = pipe.fileHandleForReading.fileDescriptor
                    var buffer = [UInt8](repeating: 0, count: 65_536)
                    while true {
                        let n = read(fd, &buffer, buffer.count)
                        if n <= 0 { break }
                        collector.add(Data(buffer[0..<n]), error: isError)
                    }
                    readers.leave()
                }
            }

            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.set()
                kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }

        if status.error == nil {
            // Usually the pipes close with ssh. Don't wait long if something else still holds them.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    _ = readers.wait(timeout: .now() + 2)
                    done.resume()
                }
            }
        }
        let (out, err) = collector.outputs
        return Result(exitCode: status.code, stdout: out, stderr: err, duration: Date().timeIntervalSince(started),
                      timedOut: timedOut.isSet, launchError: status.error)
    }
}
