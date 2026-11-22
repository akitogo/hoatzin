import CryptoKit
import Foundation
import Security

enum ProxmoxError: LocalizedError {
    case untrustedCertificate(fingerprint: String, changed: Bool)
    case authenticationFailed
    case needsTFA(challenge: String)
    case notLoggedIn
    case http(Int, String)
    case invalidResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .untrustedCertificate(let fp, let changed):
            return changed ? String(localized: "The server certificate changed (\(fp)).") : String(localized: "Untrusted server certificate (\(fp)).")
        case .authenticationFailed: return String(localized: "Login failed: wrong user name or password.")
        case .needsTFA: return String(localized: "Two-factor authentication required.")
        case .notLoggedIn: return String(localized: "Session expired.")
        case .http(let code, let message): return "HTTP \(code): \(message)"
        case .invalidResponse: return String(localized: "Unexpected response from Proxmox.")
        case .transport(let message): return message
        }
    }
}

enum TLSFingerprint {
    /// SHA-256 of the leaf certificate, formatted like Proxmox shows it (AA:BB:…).
    static func sha256(of trust: SecTrust) -> String? {
        guard
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Accept system-trusted certificates, or exactly the pinned one.
    static func evaluate(_ trust: SecTrust, pinned: String?) -> (accepted: Bool, fingerprint: String?) {
        let fingerprint = sha256(of: trust)
        if SecTrustEvaluateWithError(trust, nil) { return (true, fingerprint) }
        if let pinned, let fingerprint, pinned.caseInsensitiveCompare(fingerprint) == .orderedSame {
            return (true, fingerprint)
        }
        return (false, fingerprint)
    }
}

/// Minimal Proxmox VE API client (ticket authentication).
final class ProxmoxClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    let host: String
    let port: Int

    private let lock = NSLock()
    private var _pinned: String?
    private var _lastFingerprint: String?
    private var _ticket: String?
    private var _csrf: String?
    private var _user: String?
    private var _issued: Date?
    private var session: URLSession!

    init(host: String, port: Int, pinned: String?) {
        self.host = host
        self.port = port
        self._pinned = pinned
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: State

    var pinned: String? {
        get { lock.withLock { _pinned } }
        set { lock.withLock { _pinned = newValue } }
    }

    var ticket: String? { lock.withLock { _ticket } }
    var user: String? { lock.withLock { _user } }

    /// Tickets live 2 h; renew a bit earlier.
    var hasValidTicket: Bool {
        lock.withLock {
            guard _ticket != nil, let issued = _issued else { return false }
            return Date().timeIntervalSince(issued) < 100 * 60
        }
    }

    func invalidateTicket() {
        lock.withLock { _ticket = nil; _csrf = nil; _issued = nil }
    }

    var hostForURL: String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    var baseURL: URL {
        URL(string: "https://\(hostForURL):\(port)")!
    }

    // MARK: Requests

    /// Opens a TLS connection to surface certificate problems before asking for a password.
    func probe() async throws {
        _ = try await raw("GET", "/api2/json/version", form: nil, authenticated: false, allowUnauthorized: true)
    }

    func login(user: String, password: String) async throws {
        let (status, json) = try await raw("POST", "/api2/json/access/ticket",
                                           form: ["username": user, "password": password],
                                           authenticated: false, allowUnauthorized: true)
        try handleLogin(status: status, json: json)
    }

    /// PVE 7+: second step with the TFA challenge ticket. `response` like "totp:123456".
    func completeTFA(user: String, challenge: String, response: String) async throws {
        let (status, json) = try await raw("POST", "/api2/json/access/ticket",
                                           form: ["username": user, "tfa-challenge": challenge, "password": response],
                                           authenticated: false, allowUnauthorized: true)
        try handleLogin(status: status, json: json)
    }

    private func handleLogin(status: Int, json: Any?) throws {
        guard status == 200,
              let data = (json as? [String: Any])?["data"] as? [String: Any],
              let ticket = data["ticket"] as? String
        else { throw ProxmoxError.authenticationFailed }

        if Self.int(data["NeedTFA"]) == 1 {
            throw ProxmoxError.needsTFA(challenge: ticket)
        }
        lock.withLock {
            _ticket = ticket
            _csrf = data["CSRFPreventionToken"] as? String
            _user = data["username"] as? String
            _issued = Date()
        }
    }

    /// Returns the `data` member of an authenticated API call.
    func get(_ path: String) async throws -> Any? {
        let (status, json) = try await raw("GET", "/api2/json" + path, form: nil, authenticated: true, allowUnauthorized: false)
        guard status == 200 else { throw ProxmoxError.invalidResponse }
        return (json as? [String: Any])?["data"]
    }

    private func raw(_ method: String, _ path: String, form: [String: String]?, authenticated: Bool, allowUnauthorized: Bool) async throws -> (Int, Any?) {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            let (ticket, csrf) = lock.withLock { (_ticket, _csrf) }
            guard let ticket else { throw ProxmoxError.notLoggedIn }
            request.setValue("PVEAuthCookie=\(Self.formEncode(ticket))", forHTTPHeaderField: "Cookie")
            if method != "GET", let csrf { request.setValue(csrf, forHTTPHeaderField: "CSRFPreventionToken") }
        }
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = form.map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }
                .joined(separator: "&").data(using: .utf8)
        }

        lock.withLock { _lastFingerprint = nil }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            let (fingerprint, pinned) = lock.withLock { (_lastFingerprint, _pinned) }
            if let fingerprint, [.cancelled, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                                  .serverCertificateNotYetValid, .serverCertificateHasBadDate, .secureConnectionFailed].contains(error.code) {
                throw ProxmoxError.untrustedCertificate(fingerprint: fingerprint, changed: pinned != nil)
            }
            throw ProxmoxError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw ProxmoxError.invalidResponse }
        let json = try? JSONSerialization.jsonObject(with: data)
        if http.statusCode == 401 {
            if allowUnauthorized { return (401, json) }
            invalidateTicket()
            throw ProxmoxError.notLoggedIn
        }
        if http.statusCode >= 400 && !allowUnauthorized {
            let message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ProxmoxError.http(http.statusCode, http.value(forHTTPHeaderField: "Reason") ?? message)
        }
        return (http.statusCode, json)
    }

    // MARK: URLSessionDelegate

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let result = TLSFingerprint.evaluate(trust, pinned: pinned)
        lock.withLock { _lastFingerprint = result.fingerprint }
        if result.accepted {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: Helpers

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as NSNumber: return v.intValue
        case let v as String: return Int(v)
        default: return nil
        }
    }
}
