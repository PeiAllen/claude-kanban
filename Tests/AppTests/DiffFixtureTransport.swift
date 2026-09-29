import Foundation
import OrchestraCore

/// Replaces only RPC transport; the mounted inspector and renderer remain production views.
/// No real socket, daemon, repository, or agent session is opened by the GUI checks.
final class DiffFixtureTransport: Transport, @unchecked Sendable {
    private let condition = NSCondition()
    private var queue: [Data] = []
    private var closed = false
    private let fixture: String

    init(fixture: String) { self.fixture = fixture }
    func open() throws {}

    func write(_ data: Data) -> Bool {
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = request["id"], let method = request["method"] as? String else { return false }
        let result: Any = method == "diffText" ? fixture : [:]
        guard let reply = try? JSONSerialization.data(withJSONObject: ["id": id, "result": result]) else { return false }
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return false }
        queue.append(reply)
        condition.signal()
        return true
    }

    func readLine() -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty && !closed { condition.wait() }
        return closed ? nil : queue.removeFirst()
    }

    func shutdown() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func close() { shutdown() }
}
