import Foundation

/// UDS JSON-RPC server in the daemon. Dispatches the `CommandRegistry` (+ subscribe/getConfig/
/// setConfig/ping/version/report), pushes `Event` notifications, and keeps a bounded activity ring
/// buffer that `subscribe()` replays to a newly-connected client.
public final class ControlServer: @unchecked Sendable {
    let service: OrchestraService
    let registry = CommandRegistry()
    let socketPath: String
    public var onConfigChanged: (@Sendable (Config) -> Void)?
    /// Fired once per connection teardown with the connection's clientId (nil-clientId connections
    /// never fire). D4 wires its ownership lease here to mark a disconnected client's leases stale.
    public var onClientDisconnect: (@Sendable (String) -> Void)?

    private var serverFd: Int32 = -1
    private let lock = NSLock()
    private var subscribers: [Int32: PeerConnection] = [:]
    private var ring: [ActivityItem] = []
    private let ringCap = 200
    private let acceptQueue = DispatchQueue(label: "orchestra.accept")

    public init(service: OrchestraService, socketPath: String = Config.socketPath) {
        self.service = service
        self.socketPath = socketPath
    }

    /// Bind + start the event pump + accept loop. Returns once listening (serving continues async).
    public func start() throws {
        serverFd = try UDS.listen(path: socketPath)
        // Event pump: fan service events out to subscribers; ring-buffer activity.
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            for await event in await self.service.subscribe() {
                self.handleEvent(event)
            }
        }
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        // Take and clear serverFd under the lock so acceptLoop never reads it concurrently with this
        // close (which would risk acting on a closed/reused fd).
        let fd = lock.withLock { let f = serverFd; serverFd = -1; return f }
        if fd >= 0 { closeFD(fd) }
        unlink(socketPath)
    }

    // MARK: - accept / connections

    private func acceptLoop() {
        while true {
            let fd = lock.withLock { serverFd }
            if fd < 0 { break }
            let conn = UDS.accept(fd)
            if conn < 0 {
                // accept() returns -1 when stop() closes the listener — exit then; otherwise a
                // transient error, so loop (re-reading serverFd avoids a busy-spin after shutdown).
                if lock.withLock({ serverFd }) < 0 { break }
                continue
            }
            let c = PeerConnection(fd: conn)
            DispatchQueue.global().async { [weak self] in self?.serve(c) }
        }
    }

    private func serve(_ conn: PeerConnection) {
        let reader = LineReader(fd: conn.fd)
        while let line = reader.next() {
            guard !line.isEmpty else { continue }
            guard let req = try? RPCCodec.decoder.decode(RPCRequest.self, from: line) else {
                conn.enqueue((try? RPCCodec.line(RPCResponse(id: nil, result: nil,
                    error: RPCError(code: -32700, message: "parse error")))) ?? Data())
                continue
            }
            _Concurrency.Task { [weak self] in await self?.handle(req, conn) }
        }
        handleDisconnect(conn)
    }

    // MARK: - dispatch

    private func handle(_ req: RPCRequest, _ conn: PeerConnection) async {
        if let cid = req.clientId { conn.setClientId(cid) }
        let source = ActivitySource(rawValue: req.source ?? "app") ?? .app
        do {
            let result = try await dispatch(req, conn, source: source)
            if let id = req.id {
                conn.enqueue((try? RPCCodec.line(RPCResponse(id: id, result: result))) ?? Data())
            }
        } catch let e as OrchestraError {
            if let id = req.id {
                conn.enqueue((try? RPCCodec.line(RPCResponse(id: id, result: nil,
                    error: RPCError(code: e.code, message: e.description)))) ?? Data())
            }
        } catch let e as RPCError {
            if let id = req.id {
                conn.enqueue((try? RPCCodec.line(RPCResponse(id: id, result: nil, error: e))) ?? Data())
            }
        } catch {
            if let id = req.id {
                conn.enqueue((try? RPCCodec.line(RPCResponse(id: id, result: nil,
                    error: RPCError(code: -32000, message: "\(error)")))) ?? Data())
            }
        }
    }

    private func dispatch(_ req: RPCRequest, _ conn: PeerConnection, source: ActivitySource) async throws -> JSONValue {
        switch req.method {
        case "ping":    return .object(["ok": .bool(true)])
        case "version": return .object(["version": .string(OrchestraVersion.current)])
        case "subscribe":
            conn.isSubscriber = true
            conn.onBroken = { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.handleDisconnect(conn)
            }
            // Register + replay the ring under one lock (paired with handleEvent's lock) so live
            // delivery and history replay can't duplicate or reorder. enqueue() only appends to the
            // connection's serial queue, so holding the lock is cheap.
            lock.withLock {
                subscribers[conn.fd] = conn
                for item in ring {
                    conn.enqueue((try? RPCCodec.line(eventNotification(.activity(item)))) ?? Data())
                }
            }
            return .object(["ok": .bool(true)])
        case "getConfig":
            return try JSONValue(encodable: await service.getConfig())
        case "setConfig":
            guard let p = req.params else { throw OrchestraError.invalidParams("missing config") }
            let newConfig = try p.decode(Config.self)
            await service.setConfig { $0 = newConfig }
            onConfigChanged?(newConfig)
            return try JSONValue(encodable: newConfig)
        case "models":
            return try JSONValue(encodable: await service.models(agentId: req.params?.optString("agentId")))
        case "agents":
            return try JSONValue(encodable: await service.agents())
        case "archivedList":
            return try JSONValue(encodable: await service.archivedTasks())
        case "openInZed":
            guard let p = req.params, let ref = p.optString("ref") else {
                throw OrchestraError.invalidParams("openInZed needs ref")
            }
            let task = try await service.resolveRef(ref)
            try await service.openInZed(task.id)
            return .object(["ok": .bool(true)])
        case "openNotes":
            guard let p = req.params, let ref = p.optString("ref") else {
                throw OrchestraError.invalidParams("openNotes needs ref")
            }
            let task = try await service.resolveRef(ref)
            let n = try await service.openNotes(task.id)
            return .object(["ok": .bool(true), "opened": .int(n.opened), "total": .int(n.total)])
        case "hook":
            // The unified hook channel: the `_report` edge sends a TYPED event (already parsed at the
            // edge); the daemon dispatches both directions (apply telemetry + compose orientation/drain)
            // and returns an optional HookResponse to print. Replaces the old report/drain/sessionBrief
            // RPCs. Internal plumbing — NOT a registry Command.
            guard let p = req.params, let ref = p.optString("ref"),
                  let kind = p.optString("event"), let event = HookEvent(rawValue: kind) else {
                throw OrchestraError.invalidParams("hook needs ref + event")
            }
            let report = p["report"].flatMap { try? $0.decode(StatusReport.self) }
            let source = p.optString("source").flatMap(SessionSource.init(rawValue:))
            let resp = await service.handleHook(ref, event: event, report: report, source: source)
            if let resp { return .object(["response": try JSONValue(encodable: resp)]) }
            return .object(["response": .null])
        case "diffText":
            // Code review on the board (axis 7): the inspector's rendered diff. Internal + app-only —
            // NOT a registry Command, so it never surfaces as an MCP tool (agents run `git diff`).
            guard let p = req.params, let ref = p.optString("ref") else {
                throw OrchestraError.invalidParams("diffText needs ref")
            }
            let task = try await service.resolveRef(ref)
            let base = DiffBase(rawValue: p.optString("base") ?? "branch") ?? .branch
            return .string(try await service.diffText(task.id, base: base))
        case "diffStat":
            // Recompute + return the footer diffstat (on-selection refresh). Internal + app-only.
            guard let p = req.params, let ref = p.optString("ref") else {
                throw OrchestraError.invalidParams("diffStat needs ref")
            }
            let task = try await service.resolveRef(ref)
            let base = DiffBase(rawValue: p.optString("base") ?? "branch") ?? .branch
            let stat = try await service.diffStat(task.id, base: base)
            return try stat.map { try JSONValue(encodable: $0) } ?? .null
        case "agentTerminalOwner":
            // App/phone UI coordination — internal + app-only, NOT a registry Command (an agent must
            // never take over a terminal). Ephemeral lease; nothing is persisted to the task store.
            guard let p = req.params, let ref = p.optString("ref") else {
                throw OrchestraError.invalidParams("agentTerminalOwner needs ref")
            }
            return try JSONValue(encodable: await service.agentTerminalOwner(ref))
        case "takeOverAgentTerminal":
            guard let p = req.params, let ref = p.optString("ref"),
                  let clientId = p.optString("clientId"),
                  let kind = p.optString("kind").flatMap(AgentTerminalOwnerKind.init(rawValue:)) else {
                throw OrchestraError.invalidParams("takeOverAgentTerminal needs ref, clientId, kind")
            }
            return try JSONValue(encodable:
                await service.takeOverAgentTerminal(ref, clientId: clientId, kind: kind))
        case "releaseAgentTerminal":
            guard let p = req.params, let ref = p.optString("ref"),
                  let clientId = p.optString("clientId"), let epoch = p.optInt("epoch") else {
                throw OrchestraError.invalidParams("releaseAgentTerminal needs ref, clientId, epoch")
            }
            return try JSONValue(encodable:
                try await service.releaseAgentTerminal(ref, clientId: clientId, epoch: epoch))
        case "heartbeatAgentTerminal":
            guard let p = req.params, let ref = p.optString("ref"),
                  let clientId = p.optString("clientId"), let epoch = p.optInt("epoch") else {
                throw OrchestraError.invalidParams("heartbeatAgentTerminal needs ref, clientId, epoch")
            }
            return try JSONValue(encodable:
                try await service.heartbeatAgentTerminal(ref, clientId: clientId, epoch: epoch))
        default:
            guard let cmd = registry.command(req.method) else {
                throw RPCError(code: -32601, message: "method not found: \(req.method)")
            }
            return try await cmd.run(service, req.params ?? .object([:]), source)
        }
    }

    // MARK: - events

    private func handleEvent(_ event: Event) {
        let line = (try? RPCCodec.line(eventNotification(event))) ?? Data()
        // Append-to-ring and the subscriber snapshot happen under one lock so a concurrent
        // `subscribe` either fully replays this event from the ring (and never delivers it live too)
        // or registers in time to receive it live — never both, never out of order.
        let conns: [PeerConnection] = lock.withLock {
            if case .activity(let item) = event {
                ring.append(item)
                if ring.count > ringCap { ring.removeFirst(ring.count - ringCap) }
            }
            return Array(subscribers.values)
        }
        // enqueue() is non-blocking, so a slow/stuck client can't stall delivery to the others; a
        // failed write fires the connection's `onBroken` to drop it.
        for c in conns { c.enqueue(line) }
    }

    /// A proper JSON-RPC notification: `{method:"event", params:<Event>}`.
    private func eventNotification(_ event: Event) -> RPCNotification {
        RPCNotification(method: "event", params: try? JSONValue(encodable: event))
    }

    private func removeSubscriber(_ conn: PeerConnection) { _ = lock.withLock { subscribers.removeValue(forKey: conn.fd) } }

    /// Snapshot of the clientIds with at least one live subscriber connection. D4 uses this for
    /// liveness. NOTE: a reconnecting client briefly disappears here (old connection torn down before
    /// the new one subscribes), so D4 must use a heartbeat grace window, not treat absence as loss.
    public func connectedClientIds() -> Set<String> {
        lock.withLock { Set(subscribers.values.compactMap { $0.clientId }) }
    }

    /// Single teardown path for a dropped connection: drop it as a subscriber, close it, and fire
    /// `onClientDisconnect` once if it had a known clientId. Reached from the read-loop EOF and from a
    /// broken write; the once-guard keeps the callback single-shot.
    private func handleDisconnect(_ conn: PeerConnection) {
        removeSubscriber(conn)
        conn.close()
        if let cid = conn.clientId, conn.markDisconnectNotified() {
            onClientDisconnect?(cid)
        }
    }
}

/// A single client connection with a serial, non-blocking writer. All writes (responses + events)
/// go through one per-connection serial queue, so frames stay ordered and a slow/stuck client only
/// backs up its own queue — never the shared event pump.
final class PeerConnection: @unchecked Sendable {
    let fd: Int32
    var isSubscriber = false
    /// Fired once, off the event pump, when a queued write fails — lets the server drop a dead
    /// subscriber without ever blocking on it.
    var onBroken: (@Sendable () -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var closed = false
    private var broken = false
    private var _clientId: String?
    private var disconnectNotified = false

    /// The caller's stable per-install identity (D3). Set once from the first request that carries a
    /// clientId; nil for anonymous CLI/MCP connections. Read by the ownership lease (D4).
    var clientId: String? { lock.withLock { _clientId } }

    /// Record the connection's clientId. Idempotent: a client sends the same id on every request, so
    /// only the first non-nil set sticks.
    func setClientId(_ id: String) { lock.withLock { if _clientId == nil { _clientId = id } } }

    /// Returns true exactly once, so the server fires `onClientDisconnect` a single time even though
    /// teardown can be reached from both the read-loop EOF and a broken write.
    func markDisconnectNotified() -> Bool {
        lock.withLock { if disconnectNotified { return false }; disconnectNotified = true; return true }
    }

    init(fd: Int32) {
        self.fd = fd
        self.queue = DispatchQueue(label: "orchestra.conn.\(fd)")
    }

    /// Enqueue a frame for ordered delivery. Returns immediately; the actual `write(2)` happens on
    /// the connection's serial queue. A failed write marks the connection broken and fires
    /// `onBroken` exactly once.
    func enqueue(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let skip = self.closed || self.broken
            self.lock.unlock()
            if skip { return }
            if !UDS.writeAll(self.fd, data) {
                self.lock.lock(); let first = !self.broken; self.broken = true; self.lock.unlock()
                if first { self.onBroken?() }
            }
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if !closed { closeFD(fd); closed = true }
    }
}

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
