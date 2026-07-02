import Foundation

/// UDS JSON-RPC client shared by the app, CLI, and MCP bridge. Request/response by id; a background
/// reader resolves pending calls and feeds the event stream. I/O goes through a `Transport` (default
/// `UDSTransport`) so the same client drives a local socket, an SSH-forwarded socket, or a future
/// WebSocket without change.
public final class ControlClient: @unchecked Sendable {
    public let source: ActivitySource
    private let makeTransport: @Sendable () -> Transport
    private var transport: Transport?
    private let writeLock = NSLock()

    private let stateLock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var eventContinuation: AsyncStream<Event>.Continuation?

    public private(set) var state: ConnectionState = .down
    /// Observed by the UI. Fired on every state change (off the caller's thread — hop to your actor).
    public var onState: (@Sendable (ConnectionState) -> Void)?

    /// Back-compat convenience: a UDS client by socket path.
    public convenience init(socketPath: String = Config.socketPath, source: ActivitySource = .app) {
        self.init(transport: { UDSTransport(socketPath: socketPath) }, source: source)
    }

    /// Designated init: a factory so reconnect can mint a FRESH transport each attempt.
    public init(transport: @escaping @Sendable () -> Transport, source: ActivitySource = .app) {
        self.makeTransport = transport
        self.source = source
    }

    private func setState(_ s: ConnectionState) {
        stateLock.withLock { state = s }
        onState?(s)
    }

    public func connect() throws {
        let t = makeTransport()
        setState(.connecting)
        try t.open()
        writeLock.withLock { transport = t }
        setState(.live)
        DispatchQueue.global().async { [weak self] in self?.readLoop() }
    }

    public func close() {
        // Guard `transport` with writeLock so we never tear it down under an in-flight `write`.
        let t: Transport? = writeLock.withLock { let x = transport; transport = nil; return x }
        t?.close()
        stateLock.withLock {
            for (_, c) in pending { c.resume(throwing: OrchestraError.io("connection closed")) }
            pending.removeAll()
            eventContinuation?.finish()
        }
        setState(.down)
    }

    // MARK: - calls

    @discardableResult
    public func call(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
        let id = stateLock.withLock { let i = nextId; nextId += 1; return i }
        let req = RPCRequest(id: id, method: method, params: params, source: source.rawValue)
        let line = try RPCCodec.line(req)
        return try await withCheckedThrowingContinuation { cont in
            stateLock.withLock { pending[id] = cont }
            let ok = writeLock.withLock { transport?.write(line) ?? false }
            if !ok {
                // Resume ONLY if we still own the pending entry. If `close()` raced in and already
                // resumed+removed it, `removeValue` returns nil and we skip — never double-resume
                // (which is a fatal continuation misuse).
                if let c = stateLock.withLock({ pending.removeValue(forKey: id) }) {
                    c.resume(throwing: OrchestraError.io("write failed"))
                }
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
            // Finish any prior stream before replacing it, so its consumer doesn't hang forever on a
            // continuation that will never yield or finish.
            stateLock.withLock {
                self.eventContinuation?.finish()
                self.eventContinuation = cont
            }
            _Concurrency.Task { try? await self.call("subscribe") }
        }
    }

    // MARK: - reader

    private func readLoop() {
        let t = writeLock.withLock { transport }
        while let line = t?.readLine() {
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
