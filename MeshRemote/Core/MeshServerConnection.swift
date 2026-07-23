import Foundation
import Observation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

enum MeshError: Error, LocalizedError {
    case badServerAddress
    case authFailed(String)
    case twoFactorRequired
    case notConnected
    case timeout(String)
    case relayFailed(String)

    var errorDescription: String? {
        switch self {
        case .badServerAddress: return "Invalid server address."
        case .authFailed(let m): return m
        case .twoFactorRequired: return "This account requires a two-factor code."
        case .notConnected: return "Not connected to the server."
        case .timeout(let what): return "Timed out waiting for \(what)."
        case .relayFailed(let m): return m
        }
    }
}

/// The MeshCentral control channel: wss://server/control.ashx speaking JSON frames.
/// Owns login, the device list, realtime events, relay cookies and tunnel setup.
@Observable
@MainActor
final class MeshServerConnection {
    let profile: ServerProfile

    private(set) var state: ConnectionState = .disconnected
    private(set) var serverInfo: ServerInfo?
    private(set) var userInfo: UserInfo?
    private(set) var meshes: [Mesh] = []
    private(set) var nodes: [String: MeshNode] = [:]   // by node id
    private(set) var lastError: String?

    private var socket: MeshWebSocket?
    private var receiveTask: Task<Void, Never>?
    private var cookieRefreshTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    // Relay cookies minted by {action:'authcookie'}.
    private var authCookie: String?
    private var rCookie: String?
    // Coalesces concurrent cookie fetches so two tunnels opening at once share
    // one request instead of racing (and stranding) separate continuations.
    private var cookieFetch: Task<(auth: String, rauth: String), Error>?

    // Awaits a createLoginToken response.
    private var tokenWaiter: CheckedContinuation<(user: String, pass: String)?, Never>?

    init(profile: ServerProfile) {
        self.profile = profile
    }

    // MARK: - Connect / disconnect

    /// Local-account login: username + password (+ optional 2FA token) via x-meshauth.
    func connect(password: String, token: String? = nil) async throws {
        var authValue = "\(Data(profile.username.utf8).base64EncodedString()),\(Data(password.utf8).base64EncodedString())"
        if let token, !token.isEmpty {
            authValue += ",\(Data(token.utf8).base64EncodedString())"
        }
        try await connect(authHeaders: ["x-meshauth": authValue])
    }

    /// External/SSO login: authenticate with a captured MeshCentral session
    /// cookie (e.g. "xid=…; xid.sig=…"). control.ashx accepts the session cookie
    /// directly, so no password is involved. Short-lived — used to bootstrap a token.
    func connect(sessionCookie: String) async throws {
        try await connect(authHeaders: ["Cookie": sessionCookie])
    }

    /// Durable login-token auth: a `~t:…` token username + its password, sent the
    /// same way as a normal login. Survives SSO session expiry.
    func connect(tokenUser: String, tokenPass: String) async throws {
        let authValue = "\(Data(tokenUser.utf8).base64EncodedString()),\(Data(tokenPass.utf8).base64EncodedString())"
        try await connect(authHeaders: ["x-meshauth": authValue])
    }

    /// Returns true if the given session cookie authenticates against
    /// control.ashx. Used by the SSO web-login flow to detect when the user has
    /// finished signing in (the real auth is the only reliable success signal).
    static func validateSessionCookie(_ cookie: String, profile: ServerProfile) async -> Bool {
        guard let url = profile.websocketURL(path: "control.ashx") else { return false }
        let socket = MeshWebSocket(url: url, headers: ["Cookie": cookie],
                                   allowSelfSigned: profile.allowSelfSigned)
        defer { socket.close() }
        do {
            try await socket.connect()
            let watchdog = Task { try? await Task.sleep(for: .seconds(8)); socket.close() }
            defer { watchdog.cancel() }
            while true {
                let message = try await socket.receive()
                guard case .text(let text) = message, let json = parseJSON(text) else { continue }
                switch json["action"] as? String {
                case "userinfo": return true      // authenticated
                case "close": return false        // rejected (not signed in yet)
                default: continue
                }
            }
        } catch {
            return false
        }
    }

    private func connect(authHeaders: [String: String]) async throws {
        guard state != .connecting else { return }
        guard let url = profile.websocketURL(path: "control.ashx") else {
            throw MeshError.badServerAddress
        }
        state = .connecting
        lastError = nil

        let socket = MeshWebSocket(url: url,
                                   headers: authHeaders,
                                   allowSelfSigned: profile.allowSelfSigned)
        self.socket = socket

        do {
            try await socket.connect()
            // The server pushes serverinfo then userinfo on success, or a close message.
            try await waitForLogin(socket: socket)
        } catch {
            self.socket = nil
            let message = friendlyMessage(for: error)
            state = .failed(message)
            throw error
        }

        state = .connected
        startReceiveLoop(socket: socket)
        startCookieRefresh()
        startHeartbeat()

        try? await sendJSON(["action": "meshes"])
        try? await sendJSON(["action": "nodes"])
        try? await sendJSON(["action": "authcookie"])
    }

    /// Called when the app returns to the foreground. iOS may have torn down the
    /// socket while suspended (leaving it half-open) and the relay cookies may be
    /// past the server's ~60-minute lifetime. Re-mint cookies and probe the
    /// control channel; if the probe fails, surface the dead connection instead
    /// of showing stale "online" devices forever.
    func refreshAfterForeground() async {
        guard state == .connected else { return }
        invalidateCookies()
        do {
            try await sendJSON(["action": "authcookie"])
            try await sendJSON(["action": "nodes"])
        } catch {
            markConnectionLost()
        }
    }

    /// Reads frames until userinfo arrives (login complete) or a close message / error.
    private func waitForLogin(socket: MeshWebSocket) async throws {
        let watchdog = Task {
            try await Task.sleep(for: .seconds(15))
            socket.close()
        }
        defer { watchdog.cancel() }
        while true {
            let message = try await socket.receive()
            guard case .text(let text) = message,
                  let json = Self.parseJSON(text) else { continue }
            let action = json["action"] as? String
            switch action {
            case "serverinfo":
                if let info = json["serverinfo"] as? [String: Any] {
                    serverInfo = ServerInfo(json: info)
                }
            case "userinfo":
                if let info = json["userinfo"] as? [String: Any] {
                    userInfo = UserInfo(json: info)
                }
                return
            case "close":
                throw closeError(json)
            default:
                continue
            }
        }
    }

    private func closeError(_ json: [String: Any]) -> MeshError {
        let cause = json["cause"] as? String ?? ""
        let msg = json["msg"] as? String ?? ""
        switch (cause, msg) {
        case (_, "tokenrequired"): return .twoFactorRequired
        case ("noauth", "nokey"): return .authFailed("This server requires a URL access key. Add it in the server settings.")
        case ("banned", _): return .authFailed("Too many attempts — this IP is temporarily banned by the server.")
        case ("notools", _): return .authFailed("This account is not permitted to use API clients.")
        case ("emailvalidation", _): return .authFailed("Verify the account email address before logging in.")
        default: return .authFailed("Invalid username or password.")
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        if let meshError = error as? MeshError { return meshError.localizedDescription }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot:
                return "The server's certificate isn't trusted. Enable “Allow self-signed certificate” if this server uses one."
            case NSURLErrorCannotFindHost: return "Server not found — check the address."
            case NSURLErrorCannotConnectToHost: return "Could not reach the server."
            case NSURLErrorTimedOut: return "Connection timed out."
            case NSURLErrorNotConnectedToInternet: return "No network connection."
            default: break
            }
        }
        return error.localizedDescription
    }

    func disconnect() {
        cleanup()
        state = .disconnected
    }

    private func cleanup() {
        receiveTask?.cancel()
        cookieRefreshTask?.cancel()
        heartbeatTask?.cancel()
        cookieFetch?.cancel()
        receiveTask = nil
        cookieRefreshTask = nil
        heartbeatTask = nil
        invalidateCookies()
        if let waiter = tokenWaiter { tokenWaiter = nil; waiter.resume(returning: nil) }
        socket?.close()
        socket = nil
    }

    private func invalidateCookies() {
        authCookie = nil
        rCookie = nil
        cookieFetch = nil
    }

    /// Transition to a lost-connection state exactly once, tearing down tasks.
    private func markConnectionLost() {
        guard state == .connected else { return }
        cleanup()
        state = .failed("Connection to the server was lost.")
    }

    // MARK: - Receive loop

    private func startReceiveLoop(socket: MeshWebSocket) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard case .text(let text) = message else { continue }
                    guard let json = Self.parseJSON(text) else { continue }
                    await self?.handle(json)
                } catch {
                    await MainActor.run { [weak self] in self?.markConnectionLost() }
                    return
                }
            }
        }
    }

    nonisolated static func parseJSON(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func handle(_ json: [String: Any]) {
        guard let action = json["action"] as? String else { return }

        switch action {
        case "ping":
            Task { try? await sendJSON(["action": "pong"]) }
        case "meshes":
            if let list = json["meshes"] as? [[String: Any]] {
                meshes = list.compactMap { Mesh(json: $0) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        case "nodes":
            if let grouped = json["nodes"] as? [String: [[String: Any]]] {
                var updated: [String: MeshNode] = [:]
                for (meshId, list) in grouped {
                    for item in list {
                        if let node = MeshNode(json: item, meshId: meshId) {
                            updated[node.id] = node
                        }
                    }
                }
                nodes = updated
            }
        case "authcookie":
            authCookie = json["cookie"] as? String
            rCookie = json["rcookie"] as? String
        case "createLoginToken":
            if let waiter = tokenWaiter {
                tokenWaiter = nil
                if let user = json["tokenUser"] as? String, let pass = json["tokenPass"] as? String {
                    waiter.resume(returning: (user, pass))
                } else {
                    waiter.resume(returning: nil)   // server refused (result: error)
                }
            }
        case "event":
            if let event = json["event"] as? [String: Any] {
                handleEvent(event)
            }
        case "close":
            let err = closeError(json)
            state = .failed(err.localizedDescription)
        default:
            break
        }
    }

    private func handleEvent(_ event: [String: Any]) {
        guard let action = event["action"] as? String else { return }
        switch action {
        case "nodeconnect":
            guard let nodeId = event["nodeid"] as? String, var node = nodes[nodeId] else { return }
            node.conn = event["conn"] as? Int ?? 0
            node.pwr = event["pwr"] as? Int ?? 0
            nodes[nodeId] = node
        case "changenode":
            guard let nodeJson = event["node"] as? [String: Any],
                  let nodeId = nodeJson["_id"] as? String else { return }
            if var node = nodes[nodeId] {
                node.merge(json: nodeJson)
                nodes[nodeId] = node
            }
        case "addnode":
            guard let nodeJson = event["node"] as? [String: Any],
                  let meshId = event["meshid"] as? String ?? nodeJson["meshid"] as? String,
                  let node = MeshNode(json: nodeJson, meshId: meshId) else { return }
            nodes[node.id] = node
        case "removenode":
            if let nodeId = event["nodeid"] as? String { nodes.removeValue(forKey: nodeId) }
        case "nodemeshchange", "meshchange", "createmesh", "deletemesh":
            Task {
                try? await sendJSON(["action": "meshes"])
                try? await sendJSON(["action": "nodes"])
            }
        default:
            break
        }
    }

    // MARK: - Requests

    func sendJSON(_ object: [String: Any]) async throws {
        guard let socket else { throw MeshError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw MeshError.notConnected }
        try await socket.send(text: text)
    }

    func refreshDeviceList() async {
        try? await sendJSON(["action": "meshes"])
        try? await sendJSON(["action": "nodes"])
    }

    /// True for agentless devices in a local/relay device group (mesh mtype 3).
    /// They never report an agent connection, but the server can still reach
    /// them over the network (e.g. SSH), so they must not be treated as offline.
    func isLocalDevice(_ node: MeshNode) -> Bool {
        meshes.first { $0.id == node.meshId }?.mtype == 3
    }

    /// Asks the server to mint a durable login token for this account, so the app
    /// can reconnect without signing in again. Returns nil if the server refuses
    /// (e.g. login tokens disabled) or times out — the caller then falls back to
    /// the session cookie. `expire: 0` means the token never expires.
    func createLoginToken(name: String = "Mesh Remote (iOS)") async -> (user: String, pass: String)? {
        guard state == .connected, tokenWaiter == nil else { return nil }
        return await withCheckedContinuation { cont in
            tokenWaiter = cont
            Task { try? await sendJSON(["action": "createLoginToken", "name": name, "expire": 0]) }
            Task {
                try? await Task.sleep(for: .seconds(10))
                if let waiter = tokenWaiter { tokenWaiter = nil; waiter.resume(returning: nil) }
            }
        }
    }

    func wake(nodeId: String) async throws {
        try await sendJSON(["action": "wakedevices", "nodeids": [nodeId]])
    }

    func powerAction(nodeId: String, action: PowerActionType) async throws {
        try await sendJSON(["action": "poweraction", "nodeids": [nodeId], "actiontype": action.rawValue])
    }

    // MARK: - Relay cookies & tunnels

    private func startCookieRefresh() {
        cookieRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20 * 60))
                guard let self else { return }
                try? await self.sendJSON(["action": "authcookie"])
            }
        }
    }

    /// Periodic client heartbeat. On a socket iOS half-closed during suspension,
    /// the send throws on resume, letting us detect and surface a dead connection
    /// (send-only; the server answers our ping with pong, which we ignore).
    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self else { return }
                do { try await self.sendJSON(["action": "ping"]) }
                catch { self.markConnectionLost(); return }
            }
        }
    }

    /// Ensures fresh relay cookies, requesting them if needed. Concurrent callers
    /// share a single in-flight fetch so they can't strand each other's waiters.
    func relayCookies() async throws -> (auth: String, rauth: String) {
        if let authCookie, let rCookie { return (authCookie, rCookie) }
        if let existing = cookieFetch { return try await existing.value }

        let fetch = Task { () throws -> (auth: String, rauth: String) in
            try await sendJSON(["action": "authcookie"])
            // The response populates authCookie/rCookie via handle(); poll for it.
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let a = authCookie, let r = rCookie { return (a, r) }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw MeshError.timeout("device credentials")
        }
        cookieFetch = fetch
        defer { if cookieFetch == fetch { cookieFetch = nil } }
        return try await fetch.value
    }

    /// Opens a relay tunnel to a device. If the first attempt times out — the
    /// usual symptom of relay cookies that went stale while the app was
    /// suspended — it re-mints cookies once and retries before giving up.
    func openTunnel(nodeId: String, relayProtocol: RelayProtocol) async throws -> MeshWebSocket {
        do {
            return try await openTunnelOnce(nodeId: nodeId, relayProtocol: relayProtocol)
        } catch MeshError.timeout {
            invalidateCookies()
            return try await openTunnelOnce(nodeId: nodeId, relayProtocol: relayProtocol)
        }
    }

    private func openTunnelOnce(nodeId: String, relayProtocol: RelayProtocol) async throws -> MeshWebSocket {
        guard state == .connected else { throw MeshError.notConnected }
        let cookies = try await relayCookies()
        let tunnelId = Self.randomHex(12)

        // Agent side (via control channel). The value is server-relative ('*' prefix).
        let agentURL = "*/meshrelay.ashx?p=\(relayProtocol.rawValue)&nodeid=\(nodeId)&id=\(tunnelId)&rauth=\(cookies.rauth)"
        try await sendJSON([
            "action": "msg", "type": "tunnel", "nodeid": nodeId,
            "value": agentURL, "usage": relayProtocol.rawValue
        ])

        // Our side.
        guard let url = profile.websocketURL(path: "meshrelay.ashx", query: [
            URLQueryItem(name: "browser", value: "1"),
            URLQueryItem(name: "p", value: String(relayProtocol.rawValue)),
            URLQueryItem(name: "nodeid", value: nodeId),
            URLQueryItem(name: "id", value: tunnelId),
            URLQueryItem(name: "auth", value: cookies.auth)
        ]) else { throw MeshError.badServerAddress }

        let relay = MeshWebSocket(url: url, allowSelfSigned: profile.allowSelfSigned)
        try await relay.connect()

        // Wait for 'c' or 'cr' (the agent may take a few seconds to dial in).
        // receive() blocks until a frame arrives, so a watchdog enforces the timeout
        // by closing the socket, which makes receive() throw.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(20))
            relay.close()
        }
        defer { watchdog.cancel() }
        do {
            while true {
                let message = try await relay.receive()
                if case .text(let text) = message, text == "c" || text == "cr" { break }
            }
        } catch {
            relay.close()
            throw MeshError.timeout("the device to connect")
        }
        try await relay.send(text: String(relayProtocol.rawValue))
        return relay
    }

    /// Opens the SSH terminal relay (a different endpoint from meshrelay).
    /// Returns the socket right after connection; the SSH auth dance happens on it.
    func openSSHTunnel(nodeId: String) async throws -> MeshWebSocket {
        guard state == .connected else { throw MeshError.notConnected }
        let cookies = try await relayCookies()
        guard let url = profile.websocketURL(path: "sshterminalrelay.ashx", query: [
            URLQueryItem(name: "browser", value: "1"),
            URLQueryItem(name: "p", value: "11"),
            URLQueryItem(name: "nodeid", value: nodeId),
            URLQueryItem(name: "id", value: Self.randomHex(12)),
            URLQueryItem(name: "auth", value: cookies.auth)
        ]) else { throw MeshError.badServerAddress }

        let relay = MeshWebSocket(url: url, allowSelfSigned: profile.allowSelfSigned)
        do {
            try await relay.connect()
        } catch {
            throw MeshError.relayFailed("Could not open an SSH session. Make sure SSH is enabled on the server (\"ssh\": true in the domain config).")
        }
        return relay
    }

    static func randomHex(_ length: Int) -> String {
        let chars = "0123456789abcdef"
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}
