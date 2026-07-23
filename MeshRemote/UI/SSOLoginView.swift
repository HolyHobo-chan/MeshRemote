import SwiftUI
import WebKit

/// Signs a user in through their server's real web login (SSO, OIDC, SAML,
/// local — whatever the server presents), then captures the resulting
/// MeshCentral session cookie so the app can authenticate control.ashx with it.
///
/// Success is detected by probing control.ashx with the captured cookie after
/// each page load — the real authentication is the only version-proof signal.
struct SSOLoginView: View {
    let profile: ServerProfile
    /// Called with the captured cookie header (e.g. "xid=…; xid.sig=…") on success.
    let onSuccess: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var checking = false

    var body: some View {
        NavigationStack {
            ZStack {
                if let url = profile.loginPageURL {
                    SSOWebView(url: url,
                               allowSelfSigned: profile.allowSelfSigned,
                               profile: profile,
                               checking: $checking) { cookie in
                        onSuccess(cookie)
                        dismiss()
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("Invalid Server Address", systemImage: "exclamationmark.triangle")
                }

                if checking {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Signing in…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct SSOWebView: UIViewRepresentable {
    let url: URL
    let allowSelfSigned: Bool
    let profile: ServerProfile
    @Binding var checking: Bool
    let onCapture: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Fresh, isolated session each time — no stale cookies, and it's cleared
        // when this view goes away.
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) { }

    func makeCoordinator() -> Coordinator {
        Coordinator(allowSelfSigned: allowSelfSigned, profile: profile,
                    setChecking: { checking = $0 }, onCapture: onCapture)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let allowSelfSigned: Bool
        private let profile: ServerProfile
        private let setChecking: (Bool) -> Void
        private let onCapture: (String) -> Void
        private var finished = false
        private var probing = false

        init(allowSelfSigned: Bool, profile: ServerProfile,
             setChecking: @escaping (Bool) -> Void, onCapture: @escaping (String) -> Void) {
            self.allowSelfSigned = allowSelfSigned
            self.profile = profile
            self.setChecking = setChecking
            self.onCapture = onCapture
        }

        // Accept the server's self-signed cert when the profile opted in — the
        // same trust rule the rest of the app uses.
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            if allowSelfSigned && challenge.protectionSpace.host == profile.baseURL?.host {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkForLogin(webView)
        }

        /// After each page load, read the session cookies and test them against
        /// control.ashx. On success, hand the cookie header back.
        private func checkForLogin(_ webView: WKWebView) {
            guard !finished, !probing else { return }
            let host = profile.baseURL?.host
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let relevant = cookies.filter { host == nil || $0.domain.contains(host!) || host!.contains($0.domain) }
                // Need at least the MeshCentral session cookie to bother probing.
                guard relevant.contains(where: { $0.name == "xid" }) else { return }
                let header = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

                self.probing = true
                self.setChecking(true)
                Task { @MainActor in
                    let ok = await MeshServerConnection.validateSessionCookie(header, profile: self.profile)
                    self.probing = false
                    if ok && !self.finished {
                        self.finished = true
                        self.setChecking(false)
                        self.onCapture(header)
                    } else {
                        self.setChecking(false)   // not signed in yet; keep the page up
                    }
                }
            }
        }
    }
}
