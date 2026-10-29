import XCTest
@testable import MeshRemote

/// Server-field parsing and URL building, including MeshCentral's
/// path-based domains (https://server/domain1/).
@MainActor
final class ServerAddressTests: XCTestCase {
    func testParseKeepsDomainPath() {
        XCTAssertEqual(ServerAddress.parse("https://mesh.example.com:8080/domain1/?key=abc"),
                       .init(host: "mesh.example.com:8080/domain1", key: "abc"))
        XCTAssertEqual(ServerAddress.parse("mesh.example.com/domain2")?.host, "mesh.example.com/domain2")
    }

    func testParseDefaultDomain() {
        XCTAssertEqual(ServerAddress.parse("https://mesh.example.com:8443/?key=abc123"),
                       .init(host: "mesh.example.com:8443", key: "abc123"))
        XCTAssertEqual(ServerAddress.parse("mesh.example.com")?.host, "mesh.example.com")
    }

    func testParseDropsTrailingPage() {
        XCTAssertEqual(ServerAddress.parse("https://mesh.example.com/domain1/login.htm")?.host,
                       "mesh.example.com/domain1")
        XCTAssertEqual(ServerAddress.parse("https://mesh.example.com/control.ashx")?.host,
                       "mesh.example.com")
    }

    func testURLsIncludeDomainPath() {
        let profile = ServerProfile(displayName: "", host: "mesh.example.com:8080/domain1",
                                    username: "", allowSelfSigned: false)
        XCTAssertEqual(profile.domainPath, "/domain1")
        XCTAssertEqual(profile.websocketURL(path: "control.ashx")?.absoluteString,
                       "wss://mesh.example.com:8080/domain1/control.ashx")
        XCTAssertEqual(profile.loginPageURL?.absoluteString, "https://mesh.example.com:8080/domain1/")
    }

    func testURLsForDefaultDomain() {
        let profile = ServerProfile(displayName: "", host: "mesh.example.com",
                                    username: "", allowSelfSigned: false)
        XCTAssertEqual(profile.domainPath, "")
        XCTAssertEqual(profile.websocketURL(path: "control.ashx")?.absoluteString,
                       "wss://mesh.example.com/control.ashx")
        XCTAssertEqual(profile.loginPageURL?.absoluteString, "https://mesh.example.com/")
    }
}
