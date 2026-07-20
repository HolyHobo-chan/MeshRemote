import Foundation

/// A message received from a MeshCentral websocket.
enum WSMessage {
    case text(String)
    case binary(Data)
}

enum WSError: Error, LocalizedError {
    case notConnected
    case closed(code: URLSessionWebSocketTask.CloseCode?, reason: String?)
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected."
        case .closed(_, let reason):
            if let reason, !reason.isEmpty { return "Connection closed: \(reason)" }
            return "Connection closed."
        case .httpError(let code): return "Server returned HTTP \(code)."
        }
    }
}

/// Thin wrapper over URLSessionWebSocketTask: optional self-signed-cert trust,
/// custom headers, and an async receive stream.
final class MeshWebSocket: NSObject, @unchecked Sendable {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let allowSelfSigned: Bool
    private let expectedHost: String

    init(url: URL, headers: [String: String] = [:], allowSelfSigned: Bool) {
        self.allowSelfSigned = allowSelfSigned
        self.expectedHost = url.host ?? ""
        super.init()

        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session

        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 32 * 1024 * 1024
        self.task = task
    }

    /// Opens the socket and completes once connected (or throws on failure).
    func connect() async throws {
        guard let task else { throw WSError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            openContinuation = cont
            task.resume()
        }
    }

    private var openContinuation: CheckedContinuation<Void, Error>?

    func send(text: String) async throws {
        guard let task else { throw WSError.notConnected }
        try await task.send(.string(text))
    }

    func send(data: Data) async throws {
        guard let task else { throw WSError.notConnected }
        try await task.send(.data(data))
    }

    func receive() async throws -> WSMessage {
        guard let task else { throw WSError.notConnected }
        let message = try await task.receive()
        switch message {
        case .string(let s): return .text(s)
        case .data(let d): return .binary(d)
        @unknown default: throw WSError.notConnected
        }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    deinit { close() }
}

extension MeshWebSocket: URLSessionWebSocketDelegate, URLSessionDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        openContinuation?.resume()
        openContinuation = nil
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        openContinuation?.resume(throwing: WSError.closed(code: closeCode, reason: reasonText))
        openContinuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            openContinuation?.resume(throwing: error)
            openContinuation = nil
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if allowSelfSigned && challenge.protectionSpace.host == expectedHost {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
