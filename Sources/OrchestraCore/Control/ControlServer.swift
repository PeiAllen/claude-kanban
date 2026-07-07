import Foundation

/// UDS JSON-RPC server in the daemon. Dispatches the `CommandRegistry` (+ subscribe/getConfig/
/// setConfig/ping/version/report), pushes `Event` notifications, and keeps a bounded activity ring
/// buffer that `subscribe()` replays to a newly-connected client.
public final class ControlServer: @unchecked Sendable {
    let service: OrchestraService
    let registry = CommandRegistry()
    let socketPath: String
    public var onConfigChanged: (@Sendable (Config) -> Void)?

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
        // The reader loop has ended (EOF): this thread owns the close.
        handleReaderEOF(conn)
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
            conn.onBroken = { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.handleBrokenWrite(conn)
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
            // No explicit base ⇒ the card's default baseline (parent-relative when stacked), matching the
            // report-funnel path so both writers persist a consistent footer stat.
            let base = p.optString("base").flatMap(DiffBase.init(rawValue:))
            let stat = try await service.diffStat(task.id, base: base)
            return try stat.map { try JSONValue(encodable: $0) } ?? .null
        case "changedNotes":
            // The phone's Notes page (M6): the markdown notes this branch changed/added, WITH content,
            // so the phone can render them in-app (the desktop's openNotes opens Obsidian, which the
            // phone lacks). Internal + app-only — NOT a registry Command (agents read notes off disk).
            guard let p = req.params, let ref = p.optString("ref") else {
                throw OrchestraError.invalidParams("changedNotes needs ref")
            }
            let task = try await service.resolveRef(ref)
            return try JSONValue(encodable: try await service.changedNotes(task.id))
        case "spawnRepos":
            // The phone's Spawn sheet (repo/dir autofill): git repos under reposRoot + freeform dir
            // candidates. Internal + app-only — NOT a registry Command, so it never becomes an MCP tool
            // (an agent spawns via `spawn`, it doesn't browse the daemon's disk). The desktop reads its
            // own disk directly; the phone can't, so the daemon enumerates for it.
            return try JSONValue(encodable: await service.spawnRepos())
        case "spawnBranches":
            // Local git branches for a chosen repo (Spawn sheet branch autofill). Internal + app-only.
            guard let p = req.params, let repo = p.optString("repo") else {
                throw OrchestraError.invalidParams("spawnBranches needs repo")
            }
            return try JSONValue(encodable: await service.spawnBranches(repo: repo))
        case "listDir":
            // The phone's Spawn-sheet directory browser: a directory's children (subdirs + files),
            // confined to the daemon's browse roots ($HOME + allowlist), dotfiles hidden. Internal +
            // app-only — NOT a registry Command, so it never becomes an MCP tool (an agent spawns via
            // `spawn`, it never browses the daemon's disk). nil/empty path → the root listing.
            let listPath = req.params?.optString("path")
            return try JSONValue(encodable: try await service.listDir(listPath))
        case "registerDevice":
            // The phone hands over its APNs device token + notification-pref snapshot (N1) so the daemon
            // can push attention alerts while the phone is backgrounded. Internal + app-only — NOT a
            // registry Command (agents never register for push). Keyed by clientId; re-register replaces.
            guard let p = req.params else { throw OrchestraError.invalidParams("registerDevice needs a registration") }
            let reg = try p.decode(DeviceRegistration.self)
            return try JSONValue(encodable: try await service.registerDevice(reg))
        case "unregisterDevice":
            guard let p = req.params, let clientId = p.optString("clientId") else {
                throw OrchestraError.invalidParams("unregisterDevice needs clientId")
            }
            try await service.unregisterDevice(clientId: clientId)
            return .object(["ok": .bool(true)])
        case "boardSnapshot":
            // Bulk board (re)paint in one round trip: tasks + archived + config + models + agents PLUS
            // every active card's shell sessions + agent-terminal owner. Collapses the client's
            // per-(re)connect fan-out (~2N round trips for N cards). Internal + app-only — NOT a registry
            // Command (agents poll `list`, not the whole board). Read-only; not logged (like `list`).
            return try JSONValue(encodable: await service.boardSnapshot())
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

    /// Reader (`serve`) EOF path: drop the subscriber and CLOSE the fd. The reader thread owns the close,
    /// so the fd is released only once nothing is reading it — no recycled-fd cross-wiring.
    private func handleReaderEOF(_ conn: PeerConnection) {
        removeSubscriber(conn)
        conn.close()
    }

    /// Broken-write / `onBroken` path (runs on the connection's writer queue, NOT the reader). Drop the
    /// subscriber so the event pump stops writing to it, then `shutdownRead()` to WAKE the blocked reader
    /// — which then reaches `handleReaderEOF` and owns the close. Never closes the fd here: closing an fd
    /// the reader still holds is exactly the recycled-fd cross-wiring this fix removes. Idempotent with
    /// the reader path (both guard on `closed`/`didShutdown`), so the two racing calls are safe.
    private func handleBrokenWrite(_ conn: PeerConnection) {
        removeSubscriber(conn)
        conn.shutdownRead()
    }
}

/// A single client connection with a serial, non-blocking writer. All writes (responses + events)
/// go through one per-connection serial queue, so frames stay ordered and a slow/stuck client only
/// backs up its own queue — never the shared event pump.
final class PeerConnection: @unchecked Sendable {
    let fd: Int32
    /// Fired once, off the event pump, when a queued write fails — lets the server drop a dead
    /// subscriber without ever blocking on it.
    var onBroken: (@Sendable () -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var closed = false
    private var didShutdown = false
    private var broken = false
    private var _clientId: String?

    /// The caller's stable per-install identity (D3). Set once from the first request that carries a
    /// clientId; nil for anonymous CLI/MCP connections. Read by the ownership lease (D4).
    var clientId: String? { lock.withLock { _clientId } }

    /// Record the connection's clientId. Idempotent: a client sends the same id on every request, so
    /// only the first non-nil set sticks.
    func setClientId(_ id: String) { lock.withLock { if _clientId == nil { _clientId = id } } }

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

    /// Wake the connection's blocked reader (`serve`'s `LineReader.next`) by half-closing the socket,
    /// WITHOUT releasing the fd. Called from the writer/`onBroken` path so the reader observes EOF and
    /// reaches its own `close()`. Idempotent; a no-op once closed. Never closing the fd here is what
    /// prevents recycled-fd cross-wiring: on Linux `closeFD` wouldn't even wake the reader, and on Darwin
    /// closing an fd the reader still holds lets a fresh `accept()` reuse the number under the zombie reader.
    func shutdownRead() {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !didShutdown else { return }
        didShutdown = true
        shutdownFD(fd)
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
