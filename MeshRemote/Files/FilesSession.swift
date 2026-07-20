import Foundation
import Observation

struct FileEntry: Identifiable, Hashable {
    enum Kind: Int {
        case drive = 1
        case directory = 2
        case file = 3
    }

    var id: String { name }
    let name: String
    let kind: Kind
    let size: Int64
    let modified: Date?
    let driveType: String?
    let freeBytes: Int64?

    init?(json: [String: Any]) {
        guard let name = json["n"] as? String,
              let typeRaw = json["t"] as? Int else { return nil }
        self.name = name
        self.kind = Kind(rawValue: min(typeRaw, 3)) ?? .file
        self.size = (json["s"] as? NSNumber)?.int64Value ?? 0
        self.driveType = json["dt"] as? String
        self.freeBytes = (json["f"] as? NSNumber)?.int64Value

        if let seconds = json["d"] as? NSNumber {
            self.modified = Date(timeIntervalSince1970: seconds.doubleValue)
        } else if let iso = json["d"] as? String {
            self.modified = ISO8601DateFormatter.meshFormatter.date(from: iso)
        } else {
            self.modified = nil
        }
    }
}

private extension ISO8601DateFormatter {
    static let meshFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

enum FilesSessionState: Equatable {
    case connecting
    case ready
    case closed(String?)
}

struct FileTransferProgress: Equatable {
    var fileName: String
    var transferred: Int64
    var total: Int64
    var isUpload: Bool

    var fraction: Double {
        total > 0 ? Double(transferred) / Double(total) : 0
    }
}

/// File browsing over a meshrelay p=5 tunnel: JSON commands as binary frames,
/// download chunks as raw binary with a 4-byte header.
@Observable
@MainActor
final class FilesSession {
    private(set) var state: FilesSessionState = .connecting
    private(set) var entries: [FileEntry] = []
    private(set) var pathComponents: [String] = []
    private(set) var isLoading = false
    private(set) var transfer: FileTransferProgress?
    private(set) var lastError: String?

    let node: MeshNode
    private let connection: MeshServerConnection
    private var socket: MeshWebSocket?
    private var sender: OrderedSender?
    private var receiveTask: Task<Void, Never>?
    private var requestCounter = 1
    private var stopped = false

    // Active download (plain HTTPS via devicefile.ashx — see HTTPSDownloader).
    private var downloader: HTTPSDownloader?

    // Active upload state. The agent applies no flow control on uploads — it
    // writes whatever arrives and acks each chunk — so we keep a window of
    // chunks in flight instead of the naive 1-chunk-per-round-trip.
    private let uploadWindow = 16          // × 64 KB = ~1 MB in flight
    private var uploadInFlight = 0
    private var uploadData: Data?
    private var uploadOffset = 0
    private var uploadReqId = 0
    private var uploadContinuation: CheckedContinuation<Void, Error>?

    // Progress updates are throttled: SwiftUI re-rendering per chunk steals
    // main-thread time from the transfer itself.
    private var lastProgressUpdate = Date.distantPast

    init(connection: MeshServerConnection, node: MeshNode) {
        self.connection = connection
        self.node = node
    }

    /// Windows agents list drives at the empty path; everything else starts at /.
    private var isWindows: Bool { node.osFamily == .windows }

    var currentPath: String {
        if pathComponents.isEmpty { return isWindows ? "" : "/" }
        return pathComponents.joined(separator: "/")
    }

    var displayPath: String {
        pathComponents.isEmpty ? (isWindows ? "This PC" : "/") : pathComponents.joined(separator: "/")
    }

    func start() async {
        do {
            let socket = try await connection.openTunnel(nodeId: node.id, relayProtocol: .files)
            // The view may have been dismissed during the connect await.
            guard !stopped else { socket.close(); return }
            self.socket = socket
            sender = OrderedSender(socket: socket)
            state = .ready
            startReceiveLoop(socket: socket)
            await list()
        } catch {
            guard !stopped else { return }
            state = .closed(error.localizedDescription)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        sendControlText(["ctrlChannel": "102938", "type": "close"])
        receiveTask?.cancel()
        sender?.finish()
        sender = nil
        socket?.close()
        socket = nil
        downloader?.cancel()
        downloader = nil
        uploadContinuation?.resume(throwing: MeshError.notConnected)
        uploadContinuation = nil
        if case .closed = state {} else { state = .closed(nil) }
    }

    // MARK: - Navigation

    func list() async {
        isLoading = true
        lastError = nil
        requestCounter += 1
        sendJSON(["action": "ls", "reqid": requestCounter, "path": currentPath])
    }

    func enter(_ entry: FileEntry) async {
        guard entry.kind != .file else { return }
        pathComponents.append(entry.name)
        await list()
    }

    func goUp() async {
        guard !pathComponents.isEmpty else { return }
        pathComponents.removeLast()
        await list()
    }

    // MARK: - Operations

    func makeDirectory(named name: String) async {
        let path = childPath(name)
        requestCounter += 1
        sendJSON(["action": "mkdir", "reqid": requestCounter, "path": path])
        try? await Task.sleep(for: .milliseconds(400))
        await list()
    }

    func delete(_ entry: FileEntry, recursive: Bool) async {
        requestCounter += 1
        sendJSON(["action": "rm", "reqid": requestCounter, "path": currentPath,
                  "delfiles": [entry.name], "rec": recursive])
        try? await Task.sleep(for: .milliseconds(400))
        await list()
    }

    func rename(_ entry: FileEntry, to newName: String) async {
        sendJSON(["action": "rename", "path": currentPath,
                  "oldname": entry.name, "newname": newName])
        try? await Task.sleep(for: .milliseconds(400))
        await list()
    }

    private func childPath(_ name: String) -> String {
        if pathComponents.isEmpty { return isWindows ? name : "/\(name)" }
        return currentPath + "/" + name
    }

    // MARK: - Download

    /// Downloads a remote file over plain HTTPS (devicefile.ashx) and returns a
    /// local temporary URL. This is what the web UI uses too — the relay
    /// download protocol is capped by the agent at one 16 KB chunk per round trip.
    func download(_ entry: FileEntry) async throws -> URL {
        guard transfer == nil else { throw MeshError.relayFailed("Another transfer is in progress.") }
        let cookies = try await connection.relayCookies()
        // Ids look like "node/<domain>/<hash>" — the domain segment is EMPTY on
        // default-domain servers ("node//hash"), so empty parts must be kept.
        let meshParts = node.meshId.split(separator: "/", omittingEmptySubsequences: false)
        let nodeParts = node.id.split(separator: "/", omittingEmptySubsequences: false)
        guard meshParts.count == 3, nodeParts.count == 3,
              let base = connection.profile.baseURL,
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw MeshError.badServerAddress
        }
        comps.path = "/devicefile.ashx"
        comps.queryItems = [
            URLQueryItem(name: "c", value: cookies.auth),
            URLQueryItem(name: "m", value: String(meshParts[2])),
            URLQueryItem(name: "n", value: String(nodeParts[2])),
            URLQueryItem(name: "f", value: childPath(entry.name))
        ]
        // '+' survives URLComponents encoding but the server decodes it as a
        // space (form encoding); escape it so filenames with '+' work.
        comps.percentEncodedQuery = comps.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { throw MeshError.badServerAddress }

        transfer = FileTransferProgress(fileName: entry.name, transferred: 0,
                                        total: entry.size, isUpload: false)
        let downloader = HTTPSDownloader(allowSelfSigned: connection.profile.allowSelfSigned,
                                         host: base.host ?? "")
        self.downloader = downloader
        let expectedTotal = entry.size
        downloader.onProgress = { [weak self] received, reported in
            Task { @MainActor [weak self] in
                self?.updateProgress(received, total: reported > 0 ? reported : expectedTotal)
            }
        }
        defer {
            transfer = nil
            self.downloader = nil
        }

        let tempURL = try await downloader.download(from: url)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshRemoteDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let localURL = directory.appendingPathComponent(entry.name)
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: tempURL, to: localURL)
        return localURL
    }

    func cancelTransfer() {
        downloader?.cancel()
        if uploadContinuation != nil {
            sendJSON(["action": "uploadcancel", "reqid": uploadReqId])
            uploadContinuation?.resume(throwing: CancellationError())
            uploadContinuation = nil
            uploadData = nil
        }
        transfer = nil
    }

    private func updateProgress(_ transferred: Int64, total: Int64? = nil) {
        guard transfer != nil else { return }
        let now = Date()
        let finished = total != nil && transferred >= (total ?? 0)
        guard finished || now.timeIntervalSince(lastProgressUpdate) > 0.1 else { return }
        lastProgressUpdate = now
        transfer?.transferred = transferred
        if let total, total > 0 { transfer?.total = total }
    }

    // MARK: - Upload

    func upload(fileURL: URL) async throws {
        guard transfer == nil else { throw MeshError.relayFailed("Another transfer is in progress.") }
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: fileURL)
        let name = fileURL.lastPathComponent
        requestCounter += 1
        uploadReqId = requestCounter
        uploadData = data
        uploadOffset = 0
        uploadInFlight = 0
        transfer = FileTransferProgress(fileName: name, transferred: 0,
                                        total: Int64(data.count), isUpload: true)
        defer {
            transfer = nil
            uploadData = nil
        }

        sendJSON(["action": "upload", "reqid": uploadReqId, "path": currentPath,
                  "name": name, "size": data.count, "append": false])

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            uploadContinuation = cont
        }
        await list()
    }

    /// Sends chunks until the in-flight window is full; called on start and on
    /// every uploadack. When everything is sent and acknowledged, finishes up.
    private func pumpUpload() {
        guard let data = uploadData else { return }
        while uploadInFlight < uploadWindow && uploadOffset < data.count {
            let chunkSize = min(65536, data.count - uploadOffset)
            var chunk = data.subdata(in: uploadOffset ..< uploadOffset + chunkSize)
            uploadOffset += chunkSize
            uploadInFlight += 1
            // Escape chunks that could be mistaken for JSON commands.
            if let first = chunk.first, first == 0x7B || first == 0x00 {
                chunk.insert(0x00, at: chunk.startIndex)
            }
            sender?.send(data: chunk)
        }
        // Show acknowledged progress (bytes the agent has written), approximately.
        let acknowledged = max(0, uploadOffset - uploadInFlight * 65536)
        updateProgress(Int64(acknowledged), total: Int64(data.count))
        if uploadOffset >= data.count && uploadInFlight == 0 {
            sendJSON(["action": "uploaddone", "reqid": uploadReqId])
        }
    }

    // MARK: - Receive

    private func startReceiveLoop(socket: MeshWebSocket) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    switch message {
                    case .text(let text):
                        await self?.handleText(text)
                    case .binary(let data):
                        guard !data.isEmpty else { continue }
                        if data.first == 0x7B {   // '{' → JSON command
                            if let text = String(data: data, encoding: .utf8) {
                                await self?.handleText(text)
                            }
                        }
                        // Other binary frames were relay download chunks;
                        // downloads now go over HTTPS (devicefile.ashx).
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        // Release an in-flight upload so its overlay doesn't hang.
                        self.uploadContinuation?.resume(throwing: MeshError.relayFailed("The connection dropped during the transfer."))
                        self.uploadContinuation = nil
                        self.transfer = nil
                        if case .closed = self.state { return }
                        self.state = .closed("The file session ended.")
                    }
                    return
                }
            }
        }
    }

    private func handleText(_ text: String) {
        guard text.hasPrefix("{"), let json = MeshServerConnection.parseJSON(text) else { return }

        if json["ctrlChannel"] != nil {
            if json["type"] as? String == "ping" {
                sendControlText(["ctrlChannel": "102938", "type": "pong"])
            }
            return
        }

        switch json["action"] as? String {
        case "ls", .none where json["dir"] != nil:
            handleListing(json)
        case "uploadstart":
            pumpUpload()
        case "uploadack":
            uploadInFlight = max(0, uploadInFlight - 1)
            pumpUpload()
        case "uploaddone":
            uploadContinuation?.resume()
            uploadContinuation = nil
        case "uploaderror":
            uploadContinuation?.resume(throwing: MeshError.relayFailed("The device could not write the file."))
            uploadContinuation = nil
        case "refresh":
            Task { await list() }
        default:
            // ls responses have no action field; detect by presence of dir/path.
            if json["dir"] != nil || (json["path"] != nil && json["reqid"] != nil) {
                handleListing(json)
            }
        }
    }

    private func handleListing(_ json: [String: Any]) {
        isLoading = false
        guard let dir = json["dir"] as? [[String: Any]] else {
            lastError = "This folder can't be read."
            entries = []
            return
        }
        var list = dir.compactMap { FileEntry(json: $0) }
        list.sort { a, b in
            if a.kind.rawValue != b.kind.rawValue { return a.kind.rawValue < b.kind.rawValue }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        entries = list
    }

    // MARK: - Send helpers

    /// JSON commands go to the agent as binary UTF-8 frames (first byte '{').
    private func sendJSON(_ object: [String: Any]) {
        sender?.sendJSON(object, asBinary: true)
    }

    /// Control-channel messages (ping/pong/close) travel as text frames.
    private func sendControlText(_ object: [String: Any]) {
        sender?.sendJSON(object)
    }
}
