import Foundation
import CoreGraphics
import UIKit
import Observation

/// KVM protocol command numbers (subset used by this client).
private enum KVM {
    static let key: UInt16 = 1
    static let mouse: UInt16 = 2
    static let tile: UInt16 = 3
    static let compression: UInt16 = 5
    static let refresh: UInt16 = 6
    static let screen: UInt16 = 7
    static let pause: UInt16 = 8
    static let ctrlAltDel: UInt16 = 10
    static let getDisplays: UInt16 = 11
    static let setDisplay: UInt16 = 12
    static let touchInit: UInt16 = 14
    static let message: UInt16 = 17
    static let jumbo: UInt16 = 27
    static let alert: UInt16 = 65
    static let unicodeKey: UInt16 = 85
    static let inputLock: UInt16 = 87
}

enum MouseButton {
    case left, right, middle

    var downFlag: UInt8 {
        switch self {
        case .left: return 0x02
        case .right: return 0x08
        case .middle: return 0x20
        }
    }
    var upFlag: UInt8 { downFlag << 1 }
}

enum KeyAction: UInt8 {
    case down = 0
    case up = 1
    case extendedUp = 3
    case extendedDown = 4
}

enum DesktopQuality: String, CaseIterable, Identifiable {
    case low = "Low"
    case balanced = "Balanced"
    case high = "High"

    var id: String { rawValue }

    /// (jpeg quality 1-100, scaling /1024, frame timer ms)
    /// Scaling stays 1024 (100%) in every preset: agent-side downscaling shrinks the
    /// framebuffer coordinate space and can desync mouse input from the picture.
    var settings: (quality: UInt8, scaling: UInt16, frameTimer: UInt16) {
        switch self {
        case .low: return (15, 1024, 150)
        case .balanced: return (50, 1024, 100)
        case .high: return (80, 1024, 50)
        }
    }
}

enum DesktopSessionState: Equatable {
    case connecting
    case connected
    case closed(String?)
}

@MainActor
protocol DesktopSessionDelegate: AnyObject {
    /// New pixels are available; pull `currentImage()` when convenient.
    func desktopFrameUpdated(_ session: DesktopSession)
    func desktopScreenSizeChanged(_ session: DesktopSession, size: CGSize)
}

/// A live remote desktop session: owns the relay socket, decodes the KVM stream
/// into a bitmap, and encodes input events.
@Observable
@MainActor
final class DesktopSession {
    private(set) var state: DesktopSessionState = .connecting
    private(set) var screenSize: CGSize = .zero
    private(set) var displays: [Int] = []
    private(set) var selectedDisplay: Int = 0
    private(set) var remoteMessage: String?
    private(set) var tilesReceived = 0

    var quality: DesktopQuality = .balanced {
        didSet { sendCompressionSettings() }
    }

    weak var delegate: DesktopSessionDelegate?

    private let connection: MeshServerConnection
    private let node: MeshNode
    private var socket: MeshWebSocket?
    private var receiveTask: Task<Void, Never>?
    private var rttTask: Task<Void, Never>?

    // Ordered outbound queue: input events must stay in order.
    private var sender: OrderedSender?

    // Framebuffer, internally synchronized on its own queue.
    private let framebuffer = KVMFramebuffer()

    init(connection: MeshServerConnection, node: MeshNode) {
        self.connection = connection
        self.node = node
    }

    // MARK: - Lifecycle

    private var stopped = false

    func start() async {
        do {
            let socket = try await connection.openTunnel(nodeId: node.id, relayProtocol: .desktop)
            // The view may have been dismissed during the connect await; if so,
            // don't start a session nothing will ever tear down.
            guard !stopped else { socket.close(); return }
            self.socket = socket
            state = .connected
            sender = OrderedSender(socket: socket)
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
        receiveTask?.cancel()
        rttTask?.cancel()
        sender?.finish()
        sender = nil
        socket?.close()
        socket = nil
        if case .closed = state {} else { state = .closed(nil) }
    }

    /// Pause/resume the stream (call when the app backgrounds/foregrounds).
    func setPaused(_ paused: Bool) {
        sendCommand(KVM.pause, payload: Data([paused ? 1 : 0]))
        if !paused { sendCommand(KVM.refresh) }
    }

    // MARK: - Send plumbing

    private func sendCommand(_ command: UInt16, payload: Data = Data()) {
        var data = Data(capacity: payload.count + 4)
        data.appendBE(command)
        data.appendBE(UInt16(payload.count + 4))
        data.append(payload)
        sender?.send(data: data)
    }

    private func sendControl(_ object: [String: Any]) {
        sender?.sendJSON(object)
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

    // MARK: - Input encoding

    func sendMouseMove(to point: CGPoint) {
        sendMouse(button: 0, point: point)
    }

    func sendMouseButton(_ button: MouseButton, down: Bool, at point: CGPoint) {
        sendMouse(button: down ? button.downFlag : button.upFlag, point: point)
    }

    func sendClick(_ button: MouseButton, at point: CGPoint) {
        sendMouse(button: 0, point: point)
        sendMouse(button: button.downFlag, point: point)
        sendMouse(button: button.upFlag, point: point)
    }

    func sendDoubleClick(at point: CGPoint) {
        sendClick(.left, at: point)
        sendMouse(button: 0x88, point: point)
    }

    private func sendMouse(button: UInt8, point: CGPoint) {
        let x = UInt16(max(0, min(point.x, screenSize.width)))
        let y = UInt16(max(0, min(point.y, screenSize.height)))
        var payload = Data()
        payload.append(0)
        payload.append(button)
        payload.appendBE(x)
        payload.appendBE(y)
        sendCommand(KVM.mouse, payload: payload)
    }

    /// wheel: positive = scroll up. Delta in multiples of 120.
    func sendScroll(delta: Int, at point: CGPoint) {
        let x = UInt16(max(0, min(point.x, screenSize.width)))
        let y = UInt16(max(0, min(point.y, screenSize.height)))
        var payload = Data()
        payload.append(0)
        payload.append(0)
        payload.appendBE(x)
        payload.appendBE(y)
        payload.appendBE(UInt16(bitPattern: Int16(clamping: delta)))
        sendCommand(KVM.mouse, payload: payload)
    }

    /// Printable character via the unicode path (keymap-independent).
    func sendUnicode(_ scalar: UnicodeScalar) {
        for action: UInt8 in [0, 1] {
            var payload = Data()
            payload.append(action)
            payload.appendBE(UInt16(clamping: scalar.value))
            sendCommand(KVM.unicodeKey, payload: payload)
        }
    }

    /// Virtual-key press (Windows VK codes).
    func sendKey(_ keyCode: UInt8, action: KeyAction) {
        sendCommand(KVM.key, payload: Data([action.rawValue, keyCode]))
    }

    func sendKeyTap(_ keyCode: UInt8, extended: Bool = false) {
        sendKey(keyCode, action: extended ? .extendedDown : .down)
        sendKey(keyCode, action: extended ? .extendedUp : .up)
    }

    func sendCtrlAltDel() {
        sendCommand(KVM.ctrlAltDel)
    }

    func requestRefresh() {
        sendCommand(KVM.refresh)
    }

    func selectDisplay(_ display: Int) {
        selectedDisplay = display
        var payload = Data()
        payload.appendBE(UInt16(display))
        sendCommand(KVM.setDisplay, payload: payload)
        sendCommand(KVM.refresh)
    }

    private func sendCompressionSettings() {
        let s = quality.settings
        var payload = Data()
        payload.append(1)                    // image type: JPEG
        payload.append(s.quality)
        payload.appendBE(s.scaling)
        payload.appendBE(s.frameTimer)
        sendCommand(KVM.compression, payload: payload)
    }

    // MARK: - Receive / decode

    private func startReceiveLoop(socket: MeshWebSocket) {
        receiveTask = Task { [weak self] in
            var buffer = Data()
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    switch message {
                    case .text(let text):
                        await self?.handleControl(text)
                    case .binary(let data):
                        buffer.append(data)
                        await self?.drainCommands(from: &buffer)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if case .closed = self.state { return }
                        self.state = .closed("The desktop session ended.")
                    }
                    return
                }
            }
        }
    }

    private func handleControl(_ text: String) {
        guard text.first == "{",
              let json = MeshServerConnection.parseJSON(text) else { return }
        let type = json["type"] as? String
        if type == "ping" {
            sendControl(["ctrlChannel": "102938", "type": "pong"])
        } else if type == "console", let msg = json["msg"] as? String {
            remoteMessage = msg.isEmpty ? nil : msg
        }
    }

    /// Parses complete commands out of the reassembly buffer. Internal for tests.
    func drainCommands(from buffer: inout Data) {
        while buffer.count >= 4 {
            guard var command = buffer.beUInt16(at: 0),
                  let sizeField = buffer.beUInt16(at: 2) else { return }
            var totalLength = Int(sizeField)
            var body = buffer

            if command == KVM.jumbo && sizeField == 8 {
                guard let realSize = buffer.beUInt32(at: 4) else { return }
                totalLength = 8 + Int(realSize)
                guard buffer.count >= totalLength else { return }
                body = buffer.subdata(in: buffer.startIndex + 8 ..< buffer.startIndex + totalLength)
                command = body.beUInt16(at: 0) ?? 0
            } else {
                guard totalLength >= 4 else {           // malformed; drop the stream
                    buffer.removeAll()
                    return
                }
                guard buffer.count >= totalLength else { return }
                body = buffer.subdata(in: buffer.startIndex ..< buffer.startIndex + totalLength)
            }

            process(command: command, body: body)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + totalLength)
        }
    }

    private func process(command: UInt16, body: Data) {
        switch command {
        case KVM.tile:
            guard let x = body.beUInt16(at: 4), let y = body.beUInt16(at: 6), body.count > 8 else { return }
            tilesReceived += 1
            let imageData = body.subdata(in: body.startIndex + 8 ..< body.endIndex)
            drawTile(imageData, at: CGPoint(x: CGFloat(x), y: CGFloat(y)))

        case KVM.screen:
            guard let w = body.beUInt16(at: 4), let h = body.beUInt16(at: 6) else { return }
            handleScreenSize(CGSize(width: CGFloat(w), height: CGFloat(h)))

        case KVM.getDisplays:
            guard let count = body.beUInt16(at: 4) else { return }
            var list: [Int] = []
            for i in 0..<Int(count) {
                if let id = body.beUInt16(at: 6 + i * 2) { list.append(Int(id)) }
            }
            displays = list
            if let sel = body.beUInt16(at: 6 + Int(count) * 2) { selectedDisplay = Int(sel) }

        case KVM.message, KVM.alert:
            if let text = String(data: body.dropFirst(4), encoding: .utf8), !text.hasPrefix(".") {
                remoteMessage = text
            }

        default:
            break   // other server commands (cursor shape, LED state, …) aren't surfaced
        }
    }

    private func handleScreenSize(_ size: CGSize) {
        screenSize = size
        framebuffer.resize(size)
        // Mirror the web client's post-screen-size burst.
        sendCompressionSettings()
        sendCommand(KVM.pause, payload: Data([0]))
        sendCommand(KVM.inputLock, payload: Data([2]))
        for keyCode: UInt8 in [16, 17, 18, 91, 92, 16] {
            sendKey(keyCode, action: .up)
        }
        sendCommand(KVM.touchInit)
        sendCommand(KVM.getDisplays)
        delegate?.desktopScreenSizeChanged(self, size: size)
    }

    // MARK: - Framebuffer

    private func drawTile(_ imageData: Data, at point: CGPoint) {
        framebuffer.drawTile(imageData, at: point) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.desktopFrameUpdated(self)
            }
        }
    }

    /// Snapshot of the current framebuffer (thread-safe).
    nonisolated func currentImage() -> CGImage? {
        framebuffer.makeImage()
    }
}
