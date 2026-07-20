import Foundation

/// Plain HTTPS file download with progress and optional self-signed trust.
/// Used for device file downloads via devicefile.ashx — the relay download
/// protocol is limited to one 16 KB chunk per round trip by the agent, while
/// this streams at full speed (it's what the MeshCentral web UI uses too).
final class HTTPSDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let allowSelfSigned: Bool
    private let expectedHost: String
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?

    /// (bytesReceived, totalExpected — may be -1 if the server didn't say)
    var onProgress: ((Int64, Int64) -> Void)?

    init(allowSelfSigned: Bool, host: String) {
        self.allowSelfSigned = allowSelfSigned
        self.expectedHost = host
    }

    func download(from url: URL) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
        }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let task = session.downloadTask(with: url)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            continuation?.resume(throwing: MeshError.relayFailed(
                "The server refused the download (HTTP \(http.statusCode))."))
            continuation = nil
            return
        }
        // The system deletes `location` when this method returns — move it now.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("meshremote-dl-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
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
