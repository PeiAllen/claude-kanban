import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct OTLPTraceObservation: Equatable, Sendable {
    public let cardId: UUID
    public let sessionEpoch: Int
    public let raw: RawTelemetry

    public init(cardId: UUID, sessionEpoch: Int, raw: RawTelemetry) {
        self.cardId = cardId
        self.sessionEpoch = sessionEpoch
        self.raw = raw
    }
}

/// Minimal OTLP/HTTP JSON decoder. An export request contains ended spans only; Orchestra keeps the one
/// provider root that closes a top-level turn and drops every child span before it reaches an adapter.
enum OTLPTraceDecoder {
    static func decode(_ data: Data, cardId: UUID, sessionEpoch: Int) throws -> [OTLPTraceObservation] {
        let root = try JSONValue.parse(data)
        guard let resourceSpans = root["resourceSpans"]?.arrayValue else {
            throw OrchestraError.invalidParams("OTLP trace export is missing resourceSpans")
        }

        var result: [OTLPTraceObservation] = []
        for resourceSpan in resourceSpans {
            let resourceAttributes = attributes(resourceSpan["resource"]?["attributes"])
            let scopes = resourceSpan["scopeSpans"]?.arrayValue
                ?? resourceSpan["instrumentationLibrarySpans"]?.arrayValue
                ?? []
            for scope in scopes {
                for span in scope["spans"]?.arrayValue ?? [] {
                    guard span["name"]?.stringValue == "claude_code.interaction" else { continue }
                    var merged = resourceAttributes
                    merged.merge(attributes(span["attributes"])) { _, spanValue in spanValue }
                    result.append(.init(
                        cardId: cardId,
                        sessionEpoch: sessionEpoch,
                        raw: .traceSpanEnded(name: "claude_code.interaction", attributes: .object(merged))
                    ))
                }
            }
        }
        return result
    }

    private static func attributes(_ value: JSONValue?) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for item in value?.arrayValue ?? [] {
            guard let key = item["key"]?.stringValue,
                  let raw = item["value"],
                  let decoded = anyValue(raw)
            else { continue }
            result[key] = decoded
        }
        return result
    }

    private static func anyValue(_ value: JSONValue) -> JSONValue? {
        if let string = value["stringValue"]?.stringValue { return .string(string) }
        if let bool = value["boolValue"]?.boolValue { return .bool(bool) }
        if let integer = value["intValue"]?.intValue { return .int(integer) }
        if let text = value["intValue"]?.stringValue, let integer = Int(text) { return .int(integer) }
        if let double = value["doubleValue"]?.doubleValue { return .double(double) }
        if let values = value["arrayValue"]?["values"]?.arrayValue {
            return .array(values.compactMap(anyValue))
        }
        if let values = value["kvlistValue"]?["values"]?.arrayValue {
            return .object(attributes(.array(values)))
        }
        if let bytes = value["bytesValue"]?.stringValue { return .string(bytes) }
        return nil
    }
}

/// One daemon-wide, loopback-only OTLP/HTTP JSON receiver. Its random port and path token are persisted
/// under the daemon runtime directory, so a clean or crash restart rebinds the same endpoint already held
/// by surviving Claude processes. Card id + launch epoch are URL path segments; provider session identity
/// stays in the span attributes and is checked by the adapter.
public final class OTLPHTTPTraceReceiver: @unchecked Sendable {
    private struct PersistedEndpoint: Codable {
        let port: UInt16
        let token: String
    }

    private enum HTTPFailure: Error {
        case badRequest
        case notFound
        case tooLarge
    }

    private static let maximumHeaderBytes = 64 * 1024
    private static let maximumBodyBytes = 2 * 1024 * 1024

    public let baseURL: String
    private let port: UInt16
    private let token: String
    private let lock = NSLock()
    private var serverFD: Int32
    private var started = false
    private var callback: (@Sendable (OTLPTraceObservation) -> Void)?
    private var activeClients: Set<Int32> = []
    private let acceptQueue = DispatchQueue(label: "orchestra.otlp.accept")
    private let clientGroup = DispatchGroup()

    public init(runtimeStateDir: String) throws {
        try FileManager.default.createDirectory(
            atPath: runtimeStateDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let statePath = (runtimeStateDir as NSString).appendingPathComponent("claude-otlp-endpoint.json")
        let persisted = Self.readEndpoint(at: statePath)
        let endpoint: PersistedEndpoint
        let listener: (fd: Int32, port: UInt16)
        if let persisted {
            endpoint = persisted
            listener = try Self.bind(port: persisted.port)
        } else {
            listener = try Self.bind(port: 0)
            endpoint = .init(port: listener.port, token: UUID().uuidString.lowercased())
            do { try Self.writeEndpoint(endpoint, at: statePath) }
            catch { closeFD(listener.fd); throw error }
        }
        self.serverFD = listener.fd
        self.port = listener.port
        self.token = endpoint.token
        self.baseURL = "http://127.0.0.1:\(listener.port)/\(endpoint.token)"
    }

    deinit { stop() }

    public func start(onObservation: @escaping @Sendable (OTLPTraceObservation) -> Void) {
        let listener = lock.withLock { () -> Int32? in
            guard !started, serverFD >= 0 else { return nil }
            callback = onObservation
            started = true
            return serverFD
        }
        guard let listener else { return }
        acceptQueue.async { [weak self] in self?.acceptLoop(listener) }
    }

    public func stop() {
        let state = lock.withLock { () -> (fd: Int32, wasStarted: Bool) in
            let fd = serverFD
            let wasStarted = started
            serverFD = -1
            callback = nil
            started = false
            return (fd, wasStarted)
        }
        guard state.fd >= 0 else { return }
        var listenerClosed = false
        if state.wasStarted {
            // A listening TCP socket does not reliably wake `accept` through shutdown alone on macOS.
            // Connect once over loopback, then join admission before draining every accepted client.
            if !Self.wakeAccept(port: port) {
                shutdownFD(state.fd)
                closeFD(state.fd)
                listenerClosed = true
            }
            acceptQueue.sync {}
        }
        lock.withLock {
            // Serve jobs remain the sole closers. Holding their ownership lock across shutdown prevents
            // a finished job from closing and reusing an fd while stop is still interrupting it.
            for client in activeClients { shutdownFD(client) }
        }
        clientGroup.wait()
        if !listenerClosed { closeFD(state.fd) }
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if !lock.withLock({ serverFD == listener }) { return }
                continue
            }
            let registered = lock.withLock { () -> Bool in
                guard serverFD == listener else { return false }
                _ = activeClients.insert(client)
                clientGroup.enter()
                return true
            }
            guard registered else {
                closeFD(client)
                return
            }
            Self.suppressSIGPIPE(client)
            DispatchQueue.global().async { [self] in
                defer {
                    lock.withLock {
                        _ = activeClients.remove(client)
                        closeFD(client)
                    }
                    clientGroup.leave()
                }
                serve(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        do {
            let request = try Self.readRequest(client)
            let identity = try route(request.path)
            let observations = try OTLPTraceDecoder.decode(
                request.body,
                cardId: identity.cardId,
                sessionEpoch: identity.sessionEpoch
            )
            let sink = lock.withLock { callback }
            for observation in observations { sink?(observation) }
            Self.respond(client, status: "200 OK", body: "{}")
        } catch HTTPFailure.notFound {
            Self.respond(client, status: "404 Not Found", body: "{}")
        } catch HTTPFailure.tooLarge {
            Self.respond(client, status: "413 Content Too Large", body: "{}")
        } catch {
            Self.respond(client, status: "400 Bad Request", body: "{}")
        }
    }

    private func route(_ path: String) throws -> (cardId: UUID, sessionEpoch: Int) {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count == 5,
              components[0] == token,
              components[1] == "v1",
              components[2] == "traces",
              let cardId = UUID(uuidString: components[3]),
              let epoch = Int(components[4]), epoch >= 0
        else { throw HTTPFailure.notFound }
        return (cardId, epoch)
    }

    private static func readRequest(_ fd: Int32) throws -> (path: String, body: Data) {
        let delimiter = Data("\r\n\r\n".utf8)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var headerRange: Range<Data.Index>?
        while headerRange == nil {
            guard data.count <= maximumHeaderBytes else { throw HTTPFailure.tooLarge }
            guard let count = UDS.read(fd, into: &buffer) else { throw HTTPFailure.badRequest }
            if count == 0 { continue }
            data.append(contentsOf: buffer[0..<count])
            headerRange = data.range(of: delimiter)
        }
        guard let headerRange,
              let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
        else { throw HTTPFailure.badRequest }

        let lines = header.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ").map(String.init) ?? []
        guard request.count == 3, request[0] == "POST", request[2].hasPrefix("HTTP/1.") else {
            throw HTTPFailure.badRequest
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard let contentLengthText = fields["content-length"],
              let contentLength = Int(contentLengthText), contentLength >= 0
        else { throw HTTPFailure.badRequest }
        guard contentLength <= maximumBodyBytes else { throw HTTPFailure.tooLarge }

        let bodyStart = headerRange.upperBound
        while data.count - bodyStart < contentLength {
            guard let count = UDS.read(fd, into: &buffer) else { throw HTTPFailure.badRequest }
            if count == 0 { continue }
            data.append(contentsOf: buffer[0..<count])
            guard data.count - bodyStart <= maximumBodyBytes else { throw HTTPFailure.tooLarge }
        }
        return (request[1], data.subdata(in: bodyStart..<(bodyStart + contentLength)))
    }

    private static func respond(_ fd: Int32, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        _ = writeAll(fd, Data(header.utf8) + bodyData)
    }

    private static func bind(port: UInt16) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OrchestraError.io("OTLP socket failed: \(errnoText())") }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            closeFD(fd)
            throw OrchestraError.io("OTLP loopback address could not be encoded")
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                DarwinOrGlibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let message = errnoText()
            closeFD(fd)
            throw OrchestraError.io("OTLP bind failed: \(message)")
        }
        guard listen(fd, 32) == 0 else {
            let message = errnoText()
            closeFD(fd)
            throw OrchestraError.io("OTLP listen failed: \(message)")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            let message = errnoText()
            closeFD(fd)
            throw OrchestraError.io("OTLP getsockname failed: \(message)")
        }
        return (fd, UInt16(bigEndian: actual.sin_port))
    }

    private static func wakeAccept(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { closeFD(fd) }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { return false }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                DarwinOrGlibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func readEndpoint(at path: String) -> PersistedEndpoint? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let endpoint = try? JSONDecoder().decode(PersistedEndpoint.self, from: data),
              endpoint.port > 0, !endpoint.token.isEmpty
        else { return nil }
        return endpoint
    }

    private static func writeEndpoint(_ endpoint: PersistedEndpoint, at path: String) throws {
        let data = try JSONEncoder().encode(endpoint)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        chmod(path, 0o600)
    }

    private static func suppressSIGPIPE(_ fd: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                #if canImport(Darwin)
                let count = write(fd, base + offset, raw.count - offset)
                #else
                let count = send(fd, base + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                #endif
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
}

// `bind` is also a Swift method name; this namespace prevents the receiver's `bind(port:)` helper from
// shadowing the POSIX function at its call site on both Darwin and Linux.
private enum DarwinOrGlibc {
    static func bind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.bind(fd, address, length)
        #elseif canImport(Glibc)
        Glibc.bind(fd, address, length)
        #else
        Musl.bind(fd, address, length)
        #endif
    }

    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.connect(fd, address, length)
        #elseif canImport(Glibc)
        Glibc.connect(fd, address, length)
        #else
        Musl.connect(fd, address, length)
        #endif
    }
}
