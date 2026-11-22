import AppKit

enum TerminalChoice: String, CaseIterable, Identifiable {
    case iterm, terminal, builtin

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iterm: return "iTerm2"
        case .terminal: return "Terminal"
        case .builtin: return String(localized: "Built-in tab")
        }
    }

    /// "Connect in …" as one phrase, since word order and case differ between languages.
    var connectInTitle: String {
        switch self {
        case .iterm: return String(localized: "Connect in iTerm2")
        case .terminal: return String(localized: "Connect in Terminal")
        case .builtin: return String(localized: "Connect in Built-in tab")
        }
    }

    var bundleID: String? {
        switch self {
        case .iterm: return "com.googlecode.iterm2"
        case .terminal: return "com.apple.Terminal"
        case .builtin: return nil
        }
    }

    var isInstalled: Bool {
        guard let bundleID else { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

/// Where a long address in the sidebar is shortened. At the start keeps the part that tells
/// hosts apart (…30.20); at the end keeps the network (10.20.3…).
enum AddressTruncation: String, CaseIterable, Identifiable {
    case start, end

    var id: String { rawValue }

    var label: String {
        switch self {
        case .start: return String(localized: "At the start (…30.20)")
        case .end: return String(localized: "At the end (10.20.3…)")
        }
    }

    var lineBreakMode: NSLineBreakMode { self == .start ? .byTruncatingHead : .byTruncatingTail }
}

/// UserDefaults keys (non-sensitive preferences only).
enum Prefs {
    static let sshOpenIn = "sshOpenIn"
    static let itermNewTab = "itermNewTab"
    static let terminalFontSize = "terminalFontSize"
    static let savePasswordsByDefault = "savePasswordsByDefault"
    static let defaultSSHUser = "defaultSSHUser"
    static let defaultSSHAuth = "defaultSSHAuth"
    static let defaultSSHKeyFile = "defaultSSHKeyFile"
    static let requireTouchID = "requireTouchID"
    static let touchIDGracePeriod = "touchIDGracePeriod"
    /// AIAccess raw value: off / read / open / commands.
    static let aiAccess = "aiAccess"
    static let aiReadOutput = "aiReadOutput"
    /// CommandActionPolicy raw value for the Run Command action (Shortcuts, Siri): off / ask / always.
    static let runCommandAction = "runCommandAction"
    static let spotlightConnections = "spotlightConnections"
    /// AddressTruncation raw value: where long addresses in the sidebar are shortened.
    static let addressTruncation = "addressTruncation"

    /// Every setting the user can change (also what the move from RemoteDeck copies).
    static let all = [sshOpenIn, itermNewTab, terminalFontSize, savePasswordsByDefault, defaultSSHUser, defaultSSHAuth,
                      defaultSSHKeyFile, requireTouchID, touchIDGracePeriod, aiAccess, aiReadOutput, runCommandAction,
                      spotlightConnections, addressTruncation, "sidebarCollapsed"]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            sshOpenIn: TerminalChoice.iterm.isInstalled ? TerminalChoice.iterm.rawValue : TerminalChoice.builtin.rawValue,
            itermNewTab: true,
            terminalFontSize: 13.0,
            savePasswordsByDefault: true,
            defaultSSHUser: "root",
            defaultSSHAuth: SSHAuthMode.password.rawValue,
            defaultSSHKeyFile: "",
            requireTouchID: true,
            touchIDGracePeriod: 300.0,
            aiAccess: "off",
            aiReadOutput: true,
            runCommandAction: "ask",
            spotlightConnections: true,
            addressTruncation: AddressTruncation.start.rawValue,
        ])
    }

    /// App-wide defaults for new SSH connections and Proxmox guests.
    static var sshDefaults: (user: String, auth: SSHAuthMode, keyFile: String) {
        let d = UserDefaults.standard
        let user = d.string(forKey: defaultSSHUser)?.trimmingCharacters(in: .whitespaces) ?? ""
        return (user.isEmpty ? "root" : user,
                SSHAuthMode(rawValue: d.string(forKey: defaultSSHAuth) ?? "") ?? .password,
                d.string(forKey: defaultSSHKeyFile) ?? "")
    }

    static var preferredTerminal: TerminalChoice {
        let choice = TerminalChoice(rawValue: UserDefaults.standard.string(forKey: sshOpenIn) ?? "") ?? .builtin
        return choice.isInstalled ? choice : .builtin
    }
}
