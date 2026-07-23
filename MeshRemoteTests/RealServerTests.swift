import XCTest
import UIKit
@testable import MeshRemote

/// Live end-to-end tests against a real MeshCentral server with real agents.
/// Configured entirely via environment variables so no credentials live in the repo:
///   MESHREMOTE_TEST_HOST, MESHREMOTE_TEST_USER, MESHREMOTE_TEST_PASS,
///   MESHREMOTE_TEST_NODE (device name for desktop/files tests),
///   MESHREMOTE_SNAPSHOT_PATH (optional: where to write a decoded-frame PNG).
/// All tests skip when the variables are absent.
@MainActor
final class RealServerTests: XCTestCase {
    struct Config {
        let host: String
        let user: String
        let pass: String
        let nodeName: String
        let snapshotPath: String?

        static func fromEnvironment() -> Config? {
            let env = ProcessInfo.processInfo.environment
            guard let host = env["MESHREMOTE_TEST_HOST"],
                  let user = env["MESHREMOTE_TEST_USER"],
                  let pass = env["MESHREMOTE_TEST_PASS"] else { return nil }
            return Config(host: host, user: user, pass: pass,
                          nodeName: env["MESHREMOTE_TEST_NODE"] ?? "",
                          snapshotPath: env["MESHREMOTE_SNAPSHOT_PATH"])
        }
    }

    private func connect(_ config: Config) async throws -> MeshServerConnection {
        let profile = ServerProfile(displayName: "live", host: config.host,
                                    username: config.user, allowSelfSigned: true)
        let connection = MeshServerConnection(profile: profile)
        try await connection.connect(password: config.pass)
        // Give the meshes/nodes responses a moment to arrive.
        for _ in 0..<40 where connection.nodes.isEmpty {
            try await Task.sleep(for: .milliseconds(250))
        }
        return connection
    }

    private func onlineAgentNode(_ connection: MeshServerConnection, named name: String) -> MeshNode? {
        connection.nodes.values.first { $0.name == name && $0.hasAgent }
    }

    func testLoginTokenRoundTrip() async throws {
        guard let config = Config.fromEnvironment() else { throw XCTSkip("No live-server config in environment.") }
        let profile = ServerProfile(displayName: "live", host: config.host,
                                    username: config.user, allowSelfSigned: true)

        // 1. Log in with password, mint a login token.
        let c1 = MeshServerConnection(profile: profile)
        try await c1.connect(password: config.pass)
        let token = await c1.createLoginToken(name: "MeshRemote Test")
        c1.disconnect()
        guard let token else { return XCTFail("createLoginToken returned nil (server refused?)") }
        print("LIVE: minted token user=\(token.user)")

        // 2. Reconnect using ONLY the token — this is the reconnect path.
        let c2 = MeshServerConnection(profile: profile)
        try await c2.connect(tokenUser: token.user, tokenPass: token.pass)
        XCTAssertEqual(c2.state, .connected, "Token auth failed to connect")
        XCTAssertNotNil(c2.userInfo, "Token auth connected but no userinfo")
        print("LIVE: token auth OK — userinfo=\(c2.userInfo?.name ?? "nil")")
        c2.disconnect()
    }

    func testLiveAgentTerminal() async throws {
        guard let config = Config.fromEnvironment() else { throw XCTSkip("No live-server config in environment.") }
        let connection = try await connect(config)
        defer { connection.disconnect() }
        guard let node = onlineAgentNode(connection, named: config.nodeName) else {
            throw XCTSkip("Node \(config.nodeName) not online.")
        }

        let session = TerminalSession(connection: connection, node: node)
        var output = Data()
        session.onOutput = { output.append($0) }
        await session.start()
        if case .closed(let m) = session.state { return XCTFail("terminal closed: \(m ?? "")") }

        // Nudge the shell and wait for output (a prompt or the echoed command).
        try await Task.sleep(for: .milliseconds(600))
        session.sendInput(ArraySlice(Data("echo meshremote_test\r\n".utf8)))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && output.count < 4 {
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertGreaterThan(output.count, 0, "No terminal output received")
        print("LIVE: terminal output \(output.count) bytes: \(String(data: output.prefix(120), encoding: .utf8) ?? "<binary>")")
        session.stop()
    }

    func testLiveLoginAndDeviceList() async throws {
        guard let config = Config.fromEnvironment() else { throw XCTSkip("No live-server config in environment.") }
        let connection = try await connect(config)
        defer { connection.disconnect() }

        XCTAssertEqual(connection.state, .connected)
        XCTAssertFalse(connection.meshes.isEmpty, "Expected at least one device group")
        XCTAssertFalse(connection.nodes.isEmpty, "Expected at least one device")
        let online = connection.nodes.values.filter(\.isOnline)
        XCTAssertFalse(online.isEmpty, "Expected at least one online device")
        print("LIVE: \(connection.meshes.count) groups, \(connection.nodes.count) devices, \(online.count) online: \(online.map(\.name).sorted())")
    }

    func testLiveDesktopSessionDecodesFrames() async throws {
        guard let config = Config.fromEnvironment() else { throw XCTSkip("No live-server config in environment.") }
        let connection = try await connect(config)
        defer { connection.disconnect() }
        guard let node = onlineAgentNode(connection, named: config.nodeName) else {
            throw XCTSkip("Node \(config.nodeName) not online.")
        }

        let session = DesktopSession(connection: connection, node: node)
        await session.start()
        if case .closed(let message) = session.state {
            return XCTFail("Desktop session closed immediately: \(message ?? "no message")")
        }

        // Wait for screen size + pixel data. A static desktop arrives as a single
        // full-screen (jumbo) tile, so one tile is a complete first frame.
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline && (session.screenSize == .zero || session.tilesReceived < 1) {
            try await Task.sleep(for: .milliseconds(250))
            if case .closed(let message) = session.state {
                return XCTFail("Desktop session ended early: \(message ?? "no message")")
            }
        }
        XCTAssertGreaterThan(session.screenSize.width, 0, "No screen size received")
        XCTAssertGreaterThanOrEqual(session.tilesReceived, 1, "Expected tiles, got \(session.tilesReceived)")
        print("LIVE: desktop \(Int(session.screenSize.width))x\(Int(session.screenSize.height)), \(session.tilesReceived) tiles")

        let image = session.currentImage()
        XCTAssertNotNil(image, "Framebuffer snapshot missing")
        if let image, let path = config.snapshotPath {
            let png = UIImage(cgImage: image).pngData()
            try png?.write(to: URL(fileURLWithPath: path))
            print("LIVE: snapshot written to \(path)")
        }

        // Harmless input check: nudge the mouse near the current center by 2px.
        let center = CGPoint(x: session.screenSize.width / 2, y: session.screenSize.height / 2)
        session.sendMouseMove(to: center)
        session.sendMouseMove(to: CGPoint(x: center.x + 2, y: center.y + 2))
        try await Task.sleep(for: .milliseconds(500))
        if case .closed(let message) = session.state {
            XCTFail("Session dropped after mouse input: \(message ?? "no message")")
        }
        session.stop()
    }

    func testLiveFilesTempRoundTrip() async throws {
        guard let config = Config.fromEnvironment() else { throw XCTSkip("No live-server config in environment.") }
        let connection = try await connect(config)
        defer { connection.disconnect() }
        guard let node = onlineAgentNode(connection, named: config.nodeName) else {
            throw XCTSkip("Node \(config.nodeName) not online.")
        }

        let session = FilesSession(connection: connection, node: node)
        await session.start()
        if case .closed(let message) = session.state {
            return XCTFail("Files session closed immediately: \(message ?? "no message")")
        }

        // Root listing (drive list on Windows).
        try await waitForListing(session)
        XCTAssertFalse(session.entries.isEmpty, "Root listing is empty")
        print("LIVE: root entries: \(session.entries.map(\.name))")

        // Navigate to a writable temp location: C:\ -> Windows -> Temp (agent runs as SYSTEM).
        guard let cDrive = session.entries.first(where: { $0.name.uppercased().hasPrefix("C") && $0.kind == .drive }) else {
            throw XCTSkip("No C: drive found; skipping round-trip")
        }
        await session.enter(cDrive); try await waitForListing(session)
        guard let windows = session.entries.first(where: { $0.name.lowercased() == "windows" }) else {
            throw XCTSkip("No Windows folder; skipping round-trip")
        }
        await session.enter(windows); try await waitForListing(session)
        guard let temp = session.entries.first(where: { $0.name.lowercased() == "temp" }) else {
            throw XCTSkip("No Temp folder; skipping round-trip")
        }
        await session.enter(temp); try await waitForListing(session)

        // Upload a 4 MB random file — large enough to exercise the upload window
        // and give a meaningful throughput number.
        var payload = Data(count: 4 * 1024 * 1024)
        payload.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        let fileName = "meshremote-test.bin"
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try payload.write(to: localURL)
        let uploadStart = Date()
        try await session.upload(fileURL: localURL)
        let uploadSecs = Date().timeIntervalSince(uploadStart)
        try await waitForListing(session)
        XCTAssertTrue(session.entries.contains { $0.name == fileName }, "Uploaded file not in listing")

        // Download it back and compare.
        guard let remoteEntry = session.entries.first(where: { $0.name == fileName }) else {
            return XCTFail("Uploaded file disappeared")
        }
        let downloadStart = Date()
        let downloaded = try await session.download(remoteEntry)
        let downloadSecs = Date().timeIntervalSince(downloadStart)
        let roundTripped = try Data(contentsOf: downloaded)
        XCTAssertEqual(roundTripped, payload, "Round-tripped contents differ")
        let mb = Double(payload.count) / 1_048_576
        print(String(format: "LIVE: files round-trip OK (%.0f MB) — up %.1fs (%.2f MB/s), down %.1fs (%.2f MB/s)",
                     mb, uploadSecs, mb / max(uploadSecs, 0.001), downloadSecs, mb / max(downloadSecs, 0.001)))

        // Clean up remote + local.
        await session.delete(remoteEntry, recursive: false)
        try await waitForListing(session)
        XCTAssertFalse(session.entries.contains { $0.name == fileName }, "Remote temp file was not deleted")
        try? FileManager.default.removeItem(at: localURL)
        try? FileManager.default.removeItem(at: downloaded)
        session.stop()
    }

    func testLiveSSHPromptFlow() async throws {
        guard let config = Config.fromEnvironment() else { throw XCTSkip("No live-server config in environment.") }
        let connection = try await connect(config)
        defer { connection.disconnect() }
        // Prefer an agentless local/relay device — SSH must work for those too,
        // since the server (not an agent) makes the SSH connection.
        let localNode = connection.nodes.values.first { connection.isLocalDevice($0) }
        guard let node = localNode ?? connection.nodes.values.first(where: \.isOnline) else {
            throw XCTSkip("No reachable node.")
        }
        print("LIVE: SSH target: \(node.name) (\(localNode != nil ? "local/relay device" : "agent device"))")

        let session = SSHSession(connection: connection, node: node)
        await session.start()

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            switch session.state {
            case .needsCredentials(let keyPassOnly, let error):
                print("LIVE: SSH auth prompt reached (keyPassOnly: \(keyPassOnly), error: \(error ?? "none"))")
                session.stop()
                return
            case .connected:
                print("LIVE: SSH auto-connected with stored credentials")
                session.stop()
                return
            case .closed(let message):
                // Acceptable outcome: server has SSH disabled or device unreachable —
                // what matters is a clean, explained close instead of a hang.
                print("LIVE: SSH closed gracefully: \(message ?? "no message")")
                return
            case .connecting, .authenticating:
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        XCTFail("SSH session still connecting after 15s — flow is hanging")
    }

    private func waitForListing(_ session: FilesSession, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && session.isLoading {
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTAssertFalse(session.isLoading, "Directory listing timed out")
    }
}
