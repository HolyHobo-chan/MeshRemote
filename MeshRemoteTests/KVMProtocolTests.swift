import XCTest
import UIKit
@testable import MeshRemote

/// Pure protocol tests for the KVM binary decoder — no server required.
@MainActor
final class KVMProtocolTests: XCTestCase {

    private func makeSession() -> DesktopSession {
        let profile = ServerProfile(displayName: "test", host: "localhost:1",
                                    username: "x", allowSelfSigned: true)
        let connection = MeshServerConnection(profile: profile)
        let node = MeshNode(json: ["_id": "node//test", "name": "Test"], meshId: "mesh//test")!
        return DesktopSession(connection: connection, node: node)
    }

    private func command(_ cmd: UInt16, payload: Data) -> Data {
        var data = Data()
        data.appendBE(cmd)
        data.appendBE(UInt16(payload.count + 4))
        data.append(payload)
        return data
    }

    private func jpegTile(width: Int, height: Int, color: UIColor) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    func testScreenSizeCommand() {
        let session = makeSession()
        var payload = Data()
        payload.appendBE(UInt16(1920))
        payload.appendBE(UInt16(1080))
        var buffer = command(7, payload: payload)
        session.drainCommands(from: &buffer)
        XCTAssertEqual(session.screenSize, CGSize(width: 1920, height: 1080))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testTileDecodeAndDraw() {
        let session = makeSession()

        // Screen size first, then a tile at (16, 32).
        var screen = Data()
        screen.appendBE(UInt16(256))
        screen.appendBE(UInt16(256))
        var buffer = command(7, payload: screen)

        var tilePayload = Data()
        tilePayload.appendBE(UInt16(16))
        tilePayload.appendBE(UInt16(32))
        tilePayload.append(jpegTile(width: 64, height: 64, color: .red))
        buffer.append(command(3, payload: tilePayload))

        session.drainCommands(from: &buffer)
        XCTAssertEqual(session.tilesReceived, 1)
        XCTAssertTrue(buffer.isEmpty)

        // The framebuffer applies pending draws before snapshotting (serial queue).
        let image = session.currentImage()
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 256)
        XCTAssertEqual(image?.height, 256)
    }

    func testJumboWrappedTile() {
        let session = makeSession()
        var screen = Data()
        screen.appendBE(UInt16(4096))
        screen.appendBE(UInt16(2160))
        var buffer = command(7, payload: screen)
        session.drainCommands(from: &buffer)

        var tilePayload = Data()
        tilePayload.appendBE(UInt16(0))
        tilePayload.appendBE(UInt16(0))
        tilePayload.append(jpegTile(width: 128, height: 128, color: .blue))
        let inner = command(3, payload: tilePayload)

        var jumbo = Data()
        jumbo.appendBE(UInt16(27))
        jumbo.appendBE(UInt16(8))
        jumbo.appendBE(UInt32(inner.count))
        jumbo.append(inner)

        var jumboBuffer = jumbo
        session.drainCommands(from: &jumboBuffer)
        XCTAssertEqual(session.tilesReceived, 1)
        XCTAssertTrue(jumboBuffer.isEmpty)
    }

    func testFragmentedCommandReassembly() {
        let session = makeSession()
        var payload = Data()
        payload.appendBE(UInt16(800))
        payload.appendBE(UInt16(600))
        let full = command(7, payload: payload)

        // Deliver in two fragments, as WebRTC/large websocket frames would.
        var buffer = full.prefix(5)
        session.drainCommands(from: &buffer)
        XCTAssertEqual(session.screenSize, .zero)   // incomplete: nothing parsed

        buffer.append(full.suffix(from: 5))
        session.drainCommands(from: &buffer)
        XCTAssertEqual(session.screenSize, CGSize(width: 800, height: 600))
    }

    func testDisplayListCommand() {
        let session = makeSession()
        var payload = Data()
        payload.appendBE(UInt16(2))          // two displays
        payload.appendBE(UInt16(1))
        payload.appendBE(UInt16(2))
        payload.appendBE(UInt16(0xFFFF))     // selected: all
        var buffer = command(11, payload: payload)
        session.drainCommands(from: &buffer)
        XCTAssertEqual(session.displays, [1, 2])
        XCTAssertEqual(session.selectedDisplay, 0xFFFF)
    }

    func testMalformedCommandDropsStream() {
        let session = makeSession()
        var buffer = Data([0x00, 0x03, 0x00, 0x00, 0xFF])   // size 0 < header: malformed
        session.drainCommands(from: &buffer)
        XCTAssertTrue(buffer.isEmpty)   // dropped, no infinite loop
    }

    func testBinaryHelpers() {
        var data = Data()
        data.appendBE(UInt16(0xABCD))
        data.appendBE(UInt32(0x01020304))
        XCTAssertEqual(data.beUInt16(at: 0), 0xABCD)
        XCTAssertEqual(data.beUInt32(at: 2), 0x01020304)
        XCTAssertNil(data.beUInt32(at: 4))   // out of range

        // Slices with non-zero start indices must still read correctly.
        let slice = data.subdata(in: 2..<6)
        XCTAssertEqual(slice.beUInt32(at: 0), 0x01020304)
    }
}
