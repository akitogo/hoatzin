import Foundation

/// Answers ssh's askpass questions for one ssh process.
///
/// * password prompts → pre-resolved credential, Keychain, or the AutoFill sheet;
///   a repeated prompt means the password was wrong, so the sheet is shown again.
/// * host key confirmation → a sheet showing ssh's fingerprint text.
/// * key passphrases / OTP / anything else → a prompt.
///
/// A password typed or picked via AutoFill is only written to the Keychain once ssh stops
/// asking for it (i.e. it was accepted).
@MainActor
final class SSHAuthAgent {
    let target: SSHTarget
    let owner: UUID
    private let broker: CredentialBroker
    private let prompts: PromptCenter
    private var preResolved: ResolvedCredential?
    private var passwordRequests = 0
    private var passphraseRequests = 0
    private var pendingCommit: Task<Void, Never>?
    /// Answer host-key questions with "no" without asking (commands run by AI apps, where
    /// the hop through a ProxyJump host is not covered by StrictHostKeyChecking=yes).
    private let refusesHostKeys: Bool

    init(target: SSHTarget, owner: UUID, preResolved: ResolvedCredential?, broker: CredentialBroker, prompts: PromptCenter,
         refusesHostKeys: Bool = false) {
        self.target = target
        self.owner = owner
        self.preResolved = preResolved
        self.broker = broker
        self.prompts = prompts
        self.refusesHostKeys = refusesHostKeys
    }

    /// Called when ssh exits; a quick non-zero exit means the password was not accepted.
    func processEnded(exitCode: Int32?, after seconds: TimeInterval) {
        if exitCode != 0 && seconds < 8 {
            pendingCommit?.cancel()
            pendingCommit = nil
        }
        prompts.cancelAll(owner: owner)
    }

    func handle(_ request: AskpassRequest) async -> String? {
        let prompt = request.prompt
        let lower = prompt.lowercased()

        if request.kind == "none" { return "" }

        if request.kind == "confirm" || lower.contains("(yes/no") || lower.contains("continue connecting") {
            if refusesHostKeys {
                NSLog("Hoatzin: refused a host key question for \(target.host) (command from an AI app)")
                return request.kind == "confirm" ? nil : "no"
            }
            let ok = await prompts.confirm(ConfirmPrompt(
                title: String(localized: "Verify host — \(target.host)"),
                message: String(localized: "ssh asks you to confirm the identity of \(target.host). Compare the fingerprint before you connect."),
                detail: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                confirmTitle: String(localized: "Connect")
            ), owner: owner)
            if request.kind == "confirm" { return ok ? "" : nil }
            return ok ? "yes" : "no"
        }

        if lower.contains("passphrase") {
            return await passphrase(prompt: prompt)
        }

        if lower.contains("password") {
            return await password(prompt: prompt)
        }

        return await prompts.askText(TextPrompt(
            title: "\(target.displayName) — \(target.host)",
            message: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            secure: !lower.contains("code") && !lower.contains("otp")
        ), owner: owner)
    }

    private func password(prompt: String) async -> String? {
        passwordRequests += 1

        // A second request means the previous password was rejected.
        if passwordRequests > 1 {
            pendingCommit?.cancel()
            pendingCommit = nil
        }

        let credential: ResolvedCredential?
        if passwordRequests == 1, let pre = preResolved {
            credential = pre
        } else {
            credential = await broker.resolve(
                target.credentialKey,
                fallbacks: target.fallbackKey.map { [$0] } ?? [],
                title: String(localized: "SSH — \(target.displayName)"),
                message: passwordRequests > 1
                    ? String(localized: "The server rejected the password for \(target.userAtHost). Pick the right entry or type it.")
                    : String(localized: "No saved password for \(target.credentialKey.display). Pick it from Passwords (AutoFill) or type it."),
                usernameEditable: false,
                owner: owner,
                forcePrompt: passwordRequests > 1,
                isRetry: passwordRequests > 1
            )
        }
        preResolved = nil
        guard let credential else { return nil }

        if credential.shouldSave {
            let broker = self.broker
            pendingCommit = Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                await broker.commit(credential)
            }
        }
        return credential.secret
    }

    private func passphrase(prompt: String) async -> String? {
        var keyPath = (target.identityFile as NSString).expandingTildeInPath
        if let start = prompt.firstIndex(of: "'"), let end = prompt.lastIndex(of: "'"), start < end {
            keyPath = String(prompt[prompt.index(after: start)..<end])
        }
        let key = CredentialKey(server: keyPath.isEmpty ? "ssh-key" : keyPath, account: "passphrase", proto: .ssh, port: 0)
        let credential = await broker.resolve(
            key,
            title: String(localized: "Key passphrase"),
            message: keyPath.isEmpty ? String(localized: "Passphrase for your SSH key.") : String(localized: "Passphrase for \(keyPath)."),
            usernameEditable: false,
            secretLabel: String(localized: "Passphrase"),
            owner: owner,
            forcePrompt: passphraseRequests > 0,
            isRetry: passphraseRequests > 0
        )
        passphraseRequests += 1
        guard let credential else { return nil }
        await broker.commit(credential)
        return credential.secret
    }
}
