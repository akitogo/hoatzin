import AppKit
import Observation
import WebKit
import HoatzinCore

/// A Proxmox console (xterm.js shell / noVNC screen) in a tab.
/// Uses an in-memory web data store; the auth ticket only lives there and in RAM.
@MainActor
@Observable
final class ConsoleSession: Identifiable {
    let id = UUID()
    let serverID: UUID
    let kind: ConsoleKind
    let node: String
    let vmid: Int?
    let guestName: String?
    var title: String
    var isLoading = false
    var error: String?

    @ObservationIgnored private let runtime: ProxmoxRuntime
    @ObservationIgnored private var navigationDelegate: Navigation?
    @ObservationIgnored private(set) lazy var webView: WKWebView = makeWebView()

    init(serverID: UUID, kind: ConsoleKind, node: String, vmid: Int?, guestName: String?, title: String, runtime: ProxmoxRuntime) {
        self.serverID = serverID
        self.kind = kind
        self.node = node
        self.vmid = vmid
        self.guestName = guestName
        self.title = title
        self.runtime = runtime
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let client = try await runtime.authenticatedClient(serverID)
            guard let ticket = client.ticket else { throw ProxmoxError.notLoggedIn }
            navigationDelegate?.host = client.host
            navigationDelegate?.pinned = client.pinned

            let cookie = HTTPCookie(properties: [
                .name: "PVEAuthCookie",
                .value: ProxmoxClient.formEncode(ticket),
                .domain: client.host,
                .path: "/",
                .secure: "TRUE",
            ])
            if let cookie {
                await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
            let url = runtime.consoleURL(client: client, kind: kind, node: node, vmid: vmid, name: guestName)
            webView.load(URLRequest(url: url))
        } catch is CancellationError {
            error = String(localized: "Login cancelled.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func terminate() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    func focus() {
        webView.window?.makeFirstResponder(webView)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        let delegate = Navigation(owner: self)
        navigationDelegate = delegate
        view.navigationDelegate = delegate
        return view
    }

    private final class Navigation: NSObject, WKNavigationDelegate {
        weak var owner: ConsoleSession?
        var host: String?
        var pinned: String?

        init(owner: ConsoleSession) { self.owner = owner }

        func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust
            else { return (.performDefaultHandling, nil) }
            guard challenge.protectionSpace.host == host else { return (.performDefaultHandling, nil) }
            let result = TLSFingerprint.evaluate(trust, pinned: pinned)
            return result.accepted ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            owner?.error = error.localizedDescription
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            owner?.error = error.localizedDescription
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Keep the tab on the console; open anything else (docs links etc.) in the browser.
            if let url = navigationAction.request.url, navigationAction.targetFrame == nil || (url.host != host && url.scheme?.hasPrefix("http") == true) {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}
