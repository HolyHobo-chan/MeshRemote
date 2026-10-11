import Foundation

/// Serializes websocket sends: yields are synchronous, so enqueue order from the
/// main actor is preserved on the wire. (Spawning a Task per send would not be.)
final class OrderedSender {
    enum Outbound {
        case text(String)
        case binary(Data)
    }

    private let continuation: AsyncStream<Outbound>.Continuation
    private let task: Task<Void, Never>

    init(socket: MeshWebSocket) {
        let (stream, continuation) = AsyncStream.makeStream(of: Outbound.self)
        self.continuation = continuation
        self.task = Task {
            for await item in stream {
                do {
                    switch item {
                    case .text(let text): try await socket.send(text: text)
                    case .binary(let data): try await socket.send(data: data)
                    }
                } catch {
                    break
                }
            }
        }
    }

    func send(text: String) {
        continuation.yield(.text(text))
    }

    func send(data: Data) {
        continuation.yield(.binary(data))
    }

    func sendJSON(_ object: [String: Any], asBinary: Bool = false) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        if asBinary {
            send(data: data)
        } else if let text = String(data: data, encoding: .utf8) {
            send(text: text)
        }
    }

    /// Stops taking new messages, lets everything already queued go out, then
    /// closes `socket`. Sessions queue a final "close" just before stopping;
    /// cancelling the queue outright would drop it, leaving the agent to see an
    /// abrupt disconnect instead of a clean end. A stalled send can't hold the
    /// socket open — after a second it's closed anyway, which fails the send.
    func finish(closing socket: MeshWebSocket) {
        continuation.finish()
        let drain = task
        Task {
            let deadline = Task {
                guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
                socket.close()
            }
            await drain.value
            deadline.cancel()
            socket.close()
        }
    }
}
