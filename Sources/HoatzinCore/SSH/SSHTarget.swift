import Foundation

/// Everything needed to start one ssh connection. Contains no secrets.
public struct SSHTarget: Hashable {
    public var displayName: String
    public var host: String
    public var port: Int = 22
    public var username: String
    public var auth: SSHAuthMode = .password
    public var identityFile: String = ""
    public var keychainHost: String = ""
    public var extraArgs: String = ""
    /// Also tried when no Keychain item exists for `credentialKey`
    /// (e.g. the Proxmox root@pam password for SSH to a Proxmox node).
    public var fallbackKey: CredentialKey? = nil

    public init(displayName: String, host: String, port: Int = 22, username: String, auth: SSHAuthMode = .password, identityFile: String = "", keychainHost: String = "", extraArgs: String = "", fallbackKey: CredentialKey? = nil) {
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.identityFile = identityFile
        self.keychainHost = keychainHost
        self.extraArgs = extraArgs
        self.fallbackKey = fallbackKey
    }

    public var credentialKey: CredentialKey {
        let server = keychainHost.trimmingCharacters(in: .whitespaces)
        return CredentialKey(server: server.isEmpty ? host : server, account: username, proto: .ssh, port: port)
    }

    public var userAtHost: String { "\(username)@\(host)" + (port == 22 ? "" : ":\(port)") }

    public var sshArguments: [String] {
        var args = ["-o", "ServerAliveInterval=30"]
        if port != 22 { args += ["-p", String(port)] }
        if !username.isEmpty { args += ["-l", username] }
        let identity = (identityFile as NSString).expandingTildeInPath
        if !identityFile.isEmpty { args += ["-i", identity] }
        args += Self.splitArguments(extraArgs)
        args.append(host)
        return args
    }

    /// Arguments for running one command without a terminal (the AI tool `run_command`).
    ///
    /// ssh keeps the first value it sees for an `-o` option, and the command line comes before
    /// ~/.ssh/config, so neither the config nor the entry's extra arguments can undo these.
    /// `-T` goes after the extra arguments because for flags the last one wins. `--` after the
    /// host stops ssh from reading a command that starts with "-" as options.
    public func commandArguments(_ command: String) -> [String] {
        let hardened = [
            "StrictHostKeyChecking=yes", // never accept a new or changed host key
            "UpdateHostKeys=no",
            "ConnectTimeout=15",
            "ControlMaster=no",          // no background master holding the output open
            "ClearAllForwardings=yes",
            "ForwardAgent=no",
            "ForwardX11=no",
            "PermitLocalCommand=no",
            "LogLevel=ERROR",            // no login banners in the output
        ]
        return hardened.flatMap { ["-o", $0] } + ["-n"] + sshArguments.dropLast() + ["-T", host, "--", command]
    }

    /// Minimal shell-like splitting that honours single and double quotes.
    public static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true
            } else if ch.isWhitespace {
                if hasToken || !current.isEmpty { result.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(ch)
            }
        }
        if hasToken || !current.isEmpty { result.append(current) }
        return result
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
