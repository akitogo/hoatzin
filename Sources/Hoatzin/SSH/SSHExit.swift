import Foundation

/// What the end of ssh in a built-in tab means. ssh exits with 255 for its own errors and with
/// the remote shell's status otherwise; its own messages are always in English.
enum SSHExit: Equatable {
    /// Exit code 0: the user logged out (exit, Control-D).
    case clean
    /// A working connection broke: the server restarted, the network went away or the Mac slept.
    case connectionLost
    /// The login or the host key was refused: trying again by itself won't help.
    case refused
    /// Another ssh error, e.g. a host that can't be reached (yet).
    case sshError
    /// The remote shell's own exit code, or ssh was stopped by a signal.
    case remoteExit

    /// ssh's last words when an established connection ends without a logout.
    static let lostPhrases = ["closed by remote host", "broken pipe", "not responding", "connection reset by peer",
                              "read from remote host", "client_loop: send disconnect"]
    /// Errors before a session got in, even where the wording overlaps with the ones above.
    static let notConnectedPhrases = ["connect to host", "kex_exchange_identification", "could not resolve hostname"]
    static let refusedPhrases = ["permission denied", "host key verification failed", "too many authentication failures",
                                 "remote host identification has changed"]

    /// - Parameter lastLines: the end of the tab's text; ssh's message is in its last two lines.
    static func classify(exitCode: Int32?, lastLines: String) -> SSHExit {
        if exitCode == 0 { return .clean }
        guard exitCode == 255 else { return .remoteExit }
        let lines = lastLines.lowercased().split(separator: "\n").suffix(2)
        func says(_ phrases: [String]) -> Bool { lines.contains { line in phrases.contains { line.contains($0) } } }
        if says(refusedPhrases) { return .refused }
        if says(notConnectedPhrases) { return .sshError }
        if says(lostPhrases) { return .connectionLost }
        return .sshError
    }
}

/// What a built-in tab does after ssh ended, including a round of automatic reconnects after a
/// dropped connection: attempts every few seconds until one gets in, the login is refused, or
/// `window` has passed (a server restart usually takes one or two minutes).
struct ReconnectPlan {
    static let window: TimeInterval = 300
    /// An attempt that kept running this long got in; a later drop starts a new round.
    static let connectedAfter: TimeInterval = 20
    /// Seconds an attempt waits for the server, so an unreachable host fails quickly.
    static let connectTimeout = 10

    static func delay(beforeAttempt attempt: Int) -> TimeInterval {
        attempt <= 1 ? 2 : (attempt == 2 ? 5 : 10)
    }

    enum Step: Equatable {
        case closeTab
        case retry(attempt: Int, delay: TimeInterval)
        case gaveUp
        case stay
    }

    /// When the current round ends; nil outside of one.
    private(set) var until: Date?
    private(set) var attempt = 0

    var isActive: Bool { until != nil }

    mutating func cancel() {
        until = nil
        attempt = 0
    }

    mutating func next(after ending: SSHExit, ranFor: TimeInterval, now: Date = Date(),
                       closeOnClean: Bool, autoReconnect: Bool) -> Step {
        if ranFor >= Self.connectedAfter { cancel() }
        if ending == .clean {
            cancel()
            return closeOnClean ? .closeTab : .stay
        }
        guard autoReconnect else { cancel(); return .stay }
        if ending == .connectionLost && until == nil { until = now.addingTimeInterval(Self.window) }
        guard let until else { return .stay }
        guard ending == .connectionLost || ending == .sshError else { cancel(); return .stay }
        guard now < until else { cancel(); return .gaveUp }
        attempt += 1
        return .retry(attempt: attempt, delay: Self.delay(beforeAttempt: attempt))
    }
}
