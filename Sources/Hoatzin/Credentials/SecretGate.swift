import AppKit
import LocalAuthentication

/// Asks for Touch ID (or the Mac password as fallback) before Hoatzin uses a password
/// saved in the Keychain, then stays unlocked for a grace period.
///
/// This check is enforced by the app. The Keychain itself still only checks that it is
/// Hoatzin reading the item. Keychain-enforced biometry would need the data-protection
/// keychain, which requires an Apple-issued signing identity.
@MainActor
final class SecretGate {
    typealias Authenticator = @MainActor (String) async -> Bool

    static let shared = SecretGate()

    private let authenticate: Authenticator
    private var unlockedUntil: Date?
    private var pending: Task<Bool, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Overrides the preferences (tests).
    var enabledOverride: Bool?
    var graceOverride: TimeInterval?

    init(authenticate: Authenticator? = nil) {
        self.authenticate = authenticate ?? Self.systemAuthentication
    }

    var isEnabled: Bool {
        enabledOverride ?? UserDefaults.standard.bool(forKey: Prefs.requireTouchID)
    }

    var gracePeriod: TimeInterval {
        max(0, graceOverride ?? UserDefaults.standard.double(forKey: Prefs.touchIDGracePeriod))
    }

    var isUnlocked: Bool {
        guard let unlockedUntil else { return false }
        return unlockedUntil > Date()
    }

    /// Returns true if the caller may read saved secrets now.
    /// Concurrent callers share one Touch ID prompt.
    func unlock(reason: String) async -> Bool {
        guard isEnabled else { return true }
        if isUnlocked { return true }
        if let pending { return await pending.value }

        let task = Task { @MainActor in await self.authenticate(reason) }
        pending = task
        let ok = await task.value
        pending = nil
        if ok {
            // A grace period of 0 still lets callers waiting on this prompt through.
            unlockedUntil = Date().addingTimeInterval(gracePeriod)
        }
        return ok
    }

    func lock() {
        unlockedUntil = nil
    }

    /// Locks again when the Mac sleeps, the screen locks or the user session switches.
    func startAutoLock() {
        guard observers.isEmpty else { return }
        let lockNow: @Sendable (Notification) -> Void = { _ in Task { @MainActor in SecretGate.shared.lock() } }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main, using: lockNow))
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockNow))
    }

    private static func systemAuthentication(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        // Touch ID when available, otherwise (e.g. lid closed) the Mac login password.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            NSLog("Hoatzin: device owner authentication unavailable: \(error?.localizedDescription ?? "unknown")")
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
