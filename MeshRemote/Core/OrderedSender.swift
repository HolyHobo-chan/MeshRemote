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

    func finish() {
        continuation.finish()
        task.cancel()
    }
}
