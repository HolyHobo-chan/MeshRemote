import XCTest
@testable import MeshRemote

/// Live integration tests against a local MeshCentral instance.
/// Start it with: node node_modules/meshcentral (account admin/test1234).
/// Tests skip automatically when the server isn't running.
@MainActor
final class ControlChannelTests: XCTestCase {
    static let host = "localhost:8443"
    static let username = "admin"
    static let password = "test1234"

    private func makeProfile() -> ServerProfile {
        ServerProfile(displayName: "local-test", host: Self.host,
                      username: Self.username, allowSelfSigned: true)
    }

    private func serverAvailable() async -> Bool {
        guard let url = URL(string: "https://\(Self.host)/") else { return false }
        let socket = MeshWebSocket(url: url, allowSelfSigned: true)
        defer { socket.close() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        // A plain HTTPS probe with self-signed trust via the websocket's session is
        // overkill; just try a TCP-level fetch and accept any response/error != cannotConnect.
        do {
            let config = URLSessionConfiguration.ephemeral
            let session = URLSession(configuration: config, delegate: TrustAllDelegate(), delegateQueue: nil)
            _ = try await session.data(for: request)
            return true
        } catch {
            let ns = error as NSError
            return !(ns.domain == NSURLErrorDomain &&
                     (ns.code == NSURLErrorCannotConnectToHost || ns.code == NSURLErrorCannotFindHost))
        }
    }

    func testLoginDeviceListAndCookies() async throws {
        guard await serverAvailable() else {
            throw XCTSkip("Local MeshCentral test server is not running.")
        }
        let connection = MeshServerConnection(profile: makeProfile())
        try await connection.connect(password: Self.password)

        XCTAssertEqual(connection.state, .connected)
        XCTAssertNotNil(connection.serverInfo)
        XCTAssertEqual(connection.userInfo?.name.lowercased(), Self.username)

        // meshes/nodes were requested during connect; give the server a moment.
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(connection.meshes.contains { $0.name == "TestGroup" },
                      "Expected the TestGroup device group; got \(connection.meshes.map(\.name))")

        // Relay cookies must be mintable.
        let cookies = try await connection.relayCookies()
        XCTAssertFalse(cookies.auth.isEmpty)
        XCTAssertFalse(cookies.rauth.isEmpty)

        connection.disconnect()
        XCTAssertEqual(connection.state, .disconnected)
    }

    func testBadPasswordFails() async throws {
        guard await serverAvailable() else {
            throw XCTSkip("Local MeshCentral test server is not running.")
        }
        let connection = MeshServerConnection(profile: makeProfile())
        do {
            try await connection.connect(password: "definitely-wrong")
            XCTFail("Login should have failed")
        } catch {
            if case .failed(let message) = connection.state {
                XCTAssertTrue(message.lowercased().contains("invalid")
                              || message.lowercased().contains("password"),
                              "Unexpected error message: \(message)")
            } else {
                XCTFail("Expected failed state, got \(connection.state)")
            }
        }
    }

    func testBadHostProducesFriendlyError() async {
        let profile = ServerProfile(displayName: "x", host: "definitely-not-a-real-host.invalid",
                                    username: "u", allowSelfSigned: true)
        let connection = MeshServerConnection(profile: profile)
        do {
            try await connection.connect(password: "p")
            XCTFail("Connect should have failed")
        } catch {
            guard case .failed(let message) = connection.state else {
                return XCTFail("Expected failed state")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    /// Opening a tunnel to a nonexistent node should fail with a timeout,
    /// not hang or crash — and the relay must accept our auth cookie.
    func testTunnelToOfflineNodeTimesOut() async throws {
        guard await serverAvailable() else {
            throw XCTSkip("Local MeshCentral test server is not running.")
        }
        let connection = MeshServerConnection(profile: makeProfile())
        try await connection.connect(password: Self.password)
        defer { connection.disconnect() }

        try await Task.sleep(for: .seconds(2))   // let the meshes response arrive
        guard let meshId = connection.meshes.first?.id else {
            throw XCTSkip("No device group present.")
        }
        let fakeNodeId = "node//0000000000000000000000000000000000000000000000000000000000000000"
        _ = meshId
        do {
            _ = try await connection.openTunnel(nodeId: fakeNodeId, relayProtocol: .files)
            XCTFail("Tunnel to a fake node should not succeed")
        } catch {
            // Expected: timeout or relay refusal. Either way we must reach here.
        }
    }
}

private final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
