import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// UDS JSON-RPC client shared by the app, CLI, and MCP bridge. Request/response by id; a background
/// reader resolves pending calls and feeds the event stream.
public final class ControlClient: @unchecked Sendable {
    public let source: ActivitySource
    private let socketPath: String
    private var fd: Int32 = -1
    private let writeLock = NSLock()

    private let stateLock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var eventContinuation: AsyncStream<Event>.Continuation?

    public init(socketPath: String = Config.socketPath, source: ActivitySource = .app) {
        self.socketPath = socketPath
        self.source = source
    }

    public func connect() throws {
        fd = try UDS.connect(path: socketPath)
        DispatchQueue.global().async { [weak self] in self?.readLoop() }
    }

    public func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        stateLock.withLock {
            for (_, c) in pending { c.resume(throwing: OrchestraError.io("connection closed")) }
            pending.removeAll()
            eventContinuation?.finish()
        }
    }

    // MARK: - calls

    @discardableResult
    public func call(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
        let id = stateLock.withLock { let i = nextId; nextId += 1; return i }
        let req = RPCRequest(id: id, method: method, params: params, source: source.rawValue)
        let line = try RPCCodec.line(req)
        return try await withCheckedThrowingContinuation { cont in
            stateLock.withLock { pending[id] = cont }
            writeLock.lock(); let ok = UDS.writeAll(fd, line); writeLock.unlock()
            if !ok {
                stateLock.withLock { pending[id] = nil }
                cont.resume(throwing: OrchestraError.io("write failed"))
            }
        }
    }

    /// Typed call: decode the result into `T`.
    public func call<T: Decodable>(_ method: String, _ params: JSONValue? = nil, as type: T.Type) async throws -> T {
        let result = try await call(method, params)
        return try result.decode(T.self)
    }

    /// Subscribe to the daemon's event stream (task upserts/removals + activity). Sends the subscribe
    /// request and returns a live stream.
    public func subscribe() -> AsyncStream<Event> {
        AsyncStream { cont in
            stateLock.withLock { self.eventContinuation = cont }
            _Concurrency.Task { try? await self.call("subscribe") }
        }
    }

    // MARK: - reader

    private func readLoop() {
        let reader = LineReader(fd: fd)
        while let line = reader.next() {
            guard !line.isEmpty,
                  let msg = try? RPCCodec.decoder.decode(WireMessage.self, from: line) else { continue }
            if msg.method == "event" {
                if let event = try? msg.params?.decode(Event.self) {
                    stateLock.withLock { eventContinuation }?.yield(event)
                }
            } else if let id = msg.id {
                if let cont = stateLock.withLock({ pending.removeValue(forKey: id) }) {
                    if let err = msg.error { cont.resume(throwing: err) }
                    else { cont.resume(returning: msg.result ?? .null) }
                }
            }
        }
        close()
    }
}
