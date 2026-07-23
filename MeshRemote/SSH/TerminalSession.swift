import Foundation
import Observation

enum TerminalSessionState: Equatable {
    case connecting
    case connected
    case closed(String?)
}

/// The MeshCentral agent terminal (p=1): a shell run by the agent itself —
/// cmd.exe on Windows, bash on Unix — needing no SSH server on the device.
///
/// Wire contract (differs from SSH): after the relay's c/cr handshake the app
/// sends an `options` JSON then the protocol number; terminal I/O is then raw
/// **binary** both ways, while control (resize/consent/close) is JSON text
/// tagged `ctrlChannel: 102938`.
@Observable
@MainActor
final class TerminalSession {
    private(set) var state: TerminalSessionState = .connecting
    private(set) var consoleMessage: String?   // agent status/consent banner

    /// Terminal output sink (set by the terminal view). Bytes that arrive before
    /// the sink is attached are buffered.
    var onOutput: ((Data) -> Void)? {
        didSet {
            guard let onOutput, !pendingOutput.isEmpty else { return }
            onOutput(pendingOutput)
            pendingOutput.removeAll()
        }
    }

    var cols = 80
    var rows = 25

    private var pendingOutput = Data()
    private let connection: MeshServerConnection
    private let node: MeshNode
    private var socket: MeshWebSocket?
    private var sender: OrderedSender?
    private var receiveTask: Task<Void, Never>?
    private var rttTask: Task<Void, Never>?
    private var stopped = false

    init(connection: MeshServerConnection, node: MeshNode) {
        self.connection = connection
        self.node = node
    }

    func start() async {
        do {
            let options: [String: Any] = [
                "type": "options", "protocol": RelayProtocol.terminal.rawValue,
                "cols": cols, "rows": rows, "xterm": true
            ]
            let socket = try await connection.openTunnel(nodeId: node.id,
                                                         relayProtocol: .terminal,
                                                         options: options)
            guard !stopped else { socket.close(); return }
            self.socket = socket
            sender = OrderedSender(socket: socket)
            state = .connected
            startReceiveLoop(socket: socket)
            startRTT()
        } catch {
            guard !stopped else { return }
            state = .closed(error.localizedDescription)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        sendControl(["ctrlChannel": "102938", "type": "close"])
        rttTask?.cancel()
        receiveTask?.cancel()
        sender?.finish()
        sender = nil
        socket?.close()
        socket = nil
        if case .closed = state {} else { state = .closed(nil) }
    }

    // MARK: - I/O

    /// Keystrokes/pasted text go to the shell as raw binary UTF-8 (no prefix).
    func sendInput(_ data: ArraySlice<UInt8>) {
        guard state == .connected else { return }
        sender?.send(data: Data(data))
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        guard state == .connected else { return }
        sendControl(["ctrlChannel": "102938", "type": "termsize", "cols": cols, "rows": rows])
    }

    private func startRTT() {
        rttTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sendControl(["ctrlChannel": 102938, "type": "rtt",
                                   "time": Int(Date().timeIntervalSince1970 * 1000)])
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func startReceiveLoop(socket: MeshWebSocket) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    switch message {
                    case .binary(let data):
                        await self?.emitOutput(data)
                    case .text(let text):
                        await self?.handleControl(text)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if case .closed = self.state { return }
                        self.state = .closed("The terminal session ended.")
                    }
                    return
                }
            }
        }
    }

    private func emitOutput(_ data: Data) {
        if let onOutput { onOutput(data) } else { pendingOutput.append(data) }
    }

    private func handleControl(_ text: String) {
        guard text.first == "{", let json = MeshServerConnection.parseJSON(text) else { return }
        guard json["ctrlChannel"] != nil else { return }
        switch json["type"] as? String {
        case "ping":
            sendControl(["ctrlChannel": "102938", "type": "pong"])
        case "console":
            // msgid 0 = clear/ready, 1 = waiting for consent, 2 = error.
            let msgid = json["msgid"] as? Int ?? 0
            let msg = json["msg"] as? String
            consoleMessage = (msgid == 0) ? nil : msg
        default:
            break
        }
    }

    private func sendControl(_ object: [String: Any]) {
        sender?.sendJSON(object)
    }
}
