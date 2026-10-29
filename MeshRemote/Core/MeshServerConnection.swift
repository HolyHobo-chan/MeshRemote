import Foundation
import Observation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    /// The socket died (usually because iOS suspended the app) and we're
    /// re-establishing it. The device list stays on screen while this happens.
    case reconnecting
    case connected
    case failed(String)
}

enum MeshError: Error, LocalizedError {
    case badServerAddress
    case authFailed(String)
    /// The server refused these credentials outright (bad password, revoked or
    /// expired token). Distinct from authFailed so callers can tell "these
    /// credentials are dead" from "this attempt failed" (IP ban, missing key).
    case credentialsRejected
    case twoFactorRequired
    case notConnected
    case timeout(String)
    case relayFailed(String)

    var errorDescription: String? {
        switch self {
        case .badServerAddress: return "Invalid server address."
        case .authFailed(let m): return m
        case .credentialsRejected: return "Invalid username or password."
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
    // Requests awaiting a reply, keyed by the tag sent with each one, so a late
    // answer to an abandoned request can't satisfy a newer one. Each entry
    // decodes its own reply; nil means no reply (timeout or disconnect).
    private var replyWaiters: [Int: ([String: Any]?) -> Void] = [:]

    // The headers that produced the current session, replayed to reconnect
    // after iOS tears the socket down. Memory only — never persisted.
    private var authHeaders: [String: String]?
    private var reconnectTask: Task<Void, Never>?

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
        // Tear down anything left from a previous session first. Without this a
        // reconnect would leave the old receive loop running against the dead
        // socket, and its eventual failure would kill the new connection.
        cleanup()

        let socket = MeshWebSocket(url: url,
                                   headers: authHeaders,
                                   allowSelfSigned: profile.allowSelfSigned)
        self.socket = socket

        do {
            try await socket.connect()
            // The server pushes serverinfo then userinfo on success, or a close message.
            try await waitForLogin(socket: socket)
        } catch {
            socket.close()   // a rejected login leaves the socket open otherwise
            self.socket = nil
            state = .failed(ConnectionAdvice.message(for: error, profile: profile))
            throw error
        }

        self.authHeaders = authHeaders   // kept so we can silently reconnect later
        state = .connected
        startReceiveLoop(socket: socket)
        startCookieRefresh()
        startHeartbeat()

        try? await sendJSON(["action": "meshes"])
        try? await sendJSON(["action": "nodes"])
        try? await sendJSON(["action": "authcookie"])
    }

    /// Called when the app returns to the foreground. iOS severs the control
    /// socket whenever it suspends the app — a few seconds in another app is
    /// enough — so returning here usually means either stale relay cookies (the
    /// server's are good for ~60 minutes) or a dead socket that needs redialing.
    func refreshAfterForeground() async {
        switch state {
        case .connected:
            invalidateCookies()
            do {
                try await sendJSON(["action": "authcookie"])
                try await sendJSON(["action": "nodes"])
            } catch {
                markConnectionLost()
            }
        case .reconnecting:
            // Died while we were suspended (background tasks don't run then), so
            // this foreground pass is the first chance to redial.
            await reconnect()
        case .connecting, .disconnected, .failed:
            // .failed is terminal on purpose: it's where a rejected login lands,
            // and replaying the same credentials on every app switch would earn
            // an IP ban from MeshCentral rather than a session. The banner's
            // Retry button is the way back from here.
            break
        }
    }

    /// What to tell the user about a failed connect: the server's own wording
    /// when it answered (bad password, account locked), otherwise advice for
    /// the network-level error, since it never got that far.
    func failureMessage(for error: Error) -> String {
        if case .failed(let message) = state { return message }
        return ConnectionAdvice.message(for: error, profile: profile)
    }

    /// Re-establishes the control channel by replaying the headers that worked
    /// the first time. Leaves the UI in place: a quick app switch shouldn't dump
    /// the user back to the server list.
    func reconnect() async {
        guard let authHeaders else { return }
        // A queued retry can land after the connection already came back (the
        // foreground pass usually wins the race). Re-dialing here would tear
        // down a perfectly healthy session.
        guard state != .connected, state != .connecting else { return }
        // connect() records its own outcome in `state`, including the failure
        // message, so there's nothing to add here.
        try? await connect(authHeaders: authHeaders)
    }

    /// Retries a socket that dropped while the app was on screen (flaky Wi-Fi,
    /// server restart). Backs off exponentially, with jitter so a fleet of
    /// clients doesn't redial a restarting server in lockstep.
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            for attempt in 0..<3 {
                if attempt > 0 {
                    let delay = pow(2.0, Double(attempt)) + Double.random(in: 0...1)
                    // A cancelled sleep throws, which is the signal to stop.
                    if (try? await Task.sleep(for: .seconds(delay))) == nil { return }
                }
                guard let self else { return }
                await self.reconnect()
                if self.state == .connected { return }
                // Between attempts we're still recovering, not failed: tunnels
                // waiting on the connection should keep waiting, and the banner
                // should keep saying "Reconnecting…" rather than flash an error.
                // Only the last failure stands. (A cancelled task means sign-out,
                // whose .disconnected must not be overwritten.)
                if attempt < 2, !Task.isCancelled, case .failed = self.state {
                    self.state = .reconnecting
                }
            }
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
        default: return .credentialsRejected
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        authHeaders = nil      // an explicit sign-out must not silently reconnect
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
        // No reply can arrive on a closed socket; answer now rather than at the timeout.
        let waiters = replyWaiters.values
        replyWaiters.removeAll()
        waiters.forEach { $0(nil) }
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
        // connect() stores the credentials before it reports .connected, so
        // reaching here always means we have what we need to redial.
        state = .reconnecting
        scheduleReconnect()
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
        case "msg":
            // A reply to request(_:): the server echoes our tag back. Anything
            // without one of our tags isn't for us.
            guard let tag = (json["tag"] as? Int) ?? (json["tag"] as? String).flatMap(Int.init),
                  let waiter = replyWaiters.removeValue(forKey: tag) else { break }
            waiter(json)
        case "event":
            if let event = json["event"] as? [String: Any] {
                handleEvent(event)
            }
        case "close":
            // The server ended the session (revoked, account locked). Tear down
            // here: markConnectionLost only acts on .connected, so once we report
            // .failed nothing else would stop the heartbeat, the cookie timer or
            // the socket.
            let err = closeError(json)
            cleanup()
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
    /// Asks a device's agent which users are signed in, for the remote-desktop
    /// session picker (what the web client's Connect button does). Nil when the
    /// agent doesn't answer in time; callers then connect to the console, which
    /// is what remote desktop always did before.
    func userSessions(nodeId: String) async -> [UserSession]? {
        await request(["action": "msg", "type": "userSessions", "nodeid": nodeId]) { reply in
            guard reply["type"] as? String == "userSessions" else { return nil }
            // The agent sends an object keyed by session id; accept a plain array too.
            let entries = (reply["data"] as? [String: [String: Any]]).map { Array($0.values) }
                ?? (reply["data"] as? [[String: Any]]) ?? []
            return entries.compactMap(UserSession.init(json:))
        }
    }

    /// Sends `command` with a fresh tag and waits for the reply the server
    /// routes back with that tag, decoded by `decode`. Nil on timeout.
    private func request<T>(_ command: [String: Any], timeout: Duration = .seconds(8),
                            decode: @escaping ([String: Any]) -> T?) async -> T? {
        // Ride out a redial in progress (e.g. just back from the background)
        // rather than reporting a missing answer.
        guard (try? await waitUntilConnected()) != nil else { return nil }
        let tag = Int.random(in: 1...Int(Int32.max))
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            replyWaiters[tag] = { reply in cont.resume(returning: reply.flatMap(decode)) }
            var message = command
            message["tag"] = tag
            Task { try? await sendJSON(message) }
            Task {
                try? await Task.sleep(for: timeout)
                replyWaiters.removeValue(forKey: tag)?(nil)
            }
        }
    }

    func createLoginToken(name: String = "MeshRemote (iOS)") async -> (user: String, pass: String)? {
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
    /// `options`, when set, is sent as a JSON control frame right after the c/cr
    /// handshake and before the protocol number — required by the agent terminal
    /// (p=1) to carry initial size/shell settings. Desktop/files pass nil.
    func openTunnel(nodeId: String, relayProtocol: RelayProtocol,
                    options: [String: Any]? = nil) async throws -> MeshWebSocket {
        try await waitUntilConnected()
        do {
            return try await openTunnelOnce(nodeId: nodeId, relayProtocol: relayProtocol, options: options)
        } catch where state == .reconnecting || state == .connecting {
            // Checked first: the control socket dropped while we were opening —
            // typically the foreground probe finding that iOS killed it — so any
            // error here, timeout included, means "wait for the redial", not
            // "retry against the dead socket".
            try await waitUntilConnected()
            return try await openTunnelOnce(nodeId: nodeId, relayProtocol: relayProtocol, options: options)
        } catch MeshError.timeout {
            invalidateCookies()
            return try await openTunnelOnce(nodeId: nodeId, relayProtocol: relayProtocol, options: options)
        }
    }

    /// Holds a tunnel open request until the control socket is usable. Sessions
    /// coming back to the foreground start at the same moment the control
    /// socket is being redialed, and a tunnel can't be opened without it.
    /// The cap covers the whole retry budget in scheduleReconnect — a single
    /// dial can take ~35s (socket timeout plus the login watchdog) — so a slow
    /// but successful redial isn't reported as a failure. Cancelling the caller
    /// (e.g. leaving the screen) ends the wait immediately.
    private func waitUntilConnected(timeout: Duration = .seconds(120)) async throws {
        let deadline = ContinuousClock.now + timeout
        while state == .reconnecting || state == .connecting {
            guard ContinuousClock.now < deadline else {
                throw MeshError.timeout("the server connection")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard state == .connected else { throw MeshError.notConnected }
    }

    private func openTunnelOnce(nodeId: String, relayProtocol: RelayProtocol,
                                options: [String: Any]?) async throws -> MeshWebSocket {
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
        // Every failure below must close the relay explicitly: its URLSession
        // retains it as delegate, so a dropped socket is never deallocated and
        // would stay connected (and leak) for the life of the process.
        var handedOff = false
        defer { if !handedOff { relay.close() } }
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
        // Optional options control frame (terminal), then the protocol number.
        if let options,
           let data = try? JSONSerialization.data(withJSONObject: options),
           let text = String(data: data, encoding: .utf8) {
            try await relay.send(text: text)
        }
        try await relay.send(text: String(relayProtocol.rawValue))
        handedOff = true
        return relay
    }

    /// Opens the SSH terminal relay (a different endpoint from meshrelay).
    /// Returns the socket right after connection; the SSH auth dance happens on it.
    func openSSHTunnel(nodeId: String) async throws -> MeshWebSocket {
        try await waitUntilConnected()
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
            relay.close()   // see openTunnelOnce: an unclosed socket is never freed
            throw MeshError.relayFailed("Could not open an SSH session. Make sure SSH is enabled on the server (\"ssh\": true in the domain config).")
        }
        return relay
    }

    static func randomHex(_ length: Int) -> String {
        let chars = "0123456789abcdef"
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}
