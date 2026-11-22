import Foundation
import Security

enum CredentialProtocol: String, Sendable {
    case ssh, https

    var secValue: CFString {
        switch self {
        case .ssh: return kSecAttrProtocolSSH
        case .https: return kSecAttrProtocolHTTPS
        }
    }
}

/// Identifies one credential. Non-secret; safe to keep in memory and in the library file.
struct CredentialKey: Hashable, Sendable {
    var server: String
    var account: String
    var proto: CredentialProtocol
    var port: Int

    var display: String { "\(account)@\(server)" }
}

enum KeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return String(localized: "Keychain: \(text)")
        }
    }
}

/// Internet-password items in the user's login keychain.
///
/// Items are stored as `kSecClassInternetPassword` (server / account / protocol / port), the
/// same shape Keychain Access uses for network passwords, so they are easy to find and audit
/// there. Nothing secret is ever written anywhere else by this app.
enum Keychain {
    private static func baseQuery(_ key: CredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: key.server,
            kSecAttrAccount as String: key.account,
            kSecAttrProtocol as String: key.proto.secValue,
        ]
    }

    /// Reads the secret. May show the system "allow access" dialog the first time.
    static func read(_ key: CredentialKey) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    /// Checks for an item by attributes only (never prompts, never reads the secret).
    static func exists(_ key: CredentialKey) -> Bool {
        var query = baseQuery(key)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    static func save(_ key: CredentialKey, secret: String) throws {
        let data = Data(secret.utf8)
        var add = baseQuery(key)
        add[kSecAttrPort as String] = key.port
        add[kSecAttrLabel as String] = "\(key.server) (\(key.account), \(key.proto.rawValue))"
        add[kSecAttrComment as String] = "Saved by Hoatzin"
        add[kSecValueData as String] = data

        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func delete(_ key: CredentialKey) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}
