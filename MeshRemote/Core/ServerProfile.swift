import Foundation

/// A saved MeshCentral server. Passwords live in the Keychain, keyed by profile id.
struct ServerProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var displayName: String = ""
    var host: String = ""            // hostname[:port], no scheme
    var username: String = ""
    var allowSelfSigned: Bool = false
    var urlKey: String = ""          // domain loginkey (?key=), rarely used
    var autoConnect: Bool = false    // connect to this server on app launch

    init() {}

    init(displayName: String, host: String, username: String,
         allowSelfSigned: Bool, urlKey: String = "", autoConnect: Bool = false) {
        self.displayName = displayName
        self.host = host
        self.username = username
        self.allowSelfSigned = allowSelfSigned
        self.urlKey = urlKey
        self.autoConnect = autoConnect
    }

    // Tolerant decoding: profiles saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        allowSelfSigned = try c.decodeIfPresent(Bool.self, forKey: .allowSelfSigned) ?? false
        urlKey = try c.decodeIfPresent(String.self, forKey: .urlKey) ?? ""
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? false
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
        guard let base = baseURL,
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = "wss"
        comps.path = "/" + path
        var items = query
        if !urlKey.isEmpty { items.append(URLQueryItem(name: "key", value: urlKey)) }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url
    }

    var keychainAccount: String { "server-\(id.uuidString)" }

    var password: String? {
        get { KeychainStore.password(account: keychainAccount) }
        nonmutating set {
            if let newValue { KeychainStore.setPassword(newValue, account: keychainAccount) }
            else { KeychainStore.deletePassword(account: keychainAccount) }
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
        var profiles = load()
        profiles.removeAll { $0.id == profile.id }
        save(profiles)
    }
}
