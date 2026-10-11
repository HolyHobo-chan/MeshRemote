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
    // This state is reached from the main actor (connect/receive/close), the
    // send queue's background task, watchdog tasks and URLSession's delegate
    // queue, so every access goes through `lock` — that's what makes the
    // @unchecked Sendable above true rather than just asserted.
    private let lock = NSLock()
    private var _task: URLSessionWebSocketTask?
    private var _session: URLSession?
    private var _openContinuation: CheckedContinuation<Void, Error>?

    private var task: URLSessionWebSocketTask? { lock.withLock { _task } }

    private let allowSelfSigned: Bool
    private let expectedHost: String

    init(url: URL, headers: [String: String] = [:], allowSelfSigned: Bool) {
        self.allowSelfSigned = allowSelfSigned
        self.expectedHost = url.host ?? ""
        super.init()

        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        // Don't let URLSession's own cookie store add/override cookies — when we
        // pass an explicit Cookie header (SSO session auth), it must go verbatim.
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _session = session

        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 32 * 1024 * 1024
        _task = task
    }

    /// Opens the socket and completes once connected (or throws on failure).
    func connect() async throws {
        guard let task else { throw WSError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.withLock { _openContinuation = cont }
            task.resume()
        }
    }

    /// Hands the open result to connect() exactly once, whichever delegate
    /// callback arrives first. Resumed outside the lock.
    private func finishOpen(_ result: Result<Void, Error>) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { _openContinuation = nil }
            return _openContinuation
        }
        cont?.resume(with: result)
    }

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
        let (task, session) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?) in
            defer { _task = nil; _session = nil }
            return (_task, _session)
        }
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    deinit { close() }
}

extension MeshWebSocket: URLSessionWebSocketDelegate, URLSessionDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        finishOpen(.success(()))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        finishOpen(.failure(WSError.closed(code: closeCode, reason: reasonText)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finishOpen(.failure(error))
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
