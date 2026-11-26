import AppKit
import Observation
import SwiftTerm
import HoatzinCore

/// A key typed after text by the AI tool `send_input`.
enum TerminalKey: String, CaseIterable {
    case enter, tab, escape, ctrlC = "ctrl-c", ctrlD = "ctrl-d", ctrlZ = "ctrl-z", up, down, left, right, none

    var label: String {
        switch self {
        case .enter: return String(localized: "Return")
        case .tab: return String(localized: "Tab")
        case .escape: return String(localized: "Esc")
        case .ctrlC: return String(localized: "Control-C")
        case .ctrlD: return String(localized: "Control-D")
        case .ctrlZ: return String(localized: "Control-Z")
        case .up: return String(localized: "Up Arrow")
        case .down: return String(localized: "Down Arrow")
        case .left: return String(localized: "Left Arrow")
        case .right: return String(localized: "Right Arrow")
        case .none: return String(localized: "no key")
        }
    }
}

/// When a terminal last received output. Written on SwiftTerm's I/O thread.
final class OutputClock: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var last = Date.distantPast

    func tick() { lock.withLock { count += 1; last = Date() } }

    /// Number of output batches so far, and when the last one arrived.
    var snapshot: (count: Int, last: Date) { lock.withLock { (count, last) } }
}

/// An ssh process running in an embedded terminal tab.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    enum State: Equatable {
        case idle, running, exited(Int32?)
    }

    let id = UUID()
    let target: SSHTarget
    var title: String
    private(set) var state: State = .idle

    @ObservationIgnored private let broker: CredentialBroker
    @ObservationIgnored private let prompts: PromptCenter
    @ObservationIgnored private var preResolved: ResolvedCredential?
    @ObservationIgnored private var agent: SSHAuthAgent?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var delegateBridge: Bridge?
    @ObservationIgnored private var plan = ReconnectPlan()
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    /// Closes this tab; set by the app, used after a clean logout.
    @ObservationIgnored var onCleanExit: (() -> Void)?
    /// When the next automatic reconnect starts; nil while none is waiting.
    private(set) var reconnectAt: Date?
    @ObservationIgnored let output = OutputClock()
    @ObservationIgnored private(set) lazy var terminalView: LocalProcessTerminalView = makeView()
    /// The terminal inside a small margin, like other terminal apps.
    @ObservationIgnored private(set) lazy var containerView: NSView = makeContainer()

    static let background = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)

    init(target: SSHTarget, preResolved: ResolvedCredential?, broker: CredentialBroker, prompts: PromptCenter) {
        self.target = target
        self.title = target.displayName
        self.preResolved = preResolved
        self.broker = broker
        self.prompts = prompts
    }

    var isRunning: Bool { state == .running }

    func start() {
        guard state != .running else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAt = nil
        let agent = SSHAuthAgent(target: target, owner: id, preResolved: preResolved, broker: broker, prompts: prompts)
        preResolved = nil
        self.agent = agent
        let token = AskpassServer.shared.register { request in await agent.handle(request) }
        self.token = token

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (key, value) in AskpassServer.shared.environment(token: token) { env[key] = value }

        let view = terminalView
        if state != .idle { note(String(localized: "reconnecting to \(target.userAtHost)")) }
        startedAt = Date()
        state = .running
        // While reconnecting, a host that's still down should fail fast instead of after a minute.
        let retrying = plan.isActive ? ["-o", "ConnectTimeout=\(ReconnectPlan.connectTimeout)"] : []
        view.startProcess(
            executable: "/usr/bin/ssh",
            args: retrying + target.sshArguments,
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: "ssh"
        )
        // Only this ssh (and its ProxyJump children) may use the token. startProcess has
        // forked synchronously; ssh needs a network round trip before its first prompt.
        if let pid = view.process?.shellPid, pid > 0 {
            AskpassServer.shared.bind(token, to: pid)
        }
    }

    func terminate() {
        isClosed = true
        cancelReconnect()
        if state == .running { terminalView.terminate() }
        cleanup(exitCode: nil)
    }

    /// Stops a round of automatic reconnects; the tab stays as it is.
    func stopReconnecting() {
        guard plan.isActive || reconnectAt != nil else { return }
        cancelReconnect()
        note(String(localized: "stopped reconnecting"))
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAt = nil
        plan.cancel()
    }

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    /// Types `text` into the running ssh as if from the keyboard, then presses `key`.
    /// Line breaks are sent as Return.
    func type(_ text: String, then key: TerminalKey) {
        let view = terminalView
        let typed = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if !typed.isEmpty { view.send(txt: typed) }
        switch key {
        case .enter: view.send(txt: "\r")
        case .tab: view.send(txt: "\t")
        case .escape: view.send([0x1B])
        case .ctrlC: view.send([0x03])
        case .ctrlD: view.send([0x04])
        case .ctrlZ: view.send([0x1A])
        case .up: view.sendKeyUp()
        case .down: view.sendKeyDown()
        case .left: view.sendKeyLeft()
        case .right: view.sendKeyRight()
        case .none: break
        }
    }

    func applyFontSize(_ size: Double) {
        terminalView.font = NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    fileprivate func processEnded(exitCode: Int32?) {
        let ranFor = Date().timeIntervalSince(startedAt)
        cleanup(exitCode: exitCode)
        state = .exited(exitCode)
        guard !isClosed else { return }

        // ssh's own message is in the last lines, before anything is added below.
        let ending = SSHExit.classify(exitCode: exitCode, lastLines: AIBridge.lastLines(of: terminalView.getBufferAsData(), count: 2))
        let defaults = UserDefaults.standard
        let step = plan.next(after: ending, ranFor: ranFor,
                             closeOnClean: defaults.bool(forKey: Prefs.closeTabOnCleanExit) && onCleanExit != nil,
                             autoReconnect: defaults.bool(forKey: Prefs.autoReconnect))
        let code = Int(exitCode ?? -1)
        switch step {
        case .closeTab:
            onCleanExit?()
        case .retry(let attempt, let delay):
            note(attempt == 1
                 ? String(localized: "connection lost (exit \(code)), reconnecting in \(Int(delay)) s")
                 : String(localized: "trying again in \(Int(delay)) s"))
            scheduleReconnect(after: delay)
        case .gaveUp:
            note(String(localized: "connection closed (exit \(code)), stopped reconnecting after 5 minutes"))
        case .stay:
            note(exitCode.map { String(localized: "connection closed (exit \(Int($0)))") } ?? String(localized: "connection closed"))
        }
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        reconnectAt = Date().addingTimeInterval(delay)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.reconnectAt != nil, !self.isClosed else { return }
            self.start()
        }
    }

    /// A dimmed line from Hoatzin in the terminal, between ssh's output.
    private func note(_ text: String) {
        terminalView.feed(text: "\r\n\u{1B}[2m— \(text) —\u{1B}[0m\r\n")
    }

    private func cleanup(exitCode: Int32?) {
        agent?.processEnded(exitCode: exitCode, after: Date().timeIntervalSince(startedAt))
        if let token { AskpassServer.shared.unregister(token) }
        token = nil
        agent = nil
        prompts.cancelAll(owner: id)
    }

    private func makeView() -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let size = UserDefaults.standard.double(forKey: Prefs.terminalFontSize)
        view.font = NSFont.monospacedSystemFont(ofSize: CGFloat(size > 0 ? size : 13), weight: .regular)
        view.nativeBackgroundColor = Self.background
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        view.caretColor = .systemTeal
        view.optionAsMetaKey = false
        let bridge = Bridge(owner: self)
        delegateBridge = bridge
        view.processDelegate = bridge
        let clock = output
        view.setProcessOutputHandler { clock.tick() }
        return view
    }

    private func makeContainer() -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Self.background.cgColor
        let terminal = terminalView
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            terminal.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        return container
    }

    private final class Bridge: LocalProcessTerminalViewDelegate {
        weak var owner: TerminalSession?

        init(owner: TerminalSession) { self.owner = owner }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            guard let owner, !title.isEmpty else { return }
            owner.title = "\(owner.target.displayName) — \(title)"
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            owner?.processEnded(exitCode: exitCode)
        }
    }
}
