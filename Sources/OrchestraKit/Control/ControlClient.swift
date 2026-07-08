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
    /// Idempotency guard (#4): true once a `connect()`/`connectAsync()` has a live read/reconnect loop
    /// running. A second connect while one is live is a no-op — without this, it would leak the current
    /// transport and spawn a duplicate `runLoop`, delivering every event twice forever. Reset on a failed
    /// first open (so `start()`'s retry loop can re-attempt) and on `close()`.
    private var started = false

    public private(set) var state: ConnectionState = .down
    /// Observed by the UI. Fired on every state change (off the caller's thread — hop to your actor).
    public var onState: (@Sendable (ConnectionState) -> Void)?
    /// Fired after a successful RE-connect (a drop → backoff → re-open, NOT the first connect), once the
    /// re-subscribe has been issued. The one "re-assert on reconnect" hook (#1): the UI re-runs its full
    /// `refresh()` here so a daemon restart / link drop reconciles the board instead of silently going
    /// stale. Off the caller's thread — hop to your actor.
    public var onReconnect: (@Sendable () -> Void)?

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
    /// Idempotent (#4): a second call while a loop is already live is a no-op. Prefer `connectAsync()` on
    /// the @MainActor — this blocks the caller through the (possibly slow SSH) first `open()`.
    public func connect() throws {
        guard beginConnect() else { return }
        do { try openOnce() } catch { endFailedConnect(); throw error }
        launchRunLoop()
    }

    /// Async first-connect (#8): runs the blocking first `open()` — which for the SSH transport does two
    /// NIO `.wait()`s (TCP+SSH handshake, then channel open) — OFF the caller's thread, so an unreachable
    /// Mac never freezes the @MainActor (and onboarding "Test", which polls `state`, keeps updating).
    /// Same idempotency + throw-on-first-failure semantics as `connect()`.
    public func connectAsync() async throws {
        guard beginConnect() else { return }
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global().async { [weak self] in
                    guard let self else { cont.resume(throwing: OrchestraError.io("client deallocated")); return }
                    do { try self.openOnce(); cont.resume() }
                    catch { cont.resume(throwing: error) }
                }
            }
        } catch { endFailedConnect(); throw error }
        launchRunLoop()
    }

    /// Reserve the single-loop slot. Returns false (→ caller no-ops) if a loop is already live.
    private func beginConnect() -> Bool {
        stateLock.withLock {
            if started { return false }
            started = true; stopping = false
            return true
        }
    }
    /// Release the slot after a failed first `open()` so `start()`'s retry loop can re-attempt.
    private func endFailedConnect() { stateLock.withLock { started = false } }
    private func launchRunLoop() { DispatchQueue.global().async { [weak self] in self?.runLoop() } }

    /// One connection attempt: mint a fresh transport, open it, verify a real daemon answers a `version`
    /// probe, THEN publish `.live`. Throws on transport failure OR a live transport with a dead daemon
    /// behind it (#10: "SSH up, daemon down" — the exec-bridge connects but the daemon socket refuses, so
    /// the channel EOFs). Gating `.live` on the probe turns that into a clean open failure → backoff,
    /// instead of flapping `.live`→`.retrying` forever with no diagnosable reason (and stops onboarding
    /// "Test" from false-passing against a dead daemon).
    private func openOnce() throws {
        let t = makeTransport()
        setState(.connecting)
        try t.open()
        do { try probeVersion(on: t) }
        catch { t.close(); throw error }
        writeLock.withLock { transport = t }
        setState(.live)
    }

    /// Synchronous `version` round-trip on a freshly-opened transport, BEFORE the shared read loop owns
    /// it. Confirms a real daemon is behind the transport (not just an open socket / SSH channel). No
    /// subscription is active yet, so no events can interleave; any non-matching frame is ignored, and a
    /// closed stream (EOF before the reply) means the daemon never answered → throw.
    private func probeVersion(on t: Transport) throws {
        let id = stateLock.withLock { let i = nextId; nextId += 1; return i }
        let req = RPCRequest(id: id, method: "version", params: nil, source: source.rawValue, clientId: clientId)
        guard t.write(try RPCCodec.line(req)) else { throw OrchestraError.io("version probe write failed") }
        while let line = t.readLine() {
            guard !line.isEmpty,
                  let msg = try? RPCCodec.decoder.decode(WireMessage.self, from: line) else { continue }
            if msg.id == id {
                if let err = msg.error { throw err }
                return                                  // daemon answered → it's alive
            }
            // ignore any other frame during the probe (nothing is subscribed yet)
        }
        throw OrchestraError.io("daemon did not answer version probe (connection closed)")
    }

    public func close() {
        stateLock.withLock { stopping = true; started = false }
        // Wake the reader by SHUTTING DOWN the transport, NOT closing it: on Linux `close(2)` won't
        // unblock a thread parked in `read(2)` (→ leaked reader thread), and closing an fd the reader
        // still holds risks recycled-fd cross-wiring. The runLoop reader owns the actual `close()` (see
        // `closeTransport()`), so we leave `transport` set here — the reader must still find and close it.
        let t = writeLock.withLock { transport }
        t?.shutdown()
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

    /// One-round-trip board snapshot: tasks + archived + config + models + agents + every active card's
    /// shell sessions + agent-terminal owner. The bulk form of `list`+`archivedList`+`getConfig`+`models`+
    /// `agents` and the per-card `sessions`/`agentTerminalOwner` fan-out — collapsing ~2N round trips on
    /// every (re)connect into one, and (issued right after `subscribe`) closing the snapshot/subscribe gap.
    public func boardSnapshot() async throws -> BoardSnapshot {
        try await call("boardSnapshot", .object([:]), as: BoardSnapshot.self)
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

    /// Typed convenience over the `spawnRepos` verb — absolute paths to the git repos under the daemon's
    /// reposRoot, which also serve as the freeform dir candidates, for the Spawn sheet's repo/dir pickers.
    /// The phone can't browse the daemon's disk, so the daemon enumerates for it.
    public func spawnRepos() async throws -> [String] {
        try await call("spawnRepos", as: [String].self)
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
    public func registerDevice(token: String, prefs: NotifyPrefsSnapshot) async throws -> DeviceRegistration {
        let reg = DeviceRegistration(token: token, clientId: clientId ?? "", prefs: prefs)
        return try await call("registerDevice", try JSONValue(encodable: reg), as: DeviceRegistration.self)
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
            // The runLoop thread OWNS the current transport's close (reader-owns-close). Every exit path
            // closes whatever transport is live so a `close()` that only `shutdown()`s can't leak the fd —
            // including the case where `stopping` was set before this loop began reading.
            if stateLock.withLock({ stopping }) { closeTransport(); return }
            readUntilEOF()                                   // returns when the current transport hits EOF
            failPending()
            if stateLock.withLock({ stopping }) { return }   // readUntilEOF already closed the transport
            setState(.retrying)
            // Backoff-reconnect until success or an explicit close().
            while true {
                if stateLock.withLock({ stopping }) { closeTransport(); setState(.down); return }
                let ms = Self.backoffMillis(attempt); attempt += 1
                Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
                if stateLock.withLock({ stopping }) { closeTransport(); setState(.down); return }
                do {
                    try openOnce()
                    attempt = 0
                    // Re-subscribe FIRST (so the daemon re-registers us before we snapshot), then fire the
                    // re-assert hook (#1) — the UI re-runs `refresh()` here, reconciling a board that would
                    // otherwise stay silently stale after a daemon restart / link drop.
                    if stateLock.withLock({ subscribed }) { _Concurrency.Task { try? await self.call("subscribe") } }
                    onReconnect?()
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
        // EOF: the reader owns the close. Drop the dead transport so the next openOnce() replaces it
        // cleanly, and release its fd HERE (on the reader thread) — never from a writer/teardown thread.
        closeTransport()
    }

    /// Reader-owned teardown of the current transport: atomically take it out of the shared slot and
    /// `close()` it. Idempotent (nil-safe; `Transport.close()` guards a already-closed fd). Only the
    /// runLoop (reader) thread calls this — teardown/writer threads call `Transport.shutdown()` instead,
    /// which wakes the reader so IT reaches here and closes.
    private func closeTransport() {
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
