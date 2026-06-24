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
    private var subscribers: [Int32: Connection] = [:]
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
        if serverFd >= 0 { close(serverFd); serverFd = -1 }
        unlink(socketPath)
    }

    // MARK: - accept / connections

    private func acceptLoop() {
        while serverFd >= 0 {
            let fd = UDS.accept(serverFd)
            if fd < 0 { continue }
            let conn = Connection(fd: fd)
            DispatchQueue.global().async { [weak self] in self?.serve(conn) }
        }
    }

    private func serve(_ conn: Connection) {
        let reader = LineReader(fd: conn.fd)
        while let line = reader.next() {
            guard !line.isEmpty else { continue }
            guard let req = try? RPCCodec.decoder.decode(RPCRequest.self, from: line) else {
                conn.write((try? RPCCodec.line(RPCResponse(id: nil, result: nil,
                    error: RPCError(code: -32700, message: "parse error")))) ?? Data())
                continue
            }
            _Concurrency.Task { [weak self] in await self?.handle(req, conn) }
        }
        removeSubscriber(conn)
        conn.close()
    }

    // MARK: - dispatch

    private func handle(_ req: RPCRequest, _ conn: Connection) async {
        let source = ActivitySource(rawValue: req.source ?? "app") ?? .app
        do {
            let result = try await dispatch(req, conn, source: source)
            if let id = req.id {
                conn.write(try RPCCodec.line(RPCResponse(id: id, result: result)))
            }
        } catch let e as OrchestraError {
            if let id = req.id {
                conn.write((try? RPCCodec.line(RPCResponse(id: id, result: nil,
                    error: RPCError(code: e.code, message: e.description)))) ?? Data())
            }
        } catch let e as RPCError {
            if let id = req.id {
                conn.write((try? RPCCodec.line(RPCResponse(id: id, result: nil, error: e))) ?? Data())
            }
        } catch {
            if let id = req.id {
                conn.write((try? RPCCodec.line(RPCResponse(id: id, result: nil,
                    error: RPCError(code: -32000, message: "\(error)")))) ?? Data())
            }
        }
    }

    private func dispatch(_ req: RPCRequest, _ conn: Connection, source: ActivitySource) async throws -> JSONValue {
        switch req.method {
        case "ping":    return .object(["ok": .bool(true)])
        case "version": return .object(["version": .string(OrchestraVersion.current)])
        case "subscribe":
            conn.isSubscriber = true
            addSubscriber(conn)
            // Replay the activity ring buffer to the freshly-connected client.
            let snapshot = lock.withLock { ring }
            for item in snapshot {
                conn.write((try? RPCCodec.line(eventNotification(.activity(item)))) ?? Data())
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
            return try JSONValue(encodable: await service.models())
        case "archivedList":
            return try JSONValue(encodable: await service.archivedTasks())
        case "openInZed":
            guard let p = req.params, let ref = p.optString("ref") else {
                throw OrchestraError.invalidParams("openInZed needs ref")
            }
            let task = try await service.resolveRef(ref)
            try await service.openInZed(task.id)
            return .object(["ok": .bool(true)])
        case "report":
            guard let p = req.params, let ref = p.optString("ref") else {
                throw OrchestraError.invalidParams("report needs ref")
            }
            let task = try await service.resolveRef(ref)
            let patch = try (p["report"] ?? p).decode(StatusReport.self)
            try await service.report(task.id, patch)
            return .object(["ok": .bool(true)])
        default:
            guard let cmd = registry.command(req.method) else {
                throw RPCError(code: -32601, message: "method not found: \(req.method)")
            }
            return try await cmd.run(service, req.params ?? .object([:]), source)
        }
    }

    // MARK: - events

    private func handleEvent(_ event: Event) {
        if case .activity(let item) = event {
            lock.withLock {
                ring.append(item)
                if ring.count > ringCap { ring.removeFirst(ring.count - ringCap) }
            }
        }
        let conns = lock.withLock { Array(subscribers.values) }
        let line = (try? RPCCodec.line(eventNotification(event))) ?? Data()
        for c in conns where !c.write(line) { removeSubscriber(c); c.close() }
    }

    /// A proper JSON-RPC notification: `{method:"event", params:<Event>}`.
    private func eventNotification(_ event: Event) -> RPCNotification {
        RPCNotification(method: "event", params: try? JSONValue(encodable: event))
    }

    private func addSubscriber(_ conn: Connection) { lock.withLock { subscribers[conn.fd] = conn } }
    private func removeSubscriber(_ conn: Connection) { _ = lock.withLock { subscribers.removeValue(forKey: conn.fd) } }
}

/// A single client connection with a serialized writer.
final class Connection: @unchecked Sendable {
    let fd: Int32
    var isSubscriber = false
    private let writeLock = NSLock()
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    @discardableResult
    func write(_ data: Data) -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        if closed { return false }
        return UDS.writeAll(fd, data)
    }

    func close() {
        writeLock.lock(); defer { writeLock.unlock() }
        if !closed { Darwin.close(fd); closed = true }
    }
}

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

#if canImport(Darwin)
import Darwin
#endif
