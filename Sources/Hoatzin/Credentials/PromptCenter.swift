import AppKit
import Observation
import HoatzinCore

struct PasswordPrompt {
    var title: String
    var message: String?
    var key: CredentialKey
    /// When false the username is shown but locked (e.g. ssh already started with it).
    var usernameEditable: Bool = true
    var saveByDefault: Bool = true
    var isRetry: Bool = false
    var secretLabel: String = String(localized: "Password")
}

struct PasswordAnswer {
    var username: String
    var password: String
    var save: Bool
}

struct ConfirmPrompt {
    var title: String
    var message: String
    var detail: String? = nil
    var confirmTitle: String = String(localized: "Continue")
    var cancelTitle: String = String(localized: "Cancel")
    var destructive: Bool = false
    /// Optional checkbox shown above the buttons (e.g. "Don't ask again for 15 minutes").
    var optionTitle: String? = nil
    /// For questions an AI app triggers: the sheet can appear while the user types elsewhere,
    /// so Return doesn't confirm and the confirm button works only after a second.
    var guardsAgainstStrayKeys: Bool = false
}

struct TextPrompt {
    var title: String
    var message: String
    var placeholder: String = ""
    var secure: Bool = true
}

enum PromptContent {
    case password(PasswordPrompt)
    case confirm(ConfirmPrompt)
    case text(TextPrompt)
}

enum PromptResponse {
    case cancelled
    case password(PasswordAnswer)
    case confirmed(Bool)
    /// Answer to a `ConfirmPrompt` with an `optionTitle`.
    case confirmedWithOption(Bool, option: Bool)
    case text(String)
}

/// Serialises every interactive question (passwords, host keys, certificates, OTP codes)
/// into one queue that the main window presents as sheets, one at a time.
@MainActor
@Observable
final class PromptCenter {
    struct Pending: Identifiable {
        let id = UUID()
        let owner: UUID?
        let content: PromptContent
        let complete: (PromptResponse) -> Void
    }

    private(set) var queue: [Pending] = []

    var current: Pending? { queue.first }

    func ask(_ content: PromptContent, owner: UUID? = nil) async -> PromptResponse {
        NSApp?.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in
            queue.append(Pending(owner: owner, content: content) { continuation.resume(returning: $0) })
        }
    }

    func respond(_ id: UUID, _ response: PromptResponse) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let pending = queue.remove(at: index)
        pending.complete(response)
    }

    /// Cancels open questions of a session that went away (e.g. ssh exited).
    func cancelAll(owner: UUID) {
        let mine = queue.filter { $0.owner == owner }
        queue.removeAll { $0.owner == owner }
        mine.forEach { $0.complete(.cancelled) }
    }

    // MARK: Convenience

    func askPassword(_ prompt: PasswordPrompt, owner: UUID? = nil) async -> PasswordAnswer? {
        if case .password(let answer) = await ask(.password(prompt), owner: owner) { return answer }
        return nil
    }

    func confirm(_ prompt: ConfirmPrompt, owner: UUID? = nil) async -> Bool {
        await confirmWithOption(prompt, owner: owner).confirmed
    }

    /// Like `confirm`, also returning whether the prompt's checkbox was ticked.
    func confirmWithOption(_ prompt: ConfirmPrompt, owner: UUID? = nil) async -> (confirmed: Bool, option: Bool) {
        switch await ask(.confirm(prompt), owner: owner) {
        case .confirmed(let ok): return (ok, false)
        case .confirmedWithOption(let ok, let option): return (ok, ok && option)
        default: return (false, false)
        }
    }

    func askText(_ prompt: TextPrompt, owner: UUID? = nil) async -> String? {
        if case .text(let value) = await ask(.text(prompt), owner: owner) { return value }
        return nil
    }
}
