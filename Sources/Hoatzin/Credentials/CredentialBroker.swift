import Foundation

struct ResolvedCredential: Sendable {
    var key: CredentialKey
    var secret: String
    var fromKeychain: Bool
    var shouldSave: Bool
}

/// Finds the secret for a connection:
///  1. the Keychain item filed under (server, account, protocol), if present, after a
///     Touch ID check (see `SecretGate`);
///  2. otherwise a sheet with AutoFill-enabled fields, so the password can be picked from
///     the Passwords app (Touch ID) without ever being typed — optionally saved to the
///     Keychain for next time.
@MainActor
final class CredentialBroker {
    nonisolated static let saveByDefaultKey = "savePasswordsByDefault"

    let prompts: PromptCenter
    let gate: SecretGate
    var onError: ((String) -> Void)?

    init(prompts: PromptCenter, gate: SecretGate? = nil) {
        self.prompts = prompts
        self.gate = gate ?? .shared
    }

    var saveByDefault: Bool {
        UserDefaults.standard.object(forKey: Self.saveByDefaultKey) as? Bool ?? true
    }

    func resolve(
        _ key: CredentialKey,
        fallbacks: [CredentialKey] = [],
        title: String,
        message: String? = nil,
        usernameEditable: Bool = true,
        secretLabel: String = "Password",
        owner: UUID? = nil,
        forcePrompt: Bool = false,
        isRetry: Bool = false
    ) async -> ResolvedCredential? {
        if !forcePrompt {
            for candidate in [key] + fallbacks where await Self.hasKeychainItem(candidate) {
                // Touch ID first; cancelling it cancels the connection.
                guard await gate.unlock(reason: String(localized: "use the saved password for \(candidate.display)")) else { return nil }
                if let secret = await Self.readKeychain(candidate) {
                    return ResolvedCredential(key: key, secret: secret, fromKeychain: true, shouldSave: false)
                }
            }
        }
        let prompt = PasswordPrompt(
            title: title,
            message: message,
            key: key,
            usernameEditable: usernameEditable,
            saveByDefault: saveByDefault,
            isRetry: isRetry,
            secretLabel: secretLabel
        )
        guard let answer = await prompts.askPassword(prompt, owner: owner) else { return nil }
        var resolvedKey = key
        let username = answer.username.trimmingCharacters(in: .whitespaces)
        if usernameEditable, !username.isEmpty { resolvedKey.account = username }
        return ResolvedCredential(key: resolvedKey, secret: answer.password, fromKeychain: false, shouldSave: answer.save)
    }

    /// Persists a credential the user chose to remember.
    func commit(_ credential: ResolvedCredential) async {
        guard credential.shouldSave else { return }
        let key = credential.key
        let secret = credential.secret
        let error: String? = await Task.detached {
            do { try Keychain.save(key, secret: secret); return nil } catch { return error.localizedDescription }
        }.value
        if let error { onError?(error) }
    }

    func forget(_ key: CredentialKey) async {
        let error: String? = await Task.detached {
            do { try Keychain.delete(key); return nil } catch { return error.localizedDescription }
        }.value
        if let error { onError?(error) }
    }

    func store(_ key: CredentialKey, secret: String) async {
        await commit(ResolvedCredential(key: key, secret: secret, fromKeychain: false, shouldSave: true))
    }

    static func readKeychain(_ key: CredentialKey) async -> String? {
        await Task.detached { try? Keychain.read(key) }.value
    }

    static func hasKeychainItem(_ key: CredentialKey) async -> Bool {
        await Task.detached { Keychain.exists(key) }.value
    }
}
