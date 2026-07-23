import Foundation

/// How a saved server signs in.
enum AuthMethod: String, Codable {
    case password   // local account: username + password via x-meshauth
    case sso        // external/SSO account: browser login, session cookie
}

/// A saved MeshCentral server. Passwords/session cookies live in the Keychain, keyed by profile id.
struct ServerProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var displayName: String = ""
    var host: String = ""            // hostname[:port], no scheme
    var username: String = ""
    var allowSelfSigned: Bool = false
    var autoConnect: Bool = false    // connect to this server on app launch
    var authMethod: AuthMethod = .password
    var staySignedIn: Bool = false   // mint & reuse a login token (skips password/2FA re-entry)

    init() {}

    init(displayName: String, host: String, username: String,
         allowSelfSigned: Bool, autoConnect: Bool = false,
         authMethod: AuthMethod = .password) {
        self.displayName = displayName
        self.host = host
        self.username = username
        self.allowSelfSigned = allowSelfSigned
        self.autoConnect = autoConnect
        self.authMethod = authMethod
    }

    // Tolerant decoding: profiles saved before a field existed still load.
    // (urlKey is Keychain-backed, not a Codable field.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        allowSelfSigned = try c.decodeIfPresent(Bool.self, forKey: .allowSelfSigned) ?? false
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? false
        authMethod = try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .password
        staySignedIn = try c.decodeIfPresent(Bool.self, forKey: .staySignedIn) ?? false
    }

    var baseURL: URL? {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "https://", with: "")
        text = text.replacingOccurrences(of: "wss://", with: "")
        if text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        return URL(string: "https://\(text)")
    }

    func websocketURL(path: String, query: [URLQueryItem] = []) -> URL? {
        urlWith(scheme: "wss", path: path, query: query)
    }

    /// HTTPS URL for the given path (e.g. devicefile.ashx), with the domain key applied.
    func httpsURL(path: String, query: [URLQueryItem] = []) -> URL? {
        urlWith(scheme: "https", path: path, query: query)
    }

    /// The domain's web page, including the ?key= access key when the domain
    /// requires one — used for the in-app SSO login.
    var loginPageURL: URL? {
        urlWith(scheme: "https", path: "", query: [])
    }

    private func urlWith(scheme: String, path: String, query: [URLQueryItem]) -> URL? {
        guard let base = baseURL,
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = scheme
        if !path.isEmpty { comps.path = "/" + path }
        var items = query
        if !urlKey.isEmpty { items.append(URLQueryItem(name: "key", value: urlKey)) }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url
    }

    var keychainAccount: String { "server-\(id.uuidString)" }
    private var cookieAccount: String { "cookie-\(id.uuidString)" }
    private var tokenUserAccount: String { "tokuser-\(id.uuidString)" }
    private var tokenPassAccount: String { "tokpass-\(id.uuidString)" }
    private var urlKeyAccount: String { "urlkey-\(id.uuidString)" }

    var password: String? {
        get { KeychainStore.password(account: keychainAccount) }
        nonmutating set {
            if let newValue { KeychainStore.setPassword(newValue, account: keychainAccount) }
            else { KeychainStore.deletePassword(account: keychainAccount) }
        }
    }

    /// The domain access key (?key=) some servers require. It's a semi-secret URL
    /// value, so it lives in the Keychain rather than plain profile storage.
    var urlKey: String {
        get { KeychainStore.password(account: urlKeyAccount) ?? "" }
        nonmutating set {
            if newValue.isEmpty { KeychainStore.deletePassword(account: urlKeyAccount) }
            else { KeychainStore.setPassword(newValue, account: urlKeyAccount) }
        }
    }

    /// The captured MeshCentral session-cookie header for SSO logins
    /// (e.g. "xid=…; xid.sig=…"). Short-lived — used only to bootstrap a login
    /// token. Stored in the Keychain like a password.
    var sessionCookie: String? {
        get { KeychainStore.password(account: cookieAccount) }
        nonmutating set {
            if let newValue { KeychainStore.setPassword(newValue, account: cookieAccount) }
            else { KeychainStore.deletePassword(account: cookieAccount) }
        }
    }

    /// A durable MeshCentral login token (username `~t:…` + password) minted after
    /// an SSO sign-in, so the app doesn't have to prompt again. Revocable from the
    /// MeshCentral web UI. The two halves are stored as separate Keychain items.
    var loginToken: (user: String, pass: String)? {
        get {
            guard let user = KeychainStore.password(account: tokenUserAccount),
                  let pass = KeychainStore.password(account: tokenPassAccount) else { return nil }
            return (user, pass)
        }
        nonmutating set {
            if let newValue {
                KeychainStore.setPassword(newValue.user, account: tokenUserAccount)
                KeychainStore.setPassword(newValue.pass, account: tokenPassAccount)
            } else {
                KeychainStore.deletePassword(account: tokenUserAccount)
                KeychainStore.deletePassword(account: tokenPassAccount)
            }
        }
    }
}

/// Persists server profiles in UserDefaults (passwords stay in Keychain).
@MainActor
final class ProfileStore {
    private static let key = "meshremote.serverProfiles"

    static func load() -> [ServerProfile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let profiles = try? JSONDecoder().decode([ServerProfile].self, from: data) else { return [] }
        return profiles
    }

    static func save(_ profiles: [ServerProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func delete(_ profile: ServerProfile) {
        KeychainStore.deletePassword(account: profile.keychainAccount)
        profile.sessionCookie = nil
        profile.loginToken = nil   // clears both token Keychain items
        profile.urlKey = ""        // clears the Keychain-stored login key
        var profiles = load()
        profiles.removeAll { $0.id == profile.id }
        save(profiles)
    }
}
