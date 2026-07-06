import Foundation

/// UDS JSON-RPC client shared by the app, CLI, and MCP bridge. Request/response by id; a background
/// reader resolves pending calls and feeds the event stream. I/O goes through a `Transport` (default
/// `UDSTransport`) so the same client drives a local socket, an SSH-forwarded socket, or a future
/// WebSocket without change. A dropped transport triggers backoff → reconnect → re-subscribe rather
/// than dying; `state`/`onState` surface the live connection state for the UI to bind.
public final class ControlClient: @unchecked Sendable {
    public let source: ActivitySource
    /// Stable per-install identity stamped on every request (D3). Immutable per instance, so a reconnect
    /// re-subscribes with the SAME id; nil for anonymous callers (CLI/MCP), which send no clientId.
    public let clientId: String?
    private let makeTransport: @Sendable () -> Transport
    private var transport: Transport?
    private let writeLock = NSLock()

    private let stateLock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var eventContinuation: AsyncStream<Event>.Continuation?
    private var subscribed = false
    private var stopping = false

    public private(set) var state: ConnectionState = .down
    /// Observed by the UI. Fired on every state change (off the caller's thread — hop to your actor).
    public var onState: (@Sendable (ConnectionState) -> Void)?

    /// Back-compat convenience: a UDS client by socket path.
    public convenience init(socketPath: String = Config.socketPath, source: ActivitySource = .app,
                            clientId: String? = nil) {
        self.init(transport: { UDSTransport(socketPath: socketPath) }, source: source, clientId: clientId)
    }

    /// Designated init: a factory so reconnect can mint a FRESH transport each attempt.
    public init(transport: @escaping @Sendable () -> Transport, source: ActivitySource = .app,
                clientId: String? = nil) {
        self.makeTransport = transport
        self.source = source
        self.clientId = clientId
    }

    private func setState(_ s: ConnectionState) {
        stateLock.withLock { state = s }
        onState?(s)
    }

    /// Connect + start the read/reconnect loop. The first connect is synchronous so callers still get an
    /// immediate throw on a hard first failure; after that, drops are handled transparently by the loop.
    public func connect() throws {
        stateLock.withLock { stopping = false }
        try openOnce()
        DispatchQueue.global().async { [weak self] in self?.runLoop() }
    }

    /// One connection attempt: mint a fresh transport, open it, publish `.live`. Throws on failure.
    private func openOnce() throws {
        let t = makeTransport()
        setState(.connecting)
        try t.open()
        writeLock.withLock { transport = t }
        setState(.live)
    }

    public func close() {
        stateLock.withLock { stopping = true }
        // Guard `transport` with writeLock so we never tear it down under an in-flight `write`. Closing it
        // also unblocks the reader (readLine → nil), so the loop can observe `stopping` and exit.
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
        let req = RPCRequest(id: id, method: method, params: params, source: source.rawValue, clientId: clientId)
        let line = try RPCCodec.line(req)
        return try await withCheckedThrowingContinuation { cont in
            stateLock.withLock { pending[id] = cont }
            let ok = writeLock.withLock { transport?.write(line) ?? false }
            if !ok {
                // Resume ONLY if we still own the pending entry. If `close()`/a drop raced in and already
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

    // MARK: - Agent-terminal ownership (app/phone UI coordination)

    public func agentTerminalOwner(_ ref: String) async throws -> AgentTerminalOwnerState {
        try await call("agentTerminalOwner", .object(["ref": .string(ref)]),
                       as: AgentTerminalOwnerState.self)
    }

    public func takeOverAgentTerminal(_ ref: String, clientId: String,
                                      kind: AgentTerminalOwnerKind) async throws -> TakeOverResult {
        try await call("takeOverAgentTerminal", .object([
            "ref": .string(ref), "clientId": .string(clientId), "kind": .string(kind.rawValue),
        ]), as: TakeOverResult.self)
    }

    public func releaseAgentTerminal(_ ref: String, clientId: String,
                                     epoch: Int) async throws -> AgentTerminalOwnerState {
        try await call("releaseAgentTerminal", .object([
            "ref": .string(ref), "clientId": .string(clientId), "epoch": .int(epoch),
        ]), as: AgentTerminalOwnerState.self)
    }

    public func heartbeatAgentTerminal(_ ref: String, clientId: String,
                                       epoch: Int) async throws -> AgentTerminalOwnerState {
        try await call("heartbeatAgentTerminal", .object([
            "ref": .string(ref), "clientId": .string(clientId), "epoch": .int(epoch),
        ]), as: AgentTerminalOwnerState.self)
    }

    /// Typed convenience over the `capture` verb — a non-attaching, read-only pane snapshot. The
    /// phone Agent tab's v1 read source.
    public func capture(_ ref: String, window: String = "agent") async throws -> CaptureResult {
        try await call("capture", .object(["ref": .string(ref), "window": .string(window)]),
                       as: CaptureResult.self)
    }

    /// Typed convenience over the `changedNotes` verb — the markdown notes a card's branch changed/added,
    /// each with content, for the phone's Notes page (M6). Empty for a non-worktree card.
    public func changedNotes(_ ref: String) async throws -> [NoteFile] {
        try await call("changedNotes", .object(["ref": .string(ref)]), as: [NoteFile].self)
    }

    /// Typed convenience over the `spawnRepos` verb — git repos under the daemon's reposRoot + freeform
    /// dir candidates, for the Spawn sheet's repo/dir pickers. The phone can't browse the daemon's disk,
    /// so the daemon enumerates for it.
    public func spawnRepos() async throws -> SpawnRepos {
        try await call("spawnRepos", as: SpawnRepos.self)
    }

    /// Typed convenience over the `spawnBranches` verb — local git branches for `repo`, most-recent
    /// first. Empty when the repo has no branches / isn't a git repo (the picker degrades to free text).
    public func spawnBranches(repo: String) async throws -> [String] {
        try await call("spawnBranches", .object(["repo": .string(repo)]), as: [String].self)
    }

    /// Typed convenience over the `listDir` verb — a directory's children for the Spawn sheet's remote
    /// directory browser (the phone can't browse the daemon's disk). Confined to the daemon's browse
    /// roots. `path` nil/empty → the root listing. Throws `pathNotAllowed` if the path escapes the roots.
    public func listDir(path: String?) async throws -> DirListing {
        try await call("listDir", .object(["path": .string(path ?? "")]), as: DirListing.self)
    }

    /// Send a constrained key chord to a card's tmux window (default `agent`). Convenience over the
    /// `send-keys` verb — encodes the typed chord to the wire form. Distinct from queuing to the inbox
    /// (`send`): live keystrokes, no implicit Enter (submitting needs an explicit `.named(.enter)`).
    public func sendKeys(ref: String, _ chord: [KeyToken], window: String = "agent") async throws {
        _ = try await call("send-keys", .object([
            "ref": .string(ref),
            "keys": try JSONValue(encodable: chord),
            "window": .string(window),
        ]))
    }

    /// Register this device for push (N1): hand the APNs device token + the current notification-pref
    /// snapshot to the daemon so it can deliver attention pushes while the phone is backgrounded. Called
    /// after `registerForRemoteNotifications` yields a token, and re-called whenever prefs change. Keyed
    /// by `clientId` daemon-side; a re-register replaces the prior entry.
    @discardableResult
    public func registerDevice(token: String, prefs: NotifyPrefsSnapshot,
                               platform: String = "ios") async throws -> DeviceRegistration {
        let reg = DeviceRegistration(token: token, clientId: clientId ?? "", platform: platform, prefs: prefs)
        return try await call("registerDevice", try JSONValue(encodable: reg), as: DeviceRegistration.self)
    }

    /// Drop this device's push registration (notifications revoked / sign-out).
    public func unregisterDevice() async throws {
        _ = try await call("unregisterDevice", .object(["clientId": .string(clientId ?? "")]))
    }

    /// Subscribe to the daemon's event stream (task upserts/removals + activity). Sends the subscribe
    /// request and returns a live stream. The stream persists across reconnects — only `close()` ends it;
    /// on reconnect the client re-issues the subscribe RPC so the same stream keeps receiving events.
    public func subscribe() -> AsyncStream<Event> {
        AsyncStream { cont in
            // Finish any prior stream before replacing it, so its consumer doesn't hang forever on a
            // continuation that will never yield or finish.
            stateLock.withLock {
                self.eventContinuation?.finish()
                self.eventContinuation = cont
                self.subscribed = true
            }
            _Concurrency.Task { try? await self.call("subscribe") }
        }
    }

    // MARK: - read / reconnect loop

    private func runLoop() {
        var attempt = 0
        while true {
            if stateLock.withLock({ stopping }) { return }
            readUntilEOF()                                   // returns when the current transport hits EOF
            failPending()
            if stateLock.withLock({ stopping }) { return }   // close() already published .down
            setState(.retrying)
            // Backoff-reconnect until success or an explicit close().
            while true {
                if stateLock.withLock({ stopping }) { setState(.down); return }
                let ms = Self.backoffMillis(attempt); attempt += 1
                Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
                if stateLock.withLock({ stopping }) { setState(.down); return }
                do {
                    try openOnce()
                    attempt = 0
                    if stateLock.withLock({ subscribed }) { _Concurrency.Task { try? await self.call("subscribe") } }
                    break
                } catch { setState(.retrying); continue }
            }
        }
    }

    /// Read pump for the CURRENT transport; returns on EOF. Does NOT close the client or finish the event
    /// stream — a transient drop must not end a live subscription.
    private func readUntilEOF() {
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
        // EOF: drop the dead transport so the next openOnce() replaces it cleanly.
        let dead: Transport? = writeLock.withLock { let x = transport; transport = nil; return x }
        dead?.close()
    }

    /// Fail every in-flight call so awaiters don't hang across a reconnect.
    private func failPending() {
        let conts = stateLock.withLock { () -> [CheckedContinuation<JSONValue, Error>] in
            let cs = Array(pending.values); pending.removeAll(); return cs
        }
        for c in conts { c.resume(throwing: OrchestraError.io("connection dropped")) }
    }

    /// Exponential backoff (250ms → 5s cap) with attempt-derived jitter — no Date/random (unavailable in
    /// some sandboxes), so it stays deterministic and resume-safe.
    static func backoffMillis(_ attempt: Int) -> Int {
        let base = min(5000, 250 * (1 << min(attempt, 5)))       // 250,500,1000,2000,4000,5000…
        let jitter = base / 5
        let sign = attempt % 2 == 0 ? 1 : -1
        return max(50, base + sign * (jitter * (attempt % 3)) / 3)
    }
}
