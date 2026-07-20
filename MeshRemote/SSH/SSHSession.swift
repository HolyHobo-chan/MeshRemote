import Foundation
import Observation

enum SSHSessionState: Equatable {
    case connecting
    case needsCredentials(keyPassOnly: Bool, error: String?)
    case authenticating
    case connected
    case closed(String?)
}

/// SSH over MeshCentral's sshterminalrelay: the server runs the actual SSH client;
/// we exchange JSON control messages and '~'-prefixed terminal text.
@Observable
@MainActor
final class SSHSession {
    private(set) var state: SSHSessionState = .connecting

    /// Terminal output sink (set by the terminal view). Bytes arriving before the
    /// sink is attached are buffered.
    var onOutput: ((Data) -> Void)? {
        didSet {
            guard let onOutput, !pendingOutput.isEmpty else { return }
            onOutput(pendingOutput)
            pendingOutput.removeAll()
        }
    }

    /// Current terminal dimensions, updated by the terminal view.
    var cols = 80
    var rows = 24

    private var pendingOutput = Data()
    private let connection: MeshServerConnection
    private let node: MeshNode
    private var socket: MeshWebSocket?
    private var sender: OrderedSender?
    private var receiveTask: Task<Void, Never>?
    private var stopped = false

    init(connection: MeshServerConnection, node: MeshNode) {
        self.connection = connection
        self.node = node
    }

    func start() async {
        do {
            let socket = try await connection.openSSHTunnel(nodeId: node.id)
            // The view may have been dismissed during the connect await; if so,
            // don't spin up a session nothing will ever tear down.
            guard !stopped else { socket.close(); return }
            self.socket = socket
            sender = OrderedSender(socket: socket)
            startReceiveLoop(socket: socket)
        } catch {
            guard !stopped else { return }
            state = .closed(error.localizedDescription)
        }
    }

    func stop() {
        stopped = true
        receiveTask?.cancel()
        sender?.finish()
        sender = nil
        socket?.close()
        socket = nil
        if case .closed = state {} else { state = .closed(nil) }
    }

    // MARK: - Auth

    func submitCredentials(username: String, password: String, remember: Bool) {
        state = .authenticating
        sendJSON([
            "action": "sshauth",
            "username": username,
            "password": password,
            "keep": remember ? 1 : 0,
            "cols": cols, "rows": rows,
            "width": cols * 8, "height": rows * 16
        ])
    }

    /// The device has a stored SSH private key; the server only needs its
    /// passphrase. Sending `sshkeyauth` uses that key instead of overwriting it
    /// with a password attempt (which `sshauth` would do).
    func submitKeyPassphrase(_ keyPass: String) {
        state = .authenticating
        sendJSON([
            "action": "sshkeyauth",
            "keypass": keyPass,
            "cols": cols, "rows": rows,
            "width": cols * 8, "height": rows * 16
        ])
    }

    private func sendAutoAuth() {
        state = .authenticating
        sendJSON([
            "action": "sshautoauth",
            "cols": cols, "rows": rows,
            "width": cols * 8, "height": rows * 16
        ])
    }

    // MARK: - Terminal I/O

    func sendInput(_ data: ArraySlice<UInt8>) {
        guard state == .connected,
              let text = String(bytes: data, encoding: .utf8) else { return }
        sender?.send(text: "~" + text)
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        guard state == .connected else { return }
        sendJSON(["action": "resize", "cols": cols, "rows": rows,
                  "width": cols * 8, "height": rows * 16])
    }

    // MARK: - Receive

    private func startReceiveLoop(socket: MeshWebSocket) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard case .text(let text) = message else { continue }
                    await self?.handle(text)
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if case .closed = self.state { return }
                        self.state = .closed("The SSH session ended.")
                    }
                    return
                }
            }
        }
    }

    private func handle(_ text: String) {
        if text == "c" || text == "cr" {
            state = .connected
            return
        }
        if text.hasPrefix("~") {
            let payload = Data(text.dropFirst().utf8)
            if let onOutput { onOutput(payload) }
            else { pendingOutput.append(payload) }
            return
        }
        guard text.hasPrefix("{"), let json = MeshServerConnection.parseJSON(text) else { return }

        if json["ctrlChannel"] != nil {
            if json["type"] as? String == "ping" {
                sendJSON(["ctrlChannel": "102938", "type": "pong"])
            }
            return
        }

        switch json["action"] as? String {
        case "sshauth":
            let keyPassOnly = json["askkeypass"] as? Bool ?? false
            state = .needsCredentials(keyPassOnly: keyPassOnly, error: nil)
        case "sshautoauth":
            sendAutoAuth()
        case "autherror":
            state = .needsCredentials(keyPassOnly: false, error: "Authentication failed — check the username and password.")
        case "sessiontimeout":
            state = .closed("The SSH connection timed out. Is SSH running on the device?")
        case "sessionerror", "connectionerror":
            state = .closed("The server could not reach the device over SSH.")
        default:
            break
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        sender?.sendJSON(object)
    }
}
